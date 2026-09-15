import XCTest

@testable import MeetingReminder

/// Pure-logic tests for the meeting-note lookup helper. No network, no
/// EventKit — everything here is a value-in/value-out transformation.
final class MeetingNoteMatcherTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a UTC instant from an ISO8601 string so tests read as wall time.
    private func utc(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else {
            XCTFail("bad test date \(iso)")
            return Date()
        }
        return d
    }

    private func candidate(_ id: String, _ title: String) -> MeetingNoteMatcher.Candidate {
        MeetingNoteMatcher.Candidate(
            pageID: id,
            title: title,
            url: URL(string: "https://notion.so/\(id)")!)
    }

    // MARK: - resolve

    func testResolveReturnsUniqueOnSingleExactMatch() {
        let candidates = [candidate("p1", "Dr Migrate Walkthrough")]
        let result = MeetingNoteMatcher.resolve(candidates: candidates,
                                                title: "Dr Migrate Walkthrough")
        guard case .unique(let hit) = result else {
            return XCTFail("expected unique, got \(result)")
        }
        XCTAssertEqual(hit.pageID, "p1")
    }

    func testResolveIsCaseInsensitive() {
        let candidates = [candidate("p1", "dr migrate WALKTHROUGH")]
        let result = MeetingNoteMatcher.resolve(candidates: candidates,
                                                title: "Dr Migrate Walkthrough")
        guard case .unique(let hit) = result else {
            return XCTFail("expected unique, got \(result)")
        }
        XCTAssertEqual(hit.pageID, "p1")
    }

    /// The load-bearing precision step: Notion's server-side `contains` filter
    /// returns "Sync with Bob" for the needle "Sync". Exact equality must
    /// reject it, otherwise a short-titled meeting hijacks a longer one's note.
    func testResolveRejectsSubstringOnlyMatch() {
        let candidates = [candidate("p1", "Sync with Bob")]
        let result = MeetingNoteMatcher.resolve(candidates: candidates, title: "Sync")
        XCTAssertEqual(result, .none)
    }

    func testResolveReturnsAmbiguousOnTwoExactMatches() {
        let candidates = [
            candidate("p1", "Weekly Cadence"),
            candidate("p2", "weekly cadence"),
            candidate("p3", "Weekly Cadence Planning"),
        ]
        let result = MeetingNoteMatcher.resolve(candidates: candidates, title: "Weekly Cadence")
        XCTAssertEqual(result, .ambiguous(["p1", "p2"]))
    }

    func testResolveReturnsNoneOnEmptyCandidates() {
        XCTAssertEqual(MeetingNoteMatcher.resolve(candidates: [], title: "Anything"), .none)
    }

    func testResolveTrimsSurroundingWhitespace() {
        let candidates = [candidate("p1", "  Dr Migrate Walkthrough\n")]
        let result = MeetingNoteMatcher.resolve(candidates: candidates,
                                                title: " Dr Migrate Walkthrough ")
        guard case .unique(let hit) = result else {
            return XCTFail("expected unique, got \(result)")
        }
        XCTAssertEqual(hit.pageID, "p1")
    }

    func testResolveReturnsNoneForEmptyTitle() {
        let candidates = [candidate("p1", "")]
        XCTAssertEqual(MeetingNoteMatcher.resolve(candidates: candidates, title: "   "), .none)
    }

    // MARK: - appleEventID

    func testAppleEventIDIsBareForNonRecurringEvent() {
        let id = MeetingNoteMatcher.appleEventID(
            externalID: "12D54CB4-98F5-474F-B81D-0C0B82C32DD7",
            isRecurring: false,
            start: utc("2026-09-15T10:30:00Z"))
        XCTAssertEqual(id, "12D54CB4-98F5-474F-B81D-0C0B82C32DD7")
    }

    func testAppleEventIDAppendsOccurrenceDateForRecurringEvent() {
        let id = MeetingNoteMatcher.appleEventID(
            externalID: "286E9957",
            isRecurring: true,
            start: utc("2026-09-15T06:30:00Z"))
        XCTAssertEqual(id, "286E9957_2026-09-15")
    }

    /// 00:30 BST on the 16th is 23:30Z on the 15th. The suffix must follow
    /// Europe/London, or the occurrence gets tagged with the previous UTC day
    /// and never matches the row the sync wrote.
    func testAppleEventIDUsesLondonDayNotUTCDay() {
        let id = MeetingNoteMatcher.appleEventID(
            externalID: "LATE",
            isRecurring: true,
            start: utc("2026-07-15T23:30:00Z"))
        XCTAssertEqual(id, "LATE_2026-07-16")
    }

    // MARK: - dayString

    func testDayStringUsesLondonCalendarDay() {
        XCTAssertEqual(MeetingNoteMatcher.dayString(for: utc("2026-07-15T23:30:00Z")),
                       "2026-07-16")
        XCTAssertEqual(MeetingNoteMatcher.dayString(for: utc("2026-09-15T10:30:00Z")),
                       "2026-09-15")
    }

    /// Outside BST the offset is zero, so London and UTC agree.
    func testDayStringInWinterMatchesUTC() {
        XCTAssertEqual(MeetingNoteMatcher.dayString(for: utc("2026-01-15T23:30:00Z")),
                       "2026-01-15")
    }

    // MARK: - query bodies

    func testTitleDayQueryBodyBracketsASingleDay() {
        let body = MeetingNoteMatcher.titleDayQueryBody(
            titleProperty: "Title",
            dateProperty: "Start",
            titleNeedle: "Dr Migrate Walkthrough",
            day: "2026-09-15",
            cursor: nil)

        XCTAssertEqual(body["page_size"] as? Int, 100)
        XCTAssertNil(body["start_cursor"])

        guard let filter = body["filter"] as? [String: Any],
              let clauses = filter["and"] as? [[String: Any]] else {
            return XCTFail("expected an `and` filter, got \(body)")
        }
        XCTAssertEqual(clauses.count, 3)

        let titleClause = clauses[0]
        XCTAssertEqual(titleClause["property"] as? String, "Title")
        XCTAssertEqual((titleClause["title"] as? [String: Any])?["contains"] as? String,
                       "Dr Migrate Walkthrough")

        let after = (clauses[1]["date"] as? [String: Any])?["on_or_after"] as? String
        let before = (clauses[2]["date"] as? [String: Any])?["on_or_before"] as? String
        XCTAssertEqual(after, "2026-09-15")
        XCTAssertEqual(before, "2026-09-15")
        XCTAssertEqual(clauses[1]["property"] as? String, "Start")
        XCTAssertEqual(clauses[2]["property"] as? String, "Start")
    }

    func testTitleDayQueryBodyCarriesCursorWhenPaging() {
        let body = MeetingNoteMatcher.titleDayQueryBody(
            titleProperty: "Title",
            dateProperty: "Start",
            titleNeedle: "x",
            day: "2026-09-15",
            cursor: "cur-123")
        XCTAssertEqual(body["start_cursor"] as? String, "cur-123")
    }

    // MARK: - relation extraction

    /// The relation is by page ID, so it survives the note being renamed —
    /// which title matching cannot. This is the authoritative path.
    func testRelationPageIDsReadsRelationFromFirstRow() {
        let response: [String: Any] = [
            "results": [[
                "id": "cal-row-1",
                "properties": [
                    "Meeting Notes": [
                        "relation": [["id": "note-1"]]
                    ]
                ],
            ]]
        ]
        XCTAssertEqual(
            MeetingNoteMatcher.relationPageIDs(from: response, property: "Meeting Notes"),
            ["note-1"])
    }

    func testRelationPageIDsReturnsAllWhenSeveralLinked() {
        let response: [String: Any] = [
            "results": [[
                "id": "cal-row-1",
                "properties": [
                    "Meeting Notes": [
                        "relation": [["id": "note-1"], ["id": "note-2"]]
                    ]
                ],
            ]]
        ]
        XCTAssertEqual(
            MeetingNoteMatcher.relationPageIDs(from: response, property: "Meeting Notes"),
            ["note-1", "note-2"])
    }

    func testRelationPageIDsIsEmptyWhenUnlinked() {
        let response: [String: Any] = [
            "results": [[
                "id": "cal-row-1",
                "properties": ["Meeting Notes": ["relation": []]],
            ]]
        ]
        XCTAssertEqual(
            MeetingNoteMatcher.relationPageIDs(from: response, property: "Meeting Notes"),
            [])
    }

    func testRelationPageIDsIsEmptyWhenNoCalendarRowExists() {
        XCTAssertEqual(
            MeetingNoteMatcher.relationPageIDs(from: ["results": []], property: "Meeting Notes"),
            [])
    }

    // MARK: - pageURL

    func testPageURLStripsDashesFromPageID() {
        let url = MeetingNoteMatcher.pageURL(forPageID: "3dcef850-f293-8091-b1b9-f2b1fc7d5ebb")
        XCTAssertEqual(url.absoluteString,
                       "https://www.notion.so/3dcef850f2938091b1b9f2b1fc7d5ebb")
    }

    func testAppleEventIDQueryBodyFiltersOnExactRichText() {
        let body = MeetingNoteMatcher.appleEventIDQueryBody(
            property: "Apple Event ID",
            value: "12D54CB4")
        guard let filter = body["filter"] as? [String: Any] else {
            return XCTFail("expected a filter, got \(body)")
        }
        XCTAssertEqual(filter["property"] as? String, "Apple Event ID")
        XCTAssertEqual((filter["rich_text"] as? [String: Any])?["equals"] as? String, "12D54CB4")
    }
}
