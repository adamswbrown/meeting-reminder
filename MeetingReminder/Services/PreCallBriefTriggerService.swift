import Combine
import EventKit
import Foundation

/// Pure text builder for the **instant** Slack ping fired the moment a new meeting is
/// detected — a lightweight "something landed" alert that reaches Slack within the ~2 min
/// detection window, ahead of the full headless briefing (which takes ~8 min to compose).
/// Kept pure (no Keychain/network) so it is unit-testable; the actual POST lives on
/// `PreCallBriefTriggerService.postSlackPing`.
enum IntradaySlackPing {
    static func message(title: String, start: Date, now: Date,
                        timeZone: TimeZone = TimeZone(identifier: "Europe/London") ?? .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_GB")
        timeFmt.timeZone = timeZone
        timeFmt.dateFormat = "HH:mm"
        let timeStr = timeFmt.string(from: start)

        let dayWord: String
        if cal.isDate(start, inSameDayAs: now) {
            dayWord = "today"
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
                  cal.isDate(start, inSameDayAs: tomorrow) {
            dayWord = "tomorrow"
        } else {
            let dateFmt = DateFormatter()
            dateFmt.locale = Locale(identifier: "en_GB")
            dateFmt.timeZone = timeZone
            dateFmt.dateFormat = "EEE d MMM"
            dayWord = dateFmt.string(from: start)
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "📅 New meeting just landed — *\(cleanTitle)* @ \(timeStr) \(dayWord). Full brief to follow."
    }
}

/// Pure decision for the intraday brief catcher: given a meeting's start time and
/// the current time, should we brief it **now**, **wait** until a later time, or
/// **drop** it?
///
/// This exists to close the working-hours "dead zone": a meeting that starts at (or
/// just after) the 09:00 window-open used to be un-briefable — before 09:00 the gate
/// deferred it to 09:00, and at 09:00 the "already-started" drop discarded it before
/// it could fire. Two rules fix that:
///   - **(A) imminent exemption** — a meeting that starts *before* the next working
///     window opens can't wait, so it's briefed now even outside hours; a meeting
///     that starts *at/after* the open waits for the window (kept in-hours, no
///     antisocial-hours Slack for an evening booking).
///   - **(C) started-grace** — the "already-started" drop tolerates a short grace
///     (default 5 min) so a meeting isn't discarded in the seconds between detection,
///     the debounce, and the drain — and a brief for a just-started meeting is still
///     worth sending.
struct IntradayBriefGate {
    var calendar: Calendar
    var workStartHour: Int
    var workEndHour: Int              // exclusive upper bound (matches 9..<17)
    var workdays: ClosedRange<Int>    // Calendar weekday: 1=Sun … 7=Sat → Mon–Fri = 2...6
    var startedGrace: TimeInterval    // (C) tolerance past a meeting's start before we drop it

    init(calendar: Calendar = .current,
         workStartHour: Int = 9,
         workEndHour: Int = 17,
         workdays: ClosedRange<Int> = 2...6,
         startedGrace: TimeInterval = 300) {
        self.calendar = calendar
        self.workStartHour = workStartHour
        self.workEndHour = workEndHour
        self.workdays = workdays
        self.startedGrace = startedGrace
    }

    enum Decision: Equatable {
        case fireNow
        case waitUntil(Date)
        case drop
    }

    func decide(meetingStart: Date, now: Date) -> Decision {
        // (C) Started beyond the grace window → no longer a pre-call brief.
        if meetingStart <= now.addingTimeInterval(-startedGrace) { return .drop }
        // In working hours → brief now (the caller still applies its min-interval floor).
        if isWithinWorkingHours(now) { return .fireNow }
        // Outside hours. (A) A meeting that starts *before* the next window opens can't
        // wait — brief it now. One that starts *at/after* the open waits for the window,
        // so an evening/early-morning booking doesn't fire an antisocial-hours alert.
        let open = nextWorkingWindowOpen(after: now)
        if meetingStart < open { return .fireNow }
        return .waitUntil(open)
    }

    func isWithinWorkingHours(_ date: Date) -> Bool {
        let comps = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour else { return false }
        return workdays.contains(weekday) && (workStartHour..<workEndHour).contains(hour)
    }

    /// Soonest workday `workStartHour:00` strictly after `now`. Returns `now` when
    /// already in-window (callers gate on `isWithinWorkingHours` first, but this keeps
    /// the function total).
    func nextWorkingWindowOpen(after now: Date) -> Date {
        if isWithinWorkingHours(now) { return now }
        let startToday = calendar.startOfDay(for: now)
        for i in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: i, to: startToday),
                  let open = calendar.date(bySettingHour: workStartHour, minute: 0, second: 0, of: day)
            else { continue }
            if workdays.contains(calendar.component(.weekday, from: open)) && open > now {
                return open
            }
        }
        return now.addingTimeInterval(3600)   // pathological fallback
    }
}

