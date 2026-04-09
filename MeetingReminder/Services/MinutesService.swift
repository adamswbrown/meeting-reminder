import AppKit
import Foundation
import SwiftUI

/// Wraps the local `minutes` CLI (https://github.com/silverstein/minutes).
///
/// All CLI invocations spawn a `Process` on a background queue and surface
/// results back on the main actor. The CLI is invoked via `/bin/sh -lc`
/// so it inherits the user's PATH (Homebrew on Apple Silicon: /opt/homebrew/bin).
@MainActor
final class MinutesService: ObservableObject {
    // MARK: - Published State

    @Published var isInstalled: Bool = false
    @Published var version: String?
    @Published var binaryPath: URL?
    @Published var meetingsFolder: URL?
    @Published var lastError: String?
    @Published var currentRecordingTitle: String?
    @Published var lastHealthOutput: String?

    /// Live snapshot of `minutes status` — refreshed every few seconds so the
    /// UI can show whether the CLI is recording/processing even if the app
    /// didn't start the recording itself (e.g. the app was relaunched while
    /// `minutes record` was still running in the background).
    @Published var status: Status = .idle

    /// Asynchronously published when a `minutes record` spawn fails after the
    /// fact — e.g. stale device name in config, missing whisper model, etc.
    /// The `OverlayCoordinator` observes this and rolls back the
    /// `currentMeetingInProgress` state it optimistically set, then shows an
    /// NSAlert with the error details.
    @Published var recordingDidFail: RecordingFailure?

    /// Live transcript model name from `~/.config/minutes/config.toml`.
    /// Empty string means the recording sidecar will silently skip live transcription.
    @Published var liveTranscriptModel: String = ""
    @Published var liveTranscriptConfigured: Bool = false

    // MARK: - Types

    /// Details about a failed `minutes record` spawn. Surfaced to the user via
    /// `recordingDidFail`. Includes the captured stderr so the alert can show
    /// a real diagnostic instead of a vague "something went wrong".
    struct RecordingFailure: Equatable {
        /// Title the caller tried to record under.
        let attemptedTitle: String
        /// One-line human-readable summary for the alert header.
        let summary: String
        /// Full stderr text from the failed process (may be empty).
        let stderr: String
    }

    /// A parsed snapshot of `minutes status`.
    enum Status: Equatable {
        case idle
        case recording(title: String?)
        case processing(title: String?, stage: String?)

        var isActive: Bool {
            switch self {
            case .idle: return false
            case .recording, .processing: return true
            }
        }

        var title: String? {
            switch self {
            case .idle: return nil
            case .recording(let t), .processing(let t, _): return t
            }
        }
    }

    // MARK: - User-tunable Preferences

    /// Master feature flag — when false, the entire Minutes integration is
    /// dormant: no recording, no prep brief, no live transcript, no post-meeting
    /// nudge driven by Minutes output. Defaults to false; user opts in from
    /// Settings → Minutes. Meeting Reminder's primary recording story is
    /// delegated to Notion.
    @AppStorage("minutesIntegrationEnabled") var integrationEnabled: Bool = false
    @AppStorage("autoRecordWithMinutes") var autoRecord: Bool = false
    @AppStorage("minutesPrepEnabled") var prepEnabled: Bool = true

    // MARK: - Init

    init() {
        // Default to common Homebrew location; user can override via Settings.
        if let custom = UserDefaults.standard.string(forKey: "minutesBinaryPath") {
            self.binaryPath = URL(fileURLWithPath: custom)
        } else {
            self.binaryPath = URL(fileURLWithPath: "/opt/homebrew/bin/minutes")
        }
        self.meetingsFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("meetings")
    }

    // MARK: - Detection

