import Combine
import SwiftUI

@main
struct MeetingReminderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var calendarService = CalendarService()
    @StateObject private var meetingMonitor: MeetingMonitor
    @StateObject private var overlayCoordinator: OverlayCoordinator
    @StateObject private var notionService = NotionService()
    @StateObject private var preCallBriefService: PreCallBriefService
    @StateObject private var calendarNotionSync = CalendarNotionSyncService()
    @StateObject private var availabilityPushService: AvailabilityPushService

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
        let notion = NotionService()
        let preCallBriefs = PreCallBriefService()
        let availability = AvailabilityPushService()
        let coordinator = OverlayCoordinator(
            monitor: monitor,
            notionService: notion,
            preCallBriefService: preCallBriefs
        )
        _calendarService = StateObject(wrappedValue: calendar)
        _meetingMonitor = StateObject(wrappedValue: monitor)
        _overlayCoordinator = StateObject(wrappedValue: coordinator)
        _notionService = StateObject(wrappedValue: notion)
        _preCallBriefService = StateObject(wrappedValue: preCallBriefs)
        _availabilityPushService = StateObject(wrappedValue: availability)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                calendarService: calendarService,
                meetingMonitor: meetingMonitor,
                overlayCoordinator: overlayCoordinator,
                calendarNotionSync: calendarNotionSync
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
                    calendarNotionSync.startScheduleIfEnabled()
                    availabilityPushService.start()

                    if !hasCompletedOnboarding {
                        onboardingController.show(calendarService: calendarService)
                    }
                }
                .onOpenURL { url in
                    // meetingreminder://calsync triggers an immediate Calendar→Notion
                    // sync. Wired up so an Apple Shortcut (Open URL action) can run
                    // the sync on demand from the menu bar / dock without needing a
                    // separate launchd job.
                    guard url.scheme == "meetingreminder" else { return }
                    if url.host == "calsync" {
                        Task { await calendarNotionSync.runNow() }
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                calendarService: calendarService,
                notionService: notionService,
                calendarNotionSync: calendarNotionSync,
                availabilityPushService: availabilityPushService
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
    private let notionService: NotionService
    private let preCallBriefService: PreCallBriefService
    private let windowController = OverlayWindowController()
    private let breakWindowController = BreakOverlayWindowController()
    private let checklistController = ChecklistWindowController()
    private let contextPanelController = ContextPanelWindowController()
    private let minimalAlertController = MinimalAlertWindowController()
    private let briefPanelController = BriefPanelWindowController()
    private var cancellables = Set<AnyCancellable>()

    init(
        monitor: MeetingMonitor,
        notionService: NotionService,
        preCallBriefService: PreCallBriefService
    ) {
        self.monitor = monitor
        self.notionService = notionService
        self.preCallBriefService = preCallBriefService

        // Ensure all panels are closed when the app terminates
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closeAllPanels()
            }
        }
    }

    private func closeAllPanels() {
        windowController.close()
        breakWindowController.close()
        checklistController.close()
        contextPanelController.close()
        minimalAlertController.close()
        briefPanelController.close()
    }

    // MARK: - Preview Methods

    /// Show the pre-meeting checklist as a standalone preview (no overlay)
    func previewChecklist() {
        checklistController.show { [weak self] in
            self?.checklistController.close()
        }
    }

    /// Show the meeting context panel with a sample meeting for preview.
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
        contextPanelController.show(event: sampleEvent) { [weak self] in
            self?.contextPanelController.close()
        }
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
                    // Kick off/show Notion pre-call brief when reminder appears.
                    showBriefPanelIfConfigured(for: event)
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

        // Meeting in-progress: fire the Notion page creation, show the context
        // panel and the pre-call brief.
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

                // Context panel: shown for every meeting — attendees + notes +
                // location are useful on their own.
                self.contextPanelController.show(event: event) { [weak self] in
                    self?.contextPanelController.close()
                }

                // Also show the brief when a meeting is started directly from
                // the menu bar (which bypasses the reminder overlay path).
                self.showBriefPanelIfConfigured(for: event)
            }
            .store(in: &cancellables)

        // Post-meeting: detect transition from in-progress to ended, close
        // the panels we opened for the meeting.
        monitor.$currentMeetingInProgress
            .receive(on: RunLoop.main)
            .removeDuplicates(by: { $0?.id == $1?.id })
            .scan((nil, nil) as (MeetingEvent?, MeetingEvent?)) { prev, current in
                (prev.1, current)
            }
            .sink { [weak self] (previous, current) in
                guard let self else { return }
                if previous != nil, current == nil {
                    self.contextPanelController.close()
                    self.briefPanelController.close()
                }
            }
            .store(in: &cancellables)
    }

    /// True when a pre-call brief can be shown — drives the menu bar
    /// "Show pre-call brief" button visibility so it never appears as a no-op.
    var canShowPreCallBrief: Bool { notionService.isConfigured }

    func showBriefPanelIfConfigured(for event: MeetingEvent) {
        guard notionService.isConfigured else { return }
        briefPanelController.show(
            event: event,
            service: preCallBriefService,
            onClose: { [weak self] in
                self?.briefPanelController.close()
            }
        )
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

        // Edit menu — without this, LSUIElement apps don't get Cmd+X/C/V/A in
        // text fields (Settings inputs, overlay text fields, etc.). Items have
        // nil targets so they hit the responder chain (NSText, NSResponder).
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo",
                                     action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo",
                                   action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",
                                     action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",
                                     action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",
                                     action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All",
                                     action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

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
