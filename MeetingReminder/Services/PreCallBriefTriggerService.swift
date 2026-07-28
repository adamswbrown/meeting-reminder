import Combine
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
    private var cancellable: AnyCancellable?
    private var baselineSeeded = false
    private var firedIDs: Set<String>
    private var lastRunTime: Date?
    private var debounceTask: Task<Void, Never>?

    private let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingReminder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("precall-brief-intraday.log")
    }()

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
        self.firedIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.firedIDs) ?? [])
    }

    // MARK: Lifecycle

    /// Subscribe to calendar changes if enabled. Safe to call repeatedly.
    func start() { reconfigure() }

    private func reconfigure() {
        cancellable?.cancel()
        cancellable = nil
        debounceTask?.cancel()
        baselineSeeded = false
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
        // First emission after (re)start is the existing diary — seed the baseline so
        // we never storm on launch. Co Work owns anything already in the calendar.
        guard baselineSeeded else {
            for e in upcomingTodayMeetings(events) { firedIDs.insert(e.id) }
            persistFired()
            baselineSeeded = true
            return
        }

        let candidates = upcomingTodayMeetings(events)
            .filter { !firedIDs.contains($0.id) }
            .sorted { $0.startDate < $1.startDate }

        guard let target = candidates.first, withinWorkingHours(Date()) else { return }

        // Debounce ~30s to let a burst of calendar writes settle, then run.
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.runIfAllowed(for: target)
        }
    }

    /// Non-all-day meetings that start later today (future), used both for the baseline
    /// seed and candidate detection.
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

    // MARK: Run

    private func runIfAllowed(for target: MeetingEvent) async {
        guard isEnabled, !isRunning else { return }
        if let last = lastRunTime, Date().timeIntervalSince(last) < minInterval { return }
        // Re-confirm it's still un-fired and still upcoming (it may have been briefed
        // by Co Work in the meantime — the skill will dedup anyway, but skip the spawn).
        guard !firedIDs.contains(target.id), target.startDate > Date() else { return }

        isRunning = true
        lastRunTime = Date()
        defer { isRunning = false }

        log("firing intraday brief for: \(target.title) @ \(target.startDate)")

        let filled = buildPrompt(for: target)
        guard let filled else {
            recordResult("skill file unreadable at \(skillPath)")
            return
        }

        let output = await Self.runClaude(cliPath: cliPath, promptStdin: filled)
        // Mark fired regardless of outcome — a failed run should not loop; Co Work's
        // schedule is the backstop. (A transient failure is visible in lastResult/log.)
        firedIDs.insert(target.id)
        persistFired()

        let summary = Self.parseResult(output) ?? firstNonEmptyLine(output) ?? "(no output)"
        recordResult(summary)
        log("result: \(summary)")

        // Another new meeting may be waiting; re-check after the floor.
        if let events = calendarService?.events {
            let more = upcomingTodayMeetings(events).contains { !firedIDs.contains($0.id) }
            if more {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(self?.minInterval ?? 120) * 1_000_000_000)
                    if let events = self?.calendarService?.events { self?.handleEventsChanged(events) }
                }
            }
        }
    }

    /// Read the skill, substitute the target meeting block.
    private func buildPrompt(for target: MeetingEvent) -> String? {
        guard let template = try? String(contentsOfFile: skillPath, encoding: .utf8) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.timeZone = TimeZone(identifier: "Europe/London")
        let appleID = target.id.components(separatedBy: "_").first ?? target.id
        return template
            .replacingOccurrences(of: "{{MEETING_TITLE}}", with: target.title)
            .replacingOccurrences(of: "{{MEETING_START}}", with: fmt.string(from: target.startDate))
            .replacingOccurrences(of: "{{MEETING_END}}", with: fmt.string(from: target.endDate))
            .replacingOccurrences(of: "{{APPLE_EVENT_ID}}", with: appleID)
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

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "FAILED to launch \(cliPath): \(error.localizedDescription)")
                    return
                }

                // Feed the prompt, then close stdin so `claude --print` proceeds.
                if let data = promptStdin.data(using: .utf8) {
                    stdin.fileHandleForWriting.write(data)
                }
                stdin.fileHandleForWriting.closeFile()

                // Watchdog: kill after 10 minutes.
                let deadline = DispatchTime.now() + .seconds(600)
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning { process.terminate() }
                }

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
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

    private func persistFired() {
        // Cap the persisted set so it can't grow unbounded across days.
        var arr = Array(firedIDs)
        if arr.count > 500 { arr = Array(arr.suffix(500)); firedIDs = Set(arr) }
        UserDefaults.standard.set(arr, forKey: Keys.firedIDs)
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
