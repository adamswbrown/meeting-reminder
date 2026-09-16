import Foundation

// MARK: - Token budget (pure, testable — NOT gated to macOS 26)
//
// Legacy compact-context rendering uses a conservative 4,096-token budget.
// The fallback provider reads the actual runtime window and counts tokens. Measured
// 4.07 chars/token on real briefing prose (see docs); we divide by 3.5 to
// OVER-estimate tokens (~16% safety margin) so we truncate before the framework
// ever errors.

enum TokenBudget {
    static let window = 4096
    static let instructionReserve = 100   // ~3-sentence system instructions
    static let outputReserve = 500        // legacy compact generation headroom
    static var inputCeiling: Int { window - instructionReserve - outputReserve } // 3496

    static func estimate(_ s: String) -> Int { Int(ceil(Double(s.count) / 3.5)) }
    static func fits(_ s: String) -> Bool { estimate(s) <= inputCeiling }
}

enum IntradayContextCaps {
    static let priorNotesChars = 1500     // ≈ 430 tok — the one variable-length field
    static let maxAttendees = 6
    static let attendeeChars = 70
    static let titleChars = 160
}

// MARK: - Assembled context (pure, testable)
//
// Everything the model is allowed to see. Built deterministically in Swift (the
// skill's gathering steps) so the model only does the generation step. render()
// applies hard caps and a deterministic degrade ladder so it always fits the 4K
// window regardless of how large the source notes are.

struct IntradayBriefContext {
    let title: String
    let startLondon: String   // pre-formatted Europe/London "yyyy-MM-dd HH:mm"
    let endLondon: String
    let video: String?
    let attendees: [String]
    let priorNotesSnippet: String?

    /// Full prompt, then drop lowest-priority sections until it fits.
    func render() -> String {
        for notesCap in [IntradayContextCaps.priorNotesChars, IntradayContextCaps.priorNotesChars / 2, 0] {
            let s = build(notesCap: notesCap)
            if TokenBudget.fits(s) { return s }
        }
        return renderMinimal()
    }

    /// Title / time / attendees only — the last-resort fallback (never drops identity).
    func renderMinimal() -> String { build(notesCap: 0, includeVideo: false) }

    private func build(notesCap: Int, includeVideo: Bool = true) -> String {
        var lines: [String] = ["MEETING"]
        lines.append("- Title: \(String(title.prefix(IntradayContextCaps.titleChars)))")
        lines.append("- When (Europe/London): \(startLondon)–\(endLondon)")
        if includeVideo, let video, !video.isEmpty { lines.append("- Video: \(video)") }

        let att = attendees.prefix(IntradayContextCaps.maxAttendees)
            .map { String($0.prefix(IntradayContextCaps.attendeeChars)) }
        if !att.isEmpty {
            lines.append("ATTENDEES")
            lines.append(contentsOf: att.map { "- \($0)" })
        }

        if notesCap > 0, let notes = priorNotesSnippet,
           case let trimmed = Self.truncateWords(notes, notesCap), !trimmed.isEmpty {
            lines.append("PRIOR CONTEXT (from the invite / most recent notes)")
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n")
    }

    static func truncateWords(_ s: String, _ maxChars: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxChars else { return t }
        let cut = t.prefix(maxChars)
        if let sp = cut.lastIndex(of: " ") { return cut[..<sp] + " …" }
        return cut + " …"
    }
}

extension IntradayBriefContext {
    /// Build from a calendar event. `priorNotes` (the most recent Notion Meeting Notes
    /// for a repeated meeting) takes precedence over the invite body when present.
    static func from(_ e: MeetingEvent, priorNotes: String? = nil) -> IntradayBriefContext {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.timeZone = TimeZone(identifier: "Europe/London")
        fmt.locale = Locale(identifier: "en_GB_POSIX")
        let inviteBody = e.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = (priorNotes?.isEmpty == false) ? priorNotes : inviteBody
        return IntradayBriefContext(
            title: e.title,
            startLondon: fmt.string(from: e.startDate),
            endLondon: fmt.string(from: e.endDate),
            video: e.videoLink?.host,
            attendees: e.attendees ?? [],
            priorNotesSnippet: (notes?.isEmpty == false) ? notes : nil)
    }
}
