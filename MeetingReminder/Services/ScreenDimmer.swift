import AppKit
import Foundation
import IOKit.graphics

/// Gradually dims the screen before meetings.
/// Safety: linear dimming only, never below 70%, respects Reduce Motion, off by default.
@MainActor
final class ScreenDimmer {
    private var dimTimer: Timer?
    private var originalBrightness: Float?
    private var targetBrightness: Float = 0.7
    private var dimStartTime: Date?
    private var dimDuration: TimeInterval = 300 // 5 minutes

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "screenDimmingEnabled")
    }

    /// Begin gradual dimming over the specified duration
    func startDimming(durationSeconds: TimeInterval = 300) {
        guard isEnabled else { return }

        // Respect Reduce Motion accessibility setting
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return
        }

        guard let current = getCurrentBrightness() else { return }
        originalBrightness = current
        dimDuration = durationSeconds
        dimStartTime = Date()

        // Target is 70% of current brightness, never below 0.7 absolute
        targetBrightness = max(current * 0.7, 0.3)

        // Update every 5 seconds for smooth linear transition
        dimTimer?.invalidate()
        dimTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateDimming()
            }
        }
    }

    /// Restore original brightness
    func restore() {
        dimTimer?.invalidate()
        dimTimer = nil

        if let original = originalBrightness {
            setBrightness(original)
            originalBrightness = nil
        }
        dimStartTime = nil
    }

    private func updateDimming() {
        guard let start = dimStartTime, let original = originalBrightness else {
            restore()
            return
        }

        let elapsed = Date().timeIntervalSince(start)
        let progress = min(elapsed / dimDuration, 1.0)

        // Linear interpolation
        let currentTarget = original - (Float(progress) * (original - targetBrightness))
        setBrightness(currentTarget)

        if progress >= 1.0 {
            dimTimer?.invalidate()
            dimTimer = nil
        }
    }

    // MARK: - IOKit Brightness Control

    private func getCurrentBrightness() -> Float? {
        var brightness: Float = 0
        var iterator: io_iterator_t = 0

        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        )

        guard result == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
        return brightness
    }

    private func setBrightness(_ brightness: Float) {
        var iterator: io_iterator_t = 0

        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        )

        guard result == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, brightness)
    }
}
