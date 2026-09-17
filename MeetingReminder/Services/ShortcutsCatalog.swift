import Foundation

/// Lists the user's Shortcuts by name via `/usr/bin/shortcuts` (the system CLI,
/// present by default on macOS 12+).
///
/// Extracted from `BusyLightService` so the briefing settings can offer the same
/// pick-from-a-list experience instead of a free-text field, where a typo or a
/// blank value fails silently at the moment a briefing is needed.
enum ShortcutsCatalog {
    enum ListResult {
        case success([String])
        case failure(String)
    }

    nonisolated static func list() async -> ListResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let stdoutPipe = Pipe(), stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do { try process.run() } catch {
                continuation.resume(returning: .failure(error.localizedDescription)); return
            }
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: .failure(
                    message.isEmpty ? "shortcuts list failed (\(process.terminationStatus))" : message))
                return
            }
            let names = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            continuation.resume(returning: .success(names))
        }
    }
}
