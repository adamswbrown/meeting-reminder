import Foundation

/// Auto-links Meeting Notes / Pre-Call Briefing pages to Calendar Events rows
/// when an unambiguous title+day match exists. Strictly append-only — never
/// overwrites a relation the user already populated. If two candidate pages
/// match the same event, the link is skipped with a warning rather than
/// guessed.
///
/// Identity strategy:
///   - Server-side filter: title `contains` event title (case-insensitive) AND
///     date is on the event's start day in Europe/London.
///   - Local re-filter: exact case-insensitive title equality (so "Sync" event
///     can't link to "Sync with Bob" notes).
///   - Date overlap is computed in Europe/London so a 23:30 BST meeting
///     doesn't get tagged with the wrong day.
final class RelationLinker {
    private let client: CalendarSyncNotionClient
    private let logger: CalendarSyncLogger
    private let dryRun: Bool

    init(client: CalendarSyncNotionClient, logger: CalendarSyncLogger, dryRun: Bool) {
        self.client = client
        self.logger = logger
        self.dryRun = dryRun
    }

    private static let londonTimeZone = TimeZone(identifier: "Europe/London")!
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = londonTimeZone
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        return f
    }()

    /// One candidate match in a target DS.
    private struct Candidate {
        let pageID: String
        let title: String
    }

    /// Targets needing one or both relations populated.
    struct LinkTarget {
        let pageID: String
        let event: EventLike
        let needsMeetingNotes: Bool
        let needsPreCallBriefing: Bool
    }

    struct LinkCounts {
        var meetingNotesLinked = 0
        var preCallBriefingsLinked = 0
        var ambiguous = 0
        var failed = 0
    }

    /// Iterates targets and patches each Calendar Events row with any
    /// unambiguous matches. Returns counts so the caller can surface them in
    /// the run summary.
    func linkAll(_ targets: [LinkTarget]) async -> LinkCounts {
        var counts = LinkCounts()
        for target in targets {
            if target.needsMeetingNotes {
                let outcome = await link(
                    target: target,
                    dataSourceID: CalendarSyncConstants.meetingNotesDataSourceID,
                    titleProperty: CalendarSyncConstants.meetingNotesTitleProperty,
                    dateProperty: CalendarSyncConstants.meetingNotesDateProperty,
                    relationProperty: CalendarSyncConstants.calendarEventsMeetingNotesRelation,
                    label: "Meeting Notes")
                switch outcome {
                case .linked: counts.meetingNotesLinked += 1
                case .ambiguous: counts.ambiguous += 1
                case .failed: counts.failed += 1
                case .none: break
                }
            }
            if target.needsPreCallBriefing {
                let outcome = await link(
                    target: target,
                    dataSourceID: CalendarSyncConstants.preCallBriefingsDataSourceID,
                    titleProperty: CalendarSyncConstants.preCallBriefingsTitleProperty,
                    dateProperty: CalendarSyncConstants.preCallBriefingsDateProperty,
                    relationProperty: CalendarSyncConstants.calendarEventsPreCallBriefingRelation,
                    label: "Pre-Call Briefing")
                switch outcome {
                case .linked: counts.preCallBriefingsLinked += 1
                case .ambiguous: counts.ambiguous += 1
                case .failed: counts.failed += 1
                case .none: break
                }
            }
        }
        return counts
    }

    private enum LinkOutcome { case linked, ambiguous, failed, none }

    private func link(target: LinkTarget,
                      dataSourceID: String,
                      titleProperty: String,
                      dateProperty: String,
                      relationProperty: String,
                      label: String) async -> LinkOutcome {
        let title = target.event.eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .none }
        let day = Self.dayFormatter.string(from: target.event.eventStart)

        do {
            let candidates = try await queryCandidates(
                dataSourceID: dataSourceID,
                titleProperty: titleProperty,
                dateProperty: dateProperty,
                titleNeedle: title,
                day: day)

            // Tighten to exact case-insensitive title equality. Server-side
            // `contains` is too permissive — "Sync" would match "Sync with
            // Bob" — so this is the load-bearing precision step.
            let exact = candidates.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            if exact.isEmpty {
                return .none
            }
            if exact.count > 1 {
                let pageList = exact.map { $0.pageID }.joined(separator: ", ")
                logger.warn("auto-link \(label): ambiguous for '\(title)' on \(day) — \(exact.count) candidates: \(pageList)")
                return .ambiguous
            }

            let candidatePageID = exact[0].pageID
            if dryRun {
                logger.info("auto-link \(label): DRY would link \(target.pageID) ↔ \(candidatePageID) ('\(title)' on \(day))")
                return .linked
            }
            // PATCH the relation on the Calendar Events side. Notion mirrors
            // the inverse `Calendar Event` relation onto the MN/PCB row
            // automatically.
            let body: [String: Any] = [
                "properties": [
                    relationProperty: [
                        "relation": [["id": candidatePageID]]
                    ]
                ]
            ]
            _ = try await client.patch(path: "/pages/\(target.pageID)", body: body)
            logger.info("auto-link \(label): \(target.pageID) ↔ \(candidatePageID) ('\(title)' on \(day))")
            return .linked
        } catch {
            logger.error("auto-link \(label): failed for '\(title)' on \(day): \(error)")
            return .failed
        }
    }

    private func queryCandidates(dataSourceID: String,
                                 titleProperty: String,
                                 dateProperty: String,
                                 titleNeedle: String,
                                 day: String) async throws -> [Candidate] {
        let body: [String: Any] = [
            "page_size": 25,
            "filter": [
                "and": [
                    ["property": titleProperty,
                     "title": ["contains": titleNeedle]],
                    ["property": dateProperty,
                     "date": ["on_or_after": day]],
                    ["property": dateProperty,
                     "date": ["on_or_before": day]],
                ]
            ]
        ]
        let resp = try await client.post(
            path: "/data_sources/\(dataSourceID)/query",
            body: body)
        let results = resp["results"] as? [[String: Any]] ?? []
        var out: [Candidate] = []
        for row in results {
            guard let id = row["id"] as? String,
                  let props = row["properties"] as? [String: Any],
                  let title = extractTitle(props[titleProperty]),
                  !title.isEmpty else { continue }
            out.append(Candidate(pageID: id, title: title))
        }
        return out
    }

    private func extractTitle(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let arr = dict["title"] as? [[String: Any]] else { return nil }
        return arr.compactMap { ($0["plain_text"] as? String) }.joined()
    }
}
