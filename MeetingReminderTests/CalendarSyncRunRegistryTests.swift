import XCTest
@testable import MeetingReminder

/// The Calendar→Notion upsert resolves each Apple Event ID against a snapshot
/// of Notion taken once at run start. Rows the run creates itself were never in
/// that snapshot, so a repeated Apple Event ID used to fall through to the
/// CREATE branch a second time and mint a duplicate page. The registry closes
/// that gap by remembering what the run has already resolved.
final class CalendarSyncRunRegistryTests: XCTestCase {

    func testUnseenAppleIDResolvesToNil() {
        let registry = CalendarSyncRunRegistry()
        XCTAssertNil(registry.pageID(for: "EVENT-A"))
    }

    func testRegisteredAppleIDResolvesToItsPageID() {
        var registry = CalendarSyncRunRegistry()
        registry.register(appleID: "EVENT-A", pageID: "page-1")
        XCTAssertEqual(registry.pageID(for: "EVENT-A"), "page-1")
    }

    func testDistinctAppleIDsDoNotCollide() {
        var registry = CalendarSyncRunRegistry()
        registry.register(appleID: "EVENT-A", pageID: "page-1")
        registry.register(appleID: "EVENT-B", pageID: "page-2")
        XCTAssertEqual(registry.pageID(for: "EVENT-A"), "page-1")
        XCTAssertEqual(registry.pageID(for: "EVENT-B"), "page-2")
    }

    /// Mirrors `fetchExistingEvents`, which keeps the first-seen row as
    /// canonical. If a duplicate somehow reaches the registry, the run must
    /// keep writing to one page rather than ping-ponging between two.
    func testReRegisteringKeepsFirstPageID() {
        var registry = CalendarSyncRunRegistry()
        registry.register(appleID: "EVENT-A", pageID: "page-1")
        registry.register(appleID: "EVENT-A", pageID: "page-2")
        XCTAssertEqual(registry.pageID(for: "EVENT-A"), "page-1")
    }

    /// An empty external identifier is already rejected upstream; the registry
    /// must not turn it into a key that makes unrelated events collide.
    func testEmptyAppleIDIsNeverRegistered() {
        var registry = CalendarSyncRunRegistry()
        registry.register(appleID: "", pageID: "page-1")
        XCTAssertNil(registry.pageID(for: ""))
    }

    /// The upsert loop registers rows it UPDATES as well as rows it creates, so
    /// a duplicate of an already-existing row is also absorbed.
    func testRegistryAbsorbsRepeatOfAnExistingRow() {
        var registry = CalendarSyncRunRegistry()
        registry.register(appleID: "EVENT-A", pageID: "existing-page")
        XCTAssertEqual(registry.pageID(for: "EVENT-A"), "existing-page")
        XCTAssertNil(registry.pageID(for: "EVENT-UNSEEN"))
    }
}
