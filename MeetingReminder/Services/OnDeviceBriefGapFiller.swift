import AppKit
import Combine
import Foundation

// MARK: - Pure planning (testable — NOT gated to macOS 26)

/// Decisions for the on-device gap-filler, kept free of I/O so they can be tested.
enum GapFillPlanner {
    /// `Briefing Status` value marking a page as an on-device draft. The cloud routine
    /// and the intraday skill treat it as "not briefed": if Claude runs with credit it
    /// rewrites the page in place and sets the status back to `Auto`.
    static let onDeviceStatus = "On-device"

    /// The cloud briefing routine's schedule: weekdays at 02:04 UTC (cron `4 2 * * 1-5`,
    /// routine trig_01CUbUGc4yywHDdgUJTapsLb). Keep in step if the routine moves.
    static let routineHourUTC = 2
    static let routineMinuteUTC = 4
    static let routineWeekdays = 2...6            // Calendar weekday: Mon–Fri
    /// How long a run is given to finish before its result is trusted.
    static let routineSettle: TimeInterval = 45 * 60

    /// The first moment after `now` by which the next cloud run should have finished.
    /// A meeting is only drafted on-device if it starts before this: anything later
    /// gets a Claude briefing first (or, if Claude is out of credit, a draft once this
    /// passes). Drafting earlier only produces pages Claude immediately rewrites.
    static func nextClaudeSettle(after now: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let today = utc.startOfDay(for: now)
        for offset in 0..<8 {
            guard let day = utc.date(byAdding: .day, value: offset, to: today),
                  routineWeekdays.contains(utc.component(.weekday, from: day)),
                  let run = utc.date(bySettingHour: routineHourUTC, minute: routineMinuteUTC, second: 0, of: day)
            else { continue }
            let settle = run.addingTimeInterval(routineSettle)
            if settle > now { return settle }
        }
        return now.addingTimeInterval(24 * 3600)   // unreachable: a weekday is always within 8 days
    }

    /// One key per occurrence, so a moved meeting is re-checked at its new time.
    static func key(_ e: MeetingEvent) -> String {
        "\(e.id)|\(Int(e.startDate.timeIntervalSince1970))"
    }

    /// Meetings starting after `now` and before `until` that haven't been handled.
    /// Skips all-day events, ad-hoc meetings and anything with no attendees (focus
    /// blocks and personal holds don't need a brief).
    static func candidates(_ events: [MeetingEvent], now: Date, until: Date,
                           handled: Set<String>) -> [MeetingEvent] {
        events
            .filter { e in
                !e.isAllDay
                    && !e.id.hasPrefix("adhoc-")
                    && e.startDate > now
                    && e.startDate < until
                    && !(e.attendees ?? []).isEmpty
                    && !handled.contains(key(e))
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// True when any brief title in the event's ±12h window is a close enough match.
    /// Same Levenshtein similarity and default threshold as the brief panel, so a
    /// brief the panel would show counts as "already briefed".
    static func hasBrief(titles: [String], for title: String, threshold: Double = 0.6) -> Bool {
        let wanted = title.lowercased()
        return titles.contains { PreCallBriefService.similarity($0.lowercased(), wanted) >= threshold }
    }

    /// Notion blocks for the page body. The callout up top makes the provenance
    /// obvious: this is a low-fidelity stand-in, not a Claude briefing.
    static func pageBlocks(summary: String, talkingPoints: [String], prepActions: [String],
                           meetingStart: Date, usedTeams: Bool, usedPriorNotes: Bool) -> [[String: Any]] {
        func rich(_ s: String) -> [[String: Any]] {
            [["type": "text", "text": ["content": String(s.prefix(1900))]]]
        }
        func clean(_ items: [String]) -> [String] {
            items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3).map { $0 }
        }
        var sources = ["calendar invite"]
        if usedPriorNotes { sources.append("prior meeting notes") }
        if usedTeams { sources.append("Teams chat") }
        let when = DateFormatter()
        when.dateFormat = "EEE d MMM, HH:mm"
        when.timeZone = TimeZone(identifier: "Europe/London")
        when.locale = Locale(identifier: "en_GB")

        var blocks: [[String: Any]] = [[
            "object": "block", "type": "callout",
            "callout": [
                "rich_text": rich("On-device draft for \(when.string(from: meetingStart)) (Apple Intelligence). No Claude briefing existed, so this was generated locally from: \(sources.joined(separator: ", ")). Lower quality, so check before relying on it. Claude replaces this page if it runs with credit."),
                "icon": ["type": "emoji", "emoji": "🤖"],
                "color": "gray_background",
            ],
        ]]
        func heading(_ s: String) {
            blocks.append(["object": "block", "type": "heading_3", "heading_3": ["rich_text": rich(s)]])
        }
        heading("Summary")
        blocks.append(["object": "block", "type": "paragraph", "paragraph": ["rich_text": rich(summary)]])
        let points = clean(talkingPoints)
        if !points.isEmpty {
            heading("Talking points")
            blocks += points.map { ["object": "block", "type": "bulleted_list_item",
                                    "bulleted_list_item": ["rich_text": rich($0)]] }
        }
        let actions = clean(prepActions)
        if !actions.isEmpty {
            heading("Prep")
            blocks += actions.map { ["object": "block", "type": "to_do",
                                     "to_do": ["rich_text": rich($0), "checked": false]] }
        }
        return blocks
    }
}

// MARK: - Service

/// Makes sure every meeting has *some* Pre-Call Briefing. Every 5 minutes it looks at
/// meetings starting before the next cloud briefing run has had its chance; any with
/// no brief in Notion gets one
/// generated by the on-device Foundation Models system model, fed the invite, the
/// most recent prior Meeting Notes, and the Teams chat context the teams-chat-mcp
/// feeder writes onto the Calendar Events row. Off by default; needs macOS 26 and
/// the Notion token.
@MainActor
final class OnDeviceBriefGapFiller: ObservableObject {
    enum Keys {
        static let enabled = "onDeviceBriefGapFillEnabled"
        static let handled = "onDeviceBriefGapFillHandled"
        static let lastResult = "onDeviceBriefGapFillLastResult"
    }

