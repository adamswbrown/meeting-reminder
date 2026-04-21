import AppKit
import Foundation

/// Fetches pre-call briefs from a Notion database and matches them to calendar
/// events. Reuses the Notion integration token stored in Keychain by
/// `NotionService` — no new credentials.
///
/// Flow:
///   1. `match(for:)` queries the configured Notion database filtered on a
///      ±12h window around the event's start, scores each candidate by a
///      Levenshtein-based fuzzy title match (Attendees overlap as tiebreaker),
///      and returns the top pick above threshold. Widens to ±7 days if nothing
///      matches on the same day.
///   2. `fetchBrief(pageID:)` pulls the page's children blocks and converts
///      them to markdown in-process.
///   3. `attach(pageID:to:)` persists a user-chosen page as the definitive
///      match for an event (survives app restart, never overwritten by
///      auto-match).
///   4. `listRecentBriefs(daysBack:)` powers the manual "Attach brief…"
///      picker.
@MainActor
final class PreCallBriefService: ObservableObject {
    // MARK: - Published state

    @Published var lastError: String?
    @Published var isSearching = false

    // MARK: - Configuration

    /// Keychain key owned by NotionService — we deliberately share it.
    private let tokenKey = "notionAPIToken"

    /// Default data source (database) ID — the "Pre-Call Briefings" DB.
    /// User can change this in Settings to point the pipeline at a different
    /// Notion database (future generalisation).
    static let defaultDatabaseID = "c2a1ea4e2c58470ea77608a635756d00"

    var databaseID: String {
        let stored = UserDefaults.standard.string(forKey: "preCallBriefsDatabaseID") ?? ""
        return stored.isEmpty ? Self.defaultDatabaseID : stored
    }

    var fuzzyThreshold: Double {
        let stored = UserDefaults.standard.double(forKey: "preCallBriefFuzzyThreshold")
        return stored == 0 ? 0.6 : stored
    }

    var apiToken: String? {
        KeychainHelper.read(key: tokenKey)
    }

    /// True when we have a token. The database ID always has a default, so
    /// no separate "configured" check is needed for that.
    var isConfigured: Bool {
        apiToken != nil
    }

    // MARK: - Persistence

    private let matchesKey = "preCallBriefMatches"

