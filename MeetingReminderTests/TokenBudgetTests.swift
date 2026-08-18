import XCTest
@testable import MeetingReminder

final class TokenBudgetTests: XCTestCase {

    // MARK: TokenBudget arithmetic

    func testInputCeilingReservesInstructionsAndOutput() {
        XCTAssertEqual(TokenBudget.inputCeiling, 4096 - 100 - 500)
    }

    func testEstimateOverEstimatesVersusMeasuredRatio() {
        // Measured real ratio was 4.07 chars/token; our estimator uses 3.5, so it must
        // report MORE tokens than reality for the same string (conservative).
        let s = String(repeating: "a", count: 4070)   // ≈ 1000 real tokens
        let realish = Int(ceil(4070.0 / 4.07))
        XCTAssertGreaterThan(TokenBudget.estimate(s), realish)
    }

    func testFitsBoundary() {
        let atCeiling = String(repeating: "x", count: TokenBudget.inputCeiling * 3)      // 3 c/tok < 3.5 ⇒ fits
        XCTAssertTrue(TokenBudget.fits(atCeiling))
        let tooBig = String(repeating: "x", count: (TokenBudget.inputCeiling + 200) * 4) // 4 c/tok ⇒ over
        XCTAssertFalse(TokenBudget.fits(tooBig))
    }

    // MARK: truncateWords

    func testTruncateWordsBreaksOnWordBoundary() {
        let out = IntradayBriefContext.truncateWords("the quick brown fox jumps", 12)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertFalse(out.contains("bro"), "should not cut mid-word: \(out)")
        XCTAssertTrue(out.hasPrefix("the quick"))
    }

    func testTruncateWordsShortStringUnchanged() {
        XCTAssertEqual(IntradayBriefContext.truncateWords("hello", 50), "hello")
    }

    // MARK: render() always fits the window

    private func ctx(notes: String?) -> IntradayBriefContext {
        IntradayBriefContext(
            title: "Advisory / Ask Adam — Northwind Traders (migration strategy)",
            startLondon: "2026-08-17 15:30", endLondon: "2026-08-17 16:00",
            video: "teams.microsoft.com",
            attendees: ["Sarah Whitcombe (sarah@northwind.com, Head of Infra)", "Adam Brown (host)"],
            priorNotesSnippet: notes)
    }

    func testRenderTypicalContextFits() {
        let s = ctx(notes: "Discovery kicked off; ~400 VMs, SQL 2012 blocker; wants wave plan.").render()
        XCTAssertTrue(TokenBudget.fits(s))
        XCTAssertTrue(s.contains("Northwind Traders"))
        XCTAssertTrue(s.contains("SQL 2012"))
    }

    func testRenderPathologicalNotesStillFits() {
        // A pasted 40k-char transcript must NOT blow the window — degrade ladder caps it.
        let huge = String(repeating: "lorem ipsum dolor sit amet ", count: 2000) // ~54k chars
        let s = ctx(notes: huge).render()
        XCTAssertTrue(TokenBudget.fits(s), "render must always fit 4K; got \(TokenBudget.estimate(s)) tok")
        XCTAssertTrue(s.contains("Northwind Traders"), "identity must survive degrade")
    }

    func testRenderMinimalDropsNotesButKeepsIdentity() {
        let s = ctx(notes: "some notes").renderMinimal()
        XCTAssertFalse(s.contains("PRIOR CONTEXT"))
        XCTAssertTrue(s.contains("Advisory / Ask Adam"))
        XCTAssertTrue(s.contains("Sarah Whitcombe"))
    }

    func testAttendeesCappedAtSix() {
        let many = (1...20).map { "Person \($0) (p\($0)@x.com)" }
        let c = IntradayBriefContext(title: "T", startLondon: "a", endLondon: "b",
                                     video: nil, attendees: many, priorNotesSnippet: nil)
        let lines = c.render().split(separator: "\n").filter { $0.hasPrefix("- Person") }
        XCTAssertEqual(lines.count, IntradayContextCaps.maxAttendees)
    }
}
