import EventKit
import Foundation
import SwiftUI

// MARK: - Notion HTTP client

struct CalendarSyncNotionError: Error, CustomStringConvertible {
    let status: Int
    let body: String
    var description: String { "Notion API \(status): \(body)" }
}

/// Thin wrapper over `URLSession` scoped to the calendar-sync feature.
/// Distinct from `NotionService` because this client is unrelated to the
/// user's create-meeting-page flow and uses a separately-scoped integration
/// token (different Notion access scope).
final class CalendarSyncNotionClient {
    private let token: String
    private let session: URLSession
    private let logger: CalendarSyncLogger

    init(token: String, logger: CalendarSyncLogger) {
        self.token = token
        self.logger = logger
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        try await request(method: "POST", path: path, body: body)
    }

    func patch(path: String, body: [String: Any]) async throws -> [String: Any] {
        try await request(method: "PATCH", path: path, body: body)
    }

    private func request(method: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        let url = URL(string: "https://api.notion.com/v1\(path)")!
        var attempt = 0
        var delay: UInt64 = 500_000_000 // 0.5s

        while true {
            attempt += 1
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(CalendarSyncConstants.notionVersion, forHTTPHeaderField: "Notion-Version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }

            let (data, resp): (Data, URLResponse)
            do {
                (data, resp) = try await session.data(for: req)
            } catch {
                if attempt < 3 {
                    logger.warn("network error \(error.localizedDescription), retrying (attempt \(attempt))")
                    try await Task.sleep(nanoseconds: delay)
                    delay *= 2
                    continue
                }
                throw error
            }

            guard let http = resp as? HTTPURLResponse else {
                throw CalendarSyncNotionError(status: -1, body: "non-http response")
            }
            if (200..<300).contains(http.statusCode) {
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            let retriable = [429, 502, 503, 504].contains(http.statusCode)
            if retriable && attempt < 3 {
                logger.warn("notion \(http.statusCode), retrying (attempt \(attempt))")
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            }
            throw CalendarSyncNotionError(status: http.statusCode, body: bodyStr)
        }
    }
}

// MARK: - Notion query helpers

enum CalendarSyncNotionQueries {
    static func fetchSkipRules(client: CalendarSyncNotionClient) async throws -> [SkipRule] {
        var rules: [SkipRule] = []
        var cursor: String? = nil
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let c = cursor { body["start_cursor"] = c }
            let resp = try await client.post(
                path: "/data_sources/\(CalendarSyncConstants.skipListDataSourceID)/query",
                body: body)
            let results = resp["results"] as? [[String: Any]] ?? []
            for row in results {
                guard let props = row["properties"] as? [String: Any] else { continue }
                let active = (props["Active"] as? [String: Any])?["checkbox"] as? Bool ?? true
                if !active { continue }
                let title = extractTitle(props["Meeting Title"]) ?? ""
                let mtRaw = ((props["Match Type"] as? [String: Any])?["select"] as? [String: Any])?["name"] as? String ?? "Exact Title"
                let mt: SkipRule.MatchType = (mtRaw == "Title Contains") ? .titleContains : .exactTitle
                if !title.isEmpty { rules.append(SkipRule(title: title, matchType: mt)) }
            }
            cursor = resp["next_cursor"] as? String
        } while cursor != nil
        return rules
    }

    struct ExistingRow {
        let pageID: String
        /// True when *either* the Meeting Notes or Pre-Call Briefing relation
        /// has at least one populated link. Used by orphan classification —
        /// rows with manual links must never be archived automatically.
        let hasManualRelations: Bool
        /// Per-relation populated state. Used by B1 auto-link to enforce
        /// append-only writes: an empty column may be filled, a non-empty one
        /// must never be touched.
        let hasMeetingNotesLink: Bool
        let hasPreCallBriefingLink: Bool
        /// True when Notion has the page archived (in-app "Archive", not
        /// Trash). Tracked so we can keep the canonical pageID even if the
        /// archived row was the first one seen during pagination.
        let archived: Bool
    }

    struct ExistingEventsResult {
        let byAppleID: [String: ExistingRow]
        /// `appleID -> [pageID, pageID, ...]` for any appleID that appeared on
        /// more than one row. The canonical pageID is also included in this
        /// list — the first entry. Empty when the corpus is clean.
        let duplicates: [String: [String]]
    }

    /// Returns the existing-events lookup plus a duplicates report. Duplicate
    /// detection here is the load-bearing safety net: if two rows already
    /// share an Apple Event ID, we deterministically pick a canonical pageID
    /// (preferring non-archived, then the first seen) so the upsert never
    /// silently writes to a random one. The `duplicates` map is logged by
    /// the caller and exposed in counts.
    static func fetchExistingEvents(client: CalendarSyncNotionClient,
                                    logger: CalendarSyncLogger) async throws -> ExistingEventsResult {
        var map: [String: ExistingRow] = [:]
        var dupes: [String: [String]] = [:]
        var cursor: String? = nil
        var seenArchived = 0
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let c = cursor { body["start_cursor"] = c }
            let resp = try await client.post(
                path: "/data_sources/\(CalendarSyncConstants.calendarEventsDataSourceID)/query",
                body: body)
            let results = resp["results"] as? [[String: Any]] ?? []
            for row in results {
                guard let id = row["id"] as? String,
                      let props = row["properties"] as? [String: Any],
                      let appleID = extractRichText(props["Apple Event ID"]),
                      !appleID.isEmpty else { continue }
                let archived = (row["archived"] as? Bool) ?? false
                if archived { seenArchived += 1 }
                let notesCount = relationCount(props[CalendarSyncConstants.calendarEventsMeetingNotesRelation])
                let briefCount = relationCount(props[CalendarSyncConstants.calendarEventsPreCallBriefingRelation])
                let hasRelations = (notesCount + briefCount) > 0
                let candidate = ExistingRow(
                    pageID: id,
                    hasManualRelations: hasRelations,
                    hasMeetingNotesLink: notesCount > 0,
                    hasPreCallBriefingLink: briefCount > 0,
                    archived: archived)

                if let existing = map[appleID] {
                    // Record both page IDs as a duplicate set.
                    if dupes[appleID] == nil { dupes[appleID] = [existing.pageID] }
                    dupes[appleID]?.append(id)
                    // Prefer a non-archived row as canonical; if both are the
                    // same archive state, keep the first-seen for stability.
                    if existing.archived && !archived {
                        map[appleID] = candidate
                    }
                } else {
                    map[appleID] = candidate
                }
            }
            cursor = resp["next_cursor"] as? String
        } while cursor != nil
        if seenArchived > 0 {
            logger.info("existing rows: \(seenArchived) archived included in lookup")
        }
        return ExistingEventsResult(byAppleID: map, duplicates: dupes)
    }

