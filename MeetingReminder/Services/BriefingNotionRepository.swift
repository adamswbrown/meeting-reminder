import Foundation

protocol BriefingNotionTransport {
    func get(path: String) async throws -> [String: Any]
    func post(path: String, body: [String: Any]) async throws -> [String: Any]
    func patch(path: String, body: [String: Any]) async throws -> [String: Any]
}
extension CalendarSyncNotionClient: BriefingNotionTransport {}

struct BriefingNotionPage {
    var id: String
    var url: String
}

struct BriefingNotionRepository {
    let client: any BriefingNotionTransport

    static func live(logPath: String) throws -> Self {
        guard let token = KeychainHelper.read(key: CalendarSyncConstants.tokenKeychainKey), !token.isEmpty else {
            throw BriefingFallbackError.unavailable("Notion integration token is missing.")
        }
        return Self(client: CalendarSyncNotionClient(token: token, logger: CalendarSyncLogger(path: logPath),
                                                    retryWrites: false))
    }

    func shouldSkip(_ meeting: MeetingEvent) async throws -> Bool {
        let rows = try await queryAll(CalendarSyncConstants.skipListDataSourceID, body: [:])
        return rows.contains { row in
            let properties = row["properties"] as? [String: Any] ?? [:]
            guard (properties["Active"] as? [String: Any])?["checkbox"] as? Bool != false,
                  let titleParts = (properties["Meeting Title"] as? [String: Any])?["title"] as? [[String: Any]] else { return false }
            let title = titleParts.map { $0["plain_text"] as? String ?? (($0["text"] as? [String: Any])?["content"] as? String ?? "") }.joined()
            guard !title.isEmpty else { return false }
            let type = ((properties["Match Type"] as? [String: Any])?["select"] as? [String: Any])?["name"] as? String
            let lhs = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rhs = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return type == "Title Contains" ? lhs.contains(rhs) : lhs == rhs
        }
    }

    func context(for meeting: MeetingEvent) async -> BriefingContext {
        var context = BriefingContext(meeting: meeting, evidence: [],
            coverage: ["Calendar: EventKit snapshot; attendee email coverage may be incomplete."])
        if let notes = meeting.notes, !notes.isEmpty {
            context.evidence.append(.init(id: "invite", source: "Meeting invitation", text: String(notes.prefix(6000))))
            if notes.count > 6000 { context.coverage.append("Invitation truncated at 6000 characters.") }
        }
        do {
            let before = min(meeting.startDate, Date())
            let query: [String: Any] = ["page_size": 3,
                "sorts": [["property": CalendarSyncConstants.meetingNotesDateProperty, "direction": "descending"]],
                "filter": ["and": [
                    ["property": CalendarSyncConstants.meetingNotesTitleProperty, "title": ["contains": meeting.title]],
                    ["property": CalendarSyncConstants.meetingNotesDateProperty, "date": ["before": Self.iso(before)]],
                    ["property": CalendarSyncConstants.meetingNotesDateProperty, "date": ["on_or_after": Self.iso(before.addingTimeInterval(-90 * 86400))]]]]]
            let response = try await client.post(path: "/data_sources/\(CalendarSyncConstants.meetingNotesDataSourceID)/query", body: query)
            let rows = response["results"] as? [[String: Any]] ?? []
            context.coverage.append(rows.isEmpty ? "Notion notes: no title matches in the previous 90 days."
                : "Notion notes: most recent \(rows.count) title matches in 90 days; customer/domain matching is not available in this fallback.")
            if response["has_more"] as? Bool == true { context.coverage.append("Older matching notes omitted.") }
            for (index, row) in rows.enumerated() {
                guard let id = row["id"] as? String else { continue }
                let text = try await pageText(id, maxCharacters: 8000)
                context.evidence.append(.init(id: "notes-\(index + 1)", source: "Prior meeting notes (\(id))",
                    text: text, url: row["url"] as? String ?? "https://www.notion.so/\(id.replacingOccurrences(of: "-", with: ""))"))
            }
        } catch { context.coverage.append("Notion prior notes unavailable or incomplete; do not infer no prior actions.") }
        return context
    }

