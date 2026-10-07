import XCTest
@testable import MeetingReminder

final class OnDeviceBriefGapFillerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(id: String = "e1", minutesFromNow: Double, attendees: [String]? = ["a@x.com"],
                       allDay: Bool = false, title: String = "Kainos pilot check-in") -> MeetingEvent {
        let start = now.addingTimeInterval(minutesFromNow * 60)
        return MeetingEvent(id: id, title: title, startDate: start, endDate: start.addingTimeInterval(1800),
                            calendar: "Calendar", calendarColor: "", videoLink: nil, isAllDay: allDay,
                            attendees: attendees, notes: nil, location: nil)
    }

    // MARK: candidates

    private var until: Date { now.addingTimeInterval(24 * 3600) }

    func testPicksFutureMeetingsBeforeTheHorizon() {
        let events = [event(id: "soon", minutesFromNow: 45), event(id: "tomorrow", minutesFromNow: 20 * 60),
                      event(id: "beyond", minutesFromNow: 30 * 60), event(id: "past", minutesFromNow: -5)]
        XCTAssertEqual(GapFillPlanner.candidates(events, now: now, until: until, handled: []).map(\.id),
                       ["soon", "tomorrow"])
    }

    func testHorizonIsEndOfTomorrow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let eveningToday = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 17))!
        let expected = cal.date(from: DateComponents(year: 2026, month: 10, day: 9))!
        XCTAssertEqual(GapFillPlanner.horizon(from: eveningToday, calendar: cal), expected)
    }

    func testSkipsAllDayAttendeeLessAndAdHoc() {
        let events = [event(id: "allday", minutesFromNow: 30, allDay: true),
                      event(id: "solo", minutesFromNow: 30, attendees: []),
                      event(id: "nil-att", minutesFromNow: 30, attendees: nil),
                      event(id: "adhoc-1", minutesFromNow: 30)]
        XCTAssertTrue(GapFillPlanner.candidates(events, now: now, until: until, handled: []).isEmpty)
    }

    func testHandledKeyIsPerOccurrence() {
        let e = event(minutesFromNow: 30)
        XCTAssertTrue(GapFillPlanner.candidates([e], now: now, until: until, handled: [GapFillPlanner.key(e)]).isEmpty)
        // Same event moved to a new time is a new occurrence → checked again.
        let moved = event(minutesFromNow: 40)
        XCTAssertEqual(GapFillPlanner.candidates([moved], now: now, until: until, handled: [GapFillPlanner.key(e)]).count, 1)
    }

    func testCandidatesSortedSoonestFirst() {
        let events = [event(id: "b", minutesFromNow: 50), event(id: "a", minutesFromNow: 10)]
        XCTAssertEqual(GapFillPlanner.candidates(events, now: now, until: until, handled: []).map(\.id), ["a", "b"])
    }

    // MARK: hasBrief

    func testHasBriefMatchesCloseTitlesCaseInsensitively() {
        XCTAssertTrue(GapFillPlanner.hasBrief(titles: ["kainos pilot check-in"], for: "Kainos pilot check-in"))
        XCTAssertTrue(GapFillPlanner.hasBrief(titles: ["Kainos pilot check in"], for: "Kainos pilot check-in"))
        XCTAssertFalse(GapFillPlanner.hasBrief(titles: ["Weekly Cadence"], for: "Kainos pilot check-in"))
        XCTAssertFalse(GapFillPlanner.hasBrief(titles: [], for: "Kainos pilot check-in"))
    }

    // MARK: pageBlocks

    func testPageBlocksLeadWithProvenanceCalloutAndCapLists() {
        let blocks = GapFillPlanner.pageBlocks(summary: "S", talkingPoints: ["1", " ", "2", "3", "4"],
                                               prepActions: [], usedTeams: true, usedPriorNotes: false)
        XCTAssertEqual(blocks.first?["type"] as? String, "callout")
        let calloutText = ((blocks.first?["callout"] as? [String: Any])?["rich_text"] as? [[String: Any]])?
            .compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined() ?? ""
        XCTAssertTrue(calloutText.contains("Teams chat"))
        XCTAssertFalse(calloutText.contains("prior meeting notes"))
        XCTAssertEqual(blocks.filter { $0["type"] as? String == "bulleted_list_item" }.count, 3)
        // No actions → no "Prep" heading and no to-dos.
        XCTAssertEqual(blocks.filter { $0["type"] as? String == "to_do" }.count, 0)
        XCTAssertEqual(blocks.filter { $0["type"] as? String == "heading_3" }.count, 2)
    }

    // MARK: Teams context in the prompt

    func testTeamsContextRenderedAndDroppedByLadder() {
        let ctx = IntradayBriefContext(title: "T", startLondon: "a", endLondon: "b", video: nil,
                                       attendees: [], priorNotesSnippet: nil,
                                       teamsContext: "Jane: WinRM blocked by GPO")
        XCTAssertTrue(ctx.render().contains("TEAMS CONTEXT"))
        XCTAssertFalse(ctx.renderMinimal().contains("TEAMS CONTEXT"))

        let huge = IntradayBriefContext(title: "T", startLondon: "a", endLondon: "b", video: nil,
                                        attendees: [], priorNotesSnippet: String(repeating: "word ", count: 5000),
                                        teamsContext: String(repeating: "chat ", count: 5000))
        XCTAssertTrue(TokenBudget.fits(huge.render()))
    }
}

/// Opt-in end-to-end check: real on-device model, real Keychain token, real Notion
/// write. Creates one "[TEST]" Pre-Call Briefing page — trash it afterwards.
/// Run with: TEST_RUNNER_GAPFILL_LIVE=1 xcodebuild test -only-testing:MeetingReminderTests/OnDeviceBriefGapFillerLiveTests
@MainActor
final class OnDeviceBriefGapFillerLiveTests: XCTestCase {
    func testLiveFillCreatesNotionPage() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GAPFILL_LIVE"] == "1", "live test is opt-in")
        guard let token = KeychainHelper.read(key: CalendarSyncConstants.tokenKeychainKey) else {
            throw XCTSkip("no Notion token")
        }
        let start = Date().addingTimeInterval(30 * 60)
        let event = MeetingEvent(
            id: "gapfill-live-\(UUID().uuidString)", title: "[TEST] On-device gap-filler check",
            startDate: start, endDate: start.addingTimeInterval(1800), calendar: "Test",
            attendees: ["jane.doe@example.com", "luke.lloyd@altra.cloud"],
            notes: "Pilot check-in. 40 servers failing guest scan because WinRM is blocked by GPO. Adam to send the firewall rule doc.")
        let filler = OnDeviceBriefGapFiller(calendarService: CalendarService(), enrichment: CalendarEnrichmentService())
        UserDefaults.standard.removeObject(forKey: OnDeviceBriefGapFiller.Keys.lastResult)
        await filler.fill(event, client: CalendarSyncNotionClient(token: token, logger: CalendarSyncLogger(path: NSTemporaryDirectory() + "gapfill-live.log")))
        print("GAPFILL_LIVE_RESULT: \(filler.lastResult)")
        XCTAssertTrue(filler.lastResult.contains("briefed"), filler.lastResult)
    }
}
