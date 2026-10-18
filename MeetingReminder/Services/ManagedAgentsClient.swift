import Foundation

// MARK: - Settings

/// Which Managed Agent a run targets. Each role has its own agent ID in UserDefaults;
/// the environment and vault are shared.
enum ManagedAgentRole: String {
    case precall
    case followUp

    var agentIDKey: String {
        switch self {
        case .precall: return "managedAgentsPrecallAgentID"
        case .followUp: return "managedAgentsFollowUpAgentID"
        }
    }
}

enum ManagedAgentsSettings {
    /// Keychain entry for the Anthropic API key (never UserDefaults).
    static let apiKeyKeychainKey = "anthropicAPIKey"
    static let environmentIDKey = "managedAgentsEnvironmentID"
    static let vaultIDKey = "managedAgentsVaultID"
    /// Opt-in: send intraday pre-call briefings to the Managed Agent instead of the local `claude` CLI.
    static let precallEnabledKey = "managedAgentsPrecallEnabled"

    static var apiKey: String? {
        let key = KeychainHelper.read(key: apiKeyKeychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty == false) ? key : nil
    }

    static func agentID(for role: ManagedAgentRole) -> String? { trimmedDefault(role.agentIDKey) }
    static var environmentID: String? { trimmedDefault(environmentIDKey) }
    static var vaultID: String? { trimmedDefault(vaultIDKey) }

    /// True when a run for `role` has everything it needs (key, agent, environment).
    /// The vault is optional here — an agent with no credentials can still run.
    static func isConfigured(for role: ManagedAgentRole) -> Bool {
        apiKey != nil && agentID(for: role) != nil && environmentID != nil
    }

    private static func trimmedDefault(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
}

// MARK: - Prompts

enum ManagedAgentsPrompts {
    /// Prepended to the locally-built briefing skill when it runs in the sandbox. The skill
    /// was written for a headless `claude` on the Mac (Keychain, `remctl`, MCP servers); none
    /// of that exists in the sandbox, so say where the equivalents live. The skill's own
    /// result-line format is deliberately left untouched — the app parses it.
    static let precallPreamble = """
    RUNTIME NOTE — you are running in a cloud sandbox, not on the user's Mac. Where this \
    conflicts with the tool instructions below, this note wins:
    - There is no Keychain, `security` command, `remctl`, macOS app or MCP server.
    - Slack: call https://slack.com/api/chat.postMessage with curl and the header \
    `Authorization: Bearer $SLACK_BOT_TOKEN`.
    - Notion: call https://api.notion.com/v1/... with curl, the header \
    `Authorization: Bearer $NOTION_API_TOKEN` and `Notion-Version: 2025-09-03`. Query data sources \
    by data source ID.
    - Never print either token. Use the environment variables exactly as written.
    - Apple Reminders cannot be written from here. Skip every Reminders / `remctl` step.
    - Everything else, including the final `INTRADAY_RESULT:` line, is unchanged.

    ---

    """
}

// MARK: - Errors

enum ManagedAgentsError: LocalizedError {
    case notConfigured
    /// The session was never started (or the prompt never reached it). Nothing ran, so the
    /// caller may safely retry the same work another way.
    case startFailed(String)
    /// The session started and then failed, was terminated, or hit its budget. It may have
    /// produced side effects, so the caller must NOT re-run the work elsewhere.
    case runFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Managed Agents is not configured"
        case .startFailed(let why): return "could not start Managed Agent session: \(why)"
        case .runFailed(let why): return "Managed Agent run failed: \(why)"
        case .timedOut: return "Managed Agent run timed out"
        }
    }
}

// MARK: - Event parsing (pure)

enum ManagedAgentsEventParser {
    enum Outcome: Equatable {
        case running
        /// Session is paused waiting for the client to settle these tool-use events.
        case needsConfirmation(toolUseIDs: [String])
        case finished(text: String)
        case budgetReached(text: String)
        case terminated(text: String)
    }

    /// Reduces a session's event list to what the poller should do next.
    ///
    /// A freshly created session reports `idle` before it has picked up the queued user
    /// message, so `idle` only counts as finished once the session has been seen running.
    static func outcome(of rawEvents: [[String: Any]]) -> Outcome {
        // Order by processed_at (ISO 8601 sorts lexicographically); the original index breaks
        // ties and keeps events without a timestamp in place.
        let events = rawEvents.enumerated().sorted { a, b in
            let ta = a.element["processed_at"] as? String ?? ""
            let tb = b.element["processed_at"] as? String ?? ""
            return ta == tb ? a.offset < b.offset : ta < tb
        }.map { $0.element }

        var sawRunning = false
        var status = "running"
        var stopType: String?
        var confirmIDs: [String] = []
        var texts: [String] = []

        for event in events {
            guard let type = event["type"] as? String else { continue }
            switch type {
            case "agent.message":
                let blocks = event["content"] as? [[String: Any]] ?? []
                for block in blocks where (block["type"] as? String) == "text" {
                    if let text = block["text"] as? String { texts.append(text) }
                }
            case "session.status_running", "session.status_rescheduled", "status_running":
                sawRunning = true
                status = "running"
                stopType = nil
                confirmIDs = []
            case "session.status_idle", "status_idle":
                status = "idle"
                let reason = event["stop_reason"] as? [String: Any]
                stopType = reason?["type"] as? String
                confirmIDs = reason?["event_ids"] as? [String] ?? []
            case "session.status_terminated", "status_terminated":
                status = "terminated"
            default:
                break
            }
        }

        let text = texts.joined(separator: "\n")
        switch status {
        case "terminated":
            return .terminated(text: text)
        case "idle":
            if stopType == "requires_action" { return .needsConfirmation(toolUseIDs: confirmIDs) }
            if stopType == "budget_reached" { return .budgetReached(text: text) }
            return sawRunning ? .finished(text: text) : .running
        default:
            return .running
        }
    }
}

