import AppKit
import Foundation

/// Notion API client for creating meeting pages in a user-chosen database.
///
/// This service is deliberately minimal: on meeting join it creates a page in
/// the configured database and opens it in the Notion desktop app. Recording,
/// transcription, and summarisation are delegated to Notion's own AI Meeting
/// Notes block — Meeting Reminder just provides the trigger + the scaffolding.
@MainActor
final class NotionService: ObservableObject {
    // MARK: - Published state

    @Published var isConnected = false
    @Published var databaseName: String?
    @Published var lastError: String?
    @Published var isTesting = false

    // MARK: - Persistence

    private let tokenKey = "notionAPIToken"

    /// Tracks event IDs for which a Notion page has already been created this
    /// session. Prevents duplicate pages when the Combine sink fires more than
    /// once for the same meeting (e.g. rapid state transitions or multi-screen
    /// overlay setups).
    private var createdEventIDs: Set<String> = []

    /// Tracks event IDs for which a page creation is currently in-flight.
    /// Guards against concurrent `createMeetingPage` calls for the same event
    /// that could both pass the `createdEventIDs` check before either inserts
    /// its ID (possible because `@MainActor` suspends at `await` points).
    private var pendingEventIDs: Set<String> = []

    /// Bundle identifier for the Notion desktop application.
    private static let notionBundleID = "notion.id"

