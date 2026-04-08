import AppKit
import SwiftUI

/// A small, screen-share-safe notification used when the user is in a call (mic active).
/// Avoids the full-screen overlay so the user doesn't broadcast a giant "MEETING IN 2 MIN"
/// banner to other participants.
struct MinimalAlertView: View {
    let event: MeetingEvent
    let onDismiss: () -> Void
    let onSnooze: (Int) -> Void
    let onJoin: () -> Void

    @State private var appeared = false
    @State private var countdown: String = ""
    @State private var timer: Timer?

    private var videoServiceName: String {
        guard let url = event.videoLink else { return "Meeting" }
        return VideoLinkDetector.serviceName(for: url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 15))
                    .foregroundColor(.orange)
                Text("UPCOMING MEETING")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .tracking(0.5)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Title
            Text(event.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Countdown
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                Text(countdown)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }

            // Action buttons
            HStack(spacing: 6) {
                if event.videoLink != nil {
                    Button(action: onJoin) {
                        HStack(spacing: 5) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 11))
                            Text("Join \(videoServiceName)")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }

                Button { onSnooze(60) } label: {
                    Text("1 min")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.18))
                        .foregroundColor(.white)
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)

                Button { onSnooze(30) } label: {
                    Text("30s")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.18))
                        .foregroundColor(.white)
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.16),
                    Color(red: 0.06, green: 0.07, blue: 0.10),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        .opacity(appeared ? 1.0 : 0.0)
        .offset(y: appeared ? 0 : -10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                appeared = true
            }
            updateCountdown()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in
                    updateCountdown()
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func updateCountdown() {
        let seconds = Int(event.startDate.timeIntervalSinceNow)
        if seconds <= 0 {
            countdown = "Starting now"
        } else if seconds < 60 {
            countdown = "in \(seconds)s"
        } else {
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            if remainingSeconds == 0 {
                countdown = "in \(minutes) min"
            } else {
                countdown = "in \(minutes)m \(remainingSeconds)s"
            }
        }
    }
}

// MARK: - Minimal Alert Window Controller

final class MinimalAlertWindowController {
    private var panel: NSPanel?

    func show(
        event: MeetingEvent,
        onDismiss: @escaping () -> Void,
        onSnooze: @escaping (Int) -> Void,
        onJoin: @escaping () -> Void
    ) {
        close()

        // Use the user's chosen target screen (or primary as fallback)
        guard let screen = DisplayPreferences.targetScreens().first else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 170),
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

        let view = MinimalAlertView(
            event: event,
            onDismiss: { [weak self] in
                self?.close()
                onDismiss()
            },
            onSnooze: { [weak self] seconds in
                self?.close()
                onSnooze(seconds)
            },
            onJoin: { [weak self] in
                self?.close()
                onJoin()
            }
        )

        panel.contentView = NSHostingView(rootView: view)

        // Position top-right of the chosen screen
        let x = screen.visibleFrame.maxX - 360
        let y = screen.visibleFrame.maxY - 190
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
