import EventKit
import Foundation

// MARK: - Constants

/// Hardcoded identifiers and tuning knobs for the Calendar → Notion sync feature.
///
/// The Notion data source IDs are *live* — they point to real production
/// databases under the user's Operations parent page in Notion. They are not
/// user-configurable; bind them at compile time so a misconfiguration in
/// UserDefaults can't accidentally write to the wrong place.
enum CalendarSyncConstants {
    static let calendarEventsDataSourceID = "1d605620-3b70-47f1-96d8-465e57fd0bdd"
    static let skipListDataSourceID = "77164bfd-8536-4c3a-ba3d-701fe64fc9b3"
    static let migrationsDataSourceID = "7590658a-f038-45c1-b6ca-d50b2421b0c4"
    static let notionVersion = "2025-09-03"
    /// Reuses the same Keychain entry as `NotionService` — the user has scoped
    /// their Notion integration to cover both the create-meeting-page flow and
    /// the Calendar Events / Skip List databases under Operations.
    static let tokenKeychainKey = "notionAPIToken"
    static let internalDomain = "altra.cloud"
    static let lookbackDays = 90
    static let lookaheadDays = 30
    static let dailyHour = 6
    static let dailyMinute = 0
    static let logRelativePath = "Library/Logs/MeetingReminder/calendar-notion-sync.log"
    static let logMaxBytes = 5 * 1024 * 1024
    static let exchangeCalendarTitle = "Calendar"
    static let exchangeSourceTitle = "Exchange"
    static let calendarPropertyValue = "Calendar (Exchange)"

    // UserDefaults keys
    static let prefEnabledKey = "calendarNotionSyncEnabled"
    static let prefLastRunKey = "calendarNotionSyncLastRunAt"
    static let prefLastResultKey = "calendarNotionSyncLastResult"
    /// Optional Notion view UUID. When set, every sync run also PATCHes the
    /// view's filter to "Date is within the current Mon–Sun (Europe/London)".
    /// Stored without dashes or with — both are accepted at runtime.
    static let prefRollingWeekViewIDKey = "calendarNotionRollingWeekViewID"
    /// When true, rows in Notion whose source events have disappeared from the
    /// calendar window get classified as Stale (if they have manual relations)
    /// or archived + Orphaned. Default false — opt-in for the first month so
    /// the user can observe the behaviour before trusting it with archives.
    static let prefArchiveOrphansKey = "calendarNotionSyncArchiveOrphans"
    /// Array of EKCalendar identifiers the user has opted into syncing. When
    /// missing/empty, the sync falls back to the single Exchange "Calendar"
    /// (preserving v1 behaviour).
    static let prefEnabledCalendarIDsKey = "calendarNotionSyncEnabledCalendarIDs"
    /// When true, drops events with EKEventAvailability == .free or
    /// .unavailable (OOO) before upsert. Off by default — most users want a
    /// record of their holidays in the ledger even though they're not real
    /// meetings.
    static let prefSkipFreeAndOOOKey = "calendarNotionSyncSkipFreeAndOOO"
    /// When true, after each upsert the orchestrator queries Meeting Notes
    /// and Pre-Call Briefings for an unambiguous title+day match and PATCHes
    /// the Calendar Events row's relation when (and only when) the relation
    /// column is currently empty. Default false — opt-in.
    static let prefAutoLinkRelationsKey = "calendarNotionSyncAutoLinkRelations"

    /// Notion data source IDs and property names for B1 auto-linking.
    static let meetingNotesDataSourceID = "1f2ef850-f293-80ba-a763-000bb894d2c0"
    static let preCallBriefingsDataSourceID = "656b2eff-7ea3-4730-91fe-104ff647f4e3"
    static let meetingNotesTitleProperty = "Title"
    static let meetingNotesDateProperty = "Start"
    static let preCallBriefingsTitleProperty = "Meeting Title"
    static let preCallBriefingsDateProperty = "Date & Time"
    static let calendarEventsMeetingNotesRelation = "Meeting Notes"
    static let calendarEventsPreCallBriefingRelation = "Pre-Call Briefing"
}

// MARK: - Logger

