import Foundation

/// Teams/Graph enrichment written onto a meeting's Calendar Events row by the
/// local `teams-chat-mcp` feeder — `Teams Meeting`, `RSVP Summary`, `My Status`.
/// `Teams Chat Context` exists on the same row but isn't surfaced here; it's
/// prose meant for the cloud briefing, not a quick glance.
struct CalendarRowEnrichment {
    let isTeamsMeeting: Bool
    let rsvpSummary: String?
    let myStatus: String?

    var isEmpty: Bool {
        !isTeamsMeeting && rsvpSummary == nil && myStatus == nil
    }
}

/// Fetches `CalendarRowEnrichment` for a `MeetingEvent` by its exact Calendar
/// Events row, keyed on `Apple Event ID`. Reuses the Notion integration token
/// stored in Keychain by `NotionService` — no new credentials.
///
/// Unlike `PreCallBriefService`'s fuzzy title+date matching (Pre-Call
/// Briefings has no stable key back to a calendar event), Calendar Events rows
/// carry the exact same composite ID the Mac app itself writes on sync
/// (`CalendarEventMapper.compositeAppleID`), so this is an exact lookup.
final class CalendarEnrichmentService {
    private let tokenKey = "notionAPIToken"

    private var apiToken: String? {
        KeychainHelper.read(key: tokenKey)
    }

    var isConfigured: Bool {
        apiToken != nil
    }

    /// Mirrors `CalendarEventMapper.compositeAppleID`: non-recurring events use
    /// the bare external ID; recurring occurrences append the start date in
    /// Europe/London so a 23:30 BST meeting doesn't get tagged with tomorrow's
    /// UTC date. Duplicated rather than shared because `CalendarEventMapper`
    /// operates on `EventLike`, not `MeetingEvent` — keeping this small and
    /// pure avoids pulling the sync service's EventKit-adapter machinery into
    /// the UI layer for one formula.
    private static let londonTimeZone = TimeZone(identifier: "Europe/London")!
    private static let londonDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = londonTimeZone
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        return f
    }()

    private func compositeAppleID(for event: MeetingEvent) -> String? {
        guard let base = event.externalID, !base.isEmpty else { return nil }
        guard event.isRecurring else { return base }
        return "\(base)_\(Self.londonDayFormatter.string(from: event.startDate))"
    }

    func fetchEnrichment(for event: MeetingEvent) async -> CalendarRowEnrichment? {
        guard let token = apiToken, let appleID = compositeAppleID(for: event) else { return nil }
        guard let url = URL(
            string: "https://api.notion.com/v1/data_sources/\(CalendarSyncConstants.calendarEventsDataSourceID)/query"
        ) else { return nil }

        let body: [String: Any] = [
            "filter": [
                "property": "Apple Event ID",
                "rich_text": ["equals": appleID],
            ],
            "page_size": 1,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue(CalendarSyncConstants.notionVersion, forHTTPHeaderField: "Notion-Version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let row = results.first,
                  let props = row["properties"] as? [String: Any] else {
                return nil
            }
            return CalendarRowEnrichment(
                isTeamsMeeting: Self.checkboxValue(props["Teams Meeting"]),
                rsvpSummary: Self.richTextValue(props["RSVP Summary"]),
                myStatus: Self.richTextValue(props["My Status"])
            )
        } catch {
            return nil
        }
    }

    private static func checkboxValue(_ any: Any?) -> Bool {
        (any as? [String: Any])?["checkbox"] as? Bool ?? false
    }

    private static func richTextValue(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let items = dict["rich_text"] as? [[String: Any]] else { return nil }
        let joined = items.compactMap { $0["plain_text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }
}
