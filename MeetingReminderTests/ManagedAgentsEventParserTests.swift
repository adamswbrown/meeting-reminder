import XCTest
@testable import MeetingReminder

final class ManagedAgentsEventParserTests: XCTestCase {

    private func ev(_ type: String, at t: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var e: [String: Any] = ["type": type, "processed_at": t]
        for (k, v) in extra { e[k] = v }
        return e
    }

    private func message(_ text: String, at t: String) -> [String: Any] {
        ev("agent.message", at: t, ["content": [["type": "text", "text": text]]])
    }

    /// A new session reports idle before it has picked up the queued message — that is not "done".
    func testIdleBeforeAnyRunning_isStillRunning() {
        let events = [ev("session.status_idle", at: "2026-10-18T10:00:00Z", ["stop_reason": ["type": "end_turn"]])]
        XCTAssertEqual(ManagedAgentsEventParser.outcome(of: events), .running)
    }

    func testRunningThenIdleEndTurn_isFinishedWithAgentText() {
        let events = [
            ev("session.status_running", at: "2026-10-18T10:00:01Z"),
            message("INTRADAY_RESULT: created=1", at: "2026-10-18T10:00:30Z"),
            ev("session.status_idle", at: "2026-10-18T10:00:31Z", ["stop_reason": ["type": "end_turn"]]),
        ]
        XCTAssertEqual(ManagedAgentsEventParser.outcome(of: events),
                       .finished(text: "INTRADAY_RESULT: created=1"))
    }

    func testStillRunning() {
        let events = [
            ev("session.status_running", at: "2026-10-18T10:00:01Z"),
            message("working", at: "2026-10-18T10:00:05Z"),
        ]
        XCTAssertEqual(ManagedAgentsEventParser.outcome(of: events), .running)
    }

    func testRequiresAction_returnsToolUseIDsToSettle() {
        let events = [
            ev("session.status_running", at: "2026-10-18T10:00:01Z"),
            ev("session.status_idle", at: "2026-10-18T10:00:05Z",
               ["stop_reason": ["type": "requires_action", "event_ids": ["sevt_1", "sevt_2"]]]),
        ]
        XCTAssertEqual(ManagedAgentsEventParser.outcome(of: events),
                       .needsConfirmation(toolUseIDs: ["sevt_1", "sevt_2"]))
    }

    /// After the confirmations are settled the session runs again — the earlier pause must not stick.
    func testRunningAfterRequiresAction_clearsThePause() {
        let events = [
            ev("session.status_running", at: "2026-10-18T10:00:01Z"),
            ev("session.status_idle", at: "2026-10-18T10:00:05Z",
               ["stop_reason": ["type": "requires_action", "event_ids": ["sevt_1"]]]),
            ev("session.status_running", at: "2026-10-18T10:00:06Z"),
        ]
        XCTAssertEqual(ManagedAgentsEventParser.outcome(of: events), .running)
    }

    func testBudgetReached() {
        let events = [
            ev("session.status_running", at: "2026-10-18T10:00:01Z"),
            ev("session.status_idle", at: "2026-10-18T10:05:00Z", ["stop_reason": ["type": "budget_reached"]]),
        ]
        XCTAssertEqual(ManagedAgentsEventParser.outcome(of: events), .budgetReached(text: ""))
    }

    func testTerminated() {
        let events = [
            ev("session.status_running", at: "2026-10-18T10:00:01Z"),
            ev("session.status_terminated", at: "2026-10-18T10:00:09Z"),
        ]
        XCTAssertEqual(ManagedAgentsEventParser.outcome(of: events), .terminated(text: ""))
    }

    /// The list endpoint's ordering is not relied on: events are re-sorted by processed_at.
    func testNewestFirstOrdering_isNormalised() {
        let events = [
            ev("session.status_idle", at: "2026-10-18T10:00:31Z", ["stop_reason": ["type": "end_turn"]]),
            message("done", at: "2026-10-18T10:00:30Z"),
            ev("session.status_running", at: "2026-10-18T10:00:01Z"),
        ]
        XCTAssertEqual(ManagedAgentsEventParser.outcome(of: events), .finished(text: "done"))
    }

    func testMultipleAgentMessagesAreJoinedInOrder() {
        let events = [
            ev("session.status_running", at: "2026-10-18T10:00:01Z"),
            message("first", at: "2026-10-18T10:00:10Z"),
            message("second", at: "2026-10-18T10:00:20Z"),
            ev("session.status_idle", at: "2026-10-18T10:00:21Z", ["stop_reason": ["type": "end_turn"]]),
        ]
        XCTAssertEqual(ManagedAgentsEventParser.outcome(of: events), .finished(text: "first\nsecond"))
    }
}
