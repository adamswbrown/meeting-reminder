import Foundation

/// Reads the most recent *prior* Meeting Notes page whose title matches an upcoming
/// meeting, and returns a plain-text snippet of its body. Feeds the on-device intraday
/// briefing so a repeated meeting is briefed with what happened last time — not just the
/// invite body. Best-effort: returns nil on no token / no match / any error.
enum NotionPriorNotesReader {

    /// - Parameters:
    ///   - title: the upcoming meeting's title (matched as a Notion `contains` needle).
    ///   - before: only consider notes dated strictly before this (a genuine *prior* meeting).
    ///   - maxChars: cap on the returned snippet.
    static func fetch(title rawTitle: String,
                      before: Date,
                      maxChars: Int = 1500,
                      logPath: String) async -> String? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 3 else { return nil }
        guard let token = KeychainHelper.read(key: CalendarSyncConstants.tokenKeychainKey),
              !token.isEmpty else { return nil }

        let logger = CalendarSyncLogger(path: logPath)
        let client = CalendarSyncNotionClient(token: token, logger: logger)

        do {
            // 1. Most recent Meeting Notes rows matching the title, newest first.
            let query: [String: Any] = [
                "page_size": 5,
                "sorts": [["property": CalendarSyncConstants.meetingNotesDateProperty,
                           "direction": "descending"]],
                "filter": ["property": CalendarSyncConstants.meetingNotesTitleProperty,
                           "title": ["contains": title]],
            ]
            let resp = try await client.post(
                path: "/data_sources/\(CalendarSyncConstants.meetingNotesDataSourceID)/query",
                body: query)
            let rows = resp["results"] as? [[String: Any]] ?? []

            // 2. Pick the newest row dated strictly before the upcoming meeting.
            guard let pageID = newestPriorPageID(rows: rows, before: before) else { return nil }

            // 3. Read its block children and flatten to text.
            let blocksResp = try await client.get(path: "/blocks/\(pageID)/children?page_size=100")
            let blocks = blocksResp["results"] as? [[String: Any]] ?? []
            let text = extractPlainText(fromBlocks: blocks, maxChars: maxChars)
            return text.isEmpty ? nil : text
        } catch {
            logger.warn("prior-notes read failed for '\(title)': \(error)")
            return nil
        }
    }

    // MARK: - Pure helpers (testable)

    /// The page id of the newest row whose `Start` date is strictly before `before`.
    /// Rows are assumed newest-first (query sorts descending) but we don't rely on it.
    static func newestPriorPageID(rows: [[String: Any]], before: Date) -> String? {
        var best: (id: String, date: Date)?
        for row in rows {
            guard let id = row["id"] as? String,
                  let props = row["properties"] as? [String: Any],
                  let date = startDate(props[CalendarSyncConstants.meetingNotesDateProperty]),
                  date < before else { continue }
            if best == nil || date > best!.date { best = (id, date) }
        }
        return best?.id
    }

    /// Parse a Notion `date` property's start into a Date (date or datetime).
    static func startDate(_ any: Any?) -> Date? {
        guard let dict = any as? [String: Any],
              let date = dict["date"] as? [String: Any],
              let start = date["start"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: start) { return d }
        iso.formatOptions = [.withFullDate]   // date-only ("2026-08-10")
        return iso.date(from: start)
    }

    /// Flatten common text-bearing Notion blocks to plain text, capped at `maxChars`.
    static func extractPlainText(fromBlocks blocks: [[String: Any]], maxChars: Int) -> String {
        let textTypes = ["paragraph", "heading_1", "heading_2", "heading_3",
                         "bulleted_list_item", "numbered_list_item", "toggle",
                         "quote", "callout", "to_do"]
        var pieces: [String] = []
        for block in blocks {
            guard let type = block["type"] as? String, textTypes.contains(type),
                  let payload = block[type] as? [String: Any],
                  let rich = payload["rich_text"] as? [[String: Any]] else { continue }
            let line = rich.compactMap { $0["plain_text"] as? String }.joined()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                pieces.append(type.hasPrefix("bulleted") || type.hasPrefix("numbered") || type == "to_do"
                              ? "• \(trimmed)" : trimmed)
            }
        }
        let joined = pieces.joined(separator: "\n")
        guard joined.count > maxChars else { return joined }
        let cut = joined.prefix(maxChars)
        if let sp = cut.lastIndex(of: " ") { return cut[..<sp] + " …" }
        return cut + " …"
    }
}
