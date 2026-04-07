import AppKit
import SwiftUI

/// A non-blocking nudge that appears after a meeting ends,
/// prompting the user to capture action items.
struct PostMeetingNudgeView: View {
    let meetingTitle: String
    let notionPageURL: URL?
    let actionItems: [String]
    let onDismiss: () -> Void

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

            Text("Capture your action items before you forget!")
                .font(.callout)
                .foregroundColor(.secondary)

            // Action items from Notion (if available)
            if !actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action items found:")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    ForEach(actionItems, id: \.self) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.accentColor)
                            Text(item)
                                .font(.callout)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(8)
            }

            // Notion button
            if let url = notionPageURL {
                Button {
                    NotionService.openInNotionApp(url)
                    onDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text("Open Meeting Notes")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .opacity(appeared ? 1.0 : 0.0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                appeared = true
            }
        }
    }
}

// MARK: - Post-Meeting Nudge Window Controller

final class PostMeetingNudgeWindowController {
    private var panel: NSPanel?
    private var autoDismissTimer: Timer?

    func show(
        meetingTitle: String,
        notionPageURL: URL?,
        actionItems: [String],
        onDismiss: @escaping () -> Void
    ) {
        close()

        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
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
            notionPageURL: notionPageURL,
            actionItems: actionItems,
            onDismiss: { [weak self] in
                self?.close()
                onDismiss()
            }
        )

        panel.contentView = NSHostingView(rootView: view)

        // Position bottom-right
        let x = screen.visibleFrame.maxX - 340
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
