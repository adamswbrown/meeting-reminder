import Foundation

struct BriefingProcessResult {
    var output: String
    var error: String = ""
    var exitCode: Int32 = 0
    var timedOut = false

    /// Only trust the CLI's final error envelope. A rate limit in a tool response,
    /// a quoted document, a network error or an authentication error is not exhaustion.
    var providerExhausted: Bool {
        guard !timedOut, let data = output.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["type"] as? String == "result",
              envelope["is_error"] as? Bool == true else { return false }
        let messages: [String]
        if let result = envelope["result"] as? String, !result.isEmpty { messages = [result] }
        else { messages = envelope["errors"] as? [String] ?? [] }
        guard !messages.isEmpty else { return false }
        return messages.allSatisfy { raw in
            let message = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["you've hit your limit", "you have hit your limit", "credit balance is too low",
                "usage limit reached", "you've reached your usage limit"].contains(where: { message.hasPrefix($0) }) { return true }
            // Anthropic API credit failures can be wrapped by the CLI in this envelope.
            // Accept only its exact error type/message, never generic 429/tool text.
            guard raw.hasPrefix("API Error: 400 "), let brace = raw.firstIndex(of: "{"),
                  let bytes = String(raw[brace...]).data(using: .utf8),
                  let api = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let error = api["error"] as? [String: Any],
                  error["type"] as? String == "invalid_request_error",
                  let detail = error["message"] as? String else { return false }
            return detail.lowercased().hasPrefix("your credit balance is too low")
        }
    }

    var text: String {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String else { return output }
        return result
    }

    var succeeded: Bool {
        guard !timedOut, exitCode == 0 else { return false }
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["is_error"] as? Bool == true { return false }
        return true
    }
}

/// Bounded child processes. Files avoid pipe deadlocks (including inherited pipes
/// in MCP grandchildren). A timeout never authorizes repeating a remote write.
enum BriefingProcess {
    static func run(executable: String, arguments: [String], input: String = "",
                    timeout: TimeInterval = 90) async -> BriefingProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("brief-process-\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let inputURL = directory.appendingPathComponent("input")
                    let outputURL = directory.appendingPathComponent("output")
                    let errorURL = directory.appendingPathComponent("error")
                    try Data(input.utf8).write(to: inputURL)
                    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                    let stdin = try FileHandle(forReadingFrom: inputURL)
                    let stdout = try FileHandle(forWritingTo: outputURL)
                    let stderr = try FileHandle(forWritingTo: errorURL)
                    defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.currentDirectoryURL = directory
                    var environment = ProcessInfo.processInfo.environment
                    let home = NSHomeDirectory()
                    environment["HOME"] = environment["HOME"] ?? home
                    environment["PATH"] = ["\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/bin",
                        "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
                    process.environment = environment
                    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
                    let done = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in done.signal() }
                    try process.run()
                    let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
                    if timedOut {
                        if process.isRunning { process.terminate() }
                        if done.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                            _ = done.wait(timeout: .now() + 2)
                        }
                    }
                    // Read only a bounded prefix, never dump diagnostics or tokens into logs.
                    func read(_ url: URL) -> String {
                        guard let file = try? FileHandle(forReadingFrom: url) else { return "" }
                        defer { try? file.close() }
                        let bytes = (try? file.read(upToCount: 1_048_576)) ?? Data()
                        return String(data: bytes, encoding: .utf8) ?? ""
                    }
                    continuation.resume(returning: .init(output: read(outputURL), error: read(errorURL),
                        exitCode: process.isRunning ? -1 : process.terminationStatus, timedOut: timedOut))
                } catch {
                    continuation.resume(returning: .init(output: "", error: "Process launch failed", exitCode: -1))
                }
            }
        }
    }

    static func claude(path: String, prompt: String, generationOnly: Bool = false) async -> BriefingProcessResult {
        var arguments = ["--print", "--output-format", "json", "--no-session-persistence"]
        if generationOnly {
            arguments += ["--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                          "--disable-slash-commands", "--system-prompt", BriefingDraft.instructions]
        } else {
            arguments += ["--dangerously-skip-permissions"]
        }
        return await run(executable: path, arguments: arguments, input: prompt, timeout: generationOnly ? 120 : 600)
    }
}
