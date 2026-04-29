import Foundation

/// Pure event-to-Notion transformation logic. No EventKit imports — operates on
/// `EventLike`. Tested independently in `CalendarEventMapperTests`.
enum CalendarEventMapper {

    // MARK: - Calendars / formatters

    private static let londonTimeZone = TimeZone(identifier: "Europe/London")!

    private static let londonDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = londonTimeZone
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static var londonCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = londonTimeZone
        return c
    }()

    // MARK: - Composite Apple Event ID

    /// The upsert key for non-master rows. Non-recurring events use the bare
    /// external ID. Recurring occurrences append the start date in
    /// Europe/London so a 23:30 BST meeting doesn't get tagged with tomorrow's
    /// UTC date.
    static func compositeAppleID(for event: EventLike) -> String {
        let base = event.externalIdentifier
        guard event.eventIsRecurring else { return base }
        let dateStr = londonDayFormatter.string(from: event.eventStart)
        return "\(base)_\(dateStr)"
    }

    // MARK: - Status

    /// Maps EKEventAvailability raw values onto the Notion select options
    /// added by migration #003. Anything unexpected becomes "Unknown" so the
    /// upsert never fails on a value Notion hasn't seen.
    ///
    /// Apple's Exchange bridge often returns `.notSupported` (rawValue 0) even
    /// for events that are *clearly* OOO at the Exchange end (verified
    /// 2026-04-29 against an "Annual Leave" all-day block). When we get
    /// `.notSupported`, fall back to a title heuristic before giving up.
    static func availabilityName(for event: EventLike) -> String {
        switch event.availabilityRawValue {
        case 1: return "Busy"
        case 2: return "Free"
        case 3: return "Tentative"
        case 4: return "OOO"
        default:
            return looksLikeOOO(title: event.eventTitle) ? "OOO" : "Unknown"
        }
    }

    /// Title-based heuristic for OOO/leave entries. Used only when
    /// EKEventAvailability is `.notSupported` — Apple's Exchange bridge swallows
    /// the OOO bit on some setups, so this is the rescue path.
    private static let oooTitlePatterns: [String] = [
        "annual leave",
        "out of office",
        "out-of-office",
        "ooo",
        "on leave",
        "pto",
        "vacation",
        "holiday",
        "sick leave",
        "off work",
        "off sick",
    ]

    static func looksLikeOOO(title: String) -> Bool {
        let lower = title.lowercased()
        for pattern in oooTitlePatterns {
            if lower.range(of: pattern) != nil { return true }
        }
        return false
    }

    static func derivedStatus(for event: EventLike, now: Date) -> String {
        if event.statusRawValue == 3 { return "Cancelled" }
        if londonCalendar.isDate(event.eventStart, inSameDayAs: now) { return "Today" }
        if event.eventStart > now { return "Upcoming" }
        return "Past"
    }

    // MARK: - Attendees

    static func attendeesString(for event: EventLike) -> String {
        let organiser = event.organizerEmail
        let parts: [String] = event.attendeesList.compactMap { att in
            if let organiser, att.email == organiser { return nil }
            if let name = att.name, !name.isEmpty {
                return "\(name) <\(att.email)>"
            } else {
                return "<\(att.email)>"
            }
        }
        let joined = parts.joined(separator: " | ")
        return truncate(joined, toCharCount: 1900)
    }

    static func attendeeCount(for event: EventLike) -> Int {
        let organiser = event.organizerEmail
        return event.attendeesList.filter { att in
            if let organiser, att.email == organiser { return false }
            return true
        }.count
    }

    static func hasExternalAttendees(for event: EventLike) -> Bool {
        let organiser = event.organizerEmail
        for att in event.attendeesList {
            if let organiser, att.email == organiser { continue }
            let domain = att.email.split(separator: "@").last.map { String($0) } ?? ""
            if domain.lowercased() != CalendarSyncConstants.internalDomain.lowercased() {
                return true
            }
        }
        return false
    }

    // MARK: - Conference URL

    private static let conferenceRegex: NSRegularExpression = {
        // Match common conference URLs. Stop at whitespace, closing paren/bracket, or quote.
        let pattern = #"https?://[^\s)>"']*(teams\.microsoft\.com|zoom\.us|meet\.google\.com|webex\.com)[^\s)>"']*"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func extractConferenceURL(from event: EventLike) -> String? {
        for source in [event.locationString, event.notesString] {
            guard let s = source, !s.isEmpty else { continue }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            if let m = conferenceRegex.firstMatch(in: s, options: [], range: range),
               let r = Range(m.range, in: s) {
                return String(s[r])
            }
        }
        return nil
    }

    // MARK: - Truncation

    static func truncate(_ s: String, toCharCount limit: Int) -> String {
        guard s.count > limit else { return s }
        let prefix = String(s.prefix(limit - 1))
        // Try to cut at the last pipe boundary so we don't slice through a
        // "Name <email>" pair mid-string.
        if let lastPipe = prefix.range(of: " | ", options: .backwards) {
            return String(prefix[..<lastPipe.lowerBound]) + "…"
        }
        return prefix + "…"
    }

    // MARK: - Series expansion

    /// Filter out cancelled occurrences, then for each recurring series emit
    /// one synthetic series-master row followed by every occurrence in window.
    /// Non-recurring events pass through unchanged.
    static func expandToRows(events: [EventLike], now: Date) -> [(event: EventLike, isSeriesMaster: Bool)] {
        var nonRecurring: [EventLike] = []
        var bySeries: [String: [EventLike]] = [:]
        var seriesOrder: [String] = []

        for ev in events where ev.statusRawValue != 3 {
            if ev.eventIsRecurring {
                let key = ev.externalIdentifier
                if bySeries[key] == nil {
                    bySeries[key] = []
                    seriesOrder.append(key)
                }
                bySeries[key]!.append(ev)
            } else {
                nonRecurring.append(ev)
            }
        }

        var rows: [(EventLike, Bool)] = []
        rows.reserveCapacity(events.count + seriesOrder.count)

        for ev in nonRecurring {
            rows.append((ev, false))
        }

        for key in seriesOrder {
            let occurrences = bySeries[key]!.sorted { $0.eventStart < $1.eventStart }
            guard let first = occurrences.first else { continue }
            rows.append((SyntheticSeriesMasterEvent(source: first), true))
            for occ in occurrences {
                rows.append((occ, false))
            }
        }
        return rows
    }

    // MARK: - Properties

    /// Compose the Notion `properties` dict for a single row.
    ///
    /// `sourceCalendarName` is the user-visible name to write for both the
    /// legacy `Calendar` select and the new `Source Calendar` select (added by
    /// migration #002). The orchestrator passes `"Calendar (Exchange)"` for the
    /// Exchange-backed calendar (preserving v1 behaviour) and the EKCalendar
    /// title for any other opted-in calendar.
    static func buildProperties(for event: EventLike,
                                now: Date,
                                isSeriesMaster: Bool,
                                sourceCalendarName: String) -> [String: Any] {
        let appleID = isSeriesMaster ? event.externalIdentifier : compositeAppleID(for: event)
        let conferenceURL = extractConferenceURL(from: event)
        let calendarName = sourceCalendarName.isEmpty
            ? CalendarSyncConstants.calendarPropertyValue
            : sourceCalendarName

        return [
            "Title": PropertyBuilder.title(event.eventTitle),
            "Date": PropertyBuilder.date(start: event.eventStart,
                                         end: event.eventEnd,
                                         allDay: event.eventIsAllDay),
            "All Day": PropertyBuilder.checkbox(event.eventIsAllDay),
            "Status": PropertyBuilder.selectByName(derivedStatus(for: event, now: now)),
            "Availability": PropertyBuilder.selectByName(availabilityName(for: event)),
            "Calendar": PropertyBuilder.selectByName(calendarName),
            "Source Calendar": PropertyBuilder.selectByName(calendarName),
            "Organiser": PropertyBuilder.richText(event.organizerName ?? ""),
            "Attendees": PropertyBuilder.richText(attendeesString(for: event)),
            "Attendee Count": PropertyBuilder.number(attendeeCount(for: event)),
            "Has External Attendees": PropertyBuilder.checkbox(hasExternalAttendees(for: event)),
            "Location": PropertyBuilder.richText(event.locationString ?? ""),
            "Conference URL": PropertyBuilder.url(conferenceURL),
            "Description": PropertyBuilder.richText(event.notesString ?? ""),
            "Recurring": PropertyBuilder.checkbox(event.eventIsRecurring),
            "Series Master": PropertyBuilder.checkbox(isSeriesMaster),
            "Apple Event ID": PropertyBuilder.richText(appleID),
            "iCal UID": PropertyBuilder.richText(event.externalIdentifier),
            "Last Synced": PropertyBuilder.dateNow(),
        ]
    }
}

