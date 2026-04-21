import SwiftUI

struct MenuBarView: View {
    @ObservedObject var calendarService: CalendarService
    @ObservedObject var meetingMonitor: MeetingMonitor
    @ObservedObject var minutesService: MinutesService
    var overlayCoordinator: OverlayCoordinator
    @Environment(\.dismiss) private var dismiss

    private var upcomingEvents: [MeetingEvent] {
        // Include: events that haven't started yet (any future time) OR events
        // that are currently in progress (started but not yet ended). This lets
        // the user see and join meetings they're running late to.
        calendarService.events.filter { event in
            event.timeUntilStart > 0 || event.isInProgress
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if calendarService.authorizationStatus != .authorized {
                calendarAccessSection
            } else if upcomingEvents.isEmpty {
                noEventsSection
            } else {
                meetingLoadSection
                Divider().padding(.vertical, 4)
                eventListSection
            }

            // Recording / reconnect / ad-hoc section
            recordingSection

            Divider()
                .padding(.vertical, 6)

            PreferencesButton {
                dismiss()
            }

            Divider()
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    meetingMonitor.testOverlay()
                } label: {
                    Label("Meeting Overlay", systemImage: "rectangle.inset.filled")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    overlayCoordinator.previewChecklist()
                } label: {
                    Label("Pre-Meeting Checklist", systemImage: "checklist")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    overlayCoordinator.previewContextPanel()
                } label: {
                    Label("Context Panel", systemImage: "info.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    meetingMonitor.testMinimalAlert()
                } label: {
                    Label("In-Call Minimal Alert", systemImage: "bell.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    overlayCoordinator.previewLiveTranscript()
                } label: {
                    Label("Live Transcript", systemImage: "waveform")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            Divider()
                .padding(.vertical, 6)

            Button {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "Meeting Reminder",
                    .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                ])
            } label: {
                Text("About Meeting Reminder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit Meeting Reminder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            // User opening the popover is a strong "I want the latest" signal.
            // Triggers `refreshSourcesIfNecessary` so remote calendars
            // (Google / Exchange / iCloud) get nudged to sync any meetings
            // added since the last poll.
            if calendarService.authorizationStatus == .authorized {
                calendarService.fetchEvents()
            }
        }
    }

    // MARK: - Recording section

    /// Shows one of three states:
    ///   1. App has `currentMeetingInProgress` set → "Recording / End meeting"
    ///   2. CLI is recording but app isn't tracking it → "Reconnect to active recording"
    ///   3. Nothing going on → "Start ad-hoc meeting"
    @ViewBuilder
    private var recordingSection: some View {
        Divider().padding(.vertical, 6)

        if let current = meetingMonitor.currentMeetingInProgress {
            inProgressView(current: current)
        } else if case let .recording(title) = minutesService.status {
            reconnectView(externalTitle: title)
        } else if case let .processing(title, stage) = minutesService.status {
            processingView(title: title, stage: stage)
        } else {
            idleView
        }
    }

    @ViewBuilder
    private func inProgressView(current: MeetingEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 11))
                Text("Recording")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            Text(current.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.bottom, 4)

            Button {
                meetingMonitor.markMeetingDone()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("End meeting")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func reconnectView(externalTitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 11))
                Text("External recording detected")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            if let t = externalTitle {
                Text(t)
                    .font(.system(size: 12))
                    .lineLimit(1)
            } else {
                Text("Untitled")
                    .font(.system(size: 12))
                    .italic()
                    .foregroundColor(.secondary)
            }
            Text("Minutes is recording but this app didn't start it.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 4)

            Button {
                dismiss()
                let title = externalTitle ?? "Reconnected recording"
                meetingMonitor.reconnectToActiveRecording(title: title)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("Reconnect to recording")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                Task { await minutesService.stopRecording() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.circle.fill")
                        .foregroundColor(.red)
                    Text("Stop external recording")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func processingView(title: String?, stage: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("Processing")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            if let t = title {
                Text(t)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            if let s = stage {
                Text(s)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var idleView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                dismiss()
                meetingMonitor.startAdHocMeeting()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .foregroundColor(.red)
                    Text("Start ad-hoc meeting")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                dismiss()
                promptForAdHocTitle()
            } label: {
                Text("Start with title…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Ad-hoc title prompt

    private func promptForAdHocTitle() {
        let alert = NSAlert()
        alert.messageText = "Start ad-hoc meeting"
        alert.informativeText = "Give this meeting a title. Recording will start immediately."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        textField.placeholderString = "e.g. Quick sync with Tim · \(formatter.string(from: Date()))"
        alert.accessoryView = textField

        // Make sure the alert is on top and active
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let title = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            meetingMonitor.startAdHocMeeting(title: title.isEmpty ? nil : title)
        }
    }

    // MARK: - Meeting Load Section (5.1)

    private var meetingLoadSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(calendarService.totalMeetingCount) meetings today")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("(\(String(format: "%.1f", calendarService.totalMeetingHours))h)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 4) {
                if calendarService.backToBackCount > 0 {
                    Text("\(calendarService.backToBackCount) back-to-back")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                if let breakTime = calendarService.formattedNextBreak {
                    if calendarService.backToBackCount > 0 {
                        Text("·")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("Next break: \(breakTime)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Sections

    private var calendarAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Calendar Access Required", systemImage: "calendar.badge.exclamationmark")
                .font(.headline)
            Text("Grant access in System Settings → Privacy & Security → Calendars")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Request Access") {
                Task { await calendarService.requestAccess() }
            }
            .controlSize(.small)
        }
    }

    private var noEventsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("No upcoming meetings", systemImage: "checkmark.circle")
                .font(.headline)
            Text("You're free for the rest of the day")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var eventListSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Upcoming Meetings")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 4)

            ForEach(upcomingEvents.prefix(5)) { event in
                eventRow(event)
                if event.id != upcomingEvents.prefix(5).last?.id {
                    Divider().padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Event Row

    private func eventRow(_ event: MeetingEvent) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(event.formattedStartTime)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if event.isInProgress {
                        Text("· In progress")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .fontWeight(.medium)
                    } else {
                        Text("· in \(event.formattedTimeUntil)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if event.videoLink != nil {
                Button {
                    dismiss()
                    meetingMonitor.joinMeetingFromCalendar(event)
                } label: {
                    if event.isInProgress {
                        // Prominent styling for the "I'm late" case — the user
                        // needs to clearly see they can join a live meeting
                        HStack(spacing: 3) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 10))
                            Text("Join")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(5)
                    } else {
                        Image(systemName: "video.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.borderless)
                .help(event.isInProgress
                      ? "Join \(VideoLinkDetector.serviceName(for: event.videoLink!)) (in progress) and start recording"
                      : "Join \(VideoLinkDetector.serviceName(for: event.videoLink!))")
            }
        }
        .padding(.vertical, 2)
    }

}

private struct PreferencesButton: View {
    var onDismiss: () -> Void

    var body: some View {
        if #available(macOS 14.0, *) {
            PreferencesButton14(onDismiss: onDismiss)
        } else {
            Button {
                onDismiss()
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.title.contains("Settings") || window.title.contains("Preferences") {
                        window.orderFrontRegardless()
                    }
                }
            } label: {
                Text("Preferences…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }
}

@available(macOS 14.0, *)
private struct PreferencesButton14: View {
    @Environment(\.openSettings) private var openSettings
    var onDismiss: () -> Void

    var body: some View {
        Button {
            onDismiss()
            openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.title.contains("Settings") || window.title.contains("Preferences") {
                    window.orderFrontRegardless()
                }
            }
        } label: {
            Text("Preferences…")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