    private static func relationCount(_ any: Any?) -> Int {
        guard let dict = any as? [String: Any],
              let arr = dict["relation"] as? [[String: Any]] else { return 0 }
        return arr.count
    }

    private static func extractTitle(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let arr = dict["title"] as? [[String: Any]] else { return nil }
        return arr.compactMap { ($0["plain_text"] as? String) }.joined()
    }

    private static func extractRichText(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let arr = dict["rich_text"] as? [[String: Any]] else { return nil }
        return arr.compactMap { ($0["plain_text"] as? String) }.joined()
    }
}

// MARK: - Counts

struct CalendarSyncCounts: CustomStringConvertible {
    var created = 0, updated = 0, skipped = 0, failed = 0
    var archived = 0, staled = 0
    /// Count of distinct appleIDs that had >1 row in Notion at run start.
    /// Surfaced so a regression that sneaks duplicates in is loud, not silent.
    var duplicates = 0
    var description: String {
        var s = "created=\(created) updated=\(updated) skipped=\(skipped) failed=\(failed)"
        if archived > 0 || staled > 0 {
            s += " archived=\(archived) staled=\(staled)"
        }
        if duplicates > 0 {
            s += " duplicates=\(duplicates)"
        }
        return s
    }
}

// MARK: - Upsert engine

