import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct NativeFallbackDraft {
    @Guide(description: "Grounded briefing, at most 1800 characters, with evidence IDs in square brackets")
    var summary: String
    @Guide(description: "Suggested preparation; at most 5 items of at most 300 characters", .count(0...5))
    var preparation: [String]
}

enum BriefingFallbackProviders {
    static func context(meeting: MeetingEvent, notion: BriefingNotionRepository) async -> BriefingContext {
        var context = await notion.context(for: meeting)
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Reuse the user's configured stdio MCP server and its installed SDK. Never
        // install dependencies, copy OAuth tokens or let the model pick tools.
        do {
            let configData = try Data(contentsOf: home.appendingPathComponent(".claude.json"))
            let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
            let servers = config?["mcpServers"] as? [String: Any]
            let teams = servers?["teams-chat"] as? [String: Any]
            let args = teams?["args"] as? [String] ?? []
            guard let directoryFlag = args.firstIndex(of: "--directory"), args.indices.contains(directoryFlag + 1),
                  let script = Bundle.main.url(forResource: "briefing-teams-context", withExtension: "py") else {
                throw BriefingFallbackError.unavailable("Teams MCP configuration unavailable.")
            }
            let python = URL(fileURLWithPath: args[directoryFlag + 1]).appendingPathComponent(".venv/bin/python").path
            // EventKit often gives only display names. Send actual emails only.
            let emails = (meeting.attendees ?? []).compactMap { value -> String? in
                let pattern = #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
                guard let range = value.range(of: pattern, options: .regularExpression) else { return nil }
                return String(value[range])
            }
            let input = try JSONSerialization.data(withJSONObject: ["title": meeting.title, "attendee_emails": emails])
            let result = await BriefingProcess.run(executable: python, arguments: [script.path],
                                                   input: String(decoding: input, as: UTF8.self), timeout: 50)
            guard result.succeeded, let data = result.output.data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["unavailable"] as? Bool == false, let text = payload["text"] as? String else {
                throw BriefingFallbackError.unavailable("Teams MCP unavailable.")
            }
            context.evidence.append(.init(id: "teams", source: "Teams context_for_meeting (last 14 days)", text: text))
            context.coverage.append("Teams: cached MCP results; freshness warnings in the evidence apply. \(emails.count) attendee emails available.")
            if payload["truncated"] as? Bool == true { context.coverage.append("Teams evidence truncated at 12000 characters.") }
        } catch { context.coverage.append("Teams MCP unavailable; outstanding conversations were not checked.") }
        return context
    }

    static func generate(context: BriefingContext, shortcut: String) async throws -> (BriefingDraft, String, BriefingContext) {
        var usedContext = context
        if !shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { return (try await cloud(context: context, shortcut: shortcut), "Shortcuts: \(shortcut)", usedContext) }
            catch { usedContext.coverage.append("Configured Shortcuts model failed; used the on-device model.") }
        }
        guard #available(macOS 26.4, *) else {
            throw BriefingFallbackError.unavailable("On-device fallback requires macOS 26.4 or later.")
        }
        let (draft, budget) = try await native(context: usedContext)
        usedContext.coverage.append(budget)
        return (draft, "Apple on-device", usedContext)
    }

    static func cloud(context: BriefingContext, shortcut: String) async throws -> BriefingDraft {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brief-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.txt"), output = directory.appendingPathComponent("output.txt")
        // Character budget, NOT a claimed PCC token limit. Output must validate before any write.
        let prompt = BriefingDraft.instructions + "\n" + context.prompt(evidenceCharacters: 24000)
        try Data(prompt.utf8).write(to: input)
        let result = await BriefingProcess.run(executable: "/usr/bin/shortcuts",
            arguments: ["run", shortcut, "--input-path", input.path, "--output-path", output.path], timeout: 90)
        guard result.succeeded else { throw BriefingFallbackError.unavailable("Shortcut failed or timed out.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 20000 else { throw BriefingFallbackError.invalidOutput }
        return try BriefingDraft.parse(String(contentsOf: output, encoding: .utf8))
    }

    @available(macOS 26.4, *)
    static func native(context: BriefingContext) async throws -> (BriefingDraft, String) {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw BriefingFallbackError.unavailable("Apple Intelligence is not ready on this Mac.")
        }
        let instructions = BriefingDraft.instructions
        let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
        let schemaTokens = try await model.tokenCount(for: NativeFallbackDraft.generationSchema)
        let reserve = 1200 + 512 // output plus transcript/formatting margin
        for cap in [14000, 8000, 4000, 1500, 0] {
            let prompt = context.prompt(evidenceCharacters: cap)
            let inputTokens = try await model.tokenCount(for: prompt)
            guard inputTokens + instructionTokens + schemaTokens + reserve <= model.contextSize else { continue }
            do {
                // Fresh session per attempt: a failed request must not consume the next attempt's context.
                let session = LanguageModelSession(model: model, instructions: instructions)
                let response = try await session.respond(to: prompt, generating: NativeFallbackDraft.self,
                    options: GenerationOptions(maximumResponseTokens: 1200)).content
                let draft = BriefingDraft(summary: response.summary, preparation: response.preparation)
                _ = try BriefingDraft.parse(String(decoding: JSONEncoder().encode(draft), as: UTF8.self))
                return (draft, "On-device context window \(model.contextSize) tokens; evidence capped at \(cap) characters. Output reserve 1200 tokens.")
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error { continue }
                throw error
            }
        }
        throw BriefingFallbackError.unavailable("The meeting context does not fit the local model.")
    }
}
