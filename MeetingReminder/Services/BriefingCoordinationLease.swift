import Foundation

/// Advisory cross-runner lease for "who is briefing this occurrence".
///
/// Two independent processes can create a Pre-Call Briefing page for the same
/// meeting: this app's fallback path, and the scheduled Co Work runner. Neither
/// can see the other's memory, so the only shared medium is Notion itself. The
/// lease lives in a `Briefing Lock` rich-text property on the occurrence's
/// **Calendar Events** row — a row both runners already read, keyed by the same
/// composite Apple Event ID the sync upserts on.
///
/// Notion offers no compare-and-swap, so this is *advisory*: claim, then re-read
/// after a settle delay and confirm the claim survived. A concurrent claimant
/// overwrites us and we see it on the re-read, so the loser backs off instead of
/// generating. That closes the window from "the whole generation run" (30–90s)
/// down to the settle delay, and it degrades safely — a missing row, a missing
/// column or an unreachable Notion yields `.unavailable`, on which the caller
/// falls back to the pre-existing check-then-act guard rather than blocking.
///
/// **The other half of this protocol is not in this repo.** The scheduled runner
/// must perform the same claim before it writes a briefing page, and honour a
/// lease held by `meeting-reminder`. Until that lands, this side still helps
/// (the app defers to the runner) but the race is only narrowed, not eliminated.
/// See docs/plans/2026-09-15-local-briefing-fallback-design.md.
struct BriefingLease: Equatable {
    /// Stable owner identifiers. Renaming one silently breaks mutual exclusion.
    static let appOwner = "meeting-reminder"
    static let scheduledOwner = "co-work"

    var owner: String
    var jobID: String
    var expiresAt: Date

    /// `owner|jobID|ISO8601` — deliberately flat text so the scheduled runner can
    /// read and write it with a one-line split, no schema coupling.
    var serialised: String { "\(owner)|\(jobID)|\(BriefingLease.iso.string(from: expiresAt))" }

    static func parse(_ text: String) -> Self? {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              let expires = iso.date(from: parts[2]) else { return nil }
        return Self(owner: parts[0], jobID: parts[1], expiresAt: expires)
    }

    func isHeld(by owner: String, jobID: String, now: Date = Date()) -> Bool {
        self.owner == owner && self.jobID == jobID && expiresAt > now
    }
    func blocks(owner: String, jobID: String, now: Date = Date()) -> Bool {
        expiresAt > now && !isHeld(by: owner, jobID: jobID, now: now)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
}

enum BriefingLeaseOutcome: Equatable {
    /// We hold the lease and may generate and write.
    case acquired
    /// Another runner holds an unexpired lease. Back off; do not write.
    case heldByOther(String)
    /// No lease could be taken (no Calendar Events row, no column, Notion error).
    /// Callers proceed on the weaker check-then-act guard and record the reason.
    case unavailable(String)
}

extension BriefingNotionRepository {
    static let lockProperty = "Briefing Lock"
    /// Long enough to cover the 90s Shortcuts timeout plus Notion writes and
    /// retries; short enough that a crashed run frees the occurrence well
    /// inside the briefing's useful life.
    static let leaseDuration: TimeInterval = 600
    /// Notion is read-after-write consistent for a page GET, but two claims can
    /// still interleave. Re-reading after a settle delay is what detects that.
    static let leaseSettleDelay: TimeInterval = 2

    /// The Calendar Events "Apple Event ID" for this occurrence — the same key
    /// `CalendarEventMapper.compositeAppleID` writes, recomputed here because
    /// `MeetingEvent` is not an `EventLike`.
    static func appleEventID(for meeting: MeetingEvent) -> String? {
        guard let external = meeting.externalID, !external.isEmpty else { return nil }
        guard meeting.isRecurring else { return external }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(external)_\(formatter.string(from: meeting.startDate))"
    }

    /// Finds the Calendar Events row carrying this occurrence's lease, if any.
    func calendarEventRow(_ meeting: MeetingEvent) async throws -> (id: String, lock: BriefingLease?)? {
        guard let appleID = Self.appleEventID(for: meeting) else { return nil }
        let response = try await client.post(
            path: "/data_sources/\(CalendarSyncConstants.calendarEventsDataSourceID)/query",
            body: ["page_size": 2, "filter": ["property": "Apple Event ID", "rich_text": ["equals": appleID]]])
        let rows = response["results"] as? [[String: Any]] ?? []
        // Duplicate rows mean the sync's own identity is ambiguous; refuse to
        // lock rather than pick one and let the other runner lock the twin.
        guard rows.count == 1, let row = rows.first, let id = row["id"] as? String else { return nil }
        let properties = row["properties"] as? [String: Any] ?? [:]
        let text = ((properties[Self.lockProperty] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? [])
            .map { $0["plain_text"] as? String ?? (($0["text"] as? [String: Any])?["content"] as? String ?? "") }
            .joined()
        return (id, BriefingLease.parse(text))
    }

    /// Claim-then-verify. Never overwrites a live foreign lease.
    func claimLease(_ meeting: MeetingEvent, jobID: String,
                    settle: TimeInterval = BriefingNotionRepository.leaseSettleDelay,
                    now: Date = Date()) async -> BriefingLeaseOutcome {
        do {
            guard let row = try await calendarEventRow(meeting) else {
                return .unavailable("No unique Calendar Events row for this occurrence; no cross-runner lease taken.")
            }
            if let lock = row.lock, lock.blocks(owner: BriefingLease.appOwner, jobID: jobID, now: now) {
                return .heldByOther(lock.owner)
            }
            let claim = BriefingLease(owner: BriefingLease.appOwner, jobID: jobID,
                                      expiresAt: now.addingTimeInterval(Self.leaseDuration))
            try await writeLock(row.id, text: claim.serialised)
            if settle > 0 { try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
            // Re-read: a claim that raced ours has overwritten the property.
            guard let confirmed = try await calendarEventRow(meeting)?.lock else {
                return .unavailable("Briefing Lock could not be read back; no cross-runner lease taken.")
            }
            if confirmed.isHeld(by: BriefingLease.appOwner, jobID: jobID, now: now) { return .acquired }
            return .heldByOther(confirmed.owner)
        } catch {
            // A lock failure must never abort a briefing; it only weakens the guard.
            return .unavailable("Briefing Lock unavailable; relying on the pre-write page check only.")
        }
    }

    /// Clears our own lease. A foreign or expired lease is left untouched.
    func releaseLease(_ meeting: MeetingEvent, jobID: String) async {
        guard let row = try? await calendarEventRow(meeting), let lock = row.lock,
              lock.isHeld(by: BriefingLease.appOwner, jobID: jobID) else { return }
        try? await writeLock(row.id, text: "")
    }

    private func writeLock(_ pageID: String, text: String) async throws {
        _ = try await client.patch(path: "/pages/\(pageID)",
            body: ["properties": [Self.lockProperty: ["rich_text": text.isEmpty ? [] : Self.rich(text)]]])
    }
}
