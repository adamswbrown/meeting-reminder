import Combine
import EventKit
import Foundation

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
@MainActor
final class PreCallBriefTriggerService: ObservableObject {

    // MARK: Settings keys
    enum Keys {
        static let enabled = "preCallBriefTriggerEnabled"
        static let cliPath = "preCallBriefCLIPath"
        static let skillPath = "preCallBriefSkillPath"
        static let minInterval = "preCallBriefMinIntervalSeconds"
        static let firedIDs = "preCallBriefFiredIDs"
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

    // MARK: Internal state
    private weak var calendarService: CalendarService?
    private let notifications = NotificationService.shared
    private var cancellable: AnyCancellable?
    /// The set of upcoming-today meeting IDs seen on the *previous* emission. A candidate
    /// is an ID present now but absent then — updated on EVERY emission (incl. outside
    /// working hours) so the midnight/day-rollover set is absorbed silently, not fired.
    /// `nil` = not yet seeded.
    private var previousUpcomingIDs: Set<String>?
    private var seeded = false               // has the diff basis been established from a real (non-empty) emission?
    private var lastSeenDay: Date?           // start-of-day of the last emission — detects rollover
    private var firedIDs: Set<String>       // fast membership test
    private var firedOrder: [String]        // insertion order, for bounded FIFO eviction
    private var skillMissingLatched = false // stop retrying every poll when the skill file is absent
    private var lastRunTime: Date?
    private var debounceTask: Task<Void, Never>?
    private var pending: [MeetingEvent] = []    // detected-but-not-yet-briefed, drained serially
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
        previousUpcomingIDs = nil   // next real emission re-seeds the diff basis (absorb, don't fire)
        seeded = false
        lastSeenDay = nil
        pending.removeAll()
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
        let current = upcomingTodayMeetings(events)
        let currentIDs = Set(current.map(\.id))
        let previous = previousUpcomingIDs
        // Always advance the diff basis (even outside hours) so pre-existing meetings are
        // absorbed and only genuinely-new appearances ever fire.
        previousUpcomingIDs = currentIDs

        if skillMissingLatched { return }

        // Day rollover — the whole new day's diary would otherwise diff as "new". Absorb it
        // silently and clear any stale pending from yesterday (NEW-3).
        let today = Calendar.current.startOfDay(for: Date())
        let rolled = lastSeenDay != nil && lastSeenDay != today
        lastSeenDay = today
        if rolled {
            pending.removeAll()
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

        // Enqueue every genuinely-new appearance (a batch sync can surface several at once);
        // they drain one at a time. Dedup against the queue + already-fired.
        let pendingIDs = Set(pending.map(\.id))
        let newOnes = current.filter {
            !previous.contains($0.id) && !firedIDs.contains($0.id) && !pendingIDs.contains($0.id)
        }
        guard !newOnes.isEmpty else { return }
        pending.append(contentsOf: newOnes)
        pending.sort { $0.startDate < $1.startDate }

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

    private func withinWorkingHours(_ date: Date) -> Bool {
        let cal = Calendar.current
        let comps = cal.dateComponents([.weekday, .hour], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour else { return false }
        // weekday: 1=Sun … 7=Sat. Working days Mon(2)–Fri(6).
        let isWeekday = (2...6).contains(weekday)
        return isWeekday && (9..<17).contains(hour)
    }

    /// Seconds until the next weekday 09:00 strictly after `now` (0 if already in-window).
    /// Used to re-arm the drain when a booking lands outside working hours.
    private func secondsUntilNextWorkingWindow(from now: Date = Date()) -> TimeInterval {
        if withinWorkingHours(now) { return 0 }
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        for i in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: i, to: startToday),
                  let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { continue }
            let wd = cal.component(.weekday, from: nine)
            if (2...6).contains(wd) && nine > now {
                return max(60, nine.timeIntervalSince(now))
            }
        }
        return 3600
    }

    // MARK: Run

    /// Process the pending queue one meeting at a time, honouring the floor + working
    /// hours + the single-in-flight guard. Re-arms itself while the queue is non-empty.
    private func drainPending() async {
        guard isEnabled, !isRunning, !skillMissingLatched else { return }
        // Drop targets that are no longer relevant (already fired, or already started).
        pending.removeAll { firedIDs.contains($0.id) || $0.startDate <= Date() }
        // Outside working hours: don't fire, but DON'T strand the queue — re-arm for the
        // next 09:00 window so an early-morning booking is briefed when hours open (NEW-2).
        guard withinWorkingHours(Date()) else {
            if !pending.isEmpty { scheduleDrain(after: secondsUntilNextWorkingWindow()) }
            return
        }
        if let last = lastRunTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {                      // floor not elapsed — retry later
                scheduleDrain(after: minInterval - elapsed)
                return
            }
        }
        guard !pending.isEmpty else { return }
        let target = pending.removeFirst()
        await runOne(target)
        if !pending.isEmpty { scheduleDrain(after: minInterval) }
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

        guard let filled = buildPrompt(for: target) else {
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

    /// Read the skill, substitute the target meeting block.
    private func buildPrompt(for target: MeetingEvent) -> String? {
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
