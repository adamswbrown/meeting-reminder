import AppKit
import SwiftUI

final class OverlayWindowController {
    private var panels: [NSPanel] = []

    func show(event: MeetingEvent, onDismiss: @escaping () -> Void,
              onSnooze: @escaping (Int) -> Void, onJoin: @escaping () -> Void) {
        close()

        for screen in DisplayPreferences.targetScreens() {
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false

            let overlayView = OverlayView(
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

            let hosting = NSHostingView(rootView: overlayView)
            // Don't let the hosting view drive the panel's content-size extrema.
            // Content-driven window sizing re-invalidates constraints mid-display-cycle
            // when the SwiftUI content resizes, which crashes AppKit via
            // -[NSWindow _postWindowNeedsUpdateConstraints]. The panel is explicitly framed.
            hosting.sizingOptions = []
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panel.makeKey()

            panels.append(panel)
        }

        // Activate the app to receive keyboard events
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
}

// MARK: - Break Overlay Window Controller

final class BreakOverlayWindowController {
    private var panels: [NSPanel] = []

    func show(nextEvent: MeetingEvent, onSkip: @escaping () -> Void) {
        close()

        for screen in DisplayPreferences.targetScreens() {
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false

            // Both OK and Skip dismiss the overlay; the distinction is semantic/UX only.
            let dismissOverlay = { [weak self] in
                self?.close()
                onSkip()
            }
            let view = BreakOverlayView(
                nextMeetingTitle: nextEvent.title,
                nextMeetingStart: nextEvent.startDate,
                onOK: dismissOverlay,
                onSkip: dismissOverlay
            )

            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []  // see OverlayWindowController: avoid content-driven window resize crash
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panel.makeKey()

            panels.append(panel)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
}
