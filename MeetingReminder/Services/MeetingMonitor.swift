import AppKit
import Combine
import CoreAudio
import Foundation

@MainActor
final class MeetingMonitor: ObservableObject {
    // MARK: - Published State

    @Published var activeOverlayEvent: MeetingEvent?
    @Published var shouldShowOverlay = false
    @Published var shouldShowMinimalAlert = false
    @Published var shouldShowBreakOverlay = false
    @Published var breakNextEvent: MeetingEvent?

    /// Dynamic menu bar text: "Standup in 12m" or "No meetings"
    @Published var menuBarText: String = "No meetings"

    /// Menu bar urgency level for colour coding
    @Published var menuBarUrgency: MenuBarUrgency = .none

    /// Whether a meeting is currently considered "in progress" (for end detection)
    @Published var currentMeetingInProgress: MeetingEvent?

    /// Whether the microphone is currently active. Polled by the same audio
    /// check timer that handles meeting-end detection. Observers (e.g. the
    /// HomeKit busy-light) can subscribe to be told the moment the mic flips,
    /// independently of whether a calendar meeting is recognised.
    @Published var micActive: Bool = false

    // MARK: - Dependencies

    private var calendarService: CalendarService
    private let screenDimmer = ScreenDimmer()
    private let floatingPromptController = FloatingPromptWindowController()

    // MARK: - Timers

    private var checkTimer: Timer?
    private var menuBarTimer: Timer?

    /// App Nap opt-out token. As an `LSUIElement` agent with no windows, this app
    /// is a prime App Nap candidate — and a napped process has its run-loop timers
    /// coalesced into multi-minute buckets, which freezes the menu bar countdown
    /// and delays the pre-meeting overlay. Held for the monitor's whole lifetime.
    /// `…AllowingIdleSystemSleep` deliberately does *not* keep the Mac awake.
    private var appNapActivity: NSObjectProtocol?

    /// Re-arms the timers after sleep. Timers don't fire while the machine is
    /// asleep and can come back throttled; the calendar data is refreshed on wake
    /// by `CalendarService`, but nothing was rebuilding *these* until now.
    private var wakeObserver: Any?

    // MARK: - State Tracking

    private var shownEventIDs: Set<String> = []
    private var snoozedEvents: [String: Date] = [:]
    private var lastCleanupDate: Date = Date()
    private var firedAlertTiers: [String: Set<Int>] = [:]  // eventID -> set of tier rawValues
    private var contextSwitchPromptShown: Set<String> = []
    private var dimmingStartedFor: String?
    private var meetingEndedIDs: Set<String> = []

    // MARK: - Audio Monitoring (for meeting end detection)

    private var audioWasActive = false
    private var audioCheckTimer: Timer?
    private var audioInactiveSince: Date?  // debounce: when audio first went idle
    private let audioDebounceSeconds: TimeInterval = 30  // require 30s of silence
    /// Arms audio/app-quit end detection only once the joined meeting's own
    /// call has been seen on the mic — see `CallEndGate`.
    private var callEndGate = CallEndGate()

    // MARK: - Video App Monitoring

    private var workspaceObserver: Any?

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Settings

    var reminderMinutes: Int {
        UserDefaults.standard.integer(forKey: "reminderMinutes").clamped(to: 1...30, default: 5)
    }

    var wrapUpMinutes: Int {
        let val = UserDefaults.standard.integer(forKey: "wrapUpMinutes")
        return val > 0 ? val : 10
    }

