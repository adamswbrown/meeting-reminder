import Foundation

/// Provisions the full set of Notion databases the app needs into a *fresh*
/// workspace, so Meeting Reminder works out-of-the-box for anyone — not just
/// the original author's pre-built Operations page.
///
/// Given an integration token and a single parent page the integration can see,
/// this service creates five databases with the exact schemas the rest of the
/// app expects, then writes their IDs into UserDefaults / Keychain so every
/// consumer (`NotionService`, `CalendarNotionSyncService`, `PreCallBriefService`,
/// `RelationLinker`, `CalComNotionBridge`, `CalendarSyncMigrations`) picks them
/// up with no code changes.
///
/// Creation order matters: Meeting Notes and Pre-Call Briefings are created
/// first because Calendar Events declares `relation` properties that point at
/// their data sources.
///
/// Notion API notes (version 2025-09-03):
///   - `POST /v1/databases` creates a database *and* its initial data source in
///     one call. Property schema goes under `initial_data_source.properties`.
///   - The response returns `data_sources: [{ id, name }]`; `id` (top level) is
///     the database ID, `data_sources[0].id` is the data source ID. Sync writes
///     target the data source ID; `NotionService`'s create-page flow (which
///     still speaks 2022-06-28 with a `database_id` parent) uses the database ID.
///   - A relation property is declared as
///     `{"relation": {"data_source_id": <uuid>, "type": "dual_property", "dual_property": {}}}`,
///     which auto-creates the inverse relation on the target — matching the
///     behaviour `RelationLinker` already relies on.
///
/// Schema migrations (`CalendarSyncMigrations` 001/002/003) are *not* seeded
/// here: Calendar Events is created with every migrated column already present,
/// and each migration's `ensureSelectColumn` is idempotent, so the first sync
/// run records them as applied without mutating the freshly-built schema.
@MainActor
final class NotionProvisioningService: ObservableObject {

    // MARK: - Progress model

    enum Step: String, CaseIterable, Identifiable {
        case validate = "Checking token & page access"
        case meetingNotes = "Creating Meeting Notes database"
        case preCallBriefings = "Creating Pre-Call Briefings database"
        case calendarEvents = "Creating Calendar Events database"
        case skipList = "Creating Skip List database"
        case migrations = "Creating Cal Sync Migrations database"
        case persist = "Saving configuration"

        var id: String { rawValue }
    }

    enum StepState: Equatable { case pending, running, done, failed }

