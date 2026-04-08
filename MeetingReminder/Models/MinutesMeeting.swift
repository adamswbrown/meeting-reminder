import Foundation

/// A meeting recorded and processed by the `minutes` CLI.
/// Parsed from the YAML frontmatter of `~/meetings/<slug>.md`.
struct MinutesMeeting: Identifiable, Equatable {
    let slug: String              // 2026-04-07-team-standup
    let title: String
    let date: Date?
    let duration: String?         // raw duration string e.g. "42m" or "9s"
    let attendees: [String]
    let actionItems: [ActionItem]
    let decisions: [Decision]
    let summary: String?
    let transcriptPath: URL

    var id: String { slug }

    struct ActionItem: Identifiable, Equatable {
        let id = UUID()
        let assignee: String?
        let task: String
        let due: String?
        let status: String?       // "open" / "done" / etc.

        static func == (lhs: ActionItem, rhs: ActionItem) -> Bool {
            lhs.assignee == rhs.assignee && lhs.task == rhs.task &&
                lhs.due == rhs.due && lhs.status == rhs.status
        }
    }

    struct Decision: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let topic: String?

        static func == (lhs: Decision, rhs: Decision) -> Bool {
            lhs.text == rhs.text && lhs.topic == rhs.topic
        }
    }

    static func == (lhs: MinutesMeeting, rhs: MinutesMeeting) -> Bool {
        lhs.slug == rhs.slug
    }

    /// Parses a Minutes markdown file. Returns nil on failure.
    static func parse(markdownAt url: URL) -> MinutesMeeting? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return parse(markdown: content, url: url)
    }

    /// Internal entry point for parsing markdown content directly (used by tests).
    static func parse(markdown: String, url: URL) -> MinutesMeeting? {
        // Frontmatter is bounded by `---` fences. The first line must be `---`.
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        // Find the closing fence.
        var endIndex: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            endIndex = i
            break
        }
        guard let frontmatterEnd = endIndex else { return nil }
        let frontmatter = Array(lines[1..<frontmatterEnd])
        let body = lines[(frontmatterEnd + 1)...].joined(separator: "\n")

        let parsed = MinutesYAML.parse(lines: frontmatter)

        // Build slug from filename: drop ".md" extension.
        let slug = url.deletingPathExtension().lastPathComponent

        let title = parsed.scalar("title") ?? slug
        let date = parsed.date("date")
        let duration = parsed.scalar("duration")
        let attendees = parsed.stringList("attendees")
        let actionItems = parsed.mappingList("action_items").map { dict -> ActionItem in
            ActionItem(
                assignee: dict["assignee"],
                task: dict["task"] ?? "",
                due: dict["due"],
                status: dict["status"]
            )
        }
        let decisions = parsed.mappingList("decisions").map { dict -> Decision in
            Decision(
                text: dict["text"] ?? "",
                topic: dict["topic"]
            )
        }

        // Extract first H2 "## Summary" section bullets, joined.
        let summary = extractSummary(from: body)

        return MinutesMeeting(
            slug: slug,
            title: title,
            date: date,
            duration: duration,
            attendees: attendees,
            actionItems: actionItems,
            decisions: decisions,
            summary: summary,
            transcriptPath: url
        )
    }

    private static func extractSummary(from body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let startIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## Summary") }) else {
            return nil
        }
        var collected: [String] = []
        for i in (startIdx + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break }
            if trimmed.hasPrefix("- ") {
                collected.append(String(trimmed.dropFirst(2)))
            } else if !trimmed.isEmpty {
                collected.append(trimmed)
            }
        }
        let joined = collected.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }
}

// MARK: - Minimal YAML parser

/// Hand-rolled parser for the subset of YAML used by `minutes` frontmatter:
/// - top-level scalars (`key: value`)
/// - top-level lists of scalars (`key:\n- value`)
/// - top-level lists of mappings (`key:\n- field1: x\n  field2: y`)
/// - skips nested mappings on keys we don't recognize (e.g. `entities`)
private struct MinutesYAML {
    private var scalars: [String: String] = [:]
    private var stringLists: [String: [String]] = [:]
    private var mappingLists: [String: [[String: String]]] = [:]

    static func parse(lines: [String]) -> MinutesYAML {
        var result = MinutesYAML()
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            // Top-level keys have no leading whitespace.
            guard !raw.isEmpty, !raw.hasPrefix(" "), !raw.hasPrefix("\t") else {
                i += 1
                continue
            }

            if let colonIdx = raw.firstIndex(of: ":") {
                let key = String(raw[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let valueStart = raw.index(after: colonIdx)
                let valuePart = String(raw[valueStart...]).trimmingCharacters(in: .whitespaces)

                if !valuePart.isEmpty {
                    // Inline scalar: `key: value`
                    result.scalars[key] = unquote(valuePart)
                    i += 1
                    continue
                }

                // Block value: collect indented children.
                var children: [String] = []
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    if next.isEmpty {
                        children.append(next)
                        j += 1
                        continue
                    }
                    // Stop at next top-level key (no indent, contains colon at top level).
                    if !next.hasPrefix(" ") && !next.hasPrefix("\t") && !next.hasPrefix("- ") {
                        break
                    }
                    children.append(next)
                    j += 1
                }
                i = j

                // Classify children.
                let stripped = children.map { $0.drop(while: { $0 == " " || $0 == "\t" }) }
                let firstNonEmpty = stripped.first { !$0.isEmpty }
                guard let first = firstNonEmpty else { continue }

                if first.hasPrefix("- ") {
                    // List. Either list-of-strings or list-of-mappings.
                    let firstItemBody = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if firstItemBody.contains(":") && !firstItemBody.hasPrefix("http") {
                        // List of mappings.
                        result.mappingLists[key] = parseListOfMappings(children)
                    } else {
                        // List of scalars.
                        result.stringLists[key] = children.compactMap { line in
                            let s = line.drop(while: { $0 == " " || $0 == "\t" })
                            guard s.hasPrefix("- ") else { return nil }
                            return unquote(String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                        }
                    }
                }
                // Otherwise it's a nested mapping (e.g. `entities:`) — skip silently.
            } else {
                i += 1
            }
        }
        return result
    }

    private static func parseListOfMappings(_ rawLines: [String]) -> [[String: String]] {
        var items: [[String: String]] = []
        var current: [String: String]?
        for line in rawLines {
            let stripped = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            if stripped.isEmpty { continue }
            if stripped.hasPrefix("- ") {
                if let c = current { items.append(c) }
                current = [:]
                let rest = String(stripped.dropFirst(2))
                if let colon = rest.firstIndex(of: ":") {
                    let k = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
                    let v = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty {
                        current?[k] = unquote(v)
                    }
                }
            } else if let colon = stripped.firstIndex(of: ":") {
                let k = String(stripped[..<colon]).trimmingCharacters(in: .whitespaces)
                let v = String(stripped[stripped.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                current?[k] = unquote(v)
            }
        }
        if let c = current { items.append(c) }
        return items
    }

    private static func unquote(_ s: String) -> String {
        var t = s
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")), t.count >= 2 {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    func scalar(_ key: String) -> String? { scalars[key] }
    func stringList(_ key: String) -> [String] { stringLists[key] ?? [] }
    func mappingList(_ key: String) -> [[String: String]] { mappingLists[key] ?? [] }

    func date(_ key: String) -> Date? {
        guard let raw = scalars[key] else { return nil }
        // Minutes uses ISO 8601 with fractional seconds + timezone:
        // 2026-04-07T06:49:35.492833+01:00
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: raw) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
