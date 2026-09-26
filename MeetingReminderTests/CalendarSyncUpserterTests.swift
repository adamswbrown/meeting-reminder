import XCTest
@testable import MeetingReminder

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
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

    private func makeUpserter(cascade: Bool = true, archive: Bool = false) -> CalendarSyncUpserter {
        let logger = CalendarSyncLogger(path: logPath)
        return CalendarSyncUpserter(client: CalendarSyncNotionClient(token: "test", logger: logger),
                                    logger: logger,
                                    dryRun: true,
                                    archiveOrphans: archive,
                                    cascadeStatus: cascade)
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

    func testCascadeStatusIsForcedOffOnReactiveRuns() {
        XCTAssertTrue(CalendarSyncMode.full.cascadesStatus(enabled: true))
        XCTAssertFalse(CalendarSyncMode.full.cascadesStatus(enabled: false))
        XCTAssertFalse(CalendarSyncMode.reactive.cascadesStatus(enabled: true))
    }
}