    func matchingPage(_ meeting: MeetingEvent) async throws -> BriefingNotionPage? {
        let rows = try await queryAll(CalendarSyncConstants.preCallBriefingsDataSourceID, body: ["filter": ["and": [
            ["property": CalendarSyncConstants.preCallBriefingsTitleProperty, "title": ["equals": meeting.title]],
            ["property": CalendarSyncConstants.preCallBriefingsDateProperty, "date": ["equals": Self.iso(meeting.startDate)]]]]])
        guard rows.count <= 1 else { throw BriefingFallbackError.ambiguousPage }
        guard let row = rows.first, let id = row["id"] as? String else { return nil }
        return Self.page(id: id, row: row)
    }

    func validatePage(_ id: String, meeting: MeetingEvent) async throws {
        let row = try await client.get(path: "/pages/\(id)")
        let properties = row["properties"] as? [String: Any] ?? [:]
        guard row["archived"] as? Bool != true, row["in_trash"] as? Bool != true,
              let start = NotionPriorNotesReader.startDate(properties[CalendarSyncConstants.preCallBriefingsDateProperty]),
              abs(start.timeIntervalSince(meeting.startDate)) < 1 else {
            throw BriefingFallbackError.unavailable("Briefing page is archived or the meeting time changed; review required.")
        }
        let outcome = ((properties["Meeting Outcome"] as? [String: Any])?["select"] as? [String: Any])?["name"] as? String
        if outcome == "Cancelled" { throw BriefingFallbackError.unavailable("Meeting was cancelled.") }
    }

    func hasMarker(_ marker: String, pageID: String) async throws -> Bool {
        let blocks = try await children(pageID)
        return blocks.contains { Self.blockText($0) == marker }
    }

    func saveFallback(_ job: BriefingFallbackJob) async throws -> BriefingNotionPage {
        guard let draft = job.draft, let context = job.context else { throw BriefingFallbackError.invalidOutput }
        let section = Self.section(marker: job.fallbackMarker, heading: "Fallback briefing — \(job.provider ?? "Apple Intelligence")",
                                   draft: draft, context: context)
        // Reconcile the normal runner's possible partial write before creating a page.
        if let existing = try await matchingPage(job.meeting) {
            try await validatePage(existing.id, meeting: job.meeting)
            if try await !hasMarker(job.fallbackMarker, pageID: existing.id) {
                _ = try await client.patch(path: "/blocks/\(existing.id)/children", body: ["children": [section]])
            }
            return existing
        }
        let properties: [String: Any] = [
            CalendarSyncConstants.preCallBriefingsTitleProperty: ["title": Self.rich(job.meeting.title)],
            CalendarSyncConstants.preCallBriefingsDateProperty: ["date": ["start": Self.iso(job.meeting.startDate)]],
            "Briefing Status": ["select": ["name": "Auto"]],
            "Attendees": ["rich_text": Self.rich((job.meeting.attendees ?? []).joined(separator: ", "))]]
        let response = try await client.post(path: "/pages", body: [
            "parent": ["type": "data_source_id", "data_source_id": CalendarSyncConstants.preCallBriefingsDataSourceID],
            "properties": properties, "children": [section]])
        guard let id = response["id"] as? String else { throw BriefingFallbackError.uncertainWrite }
        return Self.page(id: id, row: response)
    }

    func enrich(_ job: BriefingFallbackJob, draft: BriefingDraft, context: BriefingContext) async throws {
        guard let pageID = job.pageID else { throw BriefingFallbackError.uncertainWrite }
        try await validatePage(pageID, meeting: job.meeting)
        guard try await !hasMarker(job.enrichmentMarker, pageID: pageID) else { return }
        // One atomic append. Never replace/delete blocks, properties, checkboxes or relations.
        _ = try await client.patch(path: "/blocks/\(pageID)/children", body: ["children": [
            Self.section(marker: job.enrichmentMarker, heading: "Claude enrichment — \(Self.iso(Date()))",
                         draft: draft, context: context)]])
    }

