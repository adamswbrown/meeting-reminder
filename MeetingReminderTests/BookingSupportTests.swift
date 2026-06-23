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
}
