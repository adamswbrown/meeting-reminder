import Combine
import SwiftUI

@main
struct MeetingReminderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var calendarService = CalendarService()
    @StateObject private var meetingMonitor: MeetingMonitor
    @StateObject private var overlayCoordinator: OverlayCoordinator
    @StateObject private var minutesService: MinutesService
    @StateObject private var liveTranscriptService: LiveTranscriptService
    @StateObject private var obsidianService = ObsidianService()
    @StateObject private var notionService = NotionService()

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("colorBlindMode") private var colorBlindMode = false

    private let onboardingController = OnboardingWindowController()

    /// Tracks whether services have been started. The `.task` on the menu bar
    /// label fires at app launch (the label is always rendered), so this
    /// prevents duplicate starts if SwiftUI re-evaluates the label.
    @State private var hasStartedServices = false

    init() {
        let calendar = CalendarService()
        let monitor = MeetingMonitor(calendarService: calendar)
        let minutes = MinutesService()
        let live = LiveTranscriptService()
        let obsidian = ObsidianService()
        let notion = NotionService()
        let coordinator = OverlayCoordinator(
            monitor: monitor,
            minutesService: minutes,
            liveTranscriptService: live,
            obsidianService: obsidian,
            notionService: notion
        )
        _calendarService = StateObject(wrappedValue: calendar)
        _meetingMonitor = StateObject(wrappedValue: monitor)
        _overlayCoordinator = StateObject(wrappedValue: coordinator)
        _minutesService = StateObject(wrappedValue: minutes)
        _liveTranscriptService = StateObject(wrappedValue: live)
        _obsidianService = StateObject(wrappedValue: obsidian)
        _notionService = StateObject(wrappedValue: notion)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                calendarService: calendarService,
                meetingMonitor: meetingMonitor,
                minutesService: minutesService,
                overlayCoordinator: overlayCoordinator
            )
        } label: {
            menuBarLabel
                .task {
                    // Best practice: start services when the menu bar label
                    // appears (i.e. at app launch), NOT when the popover is
                    // first opened. The label is always rendered; the popover
                    // content is lazy.
                    guard !hasStartedServices else { return }
                    hasStartedServices = true

                    await calendarService.requestAccess()
                    calendarService.startMonitoring()
                    meetingMonitor.start()
                    overlayCoordinator.startObserving()
                    minutesService.startStatusPolling()

                    if !hasCompletedOnboarding {
                        onboardingController.show(calendarService: calendarService)
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                calendarService: calendarService,
                minutesService: minutesService,
                liveTranscriptService: liveTranscriptService,
                obsidianService: obsidianService,
                notionService: notionService
            )
        }
    }

    // MARK: - Dynamic Menu Bar Label

    @ViewBuilder
    private var menuBarLabel: some View {
        let urgency = meetingMonitor.menuBarUrgency
        let symbolName = urgency.symbolName
        let colorName = colorBlindMode ? urgency.colorBlindColorName : urgency.standardColorName

        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(menuBarColor(colorName))
            Text(meetingMonitor.menuBarText)
                .font(.system(size: 12))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meeting Reminder: \(meetingMonitor.menuBarText)")
    }

    private func menuBarColor(_ name: String) -> Color {
        switch name {
        case "green":   return .green
        case "yellow":  return .yellow
        case "orange":  return .orange
        case "red":     return .red
        case "blue":    return .blue
        case "cyan":    return .cyan
        case "magenta": return .pink
        default:        return .primary
        }
    }
}

@MainActor
final class OverlayCoordinator: ObservableObject {
    private let monitor: MeetingMonitor
    private let minutesService: MinutesService
    private let liveTranscriptService: LiveTranscriptService
    let obsidianService: ObsidianService
    private let notionService: NotionService
    private let windowController = OverlayWindowController()
    private let breakWindowController = BreakOverlayWindowController()
    private let checklistController = ChecklistWindowController()
    private let contextPanelController = ContextPanelWindowController()
    private let postMeetingController = PostMeetingNudgeWindowController()
    private let minimalAlertController = MinimalAlertWindowController()
    private let liveTranscriptController: LiveTranscriptWindowController
    private var cancellables = Set<AnyCancellable>()