    func pageText(_ pageID: String, maxCharacters: Int) async throws -> String {
        var remaining = maxCharacters
        var pieces: [String] = []
        var readBudget = 8
        func walk(_ id: String, depth: Int) async throws {
            guard remaining > 0, depth <= 2 else { return }
            guard readBudget > 0 else { pieces.append("[additional blocks omitted]"); return }
            readBudget -= 1
            let response = try await client.get(path: "/blocks/\(id)/children?page_size=100")
            if response["has_more"] as? Bool == true { pieces.append("[additional blocks omitted]") }
            for block in response["results"] as? [[String: Any]] ?? [] {
                guard remaining > 0 else { break }
                let text = String(Self.blockText(block).prefix(remaining))
                pieces.append(text); remaining -= text.count
                if block["has_children"] as? Bool == true, let childID = block["id"] as? String {
                    if depth < 2 { try await walk(childID, depth: depth + 1) }
                    else { pieces.append("[deeper blocks omitted]") }
                }
            }
        }
        try await walk(pageID, depth: 0)
        if remaining <= 0 { pieces.append("[truncated]") }
        return pieces.joined(separator: "\n")
    }

    private func children(_ id: String) async throws -> [[String: Any]] {
        var result: [[String: Any]] = [], cursor: String?
        for _ in 0..<10 {
            let response = try await client.get(path: "/blocks/\(id)/children?page_size=100\(cursor.map { "&start_cursor=\($0)" } ?? "")")
            result += response["results"] as? [[String: Any]] ?? []
            guard response["has_more"] as? Bool == true else { return result }
            guard let next = response["next_cursor"] as? String else { break }
            cursor = next
        }
        throw BriefingFallbackError.unavailable("Notion page exceeds the bounded read limit.")
    }

    private func queryAll(_ dataSource: String, body: [String: Any]) async throws -> [[String: Any]] {
        var results: [[String: Any]] = [], query = body
        query["page_size"] = 100
        for _ in 0..<10 {
            let response = try await client.post(path: "/data_sources/\(dataSource)/query", body: query)
            results += response["results"] as? [[String: Any]] ?? []
            guard response["has_more"] as? Bool == true else { return results }
            guard let next = response["next_cursor"] as? String else { break }
            query["start_cursor"] = next
        }
        throw BriefingFallbackError.unavailable("Notion query incomplete; refusing to infer absence.")
    }

    static func section(marker: String, heading: String, draft: BriefingDraft, context: BriefingContext) -> [String: Any] {
        var blocks = [block("paragraph", heading), block("paragraph", draft.summary),
                      block("paragraph", "Suggested preparation (not assigned tasks)")]
        blocks += draft.preparation.map { block("bulleted_list_item", $0) }
        blocks.append(block("paragraph", "Source coverage: " + context.coverage.joined(separator: " ")))
        blocks += context.evidence.map { block("paragraph", "[\($0.id)] \($0.source)\($0.url.map { " — \($0)" } ?? "")") }
        return ["object": "block", "type": "toggle", "toggle": ["rich_text": rich(marker), "children": blocks]]
    }
    private static func block(_ type: String, _ text: String) -> [String: Any] {
        ["object": "block", "type": type, type: ["rich_text": rich(text)]]
    }
    static func rich(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": ["content": String(text.prefix(1900))]]]
    }
    static func blockText(_ block: [String: Any]) -> String {
        guard let type = block["type"] as? String,
              let payload = block[type] as? [String: Any], let rich = payload["rich_text"] as? [[String: Any]] else { return "" }
        return rich.map { $0["plain_text"] as? String ?? (($0["text"] as? [String: Any])?["content"] as? String ?? "") }.joined()
    }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func page(id: String, row: [String: Any]) -> BriefingNotionPage {
        .init(id: id, url: row["url"] as? String ?? "https://www.notion.so/\(id.replacingOccurrences(of: "-", with: ""))")
    }
}