/// Simple rotating file logger scoped to the Calendar → Notion sync feature.
/// We don't reuse `print` because the user wants a persistent on-disk audit
/// trail they can `tail -f` without running the app from a terminal.
final class CalendarSyncLogger {
    enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    private let path: String
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "calendar-notion-sync.log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(path: String = CalendarSyncLogger.defaultPath,
         maxBytes: Int = CalendarSyncConstants.logMaxBytes) {
        self.path = path
        self.maxBytes = maxBytes
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(CalendarSyncConstants.logRelativePath)
    }

    func debug(_ s: String) { write(.debug, s) }
    func info(_ s: String)  { write(.info, s) }
    func warn(_ s: String)  { write(.warn, s) }
    func error(_ s: String) { write(.error, s) }

    func flush() { queue.sync { } }

    private func write(_ level: Level, _ message: String) {
        queue.async { [self] in
            rotateIfNeeded()
            let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            if let h = FileHandle(forWritingAtPath: path) {
                defer { try? h.close() }
                try? h.seekToEnd()
                if let data = line.data(using: .utf8) { try? h.write(contentsOf: data) }
            }
        }
    }

    private func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int,
              size >= maxBytes else { return }
        let rotated = path + ".1"
        try? FileManager.default.removeItem(atPath: rotated)
        try? FileManager.default.moveItem(atPath: path, toPath: rotated)
    }
}

// MARK: - EventLike protocol

/// Pure-data event abstraction so the mapper can be unit-tested without
/// EventKit. `EKEvent` conforms to this via the extension below.
protocol EventLike {
    var eventTitle: String { get }
    var eventStart: Date { get }
    var eventEnd: Date { get }
    var eventIsAllDay: Bool { get }
    /// EKEventStatus rawValue: 0=none, 1=confirmed, 2=tentative, 3=canceled
    var statusRawValue: Int { get }
    var organizerName: String? { get }
    var organizerEmail: String? { get }
    var attendeesList: [(name: String?, email: String)] { get }
    var locationString: String? { get }
    var notesString: String? { get }
    var eventIsRecurring: Bool { get }
    var externalIdentifier: String { get }
    /// EKEventAvailability rawValue: 0=notSupported, 1=busy, 2=free, 3=tentative, 4=unavailable (OOO).
    /// Exchange's "Out of Office" maps to `.unavailable`. There is no public
    /// API to distinguish "Working Elsewhere" from OOO at the EventKit layer.
    var availabilityRawValue: Int { get }
}

// MARK: - EKEvent → EventLike

extension EKEvent: EventLike {
    var eventTitle: String { self.title ?? "" }
    var eventStart: Date { self.startDate ?? .distantPast }
    var eventEnd: Date { self.endDate ?? eventStart }
    var eventIsAllDay: Bool { self.isAllDay }
    var statusRawValue: Int { Int(self.status.rawValue) }
    var organizerName: String? { self.organizer?.name }
    var organizerEmail: String? {
        guard let url = self.organizer?.url, url.scheme == "mailto" else { return nil }
        return url.absoluteString.replacingOccurrences(of: "mailto:", with: "").lowercased()
    }
    var attendeesList: [(name: String?, email: String)] {
        (self.attendees ?? []).compactMap { p in
            guard let url = p.url as URL?, url.scheme == "mailto" else { return nil }
            let email = url.absoluteString.replacingOccurrences(of: "mailto:", with: "").lowercased()
            return (p.name, email)
        }
    }
    var locationString: String? { self.location }
    var notesString: String? { self.notes }
    var eventIsRecurring: Bool { self.hasRecurrenceRules }
    var externalIdentifier: String { self.calendarItemExternalIdentifier ?? "" }
    var availabilityRawValue: Int { self.availability.rawValue }
}

// MARK: - Skip rules

struct SkipRule: Equatable {
    enum MatchType: String { case exactTitle, titleContains }
    let title: String
    let matchType: MatchType
}

enum SkipFilter {
    static func shouldSkip(title: String, rules: [SkipRule]) -> Bool {
        for rule in rules {
            switch rule.matchType {
            case .exactTitle:
                if title == rule.title { return true }
            case .titleContains:
                if title.range(of: rule.title, options: .caseInsensitive) != nil { return true }
            }
        }
        return false
    }
}

// MARK: - Synthetic event for series-master rows

/// A synthesized "series master" row — emitted once per recurring series so the
/// Notion database has a single row representing the series definition,
/// alongside one row per occurrence in the window.
///
/// Constructed from the first occurrence's metadata. The only deliberate
/// override is `title` (forced to non-recurring's title) and the property
/// composition path branching on `isSeriesMaster`.
struct SyntheticSeriesMasterEvent: EventLike {
    let source: EventLike

    var eventTitle: String { source.eventTitle }
    var eventStart: Date { source.eventStart }
    var eventEnd: Date { source.eventEnd }
    var eventIsAllDay: Bool { source.eventIsAllDay }
    var statusRawValue: Int { source.statusRawValue }
    var organizerName: String? { source.organizerName }
    var organizerEmail: String? { source.organizerEmail }
    var attendeesList: [(name: String?, email: String)] { source.attendeesList }
    var locationString: String? { source.locationString }
    var notesString: String? { source.notesString }
    var eventIsRecurring: Bool { true }
    var externalIdentifier: String { source.externalIdentifier }
    var availabilityRawValue: Int { source.availabilityRawValue }
}