    var progressiveAlertsEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "progressiveAlertsEnabled") == nil ||
               defaults.bool(forKey: "progressiveAlertsEnabled")
    }

    var contextSwitchPromptMinutes: Int {
        let val = UserDefaults.standard.integer(forKey: "contextSwitchPromptMinutes")
        return val > 0 ? val : 3
    }

    var breakEnforcementEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "breakEnforcementEnabled") == nil ||
               defaults.bool(forKey: "breakEnforcementEnabled")
    }

    /// When the user is in a call (mic active), use a minimal screen-share-safe alert
    /// instead of the full-screen overlay
    var inCallMinimalModeEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "inCallMinimalModeEnabled") == nil ||
               defaults.bool(forKey: "inCallMinimalModeEnabled")
    }

    /// True if the microphone is currently active (heuristic for "user is in a call")
    var isCurrentlyInCall: Bool {
        isAudioInputActive()
    }

    // MARK: - Init

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
    }

    // MARK: - Lifecycle

    func start() {
        beginAppNapExemption()
        scheduleTimers()
        observeWake()

        // Audio monitoring for meeting end detection
        startAudioMonitoring()

        // Video app lifecycle monitoring
        startVideoAppMonitoring()

        // React immediately when the calendar changes — a cancelled meeting
        // needs to vanish from the menu bar label the moment EventKit notices,
        // not on the next 10-second tick. Without this subscription the menu
        // bar can keep showing a meeting that's already been removed from the
        // user's calendar.
        calendarService.$events
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuBar()
                self?.checkUpcomingMeetings()
            }
            .store(in: &cancellables)

        checkUpcomingMeetings()
        updateMenuBar()
    }

    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        menuBarTimer?.invalidate()
        menuBarTimer = nil
        audioCheckTimer?.invalidate()
        audioCheckTimer = nil
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
        screenDimmer.restore()
        floatingPromptController.close()
    }

    // MARK: - Timer Scheduling

    /// Builds the check + menu bar timers and installs them in `.common` run-loop
    /// mode. `Timer.scheduledTimer` uses `.default`, which stops firing while a
    /// menu or popover tracking loop is up — so the countdown could freeze for as
    /// long as the menu bar popover stayed open.
    private func scheduleTimers() {
        // Main check timer — checks meetings every 30s
        checkTimer?.invalidate()
        let check = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkUpcomingMeetings()
            }
        }
        check.tolerance = 5
        RunLoop.main.add(check, forMode: .common)
        checkTimer = check

        // Menu bar update timer — updates text/color every 10s
        menuBarTimer?.invalidate()
        let menuBar = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMenuBar()
            }
        }
        menuBar.tolerance = 1
        RunLoop.main.add(menuBar, forMode: .common)
        menuBarTimer = menuBar
    }

    /// Tell the system this process is doing user-initiated work so it isn't
    /// napped. Without this, a background agent's timers get coalesced and the
    /// menu bar can sit on a stale countdown — reading "in 1h" for a meeting
    /// that's three minutes away — while notification-driven work carries on
    /// normally, which makes the app look alive when its timers aren't.
    private func beginAppNapExemption() {
        guard appNapActivity == nil else { return }
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Meeting countdown and pre-meeting alerts must fire on time"
        )
    }

    /// Rebuild the timers and resync the UI on wake. Sleep can leave a repeating
    /// timer firing late or not at all, and the first thing the user looks at
    /// after opening the lid is the menu bar countdown.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleTimers()
                self.startAudioMonitoring()
                self.checkUpcomingMeetings()
                self.updateMenuBar()
            }
        }
    }

    // MARK: - User Actions

    func dismiss() {
        // Dismissed without joining — restore any brightness we pulled down for
        // this meeting so the screen doesn't stay dim if the user never joins.
        if currentMeetingInProgress == nil {
            screenDimmer.restore()
            dimmingStartedFor = nil
        }
        shouldShowOverlay = false
        shouldShowMinimalAlert = false
        activeOverlayEvent = nil
    }

    func snooze(seconds: Int = 60) {
        guard let event = activeOverlayEvent else { return }
        snoozedEvents[event.id] = Date().addingTimeInterval(TimeInterval(seconds))
        shownEventIDs.remove(event.id)
        // Reset alert tiers so they can re-fire after snooze
        firedAlertTiers[event.id] = nil
        dismiss()
    }

    func joinMeeting() {
        guard let event = activeOverlayEvent, let url = event.videoLink else { return }
        // Track that this meeting is now in progress (user joined)
        currentMeetingInProgress = event
        audioWasActive = isAudioInputActive()
        callEndGate.begin(micActiveAtJoin: audioWasActive)
        audioInactiveSince = nil  // reset debounce for fresh meeting
        MeetingLauncher.open(url)
        dismiss()
    }

    /// Join a meeting from the menu bar event list directly, without going through
    /// the overlay. Handles the "I'm late to the meeting" case — set the calendar
    /// event as currently in progress so the recording pipeline (Minutes, context
    /// panel, live transcript, post-meeting nudge) all fire as if the user had
    /// clicked Join on the overlay.
    ///
    /// Also marks the event as "shown" so the overlay doesn't fire afterwards
    /// for this same event.
    func joinMeetingFromCalendar(_ event: MeetingEvent) {
        shownEventIDs.insert(event.id)
        currentMeetingInProgress = event
        audioWasActive = isAudioInputActive()
        callEndGate.begin(micActiveAtJoin: audioWasActive)
        audioInactiveSince = nil
        if let url = event.videoLink {
            MeetingLauncher.open(url)
        }
    }

    /// User manually marks meeting as done (menu bar button)
    func markMeetingDone() {
        guard let event = currentMeetingInProgress else { return }
        audioInactiveSince = nil
        handleMeetingEnded(event)
    }

    /// Start an ad-hoc meeting (no calendar event). Creates a synthetic MeetingEvent
    /// and sets it as `currentMeetingInProgress`, which triggers the OverlayCoordinator
    /// subscription to start `minutes record` and show post-meeting nudges as normal.
    /// `title` is optional — defaults to "Ad-hoc meeting · HH:mm".
    @discardableResult
    func startAdHocMeeting(title: String? = nil, durationMinutes: Int = 60) -> MeetingEvent {
        let now = Date()
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? title!
            : "Ad-hoc meeting · \(formatter.string(from: now))"

        let event = MeetingEvent(
            id: "adhoc-\(UUID().uuidString)",
            title: resolvedTitle,
            startDate: now,
            endDate: now.addingTimeInterval(TimeInterval(durationMinutes * 60)),
            calendar: "Ad-hoc",
            videoLink: nil,
            attendees: nil,
            notes: nil,
            location: nil
        )

        currentMeetingInProgress = event
        audioWasActive = isAudioInputActive()
        // An ad-hoc meeting is usually started for the call already on the
        // mic, so that audio counts as this meeting's own — arm on it.
        callEndGate.begin(micActiveAtJoin: false)
        audioInactiveSince = nil
        return event
    }

    func dismissBreak() {
        shouldShowBreakOverlay = false
        breakNextEvent = nil
    }

    func testOverlay() {
        let testEvent = MeetingEvent(
            id: "test-\(UUID().uuidString)",
            title: "Test Meeting — Overlay Preview",
            startDate: Date().addingTimeInterval(120),
            endDate: Date().addingTimeInterval(3720),
            calendar: "Test",
            videoLink: URL(string: "https://meet.google.com/test"),
            attendees: ["Alice", "Bob", "Charlie"],
            notes: "This is a test meeting to preview the overlay.",
            location: "Conference Room A"
        )
        activeOverlayEvent = testEvent
        shouldShowOverlay = true
        playAlertSound()
    }

    func testMinimalAlert() {
        let testEvent = MeetingEvent(
            id: "test-minimal-\(UUID().uuidString)",
            title: "Test Meeting — In-Call Mode Preview",
            startDate: Date().addingTimeInterval(120),
            endDate: Date().addingTimeInterval(3720),
            calendar: "Test",
            videoLink: URL(string: "https://meet.google.com/test"),
            attendees: ["Alice", "Bob"],
            notes: "Minimal alert preview",
            location: nil
        )
        activeOverlayEvent = testEvent
        shouldShowMinimalAlert = true
    }

    // MARK: - Menu Bar State

    private func updateMenuBar() {
        let now = Date()

        // If a meeting we were tracking has been cancelled out of the calendar
        // entirely, drop it from the overlay state so the UI doesn't reference a
        // ghost. `currentMeetingInProgress` is intentionally NOT cleared here —
        // ad-hoc meetings have synthetic IDs that aren't in calendarService.events,
        // and a calendar-driven in-progress meeting getting cancelled mid-call is
        // rare enough that we'd rather keep recording than rip the session out.
        let liveIDs = Set(calendarService.events.map { $0.id })
        if let active = activeOverlayEvent,
           !active.id.hasPrefix("test-"),
           !active.id.hasPrefix("adhoc-"),
           !liveIDs.contains(active.id) {
            activeOverlayEvent = nil
            shouldShowOverlay = false
            shouldShowMinimalAlert = false
        }

        let upcoming = calendarService.events.filter { $0.startDate > now }
        let inProgress = calendarService.events.first(where: { $0.isInProgress })

        if let current = inProgress {
            // Wrap-up nudge: only when we're actually in a meeting and the
            // next one is close enough that the user should start wrapping up.
            if let next = upcoming.first {
                let minutesUntilNext = Double(next.timeUntilStart) / 60.0
                if minutesUntilNext <= Double(wrapUpMinutes) {
                    menuBarText = "Wrap up — \(next.title) in \(next.shortTimeUntil)"
                } else {
                    menuBarText = "\(current.title) (in progress)"
                }
            } else {
                menuBarText = "\(current.title) (in progress)"
            }
            menuBarUrgency = .inProgress
        } else if let next = upcoming.first {
            let minutesUntil = Double(next.timeUntilStart) / 60.0
            menuBarText = "\(next.title) in \(next.shortTimeUntil)"
            menuBarUrgency = MenuBarUrgency.from(
                minutesUntil: minutesUntil,
                isInProgress: false
            )
        } else {
            menuBarText = "No meetings"
            menuBarUrgency = .none
        }
    }

    // MARK: - Core Check Loop

    private func checkUpcomingMeetings() {
        let now = Date()

        // Daily cleanup. Only wipe tracking for events that aren't currently
        // within the alert window — clearing an active event's state at the
        // first tick after midnight would let a dismissed overlay re-fire.
        if !Calendar.current.isDate(now, inSameDayAs: lastCleanupDate) {
            let activeIDs = Set(
                calendarService.events
                    .filter { event in
                        let delta = event.startDate.timeIntervalSince(now)
                        return delta <= 3600 && delta >= -3600
                    }
                    .map { $0.id }
            )
            shownEventIDs = shownEventIDs.filter { activeIDs.contains($0) }
            snoozedEvents = snoozedEvents.filter { activeIDs.contains($0.key) }
            firedAlertTiers = firedAlertTiers.filter { activeIDs.contains($0.key) }
            contextSwitchPromptShown = contextSwitchPromptShown.filter { activeIDs.contains($0) }
            meetingEndedIDs = meetingEndedIDs.filter { activeIDs.contains($0) }
            lastCleanupDate = now
        }

        // Clean up expired snoozes
        snoozedEvents = snoozedEvents.filter { $0.value > now }

        // Check for meetings that just ended (calendar-based fallback)
        checkMeetingEnded()

        // Backstop: if we dimmed for a meeting the user never joined and it's
        // now more than 2 min past its start, restore brightness so a skipped
        // meeting doesn't leave the screen dark.
        if let dimmedID = dimmingStartedFor, currentMeetingInProgress == nil,
           let dimmedEvent = calendarService.events.first(where: { $0.id == dimmedID }),
           now.timeIntervalSince(dimmedEvent.startDate) > 120 {
            screenDimmer.restore()
            dimmingStartedFor = nil
        }

        for event in calendarService.events {
            let minutesUntil = event.timeUntilStart / 60.0

            // Skip already-ended meetings we've processed
            guard !meetingEndedIDs.contains(event.id) else { continue }

            // Skip if snoozed
            if let snoozeUntil = snoozedEvents[event.id], now < snoozeUntil {
                continue
            }

            // Progressive alerts (if enabled)
            if progressiveAlertsEnabled {
                handleProgressiveAlerts(event: event, minutesUntil: minutesUntil)
            }

            // Context-switch prompt
            if minutesUntil > 0 && minutesUntil <= Double(contextSwitchPromptMinutes) &&
               !contextSwitchPromptShown.contains(event.id) &&
               !shownEventIDs.contains(event.id) {
                contextSwitchPromptShown.insert(event.id)
                floatingPromptController.show(
                    meetingTitle: event.title,
                    minutesUntil: Int(ceil(minutesUntil)),
                    onDismiss: { [weak self] in
                        self?.floatingPromptController.close()
                    }
                )
            }

            // Screen dimming (start 5 min before)
            if minutesUntil > 0 && minutesUntil <= 5 && dimmingStartedFor != event.id {
                dimmingStartedFor = event.id
                screenDimmer.startDimming(durationSeconds: minutesUntil * 60)
            }

            // Blocking overlay (existing behavior)
            let reminderSeconds = TimeInterval(reminderMinutes * 60)
            let timeUntil = event.timeUntilStart

            // When progressive alerts are on, the full-screen overlay is the
            // "blocking" tier and is gated by its toggle. With progressive
            // alerts off, the overlay always fires at reminderMinutes.
            let blockingAllowed = !progressiveAlertsEnabled ||
                AlertTier.blocking.isEnabled

            // A snooze that expired after the meeting already slipped past the
            // -60s window would otherwise never bring the overlay back. If an
            // expired snooze entry still exists for a recently-started, not-yet-
            // joined/ended meeting, re-fire regardless of the normal windows.
            if let snoozeUntil = snoozedEvents[event.id], snoozeUntil <= now,
               timeUntil <= 0 && timeUntil > -600,
               currentMeetingInProgress?.id != event.id,
               !shownEventIDs.contains(event.id) {
                snoozedEvents[event.id] = nil
                if blockingAllowed {
                    triggerOverlay(for: event)
                    return
                }
            }

            if !shownEventIDs.contains(event.id) && blockingAllowed {
                if timeUntil > 0 && timeUntil <= reminderSeconds {
                    triggerOverlay(for: event)
                    return
                }

                // Also trigger for events that just started (within 60 seconds)
                if timeUntil <= 0 && timeUntil > -60 {
                    triggerOverlay(for: event)
                    return
                }
            }

            // Catch-up overlay: if the app wasn't running during either fire
            // window above (e.g. it launched or was redeployed after the
            // meeting already started), a meeting still underway would be
            // silently missed. Fire once, bounded to `OverlayCatchUp.window`
            // after start so a long-running meeting the user is already in
            // isn't nudged on every launch. triggerOverlay downgrades to the
            // screen-share-safe minimal alert when the mic is hot.
            if OverlayCatchUp.shouldFire(
                timeUntilStart: timeUntil,
                isInProgress: event.isInProgress,
                hasEnded: event.hasEnded,
                alreadyShown: shownEventIDs.contains(event.id),
                isSnoozed: snoozedEvents[event.id] != nil,
                isCurrentMeeting: currentMeetingInProgress?.id == event.id,
                blockingAllowed: blockingAllowed
            ) {
                triggerOverlay(for: event)
                return
            }

            // Last-chance tier: the overlay fired earlier and was dismissed, but
            // the user never joined. Re-fire it once as the meeting starts.
            if progressiveAlertsEnabled && AlertTier.lastChance.isEnabled &&
               timeUntil <= 0 && timeUntil > -60 &&
               shownEventIDs.contains(event.id) &&
               !shouldShowOverlay && !shouldShowMinimalAlert &&
               snoozedEvents[event.id] == nil &&
               !meetingEndedIDs.contains(event.id) &&
               currentMeetingInProgress?.id != event.id {
                let fired = firedAlertTiers[event.id] ?? []
                if !fired.contains(AlertTier.lastChance.rawValue) {
                    var updated = fired
                    updated.insert(AlertTier.lastChance.rawValue)
                    firedAlertTiers[event.id] = updated
                    shownEventIDs.remove(event.id)
                    triggerOverlay(for: event)
                    return
                }
            }
        }
    }

    // MARK: - Progressive Alerts

    private func handleProgressiveAlerts(event: MeetingEvent, minutesUntil: Double) {
        guard minutesUntil > 0 else { return }

        let firedTiers = firedAlertTiers[event.id] ?? []

        for tier in AlertTier.allCases {
            guard tier.isEnabled else { continue }
            guard !firedTiers.contains(tier.rawValue) else { continue }
            guard minutesUntil <= Double(tier.minutesBefore) else { continue }

            // Don't fire tiers that would conflict with the blocking overlay
            if tier == .blocking || tier == .lastChance { continue }

            var updatedTiers = firedTiers
            updatedTiers.insert(tier.rawValue)
            firedAlertTiers[event.id] = updatedTiers

            switch tier {
            case .ambient:
                // Just update menu bar color — handled by updateMenuBar()
                break
            case .banner:
                NotificationService.shared.postWrapUpBanner(
                    eventID: event.id,
                    title: event.title,
                    minutesUntil: Int(ceil(minutesUntil))
                )
            case .urgent:
                playAlertSound()
            case .blocking, .lastChance:
                break // Handled by main check loop
            }
        }
    }

    // MARK: - Meeting End Detection

    /// Calendar-based fallback: detect meetings that passed their endDate
    private func checkMeetingEnded() {
        guard let snapshot = currentMeetingInProgress else { return }

        // `currentMeetingInProgress` is a snapshot from join time. If the
        // organiser has since extended or shortened the meeting, judge the end
        // against the live calendar copy, not the stale endDate. Reassigning is
        // safe: the coordinator's sinks de-duplicate on id.
        let current = MeetingMonitorLogic.refreshed(snapshot, from: calendarService.events)
        if current != snapshot {
            currentMeetingInProgress = current
        }

        if current.hasEnded {
            handleMeetingEnded(current)
        }
    }

    /// Called when we detect a meeting has ended (from any signal)
    private func handleMeetingEnded(_ event: MeetingEvent) {
        meetingEndedIDs.insert(event.id)
        currentMeetingInProgress = nil
        screenDimmer.restore()
        floatingPromptController.close()
        dimmingStartedFor = nil

        // Check for break enforcement
        if breakEnforcementEnabled,
           let nextEvent = calendarService.nextBackToBackEvent(after: event) {
            breakNextEvent = nextEvent
            shouldShowBreakOverlay = true
        }
    }

    // MARK: - Audio Monitoring (Primary meeting-end signal)

    private func startAudioMonitoring() {
        audioCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAudioState()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        audioCheckTimer = timer
    }

    private func checkAudioState() {
        let audioActive = isAudioInputActive()

        // Always publish the raw mic state so observers (HomeKit busy-light)
        // can react even when there's no calendar meeting in progress.
        if micActive != audioActive {
            micActive = audioActive
        }

        guard currentMeetingInProgress != nil else {
            audioInactiveSince = nil
            audioWasActive = audioActive
            return
        }

        // Back-to-back guard: the previous call's mic going quiet must not end
        // the meeting just joined. Ignore audio until this call is observed.
        callEndGate.observe(micActive: audioActive)
        guard callEndGate.isArmed else {
            audioInactiveSince = nil
            audioWasActive = audioActive
            return
        }

        if audioActive {
            // Audio is active — reset the debounce timer
            audioInactiveSince = nil
        } else if audioWasActive && !audioActive && audioInactiveSince == nil {
            // Audio just went inactive — start the debounce clock
            audioInactiveSince = Date()
        } else if let inactiveSince = audioInactiveSince,
                  Date().timeIntervalSince(inactiveSince) >= audioDebounceSeconds {
            // Audio has been inactive for 30+ seconds — meeting is over
            audioInactiveSince = nil
            if let event = currentMeetingInProgress {
                handleMeetingEnded(event)
            }
        }

        audioWasActive = audioActive
    }

    /// Check if any audio input device is currently running (mic in use).
    ///
    /// On macOS 14+ we use a process-aware check that ignores known always-on
    /// listeners (Superwhisper, dictation, etc.) so the busy light isn't
    /// pinned by background apps that just happen to keep the mic open. The
    /// ignored bundle ID set is the default list plus anything the user has
    /// added via `busyLightIgnoredAudioBundleIDs` UserDefaults.
    ///
    /// On macOS 13 there's no process API so we fall back to the device-level
    /// signal — same behavior as before.
    private func isAudioInputActive() -> Bool {
        let userIgnored = UserDefaults.standard.stringArray(forKey: "busyLightIgnoredAudioBundleIDs") ?? []
        let ignored = AudioProcessMonitor.defaultIgnoredBundleIDs.union(userIgnored)
        if let processBased = AudioProcessMonitor.isAnyOtherProcessUsingInput(ignoredBundleIDs: ignored) {
            return processBased
        }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return false }

        // Check if the device is running
        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let runningStatus = AudioObjectGetPropertyData(
            deviceID,
            &runningAddress,
            0, nil,
            &runningSize,
            &isRunning
        )

        return runningStatus == noErr && isRunning != 0
    }

    // MARK: - Video App Lifecycle Monitoring

    private func startVideoAppMonitoring() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }

                // Check if the terminated app is a video conferencing app
                let videoAppBundleIDs = [
                    "us.zoom.xos",           // Zoom
                    "com.microsoft.teams",    // Teams (old)
                    "com.microsoft.teams2",   // Teams (new)
                    "com.cisco.webexmeetingsapp", // Webex
                    "com.tinyspeck.slackmacgap",  // Slack
                ]

                // Only once this meeting's call has been seen: quitting the
                // previous meeting's app must not end a back-to-back join.
                if videoAppBundleIDs.contains(bundleID),
                   self.callEndGate.isArmed,
                   let event = self.currentMeetingInProgress {
                    self.handleMeetingEnded(event)
                }
            }
        }
    }

    // MARK: - Overlay Trigger

    private func triggerOverlay(for event: MeetingEvent) {
        shownEventIDs.insert(event.id)
        activeOverlayEvent = event
        floatingPromptController.close() // Close context-switch prompt

        // If user is in a call (mic active), use the minimal screen-share-safe alert
        // instead of the full-screen overlay
        if inCallMinimalModeEnabled && isCurrentlyInCall {
            shouldShowMinimalAlert = true
            // No sound — don't disturb the call
        } else {
            shouldShowOverlay = true
            playAlertSound()
        }
    }

    private func playAlertSound() {
        if UserDefaults.standard.object(forKey: "soundEnabled") == nil ||
           UserDefaults.standard.bool(forKey: "soundEnabled") {
            NSSound.beep()
        }
    }
}

