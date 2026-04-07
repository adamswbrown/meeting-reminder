import Combine
import SwiftUI

@main
struct MeetingReminderApp: App {
    @StateObject private var calendarService = CalendarService()
    @StateObject private var meetingMonitor: MeetingMonitor
    @StateObject private var overlayCoordinator: OverlayCoordinator
    @StateObject private var notionService = NotionService()

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("colorBlindMode") private var colorBlindMode = false

    private let onboardingController = OnboardingWindowController()

    init() {
        let calendar = CalendarService()
        let monitor = MeetingMonitor(calendarService: calendar)
        let coordinator = OverlayCoordinator(monitor: monitor)
        _calendarService = StateObject(wrappedValue: calendar)
        _meetingMonitor = StateObject(wrappedValue: monitor)
        _overlayCoordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                calendarService: calendarService,
                meetingMonitor: meetingMonitor,
                overlayCoordinator: overlayCoordinator
            )
            .onAppear {
                Task {
                    await calendarService.requestAccess()
                    calendarService.startMonitoring()
                    meetingMonitor.start()
                    overlayCoordinator.startObserving()

                    if !hasCompletedOnboarding {
                        onboardingController.show(calendarService: calendarService)
                    }
                }
            }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                calendarService: calendarService,
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
    private let windowController = OverlayWindowController()
    private let breakWindowController = BreakOverlayWindowController()
    private let checklistController = ChecklistWindowController()
    private let contextPanelController = ContextPanelWindowController()
    private let postMeetingController = PostMeetingNudgeWindowController()
    private var cancellables = Set<AnyCancellable>()

    init(monitor: MeetingMonitor) {
        self.monitor = monitor
    }

    // MARK: - Preview Methods

    /// Show the pre-meeting checklist as a standalone preview (no overlay)
    func previewChecklist() {
        checklistController.show { [weak self] in
            self?.checklistController.close()
        }
    }

    /// Show the meeting context panel with a sample meeting for preview
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
                } else {
                    windowController.close()
                    checklistController.close()
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

        // Post-meeting nudge (when meeting ends)
        monitor.$currentMeetingInProgress
            .receive(on: RunLoop.main)
            .removeDuplicates(by: { $0?.id == $1?.id })
            .scan((nil, nil) as (MeetingEvent?, MeetingEvent?)) { prev, current in
                (prev.1, current)
            }
            .sink { [weak self] (previous, current) in
                guard let self else { return }
                // If we had a meeting and now we don't, show post-meeting nudge
                if let ended = previous, current == nil {
                    let notionURL = self.monitor.notionPageURL(for: ended.id)
                    postMeetingController.show(
                        meetingTitle: ended.title,
                        notionPageURL: notionURL,
                        actionItems: [],
                        onDismiss: { [weak self] in
                            self?.postMeetingController.close()
                        }
                    )
                }
            }
            .store(in: &cancellables)
    }
}
