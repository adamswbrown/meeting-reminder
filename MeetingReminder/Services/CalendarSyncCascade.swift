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
}
