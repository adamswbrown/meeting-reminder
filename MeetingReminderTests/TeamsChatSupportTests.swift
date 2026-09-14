import XCTest
@testable import MeetingReminder

final class TeamsChatSupportTests: XCTestCase {
    func testScopesFromAccessToken() {
        // header.payload.sig with payload {"scp":"Chat.ReadWrite Mail.Send"}
        let payload = Data(#"{"scp":"Chat.ReadWrite Mail.Send"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJub25lIn0.\(payload).sig"
        let scopes = TeamsChatSupport.scopes(fromAccessToken: token)
        XCTAssertEqual(scopes, ["Chat.ReadWrite", "Mail.Send"])
        XCTAssertTrue(TeamsChatSupport.canReadChats(scopes: scopes))
        XCTAssertFalse(TeamsChatSupport.canReadChats(scopes: ["Mail.Send"]))
        XCTAssertEqual(TeamsChatSupport.scopes(fromAccessToken: "garbage"), [])
    }

    func testBuildDirectoryExcludesSelfAndPrefersOneOnOne() {
        let chats: [[String: Any]] = [
            ["id": "grp", "chatType": "group", "topic": "Project X", "lastUpdatedDateTime": "2026-09-13T10:00:00Z",
             "members": [["email": "Adam.Brown@altra.cloud"], ["email": "sam@example.com"], ["email": "lee@example.com"]]],
            ["id": "one", "chatType": "oneOnOne", "lastUpdatedDateTime": "2026-09-01T10:00:00Z",
             "members": [["email": "adam.brown@altra.cloud"], ["email": "SAM@example.com"]]],
            ["id": "nomembers", "chatType": "oneOnOne"],
        ]
        let dir = TeamsChatSupport.buildDirectory(chats: chats, selfEmail: "adam.brown@altra.cloud")
        XCTAssertNil(dir.byEmail["adam.brown@altra.cloud"])
        XCTAssertEqual(dir.byEmail["sam@example.com"]?.map(\.chatID), ["one", "grp"])
        XCTAssertEqual(dir.byEmail["lee@example.com"]?.map(\.chatID), ["grp"])
        XCTAssertFalse(dir.isStale)
    }

    func testDirectoryStaleAfterADay() {
        let dir = TeamsChatDirectory(fetchedAt: Date().addingTimeInterval(-25 * 3600), byEmail: [:])
        XCTAssertTrue(dir.isStale)
    }

    func testParseMessagesStripsHTMLAndDropsSystemEvents() {
        let results: [[String: Any]] = [
            ["id": "2", "messageType": "message", "createdDateTime": "2026-09-14T09:00:00.5Z",
             "from": ["user": ["displayName": "Sam"]],
             "body": ["contentType": "html", "content": "<p>Hi <at id=\"0\">Adam</at>,&nbsp;see <b>this</b></p><p>Line two</p><img src=\"x\">"]],
            ["id": "1", "messageType": "message", "createdDateTime": "2026-09-13T09:00:00Z",
             "from": ["user": ["displayName": "Adam"]],
             "body": ["contentType": "text", "content": "first"]],
            ["id": "sys", "messageType": "systemEventMessage", "createdDateTime": "2026-09-13T08:00:00Z",
             "body": ["contentType": "html", "content": "<systemEventMessage/>"]],
            ["id": "empty", "messageType": "message", "createdDateTime": "2026-09-13T07:00:00Z",
             "body": ["contentType": "html", "content": "<p> </p>"]],
            ["id": "deleted", "messageType": "message", "createdDateTime": "2026-09-13T07:00:00Z",
             "deletedDateTime": "2026-09-13T07:30:00Z", "body": ["contentType": "text", "content": "gone"]],
        ]
        let msgs = TeamsChatSupport.parseMessages(results)
        XCTAssertEqual(msgs.map(\.id), ["1", "2"])  // sorted ascending by time
        XCTAssertEqual(msgs[1].from, "Sam")
        XCTAssertEqual(msgs[1].text, "Hi Adam, see this\nLine two\n[image]")
    }

    func testStripHTMLEntitiesAndBlankLines() {
        let out = TeamsChatSupport.stripHTML("<div>a &amp; b</div><div></div><div></div><div>c &lt;d&gt;</div>")
        XCTAssertEqual(out, "a & b\n\nc <d>")
    }

    func testRecentFiltersByAgeAndLimit() {
        let now = Date()
        let mk = { (id: String, daysAgo: Double) in
            TeamsChatMessage(id: id, from: "x", sentAt: now.addingTimeInterval(-daysAgo * 86400), text: id)
        }
        let msgs = [mk("old", 30), mk("a", 5), mk("b", 3), mk("c", 1)]
        XCTAssertEqual(TeamsChatSupport.recent(msgs, days: 14, limit: 2, now: now).map(\.id), ["b", "c"])
        XCTAssertEqual(TeamsChatSupport.recent(msgs, days: 14, limit: 10, now: now).map(\.id), ["a", "b", "c"])
    }
}