/// Intraday pre-call briefing catcher.
///
/// The counterpart to the cloud "Co Work" Daily Pre-Call Briefing task (which runs
/// at ~03:00 and owns the morning digest + daily reconciliation). This service does
/// exactly one thing: when a genuinely-new meeting lands in the diary **during the
/// working day (09:00–17:00, Mon–Fri)**, it fires a headless `claude` run of the
/// *derived intraday skill* (`automation/pre-call-briefing-intraday.md`) for that
/// meeting — same briefing rules as Co Work, but delivering via local CLIs
/// (`imessage-tools` + `remctl`) because the interactively-authenticated MCP servers
/// are absent in a background spawn.
///
/// It keys off EventKit (via `CalendarService.$events`), NOT the Notion reactive sync
/// (which may be disabled), and the skill re-derives everything from the ICS feed, so
/// no Notion Calendar Events row need pre-exist. Dedup is owned by the skill's Step 3
/// property-filter check, which is what keeps it from double-briefing meetings Co Work
/// already handled.
/// Classifies a debounce window's worth of calendar appearances (`added`) and
/// disappearances (`removed`) into new meetings, **reschedules**, and
/// **cancellations**. A move typically surfaces as a same-title event vanishing at
/// one time and reappearing at another; pairing those into a single reschedule is
/// what stops a moved meeting from firing both a "cancelled" and a "new meeting"
/// alert — the user wants one "moved" post instead.
struct IntradayCalendarDiff {
    struct Reschedule { let old: MeetingEvent; let new: MeetingEvent }
    var newMeetings: [MeetingEvent]
    var reschedules: [Reschedule]
    var cancellations: [MeetingEvent]
}

enum IntradayDiffClassifier {
    static func classify(added: [MeetingEvent], removed: [MeetingEvent]) -> IntradayCalendarDiff {
        var remainingAdded = added
        var reschedules: [IntradayCalendarDiff.Reschedule] = []
        var cancellations: [MeetingEvent] = []
        for r in removed {
            // A move = same title, different start. Same title + same start isn't a
            // move (ambiguous duplicate) — leave both as separate signals.
            if let idx = remainingAdded.firstIndex(where: {
                normalizedTitle($0.title) == normalizedTitle(r.title) && $0.startDate != r.startDate
            }) {
                reschedules.append(.init(old: r, new: remainingAdded.remove(at: idx)))
            } else {
                cancellations.append(r)
            }
        }
        return IntradayCalendarDiff(newMeetings: remainingAdded,
                                    reschedules: reschedules,
                                    cancellations: cancellations)
    }