// MARK: - Client

/// Minimal raw-HTTP client for Managed Agents (the repo has no SwiftPM dependencies, so
/// there is no SDK). Start a session on a pre-created agent, send one message, poll the
/// event list until the session settles, return the agent's text.
enum ManagedAgentsClient {
    private static let host = "https://api.anthropic.com"

    /// Runs `prompt` on the agent for `role` and returns the agent's text output.
    ///
    /// - Parameters:
    ///   - maxCostCents: hard per-session spend cap (list price, USD cents); the platform pauses
    ///     the session at the cap and this call throws `runFailed`.
    ///   - timeout: wall-clock limit for the whole run.
    static func run(role: ManagedAgentRole,
                    prompt: String,
                    title: String,
                    maxCostCents: Int,
                    timeout: TimeInterval) async throws -> String {
        guard let apiKey = ManagedAgentsSettings.apiKey,
              let agentID = ManagedAgentsSettings.agentID(for: role),
              let environmentID = ManagedAgentsSettings.environmentID else {
            throw ManagedAgentsError.notConfigured
        }

        var sessionBody: [String: Any] = [
            "agent": agentID,
            "environment_id": environmentID,
            "title": String(title.prefix(120)),
            "budget": [
                "type": "limit",
                "max_list_cost": ["amount": String(maxCostCents), "currency": "USD"],
            ],
        ]
        if let vaultID = ManagedAgentsSettings.vaultID { sessionBody["vault_ids"] = [vaultID] }

        let sessionID: String
        do {
            let session = try await request("POST", "/v1/sessions", body: sessionBody, apiKey: apiKey)
            guard let id = session["id"] as? String else {
                throw ManagedAgentsError.startFailed("response had no session id")
            }
            sessionID = id
            try await sendEvents(
                [["type": "user.message", "content": [["type": "text", "text": prompt]]]],
                to: sessionID, apiKey: apiKey)
        } catch let error as ManagedAgentsError {
            throw error
        } catch {
            throw ManagedAgentsError.startFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var denied = Set<String>()
        var pollNanos: UInt64 = 2_000_000_000

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: pollNanos)
            pollNanos = min(pollNanos + 1_000_000_000, 6_000_000_000)

            // A failed poll is transient — keep going until the deadline.
            guard let page = try? await request(
                "GET", "/v1/sessions/\(sessionID)/events?limit=1000", body: nil, apiKey: apiKey) else { continue }
            let events = page["data"] as? [[String: Any]] ?? []

            switch ManagedAgentsEventParser.outcome(of: events) {
            case .running:
                continue
            case .needsConfirmation(let ids):
                // Nobody is watching a background run: refuse anything the server could not
                // clear on its own rather than approving blind.
                let fresh = ids.filter { denied.insert($0).inserted }
                if !fresh.isEmpty {
                    let confirmations: [[String: Any]] = fresh.map { ["type": "user.tool_confirmation", "tool_use_id": $0, "result": "deny"] }
                    try? await sendEvents(confirmations, to: sessionID, apiKey: apiKey)
                }
            case .finished(let text):
                return text
            case .budgetReached:
                throw ManagedAgentsError.runFailed("session hit its \(maxCostCents)¢ budget cap")
            case .terminated(let text):
                throw ManagedAgentsError.runFailed(text.isEmpty ? "session terminated" : String(text.prefix(300)))
            }
        }

        try? await sendEvents([["type": "user.interrupt"]], to: sessionID, apiKey: apiKey)
        throw ManagedAgentsError.timedOut
    }

    // MARK: HTTP

    private static func sendEvents(_ events: [[String: Any]], to sessionID: String, apiKey: String) async throws {
        _ = try await request("POST", "/v1/sessions/\(sessionID)/events", body: ["events": events], apiKey: apiKey)
    }

    private static func request(_ method: String,
                                _ path: String,
                                body: [String: Any]?,
                                apiKey: String) async throws -> [String: Any] {
        guard let url = URL(string: host + path) else {
            throw ManagedAgentsError.startFailed("bad URL \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("managed-agents-2026-04-01", forHTTPHeaderField: "anthropic-beta")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw ManagedAgentsError.startFailed("HTTP \(status): \(message)")
        }
        return json
    }
}
