import SwiftUI

/// A softer overlay that appears between back-to-back meetings,
/// encouraging the user to take a brief break before the next meeting.
struct BreakOverlayView: View {
    let nextMeetingTitle: String
    let nextMeetingStart: Date
    let onOK: () -> Void
    let onSkip: () -> Void

    @State private var countdown: String = ""
    @State private var timer: Timer?
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Soft background
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.05, green: 0.1, blue: 0.15).opacity(0.85),
                            Color(red: 0.08, green: 0.15, blue: 0.22).opacity(0.85),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "leaf.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.green.opacity(0.8))

                Text("Take a Breather")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)

                Text("You have a short break before your next meeting")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.7))

                // Countdown to next meeting
                Text(countdown)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.top, 8)

                Text("Next: \(nextMeetingTitle)")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.6))

                Spacer()

                // Suggestions
                VStack(spacing: 12) {
                    suggestionRow(icon: "figure.walk", text: "Stretch or stand up")
                    suggestionRow(icon: "drop.fill", text: "Get water")
                    suggestionRow(icon: "wind", text: "Take three deep breaths")
                }
                .padding(24)
                .background(Color.white.opacity(0.08))
                .cornerRadius(16)

                Spacer()

                HStack(spacing: 16) {
                    Button(action: onOK) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                            Text("OK")
                        }
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(Color.green.opacity(0.5))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    // Explicit shortcut needed: this view runs inside an NSPanel where
                    // SwiftUI's implicit default-button behaviour is not active.
                    .keyboardShortcut(.return, modifiers: [])

                    Button(action: onSkip) {
                        HStack(spacing: 8) {
                            Image(systemName: "forward.fill")
                            Text("Skip Break")
                        }
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }

                Spacer()
                    .frame(height: 60)
            }
            .scaleEffect(appeared ? 1.0 : 0.9)
            .opacity(appeared ? 1.0 : 0.0)
        }
        .ignoresSafeArea()
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

    private func suggestionRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.green.opacity(0.8))
                .frame(width: 24)
            Text(text)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
        }
    }

    private func updateCountdown() {
        let seconds = Int(nextMeetingStart.timeIntervalSinceNow)
        if seconds <= 0 {
            countdown = "Starting now"
        } else {
            let min = seconds / 60
            let sec = seconds % 60
            countdown = String(format: "%d:%02d", min, sec)
        }
    }
}
