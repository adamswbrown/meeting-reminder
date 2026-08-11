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
    /// EventKit when *moved* (not cancelled), so they are excluded from the
    /// reactive cancel cascade. Mirrors the intraday skill's Step 5 rule.
    static func isRecurringAppleID(_ id: String) -> Bool {
        if id.contains("/RID=") { return true }
        return id.range(of: "_[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
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

    static func classifyDisappearance(hasManualRelations: Bool,
                                      isRecurring: Bool,
                                      isReactive: Bool,
                                      cascadeEnabled: Bool,
                                      archiveEnabled: Bool) -> Disappearance {
        let noop = Disappearance(syncState: nil, rowStatus: nil,
                                 cascadeBriefCancelled: false, skip: true)
        // Neither behaviour enabled → nothing to do.
        guard cascadeEnabled || archiveEnabled else { return noop }
        // A moved recurring occurrence vanishes from EventKit without being
        // cancelled; the reactive window can't disambiguate, so defer to the
        // daily full run.
        if isReactive && isRecurring { return noop }

        // A row carrying manual work is marked Stale, never Cancelled.
        if hasManualRelations {
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
