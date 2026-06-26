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
    /// Raw intake answers keyed by question id. Tolerantly decoded so a
    /// non-string value can never fail the whole list decode.
    let answersRaw: BookingAnswerMap?

    /// The intake answers as a plain `[id: value]` map (empty if none).
    var answers: [String: String] { answersRaw?.values ?? [:] }

    enum CodingKeys: String, CodingKey {
        case id, status
        case startUTC = "start_utc"
        case endUTC = "end_utc"
        case bookerName = "booker_name"
        case bookerEmail = "booker_email"
        case eventTypeID = "event_type_id"
        case ekEventID = "ek_event_id"
        case answersRaw = "answers"
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

// MARK: - Intake answers

/// Tolerant decoder for the `answers` JSONB blob. The booking form only ever
/// emits string answers, but scalar JSON values (bool/number) are coerced to
/// String and nulls / nested objects ignored, so decode never throws on an
/// unexpected shape.
struct BookingAnswerMap: Decodable {
    let values: [String: String]

    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(values: [String: String]) { self.values = values }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var out: [String: String] = [:]
        for key in c.allKeys {
            if let s = try? c.decode(String.self, forKey: key) {
                out[key.stringValue] = s
            } else if let b = try? c.decode(Bool.self, forKey: key) {
                out[key.stringValue] = b ? "true" : "false"
            } else if let i = try? c.decode(Int.self, forKey: key) {
                out[key.stringValue] = String(i)
            } else if let d = try? c.decode(Double.self, forKey: key) {
                out[key.stringValue] = String(d)
            }
            // null / arrays / nested objects are intentionally dropped.
        }
        values = out
    }
}

/// One intake question definition, mirrors `booking_event_types.questions`.
struct BookingQuestionDef: Decodable {
    let id: String
    let label: String
    let required: Bool
}

enum BookingAnswers {
    /// Ordered "Label: value" lines for the non-empty answers. Questions drive
    /// the order and supply human labels; an answer whose id has no matching
    /// question falls back to the raw id as its label and sorts after the known
    /// ones. Blank/whitespace-only answers are skipped.
    static func format(answers: [String: String], questions: [BookingQuestionDef]) -> [String] {
        var lines: [String] = []
        var seen = Set<String>()
        for q in questions {
            seen.insert(q.id)
            let v = (answers[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { lines.append("\(q.label): \(v)") }
        }
        for (k, v) in answers.sorted(by: { $0.key < $1.key }) where !seen.contains(k) {
            let val = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty { lines.append("\(k): \(val)") }
        }
        return lines
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
            // Touching endpoints don't count: an event that ends exactly at
            // range.start, or starts exactly at range.end, is allowed so
            // back-to-back meetings are OK. Anything that survives this guard
            // genuinely overlaps.
            if other.end <= range.start || other.start >= range.end { continue }
            return true
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

// MARK: - B4: Mail.app AppleScript composer

enum MailAppleScript {
    /// Builds an osascript-able AppleScript that composes and sends a mail from a
    /// specific account, with one recipient and an optional .ics attachment,
    /// without showing the compose window. Pass `icsPath: nil` for emails that
    /// carry no attachment (e.g. rejections). Pure string builder — executes nothing.
    ///
    /// `senderEmail` is the address that MUST belong to an **enabled** Mail
    /// account for the send to proceed; the generated script `error`s (non-zero
    /// osascript exit) if no enabled account owns it. This is the guard that
    /// stops Mail silently falling back to another account (e.g. iCloud) when the
    /// intended Exchange account is disabled — booking mail only ever leaves from
    /// the Exchange address or not at all.
    static func compose(senderDisplay: String, senderEmail: String, to: String, subject: String,
                        body: String, icsPath: String?) -> String {
        // Escape backslash first, then double-quote, so generated AppleScript
        // string literals stay syntactically valid. This does NOT touch newlines —
        // AppleScript does not interpret `\n` inside a double-quoted string, so
        // multiline bodies are handled separately by escBody below.
        func esc(_ s: String) -> String {
            s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        // Body may be multiline. Split on newline and join the escaped pieces with
        // the AppleScript `linefeed` constant so the generated script concatenates
        // string literals separated by real linefeeds (e.g.
        // `"Hi Sam," & linefeed & "" & linefeed & "You're booked."`). Each piece is
        // escaped individually, preserving the backslash-then-quote order.
        func escBody(_ s: String) -> String {
            let normalised = s.replacingOccurrences(of: "\r\n", with: "\n")
            return normalised
                .components(separatedBy: "\n")
                .map(esc)
                .joined(separator: "\" & linefeed & \"")
        }

        let sender = esc(senderDisplay)
        let senderAddr = esc(senderEmail)
        let recipient = esc(to)
        let subj = esc(subject)
        let bodyEsc = escBody(body)

        var lines = [
            "tell application \"Mail\"",
            // Guard: refuse to send unless an ENABLED account owns the sender
            // address. Without this, Mail silently uses the default account.
            "\tset okAccount to false",
            "\trepeat with anAccount in accounts",
            "\t\tif (enabled of anAccount is true) and ((email addresses of anAccount) contains \"\(senderAddr)\") then set okAccount to true",
            "\tend repeat",
            "\tif okAccount is false then error \"Sender account \(senderAddr) is not enabled in Mail — refusing to send from another account\"",
            "\tset newMessage to make new outgoing message with properties {subject:\"\(subj)\", content:\"\(bodyEsc)\", visible:false}",
            "\ttell newMessage",
            "\t\tset sender to \"\(sender)\"",
            "\t\tmake new to recipient at end of to recipients with properties {address:\"\(recipient)\"}",
        ]
        if let icsPath {
            let path = esc(icsPath)
            lines.append("\t\tmake new attachment with properties {file name:(POSIX file \"\(path)\")} at after the last paragraph")
        }
        lines.append(contentsOf: [
            "\tend tell",
            "\tsend newMessage",
            "end tell",
        ])
        return lines.joined(separator: "\n")
    }
}
