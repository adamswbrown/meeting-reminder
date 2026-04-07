import SwiftUI

struct MenuBarView: View {
    @ObservedObject var calendarService: CalendarService
    @ObservedObject var meetingMonitor: MeetingMonitor
    var overlayCoordinator: OverlayCoordinator
    @Environment(\.dismiss) private var dismiss

    private var upcomingEvents: [MeetingEvent] {
        calendarService.events.filter { $0.timeUntilStart > -300 }
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

            // "Done with meeting" button when a meeting is in progress
            if meetingMonitor.currentMeetingInProgress != nil {
                Divider().padding(.vertical, 6)
                Button {
                    meetingMonitor.markMeetingDone()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Done with meeting")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

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
            }

            Divider()
                .padding(.vertical, 6)

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

            if let url = event.videoLink {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Join \(VideoLinkDetector.serviceName(for: url))")
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
