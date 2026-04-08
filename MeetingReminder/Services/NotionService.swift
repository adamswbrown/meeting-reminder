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
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "notionIntegrationEnabled") }
    }

    // MARK: - Persistence

    private let tokenKey = "notionAPIToken"

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
    var isConfigured: Bool {
        apiToken != nil && !databaseID.isEmpty
    }

    /// True when the integration is enabled *and* configured — this is what
    /// the meeting pipeline should check.
    var isActive: Bool {
        isEnabled && isConfigured
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "notionIntegrationEnabled")
    }

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
        guard let token = apiToken, !databaseID.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        let startISO = iso.string(from: event.startDate)
        let endISO = iso.string(from: event.endDate)

        var properties: [String: Any] = [
            "Title": [
                "title": [
                    ["text": ["content": event.title]]
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
            properties["Attendees Name"] = [
                "rich_text": [
                    ["text": ["content": attendees.joined(separator: ", ")]]
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
        if let notes = event.notes, !notes.isEmpty {
            children.append([
                "object": "block",
                "type": "heading_3",
                "heading_3": [
                    "rich_text": [["text": ["content": "Calendar notes"]]]
                ],
            ])
            children.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [["text": ["content": notes]]]
                ],
            ])
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

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                if let httpResponse = response as? HTTPURLResponse {
                    let detail = String(data: data, encoding: .utf8) ?? ""
                    lastError = "HTTP \(httpResponse.statusCode)\(detail.isEmpty ? "" : " — \(detail)")"
                }
                return nil
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pageURL = json["url"] as? String {
                return URL(string: pageURL)
            }
        } catch {
            lastError = error.localizedDescription
        }

        return nil
    }

    // MARK: - Open in Notion desktop app

    /// Opens a Notion URL in the desktop app; falls back to the default browser.
    static func openInNotionApp(_ url: URL) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "notion.id") {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
