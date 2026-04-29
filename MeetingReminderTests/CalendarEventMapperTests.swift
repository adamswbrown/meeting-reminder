import XCTest
@testable import MeetingReminder

private struct StubEvent: EventLike {
    var eventTitle: String = "Stub"
    var eventStart: Date = Date()
    var eventEnd: Date = Date().addingTimeInterval(1800)
    var eventIsAllDay: Bool = false
    var statusRawValue: Int = 1
    var organizerName: String? = nil
    var organizerEmail: String? = nil
    var attendeesList: [(name: String?, email: String)] = []
    var locationString: String? = nil
    var notesString: String? = nil
    var eventIsRecurring: Bool = false
    var externalIdentifier: String = "EXT"
    var availabilityRawValue: Int = 1 // .busy
}

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

final class CalendarEventMapperTests: XCTestCase {

    // MARK: composite Apple Event ID

    func testCompositeIDForNonRecurringIsBareExternalID() {
        var e = StubEvent(); e.externalIdentifier = "ABC123"; e.eventIsRecurring = false
        e.eventStart = iso("2026-04-28T14:00:00Z")
        XCTAssertEqual(CalendarEventMapper.compositeAppleID(for: e), "ABC123")
    }

    func testCompositeIDForRecurringAppendsLondonDate() {
        var e = StubEvent(); e.externalIdentifier = "XYZ"; e.eventIsRecurring = true
        // 14:00 UTC on 2026-04-28 = 15:00 BST same day
        e.eventStart = iso("2026-04-28T14:00:00Z")
        XCTAssertEqual(CalendarEventMapper.compositeAppleID(for: e), "XYZ_2026-04-28")
    }

    func testCompositeIDForRecurringHandlesBSTBoundary() {
        var e = StubEvent(); e.externalIdentifier = "XYZ"; e.eventIsRecurring = true
        // 23:30 UTC on 2026-04-28 = 00:30 BST on 2026-04-29
        e.eventStart = iso("2026-04-28T23:30:00Z")
        XCTAssertEqual(CalendarEventMapper.compositeAppleID(for: e), "XYZ_2026-04-29")
    }

    // MARK: derived status

    func testDerivedStatusCancelledWinsOverFutureDate() {
        var e = StubEvent(); e.statusRawValue = 3
        e.eventStart = iso("3000-01-01T12:00:00Z")
        XCTAssertEqual(CalendarEventMapper.derivedStatus(for: e, now: Date()), "Cancelled")
    }

    func testDerivedStatusUpcomingForFuture() {
        var e = StubEvent()
        let now = iso("2026-04-28T10:00:00Z")
        e.eventStart = iso("2026-05-15T10:00:00Z")
        XCTAssertEqual(CalendarEventMapper.derivedStatus(for: e, now: now), "Upcoming")
    }

    func testDerivedStatusPastForBeforeNow() {
        var e = StubEvent()
        let now = iso("2026-04-28T10:00:00Z")
        e.eventStart = iso("2026-03-15T10:00:00Z")
        XCTAssertEqual(CalendarEventMapper.derivedStatus(for: e, now: now), "Past")
    }

    func testDerivedStatusTodayWhenLondonDayMatches() {
        var e = StubEvent()
        let now = iso("2026-04-28T10:00:00Z")
        e.eventStart = iso("2026-04-28T15:00:00Z")
        XCTAssertEqual(CalendarEventMapper.derivedStatus(for: e, now: now), "Today")
    }

    // MARK: attendees

    func testAttendeesStringExcludesOrganiserByEmail() {
        var e = StubEvent()
        e.organizerEmail = "boss@altra.cloud"
        e.attendeesList = [(name: "Boss", email: "boss@altra.cloud"),
                           (name: "Alice", email: "alice@altra.cloud")]
        let s = CalendarEventMapper.attendeesString(for: e)
        XCTAssertFalse(s.contains("Boss"))
        XCTAssertTrue(s.contains("Alice <alice@altra.cloud>"))
    }

    func testAttendeeCountExcludesOrganiser() {
        var e = StubEvent()
        e.organizerEmail = "boss@altra.cloud"
        e.attendeesList = [(name: "Boss", email: "boss@altra.cloud"),
                           (name: "Alice", email: "alice@altra.cloud"),
                           (name: "Bob", email: "bob@altra.cloud")]
        XCTAssertEqual(CalendarEventMapper.attendeeCount(for: e), 2)
    }