    private func loadMatches() -> [String: BriefMatch] {
        guard let data = UserDefaults.standard.data(forKey: matchesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: BriefMatch].self, from: data)) ?? [:]
    }

    private func saveMatches(_ matches: [String: BriefMatch]) {
        if let data = try? JSONEncoder().encode(matches) {
            UserDefaults.standard.set(data, forKey: matchesKey)
        }
    }

    func storedMatch(for eventID: String) -> BriefMatch? {
        loadMatches()[eventID]
    }

    /// Manual attach — survives app restart and protects from auto-overwrite.
    func attach(summary: BriefSummary, to eventID: String) {
        var matches = loadMatches()
        matches[eventID] = BriefMatch(
            pageID: summary.pageID,
            pageURL: summary.pageURL.absoluteString,
            title: summary.title,
            matchedAt: Date(),
            userAttached: true
        )
        saveMatches(matches)
        objectWillChange.send()
    }

    func clearMatch(for eventID: String) {
        var matches = loadMatches()
        matches.removeValue(forKey: eventID)
        saveMatches(matches)
        objectWillChange.send()
    }

    // MARK: - Matching

    /// Find the best-matching brief for the event. Returns nil if nothing
    /// scores above threshold. Respects a prior user-attached match if one
    /// exists (never re-matches over a manual choice).
    func match(for event: MeetingEvent) async -> BriefMatch? {
        if let existing = storedMatch(for: event.id) {
            return existing
        }

        // Primary window: ±12h of the event start.
        let primaryStart = event.startDate.addingTimeInterval(-12 * 3600)
        let primaryEnd = event.startDate.addingTimeInterval(12 * 3600)

        if let best = await bestMatch(in: primaryStart...primaryEnd, for: event) {
            let match = BriefMatch(
                pageID: best.pageID,
                pageURL: best.pageURL.absoluteString,
                title: best.title,
                matchedAt: Date(),
                userAttached: false
            )
            var stored = loadMatches()
            stored[event.id] = match
            saveMatches(stored)
            return match
        }

        // Fallback: widen to ±7 days.
        let wideStart = event.startDate.addingTimeInterval(-7 * 86400)
        let wideEnd = event.startDate.addingTimeInterval(7 * 86400)
        if let best = await bestMatch(in: wideStart...wideEnd, for: event) {
            let match = BriefMatch(
                pageID: best.pageID,
                pageURL: best.pageURL.absoluteString,
                title: best.title,
                matchedAt: Date(),
                userAttached: false
            )
            var stored = loadMatches()
            stored[event.id] = match
            saveMatches(stored)
            return match
        }

        return nil
    }

    /// Re-run auto-match, ignoring any prior stored match (including manual).
    func rematch(for event: MeetingEvent) async -> BriefMatch? {
        var stored = loadMatches()
        stored.removeValue(forKey: event.id)
        saveMatches(stored)
        return await match(for: event)
    }

    private func bestMatch(in range: ClosedRange<Date>, for event: MeetingEvent) async -> BriefSummary? {
        let candidates = await queryBriefs(in: range)
        guard !candidates.isEmpty else { return nil }

        let eventTitleLower = event.title.lowercased()
        let eventAttendees = Set((event.attendees ?? []).map { $0.lowercased() })

        var scored: [(BriefCandidateSummary, Double)] = []
        for candidate in candidates {
            let titleScore = Self.similarity(candidate.title.lowercased(), eventTitleLower)
            var score = titleScore
            // Attendees overlap bonus: up to +0.15 if attendees text mentions names from the event
            if let attendeesText = candidate.attendeesText?.lowercased() {
                let overlap = eventAttendees.filter { !$0.isEmpty && attendeesText.contains($0) }.count
                if overlap > 0 {
                    score += min(0.15, Double(overlap) * 0.05)
                }
            }
            scored.append((candidate, score))
        }

        let best = scored.max(by: { $0.1 < $1.1 })
        guard let (candidate, score) = best, score >= fuzzyThreshold else { return nil }
        return candidate.toSummary()
    }

    // MARK: - Notion queries

    private func queryBriefs(in range: ClosedRange<Date>) async -> [BriefCandidateSummary] {
        guard let token = apiToken else {
            lastError = "Missing Notion token"
            return []
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let body: [String: Any] = [
            "filter": [
                "and": [
                    [
                        "property": "Date & Time",
                        "date": ["on_or_after": iso.string(from: range.lowerBound)],
                    ],
                    [
                        "property": "Date & Time",
                        "date": ["on_or_before": iso.string(from: range.upperBound)],
                    ],
                ]
            ],
            "sorts": [
                ["property": "Date & Time", "direction": "descending"]
            ],
            "page_size": 50,
        ]

        guard let url = URL(string: "https://api.notion.com/v1/databases/\(databaseID)/query") else {
            lastError = "Invalid database ID"
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Invalid response from Notion"
                return []
            }
            guard http.statusCode == 200 else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                lastError = "Notion HTTP \(http.statusCode)\(detail.isEmpty ? "" : " — \(detail.prefix(200))")"
                return []
            }
            return Self.parseQueryResults(data: data)
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    /// Public: list the last N days of briefs for the manual picker.
    func listRecentBriefs(daysBack: Int = 30) async -> [BriefSummary] {
        let end = Date()
        let start = end.addingTimeInterval(-Double(daysBack) * 86400)
        isSearching = true
        defer { isSearching = false }
        let candidates = await queryBriefs(in: start...end)
        return candidates.map { $0.toSummary() }
    }

    // MARK: - Page fetch + markdown

    /// Fetch the full page: metadata (via `/pages/{id}`) + body markdown
    /// (via `/blocks/{id}/children` walked recursively).
    func fetchBrief(pageID: String) async -> PreCallBrief? {
        guard let token = apiToken else {
            lastError = "Missing Notion token"
            return nil
        }

        async let metaTask = fetchPageMeta(pageID: pageID, token: token)
        async let markdownTask = fetchBlocksAsMarkdown(pageID: pageID, token: token, depth: 0)
        let meta = await metaTask
        let markdown = await markdownTask

        guard let meta else { return nil }
        return PreCallBrief(
            pageID: pageID,
            pageURL: meta.pageURL,
            title: meta.title,
            customerPartner: meta.customerPartner,
            date: meta.date,
            attendees: meta.attendees,
            briefingStatus: meta.briefingStatus,
            markdown: markdown
        )
    }

    private struct PageMeta {
        let pageURL: URL
        let title: String
        let customerPartner: String?
        let date: Date?
        let attendees: String?
        let briefingStatus: String?
    }

    private func fetchPageMeta(pageID: String, token: String) async -> PageMeta? {
        guard let url = URL(string: "https://api.notion.com/v1/pages/\(pageID)") else { return nil }
        var request = URLRequest(url: url)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let pageURL = (json["url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://notion.so")!
            let props = json["properties"] as? [String: Any] ?? [:]

            let title = Self.titleFromProperty(props["Meeting Title"]) ?? "Untitled"
            let customerPartner = Self.selectNameFromProperty(props["Customer / Partner"])
            let attendees = Self.richTextFromProperty(props["Attendees"])
            let briefingStatus = Self.selectNameFromProperty(props["Briefing Status"])
            let date = Self.dateStartFromProperty(props["Date & Time"])

            return PageMeta(
                pageURL: pageURL,
                title: title,
                customerPartner: customerPartner,
                date: date,
                attendees: attendees,
                briefingStatus: briefingStatus
            )
        } catch {
            return nil
        }
    }

    /// Walk the blocks tree and build a markdown document.
    /// Recurses into children up to a small depth limit to bound request fan-out.
    private func fetchBlocksAsMarkdown(pageID: String, token: String, depth: Int) async -> String {
        guard depth < 3 else { return "" }
        guard let url = URL(string: "https://api.notion.com/v1/blocks/\(pageID)/children?page_size=100") else { return "" }
        var request = URLRequest(url: url)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return ""
            }

            var out = ""
            var pendingNumberedIndex = 1
            var inNumbered = false
            for block in results {
                let type = block["type"] as? String ?? ""
                // Reset numbered list counter when leaving consecutive numbered items
                if type != "numbered_list_item" {
                    pendingNumberedIndex = 1
                    inNumbered = false
                }

                switch type {
                case "paragraph":
                    out += renderRichText(in: block, key: "paragraph") + "\n\n"
                case "heading_1":
                    out += "# " + renderRichText(in: block, key: "heading_1") + "\n\n"
                case "heading_2":
                    out += "## " + renderRichText(in: block, key: "heading_2") + "\n\n"
                case "heading_3":
                    out += "### " + renderRichText(in: block, key: "heading_3") + "\n\n"
                case "bulleted_list_item":
                    out += "- " + renderRichText(in: block, key: "bulleted_list_item") + "\n"
                case "numbered_list_item":
                    if !inNumbered { pendingNumberedIndex = 1; inNumbered = true }
                    out += "\(pendingNumberedIndex). " + renderRichText(in: block, key: "numbered_list_item") + "\n"
                    pendingNumberedIndex += 1
                case "to_do":
                    let checked = ((block["to_do"] as? [String: Any])?["checked"] as? Bool) ?? false
                    out += (checked ? "- [x] " : "- [ ] ") + renderRichText(in: block, key: "to_do") + "\n"
                case "quote":
                    out += "> " + renderRichText(in: block, key: "quote") + "\n\n"
                case "callout":
                    let text = renderRichText(in: block, key: "callout")
                    out += "> 💡 " + text + "\n\n"
                case "toggle":
                    let summary = renderRichText(in: block, key: "toggle")
                    out += "**▸ " + summary + "**\n"
                    if let id = block["id"] as? String,
                       (block["has_children"] as? Bool) == true {
                        let child = await fetchBlocksAsMarkdown(pageID: id, token: token, depth: depth + 1)
                        let indented = child.split(separator: "\n", omittingEmptySubsequences: false)
                            .map { "  " + $0 }
                            .joined(separator: "\n")
                        out += indented + "\n\n"
                    }
                case "divider":
                    out += "---\n\n"
                case "code":
                    let text = renderRichText(in: block, key: "code")
                    let lang = ((block["code"] as? [String: Any])?["language"] as? String) ?? ""
                    out += "```\(lang)\n\(text)\n```\n\n"
                case "bookmark":
                    if let urlStr = (block["bookmark"] as? [String: Any])?["url"] as? String {
                        out += "[\(urlStr)](\(urlStr))\n\n"
                    }
                default:
                    // Unsupported block types are skipped silently — the "Open in Notion"
                    // button covers the edge cases.
                    break
                }

                // Recurse into bulleted/numbered/to-do item children (nested lists)
                if (block["has_children"] as? Bool) == true,
                   ["bulleted_list_item", "numbered_list_item", "to_do"].contains(type),
                   let id = block["id"] as? String {
                    let child = await fetchBlocksAsMarkdown(pageID: id, token: token, depth: depth + 1)
                    let indented = child.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "  " + $0 }
                        .joined(separator: "\n")
                    out += indented
                }
            }
            return out
        } catch {
            return ""
        }
    }

    // MARK: - Rich text helpers

    private func renderRichText(in block: [String: Any], key: String) -> String {
        guard let inner = block[key] as? [String: Any],
              let rt = inner["rich_text"] as? [[String: Any]] else { return "" }
        return rt.compactMap { ($0["plain_text"] as? String) }.joined()
    }

    // MARK: - Property parsing helpers

    private static func titleFromProperty(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let items = dict["title"] as? [[String: Any]] else { return nil }
        let joined = items.compactMap { $0["plain_text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }

    private static func richTextFromProperty(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let items = dict["rich_text"] as? [[String: Any]] else { return nil }
        let joined = items.compactMap { $0["plain_text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }

    private static func selectNameFromProperty(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let sel = dict["select"] as? [String: Any] else { return nil }
        return sel["name"] as? String
    }

    private static func dateStartFromProperty(_ any: Any?) -> Date? {
        guard let dict = any as? [String: Any],
              let date = dict["date"] as? [String: Any],
              let start = date["start"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: start) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: start) { return d }
        // Date-only (YYYY-MM-DD)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: start)
    }

    // MARK: - Query result parsing

    /// Intermediate struct used by `queryBriefs` to retain the Attendees text
    /// alongside the summary so `bestMatch` can score tiebreakers without
    /// making a second fetch per candidate.
    struct BriefCandidateSummary {
        let pageID: String
        let pageURL: URL
        let title: String
        let customerPartner: String?
        let date: Date?
        let attendeesText: String?

        func toSummary() -> BriefSummary {
            BriefSummary(
                pageID: pageID,
                pageURL: pageURL,
                title: title,
                customerPartner: customerPartner,
                date: date
            )
        }
    }

    private static func parseQueryResults(data: Data) -> [BriefCandidateSummary] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result in
            guard let id = result["id"] as? String,
                  let urlStr = result["url"] as? String,
                  let pageURL = URL(string: urlStr) else { return nil }
            let props = result["properties"] as? [String: Any] ?? [:]
            let title = titleFromProperty(props["Meeting Title"]) ?? "Untitled"
            let cp = selectNameFromProperty(props["Customer / Partner"])
            let date = dateStartFromProperty(props["Date & Time"])
            let attendees = richTextFromProperty(props["Attendees"])
            return BriefCandidateSummary(
                pageID: id,
                pageURL: pageURL,
                title: title,
                customerPartner: cp,
                date: date,
                attendeesText: attendees
            )
        }
    }

    // MARK: - Similarity

    /// Normalised Levenshtein similarity in [0, 1].
    /// 1.0 = identical strings, 0.0 = completely different.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let d = levenshtein(a, b)
        let maxLen = Double(max(a.count, b.count))
        return 1.0 - (Double(d) / maxLen)
    }

    private static func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    curr[j - 1] + 1,
                    prev[j] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