    @Published private(set) var lastResult: String = UserDefaults.standard.string(forKey: Keys.lastResult) ?? ""

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.enabled)
            objectWillChange.send()
            reconfigure()
        }
    }

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private weak var calendarService: CalendarService?
    private let enrichment: CalendarEnrichmentService
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isRunning = false
    private var handledOrder: [String]
    private var handled: Set<String>

    private let logPath: String = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingReminder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ondevice-brief-gapfill.log").path
    }()
    private lazy var logger = CalendarSyncLogger(path: logPath)

    init(calendarService: CalendarService, enrichment: CalendarEnrichmentService) {
        self.calendarService = calendarService
        self.enrichment = enrichment
        let saved = UserDefaults.standard.stringArray(forKey: Keys.handled) ?? []
        handledOrder = saved
        handled = Set(saved)
    }

    func start() { reconfigure() }

    private func reconfigure() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        guard isEnabled, Self.isSupported else { return }

        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give the network and EventKit a moment after wake.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.tick()
            }
        }
        logger.info("gap-filler started — drafting unbriefed meetings that start before the next Claude run")
        Task { await tick() }
    }

    /// One pass over the upcoming hour. Safe to call any time.
    func tick() async {
        guard isEnabled, !isRunning, let calendarService else { return }
        guard let token = KeychainHelper.read(key: CalendarSyncConstants.tokenKeychainKey), !token.isEmpty else { return }
        let now = Date()
        let horizon = GapFillPlanner.nextClaudeSettle(after: now)
        let due = GapFillPlanner.candidates(calendarService.upcomingEvents(until: horizon),
                                            now: now, until: horizon, handled: handled)
        guard !due.isEmpty else { return }

        isRunning = true
        defer { isRunning = false }
        let client = CalendarSyncNotionClient(token: token, logger: logger)
        let skipRules = (try? await CalendarSyncNotionQueries.fetchSkipRules(client: client)) ?? []

        for event in due {
            if SkipFilter.shouldSkip(title: event.title, rules: skipRules) {
                logger.info("skip-list: '\(event.title)'")
                markHandled(event)
                continue
            }
            await fill(event, client: client)
        }
    }

    // Internal (not private) so the opt-in live test can drive one real fill.
    func fill(_ event: MeetingEvent, client: CalendarSyncNotionClient) async {
        let row = await enrichment.fetchEnrichment(for: event)
        // A Notion error must never read as "no brief": that would duplicate one.
        guard let briefed = await isBriefed(event, rowID: row?.rowPageID, client: client) else {
            logger.warn("brief lookup failed for '\(event.title)' — retrying next tick")
            return
        }
        if briefed {
            logger.info("already briefed: '\(event.title)'")
            markHandled(event)
            return
        }
        guard #available(macOS 26.0, *) else { return }

        let priorNotes = await NotionPriorNotesReader.fetch(title: event.title, before: event.startDate,
                                                            logPath: logPath)
        let ctx = IntradayBriefContext.from(event, priorNotes: priorNotes, teamsContext: row?.teamsChatContext)

        let brief: GapFillBrief
        do {
            brief = try await FoundationModelsBriefService.generateGapFill(ctx)
        } catch {
            // Don't loop on a model that can't run (e.g. Apple Intelligence off).
            record("generation failed for '\(event.title)': \(error)")
            markHandled(event)
            return
        }

        // Claude may have written one while the model ran.
        if await isBriefed(event, rowID: row?.rowPageID, client: client) == true {
            logger.info("brief appeared during generation: '\(event.title)' — discarding draft")
            markHandled(event)
            return
        }

        let blocks = GapFillPlanner.pageBlocks(summary: brief.summary, talkingPoints: brief.talkingPoints,
                                               prepActions: brief.prepActions,
                                               meetingStart: event.startDate,
                                               usedTeams: ctx.teamsContext != nil,
                                               usedPriorNotes: priorNotes != nil)
        var properties: [String: Any] = [
            CalendarSyncConstants.preCallBriefingsTitleProperty: ["title": [["text": ["content": event.title]]]],
            CalendarSyncConstants.preCallBriefingsDateProperty: ["date": ["start": Self.iso(event.startDate),
                                                                          "end": Self.iso(event.endDate)]],
            "Attendees": ["rich_text": [["text": ["content": String((event.attendees ?? []).joined(separator: ", ").prefix(1900))]]]],
            // The Claude runners treat "On-device" as not-yet-briefed and rewrite the page.
            "Briefing Status": ["select": ["name": GapFillPlanner.onDeviceStatus]],
        ]
        if let rowID = row?.rowPageID {
            properties["Calendar Event"] = ["relation": [["id": rowID]]]
        }
        do {
            let resp = try await client.post(path: "/pages", body: [
                "parent": ["type": "data_source_id", "data_source_id": CalendarSyncConstants.preCallBriefingsDataSourceID],
                "properties": properties,
                "children": blocks,
            ], idempotent: false)
            markHandled(event)
            let url = resp["url"] as? String ?? "?"
            record("briefed '\(event.title)' on-device (teams=\(ctx.teamsContext != nil) notes=\(priorNotes != nil)) → \(url)")
            NotificationService.shared.postInfo(
                id: "ondevice-gapfill-\(event.id)",
                title: "🤖 On-device briefing added",
                body: "“\(event.title)” had no briefing, so a local draft is in Notion.")
        } catch {
            // Not marked: the next tick's lookup sees a create that actually landed.
            record("Notion create failed for '\(event.title)': \(error)")
        }
    }

    /// True if a brief exists: one linked to this occurrence's Calendar Events row (which
    /// catches a meeting that was moved or renamed after it was briefed), or one with a
    /// similar title dated within ±12h. nil on any Notion error.
    private func isBriefed(_ event: MeetingEvent, rowID: String?, client: CalendarSyncNotionClient) async -> Bool? {
        if let rowID {
            let body: [String: Any] = [
                "page_size": 1,
                "filter": ["property": "Calendar Event", "relation": ["contains": rowID]],
            ]
            do {
                let resp = try await client.post(
                    path: "/data_sources/\(CalendarSyncConstants.preCallBriefingsDataSourceID)/query", body: body)
                if !((resp["results"] as? [Any]) ?? []).isEmpty { return true }
            } catch {
                return nil
            }
        }
        guard let titles = await briefTitles(near: event, client: client) else { return nil }
        return GapFillPlanner.hasBrief(titles: titles, for: event.title)
    }

    /// Titles of Pre-Call Briefings dated within ±12h of the event; nil on any error.
    private func briefTitles(near event: MeetingEvent, client: CalendarSyncNotionClient) async -> [String]? {
        let date = CalendarSyncConstants.preCallBriefingsDateProperty
        let body: [String: Any] = [
            "page_size": 100,
            "filter": ["and": [
                ["property": date, "date": ["on_or_after": Self.iso(event.startDate.addingTimeInterval(-12 * 3600))]],
                ["property": date, "date": ["on_or_before": Self.iso(event.startDate.addingTimeInterval(12 * 3600))]],
            ]],
        ]
        do {
            let resp = try await client.post(
                path: "/data_sources/\(CalendarSyncConstants.preCallBriefingsDataSourceID)/query", body: body)
            let rows = resp["results"] as? [[String: Any]] ?? []
            return rows.compactMap { row in
                let props = row["properties"] as? [String: Any]
                let title = (props?[CalendarSyncConstants.preCallBriefingsTitleProperty] as? [String: Any])?["title"] as? [[String: Any]]
                let text = title?.compactMap { $0["plain_text"] as? String }.joined() ?? ""
                return text.isEmpty ? nil : text
            }
        } catch {
            return nil
        }
    }

    private func markHandled(_ event: MeetingEvent) {
        let key = GapFillPlanner.key(event)
        guard handled.insert(key).inserted else { return }
        handledOrder.append(key)
        while handledOrder.count > 300 { handled.remove(handledOrder.removeFirst()) }
        UserDefaults.standard.set(handledOrder, forKey: Keys.handled)
    }

    private func record(_ message: String) {
        logger.info(message)
        lastResult = message
        UserDefaults.standard.set(message, forKey: Keys.lastResult)
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
