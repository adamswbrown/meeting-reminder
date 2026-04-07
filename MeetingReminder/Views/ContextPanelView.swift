import SwiftUI

/// A floating, semi-transparent panel showing meeting context (title, attendees, agenda, links).
/// Can be repositioned by the user and stays on screen during meetings.
struct ContextPanelView: View {
    let event: MeetingEvent
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.accentColor)
                Text("Meeting Context")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Title
            Text(event.title)
                .font(.title3.bold())

            // Time
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text(event.formattedStartTime)
                Text("–")
                Text(formattedEndTime)
            }
            .font(.callout)
            .foregroundColor(.secondary)

            // Calendar
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundColor(.secondary)
                Text(event.calendar)
            }
            .font(.callout)
            .foregroundColor(.secondary)

            // Attendees
            if let attendees = event.attendees, !attendees.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "person.2")
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(attendees, id: \.self) { attendee in
                            Text(attendee)
                                .font(.callout)
                        }
                    }
                }
            }

            // Notes / Description
            if let notes = event.notes, !notes.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                    Text(notes)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(8)
                }
            }

            // Video link
            if let url = event.videoLink {
                Divider()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "video.fill")
                        Text("Join \(VideoLinkDetector.serviceName(for: url))")
                    }
                    .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private var formattedEndTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: event.endDate)
    }
}

// MARK: - Context Panel Window Controller

final class ContextPanelWindowController {
    private var panel: NSPanel?

    func show(event: MeetingEvent, onClose: @escaping () -> Void) {
        close()

        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.title = "Meeting Context"

        let view = ContextPanelView(
            event: event,
            onClose: { [weak self] in
                self?.close()
                onClose()
            }
        )

        panel.contentView = NSHostingView(rootView: view)

        // Position in top-right corner
        let x = screen.visibleFrame.maxX - 320
        let y = screen.visibleFrame.maxY - 420
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