    @Published private(set) var stepStates: [Step: StepState] =
        Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .pending) })
    @Published private(set) var isRunning = false
    @Published private(set) var didSucceed = false
    @Published private(set) var errorMessage: String?

    /// The databases created this run, in creation order, with a link back to
    /// each in Notion. Populated as provisioning progresses; surfaced on the
    /// success page so the user can jump straight to what was built.
    @Published private(set) var createdDatabases: [ProvisionedDatabase] = []

    struct ProvisionedDatabase: Identifiable {
        let id = UUID()
        let name: String
        let url: URL?
    }

    // MARK: - Networking

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    private struct APIError: Error, CustomStringConvertible {
        let status: Int
        let body: String
        var description: String {
            // Surface Notion's own `message` when present — far friendlier than the raw body.
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = json["message"] as? String {
                return msg
            }
            return "Notion API \(status)"
        }
    }

    // MARK: - Public entry point

    /// Runs the full provisioning flow. `parentPageInput` may be a full Notion
    /// page URL or a bare page ID (with or without dashes). Returns true on
    /// success. Safe to re-run: a second run simply creates a second set of
    /// databases and repoints config at them (Notion has no "create if absent").
    func provision(token rawToken: String, parentPageInput: String) async -> Bool {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        isRunning = true
        defer { isRunning = false }

        guard !token.isEmpty else { return fail(.validate, "Paste your integration token first.") }
        guard let pageID = Self.extractID(from: parentPageInput) else {
            return fail(.validate, "Couldn't find a page ID in that. Paste the page's URL or its 32-character ID.")
        }

        // 1. Validate token + page access.
        mark(.validate, .running)
        do {
            _ = try await get(path: "/pages/\(pageID)", token: token)
        } catch let e as APIError {
            let hint = e.status == 404
                ? "Page not found, or the integration hasn't been shared with it. Open the page → ••• → Connections → add your integration."
                : (e.status == 401 ? "That token was rejected. Double-check you copied the whole \"Internal Integration Secret\"." : e.description)
            return fail(.validate, hint)
        } catch {
            return fail(.validate, error.localizedDescription)
        }
        mark(.validate, .done)

        do {
            // 2. Meeting Notes (relation target + NotionService create-page target).
            mark(.meetingNotes, .running)
            let meetingNotes = try await createDatabase(
                token: token, parentPageID: pageID,
                title: "Meeting Notes",
                properties: Self.meetingNotesProperties)
            mark(.meetingNotes, .done)

            // 3. Pre-Call Briefings (relation target + PreCallBriefService source).
            mark(.preCallBriefings, .running)
            let preCall = try await createDatabase(
                token: token, parentPageID: pageID,
                title: "Pre-Call Briefings",
                properties: Self.preCallBriefingsProperties)
            mark(.preCallBriefings, .done)

            // 4. Calendar Events — declares relations to the two data sources above.
            mark(.calendarEvents, .running)
            let calendarEvents = try await createDatabase(
                token: token, parentPageID: pageID,
                title: "Calendar Events",
                properties: Self.calendarEventsProperties(meetingNotesDS: meetingNotes.dataSourceID,
                                                           preCallBriefingsDS: preCall.dataSourceID))
            mark(.calendarEvents, .done)

            // 5. Skip List.
            mark(.skipList, .running)
            let skipList = try await createDatabase(
                token: token, parentPageID: pageID,
                title: "Cal Sync Skip List",
                properties: Self.skipListProperties)
            mark(.skipList, .done)

            // 6. Migrations log.
            mark(.migrations, .running)
            let migrations = try await createDatabase(
                token: token, parentPageID: pageID,
                title: "Cal Sync Migrations",
                properties: Self.migrationsProperties)
            mark(.migrations, .done)

            // 7. Persist everything.
            mark(.persist, .running)
            let d = UserDefaults.standard
            d.set(calendarEvents.dataSourceID, forKey: CalendarSyncConstants.overrideCalendarEventsDSKey)
            d.set(skipList.dataSourceID, forKey: CalendarSyncConstants.overrideSkipListDSKey)
            d.set(migrations.dataSourceID, forKey: CalendarSyncConstants.overrideMigrationsDSKey)
            d.set(meetingNotes.dataSourceID, forKey: CalendarSyncConstants.overrideMeetingNotesDSKey)
            d.set(preCall.dataSourceID, forKey: CalendarSyncConstants.overridePreCallBriefingsDSKey)
            // NotionService create-page flow uses the database ID (2022-06-28 parent).
            d.set(meetingNotes.databaseID, forKey: "notionDatabaseID")
            // PreCallBriefService reads its source via `preCallBriefsDatabaseID`.
            d.set(preCall.databaseID, forKey: "preCallBriefsDatabaseID")
            // Token last, so the app only considers Notion "configured" once every
            // ID it needs is already in place.
            KeychainHelper.save(key: CalendarSyncConstants.tokenKeychainKey, value: token)
            mark(.persist, .done)
        } catch let e as APIError {
            return fail(firstRunning() ?? .persist, e.description)
        } catch {
            return fail(firstRunning() ?? .persist, error.localizedDescription)
        }

        didSucceed = true
        return true
    }

    // MARK: - Database creation

    private struct CreatedDatabase { let databaseID: String; let dataSourceID: String }

    private func createDatabase(token: String,
                                parentPageID: String,
                                title: String,
                                properties: [String: Any]) async throws -> CreatedDatabase {
        let body: [String: Any] = [
            "parent": ["type": "page_id", "page_id": parentPageID],
            "title": [["type": "text", "text": ["content": title]]],
            "initial_data_source": ["properties": properties],
        ]
        let json = try await post(path: "/databases", token: token, body: body)
        guard let dbID = json["id"] as? String,
              let sources = json["data_sources"] as? [[String: Any]],
              let dsID = sources.first?["id"] as? String else {
            throw APIError(status: -1, body: "Created \(title) but Notion returned no data source ID.")
        }
        // Record a link back to the database. Prefer Notion's own `url`; fall
        // back to the canonical www.notion.so/<id> form if it's absent.
        let link = (json["url"] as? String).flatMap { URL(string: $0) }
            ?? URL(string: "https://www.notion.so/\(dbID.replacingOccurrences(of: "-", with: ""))")
        createdDatabases.append(ProvisionedDatabase(name: title, url: link))
        return CreatedDatabase(databaseID: dbID, dataSourceID: dsID)
    }

    // MARK: - Schemas

    private static let meetingNotesProperties: [String: Any] = [
        "Title": ["title": [:]],
        "Start": ["date": [:]],
        "End": ["date": [:]],
        "Attendees Name": ["rich_text": [:]],
    ]

    private static let preCallBriefingsProperties: [String: Any] = [
        "Meeting Title": ["title": [:]],
        "Date & Time": ["date": [:]],
        "Customer / Partner": ["select": ["options": [] as [Any]]],
        "Attendees": ["rich_text": [:]],
        "Briefing Status": ["select": ["options": [
            ["name": "Draft", "color": "gray"],
            ["name": "Ready", "color": "green"],
        ]]],
    ]

    private static let skipListProperties: [String: Any] = [
        "Meeting Title": ["title": [:]],
        "Match Type": ["select": ["options": [
            ["name": "Exact Title", "color": "blue"],
            ["name": "Title Contains", "color": "purple"],
        ]]],
        "Active": ["checkbox": [:]],
    ]

    private static let migrationsProperties: [String: Any] = [
        "Migration ID": ["title": [:]],
        "Applied At": ["date": [:]],
        "Description": ["rich_text": [:]],
    ]

    /// The full Calendar Events schema — the union of `CalendarEventMapper.buildProperties`
    /// keys and the three migration columns (Sync State / Source Calendar /
    /// Availability), plus the two relations. Options are pre-seeded so Notion
    /// views can filter on them immediately; the mapper also auto-creates any
    /// option it writes, so the lists here need only cover the known values.
    private static func calendarEventsProperties(meetingNotesDS: String,
                                                 preCallBriefingsDS: String) -> [String: Any] {
        [
            "Title": ["title": [:]],
            "Date": ["date": [:]],
            "All Day": ["checkbox": [:]],
            "Status": ["select": ["options": [
                ["name": "Cancelled", "color": "red"],
                ["name": "Today", "color": "green"],
                ["name": "Upcoming", "color": "blue"],
                ["name": "Past", "color": "gray"],
            ]]],
            "Availability": ["select": ["options": [
                ["name": "Busy", "color": "blue"],
                ["name": "Free", "color": "gray"],
                ["name": "Tentative", "color": "yellow"],
                ["name": "OOO", "color": "red"],
                ["name": "Unknown", "color": "default"],
            ]]],
            "Calendar": ["select": ["options": [] as [Any]]],
            "Source Calendar": ["select": ["options": [
                ["name": "Calendar (Exchange)", "color": "blue"],
            ]]],
            "Organiser": ["rich_text": [:]],
            "Attendees": ["rich_text": [:]],
            "Attendee Count": ["number": ["format": "number"]],
            "Has External Attendees": ["checkbox": [:]],
            "Location": ["rich_text": [:]],
            "Conference URL": ["url": [:]],
            "Description": ["rich_text": [:]],
            "Recurring": ["checkbox": [:]],
            "Series Master": ["checkbox": [:]],
            "Apple Event ID": ["rich_text": [:]],
            "iCal UID": ["rich_text": [:]],
            "Sync State": ["select": ["options": [
                ["name": "Active", "color": "green"],
                ["name": "Stale", "color": "yellow"],
                ["name": "Orphaned", "color": "gray"],
            ]]],
            "Last Synced": ["date": [:]],
            CalendarSyncConstants.calendarEventsMeetingNotesRelation: [
                "relation": [
                    "data_source_id": meetingNotesDS,
                    "type": "dual_property",
                    "dual_property": [:],
                ]
            ],
            CalendarSyncConstants.calendarEventsPreCallBriefingRelation: [
                "relation": [
                    "data_source_id": preCallBriefingsDS,
                    "type": "dual_property",
                    "dual_property": [:],
                ]
            ],
        ]
    }

    // MARK: - HTTP helpers

    private func get(path: String, token: String) async throws -> [String: Any] {
        try await request(method: "GET", path: path, token: token, body: nil)
    }

    private func post(path: String, token: String, body: [String: Any]) async throws -> [String: Any] {
        try await request(method: "POST", path: path, token: token, body: body)
    }

    private func request(method: String, path: String, token: String, body: [String: Any]?) async throws -> [String: Any] {
        let url = URL(string: "https://api.notion.com/v1\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(CalendarSyncConstants.notionVersion, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError(status: -1, body: "non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Parent-page ID parsing

    /// Extracts a 32-hex Notion ID from a page URL or a raw ID, returning it in
    /// dashed UUID form. Notion page URLs end in the ID (dashless) optionally
    /// followed by a `?…` query; a bare ID may already be dashed.
    static func extractID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Strip any query/fragment, then hunt for the last run of 32 hex chars.
        let stripped = trimmed.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? trimmed
        let hexOnly = stripped.replacingOccurrences(of: "-", with: "")
        guard let regex = try? NSRegularExpression(pattern: "[0-9a-fA-F]{32}") else { return nil }
        let range = NSRange(hexOnly.startIndex..., in: hexOnly)
        let matches = regex.matches(in: hexOnly, range: range)
        guard let last = matches.last, let r = Range(last.range, in: hexOnly) else { return nil }
        let raw = String(hexOnly[r]).lowercased()
        return Self.dashed(raw)
    }

    private static func dashed(_ hex32: String) -> String {
        let s = Array(hex32)
        guard s.count == 32 else { return hex32 }
        return "\(String(s[0..<8]))-\(String(s[8..<12]))-\(String(s[12..<16]))-\(String(s[16..<20]))-\(String(s[20..<32]))"
    }

    // MARK: - State plumbing

    private func reset() {
        stepStates = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .pending) })
        didSucceed = false
        errorMessage = nil
        createdDatabases = []
    }

    private func mark(_ step: Step, _ state: StepState) { stepStates[step] = state }

    private func firstRunning() -> Step? { Step.allCases.first { stepStates[$0] == .running } }

    @discardableResult
    private func fail(_ step: Step, _ message: String) -> Bool {
        mark(step, .failed)
        errorMessage = message
        return false
    }
}
