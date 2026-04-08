import AppKit
import SwiftUI

/// A non-blocking nudge that appears after a meeting ends,
/// prompting the user to capture action items. Backed by a parsed
/// `MinutesMeeting` from the local `minutes` CLI.
struct PostMeetingNudgeView: View {
    let meetingTitle: String
    let minutesMeeting: MinutesMeeting?
    let onDismiss: () -> Void
    let onOpenInObsidian: ((MinutesMeeting) -> Void)?

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
                Text("Meeting ended")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(meetingTitle)
                .font(.subheadline.weight(.medium))

            Divider()

            if let meeting = minutesMeeting {
                if meeting.actionItems.isEmpty {
                    Text("No action items extracted yet.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    actionItemsSection(meeting.actionItems)
                }

                if !meeting.decisions.isEmpty {
                    decisionsSection(meeting.decisions)
                }

                buttonRow(for: meeting)
            } else {
                Text("Transcribing… check Minutes in a moment.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("meetings")
                    ])
                    onDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("Open meetings folder")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .opacity(appeared ? 1.0 : 0.0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private func actionItemsSection(_ items: [MinutesMeeting.ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Action items")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: item.status == "done"
                          ? "checkmark.circle.fill"
                          : "arrow.right.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(item.status == "done" ? .green : .accentColor)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.task)
                            .font(.callout)
                            .lineLimit(2)
                        if let assignee = item.assignee, assignee.lowercased() != "unassigned" {
                            Text("→ \(assignee)\(item.due.map { " · \($0)" } ?? "")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if let due = item.due {
                            Text(due)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func decisionsSection(_ decisions: [MinutesMeeting.Decision]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Decisions")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
            ForEach(decisions) { decision in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.purple)
                        .padding(.top, 2)
                    Text(decision.text)
                        .font(.callout)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func buttonRow(for meeting: MinutesMeeting) -> some View {
        VStack(spacing: 6) {
            // Primary action — Obsidian if available, otherwise "reveal in Finder"
            if let onOpenInObsidian {
                Button {
                    onOpenInObsidian(meeting)
                    onDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("Open in Obsidian")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(.white)
                    .background(Color.purple)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([meeting.transcriptPath])
                    onDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(onOpenInObsidian == nil ? "Open transcript" : "Reveal in Finder")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(.white)
                    .background(Color.accentColor)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                if !meeting.actionItems.isEmpty {
                    Button {
                        copyActionItems(meeting.actionItems)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .foregroundColor(.primary)
                            .background(Color.primary.opacity(0.08))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .help("Copy action items")
                }
            }
        }
    }

    private func copyActionItems(_ items: [MinutesMeeting.ActionItem]) {
        let text = items.map { item -> String in
            var line = "- \(item.task)"
            if let a = item.assignee, a.lowercased() != "unassigned" { line += " (\(a))" }
            if let d = item.due { line += " due \(d)" }
            return line
        }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Post-Meeting Nudge Window Controller

final class PostMeetingNudgeWindowController {
    private var panel: NSPanel?
    private var autoDismissTimer: Timer?

    func show(
        meetingTitle: String,
        minutesMeeting: MinutesMeeting?,
        onDismiss: @escaping () -> Void,
        onOpenInObsidian: ((MinutesMeeting) -> Void)? = nil
    ) {
        close()

        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let view = PostMeetingNudgeView(
            meetingTitle: meetingTitle,
            minutesMeeting: minutesMeeting,
            onDismiss: { [weak self] in
                self?.close()
                onDismiss()
            },
            onOpenInObsidian: onOpenInObsidian
        )

        panel.contentView = NSHostingView(rootView: view)

        // Position bottom-right
        let x = screen.visibleFrame.maxX - 360
        let y = screen.visibleFrame.minY + 20
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        self.panel = panel

        // Auto-dismiss after 2 minutes
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.close()
                onDismiss()
            }
        }
    }

    func close() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
