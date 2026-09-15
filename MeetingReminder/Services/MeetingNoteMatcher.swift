import Foundation

/// Pure lookup logic for finding an existing Notion *Meeting Notes* row that
/// belongs to a calendar event, plus the Calendar Events row it should be
/// related to.
///
/// Deliberately free of `URLSession` and EventKit so the matching rules —
/// which are the part that can silently go wrong — are unit-testable. The
/// caller (`NotionService`) supplies the transport.
///
/// The matching rule mirrors `RelationLinker`: query Notion server-side with a
/// permissive `title contains` + single-day date bracket, then tighten locally
/// to exact case-insensitive title equality. Sharing the rule matters — if the
/// panel's idea of "this meeting's note" drifted from the sync's, the two
/// would fight over the same relation.
enum MeetingNoteMatcher {

    // MARK: - Calendar

    private static let londonTimeZone = TimeZone(identifier: "Europe/London")!

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = londonTimeZone
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        return f
    }()

    /// The event's calendar day in Europe/London. Using London rather than UTC
    /// keeps a 00:30 BST meeting on its own day instead of yesterday's.
    static func dayString(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Rebuilds the composite key the Calendar → Notion sync writes into the
    /// `Apple Event ID` column: bare external ID for a one-off, and
    /// `<id>_<YYYY-MM-DD>` for a recurring occurrence.
    ///
    /// Mirrors `CalendarEventMapper.compositeAppleID`, which takes an
    /// `EventLike`; this variant takes the loose fields so a `MeetingEvent`
    /// can be matched without an EventKit round-trip.
    static func appleEventID(externalID: String, isRecurring: Bool, start: Date) -> String {
        guard isRecurring else { return externalID }
        return "\(externalID)_\(dayString(for: start))"
    }

    // MARK: - Candidates

    /// One row returned by a title+day query.
    struct Candidate: Equatable {
        let pageID: String
        let title: String
        let url: URL
    }

    /// Outcome of tightening a candidate list to exact title equality.
    enum Resolution: Equatable {
        /// No row for this meeting — the caller may offer to create one.
        case none
        /// Exactly one row; safe to open.
        case unique(Candidate)
        /// Several rows share the title on the same day. Refuse to guess and
        /// report the page IDs so the ambiguity is visible rather than silent.
        case ambiguous([String])
    }

    /// Filters `candidates` down to exact case-insensitive title equality.
    ///
    /// The server-side `contains` filter is too permissive on its own: the
    /// needle "Sync" matches "Sync with Bob". Without this step the panel
    /// would happily open another meeting's notes.
    static func resolve(candidates: [Candidate], title: String) -> Resolution {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .none }

        let exact = candidates.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(needle) == .orderedSame
        }

        switch exact.count {
        case 0: return .none
        case 1: return .unique(exact[0])
        default: return .ambiguous(exact.map(\.pageID))
        }
    }

    // MARK: - Query bodies

    /// Body for a `POST /data_sources/{id}/query` that brackets one calendar
    /// day and filters titles loosely. Pass `cursor` to continue a paged read.
    static func titleDayQueryBody(titleProperty: String,
                                  dateProperty: String,
                                  titleNeedle: String,
                                  day: String,
                                  cursor: String?) -> [String: Any] {
        var body: [String: Any] = [
            "page_size": 100,
            "filter": [
                "and": [
                    ["property": titleProperty,
                     "title": ["contains": titleNeedle]],
                    ["property": dateProperty,
                     "date": ["on_or_after": day]],
                    ["property": dateProperty,
                     "date": ["on_or_before": day]],
                ]
            ],
        ]
        if let cursor { body["start_cursor"] = cursor }
        return body
    }

    /// Body for looking up the Calendar Events row by its composite Apple
    /// Event ID. Exact equality — this column is a synthetic key, not prose.
    static func appleEventIDQueryBody(property: String, value: String) -> [String: Any] {
        [
            "page_size": 1,
            "filter": [
                "property": property,
                "rich_text": ["equals": value],
            ],
        ]
    }

    // MARK: - Response parsing

    /// Pulls candidates out of a Notion query response. Rows missing an ID or
    /// a title are skipped rather than failing the whole lookup.
    static func candidates(from response: [String: Any],
                           titleProperty: String) -> [Candidate] {
        let results = response["results"] as? [[String: Any]] ?? []
        return results.compactMap { row in
            guard let id = row["id"] as? String,
                  let props = row["properties"] as? [String: Any],
                  let title = plainTitle(props[titleProperty]),
                  !title.isEmpty else { return nil }
            let url = (row["url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://notion.so/\(id.replacingOccurrences(of: "-", with: ""))")!
            return Candidate(pageID: id, title: title, url: url)
        }
    }

    /// Cursor for the next page, or nil when the read is complete.
    static func nextCursor(from response: [String: Any]) -> String? {
        guard (response["has_more"] as? Bool) == true else { return nil }
        return response["next_cursor"] as? String
    }

    /// First row's page ID, for the single-result Apple Event ID lookup.
    static func firstPageID(from response: [String: Any]) -> String? {
        (response["results"] as? [[String: Any]])?.first?["id"] as? String
    }

    /// Page IDs held in a relation property on the first returned row.
    ///
    /// This is the authoritative way to find a meeting's note: the relation
    /// points at a page ID, so it keeps working after the note is renamed —
    /// which title matching cannot. Empty means either no such row or a row
    /// with nothing linked; both mean "fall through to the next strategy".
    static func relationPageIDs(from response: [String: Any], property: String) -> [String] {
        guard let row = (response["results"] as? [[String: Any]])?.first,
              let props = row["properties"] as? [String: Any],
              let relation = (props[property] as? [String: Any])?["relation"] as? [[String: Any]]
        else { return [] }
        return relation.compactMap { $0["id"] as? String }
    }

    /// Canonical web URL for a page ID. Notion accepts the dashless form and
    /// redirects to the slugged URL, so this avoids a round-trip just to read
    /// back a page's `url`.
    static func pageURL(forPageID pageID: String) -> URL {
        let bare = pageID.replacingOccurrences(of: "-", with: "")
        return URL(string: "https://www.notion.so/\(bare)")!
    }

    private static func plainTitle(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let arr = dict["title"] as? [[String: Any]] else { return nil }
        return arr.compactMap { $0["plain_text"] as? String }.joined()
    }
}