// MARK: - Notion property builders

/// Mechanical converters from Swift values to Notion API property values.
enum PropertyBuilder {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let allDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        return f
    }()

    /// Notion's 2000-char limit on `rich_text` and `title` content is measured
    /// in UTF-16 code units, not Swift `Character`s. A string of 2000 graphemes
    /// can encode to >2000 code units when emoji or combining marks are
    /// present. We truncate to 1990 UTF-16 units at a Character boundary to
    /// leave a small safety margin.
    static func limitedToNotionContent(_ s: String) -> String {
        let limit = 1990
        if s.utf16.count <= limit { return s }
        var result = ""
        var count = 0
        for ch in s {
            let units = ch.utf16.count
            if count + units > limit { break }
            result.append(ch)
            count += units
        }
        return result
    }

    static func title(_ s: String) -> [String: Any] {
        ["title": [["text": ["content": limitedToNotionContent(s)]]]]
    }

    static func richText(_ s: String) -> [String: Any] {
        ["rich_text": [["text": ["content": limitedToNotionContent(s)]]]]
    }

    static func date(start: Date, end: Date, allDay: Bool) -> [String: Any] {
        // For all-day events, Notion expects YYYY-MM-DD with no time component.
        // For timed events, an ISO8601 datetime with offset.
        let s = allDay ? allDayFormatter.string(from: start) : isoFormatter.string(from: start)
        let e = allDay ? allDayFormatter.string(from: end)   : isoFormatter.string(from: end)
        return ["date": ["start": s, "end": e]]
    }

    static func checkbox(_ b: Bool) -> [String: Any] { ["checkbox": b] }
    static func selectByName(_ name: String) -> [String: Any] { ["select": ["name": name]] }
    static func number(_ n: Int) -> [String: Any] { ["number": n] }
    static func url(_ u: String?) -> [String: Any] {
        if let u, !u.isEmpty { return ["url": u] }
        return ["url": NSNull()]
    }
    static func dateNow() -> [String: Any] {
        ["date": ["start": isoFormatter.string(from: Date())]]
    }
}
