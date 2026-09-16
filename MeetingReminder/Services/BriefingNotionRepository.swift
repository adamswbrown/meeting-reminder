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
            guard (properties["Active"] as? [String: Any])?["checkbox"] as? Bool != false else { return false }
            let title = Self.propertyText(properties["Meeting Title"])
            guard !title.isEmpty else { return false }
            let type = Self.propertyText(properties["Match Type"])
            let lhs = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rhs = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return type == "Title Contains" ? lhs.contains(rhs) : lhs == rhs
        }
    }

    /// Reads the shared Customer / Partner mapping rules. Read-only: the fallback
    /// classifies against these but never proposes or edits a rule (the skill's
    /// Step 8B Suggestions write is not implemented on this path).
    func mappingRules() async throws -> BriefingMappingRuleSet {
        let rows = try await queryAll(CalendarSyncConstants.mappingRulesDataSourceID, body: [:])
        var set = BriefingMappingRuleSet(rowsSeen: rows.count)
        set.rules = rows.compactMap { row in
            let properties = row["properties"] as? [String: Any] ?? [:]
            let value = Self.propertyText(properties["Match Value"])
            let partner = Self.propertyText(properties["Customer / Partner"])
            guard !value.isEmpty, !partner.isEmpty,
                  let type = BriefingMappingRule.MatchType(rawValue: Self.propertyText(properties["Match Type"]))
            else { return nil }
            return BriefingMappingRule(
                matchValue: value, matchType: type, customerPartner: partner,
                isPartner: (properties["Is Partner"] as? [String: Any])?["checkbox"] as? Bool ?? false,
                // An absent Active checkbox means the column is missing, not that
                // the rule is off — treat it as live, matching the skill.
                active: (properties["Active"] as? [String: Any])?["checkbox"] as? Bool ?? true)
        }
        return set
    }

    /// Full-depth retrieval: classify the meeting, then target prior history at the
    /// resolved partner rather than the meeting title alone. Mirrors the skill's
    /// Step 4 (ladder), Step 6 (history ladder + prior briefs) and the `#AI-XXXXXX`
    /// carry-forward, so a fallback briefing joins the same rows the main runner
    /// would have used. Every source is individually fault-tolerant: a failure
    /// degrades to a coverage note, never an empty briefing.
    func context(for meeting: MeetingEvent) async -> BriefingContext {
        var context = BriefingContext(meeting: meeting, evidence: [],
            coverage: ["Calendar: EventKit snapshot; attendee email coverage may be incomplete."])
        var metadata = BriefingMetadata()

        var ruleSet = BriefingMappingRuleSet()
        do { ruleSet = try await mappingRules() }
        catch { context.coverage.append("Mapping Rules unavailable; partner resolved without them.") }
        // Rows that all fail to parse mean a column type changed under us. Without
        // this the ladder degrades to the convener fallback and looks merely
        // unlucky rather than broken.
        if ruleSet.looksBroken {
            context.coverage.append("Mapping Rules returned \(ruleSet.rowsSeen) rows but none parsed — the schema may have changed; partner resolution is running blind.")
        }
        let resolution = BriefingPartnerResolver.resolve(
            attendees: meeting.attendees ?? [], title: meeting.title, rules: ruleSet.rules)
        metadata.partner = resolution.partner
        metadata.partnerByInference = resolution.byInference
        metadata.isKeyMeeting = resolution.isGoogleColab
        metadata.stage = BriefingPartnerResolver.stage(forTitle: meeting.title)
        context.coverage.append("Customer / Partner: \(resolution.rationale)")
        if resolution.byInference {
            context.coverage.append("Partner was inferred, not rule-matched; consider adding a Mapping Rule.")
        }
        if resolution.isGoogleColab { context.coverage.append("Google Colab attendee present — treat as a Key Meeting.") }

        if let notes = meeting.notes, !notes.isEmpty {
            context.evidence.append(.init(id: "invite", source: "Meeting invitation", text: String(notes.prefix(6000))))
            if notes.count > 6000 { context.coverage.append("Invitation truncated at 6000 characters.") }
        }
        if let link = meeting.videoLink?.absoluteString {
            context.evidence.append(.init(id: "join-link", source: "Meeting join link", text: link, url: link))
        }

        // Step 6 history ladder — stop at the first filter that returns anything.
        let before = min(meeting.startDate, Date())
        let window = Self.iso(before.addingTimeInterval(-90 * 86400))
        var priorRows: [[String: Any]] = []
        var usedFilter = "none"
        var ladder: [(String, [String: Any])] = []
        if let partner = resolution.partner {
            ladder.append(("partner title match", ["property": CalendarSyncConstants.meetingNotesTitleProperty,
                                                   "title": ["contains": partner]]))
        }
        for domain in resolution.partnerDomains {
            ladder.append(("partner domain match (\(domain))",
                           ["property": "Attendees Email", "rich_text": ["contains": domain]]))
        }
        // Only worth trying if it is not already covered above: on a convened call
        // this is usually the convener's domain, not the partner's.
        if let domain = resolution.primaryDomain, !resolution.partnerDomains.contains(domain) {
            ladder.append(("most-frequent domain match (\(domain))",
                           ["property": "Attendees Email", "rich_text": ["contains": domain]]))
        }
        ladder.append(("meeting title match", ["property": CalendarSyncConstants.meetingNotesTitleProperty,
                                               "title": ["contains": meeting.title]]))
        for (label, filter) in ladder {
            do {
                let query: [String: Any] = ["page_size": 3,
                    "sorts": [["property": CalendarSyncConstants.meetingNotesDateProperty, "direction": "descending"]],
                    "filter": ["and": [filter,
                        ["property": CalendarSyncConstants.meetingNotesDateProperty, "date": ["before": Self.iso(before)]],
                        ["property": CalendarSyncConstants.meetingNotesDateProperty, "date": ["on_or_after": window]]]]]
                let response = try await client.post(
                    path: "/data_sources/\(CalendarSyncConstants.meetingNotesDataSourceID)/query", body: query)
                let rows = response["results"] as? [[String: Any]] ?? []
                if !rows.isEmpty { priorRows = rows; usedFilter = label; break }
            } catch {
                context.coverage.append("Notion notes (\(label)) query failed; do not infer no prior actions.")
            }
        }
        context.coverage.append(priorRows.isEmpty
            ? "Notion notes: no matches in the previous 90 days across partner, domain and title filters."
            : "Notion notes: \(priorRows.count) most recent via \(usedFilter), previous 90 days.")
        for (index, row) in priorRows.enumerated() {
            guard let id = row["id"] as? String else { continue }
            metadata.priorPageIDs.append(id)
            let properties = row["properties"] as? [String: Any] ?? [:]
            let status = Self.propertyText(properties["Status"])
            let text = (try? await pageText(id, maxCharacters: 8000)) ?? "[unreadable]"
            context.evidence.append(.init(
                id: "notes-\(index + 1)",
                source: "Prior meeting notes (\(status.isEmpty ? "status unknown" : status))",
                text: text,
                url: row["url"] as? String ?? "https://www.notion.so/\(id.replacingOccurrences(of: "-", with: ""))"))
        }

        // Prior briefings for the same partner — the source of open `- [ ]` items.
        if let partner = resolution.partner {
            do {
                let response = try await client.post(
                    path: "/data_sources/\(CalendarSyncConstants.preCallBriefingsDataSourceID)/query",
                    body: ["page_size": 3,
                           "sorts": [["property": CalendarSyncConstants.preCallBriefingsDateProperty, "direction": "descending"]],
                           "filter": ["and": [
                               ["property": "Customer / Partner", "select": ["equals": partner]],
                               ["property": CalendarSyncConstants.preCallBriefingsDateProperty,
                                "date": ["before": Self.iso(before)]]]]])
                let rows = response["results"] as? [[String: Any]] ?? []
                context.coverage.append("Prior briefings: \(rows.count) for \(partner).")
                var seen = Set<String>()
                for (index, row) in rows.enumerated() {
                    guard let id = row["id"] as? String else { continue }
                    let text = (try? await pageText(id, maxCharacters: 8000)) ?? ""
                    context.evidence.append(.init(id: "brief-\(index + 1)", source: "Prior pre-call briefing",
                        text: text, url: row["url"] as? String))
                    for item in BriefingPartnerResolver.openActionItems(in: text) where seen.insert(item.id).inserted {
                        metadata.openActions.append(.init(text: item.text, actionID: item.id))
                    }
                }
                if !metadata.openActions.isEmpty {
                    context.coverage.append("\(metadata.openActions.count) open action item(s) carried forward.")
                }
            } catch {
                context.coverage.append("Prior briefings unavailable; open actions may be incomplete.")
            }
        } else {
            context.coverage.append("No partner resolved; prior briefings and open actions were not retrieved.")
        }

        context.metadata = metadata
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
        let outcome = Self.propertyText(properties["Meeting Outcome"])
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
        var properties: [String: Any] = [
            CalendarSyncConstants.preCallBriefingsTitleProperty: ["title": Self.rich(job.meeting.title)],
            CalendarSyncConstants.preCallBriefingsDateProperty: ["date": ["start": Self.iso(job.meeting.startDate)]],
            "Briefing Status": ["select": ["name": "Auto"]],
            "Attendees": ["rich_text": Self.rich((job.meeting.attendees ?? []).joined(separator: ", "))]]
        // Step 7 metadata. Select values must already exist as options, so only
        // write ones the mapping rules themselves supplied; an inferred-but-unknown
        // partner would otherwise fail the whole create.
        if let metadata = context.metadata {
            if let partner = metadata.partner, !metadata.partnerByInference {
                properties["Customer / Partner"] = ["select": ["name": partner]]
            }
            if let stage = metadata.stage { properties["Stage"] = ["select": ["name": stage]] }
            if !metadata.priorPageIDs.isEmpty {
                properties["Prior Meetings"] = ["relation": metadata.priorPageIDs.map { ["id": $0] }]
            }
        }
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
                // Render a to_do as "- [ ] …" / "- [x] …". Without the marker and its
                // checked state, `BriefingPartnerResolver.openActionItems` can never
                // match a carried-forward item, and a completed item is
                // indistinguishable from an open one.
                var rendered = Self.blockText(block)
                if block["type"] as? String == "to_do" {
                    let checked = (block["to_do"] as? [String: Any])?["checked"] as? Bool ?? false
                    rendered = "- [\(checked ? "x" : " ")] " + rendered
                }
                let text = String(rendered.prefix(remaining))
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
        var blocks = [block("paragraph", heading)]
        if context.metadata?.isKeyMeeting == true {
            blocks.append(block("paragraph", "🔬 Google Colab — Key Meeting."))
        }
        blocks.append(block("paragraph", draft.summary))
        // Open items are carried forward verbatim with their existing #AI join key —
        // re-hashing here would mint a new ID and orphan the Todoist task.
        if let open = context.metadata?.openActions, !open.isEmpty {
            blocks.append(block("paragraph", "Action Items (from last call)"))
            blocks += open.map { block("to_do", "\($0.text) (\($0.actionID))") }
        }
        blocks.append(block("paragraph", "Suggested preparation (not assigned tasks)"))
        blocks += draft.preparation.map { block("bulleted_list_item", $0) }
        blocks.append(block("paragraph", "Source coverage: " + context.coverage.joined(separator: " ")))
        blocks += context.evidence.map { block("paragraph", "[\($0.id)] \($0.source)\($0.url.map { " — \($0)" } ?? "")") }
        return ["object": "block", "type": "toggle", "toggle": ["rich_text": rich(marker), "children": blocks]]
    }
    private static func block(_ type: String, _ text: String) -> [String: Any] {
        var payload: [String: Any] = ["rich_text": rich(text)]
        // A carried-forward action is by definition still open.
        if type == "to_do" { payload["checked"] = false }
        return ["object": "block", "type": type, type: payload]
    }
    static func rich(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": ["content": String(text.prefix(1900))]]]
    }
    /// Reads a Notion property's text regardless of which property TYPE it is.
    ///
    /// These databases mix `select`, `status`, `rich_text` and `title` for fields
    /// that are conceptually the same string — Mapping Rules stores
    /// `Customer / Partner` as rich_text while Pre-Call Briefings stores it as a
    /// select, and Meeting Notes `Status` is Notion's `status` type, not a select.
    /// A reader that assumes one type fails **silently**, which is exactly how the
    /// mapping-rules ladder sat dead: every rule parsed to an empty partner and was
    /// dropped by its own validity guard. Handling all four is cheaper than being
    /// wrong, and cannot regress if a column's type is changed in Notion.
    static func propertyText(_ property: Any?) -> String {
        guard let property = property as? [String: Any] else { return "" }
        for key in ["select", "status"] {
            if let value = property[key] as? [String: Any], let name = value["name"] as? String { return name }
        }
        for key in ["rich_text", "title"] {
            if let parts = property[key] as? [[String: Any]] {
                return parts.map {
                    $0["plain_text"] as? String ?? (($0["text"] as? [String: Any])?["content"] as? String ?? "")
                }.joined()
            }
        }
        return ""
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
