import Foundation

/// Remembers every Apple Event ID a single sync run has already written to, so
/// the run can never create a second Notion row for an ID it just handled.
///
/// `CalendarSyncUpserter` resolves create-vs-update against `existing`, a
/// snapshot of Notion taken once at run start. Rows the run creates itself are
/// absent from that snapshot, so a repeated Apple Event ID — the same event
/// reached twice through the input, or a run working from a snapshot another
/// writer has already moved past — fell through to CREATE a second time. That
/// is how the *Weekly Cadence Dr Migrate UK/Europe* series ended up with five
/// duplicated rows on 2026-06-30.
///
/// Deliberately a plain value type with no I/O: the decision is pure, so it is
/// unit-testable without a Notion client (see `CalendarSyncRunRegistryTests`).
struct CalendarSyncRunRegistry {
    private var pageIDsByAppleID: [String: String] = [:]

    /// Records the page an Apple Event ID resolved to this run. First write
    /// wins, mirroring `fetchExistingEvents`, which keeps the first-seen row as
    /// canonical — so a run that meets a duplicate keeps writing to one page
    /// instead of alternating between two.
    mutating func register(appleID: String, pageID: String) {
        guard !appleID.isEmpty, !pageID.isEmpty else { return }
        guard pageIDsByAppleID[appleID] == nil else { return }
        pageIDsByAppleID[appleID] = pageID
    }

    /// The page this run has already written for `appleID`, or nil if the run
    /// has not touched it yet.
    func pageID(for appleID: String) -> String? {
        guard !appleID.isEmpty else { return nil }
        return pageIDsByAppleID[appleID]
    }
}
