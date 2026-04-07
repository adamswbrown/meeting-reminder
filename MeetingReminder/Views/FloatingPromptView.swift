import AppKit
import SwiftUI

/// A non-blocking floating prompt that nudges the user to save their work before a meeting.
/// Stays on screen but doesn't block interaction with other apps.
struct FloatingPromptView: View {
    let meetingTitle: String
    let minutesUntil: Int
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 22))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Save your work")
                    .font(.system(size: 13, weight: .semibold))
                Text("You need to switch in \(minutesUntil) min — \(meetingTitle)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 380)
        .background(.ultraThickMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .opacity(appeared ? 1.0 : 0.0)
        .offset(y: appeared ? 0 : -10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                appeared = true
            }
        }
    }
}

// MARK: - Floating Prompt Window Controller

final class FloatingPromptWindowController {
    private var panel: NSPanel?

    func show(meetingTitle: String, minutesUntil: Int, onDismiss: @escaping () -> Void) {
        close()

        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 56),
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

        let view = FloatingPromptView(
            meetingTitle: meetingTitle,
            minutesUntil: minutesUntil,
            onDismiss: { [weak self] in
                self?.close()
                onDismiss()
            }
        )

        panel.contentView = NSHostingView(rootView: view)

        // Position top-center of screen
        let x = screen.visibleFrame.midX - 190
        let y = screen.visibleFrame.maxY - 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