final class CalendarSyncUpserter {
    private let client: CalendarSyncNotionClient
    private let logger: CalendarSyncLogger
    private let dryRun: Bool
    private let archiveOrphans: Bool

    init(client: CalendarSyncNotionClient,
         logger: CalendarSyncLogger,
         dryRun: Bool,
         archiveOrphans: Bool) {
        self.client = client
        self.logger = logger
        self.dryRun = dryRun
        self.archiveOrphans = archiveOrphans
    }

    /// Outcome of one run, including the link targets the auto-linker can
    /// process post-upsert. Targets are only emitted for non-series-master
    /// rows (auto-linking a series master makes no sense — meeting notes are
    /// per-occurrence) whose relation columns are empty in Notion.
    struct RunOutcome {
        var counts: CalendarSyncCounts
        var linkTargets: [RelationLinker.LinkTarget]
    }

    func run(rows: [(event: EventLike, isSeriesMaster: Bool, sourceCalendarName: String)],
             existing: [String: CalendarSyncNotionQueries.ExistingRow]) async -> RunOutcome {
        var counts = CalendarSyncCounts()
        var linkTargets: [RelationLinker.LinkTarget] = []
        let now = Date()
        var touched: Set<String> = []
        touched.reserveCapacity(rows.count)

        for row in rows {
            let appleID = row.isSeriesMaster
                ? row.event.externalIdentifier
                : CalendarEventMapper.compositeAppleID(for: row.event)
            guard !appleID.isEmpty else {
                logger.warn("skipping event with empty external identifier: \(row.event.eventTitle)")
                counts.skipped += 1
                continue
            }
            touched.insert(appleID)
            var props = CalendarEventMapper.buildProperties(for: row.event,
                                                            now: now,
                                                            isSeriesMaster: row.isSeriesMaster,
                                                            sourceCalendarName: row.sourceCalendarName)
            // Mark every touched row as Active. Together with `archived: false`
            // on the UPDATE path, this auto-restores any row that was
            // previously archived/staled but has come back from the calendar.
            props["Sync State"] = ["select": ["name": "Active"]]
            do {
                var resultPageID: String?
                var needsMN = false
                var needsPCB = false
                if let existingRow = existing[appleID] {
                    if dryRun {
                        logger.info("DRY UPDATE \(appleID) :: \(existingRow.pageID)")
                    } else {
                        var body: [String: Any] = ["properties": props]
                        body["archived"] = false
                        _ = try await client.patch(path: "/pages/\(existingRow.pageID)", body: body)
                    }
                    counts.updated += 1
                    resultPageID = existingRow.pageID
                    needsMN = !existingRow.hasMeetingNotesLink
                    needsPCB = !existingRow.hasPreCallBriefingLink
                } else {
                    if dryRun {
                        logger.info("DRY CREATE \(appleID)")
                    } else {
                        let resp = try await client.post(path: "/pages", body: [
                            "parent": [
                                "type": "data_source_id",
                                "data_source_id": CalendarSyncConstants.calendarEventsDataSourceID,
                            ],
                            "properties": props,
                        ])
                        resultPageID = resp["id"] as? String
                    }
                    counts.created += 1
                    // Newly-created rows have no relations yet, so both
                    // columns are open for an auto-link write.
                    needsMN = true
                    needsPCB = true
                }
                // Series masters are not auto-linkable — meeting notes are
                // written per-occurrence, not per-series.
                if !row.isSeriesMaster, let pid = resultPageID, (needsMN || needsPCB) {
                    linkTargets.append(RelationLinker.LinkTarget(
                        pageID: pid,
                        event: row.event,
                        needsMeetingNotes: needsMN,
                        needsPreCallBriefing: needsPCB))
                }
            } catch {
                logger.error("upsert failed for \(appleID): \(error)")
                counts.failed += 1
            }
        }

        if archiveOrphans {
            await processOrphans(touched: touched, existing: existing, counts: &counts)
        }
        return RunOutcome(counts: counts, linkTargets: linkTargets)
    }

