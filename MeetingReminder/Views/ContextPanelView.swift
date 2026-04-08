import SwiftUI

/// A floating, semi-transparent panel showing meeting context (title, attendees, agenda, links).
/// Optionally streams in an AI prep brief from `minutes` (past meetings, person profiles).
/// Stays on screen during the meeting; user can dismiss with the close button.
struct ContextPanelView: View {
    let event: MeetingEvent
    let minutesService: MinutesService?
    let onClose: () -> Void

    @State private var prepBrief: String?
    @State private var isLoadingPrep = false

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

            // AI Prep Brief (from `minutes person` + `minutes research`)
            if isLoadingPrep || prepBrief != nil {
                Divider()
                prepBriefSection
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
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(.white)
                    .background(Color.accentColor)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .onAppear {
            loadPrepBriefIfEnabled()
        }
    }

    @ViewBuilder
    private var prepBriefSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .foregroundColor(.purple)
                Text("Prep brief")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                if isLoadingPrep {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let brief = prepBrief {
                ScrollView {
                    Text(brief)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(6)
            } else if isLoadingPrep {
                Text("Reading past meetings…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }

    private func loadPrepBriefIfEnabled() {
        guard let service = minutesService, service.prepEnabled, service.isInstalled else { return }
        guard prepBrief == nil, !isLoadingPrep else { return }
        isLoadingPrep = true
        Task {
            let brief = await service.generatePrepBrief(for: event)
            await MainActor.run {
                self.prepBrief = brief
                self.isLoadingPrep = false
            }
        }
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

    func show(event: MeetingEvent, minutesService: MinutesService?, onClose: @escaping () -> Void) {
        close()

        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
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
            minutesService: minutesService,
            onClose: { [weak self] in
                self?.close()
                onClose()
            }
        )

        panel.contentView = NSHostingView(rootView: view)

        // Position in top-right corner
        let x = screen.visibleFrame.maxX - 340
        let y = screen.visibleFrame.maxY - 480
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
