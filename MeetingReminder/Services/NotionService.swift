import AppKit
import Foundation
import Security

/// Notion API client for creating meeting pages and fetching content
@MainActor
final class NotionService: ObservableObject {
    @Published var isConnected = false
    @Published var databaseName: String?
    @Published var lastError: String?

    private var apiToken: String? {
        KeychainHelper.read(key: "notionAPIToken")
    }

    var databaseID: String {
        get { UserDefaults.standard.string(forKey: "notionDatabaseID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "notionDatabaseID") }
    }

    var isConfigured: Bool {
        apiToken != nil && !databaseID.isEmpty
    }

    // MARK: - Token Management

    func setAPIToken(_ token: String) {
        KeychainHelper.save(key: "notionAPIToken", value: token)
        Task { await testConnection() }
    }

    func clearAPIToken() {
        KeychainHelper.delete(key: "notionAPIToken")
        isConnected = false
        databaseName = nil
    }

    // MARK: - Connection Test

    func testConnection() async {
        guard let token = apiToken, !databaseID.isEmpty else {
            isConnected = false
            lastError = "Missing API token or database ID"
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
                lastError = "HTTP \(httpResponse.statusCode)"
            }
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }
    }

    // MARK: - Create Meeting Page

    /// Creates a new page in the Notion database for a meeting event.
    /// Returns the page URL if successful.
    func createMeetingPage(event: MeetingEvent, attendees: [String] = [], agenda: String? = nil) async -> URL? {
        guard let token = apiToken, !databaseID.isEmpty else { return nil }

        let dateFormatter = ISO8601DateFormatter()
        let startISO = dateFormatter.string(from: event.startDate)
        let endISO = dateFormatter.string(from: event.endDate)

        var properties: [String: Any] = [
            "Title": [
                "title": [
                    ["text": ["content": event.title]]
                ]
            ],
            "Start": [
                "date": [
                    "start": startISO,
                ]
            ],
            "End": [
                "date": [
                    "start": endISO,
                ]
            ],
        ]

        // Add attendee names as rich text
        if !attendees.isEmpty {
            properties["Attendees Name"] = [
                "rich_text": [
                    ["text": ["content": attendees.joined(separator: ", ")]]
                ]
            ]
        }

        // Build page children — keep minimal, Notion auto-injects AI Meeting Notes block
        var children: [[String: Any]] = []

        if let link = event.videoLink?.absoluteString {
            children.append([
                "object": "block",
                "type": "bookmark",
                "bookmark": ["url": link],
            ])
        }

        if let agenda, !agenda.isEmpty {
            children.append([
                "object": "block",
                "type": "heading_3",
                "heading_3": [
                    "rich_text": [["text": ["content": "Agenda"]]]
                ],
            ])
            children.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [["text": ["content": agenda]]]
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
                return nil
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pageURL = json["url"] as? String {
                return URL(string: pageURL)
            }
        } catch {
            print("Notion create page error: \(error)")
        }

        return nil
    }

    // MARK: - Open in Notion Desktop App

    /// Opens a Notion URL in the desktop app rather than the browser.
    /// Falls back to default browser if Notion.app is not installed.
    static func openInNotionApp(_ url: URL) {
        let notionURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "notion.id")
        if let appURL = notionURL {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Fetch Page Content (for post-meeting action items)

    func fetchPageBlocks(pageID: String) async -> [String] {
        guard let token = apiToken else { return [] }

        do {
            let url = URL(string: "https://api.notion.com/v1/blocks/\(pageID)/children?page_size=100")!
            var request = URLRequest(url: url)
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.addValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }

            // Extract to-do items (action items)
            var actionItems: [String] = []
            for block in results {
                if let type = block["type"] as? String, type == "to_do",
                   let todo = block["to_do"] as? [String: Any],
                   let richText = todo["rich_text"] as? [[String: Any]],
                   let text = richText.first?["plain_text"] as? String,
                   !text.isEmpty {
                    let checked = (todo["checked"] as? Bool) ?? false
                    actionItems.append("\(checked ? "Done" : "TODO"): \(text)")
                }
            }
            return actionItems
        } catch {
            return []
        }
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.meetingreminder.app",
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.meetingreminder.app",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.meetingreminder.app",
        ]

        SecItemDelete(query as CFDictionary)
    }
}