    /// Identifies rows in Notion that the source calendar no longer contains.
    /// Two outcomes:
    ///   - has manual relations (Meeting Notes / Pre-Call Briefing populated)
    ///       → Sync State = "Stale". Row stays visible. Logged.
    ///   - no manual relations
    ///       → Sync State = "Orphaned" + archived = true. Row hides from views
    ///         by default. Reversible via Notion API.
    private func processOrphans(touched: Set<String>,
                                existing: [String: CalendarSyncNotionQueries.ExistingRow],
                                counts: inout CalendarSyncCounts) async {
        var orphanIDs: [String] = []
        for (appleID, row) in existing where !touched.contains(appleID) {
            _ = row // captured by closure below
            orphanIDs.append(appleID)
        }
        guard !orphanIDs.isEmpty else { return }
        logger.info("orphans: \(orphanIDs.count) rows in Notion not in source")
        for appleID in orphanIDs {
            guard let row = existing[appleID] else { continue }
            let stale = row.hasManualRelations
            do {
                var body: [String: Any] = [:]
                if stale {
                    body["properties"] = ["Sync State": ["select": ["name": "Stale"]]]
                } else {
                    body["properties"] = ["Sync State": ["select": ["name": "Orphaned"]]]
                    body["archived"] = true
                }
                if dryRun {
                    logger.info("DRY \(stale ? "STALE" : "ARCHIVE") \(appleID) :: \(row.pageID)")
                } else {
                    _ = try await client.patch(path: "/pages/\(row.pageID)", body: body)
                }
                if stale { counts.staled += 1 } else { counts.archived += 1 }
            } catch {
                logger.error("orphan handling failed for \(appleID): \(error)")
                counts.failed += 1
            }
        }
    }
}

// MARK: - Calendar reader

/// Resolves the Exchange-backed calendar and fetches events in the configured
/// window. Uses its own `EKEventStore` instance so this feature is decoupled
/// from `CalendarService`'s lifecycle. EventKit's underlying store is shared
/// across instances, so access granted to the app via `CalendarService` covers
/// this reader too — no second permission prompt.
final class CalendarSyncReader {
    private let store = EKEventStore()
    private let logger: CalendarSyncLogger

    init(logger: CalendarSyncLogger) { self.logger = logger }

