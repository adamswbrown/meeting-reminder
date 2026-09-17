import Foundation

/// Pure decision logic for cascading calendar status changes into Notion.
/// Extracted so the branching is unit-testable without a live Notion client.
/// See docs/plans/2026-08-11-calendar-status-cascade-to-notion-design.md
enum CalendarSyncCascade {

    /// First related page ID from a Notion relation property payload
    /// (read-format `{"relation":[{"id":"..."}]}`), or nil.
    static func briefPageID(fromRelation any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let arr = dict["relation"] as? [[String: Any]],
              let first = arr.first,
              let id = first["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// True when an Apple Event ID represents a recurring occurrence — it ends
    /// in `_YYYY-MM-DD` or contains `/RID=`. Recurring occurrences vanish from
    /// EventKit when *moved* as well as when cancelled, so a reactive run only
    /// cascades one when `OccurrenceProbe` can tell the two apart.
    /// Mirrors the intraday skill's Step 5 rule.
    static func isRecurringAppleID(_ id: String) -> Bool {
        if id.contains("/RID=") { return true }
        return id.range(of: "_[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    }

    /// What EventKit says about a recurring occurrence that has vanished from a
    /// windowed fetch. See `CalendarSyncReader.probeOccurrence`.
    enum OccurrenceProbe: Equatable {
        /// The series is still there and nothing claims that occurrence date any
        /// more — EventKit holds an exception for it, i.e. a real cancellation.
        case confirmedGone
        /// Either something still claims the date (a detached occurrence: a
        /// *move*, not a cancellation) or the lookup gave no evidence at all.
        /// Both defer to the daily full run rather than guess.
        case unresolved
    }

    /// Splits a recurring-occurrence Apple Event ID (`<externalID>_<YYYY-MM-DD>`)
    /// into the series' external identifier and the occurrence's Europe/London
    /// day. Returns nil for anything else — a series master, a non-recurring ID,
    /// or the legacy `/RID=` form — none of which the probe can resolve.
    static func splitOccurrenceAppleID(_ id: String) -> (externalID: String, day: String)? {
        guard !id.contains("/RID="),
              let r = id.range(of: "_[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression)
        else { return nil }
        let base = String(id[id.startIndex..<r.lowerBound])
        guard !base.isEmpty else { return nil }
        return (base, String(id[r].dropFirst()))
    }

    /// Decision for a row whose event has disappeared from the calendar
    /// (already filtered to in-window, not-touched by the caller).
    struct Disappearance {
        /// Target `Sync State` select, or nil to leave unchanged.
        let syncState: String?
        /// Target `Status` select (only "Cancelled"), or nil to leave unchanged.
        let rowStatus: String?
        /// Whether to PATCH the linked brief's Meeting Outcome = Cancelled.
        let cascadeBriefCancelled: Bool
        /// Whether the caller should do nothing for this row.
        let skip: Bool
    }

    /// `hasMeetingNotes` is the ONLY manual-work signal. A linked Pre-Call Briefing
    /// is machine-generated and is the thing the cascade updates, so it must not
    /// count as manual work — otherwise every briefed meeting goes Stale and the
    /// brief's Meeting Outcome is never set (design doc §4: "a row with Meeting
    /// Notes populated stays Stale").
    static func classifyDisappearance(hasMeetingNotes: Bool,
                                      isRecurring: Bool,
                                      isReactive: Bool,
                                      cascadeEnabled: Bool,
                                      archiveEnabled: Bool,
                                      occurrenceProbe: OccurrenceProbe = .unresolved) -> Disappearance {
        let noop = Disappearance(syncState: nil, rowStatus: nil,
                                 cascadeBriefCancelled: false, skip: true)
        // Neither behaviour enabled → nothing to do.
        guard cascadeEnabled || archiveEnabled else { return noop }
        // A moved recurring occurrence vanishes from EventKit without being
        // cancelled, and the reactive *window* can't tell that from a real
        // cancellation. Asking EventKit directly can (`probeOccurrence`): with a
        // confirmed exception we cascade immediately, otherwise defer to the
        // daily full run.
        if isReactive && isRecurring && occurrenceProbe != .confirmedGone { return noop }

        // A row carrying manual work (Meeting Notes) is marked Stale, never Cancelled.
        if hasMeetingNotes {
            return Disappearance(syncState: "Stale", rowStatus: nil,
                                 cascadeBriefCancelled: false, skip: false)
        }
        // A clean disappearance: Orphaned always; Cancelled + brief cascade
        // only when the cascade behaviour is enabled.
        return Disappearance(syncState: "Orphaned",
                             rowStatus: cascadeEnabled ? "Cancelled" : nil,
                             cascadeBriefCancelled: cascadeEnabled,
                             skip: false)
    }

    /// True when a Notion `Status` property payload (read-format
    /// `{"select":{"name":"..."}}`) currently reads "Cancelled". Used to make
    /// the cancel cascade transition-only (fire exactly once).
    static func isCancelledStatus(_ any: Any?) -> Bool {
        guard let dict = any as? [String: Any],
              let sel = dict["select"] as? [String: Any],
              let name = sel["name"] as? String else { return false }
        return name == "Cancelled"
    }

    /// True when a row's incoming start differs from what Notion currently has
    /// (both non-nil). Used to cascade a one-off move onto the linked brief.
    static func startChanged(incoming: Date, existing: Date?) -> Bool {
        guard let existing else { return false }
        return abs(incoming.timeIntervalSince(existing)) >= 60
    }
}
