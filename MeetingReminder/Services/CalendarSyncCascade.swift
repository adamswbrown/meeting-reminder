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
    /// in `_YYYY-MM-DD` or contains `/RID=`. Such an ID disappears when the
    /// occurrence is *edited* as well as when it is cancelled, so it only
    /// cascades once `OccurrenceProbe` has told the two apart.
    /// Mirrors the intraday skill's Step 5 rule.
    static func isRecurringAppleID(_ id: String) -> Bool {
        if id.contains("/RID=") { return true }
        return id.range(of: "_[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    }

    /// Whether a recurring occurrence that vanished from a windowed fetch was
    /// cancelled or merely detached (edited / moved). See
    /// `CalendarSyncReader.probeOccurrence` and `hasLiveDetachedSibling`.
    enum OccurrenceProbe: Equatable {
        /// No live detached sibling claims that occurrence date — a cancellation.
        case confirmedGone
        /// A detached occurrence still anchored to that date is alive, so the
        /// occurrence was edited or moved, not cancelled. Defer to the full run.
        case unresolved
    }

    /// Decodes a *detached* occurrence's identifier, `<seriesUID>/RID=<n>`,
    /// where `n` is seconds since the reference date (2001-01-01) of the
    /// occurrence's **original** start — i.e. its `occurrenceDate`. Verified
    /// against live Exchange data: `…/RID=811848600` ⇒ 2026-09-23T09:30:00Z.
    ///
    /// Tolerates a trailing `_YYYY-MM-DD` (present if such an event ever
    /// reported itself as recurring, so `compositeAppleID` appended a day).
    static func detachedOccurrence(fromID id: String) -> (seriesUID: String, originalStart: Date)? {
        var work = id
        if let day = work.range(of: "_[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) {
            work.removeSubrange(day)
        }
        guard let marker = work.range(of: "/RID=") else { return nil }
        let uid = String(work[work.startIndex..<marker.lowerBound])
        let digits = String(work[marker.upperBound...])
        guard !uid.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let seconds = Double(digits) else { return nil }
        return (uid, Date(timeIntervalSinceReferenceDate: seconds))
    }

    /// True when `orphanID` (`<uid>_<YYYY-MM-DD>`) still has a live **detached**
    /// sibling among `ids` — the IDs this run actually saw on the calendar.
    ///
    /// This is the signal that matters. When an organiser edits a single
    /// occurrence, Exchange detaches it and its external identifier changes to
    /// the `/RID=` form, so the generated occurrence's original composite ID
    /// orphans while the meeting is very much alive under a new ID. Both rows
    /// are visible in Notion (verified 2026-09-17: `D3C55E60…_2026-09-23`
    /// orphaned alongside a live `D3C55E60…/RID=811848600`), and marking the
    /// ghost Cancelled is wrong.
    static func hasLiveDetachedSibling(orphanID: String, among ids: Set<String>) -> Bool {
        guard let orphan = splitOccurrenceAppleID(orphanID) else { return false }
        for id in ids {
            guard let sibling = detachedOccurrence(fromID: id),
                  sibling.seriesUID == orphan.externalID else { continue }
            if CalendarEventMapper.londonDayString(for: sibling.originalStart) == orphan.day {
                return true
            }
        }
        return false
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
                                      cascadeEnabled: Bool,
                                      archiveEnabled: Bool,
                                      occurrenceProbe: OccurrenceProbe = .unresolved) -> Disappearance {
        let noop = Disappearance(syncState: nil, rowStatus: nil,
                                 cascadeBriefCancelled: false, skip: true)
        // Neither behaviour enabled → nothing to do.
        guard cascadeEnabled || archiveEnabled else { return noop }
        // A recurring occurrence also vanishes when it is merely *detached*
        // (edited), because detaching changes its external identifier — the old
        // composite ID orphans while the meeting is alive under a new one. Only
        // cascade once `probeOccurrence` has ruled a live detached sibling out.
        // This applies in EVERY mode: the daily full run shared this blind spot
        // and had been stamping such ghost rows Cancelled since long before the
        // reactive path existed (e.g. D3C55E60…_2026-09-09 on 2026-08-10).
        if isRecurring && occurrenceProbe != .confirmedGone { return noop }

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