    var databaseID: String {
        get { UserDefaults.standard.string(forKey: "notionDatabaseID") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "notionDatabaseID")
            objectWillChange.send()
        }
    }

    var apiToken: String? {
        KeychainHelper.read(key: tokenKey)
    }

    /// True when the user has entered both a token and a database ID.
    /// This is also the "active" check — if you've configured it, it's on.
    /// There is no separate enable toggle: credentials alone = active.
    var isConfigured: Bool {
        apiToken != nil && !databaseID.isEmpty
    }

    /// Kept as an alias so existing call sites don't churn. Same as `isConfigured`.
    var isActive: Bool { isConfigured }

    init() {}

    // MARK: - Token management

    func setAPIToken(_ token: String) {
        KeychainHelper.save(key: tokenKey, value: token)
        objectWillChange.send()
        Task { await testConnection() }
    }

    func clearAPIToken() {
        KeychainHelper.delete(key: tokenKey)
        isConnected = false
        databaseName = nil
        objectWillChange.send()
    }

    // MARK: - Connection test

    func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        guard let token = apiToken else {
            isConnected = false
            lastError = "Missing API token — paste it above and click Save."
            return
        }
        guard !databaseID.isEmpty else {
            isConnected = false
            lastError = "Missing database ID — paste it above and click Save."
            return
        }

        do {
            let url = URL(string: "https://api.notion.com/v1/databases/\(databaseID)")!
            var request = URLRequest(url: url)
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.addValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                isConnected = false
                lastError = "Invalid response"
                return
            }

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let title = json["title"] as? [[String: Any]],
                   let plainText = title.first?["plain_text"] as? String {
                    databaseName = plainText
                }
                isConnected = true
                lastError = nil
            } else {
                isConnected = false
                let body = String(data: data, encoding: .utf8) ?? ""
                lastError = "HTTP \(httpResponse.statusCode)\(body.isEmpty ? "" : " — \(body)")"
            }
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }
    }

    // MARK: - Create meeting page

    /// Creates a new page in the Notion database for a meeting event.
    /// Returns the page URL if successful.
    ///
    /// Property schema expected on the target database:
    ///   - Title (title)
    ///   - Start (date)
    ///   - End (date)
    ///   - Attendees Name (rich_text)  — optional
    func createMeetingPage(for event: MeetingEvent) async -> URL? {
        guard !createdEventIDs.contains(event.id),
              !pendingEventIDs.contains(event.id) else {
            // A page was already created (or is currently being created) for this
            // event. Clear lastError so the caller knows this is a silent skip,
            // not a real failure, and won't show a spurious error banner.
            lastError = nil
            return nil
        }

        // Mark as in-flight before the first await so that a second call racing
        // through while the API request is pending won't pass the guard above.
        pendingEventIDs.insert(event.id)
        defer { pendingEventIDs.remove(event.id) }

        guard let token = apiToken, !databaseID.isEmpty else {
            lastError = "Notion not configured — missing API token or database ID."
            return nil
        }
        lastError = nil

        let iso = ISO8601DateFormatter()
        let startISO = iso.string(from: event.startDate)
        let endISO = iso.string(from: event.endDate)

        // Notion limits title rich_text content to 2000 chars.
        let titleContent = String(event.title.prefix(2000))

        var properties: [String: Any] = [
            "Title": [
                "title": [
                    ["text": ["content": titleContent]]
                ]
            ],
            "Start": [
                "date": ["start": startISO]
            ],
            "End": [
                "date": ["start": endISO]
            ],
        ]

        if let attendees = event.attendees, !attendees.isEmpty {
            let joined = attendees.joined(separator: ", ")
            let truncated = String(joined.prefix(2000))
            properties["Attendees Name"] = [
                "rich_text": [
                    ["text": ["content": truncated]]
                ]
            ]
        }

        // Keep the page body minimal — Notion's AI Meeting Notes block auto-injects.
        var children: [[String: Any]] = []
        if let link = event.videoLink?.absoluteString {
            children.append([
                "object": "block",
                "type": "bookmark",
                "bookmark": ["url": link],
            ])
        }
        let cleanedNotes = NotionService.stripVideoConferencingBoilerplate(from: event.notes ?? "")
        if !cleanedNotes.isEmpty {
            children.append([
                "object": "block",
                "type": "heading_3",
                "heading_3": [
                    "rich_text": [["text": ["content": "Calendar notes"]]]
                ],
            ])
            // Notion limits each rich_text element's text.content to 2000 chars.
            // Split long notes into separate paragraph blocks (one per chunk) so
            // that every rich_text[0].text.content is guaranteed to be ≤ 2000 chars.
            let limit = 2000
            var remaining = cleanedNotes[cleanedNotes.startIndex...]
            while !remaining.isEmpty {
                let end = remaining.index(remaining.startIndex, offsetBy: limit, limitedBy: remaining.endIndex) ?? remaining.endIndex
                children.append([
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": [
                        "rich_text": [["text": ["content": String(remaining[..<end])]]]
                    ],
                ])
                remaining = remaining[end...]
            }
        }

        let body: [String: Any] = [
            "parent": ["database_id": databaseID],
            "properties": properties,
            "children": children,
        ]

        do {
            let url = URL(string: "https://api.notion.com/v1/pages")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.addValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response from Notion"
                return nil
            }
            guard httpResponse.statusCode == 200 else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                lastError = "Notion HTTP \(httpResponse.statusCode)\(detail.isEmpty ? "" : " — \(detail)")"
                return nil
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pageURL = json["url"] as? String,
               let result = URL(string: pageURL) {
                // Only mark as created after a confirmed successful API response so
                // that transient failures don't permanently suppress retries.
                createdEventIDs.insert(event.id)
                return result
            }
            lastError = "Notion returned 200 but no page URL in response body"
        } catch {
            lastError = error.localizedDescription
        }

        return nil
    }

    // MARK: - Open in Notion desktop app

    /// Strips video-conferencing boilerplate blocks from calendar notes before
    /// sending to Notion. Invite generators (Teams, Zoom, etc.) embed a block of
    /// join-link metadata delimited by long horizontal separator lines (10+
    /// underscores or dashes). That information is redundant in Notion because
    /// the video link is already captured as a bookmark block.
    static func stripVideoConferencingBoilerplate(from notes: String) -> String {
        // Match a block that starts and ends with a line of 10+ underscores or dashes,
        // capturing everything in between (including newlines via .dotMatchesLineSeparators).
        let pattern = #"[ \t]*[_\-]{10,}[ \t]*[\r\n].+?[ \t]*[_\-]{10,}[ \t]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return notes }
        let range = NSRange(notes.startIndex..., in: notes)
        let cleaned = regex.stringByReplacingMatches(in: notes, range: range, withTemplate: "")
        // Collapse 3+ consecutive blank lines left after removal
        let collapsed = cleaned.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Opens a Notion URL in the desktop app; falls back to the default browser.
    ///
    /// Prefers the `notion://` deep-link scheme over passing an `https://` URL
    /// via `withApplicationAt:`. Notion's Electron app can forward an `https://`
    /// URL to the system browser in addition to opening it internally, which
    /// causes the page to open twice (once in the app, once in a browser tab).
    /// Using `notion://` routes the URL exclusively through Notion's registered
    /// URL-scheme handler, so only the desktop app handles it.
    static func openInNotionApp(_ url: URL) {
        // Convert https://www.notion.so/... → notion://www.notion.so/... so the
        // URL is handled only by the Notion desktop app, not also by the browser.
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.scheme == "https" || components.scheme == "http",
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: notionBundleID) != nil {
            components.scheme = "notion"
            if let deepLinkURL = components.url {
                NSWorkspace.shared.open(deepLinkURL)
                return
            }
        }

        // Fallback: open via explicit app launch, or browser if Notion is absent.
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notionBundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