    func detectInstall() async {
        let result = await runCLI(args: ["--version"])
        if result.exitCode == 0 {
            let raw = String(data: result.stdout, encoding: .utf8) ?? ""
            // Output looks like: "minutes 0.10.2"
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "minutes ", with: "")
            self.version = v
            self.isInstalled = true
            self.lastError = nil
        } else {
            self.isInstalled = false
            self.version = nil
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            self.lastError = stderr.isEmpty ? "minutes not found at \(binaryPath?.path ?? "<unset>")" : stderr
        }
        // Always check the config — even if the binary wasn't found, the user might
        // have a stale config we want to surface in Settings.
        checkLiveTranscriptConfig()
    }

    /// Reads `~/.config/minutes/config.toml` and inspects the `[live_transcript].model`
    /// value. Sets `liveTranscriptConfigured = true` only if the model is non-empty.
    /// This is the same string the recording sidecar uses to decide whether to start
    /// live transcription — empty means JSONL never gets written.
    func checkLiveTranscriptConfig() {
        let configURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config")
            .appendingPathComponent("minutes")
            .appendingPathComponent("config.toml")

        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            // No config = unconfigured. The minutes binary will create a default on first run.
            liveTranscriptModel = ""
            liveTranscriptConfigured = false
            return
        }

        // Find the [live_transcript] section and the model = "..." line within it.
        // Crude TOML parsing — fine because we own the round-trip and the file is generated
        // by the minutes CLI with stable formatting.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inSection = false
        var found: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inSection = (trimmed == "[live_transcript]")
                continue
            }
            if inSection, trimmed.hasPrefix("model"), let eq = trimmed.firstIndex(of: "=") {
                let valuePart = trimmed[trimmed.index(after: eq)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                found = valuePart
                break
            }
        }

        liveTranscriptModel = found ?? ""
        liveTranscriptConfigured = !(found ?? "").isEmpty
    }

    /// Rewrites the `[live_transcript].model` line in `~/.config/minutes/config.toml`
    /// to the chosen whisper model. Creates a backup at `config.toml.bak` first.
    /// Returns true on success.
    @discardableResult
    func setLiveTranscriptModel(_ model: String) -> Bool {
        let configURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config")
            .appendingPathComponent("minutes")
            .appendingPathComponent("config.toml")

        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            self.lastError = "Could not read \(configURL.path)"
            return false
        }

        // Backup
        let backupURL = configURL.appendingPathExtension("bak")
        try? content.write(to: backupURL, atomically: true, encoding: .utf8)

        // Find and replace the model line within [live_transcript]
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inSection = false
        var rewritten = false
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inSection = (trimmed == "[live_transcript]")
                continue
            }
            if inSection, trimmed.hasPrefix("model"), trimmed.contains("=") {
                lines[i] = "model = \"\(model)\""
                rewritten = true
                break
            }
        }

        guard rewritten else {
            self.lastError = "Could not find [live_transcript].model in config.toml"
            return false
        }

        let newContent = lines.joined(separator: "\n")
        do {
            try newContent.write(to: configURL, atomically: true, encoding: .utf8)
            checkLiveTranscriptConfig()
            return true
        } catch {
            self.lastError = "Failed to write config: \(error.localizedDescription)"
            return false
        }
    }

    /// Returns the list of installed whisper models found in `~/.minutes/models/`.
    /// Names are stripped of the `ggml-` prefix and `.bin` suffix to match the
    /// short form expected by the `[live_transcript].model` config key.
    func installedWhisperModels() -> [String] {
        let modelsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".minutes")
            .appendingPathComponent("models")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return entries
            .map { $0.lastPathComponent }
            .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
            .filter { !$0.contains("silero") } // VAD model, not whisper
            .map { name in
                String(name.dropFirst("ggml-".count).dropLast(".bin".count))
            }
            .sorted()
    }

    // MARK: - Status polling

    private var statusTimer: Timer?

    /// Start polling `minutes status` every 3 seconds. Safe to call repeatedly.
    /// Drives the live `status` published property.
    func startStatusPolling() {
        guard statusTimer == nil else { return }
        Task { await refreshStatus() }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshStatus()
            }
        }
    }

    func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// Run `minutes status` once and parse the result into `status`.
    /// Also sets `currentRecordingTitle` when actively recording.
    @discardableResult
    func refreshStatus() async -> Status {
        guard isInstalled else {
            self.status = .idle
            return .idle
        }

        let result = await runCLI(args: ["status"])
        guard result.exitCode == 0,
              let dict = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        else {
            self.status = .idle
            return .idle
        }

        let recording = (dict["recording"] as? Bool) ?? false
        let processing = (dict["processing"] as? Bool) ?? false
        let processingTitle = dict["processing_title"] as? String
        let processingStage = dict["processing_stage"] as? String

        // When recording, Minutes doesn't expose the title via status JSON —
        // we rely on whatever our app passed to `startRecording`, if any.
        let recordingTitle = self.currentRecordingTitle

        let newStatus: Status
        if recording {
            newStatus = .recording(title: recordingTitle ?? processingTitle)
        } else if processing {
            newStatus = .processing(title: processingTitle, stage: processingStage)
        } else {
            newStatus = .idle
        }

        self.status = newStatus
        return newStatus
    }

    func checkHealth() async -> String {
        let result = await runCLI(args: ["health"])
        let combined = (String(data: result.stdout, encoding: .utf8) ?? "")
            + (String(data: result.stderr, encoding: .utf8) ?? "")
        self.lastHealthOutput = combined
        return combined
    }

    // MARK: - Recording Lifecycle

    /// The currently active recording Process handle. Kept so we can check
    /// `isRunning` during the verify window, and so we can terminate it
    /// cleanly from `stopRecording` if needed.
    private var activeRecordingProcess: Process?

    /// Spawn `minutes record --title "<title>"`.
    ///
    /// Unlike the old implementation, this:
    /// 1. Invokes the binary directly (no shell wrapper) so spawn errors are
    ///    real spawn errors, not shell quoting problems
    /// 2. Captures stderr to a `Pipe` so we can read it back on failure
    /// 3. Detects immediate-failure via an async verify task that checks
    ///    `process.isRunning` and `minutes status` 2.5s after spawn
    /// 4. Publishes `recordingDidFail` if verification fails, so
    ///    `OverlayCoordinator` can roll back the optimistic UI state it set
    ///
    /// Returns `true` if the initial spawn succeeded (but the recording may
    /// still fail the async verify check — that surfaces via
    /// `recordingDidFail`).
    @discardableResult
    func startRecording(for event: MeetingEvent) async -> Bool {
        guard isInstalled else {
            self.lastError = "Minutes is not installed"
            return false
        }
        guard let bin = binaryPath else {
            self.lastError = "Minutes binary path not set"
            return false
        }

        // Double-start guard
        let currentStatus = await refreshStatus()
        if currentStatus.isActive {
            let label: String
            switch currentStatus {
            case .recording: label = "recording"
            case .processing: label = "processing"
            case .idle:       label = "active"
            }
            self.lastError = "Minutes is already \(label); skipping start"
            self.recordingDidFail = RecordingFailure(
                attemptedTitle: event.title,
                summary: "Minutes is already \(label)",
                stderr: "Stop the current recording first, or use Reconnect."
            )
            return false
        }

        let title = event.title
        let process = Process()
        process.executableURL = bin
        process.arguments = ["record", "--title", title]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe() // discard stdout — minutes prints human messages we don't need

        do {
            try process.run()
        } catch {
            let failure = RecordingFailure(
                attemptedTitle: title,
                summary: "Failed to launch minutes binary",
                stderr: error.localizedDescription
            )
            self.recordingDidFail = failure
            self.lastError = failure.summary
            return false
        }

        self.activeRecordingProcess = process
        self.currentRecordingTitle = title
        self.lastError = nil

        // Verify the recording actually started. `minutes record` can exit
        // immediately on bad config (missing device, missing model, etc.) —
        // our spawn will have returned success but the process is already dead.
        // 2.5s is enough for the whisper model load + audio device init.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await self?.verifyRecordingStarted(
                process: process,
                stderrPipe: stderrPipe,
                title: title
            )
        }

        return true
    }

    private func verifyRecordingStarted(
        process: Process,
        stderrPipe: Pipe,
        title: String
    ) async {
        // Case 1: the Process has already terminated. Read stderr and fail.
        if !process.isRunning {
            let stderrText = readPipeSafely(stderrPipe).trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = summarize(stderr: stderrText)

            self.activeRecordingProcess = nil
            self.currentRecordingTitle = nil
            self.status = .idle
            self.lastError = summary
            self.recordingDidFail = RecordingFailure(
                attemptedTitle: title,
                summary: summary,
                stderr: stderrText.isEmpty ? "(no stderr output)" : stderrText
            )
            return
        }

        // Case 2: Process is alive — confirm via `minutes status` that it
        // actually registered as recording. Sometimes the process is alive
        // but in a degraded state.
        let status = await refreshStatus()
        if case .recording = status {
            // All good — nothing to do. The verify task exits.
            return
        }

        // Process alive but status not reporting recording yet. Give it one
        // more 2s to settle, then re-check.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let retry = await refreshStatus()
        if case .recording = retry { return }

        // Still not recording. Kill the process and surface a degraded-state error.
        if process.isRunning { process.terminate() }
        let stderrText = readPipeSafely(stderrPipe).trimmingCharacters(in: .whitespacesAndNewlines)

        self.activeRecordingProcess = nil
        self.currentRecordingTitle = nil
        self.status = .idle
        self.recordingDidFail = RecordingFailure(
            attemptedTitle: title,
            summary: "Minutes started but did not register as recording",
            stderr: stderrText.isEmpty ? "(no stderr output)" : stderrText
        )
    }

    /// Read whatever is currently buffered on a pipe without blocking.
    /// Used for post-mortem stderr read after a process has terminated.
    private nonisolated func readPipeSafely(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.availableData
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Extract a single human-readable summary line from a stderr blob.
    /// Minutes stderr is tracing-formatted: `2026-04-07T22:00:04 ERROR requested audio device not found ...`
    /// We strip the timestamp/level prefix and return the remaining message.
    private nonisolated func summarize(stderr: String) -> String {
        guard !stderr.isEmpty else { return "minutes record exited immediately with no output" }

        // Find the first ERROR line, or fall back to the last non-empty line.
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let errorLine = lines.first { $0.contains("ERROR") || $0.lowercased().contains("error:") }
        let chosen = errorLine ?? lines.last ?? stderr

        // Strip ANSI escapes (minutes uses colour in its tracing output)
        let ansiPattern = "\u{1B}\\[[0-9;]*m"
        var clean = chosen.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)

        // Strip leading timestamp like "2026-04-07T22:00:04.745069Z  ERROR"
        if let errorRange = clean.range(of: "ERROR") {
            clean = String(clean[errorRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
        } else if let colonRange = clean.range(of: "error:", options: .caseInsensitive) {
            clean = String(clean[colonRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
        }

        // Trim noise suffixes
        if let firstLineBreak = clean.firstIndex(of: "\n") {
            clean = String(clean[..<firstLineBreak])
        }

        return clean.isEmpty ? "minutes record failed (see stderr for details)" : clean
    }

    func stopRecording() async {
        guard isInstalled else { return }
        _ = await runCLI(args: ["stop"])
        self.currentRecordingTitle = nil
    }

    func addNote(_ text: String) async {
        guard isInstalled else { return }
        _ = await runCLI(args: ["note", text])
    }

    // MARK: - Fetch parsed meeting

    /// Polls the meetings folder up to 6 times (5s intervals) for the markdown file
    /// with the given slug, then parses it. Returns nil if not found.
    func fetchMeeting(slug: String) async -> MinutesMeeting? {
        guard let folder = meetingsFolder else { return nil }
        let url = folder.appendingPathComponent("\(slug).md")

        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: url.path) {
                if let meeting = MinutesMeeting.parse(markdownAt: url) {
                    return meeting
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return nil
    }

    /// Computes the kebab-case slug `minutes` will use for a meeting recorded today.
    /// Format observed in real Minutes output: `YYYY-MM-DD-{kebab-title}`.
    nonisolated func slug(for event: MeetingEvent) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        let datePart = dateFormatter.string(from: Date())
        let titlePart = kebabify(event.title)
        return "\(datePart)-\(titlePart)"
    }

    private nonisolated func kebabify(_ s: String) -> String {
        let lowered = s.lowercased()
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits)
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                out.append(Character(scalar))
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Prep brief composition

    /// Composes a "prep brief" by running `minutes person <name>` for each attendee
    /// (max 3) and `minutes research <title>` for the meeting topic. Returns the
    /// joined output as plain text.
    func generatePrepBrief(for event: MeetingEvent) async -> String? {
        guard isInstalled, prepEnabled else { return nil }

        var sections: [String] = []

        // Topic research
        let topic = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty {
            let result = await runCLI(args: ["research", topic])
            if result.exitCode == 0,
               let raw = String(data: result.stdout, encoding: .utf8),
               let body = sanitizePrepOutput(raw),
               !isEmptyPrepResponse(body) {
                sections.append("Topic context\n\(body)")
            }
        }

        // Per-attendee profiles (limit 3 to bound cost)
        if let attendees = event.attendees, !attendees.isEmpty {
            let limited = attendees.prefix(3)
            for name in limited {
                let cleaned = name
                    .replacingOccurrences(of: "@.*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                let result = await runCLI(args: ["person", cleaned])
                if result.exitCode == 0,
                   let raw = String(data: result.stdout, encoding: .utf8),
                   let body = sanitizePrepOutput(raw),
                   !isEmptyPrepResponse(body) {
                    sections.append("\(cleaned)\n\(body)")
                }
            }
        }

        if sections.isEmpty { return nil }
        return sections.joined(separator: "\n\n")
    }

    /// Strips the trailing JSON dump that `minutes research` and `minutes person`
    /// append after their natural-language summary. Returns the human-readable lines only.
    private nonisolated func sanitizePrepOutput(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Cut off at the first `{` that begins a JSON dump.
        if let braceIdx = trimmed.firstIndex(of: "{") {
            let before = trimmed[..<braceIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            return before.isEmpty ? nil : before
        }
        return trimmed
    }

    /// Recognises Minutes' "no data" responses so we don't render an empty section.
    private nonisolated func isEmptyPrepResponse(_ body: String) -> Bool {
        let lower = body.lowercased()
        let phrases = [
            "no cross-meeting results found",
            "no profile data found",
            "no results",
            "no meetings",
            "no recent meetings",
        ]
        return phrases.contains { lower.contains($0) }
    }

    // MARK: - File reveal

    nonisolated func openMeetingInFinder(_ meeting: MinutesMeeting) {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.transcriptPath])
    }

    // MARK: - Binary picker

    func setBinaryPath(_ url: URL) {
        self.binaryPath = url
        UserDefaults.standard.set(url.path, forKey: "minutesBinaryPath")
        Task { await detectInstall() }
    }

    // MARK: - Internal: Process runner

    private struct CLIResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    private func runCLI(args: [String]) async -> CLIResult {
        guard let bin = binaryPath else {
            return CLIResult(stdout: Data(), stderr: Data("binary path not set".utf8), exitCode: 127)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                // Quote each argument so titles with spaces survive.
                let quotedArgs = args.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                    .joined(separator: " ")
                process.arguments = ["-lc", "\"\(bin.path)\" \(quotedArgs)"]
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    process.waitUntilExit()
                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: CLIResult(
                        stdout: outData,
                        stderr: errData,
                        exitCode: process.terminationStatus
                    ))
                } catch {
                    continuation.resume(returning: CLIResult(
                        stdout: Data(),
                        stderr: Data(error.localizedDescription.utf8),
                        exitCode: 1
                    ))
                }
            }
        }
    }
}
