import AppKit
import SwiftUI

/// Floating in-meeting transcript pane. Shows rolling whisper transcription
/// from `~/.minutes/live-transcript.jsonl` plus heuristic coach hints.
struct LiveTranscriptView: View {
    @ObservedObject var service: LiveTranscriptService
    let onClose: () -> Void
    let onEndMeeting: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.purple)
                Text("Live Transcript")
                    .font(.headline)
                    .foregroundColor(.primary)
                if service.isRunning {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(0.85)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Coach hints
            if !service.hints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(service.hints.suffix(3)) { hint in
                        coachHintRow(hint)
                    }
                }
            }

            Divider()

            // Transcript scroll view
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if service.lines.isEmpty {
                            Text("Listening… transcript appears here every few seconds.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .italic()
                                .padding(.vertical, 8)
                        } else {
                            ForEach(service.lines) { line in
                                transcriptRow(line)
                                    .id(line.id)
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 260)
                .onChange(of: service.lines.count) { _ in
                    if let last = service.lines.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            // End Meeting button — required because `minutes record` holds the
            // mic, which defeats the Core Audio silence-based auto-end.
            if let onEnd = onEndMeeting {
                Button(action: onEnd) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle.fill")
                        Text("End Meeting")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(.white)
                    .background(Color.red)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    @ViewBuilder
    private func transcriptRow(_ line: LiveTranscriptLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(formatOffset(line.offsetMs))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(line.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func coachHintRow(_ hint: CoachHint) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hint.kind.icon)
                .foregroundColor(hint.kind.tint)
            Text(hint.text)
                .font(.callout.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hint.kind.tint.opacity(0.12))
        .cornerRadius(8)
    }

    private func formatOffset(_ ms: Int) -> String {
        let totalSecs = ms / 1000
        let m = totalSecs / 60
        let s = totalSecs % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Window controller

@MainActor
final class LiveTranscriptWindowController {
    private var panel: NSPanel?
    let service: LiveTranscriptService

    init(service: LiveTranscriptService) {
        self.service = service
    }

    func show(onClose: @escaping () -> Void, onEndMeeting: (() -> Void)? = nil, isPreview: Bool = false) {
        // The `liveTranscriptEnabled` setting gates real meetings; previews bypass it.
        guard isPreview || service.liveTranscriptEnabled else { return }
        close()

        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
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
        panel.title = "Live Transcript"

        let view = LiveTranscriptView(
            service: service,
            onClose: { [weak self] in
                self?.close()
                onClose()
            },
            onEndMeeting: onEndMeeting
        )

        panel.contentView = NSHostingView(rootView: view)

        // Position lower-left, doesn't collide with the top-right context panel.
        let x = screen.visibleFrame.minX + 20
        let y = screen.visibleFrame.minY + 20
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        self.panel = panel
        // Preview mode skips real polling — caller has already loaded sample data.
        if !isPreview {
            service.start()
        }
    }

    func close() {
        service.stop()
        panel?.orderOut(nil)
        panel = nil
    }
}
