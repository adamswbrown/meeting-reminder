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
        /// The row's current `Sync State` select name ("Active" / "Orphaned" /
        /// "Stale"), nil when unset. Used by the orphan sweep to avoid
        /// re-PATCHing rows already in their target state every run.
        let syncState: String?
        /// Raw `properties` payload from the Notion query response. Stored so
        /// the upserter can diff incoming props against the current state and
        /// skip the PATCH when nothing changed. Comparing read-format against
        /// write-format requires the canonicaliser in `PropertyDiff`.
        let properties: [String: Any]
        /// The row's `Date` property start, parsed from Notion. Used by orphan
        /// classification to only sweep rows whose event date falls inside the
        /// current run's fetch window — `fetchExistingEvents` queries the whole
        /// data source (no date filter), but `touched` only covers the window,
        /// so without this guard every row older than the window would be
        /// archived even though its event still exists. `nil` when the row has
        /// no parseable Date (such rows are never swept).
        let eventDate: Date?
        /// Page ID of the first linked Pre-Call Briefing (read from the
        /// relation payload), or nil. Used by the status cascade to PATCH the
        /// brief's Meeting Outcome / Date & Time. No extra Notion query.
        let preCallBriefingPageID: String?
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
                    archived: archived,
                    syncState: extractSelectName(props["Sync State"]),
                    properties: props,
                    eventDate: extractDateStart(props["Date"]),
                    preCallBriefingPageID: CalendarSyncCascade.briefPageID(
                        fromRelation: props[CalendarSyncConstants.calendarEventsPreCallBriefingRelation]))

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

    private static func extractSelectName(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let sel = dict["select"] as? [String: Any] else { return nil }
        return sel["name"] as? String
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

    // Parsers for the Notion `Date` property's `start`. Notion returns either a
    // full ISO8601 datetime (fractional or not) or an all-day `YYYY-MM-DD`.
    private static let parseDateFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let parseDatePlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let parseAllDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        return f
    }()

    /// Parses the `start` of a Notion `Date` property into a `Date`. Returns
    /// nil when the property is absent or unparseable.
    private static func extractDateStart(_ any: Any?) -> Date? {
        guard let dict = any as? [String: Any],
              let date = dict["date"] as? [String: Any],
              let start = date["start"] as? String, !start.isEmpty else { return nil }
        return parseDateFractional.date(from: start)
            ?? parseDatePlain.date(from: start)
            ?? parseAllDay.date(from: start)
    }
}

// MARK: - Counts

struct CalendarSyncCounts: CustomStringConvertible {
    var created = 0, updated = 0, skipped = 0, failed = 0
    var orphaned = 0, staled = 0
    /// Rows whose incoming props matched the existing Notion row exactly
    /// (ignoring `Last Synced`), so the PATCH was skipped. Tracked separately
    /// from `skipped` (which is for malformed/empty-id events) to make the
    /// no-op short-circuit visible in the run summary.
    var unchanged = 0
    /// Count of distinct appleIDs that had >1 row in Notion at run start.
    /// Surfaced so a regression that sneaks duplicates in is loud, not silent.
    var duplicates = 0
    var description: String {
        var s = "created=\(created) updated=\(updated) unchanged=\(unchanged) skipped=\(skipped) failed=\(failed)"
        if orphaned > 0 || staled > 0 {
            s += " orphaned=\(orphaned) staled=\(staled)"
        }
        if duplicates > 0 {
            s += " duplicates=\(duplicates)"
        }
        return s
    }
}

// MARK: - Property diffing

/// Compares incoming write-format properties (as built by
/// `CalendarEventMapper.buildProperties`) against the read-format properties
/// returned by Notion's data-source query. Equality means the upsert can skip
/// the PATCH entirely — the dominant cost in steady-state runs where most
/// events haven't changed.
///
/// `Last Synced` is always excluded because the incoming value is `now()`,
/// which would defeat the purpose. Skipped rows therefore retain their
/// previous `Last Synced` timestamp — a feature, not a bug: it now means
/// "last time we actually wrote this row," which is more useful than "last
/// time we looked at it."
enum PropertyDiff {
    static let ignoredKeys: Set<String> = ["Last Synced"]

