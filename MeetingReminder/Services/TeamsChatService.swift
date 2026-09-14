import Foundation

/// Reads recent Microsoft Teams chat messages for a meeting's attendees so the
/// pre-call brief can show "what we last talked about" alongside the Notion
/// brief. Delegated Graph only — never the metered app-only
/// `/users/{id}/chats/getAllMessages` export API.
///
/// Auth is borrowed wholesale from `GraphMailService` (same refresh token,
/// same public client). Whether chats are readable at all is decided from the
/// token's `scp` claim (`graph.canReadChats`); when the scope is missing this
/// service degrades to "no context" without surfacing errors to the brief.
///
/// Endpoints (all delegated, none metered):
/// - `GET /me/chats?$expand=members&$top=50` (paged via `@odata.nextLink`)
///   → email → chat directory, cached in UserDefaults and refreshed daily.
/// - `GET /chats/{id}/messages?$top=20` → last messages per attendee, HTML
///   bodies reduced to text by `TeamsChatSupport`.
///
/// Graph throttles Teams chat reads per app per tenant; fetches run serially
/// with a short gap and `GraphMailService.get` honours `Retry-After` on 429.
@MainActor
final class TeamsChatService: ObservableObject {
    // MARK: - Settings

    static let enabledKey = "teamsChatContextEnabled"
    private static let directoryKey = "teamsChatDirectory"

    /// Master toggle (Settings → Integrations → Availability → Teams chat context).
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
            // Turning it on is the moment to learn the granted scopes (first
            // token refresh) and build the directory, so Settings shows a real
            // status instead of "not checked yet".
            if newValue, graph.isConnected {
                Task { await ensureDirectory() }
            }
        }
    }

    /// How far back to show messages, and how many per attendee.
    var lookbackDays = 14
    var messagesPerAttendee = 10
    /// Graph caps `$top` at 50 for chat messages; 20 is plenty for context.
    private let fetchTop = 20
    /// Upper bound on chat directory pages (50 chats each) per refresh.
    private let maxDirectoryPages = 10

    // MARK: - Published state

    @Published private(set) var directory: TeamsChatDirectory?
    @Published private(set) var isRefreshingDirectory = false
    @Published var lastError: String?
    @Published private(set) var lastDirectoryRefresh: Date?

    // MARK: - Deps

    private let graph: GraphMailService

    init(graph: GraphMailService) {
        self.graph = graph
        if let data = UserDefaults.standard.data(forKey: Self.directoryKey),
           let dir = try? JSONDecoder().decode(TeamsChatDirectory.self, from: data) {
            directory = dir
            lastDirectoryRefresh = dir.fetchedAt
        }
    }

    /// Scopes are only known after the first token refresh of this install;
    /// until then we attempt the read rather than assume it's denied.
    private var scopesUnknown: Bool { graph.grantedScopes.isEmpty }

    /// True when the feature can actually produce output right now.
    var isAvailable: Bool { isEnabled && graph.isConnected && (graph.canReadChats || scopesUnknown) }

    /// Reflects whether the permission is confirmed missing (drives the orange status).
    var isPermissionDenied: Bool { graph.isConnected && !scopesUnknown && !graph.canReadChats }

    /// One-line status for Settings.
    var statusText: String {
        if !graph.isConnected { return "Exchange not connected." }
        if scopesUnknown {
            return "Permission not checked yet — click Refresh chat directory."
        }
        if !graph.canReadChats {
            return "The Exchange sign-in has no Teams chat permission. Reconnect to grant it (needs \(TeamsChatSupport.chatScope))."
        }
        if let dir = directory {
            let f = RelativeDateTimeFormatter()
            return "\(dir.byEmail.count) contacts mapped · directory refreshed \(f.localizedString(for: dir.fetchedAt, relativeTo: Date()))."
        }
        return "Chat permission granted — directory not built yet."
    }

    // MARK: - Directory

    /// Ensure the directory exists and is fresh; rebuilds when missing or >24h old.
    @discardableResult
    func ensureDirectory(force: Bool = false) async -> TeamsChatDirectory? {
        if !force, let dir = directory, !dir.isStale { return dir }
        return await refreshDirectory()
    }

    func refreshDirectory() async -> TeamsChatDirectory? {
        guard !isRefreshingDirectory else { return directory }
        guard graph.isConnected else { lastError = "Exchange not connected"; return directory }
        isRefreshingDirectory = true
        defer { isRefreshingDirectory = false }

        var chats: [[String: Any]] = []
        var next: URL? = URL(string: "https://graph.microsoft.com/v1.0/me/chats?$expand=members&$top=50")
        var pages = 0
        do {
            while let url = next, pages < maxDirectoryPages {
                let (data, http) = try await graph.get(url)
                guard http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = http.statusCode == 403
                        ? "Graph refused the chat list (403) — the sign-in has no \(TeamsChatSupport.chatScope) permission."
                        : "Graph HTTP \(http.statusCode) listing chats"
                    return directory
                }
                chats.append(contentsOf: (json["value"] as? [[String: Any]]) ?? [])
                next = (json["@odata.nextLink"] as? String).flatMap(URL.init(string:))
                pages += 1
            }
        } catch {
            lastError = error.localizedDescription
            return directory
        }

        let dir = TeamsChatSupport.buildDirectory(chats: chats, selfEmail: graph.connectedEmail)
        directory = dir
        lastDirectoryRefresh = dir.fetchedAt
        if let data = try? JSONEncoder().encode(dir) {
            UserDefaults.standard.set(data, forKey: Self.directoryKey)
        }
        lastError = nil
        return dir
    }

    // MARK: - Context

    /// Recent chat context for each attendee of `event` that has a Teams chat
    /// with the user. Silent no-op (empty array) when disabled, disconnected, or
    /// the chat scope isn't granted. Only 1:1 chats are read — group chats are
    /// noisy and often unrelated to the meeting.
    func recentContext(for event: MeetingEvent) async -> [TeamsChatContext] {
        guard isAvailable else { return [] }
        guard let emails = event.attendeeEmails, !emails.isEmpty,
              let dir = await ensureDirectory() else { return [] }

        let me = graph.connectedEmail?.lowercased()
        var out: [TeamsChatContext] = []
        for (index, rawEmail) in emails.enumerated() {
            let email = rawEmail.lowercased()
            guard email != me,
                  let chat = dir.byEmail[email]?.first(where: { $0.chatType == "oneOnOne" }) else { continue }
            let name = event.attendees?.indices.contains(index) == true ? event.attendees![index] : email
            if let messages = await fetchMessages(chatID: chat.chatID), !messages.isEmpty {
                out.append(TeamsChatContext(email: email, displayName: name, chatID: chat.chatID, messages: messages))
            }
            // Gentle pacing between chats — well under Graph's per-app limit.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return out
    }

    private func fetchMessages(chatID: String) async -> [TeamsChatMessage]? {
        guard let url = URL(string: "https://graph.microsoft.com/v1.0/chats/\(chatID)/messages?$top=\(fetchTop)") else { return nil }
        do {
            let (data, http) = try await graph.get(url)
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["value"] as? [[String: Any]] else {
                lastError = "Graph HTTP \(http.statusCode) reading chat"
                return nil
            }
            let all = TeamsChatSupport.parseMessages(results)
            return TeamsChatSupport.recent(all, days: lookbackDays, limit: messagesPerAttendee)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
