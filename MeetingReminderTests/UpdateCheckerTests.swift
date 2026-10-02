import XCTest
@testable import MeetingReminder

final class UpdateCheckerTests: XCTestCase {
    func testNumericVersionOrdering() throws {
        let installed = try XCTUnwrap(ReleaseVersion("3.9.0"))
        XCTAssertTrue(try XCTUnwrap(ReleaseVersion("v3.10.0")).isNewer(than: installed))
        XCTAssertFalse(try XCTUnwrap(ReleaseVersion("3.8.9")).isNewer(than: installed))
        XCTAssertFalse(try XCTUnwrap(ReleaseVersion("3.9.0+build.12")).isNewer(than: installed))
        XCTAssertTrue(try XCTUnwrap(ReleaseVersion("4.0.0")).isNewer(than: installed))
        XCTAssertTrue(try XCTUnwrap(ReleaseVersion("3.9.1")).isNewer(than: installed))
    }

    func testStableReleaseIsNewerThanInstalledPrerelease() throws {
        XCTAssertTrue(try XCTUnwrap(ReleaseVersion("3.6.1")).isNewer(
            than: XCTUnwrap(ReleaseVersion("3.6.1-beta.1"))
        ))
    }

    func testInvalidVersionsAreRejected() {
        for version in ["Unknown", "", "release-latest", "3..1", "3.6", "3.6.1.2", "3.6.1-", "3.6.1+", "-3.6.1"] {
            XCTAssertNil(ReleaseVersion(version), version)
        }
    }

    @MainActor
    func testNewerReleaseAndUpstreamEndpoint() async {
        let checker = UpdateChecker(installedVersion: "3.6.0") { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/adamswbrown/meeting-reminder/releases/latest")
            return Self.response(tag: "v3.6.1")
        }
        await checker.check()
        XCTAssertEqual(checker.status, .updateAvailable("v3.6.1"))
        XCTAssertEqual(UpdateChecker.latestReleaseURL.absoluteString, "https://github.com/adamswbrown/meeting-reminder/releases/latest")
    }

    @MainActor
    func testEqualAndAheadVersionsAreUpToDate() async {
        for installed in ["3.6.1", "3.7.0"] {
            let checker = UpdateChecker(installedVersion: installed) { _ in Self.response(tag: "v3.6.1") }
            await checker.check()
            XCTAssertEqual(checker.status, .upToDate)
        }
    }

    @MainActor
    func testFailedCheckCanBeRetried() async {
        var attempts = 0
        let checker = UpdateChecker(installedVersion: "3.6.0") { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return Self.response(tag: "v3.6.1")
        }
        await checker.check()
        XCTAssertEqual(checker.status, .failed)
        await checker.check()
        XCTAssertEqual(checker.status, .updateAvailable("v3.6.1"))
    }

    @MainActor
    func testSuccessfulChecksAreCachedAndManualChecksRefresh() async {
        var attempts = 0
        let checker = UpdateChecker(installedVersion: "3.6.1") { _ in
            attempts += 1
            return Self.response(tag: "v3.6.1")
        }
        await checker.check()
        await checker.check()
        XCTAssertEqual(attempts, 1)
        await checker.check(force: true)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testHTTPAndMalformedResponsesDoNotReportUpToDate() async {
        for code in [403, 404, 429, 500] {
            let checker = UpdateChecker(installedVersion: "3.6.1") { _ in
                Self.response(tag: "v3.6.1", code: code)
            }
            await checker.check()
            XCTAssertEqual(checker.status, .failed)
        }
        for payload in ["{}", "not JSON", #"{"tag_name":"latest","draft":false,"prerelease":false}"#,
                        #"{"tag_name":"v3.7.0","draft":true,"prerelease":false}"#,
                        #"{"tag_name":"v3.7.0-beta.1","draft":false,"prerelease":true}"#] {
            let checker = UpdateChecker(installedVersion: "3.6.1") { _ in
                (Data(payload.utf8), Self.response(tag: "v3.6.1").1)
            }
            await checker.check()
            XCTAssertEqual(checker.status, .failed)
        }
        let unknown = UpdateChecker(installedVersion: "Unknown") { _ in Self.response(tag: "v3.6.1") }
        await unknown.check()
        XCTAssertEqual(unknown.status, .failed)
    }

    private static func response(tag: String, code: Int = 200) -> (Data, URLResponse) {
        let data = Data("{\"tag_name\":\"\(tag)\",\"draft\":false,\"prerelease\":false}".utf8)
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: code, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