    func testAttendeesStringTruncatesUnder1900Chars() {
        var e = StubEvent()
        e.attendeesList = (0..<200).map { (Optional("Person \($0)"), "p\($0)@altra.cloud") }
        let s = CalendarEventMapper.attendeesString(for: e)
        XCTAssertLessThanOrEqual(s.count, 1900)
        XCTAssertTrue(s.hasSuffix("…"))
    }

    // MARK: external attendees

    func testHasExternalAttendeesFalseForAllInternal() {
        var e = StubEvent()
        e.attendeesList = [(nil, "a@altra.cloud"), (nil, "b@altra.cloud")]
        XCTAssertFalse(CalendarEventMapper.hasExternalAttendees(for: e))
    }

    func testHasExternalAttendeesTrueForOneExternal() {
        var e = StubEvent()
        e.attendeesList = [(nil, "a@altra.cloud"), (nil, "x@example.com")]
        XCTAssertTrue(CalendarEventMapper.hasExternalAttendees(for: e))
    }

    func testHasExternalAttendeesIgnoresOrganiserEmail() {
        var e = StubEvent()
        e.organizerEmail = "external@partner.com"
        e.attendeesList = [(nil, "external@partner.com"),
                           (nil, "a@altra.cloud")]
        XCTAssertFalse(CalendarEventMapper.hasExternalAttendees(for: e))
    }

    // MARK: conference URL

    func testExtractsTeamsURLFromNotes() {
        var e = StubEvent()
        e.notesString = "Join here https://teams.microsoft.com/l/meetup-join/abc thanks"
        XCTAssertEqual(CalendarEventMapper.extractConferenceURL(from: e),
                       "https://teams.microsoft.com/l/meetup-join/abc")
    }

    func testExtractsZoomURLFromLocation() {
        var e = StubEvent()
        e.locationString = "https://zoom.us/j/123 or in-person"
        XCTAssertTrue(CalendarEventMapper.extractConferenceURL(from: e)?.contains("zoom.us/j/123") ?? false)
    }

    func testReturnsNilWhenNoConferenceURL() {
        var e = StubEvent()
        e.notesString = "Just a description"
        e.locationString = "Conference Room A"
        XCTAssertNil(CalendarEventMapper.extractConferenceURL(from: e))
    }

    // MARK: expandToRows

    func testExpandToRowsEmitsMasterPlusOccurrencesPerSeries() {
        var occA1 = StubEvent(); occA1.eventTitle = "Series A"; occA1.externalIdentifier = "A"; occA1.eventIsRecurring = true; occA1.eventStart = iso("2026-04-28T10:00:00Z")
        var occA2 = StubEvent(); occA2.eventTitle = "Series A"; occA2.externalIdentifier = "A"; occA2.eventIsRecurring = true; occA2.eventStart = iso("2026-05-05T10:00:00Z")
        var nonRecurring = StubEvent(); nonRecurring.eventTitle = "One-off"; nonRecurring.externalIdentifier = "B"
        let rows = CalendarEventMapper.expandToRows(events: [occA1, occA2, nonRecurring], now: Date())
        // Expect: 1 non-recurring (false), 1 master (true), 2 occurrences (false)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.filter { $0.isSeriesMaster }.count, 1)
    }

