import AppKit
import Combine
import CoreAudio
import Foundation

@MainActor
final class MeetingMonitor: ObservableObject {
    // MARK: - Published State

    @Published var activeOverlayEvent: MeetingEvent?
    @Published var shouldShowOverlay = false
    @Published var shouldShowBreakOverlay = false
    @Published var breakNextEvent: MeetingEvent?

    /// Dynamic menu bar text: "Standup in 12m" or "No meetings"
    @Published var menuBarText: String = "No meetings"

    /// Menu bar urgency level for colour coding
    @Published var menuBarUrgency: MenuBarUrgency = .none

    /// Whether a meeting is currently considered "in progress" (for end detection)
    @Published var currentMeetingInProgress: MeetingEvent?

    // MARK: - Dependencies

    private var calendarService: CalendarService
    private let screenDimmer = ScreenDimmer()
    private let floatingPromptController = FloatingPromptWindowController()

    // MARK: - Timers

    private var checkTimer: Timer?
    private var menuBarTimer: Timer?

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

    // MARK: - Video App Monitoring

    private var workspaceObserver: Any?

    // MARK: - Notion Integration

    private var notionPageIDs: [String: String] = [:]  // eventID -> notionPageID
    private var notionPageURLs: [String: URL] = [:]    // eventID -> notionPageURL

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

    // MARK: - Init

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
    }

    // MARK: - Lifecycle

    func start() {
        // Main check timer — checks meetings every 30s
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkUpcomingMeetings()
            }
        }

        // Menu bar update timer — updates text/color every 10s
        menuBarTimer?.invalidate()
        menuBarTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMenuBar()
            }
        }

        // Audio monitoring for meeting end detection
        startAudioMonitoring()

        // Video app lifecycle monitoring
        startVideoAppMonitoring()

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
        screenDimmer.restore()
        floatingPromptController.close()
    }

    // MARK: - User Actions

    func dismiss() {
        shouldShowOverlay = false
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
        audioInactiveSince = nil  // reset debounce for fresh meeting
        NSWorkspace.shared.open(url)
        dismiss()
    }

    /// User manually marks meeting as done (menu bar button)
    func markMeetingDone() {
        guard let event = currentMeetingInProgress else { return }
        audioInactiveSince = nil
        handleMeetingEnded(event)
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

    // MARK: - Notion Integration

    func setNotionPage(eventID: String, pageID: String, pageURL: URL) {
        notionPageIDs[eventID] = pageID
        notionPageURLs[eventID] = pageURL
    }

    func notionPageURL(for eventID: String) -> URL? {
        notionPageURLs[eventID]
    }

    // MARK: - Menu Bar State

    private func updateMenuBar() {
        let now = Date()
        let upcoming = calendarService.events.filter { $0.startDate > now }
        let inProgress = calendarService.events.first(where: { $0.isInProgress })

        if let current = inProgress {
            menuBarText = "\(current.title) (in progress)"
            menuBarUrgency = .inProgress
        } else if let next = upcoming.first {
            let minutesUntil = Double(next.timeUntilStart) / 60.0

            // Wrap-up nudge
            if minutesUntil <= Double(wrapUpMinutes) && minutesUntil > Double(reminderMinutes) {
                menuBarText = "Wrap up — \(next.title) in \(next.shortTimeUntil)"
            } else {
                menuBarText = "\(next.title) in \(next.shortTimeUntil)"
            }

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

        // Daily cleanup
        if !Calendar.current.isDate(now, inSameDayAs: lastCleanupDate) {
            shownEventIDs.removeAll()
            snoozedEvents.removeAll()
            firedAlertTiers.removeAll()
            contextSwitchPromptShown.removeAll()
            meetingEndedIDs.removeAll()
            lastCleanupDate = now
        }

        // Clean up expired snoozes
        snoozedEvents = snoozedEvents.filter { $0.value > now }

        // Check for meetings that just ended (calendar-based fallback)
        checkMeetingEnded()

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

            if !shownEventIDs.contains(event.id) {
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
        guard let current = currentMeetingInProgress else { return }

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
        audioCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAudioState()
            }
        }
    }

    private func checkAudioState() {
        guard currentMeetingInProgress != nil else {
            audioInactiveSince = nil
            return
        }

        let audioActive = isAudioInputActive()

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

    /// Check if any audio input device is currently running (mic in use)
    private func isAudioInputActive() -> Bool {
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
                    "com.google.Chrome",      // Chrome (for Meet) — too broad, skip
                    "com.cisco.webexmeetingsapp", // Webex
                    "com.tinyspeck.slackmacgap",  // Slack
                ]

                if videoAppBundleIDs.contains(bundleID),
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
        shouldShowOverlay = true
        floatingPromptController.close() // Close context-switch prompt
        playAlertSound()
    }

    private func playAlertSound() {
        if UserDefaults.standard.object(forKey: "soundEnabled") == nil ||
           UserDefaults.standard.bool(forKey: "soundEnabled") {
            NSSound.beep()
        }
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>, default defaultValue: Int) -> Int {
        if self == 0 { return defaultValue }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
