import Foundation
import SwiftUI

/// One transcript line as written by the `minutes` recording sidecar
/// to `~/.minutes/live-transcript.jsonl`.
struct LiveTranscriptLine: Identifiable, Equatable {
    let line: Int
    let timestamp: Date?
    let offsetMs: Int
    let durationMs: Int
    let text: String
    let speaker: String?

    var id: Int { line }
}

/// A short coach hint that surfaces in the live transcript pane.
struct CoachHint: Identifiable, Equatable {
    let id = UUID()
    let kind: Kind
    let text: String
    let createdAt: Date

    enum Kind: String {
        case question, mention, commitment

        var icon: String {
            switch self {
            case .question:    return "questionmark.bubble.fill"
            case .mention:     return "person.crop.circle.badge.exclamationmark.fill"
            case .commitment:  return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .question:    return .blue
            case .mention:     return .orange
            case .commitment:  return .red
            }
        }
    }
}

/// Tails `~/.minutes/live-transcript.jsonl`, publishes new lines, and runs
/// lightweight heuristics over each new line to surface in-call coach hints.
@MainActor
final class LiveTranscriptService: ObservableObject {
    @Published var lines: [LiveTranscriptLine] = []
    @Published var hints: [CoachHint] = []
    @Published var isRunning: Bool = false

    @AppStorage("liveTranscriptEnabled") var liveTranscriptEnabled: Bool = true
    @AppStorage("inCallCoachEnabled") var inCallCoachEnabled: Bool = true
    @AppStorage("coachUserName") var userName: String = ""

    private var pollTimer: Timer?
    private var lastSeenLine: Int = 0
    private let jsonlURL: URL

