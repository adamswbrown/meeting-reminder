import XCTest
@testable import MeetingReminder

final class NotionPriorNotesReaderTests: XCTestCase {

    private func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }

    // MARK: startDate

    func testStartDateParsesDateTime() {
        let prop: [String: Any] = ["date": ["start": "2026-08-10T14:30:00Z"]]
        XCTAssertEqual(NotionPriorNotesReader.startDate(prop), iso("2026-08-10T14:30:00Z"))
    }

    func testStartDateParsesDateOnly() {
        let prop: [String: Any] = ["date": ["start": "2026-08-10"]]
        XCTAssertNotNil(NotionPriorNotesReader.startDate(prop))
    }

    func testStartDateNilOnGarbage() {
        XCTAssertNil(NotionPriorNotesReader.startDate(["date": ["start": "nope"]]))
        XCTAssertNil(NotionPriorNotesReader.startDate(nil))
        XCTAssertNil(NotionPriorNotesReader.startDate(["foo": 1]))
    }

    // MARK: newestPriorPageID

    private func row(_ id: String, _ start: String) -> [String: Any] {
        ["id": id, "properties": ["Start": ["date": ["start": start]]]]
    }

    func testPicksNewestRowStrictlyBeforeCutoff() {
        let rows = [row("a", "2026-08-01T09:00:00Z"),
                    row("b", "2026-08-14T09:00:00Z"),   // newest prior
                    row("c", "2026-09-01T09:00:00Z")]   // in the future — excluded
        let id = NotionPriorNotesReader.newestPriorPageID(rows: rows, before: iso("2026-08-17T09:00:00Z"))
        XCTAssertEqual(id, "b")
    }

    func testReturnsNilWhenAllRowsAreAfterCutoff() {
        let rows = [row("c", "2026-09-01T09:00:00Z")]
        XCTAssertNil(NotionPriorNotesReader.newestPriorPageID(rows: rows, before: iso("2026-08-17T09:00:00Z")))
    }

    func testIgnoresRowsMissingDate() {
        let rows: [[String: Any]] = [["id": "x", "properties": [:]], row("b", "2026-08-14T09:00:00Z")]
        XCTAssertEqual(NotionPriorNotesReader.newestPriorPageID(rows: rows, before: iso("2026-08-17T09:00:00Z")), "b")
    }

    // MARK: extractPlainText

    private func para(_ text: String) -> [String: Any] {
        ["type": "paragraph", "paragraph": ["rich_text": [["plain_text": text]]]]
    }
    private func bullet(_ text: String) -> [String: Any] {
        ["type": "bulleted_list_item", "bulleted_list_item": ["rich_text": [["plain_text": text]]]]
    }

    func testExtractsParagraphsAndBullets() {
        let blocks = [para("Discovery kicked off."), bullet("Send rightsizing export"), bullet("Confirm SQL owner")]
        let out = NotionPriorNotesReader.extractPlainText(fromBlocks: blocks, maxChars: 1000)
        XCTAssertEqual(out, "Discovery kicked off.\n• Send rightsizing export\n• Confirm SQL owner")
    }

    func testSkipsEmptyAndUnknownBlocks() {
        let blocks: [[String: Any]] = [
            para("Real line."),
            ["type": "divider", "divider": [:]],
            ["type": "image", "image": ["file": ["url": "x"]]],
            para("  "),  // whitespace only
        ]
        XCTAssertEqual(NotionPriorNotesReader.extractPlainText(fromBlocks: blocks, maxChars: 1000), "Real line.")
    }

    func testCapsAtMaxCharsOnWordBoundary() {
        let long = String(repeating: "word ", count: 500)   // 2500 chars
        let out = NotionPriorNotesReader.extractPlainText(fromBlocks: [para(long)], maxChars: 100)
        XCTAssertLessThanOrEqual(out.count, 103)  // 100 + " …"
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertFalse(out.contains("wor\n"))
    }

    func testEmptyBlocksReturnEmpty() {
        XCTAssertEqual(NotionPriorNotesReader.extractPlainText(fromBlocks: [], maxChars: 100), "")
    }
}
