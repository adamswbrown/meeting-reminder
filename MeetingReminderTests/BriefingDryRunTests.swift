import XCTest
@testable import MeetingReminder

/// Opt-in DRY RUN of the real fallback briefing pipeline.
///
/// Runs the production retrieval and generation code against a real meeting and
/// prints what *would* be written — it performs no Notion write, no Slack post
/// and no Todoist create. Every call it makes is a read, plus the model request.
///
/// Skipped unless BRIEFING_DRY_RUN=1, so it never runs in the ordinary suite.
final class BriefingDryRunTests: XCTestCase {
    func testDryRunRealMeeting() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BRIEFING_DRY_RUN"] == "1" else { throw XCTSkip("Opt-in dry run") }
        let title = try XCTUnwrap(env["DRY_TITLE"])
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: try XCTUnwrap(env["DRY_START"])))
        let attendees = (env["DRY_ATTENDEES"] ?? "").components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let shortcut = env["DRY_SHORTCUT"] ?? ""

        let meeting = MeetingEvent(
            id: "dry-run", title: title, startDate: start, endDate: start.addingTimeInterval(1800),
            calendar: "Calendar", attendees: attendees,
            externalID: env["DRY_APPLE_ID"], isRecurring: false)

        let log = FileManager.default.temporaryDirectory.appendingPathComponent("dry-run.log").path
        let notion = try BriefingNotionRepository.live(logPath: log)

        // Real retrieval: mapping rules, partner ladder, prior notes, prior briefs, Teams.
        let clock = Date()
        let context = await BriefingFallbackProviders.context(meeting: meeting, notion: notion)
        let retrieval = Date().timeIntervalSince(clock)

        var out = ["", String(repeating: "=", count: 78),
                   "DRY RUN — nothing is written. Reads and one model call only.",
                   String(repeating: "=", count: 78), "",
                   "MEETING: \(title)", "START:   \(start)", "ATTENDEES: \(attendees.count)", "",
                   "--- RETRIEVAL (\(String(format: "%.1f", retrieval))s) ---"]
        out += context.coverage.map { "  • \($0)" }
        out.append("")
        out.append("--- EVIDENCE GATHERED ---")
        out += context.evidence.map { "  [\($0.id)] \($0.source) — \($0.text.count) chars" }
        if let m = context.metadata {
            out += ["", "--- CLASSIFICATION ---",
                    "  Partner:      \(m.partner ?? "(none)")\(m.partnerByInference ? " (inferred)" : "")",
                    "  Stage:        \(m.stage ?? "(none)")",
                    "  Key meeting:  \(m.isKeyMeeting)",
                    "  Prior notes:  \(m.priorPageIDs.count)",
                    "  Open actions: \(m.openActions.count)"]
            out += m.openActions.map { "     - \($0.text) (\($0.actionID))" }
        }

        // Real generation through the configured shortcut (PCC) or on-device.
        let genClock = Date()
        let (draft, provider, used) = try await BriefingFallbackProviders.generate(
            context: context, shortcut: shortcut)
        let generation = Date().timeIntervalSince(genClock)

        out += ["", String(repeating: "-", count: 78),
                "PROVIDER: \(provider)   (\(String(format: "%.1f", generation))s)",
                String(repeating: "-", count: 78), "",
                "SUMMARY (\(draft.summary.count) chars):", "", draft.summary, "",
                "PREPARATION:"]
        out += draft.preparation.map { "  • \($0)" }

        // Render what would have been persisted / delivered.
        var job = BriefingFallbackJob(meeting: meeting)
        job.draft = draft; job.provider = provider; job.context = used
        job.pageURL = "(no page — dry run)"
        let section = BriefingNotionRepository.section(
            marker: job.fallbackMarker, heading: "Fallback briefing — \(provider)",
            draft: draft, context: used)
        let children = ((section["toggle"] as? [String: Any])?["children"] as? [[String: Any]]) ?? []
        out += ["", String(repeating: "-", count: 78), "WOULD WRITE TO NOTION (not written)",
                String(repeating: "-", count: 78),
                "  Toggle: \(job.fallbackMarker)"]
        out += children.map { block in
            let type = block["type"] as? String ?? "?"
            return "    <\(type)> \(BriefingNotionRepository.blockText(block).prefix(110))"
        }
        out += ["", String(repeating: "-", count: 78), "WOULD POST TO SLACK (not posted)",
                String(repeating: "-", count: 78), "",
                BriefingDeliveryService.alertText(job: job, context: used), ""]
        let tasks = used.metadata?.openActions ?? []
        out += [String(repeating: "-", count: 78),
                "WOULD CREATE IN TODOIST (not created): \(tasks.count)",
                String(repeating: "-", count: 78)]
        out += tasks.map { "  • [\(used.metadata?.partner ?? "")] \($0.text) — ID: \($0.actionID)" }
        out += ["", "END OF DRY RUN — no Notion page, Slack message or Todoist task was created.", ""]

        // The exact bytes handed to the Shortcut, so the contract can be inspected
        // rather than inferred from the code. NOTE: for a real meeting this contains
        // real content — attendee addresses, Notion page text and Teams transcripts.
        // It is the same payload the cloud route sends to Apple; treat the file
        // accordingly and delete it when you are done.
        let shortcutInput = BriefingDraft.instructions + "\n" + used.prompt(evidenceCharacters: 24000)
        try shortcutInput.write(toFile: "/tmp/pcc-shortcut-input.txt", atomically: true, encoding: .utf8)
        out += ["", "Shortcut input written to /tmp/pcc-shortcut-input.txt (\(shortcutInput.utf8.count) bytes)"]

        let text = out.joined(separator: "\n")
        print(text)
        try text.write(toFile: "/tmp/pcc-dry-run.txt", atomically: true, encoding: .utf8)
        XCTAssertFalse(draft.summary.isEmpty)
    }
}
