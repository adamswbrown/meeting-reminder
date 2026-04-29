import Foundation

/// Append-only schema migrations for the Calendar Events Notion data source.
///
/// Each `Migration` knows how to mutate the Notion schema (add a column,
/// rename a property, etc.) and is recorded in the "Cal Sync Migrations"
/// database under Operations after it succeeds. On every sync run we fetch
/// that log, run any migrations whose IDs aren't present, and append a row
/// for each.
///
/// Rules:
/// - Migrations are append-only. Once applied they are never re-run.
/// - IDs are stable forever. Renaming an ID will cause a migration to re-run.
/// - Migrations should be idempotent where practical (e.g. re-applying an
///   "add column" should be a no-op rather than an error) so a stale log
///   doesn't permanently brick subsequent syncs.
struct Migration {
    let id: String
    let description: String
    /// Performs the migration. Throwing aborts the sync run.
    let apply: (CalendarSyncNotionClient, CalendarSyncLogger) async throws -> Void
}

enum CalendarSyncMigrations {

    // MARK: - Registry

    /// Registered migrations, in order. Add new entries at the end. Never
    /// remove or renumber — the IDs are the bookkeeping key.
    static let allMigrations: [Migration] = [
        Migration(
            id: "001-add-sync-state-column",
            description: "Add Sync State select column (Active / Stale / Orphaned) to Calendar Events.",
            apply: { client, logger in
                try await ensureSelectColumn(
                    client: client,
                    logger: logger,
                    dataSourceID: CalendarSyncConstants.calendarEventsDataSourceID,
                    propertyName: "Sync State",
                    options: [
                        ("Active", "green"),
                        ("Stale", "yellow"),
                        ("Orphaned", "gray"),
                    ]
                )
            }
        ),
        Migration(
            id: "002-add-source-calendar-column",
            description: "Add Source Calendar select column to Calendar Events. Distinguishes events by their originating Apple Calendar — used by multi-calendar sync.",
            apply: { client, logger in
                try await ensureSelectColumn(
                    client: client,
                    logger: logger,
                    dataSourceID: CalendarSyncConstants.calendarEventsDataSourceID,
                    propertyName: "Source Calendar",
                    options: [
                        ("Calendar (Exchange)", "blue"),
                    ]
                )
            }
        ),
        Migration(
            id: "003-add-availability-column",
            description: "Add Availability select column reflecting EKEvent.availability — Busy / Free / Tentative / OOO / Unknown. Lets Notion views filter holidays and free-blocks separately from real meetings.",
            apply: { client, logger in
                try await ensureSelectColumn(
                    client: client,
                    logger: logger,
                    dataSourceID: CalendarSyncConstants.calendarEventsDataSourceID,
                    propertyName: "Availability",
                    options: [
                        ("Busy", "blue"),
                        ("Free", "gray"),
                        ("Tentative", "yellow"),
                        ("OOO", "red"),
                        ("Unknown", "default"),
                    ]
                )
            }
        ),
    ]

    // MARK: - Runner

    /// Runs any registered migrations whose IDs are not already in the log.
    /// Records each successful migration as a new row in the migrations DB.
    /// On dry-run, logs what *would* be applied but doesn't mutate anything.
    static func applyPending(client: CalendarSyncNotionClient,
                             logger: CalendarSyncLogger,
                             dryRun: Bool) async throws {
        let applied = try await fetchApplied(client: client)
        var pending: [Migration] = []
        for m in allMigrations where !applied.contains(m.id) {
            pending.append(m)
        }
        if pending.isEmpty {
            logger.debug("migrations: none pending (\(applied.count) already applied)")
            return
        }
        logger.info("migrations: \(pending.count) pending (\(applied.count) already applied)")
        for m in pending {
            if dryRun {
                logger.info("migrations: DRY would apply \(m.id) — \(m.description)")
                continue
            }
            logger.info("migrations: applying \(m.id) — \(m.description)")
            try await m.apply(client, logger)
            try await record(applied: m, client: client)
            logger.info("migrations: applied \(m.id)")
        }
    }

    // MARK: - Log access

    /// Fetches the set of already-applied migration IDs from the log DS.
    private static func fetchApplied(client: CalendarSyncNotionClient) async throws -> Set<String> {
        var ids: Set<String> = []
        var cursor: String? = nil
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let c = cursor { body["start_cursor"] = c }
            let resp = try await client.post(
                path: "/data_sources/\(CalendarSyncConstants.migrationsDataSourceID)/query",
                body: body)
            let results = resp["results"] as? [[String: Any]] ?? []
            for row in results {
                guard let props = row["properties"] as? [String: Any],
                      let title = (props["Migration ID"] as? [String: Any])?["title"] as? [[String: Any]],
                      let id = title.first?["plain_text"] as? String,
                      !id.isEmpty else { continue }
                ids.insert(id)
            }
            cursor = resp["next_cursor"] as? String
        } while cursor != nil
        return ids
    }

    /// Records a successful migration as a new row in the log.
    private static func record(applied m: Migration, client: CalendarSyncNotionClient) async throws {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let body: [String: Any] = [
            "parent": [
                "type": "data_source_id",
                "data_source_id": CalendarSyncConstants.migrationsDataSourceID,
            ],
            "properties": [
                "Migration ID": ["title": [["text": ["content": m.id]]]],
                "Applied At": ["date": ["start": f.string(from: Date())]],
                "Description": ["rich_text": [["text": ["content": String(m.description.prefix(1990))]]]],
            ],
        ]
        _ = try await client.post(path: "/pages", body: body)
    }

    // MARK: - Schema helpers

    /// Adds a select property with the given options to a data source if it
    /// isn't already present. If the property exists with the same name, the
    /// migration is treated as already applied (idempotent).
    static func ensureSelectColumn(client: CalendarSyncNotionClient,
                                   logger: CalendarSyncLogger,
                                   dataSourceID: String,
                                   propertyName: String,
                                   options: [(name: String, color: String)]) async throws {
        // Check existence first to keep this idempotent.
        let ds = try await client.post(path: "/data_sources/\(dataSourceID)/query",
                                       body: ["page_size": 1])
        // Per Notion 2025-09-03, properties live on the data source object, not
        // the query response. Fetch via PATCH-with-no-op which returns the
        // full data source body.
        _ = ds // we only used the query above to confirm access
        let dsBody = try await getDataSource(client: client, id: dataSourceID)
        let existingProps = dsBody["properties"] as? [String: Any] ?? [:]
        if existingProps[propertyName] != nil {
            logger.debug("migrations: column '\(propertyName)' already exists, skipping schema patch")
            return
        }
        let optionsBody: [[String: String]] = options.map { ["name": $0.name, "color": $0.color] }
        let patchBody: [String: Any] = [
            "properties": [
                propertyName: [
                    "select": ["options": optionsBody]
                ]
            ]
        ]
        _ = try await client.patch(path: "/data_sources/\(dataSourceID)", body: patchBody)
    }

    /// PATCH-with-empty-body returns the full data source object, including
    /// the `properties` map. Cheaper than a paginated query.
    private static func getDataSource(client: CalendarSyncNotionClient, id: String) async throws -> [String: Any] {
        try await client.patch(path: "/data_sources/\(id)", body: [:])
    }
}