    static func equal(incoming: [String: Any], existing: [String: Any]) -> Bool {
        return diff(incoming: incoming, existing: existing).isEmpty
    }

    /// Returns the keys whose canonical values differ. Empty set means the
    /// row is unchanged. Exposed so callers can log which properties are
    /// causing PATCHes and tighten the canonicaliser if a benign format
    /// difference is fooling the diff.
    static func diff(incoming: [String: Any], existing: [String: Any]) -> [(key: String, incoming: String, existing: String)] {
        var result: [(String, String, String)] = []
        for (key, value) in incoming where !ignoredKeys.contains(key) {
            let incomingCanon = canonical(value)
            let existingCanon = canonical(existing[key])
            if incomingCanon != existingCanon {
                result.append((key, incomingCanon, existingCanon))
            }
        }
        return result
    }

    /// Reduce a Notion property payload (read or write format) to a single
    /// comparable string. Read format wraps the payload in a `type` field
    /// alongside the type-named payload key; write format only has the
    /// type-named key. Both share the inner payload shape that we key on.
    static func canonical(_ any: Any?) -> String {
        guard let dict = any as? [String: Any] else { return "absent" }

        if let arr = dict["title"] as? [[String: Any]] {
            return "title:" + extractText(arr)
        }
        if let arr = dict["rich_text"] as? [[String: Any]] {
            return "rich_text:" + extractText(arr)
        }
        if dict.keys.contains("date") {
            if let d = dict["date"] as? [String: Any] {
                let s = (d["start"] as? String) ?? ""
                let e = (d["end"] as? String) ?? ""
                return "date:\(normaliseDateString(s))|\(normaliseDateString(e))"
            }
            return "date:nil"
        }
        if dict.keys.contains("checkbox") {
            return "checkbox:\((dict["checkbox"] as? Bool) ?? false)"
        }
        if dict.keys.contains("select") {
            if let s = dict["select"] as? [String: Any], let n = s["name"] as? String {
                return "select:\(n)"
            }
            return "select:nil"
        }
        if dict.keys.contains("number") {
            if let n = dict["number"] as? Int { return "number:\(n)" }
            if let n = dict["number"] as? Double { return "number:\(Int(n))" }
            return "number:nil"
        }
        if dict.keys.contains("url") {
            if let u = dict["url"] as? String { return "url:\(u)" }
            return "url:nil"
        }
        return "unknown"
    }