/// Pure decisions extracted from `MeetingMonitor` so they're unit-testable
/// without timers, EventKit, or Core Audio.
enum MeetingMonitorLogic {
    /// The live calendar copy of an in-progress meeting, falling back to the
    /// join-time snapshot when the event isn't in the list (ad-hoc meetings,
    /// or a meeting cancelled mid-call).
    static func refreshed(_ current: MeetingEvent, from live: [MeetingEvent]) -> MeetingEvent {
        live.first(where: { $0.id == current.id }) ?? current
    }
}

/// Decides when the audio-silence and video-app-quit signals may end the
/// current meeting. Joining a back-to-back meeting while the previous call
/// still holds the mic used to hand that call's hang-up (or app quit) to the
/// new meeting and end it early. If the mic was hot at join time, the gate
/// waits for it to go quiet and come back — this meeting's own call — before
/// arming. Joined from idle, the first mic activity arms it. Unarmed, the
/// meeting still ends by calendar end time or "Done with meeting".
struct CallEndGate {
    private(set) var isArmed = false
    private var waitingForPreviousCallToEnd = false

    mutating func begin(micActiveAtJoin: Bool) {
        isArmed = false
        waitingForPreviousCallToEnd = micActiveAtJoin
    }

    mutating func observe(micActive: Bool) {
        guard !isArmed else { return }
        if waitingForPreviousCallToEnd {
            if !micActive { waitingForPreviousCallToEnd = false }
        } else if micActive {
            isArmed = true
        }
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>, default defaultValue: Int) -> Int {
        if self == 0 { return defaultValue }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
