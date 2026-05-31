import AppKit
import Foundation
import SwiftUI

/// Drives a "busy / free" status indicator by running user-authored macOS
/// Shortcuts. The user creates the Shortcuts (typically containing a
/// "Control [Home accessory]" action) and picks which one runs for each
/// state. We just shell out to `/usr/bin/shortcuts run <name>`.
///
/// Why Shortcuts and not HomeKit directly? HomeKit on macOS is gated behind
/// the `com.apple.developer.homekit` restricted entitlement which requires
/// a paid Apple Developer account + registered App ID. Shortcuts inherits
/// HomeKit access from the user's session, so there's no entitlement burden,
/// it works with any HomeKit accessory, and the user can extend the Shortcut
/// to do more than just change a bulb (mute Slack, etc.) without code changes.
@MainActor
final class BusyLightService: ObservableObject {
    @Published private(set) var availableShortcuts: [String] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastAppliedState: AppliedState?
    @Published private(set) var isRefreshing = false

    @AppStorage("busyLightBusyEnabled") var busyEnabled: Bool = true
    @AppStorage("busyLightFreeEnabled") var freeEnabled: Bool = true
    @AppStorage("busyLightBusyShortcut") var busyShortcut: String = ""
    @AppStorage("busyLightFreeShortcut") var freeShortcut: String = ""

    enum AppliedState: String { case busy, free }

    enum ListResult {
        case success([String])
        case failure(String)
    }

    /// `/usr/bin/shortcuts` is the system CLI installed by default on macOS 12+.
    private let cliPath = "/usr/bin/shortcuts"

    func refresh() {
        isRefreshing = true
        Task.detached { [weak self] in
            let result = await Self.runList()
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let names):
                    self.availableShortcuts = names
                    self.lastError = nil
                case .failure(let err):
                    self.lastError = err
                }
                self.isRefreshing = false
            }
        }
    }

    /// Apply the configured Shortcut for `state`. No-op when the state is
    /// disabled, when no shortcut is selected, or when the same state was
    /// already applied (avoids re-running the same shortcut every poll).
    func apply(_ state: AppliedState) {
        guard lastAppliedState != state else { return }

        let enabled = (state == .busy) ? busyEnabled : freeEnabled
        let name = (state == .busy) ? busyShortcut : freeShortcut

        guard enabled, !name.isEmpty else {
            // Even when skipping, record the state so we don't re-evaluate
            // every tick if the user has one side disabled.
            lastAppliedState = state
            return
        }

        Task.detached { [weak self] in
            let err = await Self.runShortcut(name: name, at: self?.cliPath ?? "/usr/bin/shortcuts")
            await MainActor.run {
                self?.lastAppliedState = state
                if let err {
                    self?.lastError = "Running '\(name)': \(err)"
                }
            }
        }
    }

    /// Open the Shortcuts.app, optionally focused on a named shortcut.
    /// The `shortcuts://open-shortcut?name=<name>` URL scheme opens the
    /// editor for an existing shortcut. With no name, just launches the app.
    func openShortcutsApp(name: String? = nil) {
        if let name, !name.isEmpty,
           let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "shortcuts://open-shortcut?name=\(encoded)") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "shortcuts://") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open a fresh shortcut creation pane in Shortcuts.app.
    func createNewShortcut() {
        if let url = URL(string: "shortcuts://create-shortcut") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - CLI helpers

    nonisolated private static func runList() async -> ListResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failure(error.localizedDescription))
                return
            }
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                let names = raw.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .sorted { $0.lowercased() < $1.lowercased() }
                continuation.resume(returning: .success(names))
            } else {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let err = String(data: data, encoding: .utf8) ?? "shortcuts list failed (\(process.terminationStatus))"
                continuation.resume(returning: .failure(err.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    nonisolated private static func runShortcut(name: String, at cliPath: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["run", name]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe()  // discard stdout

            do {
                try process.run()
            } catch {
                continuation.resume(returning: error.localizedDescription)
                return
            }
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                continuation.resume(returning: nil)
            } else {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let err = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                continuation.resume(returning: err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