    /// Case/whitespace-insensitive title key used to pair a move's two halves.
    static func normalizedTitle(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class PreCallBriefTriggerService: ObservableObject {

    // MARK: Settings keys
    enum Keys {
        static let enabled = "preCallBriefTriggerEnabled"
        static let cliPath = "preCallBriefCLIPath"
        static let skillPath = "preCallBriefSkillPath"
        static let minInterval = "preCallBriefMinIntervalSeconds"
        static let firedIDs = "preCallBriefFiredIDs"
        static let removalFiredIDs = "preCallBriefRemovalFiredIDs"
        static let lastResult = "preCallBriefLastResult"
        static let lastRunAt = "preCallBriefLastRunAt"
    }

    // MARK: Published state (for Settings display)
    @Published private(set) var isRunning = false
    @Published private(set) var lastResult: String = UserDefaults.standard.string(forKey: Keys.lastResult) ?? ""
    @Published private(set) var lastRunAt: Date? = UserDefaults.standard.object(forKey: Keys.lastRunAt) as? Date

    // MARK: Config (read-through to UserDefaults, with sensible defaults)
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.enabled)
            objectWillChange.send()
            reconfigure()
        }
    }

    private var cliPath: String {
        UserDefaults.standard.string(forKey: Keys.cliPath) ?? "/usr/local/bin/claude"
    }

    private var skillPath: String {
        if let p = UserDefaults.standard.string(forKey: Keys.skillPath), !p.isEmpty { return p }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent("Developer/meeting-reminder/automation/pre-call-briefing-intraday.md")
    }

    private var minInterval: TimeInterval {
        let v = UserDefaults.standard.integer(forKey: Keys.minInterval)
        return v > 0 ? TimeInterval(v) : 120
    }

    /// Working-hours gate + imminent-exemption + started-grace. Defaults match the
    /// original hardcoded policy (Mon–Fri 09:00–17:00) with a 5-min started grace.
    private let gate = IntradayBriefGate()

    // MARK: Internal state
    private weak var calendarService: CalendarService?
    private let notifications = NotificationService.shared
    private var cancellable: AnyCancellable?
    /// Upcoming-today meetings seen on the *previous* emission, keyed by id — retained
    /// as full events (not just ids) so a meeting that *disappears* can still be
    /// described to the removal skill (title/start/appleID). Advanced on EVERY emission
    /// (incl. outside working hours) so the midnight/day-rollover set is absorbed
    /// silently, not fired. `nil` = not yet seeded.
    private var previousUpcoming: [String: MeetingEvent]?
    private var seeded = false               // has the diff basis been established from a real (non-empty) emission?
    private var lastSeenDay: Date?           // start-of-day of the last emission — detects rollover
    private var firedIDs: Set<String>       // fast membership test (briefs)
    private var firedOrder: [String]        // insertion order, for bounded FIFO eviction
    private var firedRemovalIDs: Set<String> // fast membership test (removals/reschedules)
    private var firedRemovalOrder: [String]  // insertion order for bounded eviction
    private var skillMissingLatched = false // stop retrying every poll when the skill file is absent
    private var lastRunTime: Date?
    private var debounceTask: Task<Void, Never>?
    private var pending: [MeetingEvent] = []    // detected-but-not-yet-briefed, drained serially

    /// A meeting that vanished from the diary during the day (cancelled or moved).
    /// `likelyReschedule` only tunes the local macOS banner wording — the skill
    /// re-derives cancel-vs-moved authoritatively from the ICS + Notion and posts one
    /// Slack line either way.
    private struct RemovalJob { let meeting: MeetingEvent; let likelyReschedule: Bool }
    private var pendingRemovals: [RemovalJob] = []

    private var permissionStore: EKEventStore?  // retained across the async consent callback

    private let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingReminder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("precall-brief-intraday.log")
    }()

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
        let saved = UserDefaults.standard.stringArray(forKey: Keys.firedIDs) ?? []
        self.firedOrder = saved
        self.firedIDs = Set(saved)
        let savedRemovals = UserDefaults.standard.stringArray(forKey: Keys.removalFiredIDs) ?? []
        self.firedRemovalOrder = savedRemovals
        self.firedRemovalIDs = Set(savedRemovals)
        // A child that closes its stdin before we finish writing must not SIGPIPE-kill
        // the whole app (M4). We handle the write error explicitly instead.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: Lifecycle

    /// Subscribe to calendar changes if enabled. Safe to call repeatedly.
    func start() { reconfigure() }

    /// Trigger the two TCC consent prompts that the Automation and Reminders panes
    /// can't be populated any other way (they have no `+` button — an app only appears
    /// after it programmatically requests access). Call from a foreground moment
    /// (the Settings button) so the prompts actually surface.
    ///
    /// The spawned `imessage-tools` / `remctl` inherit the app as the TCC-responsible
    /// process, so granting the app here unblocks them.
    @Published private(set) var permissionStatus: String = ""

    func requestPermissions() {
        // Reminders — surfaces the Reminders consent prompt + lists the app in the pane.
        // Retain the store as a property so it can't deallocate before the async consent
        // callback fires (M5).
        let store = EKEventStore()
        permissionStore = store
        let handler: (Bool, Error?) -> Void = { [weak self] granted, error in
            Task { @MainActor in
                let msg = "Reminders access: \(granted ? "granted" : "DENIED")\(error.map { " (\($0.localizedDescription))" } ?? "")"
                self?.permissionStatus = msg
                self?.log(msg)
                // Only release if it's still our store (a rapid second tap may have
                // replaced it — don't free that one out from under its callback).
                if self?.permissionStore === store { self?.permissionStore = nil }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders(completion: handler)
        } else {
            store.requestAccess(to: .reminder, completion: handler)
        }
        // Automation (control Messages) — send one harmless Apple Event so macOS shows
        // "MeetingReminder wants to control Messages" and lists the app in Automation.
        // Spawn `osascript` (a child of the app, so TCC attributes the request to the app)
        // rather than NSAppleScript, which is main-thread-only and blocks up to the consent
        // timeout (M5).
        // Blocks up to the consent-dialog timeout, so run it on a GCD thread (not the
        // cooperative pool) to avoid starving Swift concurrency.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // Must be an automation-GATED command (reading `chats` requires controlling
            // Messages) — a benign `get name` is not gated and never surfaces the prompt.
            proc.arguments = ["-e", "tell application \"Messages\" to count of chats"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var ok = false
            do {
                try proc.run()
                proc.waitUntilExit()
                ok = (proc.terminationStatus == 0)
            } catch { ok = false }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor in
                let m = ok
                    ? "Messages automation: prompt shown / already allowed"
                    : "Messages automation: denied — \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
                self?.permissionStatus = m
                self?.log(m)
            }
        }
    }

    private func reconfigure() {
        cancellable?.cancel()
        cancellable = nil
        debounceTask?.cancel()
        previousUpcoming = nil   // next real emission re-seeds the diff basis (absorb, don't fire)
        seeded = false
        lastSeenDay = nil
        pending.removeAll()
        pendingRemovals.removeAll()
        skillMissingLatched = false
        guard isEnabled, let calendarService else { return }

        cancellable = calendarService.$events
            .receive(on: RunLoop.main)
            .sink { [weak self] events in
                self?.handleEventsChanged(events)
            }
        log("started — watching calendar for intraday new meetings (09:00–17:00)")
    }

    // MARK: Candidate detection

    private func handleEventsChanged(_ events: [MeetingEvent]) {
        let now = Date()
        let current = upcomingTodayMeetings(events)
        let currentIDs = Set(current.map(\.id))
        let previous = previousUpcoming
        // Always advance the diff basis (even outside hours) so pre-existing meetings are
        // absorbed and only genuinely-new appearances/disappearances ever fire.
        previousUpcoming = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })

        if skillMissingLatched { return }

        // Day rollover — the whole new day's diary would otherwise diff as "new". Absorb it
        // silently and clear any stale pending from yesterday (NEW-3).
        let today = Calendar.current.startOfDay(for: now)
        let rolled = lastSeenDay != nil && lastSeenDay != today
        lastSeenDay = today
        if rolled {
            pending.removeAll()
            pendingRemovals.removeAll()
            return
        }

        // Seed the diff basis on the first emission that carries REAL data. Until the
        // calendar has actually loaded (`events` empty = access pending / not yet synced),
        // keep waiting — otherwise the initial diary looks "new". Once seeded, a genuinely
        // empty upcoming list is fine: a later booking still fires (NEW-1).
        if !seeded {
            if !events.isEmpty { seeded = true }
            return
        }
        guard let previous else { return }

        // Genuinely-new appearances (a batch sync can surface several at once).
        let pendingIDs = Set(pending.map(\.id))
        let added = current.filter {
            previous[$0.id] == nil && !firedIDs.contains($0.id) && !pendingIDs.contains($0.id)
        }
        // Genuine disappearances: present before, absent now, AND still in the future.
        // A meeting whose start has passed left "upcoming" because it STARTED, not
        // because it was removed — never treat that as a cancellation.
        let pendingRemovalIDs = Set(pendingRemovals.map(\.meeting.id))
        let removed = previous.values.filter {
            currentIDs.contains($0.id) == false
                && $0.startDate > now
                && !firedRemovalIDs.contains($0.id)
                && !pendingRemovalIDs.contains($0.id)
        }

        guard !added.isEmpty || !removed.isEmpty else { return }

        // Pair a same-title move into a single reschedule so it doesn't fire both a
        // "cancelled" and a "new meeting" alert (user wants one "moved" post).
        let diff = IntradayDiffClassifier.classify(added: added, removed: removed)

        // New meetings → brief queue. Also drop any new meeting whose title matches a
        // still-pending removal at a different time (a reschedule split across emissions):
        // the removal job will report the move, so don't also brief the new occurrence.
        let removalTitles = Set(pendingRemovals.map { IntradayDiffClassifier.normalizedTitle($0.meeting.title) })
        let freshBriefs = diff.newMeetings.filter {
            !removalTitles.contains(IntradayDiffClassifier.normalizedTitle($0.title))
        }
        pending.append(contentsOf: freshBriefs)
        pending.sort { $0.startDate < $1.startDate }

        // Reschedules + cancellations → removal queue (the skill decides which it is).
        pendingRemovals.append(contentsOf: diff.reschedules.map { RemovalJob(meeting: $0.old, likelyReschedule: true) })
        pendingRemovals.append(contentsOf: diff.cancellations.map { RemovalJob(meeting: $0, likelyReschedule: false) })
        pendingRemovals.sort { $0.meeting.startDate < $1.meeting.startDate }

        // Debounce ~30s to let a burst of calendar writes settle, then drain.
        scheduleDrain(after: 30)
    }

    private func scheduleDrain(after seconds: TimeInterval) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.drainPending()
        }
    }

    /// Non-all-day meetings that start later today (future).
    private func upcomingTodayMeetings(_ events: [MeetingEvent]) -> [MeetingEvent] {
        let now = Date()
        let cal = Calendar.current
        return events.filter { ev in
            !ev.isAllDay
                && ev.startDate > now
                && cal.isDateInToday(ev.startDate)
        }
    }

    // MARK: Run

    /// Process the brief + removal queues one meeting at a time, honouring the
    /// min-interval floor + the `IntradayBriefGate` (working hours, imminent exemption,
    /// started grace) + the single-in-flight guard (only ever one `claude` running).
    /// Re-arms itself while either queue is non-empty.
    private func drainPending() async {
        guard isEnabled, !isRunning, !skillMissingLatched else { return }
        let now = Date()
        // Drop already-fired items and those the gate says are too far past their start.
        pending.removeAll { firedIDs.contains($0.id) || gate.decide(meetingStart: $0.startDate, now: now) == .drop }
        pendingRemovals.removeAll {
            firedRemovalIDs.contains($0.meeting.id)
                || gate.decide(meetingStart: $0.meeting.startDate, now: now) == .drop
        }
        guard !pending.isEmpty || !pendingRemovals.isEmpty else { return }

        // Respect the floor between runs (retry once it elapses).
        if let last = lastRunTime {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < minInterval {
                scheduleDrain(after: minInterval - elapsed)
                return
            }
        }

        // Fire the earliest-starting item the gate clears *now* — brief or removal,
        // whichever meeting starts soonest. A meeting starting at/after the next
        // window-open is left to wait (kept in-hours); one starting before the window
        // opens fires now even outside hours (closes the 09:00 dead zone).
        let firableBrief = pending
            .filter { gate.decide(meetingStart: $0.startDate, now: now) == .fireNow }
            .min { $0.startDate < $1.startDate }
        let firableRemoval = pendingRemovals
            .filter { gate.decide(meetingStart: $0.meeting.startDate, now: now) == .fireNow }
            .min { $0.meeting.startDate < $1.meeting.startDate }

        switch (firableBrief, firableRemoval) {
        case let (brief?, removal?):
            if brief.startDate <= removal.meeting.startDate {
                pending.removeAll { $0.id == brief.id }; await runOne(brief)
            } else {
                pendingRemovals.removeAll { $0.meeting.id == removal.meeting.id }; await runRemoval(removal)
            }
        case let (brief?, nil):
            pending.removeAll { $0.id == brief.id }; await runOne(brief)
        case let (nil, removal?):
            pendingRemovals.removeAll { $0.meeting.id == removal.meeting.id }; await runRemoval(removal)
        case (nil, nil):
            // Nothing eligible now — re-arm for the soonest window-open across both queues.
            let soonest = ([pending.map(\.startDate), pendingRemovals.map(\.meeting.startDate)]
                .flatMap { $0 })
                .compactMap { start -> Date? in
                    if case .waitUntil(let t) = gate.decide(meetingStart: start, now: now) { return t }
                    return nil
                }.min()
            if let soonest { scheduleDrain(after: max(60, soonest.timeIntervalSince(now))) }
            return
        }
        if !pending.isEmpty || !pendingRemovals.isEmpty { scheduleDrain(after: minInterval) }
    }

    private func runOne(_ target: MeetingEvent) async {
        isRunning = true
        lastRunTime = Date()
        defer { isRunning = false }

        log("firing intraday brief for: \(target.title) @ \(target.startDate)")

        // Announce detection — a standard macOS notification so Adam knows a new meeting
        // was picked up and a briefing is being generated.
        let notifID = "intraday-\(target.id)"
        notifications.postInfo(
            id: notifID,
            title: "🆕 New meeting detected",
            body: "Generating a pre-call briefing for “\(target.title)”…")

        // Instant Slack ping — reaches #daily-breifings within the ~2 min detection window,
        // ahead of the ~8 min full brief, so Adam knows "as soon as humanly possible".
        // Fire-and-forget; does not block the brief below.
        postSlackPing(text: IntradaySlackPing.message(
            title: target.title, start: target.startDate, now: Date()))

        guard let filled = buildPrompt(for: target, mode: "NEW") else {
            // Skill file missing (it's gitignored) — latch so we don't retry every poll,
            // and warn once. Do NOT mark fired; re-enabling the toggle clears the latch.
            skillMissingLatched = true
            recordResult("skill file unreadable at \(skillPath)")
            notifications.postInfo(id: notifID, title: "⚠️ Briefing not generated",
                                   body: "Skill file missing at \(skillPath)", sound: true)
            return
        }

        let output = await Self.runClaude(cliPath: cliPath, promptStdin: filled)
        // Mark fired regardless of outcome — a failed run should not loop; Co Work's
        // schedule is the backstop.
        markFired(target.id)

        let summary = Self.parseResult(output) ?? firstNonEmptyLine(output) ?? "(no output)"
        recordResult(summary)

        // Completion banner — report a delivery failure even when a brief WAS created (M6).
        let created = summary.contains("created=") && !summary.contains("created=0")
        let deliveryFailed = summary.contains("imessage=failed")
        if created && !deliveryFailed {
            notifications.postInfo(id: notifID, title: "✅ Pre-call briefing ready",
                                   body: "“\(target.title)” — briefing saved to Notion.")
        } else if created {
            notifications.postInfo(id: notifID, title: "⚠️ Briefing saved, alert not sent",
                                   body: "“\(target.title)” — iMessage failed; check permissions / the Run Log.", sound: true)
        } else if deliveryFailed || summary.lowercased().contains("fail") {
            notifications.postInfo(id: notifID, title: "⚠️ Briefing generated with issues",
                                   body: "“\(target.title)” — see the log / Notion Run Log.", sound: true)
        } else {
            // e.g. already-briefed / no change
            notifications.postInfo(id: notifID, title: "Pre-call briefing",
                                   body: "“\(target.title)” — \(summary)")
        }
        log("result: \(summary)")
    }

    /// Fire the skill in REMOVED mode for a meeting that vanished from the diary. The
    /// skill re-derives cancel-vs-moved from the ICS + Notion and posts one Slack line;
    /// the app just reports which it looked like locally.
    private func runRemoval(_ job: RemovalJob) async {
        isRunning = true
        lastRunTime = Date()
        defer { isRunning = false }

        let target = job.meeting
        let verb = job.likelyReschedule ? "moved" : "removed"
        log("firing intraday removal (\(verb)) for: \(target.title) @ \(target.startDate)")

        let notifID = "intraday-removal-\(target.id)"
        notifications.postInfo(
            id: notifID,
            title: job.likelyReschedule ? "🔁 Meeting moved" : "🗑️ Meeting removed",
            body: "Checking “\(target.title)” and posting an update…")

        guard let filled = buildPrompt(for: target, mode: "REMOVED") else {
            skillMissingLatched = true
            recordResult("skill file unreadable at \(skillPath)")
            notifications.postInfo(id: notifID, title: "⚠️ Update not sent",
                                   body: "Skill file missing at \(skillPath)", sound: true)
            return
        }

        let output = await Self.runClaude(cliPath: cliPath, promptStdin: filled)
        markFiredRemoval(target.id)   // never loop, regardless of outcome
        let summary = Self.parseResult(output) ?? firstNonEmptyLine(output) ?? "(no output)"
        recordResult(summary)

        let deliveryFailed = summary.contains("imessage=failed")
        if deliveryFailed || summary.lowercased().contains("fail") {
            notifications.postInfo(id: notifID, title: "⚠️ Update generated with issues",
                                   body: "“\(target.title)” — see the log / Notion Run Log.", sound: true)
        } else {
            notifications.postInfo(id: notifID, title: "✅ Calendar update sent",
                                   body: "“\(target.title)” — \(summary)")
        }
        log("removal result: \(summary)")
    }

    /// Read the skill, substitute the target meeting block. `mode` is `NEW` (brief) or
    /// `REMOVED` (cancellation/reschedule).
    private func buildPrompt(for target: MeetingEvent, mode: String) -> String? {
        guard let template = try? String(contentsOfFile: skillPath, encoding: .utf8) else { return nil }
        let london = TimeZone(identifier: "Europe/London")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.timeZone = london

        // H2: build the "Apple Event ID" with the same convention as CalendarEventMapper —
        // the Exchange external UID, suffixed `_YYYY-MM-DD` (Europe/London) for a recurring
        // occurrence so the skill's reschedule CASE 1/2 discriminator works. Falls back to
        // the title+start path only when EventKit gives us no external identifier.
        let appleID: String
        if let ext = target.externalID, !ext.isEmpty {
            if target.isRecurring {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                df.timeZone = london
                df.locale = Locale(identifier: "en_US_POSIX")   // match CalendarEventMapper (H2)
                appleID = "\(ext)_\(df.string(from: target.startDate))"
            } else {
                appleID = ext
            }
        } else {
            appleID = "(unknown — match by title+start)"
        }

        // H3: the title/times come from a calendar invite anyone can send, and the skill
        // is told to also read the (attacker-controllable) ICS description. Neutralise
        // fence/placeholder tokens so injected control text can't break out of the data
        // block. The skill header additionally frames the TARGET block as untrusted data.
        func neutralise(_ s: String) -> String {
            s.replacingOccurrences(of: "{{", with: "⦃⦃")
                .replacingOccurrences(of: "}}", with: "⦄⦄")
                .replacingOccurrences(of: "```", with: "ˋˋˋ")
        }
        // Title is free-form → also cap length. The Apple Event ID is app-generated (safe
        // charset) → neutralise only, NEVER truncate (a clipped `_YYYY-MM-DD` suffix would
        // flip the skill's reschedule discriminator, NEW-4).
        let safeTitle = String(neutralise(target.title).prefix(300))
        return template
            .replacingOccurrences(of: "{{TRIGGER_MODE}}", with: mode)
            .replacingOccurrences(of: "{{MEETING_TITLE}}", with: safeTitle)
            .replacingOccurrences(of: "{{MEETING_START}}", with: fmt.string(from: target.startDate))
            .replacingOccurrences(of: "{{MEETING_END}}", with: fmt.string(from: target.endDate))
            .replacingOccurrences(of: "{{APPLE_EVENT_ID}}", with: neutralise(appleID))
    }

    // MARK: Process (runs off the main actor)

    /// Spawns `claude --print --dangerously-skip-permissions`, feeding the prompt on
    /// stdin. Returns combined stdout/stderr. Times out after 10 minutes.
    nonisolated private static func runClaude(cliPath: String, promptStdin: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = ["--print", "--dangerously-skip-permissions"]
                process.currentDirectoryURL = FileManager.default.temporaryDirectory

                // Inherit env; ensure PATH covers claude, bun (~/.bun/bin) and ~/bin.
                var env = ProcessInfo.processInfo.environment
                let home = NSHomeDirectory()
                let extra = ["/usr/local/bin", "/opt/homebrew/bin", "\(home)/.bun/bin", "\(home)/bin"]
                let path = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = (extra + [path]).joined(separator: ":")
                if env["HOME"] == nil { env["HOME"] = home }
                process.environment = env

                let stdin = Pipe(), stdout = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stdout

                // Resume the continuation exactly once, from whichever path finishes first
                // (normal read, launch failure, or the watchdog). Guarantees `isRunning`
                // is released even if a claude tool grandchild keeps the stdout pipe open
                // after the parent is killed and `readDataToEndOfFile` never sees EOF (NEW-5).
                let resumeLock = NSLock()
                var didResume = false
                func finish(_ result: String) {
                    resumeLock.lock(); defer { resumeLock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: result)
                }

                do {
                    try process.run()
                } catch {
                    finish("FAILED to launch \(cliPath): \(error.localizedDescription)")
                    return
                }

                // Feed the prompt on a SEPARATE queue so the read loop below starts
                // immediately — otherwise a child that emits >64KB before draining stdin
                // would deadlock writer and reader (M4). SIGPIPE is ignored process-wide
                // (see init); a closed pipe surfaces as a thrown error we swallow.
                DispatchQueue.global(qos: .utility).async {
                    if let data = promptStdin.data(using: .utf8) {
                        try? stdin.fileHandleForWriting.write(contentsOf: data)
                    }
                    try? stdin.fileHandleForWriting.close()
                }

                // Watchdog: SIGTERM at 10 min, SIGKILL 15s later, and resume regardless so a
                // wedged read can't hang the queue forever (M3/NEW-5). The read thread may
                // leak until the OS reaps it, but the feature keeps working.
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(600)) {
                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(15)) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        finish("(intraday run timed out after ~10m — process terminated)")
                    }
                }

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                finish(String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    // MARK: Helpers

    nonisolated private static func parseResult(_ output: String) -> String? {
        output.components(separatedBy: .newlines)
            .last { $0.contains("INTRADAY_RESULT:") }?
            .trimmingCharacters(in: .whitespaces)
    }

    private func firstNonEmptyLine(_ s: String) -> String? {
        s.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func recordResult(_ summary: String) {
        lastResult = summary
        lastRunAt = Date()
        UserDefaults.standard.set(summary, forKey: Keys.lastResult)
        UserDefaults.standard.set(lastRunAt, forKey: Keys.lastRunAt)
    }

    /// Record an ID as fired, preserving insertion order so the cap evicts the *oldest*
    /// (not a random hash-ordered) entry (M2).
    private func markFired(_ id: String) {
        guard !firedIDs.contains(id) else { return }
        firedIDs.insert(id)
        firedOrder.append(id)
        while firedOrder.count > 500 {
            firedIDs.remove(firedOrder.removeFirst())
        }
        UserDefaults.standard.set(firedOrder, forKey: Keys.firedIDs)
    }

    /// As `markFired`, but for removal/reschedule runs (separate dedup set so a briefed
    /// meeting that later gets cancelled can still fire its removal update).
    private func markFiredRemoval(_ id: String) {
        guard !firedRemovalIDs.contains(id) else { return }
        firedRemovalIDs.insert(id)
        firedRemovalOrder.append(id)
        while firedRemovalOrder.count > 500 {
            firedRemovalIDs.remove(firedRemovalOrder.removeFirst())
        }
        UserDefaults.standard.set(firedRemovalOrder, forKey: Keys.removalFiredIDs)
    }

    /// #daily-breifings — the same channel the intraday briefing skill posts to.
    private static let slackChannelID = "C0BMEG01M1N"

    /// Fire-and-forget instant Slack ping on detection. Reuses the `slackBotToken`
    /// Keychain entry the briefing skill uses. Non-blocking — never delays the brief;
    /// the full brief (with its own delivery + error handling) remains the durable path.
    /// Posts as whatever bot the token belongs to; no `username` override (that needs the
    /// `chat:write.customize` scope), so rebrand the bot in the Slack app config to change it.
    private func postSlackPing(text: String) {
        guard let token = KeychainHelper.read(key: "slackBotToken"), !token.isEmpty else {
            log("intraday ping: no slackBotToken in Keychain — instant ping skipped")
            return
        }
        guard let url = URL(string: "https://slack.com/api/chat.postMessage") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "channel": Self.slackChannelID, "text": text,
            "unfurl_links": false, "unfurl_media": false])

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            let ok = (data
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["ok"] as? Bool) ?? false
            Task { @MainActor in
                if ok { self?.log("intraday ping: instant Slack alert sent") }
                else { self?.log("intraday ping: instant Slack alert FAILED (\(err?.localizedDescription ?? "ok=false"))") }
            }
        }.resume()
    }

    private func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}