    /// All calendars EventKit knows about. The Settings UI reads this list to
    /// render the per-calendar opt-in toggles.
    func availableCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }

    /// Resolves the user-opted-in calendars from `prefEnabledCalendarIDsKey`.
    /// Returns nil when no IDs are stored — caller should fall back to
    /// `resolveExchangeCalendar()` so v1 behaviour is preserved on first launch
    /// after upgrading.
    func enabledCalendars() -> [EKCalendar]? {
        let stored = UserDefaults.standard.stringArray(forKey: CalendarSyncConstants.prefEnabledCalendarIDsKey) ?? []
        guard !stored.isEmpty else { return nil }
        let all = store.calendars(for: .event)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.calendarIdentifier, $0) })
        var resolved: [EKCalendar] = []
        for id in stored {
            if let cal = byID[id] {
                resolved.append(cal)
            } else {
                logger.warn("enabled calendar id \(id) not found in EventKit — dropping")
            }
        }
        return resolved
    }

    /// Maps an `EKCalendar` to the Notion `Source Calendar` select option.
    /// The Exchange-backed "Calendar" gets the legacy `"Calendar (Exchange)"`
    /// label so existing rows aren't churned. Everything else uses the
    /// EKCalendar title as-is — Notion auto-creates select options on write.
    func notionCalendarName(for cal: EKCalendar) -> String {
        if cal.title == CalendarSyncConstants.exchangeCalendarTitle &&
           cal.source.title == CalendarSyncConstants.exchangeSourceTitle {
            return CalendarSyncConstants.calendarPropertyValue
        }
        return cal.title
    }

    func resolveExchangeCalendar() -> EKCalendar? {
        let candidates = store.calendars(for: .event).filter {
            $0.title == CalendarSyncConstants.exchangeCalendarTitle &&
            $0.source.title == CalendarSyncConstants.exchangeSourceTitle
        }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }

        // Tie-break by event volume in the trailing 30 days.
        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        return candidates.max(by: { a, b in
            let p1 = store.predicateForEvents(withStart: from, end: now, calendars: [a])
            let p2 = store.predicateForEvents(withStart: from, end: now, calendars: [b])
            return store.events(matching: p1).count < store.events(matching: p2).count
        })
    }

    func fetchEvents(in calendar: EKCalendar) -> [EKEvent] {
        store.refreshSourcesIfNecessary()
        let now = Date()
        let from = Calendar.current.date(byAdding: .day,
                                         value: -CalendarSyncConstants.lookbackDays,
                                         to: now)!
        let to   = Calendar.current.date(byAdding: .day,
                                         value:  CalendarSyncConstants.lookaheadDays,
                                         to: now)!
        let p = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: p)
    }
}

// MARK: - Orchestrator

