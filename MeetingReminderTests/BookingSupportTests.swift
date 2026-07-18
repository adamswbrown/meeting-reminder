import XCTest
@testable import MeetingReminder

final class BookingSupportTests: XCTestCase {
    func testDecodePendingBooking() throws {
        let json = """
        [{"id":"abc","start_utc":"2026-07-01T10:00:00+00:00","end_utc":"2026-07-01T10:30:00+00:00",
          "status":"pending","booker_name":"Sam","booker_email":"sam@example.com",
          "answers":{},"event_type_id":"et1","ek_event_id":null}]
        """.data(using: .utf8)!
        let rows = try PendingBooking.decodeList(json)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bookerName, "Sam")
        XCTAssertEqual(rows[0].id, "abc")
        XCTAssertNil(rows[0].ekEventID)
    }

    func testDecodePendingBookingFractionalSeconds() throws {
        let json = """
        [{"id":"def","start_utc":"2026-07-01T10:00:00.000+00:00","end_utc":"2026-07-01T10:30:00.000+00:00",
          "status":"pending","booker_name":"Lee","booker_email":"lee@example.com",
          "answers":{},"event_type_id":"et2","ek_event_id":null}]
        """.data(using: .utf8)!
        let rows = try PendingBooking.decodeList(json)
        XCTAssertEqual(rows.count, 1)
        let expected = ISO8601DateFormatter().date(from: "2026-07-01T10:00:00Z")
        XCTAssertNotNil(expected)
        XCTAssertEqual(rows[0].startUTC, expected)
    }

    // MARK: - Intake answers: decode

    func testDecodePendingBookingWithAnswers() throws {
        let json = """
        [{"id":"abc","start_utc":"2026-07-01T10:00:00+00:00","end_utc":"2026-07-01T10:30:00+00:00",
          "status":"pending","booker_name":"Sam","booker_email":"sam@example.com",
          "answers":{"customer":"Hays","cover":"Scan review"},"event_type_id":"et1","ek_event_id":null}]
        """.data(using: .utf8)!
        let rows = try PendingBooking.decodeList(json)
        XCTAssertEqual(rows[0].answers["customer"], "Hays")
        XCTAssertEqual(rows[0].answers["cover"], "Scan review")
    }

    func testDecodePendingBookingEmptyAnswers() throws {
        let json = """
        [{"id":"abc","start_utc":"2026-07-01T10:00:00+00:00","end_utc":"2026-07-01T10:30:00+00:00",
          "status":"pending","booker_name":"Sam","booker_email":"sam@example.com",
          "answers":{},"event_type_id":"et1","ek_event_id":null}]
        """.data(using: .utf8)!
        let rows = try PendingBooking.decodeList(json)
        XCTAssertTrue(rows[0].answers.isEmpty)
    }

    func testDecodePendingBookingNonStringAnswerCoerced() throws {
        // A non-string scalar must not fail the whole decode — it's coerced.
        let json = """
        [{"id":"abc","start_utc":"2026-07-01T10:00:00+00:00","end_utc":"2026-07-01T10:30:00+00:00",
          "status":"pending","booker_name":"Sam","booker_email":"sam@example.com",
          "answers":{"customer":"Hays","urgent":true,"count":3},"event_type_id":"et1","ek_event_id":null}]
        """.data(using: .utf8)!
        let rows = try PendingBooking.decodeList(json)
        XCTAssertEqual(rows[0].answers["customer"], "Hays")
        XCTAssertEqual(rows[0].answers["urgent"], "true")
        XCTAssertEqual(rows[0].answers["count"], "3")
    }

    // MARK: - Intake answers: format

    private let sampleQuestions = [
        BookingQuestionDef(id: "customer", label: "Which customer or company is this call about?", required: true),
        BookingQuestionDef(id: "cover", label: "What would you like to cover?", required: false),
        BookingQuestionDef(id: "role", label: "Your role and organisation", required: false),
    ]

    func testFormatAnswersOrderedByQuestions() {
        let lines = BookingAnswers.format(
            answers: ["cover": "Scan review", "customer": "Hays"],
            questions: sampleQuestions
        )
        // Order follows the question list, not the dictionary.
        XCTAssertEqual(lines, [
            "Which customer or company is this call about?: Hays",
            "What would you like to cover?: Scan review",
        ])
    }

    func testFormatSkipsBlankAndWhitespaceAnswers() {
        let lines = BookingAnswers.format(
            answers: ["customer": "Hays", "cover": "   ", "role": ""],
            questions: sampleQuestions
        )
        XCTAssertEqual(lines, ["Which customer or company is this call about?: Hays"])
    }

    func testFormatUnknownAnswerKeyFallsBackToRawKeyAndSortsLast() {
        let lines = BookingAnswers.format(
            answers: ["customer": "Hays", "zzz_extra": "leftover"],
            questions: sampleQuestions
        )
        XCTAssertEqual(lines, [
            "Which customer or company is this call about?: Hays",
            "zzz_extra: leftover",
        ])
    }

    func testFormatEmptyWhenNoAnswers() {
        XCTAssertTrue(BookingAnswers.format(answers: [:], questions: sampleQuestions).isEmpty)
    }

    // MARK: - BookingEventType decode (questions optional/default)

    func testEventTypeDecodesQuestions() throws {
        let json = """
        [{"slug":"intro-30","title":"30-min intro","duration_min":30,"buffer_before":0,"buffer_after":10,
          "questions":[{"id":"customer","label":"Which customer?","required":true}]}]
        """.data(using: .utf8)!
        let list = try JSONDecoder().decode([BookingEventType].self, from: json)
        XCTAssertEqual(list[0].questions.count, 1)
        XCTAssertEqual(list[0].questions[0].id, "customer")
        XCTAssertTrue(list[0].questions[0].required)
    }

    func testEventTypeMissingQuestionsDefaultsEmpty() throws {
        let json = """
        [{"slug":"intro-30","title":"30-min intro","duration_min":30,"buffer_before":0,"buffer_after":10}]
        """.data(using: .utf8)!
        let list = try JSONDecoder().decode([BookingEventType].self, from: json)
        XCTAssertTrue(list[0].questions.isEmpty)
    }

    // MARK: - B2: BookingConflict.overlaps

    private func d(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: s)!
    }

    func testOverlapWithinRange() {
        let range = DateInterval(start: d("2026-07-01T10:00:00Z"), end: d("2026-07-01T11:00:00Z"))
        let events = [(d("2026-07-01T10:30:00Z"), d("2026-07-01T10:45:00Z"))]
        XCTAssertTrue(BookingConflict.overlaps(range: range, events: events))
    }

    func testAdjacentAfterIsNotOverlap() {
        let range = DateInterval(start: d("2026-07-01T10:00:00Z"), end: d("2026-07-01T11:00:00Z"))
        let events = [(d("2026-07-01T11:00:00Z"), d("2026-07-01T12:00:00Z"))]
        XCTAssertFalse(BookingConflict.overlaps(range: range, events: events))
    }

    func testAdjacentBeforeIsNotOverlap() {
        let range = DateInterval(start: d("2026-07-01T10:00:00Z"), end: d("2026-07-01T11:00:00Z"))
        let events = [(d("2026-07-01T09:00:00Z"), d("2026-07-01T10:00:00Z"))]
        XCTAssertFalse(BookingConflict.overlaps(range: range, events: events))
    }

    func testDisjointIsNotOverlap() {
        let range = DateInterval(start: d("2026-07-01T10:00:00Z"), end: d("2026-07-01T11:00:00Z"))
        let events = [(d("2026-07-01T09:00:00Z"), d("2026-07-01T09:30:00Z"))]
        XCTAssertFalse(BookingConflict.overlaps(range: range, events: events))
    }

    func testEmptyEventsIsNotOverlap() {
        let range = DateInterval(start: d("2026-07-01T10:00:00Z"), end: d("2026-07-01T11:00:00Z"))
        XCTAssertFalse(BookingConflict.overlaps(range: range, events: []))
    }

    // MARK: - B3: BookingICS.build

    private func sampleICS(title: String = "Intro call", description: String = "A chat") -> String {
        BookingICS.build(
            title: title,
            start: d("2026-07-01T10:00:00Z"),
            end: d("2026-07-01T10:30:00Z"),
            organizerEmail: "adam@askadam.cloud",
            attendeeEmail: "sam@example.com",
            description: description
        )
    }

    func testICSContainsCoreLines() {
        let ics = sampleICS()
        XCTAssertTrue(ics.contains("BEGIN:VEVENT"))
        XCTAssertTrue(ics.contains("METHOD:REQUEST"))
        XCTAssertTrue(ics.contains("STATUS:CONFIRMED"))
    }

    func testICSDTSTARTBasicUTC() {
        let ics = sampleICS()
        XCTAssertTrue(ics.contains("DTSTART:20260701T100000Z"), ics)
        XCTAssertTrue(ics.contains("DTEND:20260701T103000Z"), ics)
        // DTSTAMP is derived from start for determinism.
        XCTAssertTrue(ics.contains("DTSTAMP:20260701T100000Z"), ics)
    }

    func testICSEscapesCommas() {
        let ics = sampleICS(title: "Intro, with comma", description: "Line one, line two")
        XCTAssertTrue(ics.contains("SUMMARY:Intro\\, with comma"), ics)
        XCTAssertTrue(ics.contains("DESCRIPTION:Line one\\, line two"), ics)
    }

    func testICSUsesCRLF() {
        let ics = sampleICS()
        XCTAssertTrue(ics.contains("\r\n"))
        // No lone \n that isn't preceded by \r.
        let chars = Array(ics)
        for i in chars.indices where chars[i] == "\n" {
            XCTAssertTrue(i > 0 && chars[i - 1] == "\r", "Found a lone \\n at index \(i)")
        }
    }

    func testICSContainsAttendeeMailto() {
        let ics = sampleICS()
        XCTAssertTrue(ics.contains("MAILTO:sam@example.com"), ics)
    }

    // MARK: - B4: MailAppleScript.compose

    private func sampleScript(subject: String = "Your booking is confirmed",
                              body: String = "Hi Sam") -> String {
        MailAppleScript.compose(
            senderDisplay: "Adam Brown <adam.brown@altra.cloud>",
            senderEmail: "adam.brown@altra.cloud",
            to: "sam@example.com",
            subject: subject,
            body: body,
            icsPath: "/tmp/invite.ics"
        )
    }

    func testScriptPinsSender() {
        let s = sampleScript()
        XCTAssertTrue(s.contains("set sender to \"Adam Brown <adam.brown@altra.cloud>\""), s)
    }

    func testScriptContainsRecipientAndPath() {
        let s = sampleScript()
        XCTAssertTrue(s.contains("sam@example.com"), s)
        XCTAssertTrue(s.contains("/tmp/invite.ics"), s)
    }

    func testScriptIsInvisibleAndSends() {
        let s = sampleScript()
        XCTAssertTrue(s.contains("visible:false"), s)
        XCTAssertTrue(s.contains("send"), s)
        XCTAssertTrue(s.hasSuffix("send") || s.contains("send\n") || s.contains("\tsend"), s)
    }

    func testScriptEscapesDoubleQuotes() {
        let s = MailAppleScript.compose(
            senderDisplay: "Adam",
            senderEmail: "adam@example.com",
            to: "sam@example.com",
            subject: "Say \"hello\"",
            body: "Body",
            icsPath: "/tmp/invite.ics"
        )
        XCTAssertTrue(s.contains("Say \\\"hello\\\""), s)
        // The raw, unescaped sequence must not appear in the subject content.
        XCTAssertFalse(s.contains("subject:\"Say \"hello\""), s)
    }

    func testScriptWithAttachmentIncludesAttachmentLine() {
        let s = sampleScript()
        XCTAssertTrue(s.contains("make new attachment"), s)
    }

    func testScriptNilAttachmentOmitsAttachmentLine() {
        let s = MailAppleScript.compose(
            senderDisplay: "Adam",
            senderEmail: "adam@example.com",
            to: "sam@example.com",
            subject: "That slot just filled",
            body: "Hi Sam",
            icsPath: nil
        )
        // No attachment line, but the message is still composed and sent.
        XCTAssertFalse(s.contains("make new attachment"), s)
        XCTAssertTrue(s.contains("make new outgoing message"), s)
        XCTAssertTrue(s.contains("send newMessage"), s)
        XCTAssertTrue(s.contains("sam@example.com"), s)
    }

    func testScriptMultilineBodyUsesLinefeedConcatenation() {
        let s = MailAppleScript.compose(
            senderDisplay: "Adam",
            senderEmail: "adam@example.com",
            to: "sam@example.com",
            subject: "Confirmed",
            body: "Hi Sam,\n\nYou're booked.",
            icsPath: "/tmp/invite.ics"
        )
        // Newlines must become AppleScript `linefeed` concatenation, not literal \n.
        XCTAssertTrue(s.contains("& linefeed &"), s)
        XCTAssertFalse(s.contains("\\n"), s)
    }
}