    func testExpandToRowsSkipsCancelledOccurrences() {
        var live = StubEvent(); live.externalIdentifier = "A"; live.eventIsRecurring = true; live.statusRawValue = 1
        var cancelled = StubEvent(); cancelled.externalIdentifier = "A"; cancelled.eventIsRecurring = true; cancelled.statusRawValue = 3
        let rows = CalendarEventMapper.expandToRows(events: [live, cancelled], now: Date())
        // 1 master + 1 live occurrence = 2; cancelled should be filtered out before grouping
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: skip filter

    func testSkipFilterExactMatchIsCaseSensitive() {
        let rules = [SkipRule(title: "Lunch", matchType: .exactTitle)]
        XCTAssertTrue(SkipFilter.shouldSkip(title: "Lunch", rules: rules))
        XCTAssertFalse(SkipFilter.shouldSkip(title: "lunch", rules: rules))
    }

    func testSkipFilterContainsIsCaseInsensitive() {
        let rules = [SkipRule(title: "lunch", matchType: .titleContains)]
        XCTAssertTrue(SkipFilter.shouldSkip(title: "Team Lunch", rules: rules))
        XCTAssertTrue(SkipFilter.shouldSkip(title: "LUNCH break", rules: rules))
        XCTAssertFalse(SkipFilter.shouldSkip(title: "Standup", rules: rules))
    }

    func testSkipFilterNoRulesNeverSkips() {
        XCTAssertFalse(SkipFilter.shouldSkip(title: "Anything", rules: []))
    }

    // MARK: availability

    func testAvailabilityNamesForEventKitRawValues() {
        var e = StubEvent()
        e.availabilityRawValue = 1
        XCTAssertEqual(CalendarEventMapper.availabilityName(for: e), "Busy")
        e.availabilityRawValue = 2
        XCTAssertEqual(CalendarEventMapper.availabilityName(for: e), "Free")
        e.availabilityRawValue = 3
        XCTAssertEqual(CalendarEventMapper.availabilityName(for: e), "Tentative")
        e.availabilityRawValue = 4
        XCTAssertEqual(CalendarEventMapper.availabilityName(for: e), "OOO")
    }

    /// EventKit's Exchange bridge often returns .notSupported (rawValue 0) for
    /// what is in fact an OOO block. Confirm the title heuristic rescues it.
    func testAvailabilityFallsBackToTitleHeuristicWhenNotSupported() {
        var e = StubEvent()
        e.availabilityRawValue = 0
        e.eventTitle = "Annual Leave"
        XCTAssertEqual(CalendarEventMapper.availabilityName(for: e), "OOO")
        e.eventTitle = "Out of Office — Family stuff"
        XCTAssertEqual(CalendarEventMapper.availabilityName(for: e), "OOO")
    }

    func testAvailabilityUnknownWhenNotSupportedAndTitleNeutral() {
        var e = StubEvent()
        e.availabilityRawValue = 0
        e.eventTitle = "Quarterly review"
        XCTAssertEqual(CalendarEventMapper.availabilityName(for: e), "Unknown")
    }

    func testLooksLikeOOOMatchesCommonPhrases() {
        XCTAssertTrue(CalendarEventMapper.looksLikeOOO(title: "Annual Leave"))
        XCTAssertTrue(CalendarEventMapper.looksLikeOOO(title: "OOO — sailing"))
        XCTAssertTrue(CalendarEventMapper.looksLikeOOO(title: "On Leave Mon-Fri"))
        XCTAssertTrue(CalendarEventMapper.looksLikeOOO(title: "PTO"))
        XCTAssertTrue(CalendarEventMapper.looksLikeOOO(title: "vacation - bali"))
    }

    func testLooksLikeOOORejectsNeutralTitles() {
        XCTAssertFalse(CalendarEventMapper.looksLikeOOO(title: "Quarterly Review"))
        XCTAssertFalse(CalendarEventMapper.looksLikeOOO(title: "1:1 with Sandra"))
    }

    // MARK: build properties — multi-calendar plumbing

    func testBuildPropertiesWritesSourceCalendarName() {
        var e = StubEvent(); e.eventStart = iso("2026-05-01T10:00:00Z"); e.eventEnd = iso("2026-05-01T11:00:00Z")
        let props = CalendarEventMapper.buildProperties(
            for: e, now: iso("2026-05-01T09:00:00Z"),
            isSeriesMaster: false,
            sourceCalendarName: "Personal")
        let cal = props["Calendar"] as? [String: Any]
        let select = cal?["select"] as? [String: Any]
        XCTAssertEqual(select?["name"] as? String, "Personal")
        let src = props["Source Calendar"] as? [String: Any]
        let srcSelect = src?["select"] as? [String: Any]
        XCTAssertEqual(srcSelect?["name"] as? String, "Personal")
    }

    func testBuildPropertiesFallsBackToExchangeLabelOnEmptyName() {
        var e = StubEvent(); e.eventStart = iso("2026-05-01T10:00:00Z"); e.eventEnd = iso("2026-05-01T11:00:00Z")
        let props = CalendarEventMapper.buildProperties(
            for: e, now: iso("2026-05-01T09:00:00Z"),
            isSeriesMaster: false,
            sourceCalendarName: "")
        let cal = props["Calendar"] as? [String: Any]
        let select = cal?["select"] as? [String: Any]
        XCTAssertEqual(select?["name"] as? String, "Calendar (Exchange)")
    }

    func testBuildPropertiesAlwaysWritesAvailability() {
        var e = StubEvent(); e.availabilityRawValue = 4 // OOO
        let props = CalendarEventMapper.buildProperties(
            for: e, now: Date(),
            isSeriesMaster: false,
            sourceCalendarName: "Personal")
        let av = props["Availability"] as? [String: Any]
        let select = av?["select"] as? [String: Any]
        XCTAssertEqual(select?["name"] as? String, "OOO")
    }
}
