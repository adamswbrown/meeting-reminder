import XCTest
@testable import MeetingReminder

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

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
    var availabilityRawValue: Int = 1
}

/// Drives `CalendarSyncUpserter` in dry-run mode, which never touches the
/// network, so the orphan sweep's row selection can be asserted via counts.
final class CalendarSyncUpserterTests: XCTestCase {

    private var logPath: String!

    override func setUp() {
        super.setUp()
        logPath = NSTemporaryDirectory() + "calsync-upserter-tests-\(UUID().uuidString).log"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: logPath)
        super.tearDown()
    }

    private func makeUpserter(cascade: Bool = true, archive: Bool = false,
                              sweepOrphans: Bool = true) -> CalendarSyncUpserter {
        let logger = CalendarSyncLogger(path: logPath)
        return CalendarSyncUpserter(client: CalendarSyncNotionClient(token: "test", logger: logger),
                                    logger: logger,
                                    dryRun: true,
                                    archiveOrphans: archive,
                                    cascadeStatus: cascade,
                                    sweepOrphans: sweepOrphans)
    }

    private func existingRow(pageID: String = "page-1",
                             sourceCalendar: String?,
                             date: Date) -> CalendarSyncNotionQueries.ExistingRow {
        var props: [String: Any] = ["Status": ["select": ["name": "Upcoming"]]]
        if let sourceCalendar {
            props["Source Calendar"] = ["select": ["name": sourceCalendar]]
        }
        return CalendarSyncNotionQueries.ExistingRow(
            pageID: pageID,
            hasMeetingNotesLink: false,
            hasPreCallBriefingLink: false,
            archived: false,
            syncState: "Active",
            properties: props,
            eventDate: date,
            preCallBriefingPageID: nil)
    }

    private let window = (start: iso("2026-09-01T00:00:00Z"), end: iso("2026-10-31T00:00:00Z"))

    // MARK: Item A1 — orphan sweep scoped to calendars fetched this run

    func testOrphanOnFetchedCalendarIsCancelled() async {
        let existing = ["ONE-OFF": existingRow(sourceCalendar: "Work", date: iso("2026-09-20T10:00:00Z"))]
        let outcome = await makeUpserter().run(rows: [], existing: existing,
                                               orphanWindow: window,
                                               sweepableCalendars: ["Work"])
        XCTAssertEqual(outcome.counts.orphaned, 1)
    }

    /// A calendar that returned nothing this run (account offline, calendar
    /// de-selected, EventKit hiccup) must not have every one of its rows
    /// stamped Cancelled.
    func testOrphanOnUnfetchedCalendarIsLeftAlone() async {
        let existing = ["ONE-OFF": existingRow(sourceCalendar: "Work", date: iso("2026-09-20T10:00:00Z"))]
        let outcome = await makeUpserter().run(rows: [], existing: existing,
                                               orphanWindow: window,
                                               sweepableCalendars: ["Personal"])
        XCTAssertEqual(outcome.counts.orphaned, 0)
        XCTAssertEqual(outcome.counts.staled, 0)
    }

    func testOrphanWithNoSourceCalendarIsLeftAlone() async {
        let existing = ["ONE-OFF": existingRow(sourceCalendar: nil, date: iso("2026-09-20T10:00:00Z"))]
        let outcome = await makeUpserter().run(rows: [], existing: existing,
                                               orphanWindow: window,
                                               sweepableCalendars: ["Work"])
        XCTAssertEqual(outcome.counts.orphaned, 0)
    }

    func testSweepableCalendarNamesOnlyIncludesCalendarsThatReturnedEvents() {
        let names = CalendarSyncCascade.sweepableCalendarNames(
            fetched: [("Calendar (Exchange)", 42), ("Holidays", 0), ("Personal", 3)])
        XCTAssertEqual(names, ["Calendar (Exchange)", "Personal"])
    }

    func testOrphanPassIsForcedOffOnReactiveRuns() {
        XCTAssertTrue(CalendarSyncMode.full.sweepsOrphans)
        XCTAssertFalse(CalendarSyncMode.reactive.sweepsOrphans)
    }

    /// Reactive runs keep `cascadeStatus` on (so a moved one-off re-dates its
    /// brief) but must still skip the orphan pass entirely.
    func testOrphanPassSkippedWhenSweepOffEvenWithCascadeOn() async {
        let existing = ["ONE-OFF": existingRow(sourceCalendar: "Work", date: iso("2026-09-20T10:00:00Z"))]
        let outcome = await makeUpserter(cascade: true, archive: true, sweepOrphans: false)
            .run(rows: [], existing: existing,
                 orphanWindow: window,
                 sweepableCalendars: ["Work"])
        XCTAssertEqual(outcome.counts.orphaned, 0)
        XCTAssertEqual(outcome.counts.staled, 0)
    }

    // MARK: Item A3 — skip-filtered recurring series keeps its master row

    func testSkippedRecurringOccurrenceMarksSeriesMasterPresent() {
        var e = StubEvent(); e.externalIdentifier = "SERIES"; e.eventIsRecurring = true
        e.eventStart = iso("2026-09-21T09:00:00Z")
        XCTAssertEqual(Set(CalendarSyncCascade.presentIDs(forSkipped: e)),
                       ["SERIES_2026-09-21", "SERIES"])
    }

    func testSkippedOneOffMarksOnlyItself() {
        var e = StubEvent(); e.externalIdentifier = "ONE-OFF"; e.eventIsRecurring = false
        XCTAssertEqual(CalendarSyncCascade.presentIDs(forSkipped: e), ["ONE-OFF"])
    }

    /// A Skip List rule added for a recurring meeting drops every occurrence,
    /// so no series-master row is emitted; its bare-UID row must not then be
    /// swept as a cancelled one-off.
    func testSeriesMasterOfSkippedSeriesIsNotCancelled() async {
        var e = StubEvent(); e.externalIdentifier = "SERIES"; e.eventIsRecurring = true
        e.eventStart = iso("2026-09-21T09:00:00Z")
        let existing = ["SERIES": existingRow(sourceCalendar: "Work", date: iso("2026-09-14T09:00:00Z"))]
        let outcome = await makeUpserter().run(rows: [], existing: existing,
                                               orphanWindow: window,
                                               presentIDs: Set(CalendarSyncCascade.presentIDs(forSkipped: e)),
                                               sweepableCalendars: ["Work"])
        XCTAssertEqual(outcome.counts.orphaned, 0)
    }

    // MARK: Item A7 — Notion 429 handling

    func testRateLimitHonoursRetryAfter() {
        XCTAssertEqual(NotionRetryPolicy.delay(status: 429, retryAfter: "7", backoff: 0.5), 7)
    }

    func testRetryAfterIsCappedAndIgnoredWhenMalformed() {
        XCTAssertEqual(NotionRetryPolicy.delay(status: 429, retryAfter: "3600", backoff: 0.5),
                       NotionRetryPolicy.maxRetryAfter)
        XCTAssertEqual(NotionRetryPolicy.delay(status: 429, retryAfter: "soon", backoff: 0.5), 0.5)
        XCTAssertEqual(NotionRetryPolicy.delay(status: 429, retryAfter: nil, backoff: 2), 2)
        XCTAssertEqual(NotionRetryPolicy.delay(status: 503, retryAfter: "7", backoff: 1), 1)
    }

    /// A third 429 used to throw and abort the whole run; rate limits get
    /// more attempts than transient 5xx/transport errors.
    func testRateLimitGetsMoreAttemptsThanServerErrors() {
        XCTAssertTrue(NotionRetryPolicy.shouldRetry(status: 429, attempt: 3))
        XCTAssertTrue(NotionRetryPolicy.shouldRetry(status: 429, attempt: 5))
        XCTAssertFalse(NotionRetryPolicy.shouldRetry(status: 429, attempt: 6))
        XCTAssertTrue(NotionRetryPolicy.shouldRetry(status: 503, attempt: 2))
        XCTAssertFalse(NotionRetryPolicy.shouldRetry(status: 503, attempt: 3))
        XCTAssertTrue(NotionRetryPolicy.shouldRetry(status: nil, attempt: 2))
        XCTAssertFalse(NotionRetryPolicy.shouldRetry(status: 400, attempt: 1))
    }

    // MARK: Item A4 — page creates are not blindly retried

    /// A transport error or 5xx on `POST /pages` may mean the page was created
    /// and only the response was lost; retrying it blindly mints a duplicate.
    func testNonIdempotentRequestsOnlyRetryRateLimits() {
        XCTAssertFalse(NotionRetryPolicy.shouldRetry(status: nil, attempt: 1, idempotent: false))
        XCTAssertFalse(NotionRetryPolicy.shouldRetry(status: 503, attempt: 1, idempotent: false))
        XCTAssertFalse(NotionRetryPolicy.shouldRetry(status: 504, attempt: 1, idempotent: false))
        XCTAssertTrue(NotionRetryPolicy.shouldRetry(status: 429, attempt: 1, idempotent: false))
    }

    func testAmbiguousFailureClassification() {
        XCTAssertTrue(NotionRetryPolicy.isAmbiguousFailure(URLError(.timedOut)))
        XCTAssertTrue(NotionRetryPolicy.isAmbiguousFailure(CalendarSyncNotionError(status: 504, body: "")))
        XCTAssertTrue(NotionRetryPolicy.isAmbiguousFailure(CalendarSyncNotionError(status: 500, body: "")))
        XCTAssertFalse(NotionRetryPolicy.isAmbiguousFailure(CalendarSyncNotionError(status: 400, body: "")))
        XCTAssertFalse(NotionRetryPolicy.isAmbiguousFailure(CalendarSyncNotionError(status: 429, body: "")))
        XCTAssertFalse(NotionRetryPolicy.isAmbiguousFailure(CancellationError()))
    }
}