@MainActor
final class CalendarNotionSyncService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var lastResult: String?
    @Published var lastRunAt: Date?

    private let logger = CalendarSyncLogger()
    private var dailyTimer: Timer?

    init() {
        self.lastResult = UserDefaults.standard.string(forKey: CalendarSyncConstants.prefLastResultKey)
        self.lastRunAt = UserDefaults.standard.object(forKey: CalendarSyncConstants.prefLastRunKey) as? Date
    }

    // MARK: Token / config

    /// Reads the shared Notion token (same Keychain entry as `NotionService`).
    /// Token management lives in the existing Notion settings tab — this
    /// service is a *consumer*, not an owner, of credentials.
    var token: String? { KeychainHelper.read(key: CalendarSyncConstants.tokenKeychainKey) }
    var isConfigured: Bool {
        if let t = token, !t.isEmpty { return true }
        return false
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: CalendarSyncConstants.prefEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: CalendarSyncConstants.prefEnabledKey)
            objectWillChange.send()
            rescheduleDaily()
        }
    }

    /// Optional view UUID. Empty string means "no rolling-week view configured".
    var rollingWeekViewID: String {
        get { UserDefaults.standard.string(forKey: CalendarSyncConstants.prefRollingWeekViewIDKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: CalendarSyncConstants.prefRollingWeekViewIDKey)
            objectWillChange.send()
        }
    }

    var archiveOrphansEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: CalendarSyncConstants.prefArchiveOrphansKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: CalendarSyncConstants.prefArchiveOrphansKey)
            objectWillChange.send()
        }
    }

    /// When on, drops EKEventAvailability == .free / .unavailable (OOO) before
    /// upsert. The default is off — most users want holidays preserved as
    /// ledger entries even though they're not real meetings.
    var skipFreeAndOOOEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: CalendarSyncConstants.prefSkipFreeAndOOOKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: CalendarSyncConstants.prefSkipFreeAndOOOKey)
            objectWillChange.send()
        }
    }

    /// When on, after each upsert query Meeting Notes / Pre-Call Briefings for
    /// an unambiguous title+day match and PATCH the Calendar Events row's
    /// relation column when (and only when) it's empty. Default off — opt-in.
    var autoLinkRelationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: CalendarSyncConstants.prefAutoLinkRelationsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: CalendarSyncConstants.prefAutoLinkRelationsKey)
            objectWillChange.send()
        }
    }

    // MARK: Lifecycle

    func startScheduleIfEnabled() { rescheduleDaily() }

    /// Open the on-disk log in the user's default reader (usually Console.app).
    func openLogFile() {
        let url = URL(fileURLWithPath: CalendarSyncLogger.defaultPath)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        NSWorkspace.shared.open(url)
    }

    var logFilePath: String { CalendarSyncLogger.defaultPath }

    // MARK: Run

    func runNow(dryRun: Bool = false) async {
        guard !isRunning else {
            logger.warn("run skipped: already running")
            return
        }
        guard let token else {
            logger.error("no token configured")
            updateLastResult("no token")
            return
        }

        isRunning = true
        defer { isRunning = false }
        logger.info("=== sync start (dryRun=\(dryRun)) ===")

        let reader = CalendarSyncReader(logger: logger)
        // Resolve the calendars we'll sync this run. If the user has opted into
        // a specific list via Settings, use that; otherwise fall back to the
        // single Exchange calendar (preserves v1 behaviour exactly).
        let calendars: [EKCalendar]
        if let enabled = reader.enabledCalendars(), !enabled.isEmpty {
            calendars = enabled
        } else if let cal = reader.resolveExchangeCalendar() {
            calendars = [cal]
        } else {
            logger.error("no calendars to sync (Exchange calendar not found and no opt-ins configured)")
            updateLastResult("no calendars")
            return
        }
        for c in calendars {
            logger.info("calendar: \(c.title) (source: \(c.source.title))")
        }

        let client = CalendarSyncNotionClient(token: token, logger: logger)

        do {
            // Run schema migrations BEFORE any upserts so writes can rely on
            // the latest column set. Failures abort the run — refusing to
            // sync against a half-migrated schema is safer than silently
            // dropping new properties.
            try await CalendarSyncMigrations.applyPending(client: client,
                                                          logger: logger,
                                                          dryRun: dryRun)

            let skipRules = try await CalendarSyncNotionQueries.fetchSkipRules(client: client)
            logger.info("skip rules: \(skipRules.count)")

            // Per-calendar fetch + skip-filter + expand. Tag each row with the
            // source calendar's Notion-side display name so the upserter can
            // write `Source Calendar` correctly.
            var rows: [(event: EventLike, isSeriesMaster: Bool, sourceCalendarName: String)] = []
            var skipped = 0
            var totalEK = 0
            let skipFreeOOO = skipFreeAndOOOEnabled
            for cal in calendars {
                let events = reader.fetchEvents(in: cal)
                totalEK += events.count
                let calName = reader.notionCalendarName(for: cal)
                let kept: [EKEvent] = events.filter { e in
                    let title = e.title ?? ""
                    if SkipFilter.shouldSkip(title: title, rules: skipRules) {
                        logger.debug("skip rule: \(title)")
                        skipped += 1
                        return false
                    }
                    if skipFreeOOO {
                        let name = CalendarEventMapper.availabilityName(for: e)
                        if name == "Free" || name == "OOO" {
                            logger.debug("skip free/OOO: \(title) (\(name))")
                            skipped += 1
                            return false
                        }
                    }
                    return true
                }
                let expanded = CalendarEventMapper.expandToRows(events: kept.map { $0 as EventLike }, now: Date())
                for r in expanded {
                    rows.append((r.event, r.isSeriesMaster, calName))
                }
            }
            logger.info("ek events: \(totalEK) across \(calendars.count) calendar(s)")

            let existingResult = try await CalendarSyncNotionQueries.fetchExistingEvents(
                client: client, logger: logger)
            let existing = existingResult.byAppleID
            logger.info("existing notion rows: \(existing.count); rows to upsert: \(rows.count)")
            if !existingResult.duplicates.isEmpty {
                logger.warn("DUPLICATES detected: \(existingResult.duplicates.count) appleIDs have >1 row in Notion")
                for (appleID, pageIDs) in existingResult.duplicates {
                    logger.warn("  \(appleID) → \(pageIDs.joined(separator: ", "))")
                }
            }

            let upserter = CalendarSyncUpserter(client: client,
                                                logger: logger,
                                                dryRun: dryRun,
                                                archiveOrphans: archiveOrphansEnabled)
            let outcome = await upserter.run(rows: rows, existing: existing)
            var counts = outcome.counts
            counts.duplicates = existingResult.duplicates.count

            // B1 auto-link: for any row whose Meeting Notes / Pre-Call
            // Briefing column was empty, run a precision query and PATCH.
            // Manual links are preserved because they're filtered out at
            // target-collection time inside the upserter.
            if autoLinkRelationsEnabled, !outcome.linkTargets.isEmpty {
                logger.info("auto-link: \(outcome.linkTargets.count) candidate row(s) with empty relations")
                let linker = RelationLinker(client: client, logger: logger, dryRun: dryRun)
                let linkCounts = await linker.linkAll(outcome.linkTargets)
                logger.info("auto-link result: meetingNotes=\(linkCounts.meetingNotesLinked) preCallBriefings=\(linkCounts.preCallBriefingsLinked) ambiguous=\(linkCounts.ambiguous) failed=\(linkCounts.failed)")
            }
            counts.skipped += skipped
            let summary = (dryRun ? "DRY: " : "") + counts.description
            logger.info("done — \(summary)")
            updateLastResult(summary)

            // Roll the configured "this week" view forward. Cheap to do every
            // run — Notion's PATCH is idempotent and amounts to a single API
            // call. Skipped on dry-run so dry runs are pure no-ops.
            if !dryRun {
                await patchRollingWeekViewIfConfigured(client: client)
            }
        } catch {
            logger.error("fatal: \(error)")
            updateLastResult("error: \(error)")
        }
        logger.flush()
    }

    /// Read-only diagnostic. Queries the Calendar Events DS, groups by Apple
    /// Event ID, and logs any IDs with >1 row. Does not write to Notion.
    /// Surfaced as a Settings button so the user can verify the corpus is
    /// clean independently of running a full sync.
    func scanForDuplicates() async {
        guard let token, !token.isEmpty else {
            logger.error("duplicate-scan: no token configured")
            updateLastResult("duplicate-scan: no token")
            return
        }
        guard !isRunning else {
            logger.warn("duplicate-scan: skipped, sync already running")
            return
        }
        isRunning = true
        defer { isRunning = false }
        let client = CalendarSyncNotionClient(token: token, logger: logger)
        do {
            let result = try await CalendarSyncNotionQueries.fetchExistingEvents(
                client: client, logger: logger)
            if result.duplicates.isEmpty {
                logger.info("duplicate-scan: clean — \(result.byAppleID.count) unique apple IDs")
                updateLastResult("duplicate-scan: clean (\(result.byAppleID.count) unique)")
            } else {
                logger.warn("duplicate-scan: \(result.duplicates.count) duplicate apple IDs")
                for (appleID, pageIDs) in result.duplicates {
                    logger.warn("  \(appleID) → \(pageIDs.joined(separator: ", "))")
                }
                updateLastResult("duplicate-scan: \(result.duplicates.count) duplicate apple IDs (see log)")
            }
        } catch {
            logger.error("duplicate-scan: \(error)")
            updateLastResult("duplicate-scan error: \(error)")
        }
        logger.flush()
    }

    /// Public manual trigger — used by the Settings "Patch now" button so the
    /// user can re-roll the filter without firing a full sync.
    func patchRollingWeekNow() async {
        guard let token, !token.isEmpty else {
            logger.error("rolling-week: no token configured")
            return
        }
        let client = CalendarSyncNotionClient(token: token, logger: logger)
        await patchRollingWeekViewIfConfigured(client: client)
    }

    /// PATCHes the configured Notion view's filter to the current week's
    /// Mon–Sun bracket in Europe/London. No-op when no view is configured.
    private func patchRollingWeekViewIfConfigured(client: CalendarSyncNotionClient) async {
        let raw = rollingWeekViewID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let viewID = Self.normaliseViewID(raw) else {
            logger.warn("rolling-week: invalid view ID '\(raw)'")
            return
        }

        let (mondayISO, sundayISO) = Self.currentWeekBoundsLondon()
        let body: [String: Any] = [
            "filter": [
                "and": [
                    ["property": "Date", "date": ["on_or_after": mondayISO]],
                    ["property": "Date", "date": ["on_or_before": sundayISO]],
                ]
            ]
        ]
        do {
            _ = try await client.patch(path: "/views/\(viewID)", body: body)
            logger.info("rolling-week: patched view \(viewID) to \(mondayISO) … \(sundayISO)")
        } catch {
            logger.error("rolling-week: patch failed for \(viewID): \(error)")
        }
    }

    /// Accepts a bare UUID (with or without dashes) or a full Notion view URL
    /// like "https://www.notion.so/<db>?v=<viewid>". Returns a dashed UUID, or
    /// nil if the input doesn't contain a recognisable 32-hex view ID.
    private static func normaliseViewID(_ input: String) -> String? {
        // Try query parameter ?v=...
        if let url = URL(string: input),
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
            return formatUUID(v)
        }
        return formatUUID(input)
    }

    private static func formatUUID(_ s: String) -> String? {
        let stripped = s.replacingOccurrences(of: "-", with: "")
        guard stripped.count == 32, stripped.allSatisfy({ $0.isHexDigit }) else { return nil }
        // Insert dashes at 8-4-4-4-12 boundaries.
        let chars = Array(stripped)
        let parts = [
            String(chars[0..<8]),
            String(chars[8..<12]),
            String(chars[12..<16]),
            String(chars[16..<20]),
            String(chars[20..<32]),
        ]
        return parts.joined(separator: "-")
    }

    /// Returns ("YYYY-MM-DD", "YYYY-MM-DD") for the Monday and Sunday of the
    /// current week in Europe/London. Uses ISO 8601 weeks (Monday-first).
    private static func currentWeekBoundsLondon() -> (String, String) {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        cal.firstWeekday = 2 // Monday
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        // ISO weekday: Monday=2, Tuesday=3, ..., Sunday=1. Map so Mon=0…Sun=6.
        let dayOffset = (weekday + 5) % 7
        let monday = cal.date(byAdding: .day, value: -dayOffset, to: cal.startOfDay(for: now))!
        let sunday = cal.date(byAdding: .day, value: 6, to: monday)!
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        return (f.string(from: monday), f.string(from: sunday))
    }

    private func updateLastResult(_ s: String) {
        let now = Date()
        lastResult = s
        lastRunAt = now
        UserDefaults.standard.set(s, forKey: CalendarSyncConstants.prefLastResultKey)
        UserDefaults.standard.set(now, forKey: CalendarSyncConstants.prefLastRunKey)
    }

    // MARK: Daily timer

    private func rescheduleDaily() {
        dailyTimer?.invalidate()
        dailyTimer = nil
        guard isEnabled else { return }

        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = CalendarSyncConstants.dailyHour
        comps.minute = CalendarSyncConstants.dailyMinute
        var next = cal.date(from: comps)!
        if next <= now { next = cal.date(byAdding: .day, value: 1, to: next)! }
        let interval = next.timeIntervalSince(now)
        dailyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.runNow()
                self?.rescheduleDaily()
            }
        }
        logger.info("scheduled next run at \(next)")
    }
}
