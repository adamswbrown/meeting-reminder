import Foundation

struct PendingBooking: Decodable {
    let id: String
    let startUTC: Date
    let endUTC: Date
    let status: String
    let bookerName: String
    let bookerEmail: String
    let eventTypeID: String?
    let ekEventID: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case startUTC = "start_utc"
        case endUTC = "end_utc"
        case bookerName = "booker_name"
        case bookerEmail = "booker_email"
        case eventTypeID = "event_type_id"
        case ekEventID = "ek_event_id"
    }

    static func decodeList(_ data: Data) throws -> [PendingBooking] {
        let dec = JSONDecoder()
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()
        noFrac.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = withFrac.date(from: s) ?? noFrac.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad date \(s)"))
        }
        return try dec.decode([PendingBooking].self, from: data)
    }
}

// MARK: - B2: Conflict-overlap helper

enum BookingConflict {
    /// True if `range` intersects any (start,end) in `events`. Adjacent (touching)
    /// intervals do NOT count as overlap — an event that ends exactly at
    /// `range.start`, or starts exactly at `range.end`, is allowed.
    static func overlaps(range: DateInterval, events: [(Date, Date)]) -> Bool {
        for (start, end) in events {
            let other = DateInterval(start: start, end: max(start, end))
            // DateInterval.intersects treats touching endpoints as intersecting.
            // Exclude the zero-length boundary touch so back-to-back meetings are OK.
            if other.end <= range.start || other.start >= range.end { continue }
            if range.intersects(other) { return true }
        }
        return false
    }
}

// MARK: - B3: ICS invite builder

enum BookingICS {
    /// RFC-5545 VEVENT (CRLF line endings) for a confirmed booking, sent as an
    /// invite (METHOD:REQUEST) the attendee can accept. Mirrors the web builder
    /// at availability-page/lib/booking.ts `buildICSContent` for format consistency.
    static func build(title: String, start: Date, end: Date,
                      organizerEmail: String, attendeeEmail: String,
                      description: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"

        let startICS = fmt.string(from: start)
        let endICS = fmt.string(from: end)
        // DTSTAMP derived from start (not Date()) so output is deterministic/testable.
        let stampICS = startICS

        // Stable UID derived from start+end+attendee.
        let uid = "booking-\(startICS)-\(endICS)-\(attendeeEmail)@adam-booking"

        func esc(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: "\r\n", with: "\\n")
                .replacingOccurrences(of: "\n", with: "\\n")
        }

        let organizerCN = organizerEmail.split(separator: "@").first.map(String.init) ?? organizerEmail

        let lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Adam Brown Booking//EN",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTAMP:\(stampICS)",
            "DTSTART:\(startICS)",
            "DTEND:\(endICS)",
            "SUMMARY:\(esc(title))",
            "DESCRIPTION:\(esc(description))",
            "ORGANIZER;CN=\(esc(organizerCN)):MAILTO:\(organizerEmail)",
            "ATTENDEE;RSVP=TRUE:MAILTO:\(attendeeEmail)",
            "STATUS:CONFIRMED",
            "END:VEVENT",
            "END:VCALENDAR",
        ]
        return lines.joined(separator: "\r\n")
    }
}