    init() {
        self.jsonlURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".minutes")
            .appendingPathComponent("live-transcript.jsonl")
    }

    /// Start tailing the live-transcript JSONL. Safe to call repeatedly.
    func start() {
        guard liveTranscriptEnabled, !isRunning else { return }
        isRunning = true
        lines.removeAll()
        hints.removeAll()
        lastSeenLine = 0

        // Poll every 1.5s — whisper chunks land every ~3s, so this is responsive without busy-looping.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        // Immediate first poll so the pane isn't empty for 1.5s.
        poll()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isRunning = false
    }

    func clear() {
        lines.removeAll()
        hints.removeAll()
        lastSeenLine = 0
    }

    /// Inject sample data for preview (no real CLI / file polling).
    /// Used by the Preview button in the menu bar so users can see the
    /// transcript pane layout without starting a real meeting.
    func loadPreviewData() {
        stop()
        lines.removeAll()
        hints.removeAll()
        lastSeenLine = 0

        let now = Date()
        let samples: [(Int, String, String?)] = [
            (1,  "Alright everyone, thanks for joining the quarterly review.",                   "Alice"),
            (2,  "Let's start with the product roadmap update.",                                  "Alice"),
            (3,  "I'll send the deck right after the call so you can review it.",                "Bob"),
            (4,  "What's the timeline for the new release?",                                      "Charlie"),
            (5,  "We're targeting end of next sprint, so by Friday week.",                        "Bob"),
            (6,  "Adam, can you walk us through the design changes?",                             "Alice"),
            (7,  "Sure — the main change is the new dashboard layout.",                           "Adam"),
            (8,  "I'll follow up with the engineering team on the API changes.",                  "Adam"),
            (9,  "Sounds good. Let's circle back on this on Monday.",                             "Alice"),
            (10, "I'll have the updated mockups ready by end of day Wednesday.",                  "Adam"),
        ]

        var collected: [LiveTranscriptLine] = []
        for (i, text, speaker) in samples {
            collected.append(LiveTranscriptLine(
                line: i,
                timestamp: now.addingTimeInterval(Double(i) * 6),
                offsetMs: i * 6000,
                durationMs: 5000,
                text: text,
                speaker: speaker
            ))
        }
        lines = collected
        lastSeenLine = collected.last?.line ?? 0

        // Run heuristics so the preview also shows coach hints
        if inCallCoachEnabled {
            for line in collected {
                analyze(line)
            }
        }

        // Mark "running" so the red recording dot shows in preview
        isRunning = true
    }

    // MARK: - Polling

    private func poll() {
        guard FileManager.default.fileExists(atPath: jsonlURL.path) else { return }
        guard let data = try? Data(contentsOf: jsonlURL),
              let raw = String(data: data, encoding: .utf8) else { return }

        let allLines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()

        var newLines: [LiveTranscriptLine] = []
        for entry in allLines {
            guard let lineData = entry.data(using: .utf8) else { continue }
            guard let dict = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard let lineNum = dict["line"] as? Int, lineNum > lastSeenLine else { continue }

            let text = (dict["text"] as? String) ?? ""
            let offsetMs = (dict["offset_ms"] as? Int) ?? 0
            let durationMs = (dict["duration_ms"] as? Int) ?? 0
            let speaker = dict["speaker"] as? String
            var date: Date?
            if let ts = dict["ts"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                date = f.date(from: ts)
            }

            let parsed = LiveTranscriptLine(
                line: lineNum,
                timestamp: date,
                offsetMs: offsetMs,
                durationMs: durationMs,
                text: text,
                speaker: speaker
            )
            newLines.append(parsed)
            _ = decoder // suppress unused warning if decoder isn't used
        }

        guard !newLines.isEmpty else { return }
        lines.append(contentsOf: newLines)
        lastSeenLine = newLines.last!.line

        // Bound history to keep memory tiny.
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
        }

        // Run heuristics on each new line.
        if inCallCoachEnabled {
            for line in newLines {
                analyze(line)
            }
        }
    }

    // MARK: - Heuristic Coach (Tier 2)

    /// Lightweight pattern matching against transcript lines. Cheap, no LLM.
    private func analyze(_ line: LiveTranscriptLine) {
        let raw = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count > 4 else { return }
        let lower = raw.lowercased()

        // 1. Question detected — chunk ends with "?" or starts with classic question words.
        let questionWords = ["what", "when", "where", "why", "how", "who", "which", "could you", "can you", "would you", "do you", "does anyone"]
        let endsWithQuestion = raw.hasSuffix("?")
        let leadsWithQuestion = questionWords.contains { lower.hasPrefix($0 + " ") }
        if endsWithQuestion || leadsWithQuestion {
            push(.question, "Someone asked a question.")
        }

        // 2. User mention — check for the user's name.
        let trimmedName = userNameOrSystemDefault().trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            // Match first name OR full name, case-insensitive, with word boundaries.
            let firstName = trimmedName.split(separator: " ").first.map(String.init) ?? trimmedName
            if mentions(haystack: lower, needle: firstName.lowercased()) ||
               mentions(haystack: lower, needle: trimmedName.lowercased()) {
                push(.mention, "They mentioned you.")
            }
        }

        // 3. Commitment language — common patterns where the user (or another speaker) commits to do something.
        let commitmentPatterns: [String] = [
            "i'll send", "i will send", "i'll get", "i will get",
            "i'll do", "i will do", "i'll have", "i will have",
            "i'll set", "i will set", "i can do", "i can have",
            "i'll follow up", "i'll reach out", "i'll circle back",
            "by friday", "by monday", "by tuesday", "by wednesday",
            "by thursday", "by next week", "by end of day", "by eod",
        ]
        for pattern in commitmentPatterns {
            if lower.contains(pattern) {
                push(.commitment, "Commitment detected — capture this.")
                break
            }
        }
    }

    private func mentions(haystack: String, needle: String) -> Bool {
        guard !needle.isEmpty, needle.count >= 2 else { return false }
        // Word-boundary-ish: match if the needle appears bounded by non-letter chars or string ends.
        let pattern = "(^|\\W)\(NSRegularExpression.escapedPattern(for: needle))(\\W|$)"
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    private func push(_ kind: CoachHint.Kind, _ text: String) {
        // De-dupe: if the most recent hint is the same kind in the last 8 seconds, skip.
        if let last = hints.last,
           last.kind == kind,
           Date().timeIntervalSince(last.createdAt) < 8 {
            return
        }
        let hint = CoachHint(kind: kind, text: text, createdAt: Date())
        hints.append(hint)
        // Bound to last 5 hints visible.
        if hints.count > 5 {
            hints.removeFirst(hints.count - 5)
        }
        // Optional chime for high-priority hints.
        if kind == .mention {
            NSSound(named: NSSound.Name("Tink"))?.play()
        }
    }

    private func userNameOrSystemDefault() -> String {
        if !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return userName
        }
        return NSFullUserName()
    }
}