    /// Concatenates the visible text from either format. Read format exposes
    /// `plain_text`; write format embeds the string under `text.content`.
    /// Notion sometimes splits a single logical string across multiple
    /// rich-text objects (links, mentions, formatting), so we always join.
    ///
    /// EventKit's `notes` returns CRLF line endings on Exchange-backed
    /// calendars, while Notion stores plain LF. Both encode the same text;
    /// stripping CR from the canonical form lets the diff match.
    private static func extractText(_ arr: [[String: Any]]) -> String {
        let raw = arr.compactMap { item -> String? in
            if let pt = item["plain_text"] as? String { return pt }
            if let t = item["text"] as? [String: Any], let c = t["content"] as? String { return c }
            return nil
        }.joined()
        return raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Notion stores ISO8601 datetimes with fractional seconds and a
    /// `+00:00` offset (e.g. `2026-01-29T10:00:00.000+00:00`) regardless of
    /// what we wrote. Our writer emits `2026-01-29T10:00:00Z`. Both encode
    /// the same instant, so we parse-and-reformat to a canonical no-fraction
    /// `Z` form for comparison. All-day strings (`YYYY-MM-DD`) don't parse
    /// with these formatters and pass through unchanged, which is correct —
    /// they're already canonical.
    private static let parseFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let parsePlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let emitCanonical: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func normaliseDateString(_ s: String) -> String {
        if s.isEmpty { return "" }
        if let d = parseFractional.date(from: s) ?? parsePlain.date(from: s) {
            return emitCanonical.string(from: d)
        }
        return s
    }
}

// MARK: - Diff diagnostics helpers

/// Returns the index of the first differing character, or nil if one string
/// is a prefix of the other.
private func firstDifferenceIndex(_ a: String, _ b: String) -> Int? {
    let aChars = Array(a)
    let bChars = Array(b)
    let n = min(aChars.count, bChars.count)
    for i in 0..<n where aChars[i] != bChars[i] { return i }
    if aChars.count != bChars.count { return n }
    return nil
}

/// Returns a window of `radius` characters either side of `at`, with newlines
/// escaped so a single log line stays single-line.
private func sliceAround(_ s: String, at: Int, radius: Int) -> String {
    let chars = Array(s)
    let lo = max(0, at - radius)
    let hi = min(chars.count, at + radius)
    let slice = String(chars[lo..<hi])
    return slice
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

// MARK: - Upsert engine

final class CalendarSyncUpserter {
    private let client: CalendarSyncNotionClient
    private let logger: CalendarSyncLogger
    private let dryRun: Bool
    private let archiveOrphans: Bool
    private let cascadeStatus: Bool
    private let isReactive: Bool

    init(client: CalendarSyncNotionClient,
         logger: CalendarSyncLogger,
         dryRun: Bool,
         archiveOrphans: Bool,
         cascadeStatus: Bool = false,
         isReactive: Bool = false) {
        self.client = client
        self.logger = logger
        self.dryRun = dryRun
        self.archiveOrphans = archiveOrphans
        self.cascadeStatus = cascadeStatus
        self.isReactive = isReactive
    }

    /// Outcome of one run, including the link targets the auto-linker can
    /// process post-upsert. Targets are only emitted for non-series-master
    /// rows (auto-linking a series master makes no sense — meeting notes are
    /// per-occurrence) whose relation columns are empty in Notion.
    struct RunOutcome {
        var counts: CalendarSyncCounts
        var linkTargets: [RelationLinker.LinkTarget]
    }

    /// `orphanWindow` bounds the orphan sweep: only rows whose parsed `Date`
    /// falls inside `[start, end]` are eligible for orphan/stale classification.
    /// Rows outside the window (older history, far-future) are left untouched
    /// because `touched` only reflects events in the current fetch window. Nil
    /// disables the window guard (the sweep is off in that case anyway).
    func run(rows: [(event: EventLike, isSeriesMaster: Bool, sourceCalendarName: String)],
             existing: [String: CalendarSyncNotionQueries.ExistingRow],
             orphanWindow: (start: Date, end: Date)? = nil,
             presentIDs: Set<String> = []) async -> RunOutcome {
        var counts = CalendarSyncCounts()
        var linkTargets: [RelationLinker.LinkTarget] = []
        let now = Date()
        var touched: Set<String> = []
        touched.reserveCapacity(rows.count + presentIDs.count)
        // Events dropped by the Skip List or the skip-free/OOO filter still
        // exist on the calendar — treat them as "present" so a newly-added
        // skip rule doesn't cause their Notion rows to be mass-archived.
        touched.formUnion(presentIDs)
        // Cap diagnostic logging so a noisy run doesn't fill the log file.
        var diagnosticsLogged = 0
        let diagnosticsCap = 5

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
            // Mark every touched row as Active. Orphaned/Stale rows stay
            // queryable (the sweep never trashes pages), so a row whose event
            // comes back from the calendar diffs on Sync State here and gets
            // revived by the normal UPDATE PATCH.
            props["Sync State"] = ["select": ["name": "Active"]]
            do {
                var resultPageID: String?
                var needsMN = false
                var needsPCB = false
                if let existingRow = existing[appleID] {
                    // No-op short-circuit: when the incoming props match what
                    // Notion already has (excluding `Last Synced`) AND the row
                    // isn't currently archived (revival requires a write), we
                    // skip the PATCH entirely. This is the dominant path in
                    // steady-state runs where most rows are unchanged from the
                    // previous sync.
                    let differences = existingRow.archived
                        ? [(key: "<archived>", incoming: "false", existing: "true")]
                        : PropertyDiff.diff(incoming: props, existing: existingRow.properties)
                    let unchanged = differences.isEmpty
                    if !unchanged, diagnosticsLogged < diagnosticsCap {
                        let summary = differences.prefix(3).map { d -> String in
                            let inLen = d.incoming.count
                            let exLen = d.existing.count
                            let firstDiff = firstDifferenceIndex(d.incoming, d.existing)
                            let context: String
                            if let i = firstDiff {
                                let inSlice = sliceAround(d.incoming, at: i, radius: 40)
                                let exSlice = sliceAround(d.existing, at: i, radius: 40)
                                context = "@\(i) in=«\(inSlice)» ex=«\(exSlice)»"
                            } else {
                                context = "len-only"
                            }
                            return "\(d.key)[inLen=\(inLen) exLen=\(exLen) \(context)]"
                        }.joined(separator: " || ")
                        logger.info("diff \(appleID): \(summary)")
                        diagnosticsLogged += 1
                    }
                    if unchanged {
                        if dryRun {
                            logger.info("DRY NOOP \(appleID) :: \(existingRow.pageID)")
                        }
                        counts.unchanged += 1
                    } else if dryRun {
                        logger.info("DRY UPDATE \(appleID) :: \(existingRow.pageID)")
                        counts.updated += 1
                    } else {
                        var body: [String: Any] = ["properties": props]
                        body["archived"] = false
                        _ = try await client.patch(path: "/pages/\(existingRow.pageID)", body: body)
                        counts.updated += 1
                        // Reschedule cascade: when a one-off meeting moves, push
                        // the new start onto the linked brief's Date & Time so
                        // the brief stays aligned. Recurring occurrences are
                        // excluded (their appleID is date-suffixed; a moved
                        // occurrence would otherwise rewrite a prior brief).
                        if cascadeStatus,
                           !CalendarSyncCascade.isRecurringAppleID(appleID),
                           let briefID = existingRow.preCallBriefingPageID,
                           CalendarSyncCascade.startChanged(incoming: row.event.eventStart,
                                                            existing: existingRow.eventDate) {
                            let london = TimeZone(identifier: "Europe/London")!
                            let iso = ISO8601DateFormatter(); iso.timeZone = london
                            iso.formatOptions = [.withInternetDateTime]
                            let start = iso.string(from: row.event.eventStart)
                            let end = iso.string(from: row.event.eventEnd)
                            _ = try? await client.patch(path: "/pages/\(briefID)", body: ["properties": [
                                "Date & Time": ["date": ["start": start, "end": end]]
                            ]])
                            logger.info("cascade: re-dated brief \(briefID) → \(start)")
                        }
                    }
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
                //
                // ±7-day window: Meeting Notes and Pre-Call Briefings are
                // authored close to meeting time. Querying Notion twice for
                // every event in the 90/30-day sync window is mostly wasted
                // calls returning empty results. Constraining auto-link to
                // events within ±7 days of now drops the candidate set by
                // ~80% in steady state without losing meaningful matches —
                // a PCB written for an event 60 days out is vanishingly
                // rare, and if one *does* land later, the next sync after
                // it crosses into the window will pick it up.
                let withinAutoLinkWindow = abs(row.event.eventStart.timeIntervalSince(now)) <= 7 * 86_400
                if !row.isSeriesMaster, withinAutoLinkWindow,
                   let pid = resultPageID, (needsMN || needsPCB) {
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

        if archiveOrphans || cascadeStatus {
            await processOrphans(touched: touched,
                                 existing: existing,
                                 orphanWindow: orphanWindow,
                                 counts: &counts)
        }
        return RunOutcome(counts: counts, linkTargets: linkTargets)
    }

    /// Identifies rows in Notion that the source calendar no longer contains.
    /// Two outcomes:
    ///   - has manual relations (Meeting Notes / Pre-Call Briefing populated)
    ///       → Sync State = "Stale". Row stays visible. Logged.
    ///   - no manual relations
    ///       → Sync State = "Orphaned". Views filter on Sync State to hide
    ///         them.
    ///
    /// Deliberately does NOT set `archived: true`: Notion's data-source query
    /// never returns trashed pages (verified live 2026-07-18), so an archived
    /// row is invisible to `fetchExistingEvents` — a returning event would hit
    /// the CREATE branch and duplicate instead of reviving. Keeping orphans
    /// queryable means the normal UPDATE path (which always writes
    /// Sync State = Active) revives them for free.
    private func processOrphans(touched: Set<String>,
                                existing: [String: CalendarSyncNotionQueries.ExistingRow],
                                orphanWindow: (start: Date, end: Date)?,
                                counts: inout CalendarSyncCounts) async {
        var orphanIDs: [String] = []
        var skippedOutOfWindow = 0
        for (appleID, row) in existing where !touched.contains(appleID) {
            // Only sweep rows whose event date falls inside the current run's
            // fetch window. `fetchExistingEvents` queries the whole data source
            // with no date filter, but `touched` only covers the window — so
            // without this guard every row older than the window would be
            // archived even though its event still exists on the calendar.
            // Rows with no parseable Date are left untouched (conservative).
            if let window = orphanWindow {
                guard let date = row.eventDate else { skippedOutOfWindow += 1; continue }
                guard date >= window.start && date <= window.end else {
                    skippedOutOfWindow += 1
                    continue
                }
            }
            orphanIDs.append(appleID)
        }
        if skippedOutOfWindow > 0 {
            logger.info("orphans: \(skippedOutOfWindow) rows skipped (outside fetch window or no date)")
        }
        guard !orphanIDs.isEmpty else { return }
        logger.info("orphans: \(orphanIDs.count) rows in Notion not in source")
        for appleID in orphanIDs {
            guard let row = existing[appleID] else { continue }
            let decision = CalendarSyncCascade.classifyDisappearance(
                hasManualRelations: row.hasManualRelations,
                isRecurring: CalendarSyncCascade.isRecurringAppleID(appleID),
                isReactive: isReactive,
                cascadeEnabled: cascadeStatus,
                archiveEnabled: archiveOrphans)
            if decision.skip { continue }

            // Build the row PATCH. Skip when already in target state to avoid
            // re-PATCH churn (transition-only) — covers both Sync State and Status.
            var rowProps: [String: Any] = [:]
            if let ss = decision.syncState, row.syncState != ss {
                rowProps["Sync State"] = ["select": ["name": ss]]
            }
            let alreadyCancelled = CalendarSyncCascade
                .isCancelledStatus(row.properties["Status"])
            if let st = decision.rowStatus, !alreadyCancelled {
                rowProps["Status"] = ["select": ["name": st]]
            }

            // The brief cascade fires only on the transition into Cancelled
            // (i.e. the row wasn't already Cancelled) so it runs exactly once.
            let doBriefCascade = decision.cascadeBriefCancelled
                && !alreadyCancelled
                && row.preCallBriefingPageID != nil

            if rowProps.isEmpty && !doBriefCascade { continue }

            do {
                if dryRun {
                    logger.info("DRY \(decision.rowStatus ?? decision.syncState ?? "?") \(appleID) :: \(row.pageID)\(doBriefCascade ? " +brief" : "")")
                } else {
                    if !rowProps.isEmpty {
                        _ = try await client.patch(path: "/pages/\(row.pageID)",
                                                   body: ["properties": rowProps])
                    }
                    if doBriefCascade, let briefID = row.preCallBriefingPageID {
                        _ = try await client.patch(path: "/pages/\(briefID)",
                            body: ["properties": ["Meeting Outcome": ["select": ["name": "Cancelled"]]]])
                    }
                }
                if decision.rowStatus == "Cancelled" { counts.orphaned += 1 } else { counts.staled += 1 }
            } catch {
                logger.error("cascade/orphan failed for \(appleID): \(error)")
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
        let now = Date()
        let from = Calendar.current.date(byAdding: .day,
                                         value: -CalendarSyncConstants.lookbackDays,
                                         to: now)!
        let to   = Calendar.current.date(byAdding: .day,
                                         value:  CalendarSyncConstants.lookaheadDays,
                                         to: now)!
        return fetchEvents(in: calendar, from: from, to: to)
    }

    /// Window-parameterized fetch. The reactive path passes a narrow
    /// `now → +reactiveLookaheadDays` window.
    func fetchEvents(in calendar: EKCalendar, from: Date, to: Date) -> [EKEvent] {
        store.refreshSourcesIfNecessary()
        let p = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: p)
    }
}

// MARK: - Orchestrator

enum CalendarSyncMode {
    case full      // 06:00 + manual: 90/30 window, orphan sweep, rolling-week patch
    case reactive  // change-driven: now→+reactiveLookaheadDays, no orphan sweep, no rolling-week patch

    /// Compiler-exhaustive label for log lines — avoids a ternary that would
    /// silently mislabel a future third mode.
    var logLabel: String {
        switch self {
        case .full: return "full"
        case .reactive: return "reactive"
        }
    }
}

@MainActor
final class CalendarNotionSyncService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var lastResult: String?
    @Published var lastRunAt: Date?

    private let logger = CalendarSyncLogger()
    private var dailyTimer: Timer?
    private var dailyRetryTimer: Timer?
    private var changeWatcher: CalendarChangeWatcher?

    /// While a sync run is in progress, and for `changeCooldown` seconds after
    /// it finishes, calendar-change notifications are treated as self-inflicted
    /// echoes and ignored by the reactive watcher. A run's
    /// `store.refreshSourcesIfNecessary()` can itself post `.EKEventStoreChanged`,
    /// which would otherwise re-trigger the watcher in a ~2.5-min loop.
    private var ignoreChangesUntil: Date?
    private let changeCooldown: TimeInterval = 15

    /// True when an incoming calendar change should be ignored — a run is in
    /// flight, or we're within the post-run cooldown window.
    private func shouldIgnoreCalendarChange() -> Bool {
        if isRunning { return true }
        if let until = ignoreChangesUntil, Date() < until { return true }
        return false
    }

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

    /// When on (the default), cancellations/reschedules are cascaded onto the
    /// Calendar Events row Status + the linked Pre-Call Briefing. Defaults to
    /// true when the key is unset — this only flips status metadata, never
    /// archives, so it's safe on by default. Independent of archive-orphans.
    var cascadeStatusEnabled: Bool {
        UserDefaults.standard.object(forKey: CalendarSyncConstants.prefCascadeStatusKey) as? Bool ?? true
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

    /// When on, install a CalendarChangeWatcher that runs a narrow-window
    /// reactive sync on calendar changes (debounced + 2-min floor). Default
    /// off — opt-in. The 06:00 full run is unaffected.
    var reactiveEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: CalendarSyncConstants.prefReactiveEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: CalendarSyncConstants.prefReactiveEnabledKey)
            objectWillChange.send()
            reconfigureWatcher()
        }
    }

    private func reconfigureWatcher() {
        if reactiveEnabled && isConfigured {
            if changeWatcher == nil {
                changeWatcher = CalendarChangeWatcher(
                    logger: logger,
                    shouldIgnoreChange: { [weak self] in
                        self?.shouldIgnoreCalendarChange() ?? false
                    },
                    onFire: { [weak self] in
                        // A deallocated service counts as "ran" so the watcher
                        // doesn't spin re-scheduling against a dead target.
                        await self?.runReactive() ?? true
                    })
            }
            changeWatcher?.start()
        } else {
            changeWatcher?.stop()
            changeWatcher = nil
        }
    }

    // MARK: Lifecycle

    func startScheduleIfEnabled() {
        rescheduleDaily()
        reconfigureWatcher()
    }

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

    @discardableResult
    func runNow(dryRun: Bool = false) async -> Bool {
        await run(mode: .full, dryRun: dryRun)
    }

    /// Change-driven run. Narrow forward window, orphan archival forced off,
    /// rolling-week patch skipped. Shares the upsert pipeline with the full run.
    /// Returns whether the run actually executed (false if another was in
    /// flight and it was skipped).
    @discardableResult
    func runReactive() async -> Bool {
        await run(mode: .reactive, dryRun: false)
    }

    /// Runs a sync in the given mode. Returns `true` if the run executed to
    /// completion (or hit a handled fatal), `false` if it was skipped because
    /// another run was already in flight. Callers use the return to decide
    /// whether to retry (daily timer) or re-schedule the debounce (watcher).
    @discardableResult
    private func run(mode: CalendarSyncMode, dryRun: Bool) async -> Bool {
        guard !isRunning else {
            logger.warn("run skipped: already running")
            return false
        }
        guard let token else {
            logger.error("no token configured")
            updateLastResult("no token")
            return true
        }

        isRunning = true
        defer {
            isRunning = false
            // Open the post-run cooldown so the reactive watcher ignores the
            // `.EKEventStoreChanged` echo that our own `refreshSourcesIfNecessary()`
            // may have posted during this run.
            ignoreChangesUntil = Date().addingTimeInterval(changeCooldown)
        }
        logger.info("=== sync start (mode=\(mode.logLabel) dryRun=\(dryRun)) ===")

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
            return true
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
            // Composite appleIDs of events dropped by the skip filters. They
            // still exist on the calendar, so the orphan sweep must treat them
            // as present (otherwise a newly-added skip rule mass-archives them).
            var skipFilteredIDs: Set<String> = []
            // The fetch window bracket, captured so the orphan sweep only
            // considers Notion rows whose date falls inside it. Full runs use
            // the 90/30 window; reactive runs are narrow (but skip the sweep).
            let now0 = Date()
            let windowStart: Date = {
                switch mode {
                case .full:
                    return Calendar.current.date(byAdding: .day,
                        value: -CalendarSyncConstants.lookbackDays, to: now0)!
                case .reactive:
                    return now0
                }
            }()
            let windowEnd: Date = {
                switch mode {
                case .full:
                    return Calendar.current.date(byAdding: .day,
                        value: CalendarSyncConstants.lookaheadDays, to: now0)!
                case .reactive:
                    return Calendar.current.date(byAdding: .day,
                        value: CalendarSyncConstants.reactiveLookaheadDays, to: now0)!
                }
            }()
            for cal in calendars {
                let events: [EKEvent]
                switch mode {
                case .full:
                    events = reader.fetchEvents(in: cal)
                case .reactive:
                    events = reader.fetchEvents(in: cal, from: windowStart, to: windowEnd)
                }
                totalEK += events.count
                let calName = reader.notionCalendarName(for: cal)
                let kept: [EKEvent] = events.filter { e in
                    let title = e.title ?? ""
                    if SkipFilter.shouldSkip(title: title, rules: skipRules) {
                        logger.debug("skip rule: \(title)")
                        skipped += 1
                        skipFilteredIDs.insert(CalendarEventMapper.compositeAppleID(for: e))
                        return false
                    }
                    if skipFreeOOO {
                        let name = CalendarEventMapper.availabilityName(for: e)
                        if name == "Free" || name == "OOO" {
                            logger.debug("skip free/OOO: \(title) (\(name))")
                            skipped += 1
                            skipFilteredIDs.insert(CalendarEventMapper.compositeAppleID(for: e))
                            return false
                        }
                    }
                    return true
                }
                // Reactive runs use a narrow, now-anchored window, so the
                // synthetic series-master row (derived from the earliest
                // in-window occurrence) would differ from the full run's and
                // churn a spurious PATCH on each alternation. Suppress masters
                // on reactive runs — the orphan sweep is off there, so the
                // now-missing master is never mis-classified.
                let expanded = CalendarEventMapper.expandToRows(events: kept.map { $0 as EventLike },
                                                                now: Date(),
                                                                emitSeriesMasters: mode == .full)
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
                                                archiveOrphans: mode == .full && archiveOrphansEnabled,
                                                cascadeStatus: cascadeStatusEnabled,
                                                isReactive: mode != .full)
            let outcome = await upserter.run(rows: rows,
                                             existing: existing,
                                             orphanWindow: (start: windowStart, end: windowEnd),
                                             presentIDs: skipFilteredIDs)
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
            if !dryRun && mode == .full {
                await patchRollingWeekViewIfConfigured(client: client)
            }
        } catch {
            logger.error("fatal: \(error)")
            updateLastResult("error: \(error)")
        }
        logger.flush()
        return true
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
                guard let self else { return }
                let ran = await self.runNow()
                if !ran {
                    // Another run (reactive/manual) was in flight, so the daily
                    // full run was dropped. Retry once after a short delay so a
                    // day's full reconciliation isn't silently skipped.
                    self.logger.info("daily run skipped (busy) — retrying in 5 min")
                    self.scheduleDailyRetry()
                }
                self.rescheduleDaily()
            }
        }
        logger.info("scheduled next run at \(next)")
    }

    /// One-shot retry for a daily full run that was dropped because another run
    /// was in flight. Fires once after 5 min; if that attempt is also busy it
    /// is not retried again (the next 06:00 run will reconcile).
    private func scheduleDailyRetry() {
        dailyRetryTimer?.invalidate()
        dailyRetryTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ran = await self.runNow()
                if !ran {
                    self.logger.info("daily retry also skipped (busy) — next 06:00 run will reconcile")
                }
            }
        }
    }
}