    init(
        monitor: MeetingMonitor,
        minutesService: MinutesService,
        liveTranscriptService: LiveTranscriptService,
        obsidianService: ObsidianService,
        notionService: NotionService
    ) {
        self.monitor = monitor
        self.minutesService = minutesService
        self.liveTranscriptService = liveTranscriptService
        self.obsidianService = obsidianService
        self.notionService = notionService
        self.liveTranscriptController = LiveTranscriptWindowController(service: liveTranscriptService)

        // Detect minutes CLI installation in the background, but only if the
        // user has opted into the Minutes integration — otherwise there's no
        // reason to probe the CLI at all.
        if minutesService.integrationEnabled {
            Task { await minutesService.detectInstall() }
        }

        // Ensure all panels are closed when the app terminates
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closeAllPanels()
                // Best-effort: stop any active recording on quit
                if let service = self?.minutesService {
                    await service.stopRecording()
                }
            }
        }
    }

    private func closeAllPanels() {
        windowController.close()
        breakWindowController.close()
        checklistController.close()
        contextPanelController.close()
        postMeetingController.close()
        minimalAlertController.close()
        liveTranscriptController.close()
    }

    /// Present an NSAlert describing a failed `minutes record` attempt.
    /// Offers to open the Minutes settings tab where the user can inspect the
    /// config (commonly the cause: stale device name, empty live_transcript
    /// model, etc.). Also offers to copy the stderr to the clipboard for
    /// debugging / bug reports.
    static func presentRecordingFailureAlert(_ failure: MinutesService.RecordingFailure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't start recording"
        alert.informativeText = """
        Meeting: \(failure.attemptedTitle)

        \(failure.summary)

        Minutes can fail when the recording device in config.toml no longer matches your connected microphones, when the whisper model isn't installed, or when another recording is already running.
        """

        alert.addButton(withTitle: "Open Minutes Settings")
        alert.addButton(withTitle: "Copy error details")
        alert.addButton(withTitle: "Dismiss")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Open the Settings window → Minutes tab
            if #available(macOS 14.0, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        case .alertSecondButtonReturn:
            let fullDetails = """
            minutes record failure
            ======================
            Title: \(failure.attemptedTitle)
            Summary: \(failure.summary)

            Stderr:
            \(failure.stderr)
            """
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(fullDetails, forType: .string)
        default:
            break
        }
    }

    // MARK: - Preview Methods

    /// Show the pre-meeting checklist as a standalone preview (no overlay)
    func previewChecklist() {
        checklistController.show { [weak self] in
            self?.checklistController.close()
        }
    }

    /// Show the meeting context panel with a sample meeting for preview.
    /// Also opens the live transcript pane with seeded data so both panels
    /// can be previewed together as they'd appear during a real meeting.
    func previewContextPanel() {
        let sampleEvent = MeetingEvent(
            id: "preview-\(UUID().uuidString)",
            title: "Sample Meeting — Context Panel Preview",
            startDate: Date().addingTimeInterval(600),
            endDate: Date().addingTimeInterval(2400),
            calendar: "Work",
            videoLink: URL(string: "https://meet.google.com/sample"),
            attendees: ["Alice Johnson", "Bob Smith", "Charlie Davis"],
            notes: "Quarterly review of the new product roadmap. Please review the linked deck before the meeting and come prepared with feedback.",
            location: "Conference Room A / Google Meet"
        )
        contextPanelController.show(event: sampleEvent, minutesService: minutesService) { [weak self] in
            self?.contextPanelController.close()
        }
        previewLiveTranscript()
    }

    /// Show the live transcript pane with seeded sample data — works even
    /// if Minutes isn't installed or live transcripts are disabled in Settings.
    func previewLiveTranscript() {
        liveTranscriptService.loadPreviewData()
        liveTranscriptController.show(
            onClose: { [weak self] in
                self?.liveTranscriptController.close()
                self?.liveTranscriptService.clear()
            },
            onEndMeeting: { [weak self] in
                self?.liveTranscriptController.close()
                self?.liveTranscriptService.clear()
            },
            isPreview: true
        )
    }

    func startObserving() {
        // Meeting overlay
        monitor.$shouldShowOverlay
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldShow in
                guard let self else { return }
                if shouldShow, let event = monitor.activeOverlayEvent {
                    windowController.show(
                        event: event,
                        onDismiss: { [weak self] in
                            self?.monitor.dismiss()
                            self?.checklistController.close()
                        },
                        onSnooze: { [weak self] seconds in
                            self?.monitor.snooze(seconds: seconds)
                            self?.checklistController.close()
                        },
                        onJoin: { [weak self] in
                            self?.monitor.joinMeeting()
                            self?.checklistController.close()
                        }
                    )
                    // Show checklist alongside overlay
                    checklistController.show {
                        // Checklist dismissed independently
                    }
                } else {
                    windowController.close()
                    checklistController.close()
                }
            }
            .store(in: &cancellables)

        // Minimal alert (in-call mode — no checklist, no full screen)
        monitor.$shouldShowMinimalAlert
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldShow in
                guard let self else { return }
                if shouldShow, let event = monitor.activeOverlayEvent {
                    minimalAlertController.show(
                        event: event,
                        onDismiss: { [weak self] in
                            self?.monitor.dismiss()
                        },
                        onSnooze: { [weak self] seconds in
                            self?.monitor.snooze(seconds: seconds)
                        },
                        onJoin: { [weak self] in
                            self?.monitor.joinMeeting()
                        }
                    )
                } else {
                    minimalAlertController.close()
                }
            }
            .store(in: &cancellables)

        // Break overlay
        monitor.$shouldShowBreakOverlay
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldShow in
                guard let self else { return }
                if shouldShow, let nextEvent = monitor.breakNextEvent {
                    breakWindowController.show(
                        nextEvent: nextEvent,
                        onSkip: { [weak self] in
                            self?.monitor.dismissBreak()
                        }
                    )
                } else {
                    breakWindowController.close()
                }
            }
            .store(in: &cancellables)

        // Recording lifecycle: when a meeting transitions in-progress, fire
        // each opt-in integration independently.
        //
        //  - Notion (primary): create a page in the configured database and
        //    open it in the desktop app. Notion's AI Meeting Notes block
        //    handles recording + summarisation from there.
        //  - Minutes (feature-flagged, off by default): start `minutes record`,
        //    show the AI prep brief in the context panel, open the live
        //    transcript pane. Only runs when `minutesService.integrationEnabled`.
        //  - Context panel: still shown for every meeting regardless of
        //    integrations — attendees + notes + location are useful on their own.
        monitor.$currentMeetingInProgress
            .receive(on: RunLoop.main)
            .removeDuplicates(by: { $0?.id == $1?.id })
            .compactMap { $0 }
            .sink { [weak self] event in
                guard let self else { return }

                // Notion: create page + open in desktop app (fire-and-forget).
                // On failure, surface the error as a banner so the user isn't
                // left wondering why nothing happened.
                if self.notionService.isActive {
                    Task { @MainActor in
                        if let pageURL = await self.notionService.createMeetingPage(for: event) {
                            NotionService.openInNotionApp(pageURL)
                        } else if let detail = self.notionService.lastError {
                            // lastError is nil for a silent deduplication skip (page
                            // already created for this event), so only show the banner
                            // when there is an actual API or configuration failure.
                            NotificationService.shared.postIntegrationFailure(
                                integration: "Notion",
                                detail: detail
                            )
                        }
                    }
                }

                // Minutes: only if the user has explicitly opted in.
                let minutesEnabled = self.minutesService.integrationEnabled
                if minutesEnabled {
                    Task { @MainActor in
                        // detectInstall() only runs at launch when the toggle is
                        // already on. If the user enables it after launch, isInstalled
                        // is still false. Re-detect now so we don't silently skip.
                        if !self.minutesService.isInstalled {
                            await self.minutesService.detectInstall()
                        }
                        guard self.minutesService.isInstalled else { return }

                        // Start recording if auto-record is on.
                        if self.minutesService.autoRecord {
                            // Pause Core Audio silence detection — `minutes record` will hold
                            // the mic and the silence debounce can never fire while it's running.
                            self.monitor.externalRecordingActive = true
                            await self.minutesService.startRecording(for: event)
                        }

                        // Live transcript pane.
                        if self.liveTranscriptService.liveTranscriptEnabled {
                            // Small delay so the recording sidecar has time to create the JSONL file.
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            self.liveTranscriptController.show(
                                onClose: { [weak self] in
                                    self?.liveTranscriptController.close()
                                },
                                onEndMeeting: { [weak self] in
                                    self?.monitor.markMeetingDone()
                                }
                            )
                        }
                    }
                }

                // Show context panel with prep brief alongside the meeting.
                // Pass `nil` for minutesService when the integration is disabled
                // so the panel doesn't try to load a prep brief.
                self.contextPanelController.show(
                    event: event,
                    minutesService: minutesEnabled ? self.minutesService : nil
                ) { [weak self] in
                    self?.contextPanelController.close()
                }
            }
            .store(in: &cancellables)

        // Recording failure: when `minutes record` fails (stale device config,
        // missing model, etc.), roll back the optimistic "in-progress" state
        // that the UI set when the user clicked Join / Start ad-hoc, and show
        // a diagnostic alert with the captured stderr. This prevents the UI
        // from sitting in a "Recording" state while no recording exists.
        minutesService.$recordingDidFail
            .receive(on: RunLoop.main)
            .compactMap { $0 }
            .sink { [weak self] failure in
                guard let self else { return }
                // Roll back monitor state so the menu bar goes back to idle /
                // shows ad-hoc start button
                self.monitor.externalRecordingActive = false
                self.monitor.currentMeetingInProgress = nil
                // Close the panels we opened in anticipation of a recording
                self.contextPanelController.close()
                self.liveTranscriptController.close()
                // Clear the failure so it can fire again next time
                self.minutesService.recordingDidFail = nil
                // Surface to the user with actionable diagnostics
                Self.presentRecordingFailureAlert(failure)
            }
            .store(in: &cancellables)

        // Post-meeting: detect transition from in-progress to ended, stop the
        // recording, fetch the parsed meeting, and show the nudge.
        monitor.$currentMeetingInProgress
            .receive(on: RunLoop.main)
            .removeDuplicates(by: { $0?.id == $1?.id })
            .scan((nil, nil) as (MeetingEvent?, MeetingEvent?)) { prev, current in
                (prev.1, current)
            }
            .sink { [weak self] (previous, current) in
                guard let self else { return }
                if let ended = previous, current == nil {
                    // Always close the panels we opened for the meeting.
                    self.contextPanelController.close()
                    self.liveTranscriptController.close()

                    let minutesEnabled = self.minutesService.integrationEnabled
                    let obsidianEnabled = self.obsidianService.integrationEnabled

                    // Stop Minutes recording only if it was actually running.
                    if minutesEnabled {
                        self.monitor.externalRecordingActive = false
                        Task { await self.minutesService.stopRecording() }
                    }

                    // Post-meeting nudge is a Minutes-specific feature (it shows
                    // parsed action items + decisions from the transcript). When
                    // Minutes is off, Notion's own AI Meeting Notes handles capture
                    // so we skip the nudge entirely.
                    guard minutesEnabled else { return }

                    let title = ended.title
                    let slug = self.minutesService.slug(for: ended)
                    Task { @MainActor in
                        let meeting = await self.minutesService.fetchMeeting(slug: slug)
                        self.postMeetingController.show(
                            meetingTitle: title,
                            minutesMeeting: meeting,
                            onDismiss: { [weak self] in
                                self?.postMeetingController.close()
                            },
                            onOpenInObsidian: (obsidianEnabled && self.obsidianService.isInstalled)
                                ? { [weak self] parsed in
                                    self?.obsidianService.openMeetingNote(at: parsed.transcriptPath)
                                }
                                : nil
                        )

                        // Auto-open the meeting note in Obsidian.
                        if let meeting,
                           obsidianEnabled,
                           self.obsidianService.autoOpenEnabled,
                           self.obsidianService.isInstalled {
                            self.obsidianService.openMeetingNote(at: meeting.transcriptPath)
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - App Delegate

/// Minimal AppDelegate for menu bar app best practices:
/// - Installs global keyboard shortcuts (⌘Q, ⌘,) that work even though
///   LSUIElement apps have no main menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install global key-equivalent monitors so ⌘Q and ⌘, work from
        // any window (overlays, settings, popovers). LSUIElement apps don't
        // get the standard Edit/App menus, so we create invisible menu items.
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "About Meeting Reminder",
            action: #selector(showAboutPanel),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        prefsItem.target = self
        appMenu.addItem(prefsItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Meeting Reminder",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Meeting Reminder",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        ])
    }

    @objc private func openSettings() {
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
