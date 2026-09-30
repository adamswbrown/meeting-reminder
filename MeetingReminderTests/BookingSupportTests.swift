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

    private func sampleICS(title: String = "Intro call", description: String = "A chat") throws -> String {
        try BookingICS.build(
            title: title,
            start: d("2026-07-01T10:00:00Z"),
            end: d("2026-07-01T10:30:00Z"),
            organizerEmail: "adam@askadam.cloud",
            attendeeEmail: "sam@example.com",
            description: description
        )
    }

    func testICSContainsCoreLines() throws {
        let ics = try sampleICS()
        XCTAssertTrue(ics.contains("BEGIN:VEVENT"))
        XCTAssertTrue(ics.contains("METHOD:REQUEST"))
        XCTAssertTrue(ics.contains("STATUS:CONFIRMED"))
    }

    func testICSDTSTARTBasicUTC() throws {
        let ics = try sampleICS()
        XCTAssertTrue(ics.contains("DTSTART:20260701T100000Z"), ics)
        XCTAssertTrue(ics.contains("DTEND:20260701T103000Z"), ics)
        // DTSTAMP is derived from start for determinism.
        XCTAssertTrue(ics.contains("DTSTAMP:20260701T100000Z"), ics)
    }

    func testICSEscapesCommas() throws {
        let ics = try sampleICS(title: "Intro, with comma", description: "Line one, line two")
        XCTAssertTrue(ics.contains("SUMMARY:Intro\\, with comma"), ics)
        XCTAssertTrue(ics.contains("DESCRIPTION:Line one\\, line two"), ics)
    }

    func testICSUsesCRLF() throws {
        let ics = try sampleICS()
        XCTAssertTrue(ics.contains("\r\n"))
        // No lone \n that isn't preceded by \r.
        let chars = Array(ics)
        for i in chars.indices where chars[i] == "\n" {
            XCTAssertTrue(i > 0 && chars[i - 1] == "\r", "Found a lone \\n at index \(i)")
        }
    }

    func testICSContainsAttendeeMailto() throws {
        let ics = try sampleICS()
        XCTAssertTrue(ics.contains("MAILTO:sam@example.com"), ics)
    }

    func testICSRejectsInjectedAttendeeEmail() {
        // A newline in the attendee email must throw rather than producing a broken ICS.
        XCTAssertThrowsError(try BookingICS.build(
            title: "Meeting",
            start: d("2026-07-01T10:00:00Z"),
            end: d("2026-07-01T10:30:00Z"),
            organizerEmail: "adam@askadam.cloud",
            attendeeEmail: "evil\r\nBCC:other@example.com",
            description: "desc"
        ))
    }

    // MARK: - B4: MailAppleScript.compose

    private func sampleScript(subject: String = "Your booking is confirmed",
                              body: String = "Hi Sam") throws -> String {
        try MailAppleScript.compose(
            senderDisplay: "Adam Brown <adam.brown@altra.cloud>",
            senderEmail: "adam.brown@altra.cloud",
            to: "sam@example.com",
            subject: subject,
            body: body,
            icsPath: "/tmp/invite.ics"
        )
    }

    func testScriptPinsSender() throws {
        let s = try sampleScript()
        XCTAssertTrue(s.contains("set sender to \"Adam Brown <adam.brown@altra.cloud>\""), s)
    }

    func testScriptContainsRecipientAndPath() throws {
        let s = try sampleScript()
        XCTAssertTrue(s.contains("sam@example.com"), s)
        XCTAssertTrue(s.contains("/tmp/invite.ics"), s)
    }

    func testScriptIsInvisibleAndSends() throws {
        let s = try sampleScript()
        XCTAssertTrue(s.contains("visible:false"), s)
        XCTAssertTrue(s.contains("send"), s)
        XCTAssertTrue(s.hasSuffix("send") || s.contains("send\n") || s.contains("\tsend"), s)
    }

    func testScriptEscapesDoubleQuotes() throws {
        let s = try MailAppleScript.compose(
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

    func testScriptWithAttachmentIncludesAttachmentLine() throws {
        let s = try sampleScript()
        XCTAssertTrue(s.contains("make new attachment"), s)
    }

    func testScriptNilAttachmentOmitsAttachmentLine() throws {
        let s = try MailAppleScript.compose(
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

    func testScriptMultilineBodyUsesLinefeedConcatenation() throws {
        let s = try MailAppleScript.compose(
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

    func testScriptRejectsInjectedRecipientEmail() {
        // A newline in the recipient email must throw rather than injecting an extra
        // AppleScript statement into the generated script.
        XCTAssertThrowsError(try MailAppleScript.compose(
            senderDisplay: "Adam",
            senderEmail: "adam@example.com",
            to: "evil\r\ndo shell script \"rm -rf ~\"",
            subject: "Hi",
            body: "Body",
            icsPath: nil
        ))
    }

    // MARK: - BookingEmailSanitizer

    func testSanitizerAcceptsValidEmail() throws {
        XCTAssertEqual(try BookingEmailSanitizer.sanitize("sam@example.com"), "sam@example.com")
    }

    func testSanitizerStripsAndRejectsCRLF() {
        // A CR or LF anywhere in the address makes it invalid (no @ etc).
        XCTAssertThrowsError(try BookingEmailSanitizer.sanitize("evil\r\nBCC:x@y.com"))
    }

    func testSanitizerRejectsNoAtSign() {
        XCTAssertThrowsError(try BookingEmailSanitizer.sanitize("notanemail"))
    }

    func testSanitizerRejectsEmpty() {
        XCTAssertThrowsError(try BookingEmailSanitizer.sanitize(""))
    }
}

// MARK: - Booking / Cal.com / availability bug sweep

final class BookingSweepTests: XCTestCase {
    func testLegacyPollSupersededOnlyByNonEmptyCalComKey() {
        XCTAssertFalse(BookingPollService.isSupersededByCalCom(calComKey: nil))
        XCTAssertFalse(BookingPollService.isSupersededByCalCom(calComKey: ""))
        XCTAssertTrue(BookingPollService.isSupersededByCalCom(calComKey: "cal_live_x"))
    }

    func testGraphRefreshExpiryCodesAreDead() {
        XCTAssertTrue(GraphMailService.isDeadRefreshToken(error: "invalid_grant", errorCodes: [70008], description: nil))
        XCTAssertTrue(GraphMailService.isDeadRefreshToken(error: "invalid_grant", errorCodes: [50173], description: nil))
        XCTAssertTrue(GraphMailService.isDeadRefreshToken(
            error: "invalid_grant", errorCodes: nil,
            description: "AADSTS700082: The refresh token has expired due to inactivity."))
        // Conditional Access sign-in-frequency expiry.
        XCTAssertTrue(GraphMailService.isDeadRefreshToken(error: "invalid_grant", errorCodes: [70043], description: nil))
    }

    func testGraphInteractionRequiredForcesReconnect() {
        // MFA / Conditional Access interaction can't be satisfied without the
        // user, so it must surface as needsReauth (and notify), not a silent fallback.
        XCTAssertTrue(GraphMailService.isDeadRefreshToken(
            error: "invalid_grant", errorCodes: nil,
            description: "AADSTS50076: Due to a configuration change made by your administrator..."))
        XCTAssertTrue(GraphMailService.isDeadRefreshToken(error: "invalid_grant", errorCodes: [50079], description: nil))
        XCTAssertTrue(GraphMailService.isDeadRefreshToken(error: "interaction_required", errorCodes: [50078], description: nil))
        // An unrecognised or missing code is treated as dead: keeping it would fail every send silently.
        XCTAssertTrue(GraphMailService.isDeadRefreshToken(error: "invalid_grant", errorCodes: nil, description: nil))
        XCTAssertTrue(GraphMailService.isDeadRefreshToken(error: "invalid_grant", errorCodes: [12345], description: nil))
    }

    func testGraphRecoverableInvalidGrantKeepsToken() {
        // consent_required for a new scope: the token still works for Mail.Send.
        XCTAssertFalse(GraphMailService.isDeadRefreshToken(error: "invalid_grant", errorCodes: [65001], description: nil))
        XCTAssertFalse(GraphMailService.isDeadRefreshToken(
            error: "invalid_grant", errorCodes: nil,
            description: "AADSTS65001: The user or administrator has not consented..."))
        // Not an auth failure at all.
        XCTAssertFalse(GraphMailService.isDeadRefreshToken(error: "temporarily_unavailable", errorCodes: [70008], description: nil))
    }

    @MainActor
    func testCalComPaginateWalksPagesUntilShortPage() async throws {
        let source = Array(0..<120)
        var skips: [Int] = []
        let all = try await CalComService.paginate(take: 50) { skip -> [Int] in
            skips.append(skip)
            return Array(source.dropFirst(skip).prefix(50))
        }
        XCTAssertEqual(all, source)
        XCTAssertEqual(skips, [0, 50, 100])
    }

    @MainActor
    func testCalComPaginateStopsAtMaxPagesWhenSkipIgnored() async throws {
        var calls = 0
        let all = try await CalComService.paginate(take: 2, maxPages: 3) { _ -> [Int] in
            calls += 1
            return [1, 2]
        }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(all.count, 6)
    }

    func testAvailabilityPushDropsFreeUnlessOOO() {
        XCTAssertTrue(PushEvent.shouldPush(isFree: false, isOOO: false))
        XCTAssertFalse(PushEvent.shouldPush(isFree: true, isOOO: false))
        // Annual leave marked Free in Outlook still drives the "away" banner.
        XCTAssertTrue(PushEvent.shouldPush(isFree: true, isOOO: true))
    }

    func testAvailabilityInFilterChunksBoundsEachFilter() {
        let ids = (0..<95).map { "EVT-\($0)_2026-09-26T10:00:00Z" }
        let chunks = AvailabilityPushService.inFilterChunks(ids, chunkSize: 40)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks[0].hasPrefix("in.(\"EVT-0_"))
        XCTAssertEqual(chunks[2].components(separatedBy: ",").count, 15)
        XCTAssertTrue(chunks.allSatisfy { $0.count < 4000 })
    }

    func testAvailabilityInFilterChunksQuotesAndHandlesEmpty() {
        XCTAssertEqual(AvailabilityPushService.inFilterChunks([]), [])
        XCTAssertEqual(AvailabilityPushService.inFilterChunks(["a\"b", "c"]), ["in.(\"a\"\"b\",\"c\")"])
    }

    private func exchangeCopy(title: String?, invited: [String], hostOrganises: Bool = true,
                              organizer: String? = "adam@askadam.cloud", offset: TimeInterval = 0,
                              calTitle: String = "Advisory between Adam and Sam",
                              booker: String? = "sam@example.com", strict: Bool = false) -> Bool {
        CalComSyncService.isLikelyExchangeCopy(
            ekTitle: title, ekAttendeeEmails: invited, ekOrganizerIsCurrentUser: hostOrganises,
            ekOrganizerEmail: organizer, startOffset: offset,
            calTitle: calTitle, bookerEmail: booker, strict: strict)
    }

    func testCalComExchangeCopyTitleRules() {
        func match(_ ek: String?, _ cal: String) -> Bool {
            exchangeCopy(title: ek, invited: [], calTitle: cal, booker: nil)
        }
        XCTAssertTrue(match("Advisory", "advisory "))
        XCTAssertTrue(match("Advisory between Adam and Sam", "Advisory"))
        XCTAssertFalse(match("Syn", "Sync with the board"))
        XCTAssertFalse(match("Lunch", "Advisory"))
        XCTAssertFalse(match(nil, "Advisory"))
    }

    func testCalComExchangeCopyMatchesRenamedEventByBooker() {
        // Exchange copy renamed so the title no longer matches — the booker being
        // invited to a meeting the host organises still identifies it.
        XCTAssertTrue(exchangeCopy(title: "Catch-up", invited: ["Sam@Example.com"], offset: 120))
        // Same person, but an earlier meeting merely overlapping the window.
        XCTAssertFalse(exchangeCopy(title: "Catch-up", invited: ["sam@example.com"], offset: -3600))
        XCTAssertFalse(exchangeCopy(title: "Catch-up", invited: ["lee@example.com"]))
    }

    func testCalComExchangeCopyIgnoresGuestsAndForeignMeetings() {
        // An internal meeting with a cal-auto guest (e.g. a colleague added to every
        // booking) is not the booking's copy: only the booker's email counts.
        XCTAssertFalse(exchangeCopy(title: "Pipeline review", invited: ["sandra@altra.cloud"]))
        // A meeting someone else organised, even with the booker on it, is not it.
        XCTAssertFalse(exchangeCopy(title: "Partner sync", invited: ["sam@example.com"],
                                    hostOrganises: false, organizer: "lee@example.com"))
        // A colleague on the host's own domain booking via Cal.com must not match
        // every internal meeting with them.
        XCTAssertFalse(exchangeCopy(title: "1:1", invited: ["kim@askadam.cloud"], booker: "kim@askadam.cloud"))
    }

    func testCalComReconciliationRequiresTitleAndBooker() {
        // Strict (the path that deletes the app copy): a renamed event invited
        // to the booker is not enough.
        XCTAssertFalse(exchangeCopy(title: "Catch-up", invited: ["sam@example.com"], strict: true))
        // Title matches but the booker isn't on it — a different meeting.
        XCTAssertFalse(exchangeCopy(title: "Advisory between Adam and Sam",
                                    invited: ["lee@example.com"], strict: true))
        XCTAssertTrue(exchangeCopy(title: "Advisory between Adam and Sam",
                                   invited: ["sam@example.com"], strict: true))
        // No attendee data on the event: fall back to the title.
        XCTAssertTrue(exchangeCopy(title: "Advisory between Adam and Sam", invited: [], strict: true))
    }

    // MARK: - Exchange claim ledger (Outlook-cancel must not resurrect)

    func testClaimedBookingIsRemembered() {
        var ledger = CalComExchangeClaims()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(ledger.wasClaimed("abc"))
        ledger.record("abc", start: start)
        XCTAssertTrue(ledger.wasClaimed("abc"))
        XCTAssertFalse(ledger.wasClaimed("other"))
    }

    func testForgetDropsClaim() {
        var ledger = CalComExchangeClaims()
        ledger.record("abc", start: Date())
        ledger.forget("abc")
        XCTAssertFalse(ledger.wasClaimed("abc"))
    }

    func testPruneDropsOnlyBookingsWellInThePast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = CalComExchangeClaims()
        ledger.record("old", start: now.addingTimeInterval(-3 * 86_400))
        ledger.record("earlierToday", start: now.addingTimeInterval(-3_600))
        ledger.record("future", start: now.addingTimeInterval(86_400))
        ledger.prune(now: now)
        XCTAssertFalse(ledger.wasClaimed("old"))
        XCTAssertTrue(ledger.wasClaimed("earlierToday"))
        XCTAssertTrue(ledger.wasClaimed("future"))
    }

    func testClaimsRoundTripThroughPropertyList() {
        var ledger = CalComExchangeClaims()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.record("abc", start: start)
        let restored = CalComExchangeClaims(storage: ledger.storage)
        XCTAssertTrue(restored.wasClaimed("abc"))
        XCTAssertEqual(restored.storage["abc"], start)
    }
}
