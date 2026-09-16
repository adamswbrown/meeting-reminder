import Foundation

/// Slack + Todoist delivery for app-owned fallback briefings.
///
/// The main path delivers from inside the private skill, which is unreachable
/// when the provider is exhausted — that is precisely when the fallback runs. So
/// the app performs the same two deliveries itself, against the same channel,
/// project and `#AI-XXXXXX` join key, using the tokens the headless skill
/// already stores in the Keychain.
///
/// Everything here must be safe to run twice. Recovery re-enters this code after
/// a crash, and enrichment re-enters it deliberately, so:
/// - Slack is posted **once** per occurrence. The recorded `ts` is the idempotency
///   key; the enrichment update goes into that message's thread rather than as a
///   new top-level post, so it can never read as a second new-meeting alert.
/// - Todoist creates are guarded by both the caller's ledger and a live query for
///   the `#AI` key, and carry `X-Request-Id` so a retried POST is collapsed
///   server-side. Nothing here ever completes, reschedules or deletes a task —
///   Co Work owns backlog reconciliation and the user owns their checkboxes.
struct BriefingDeliveryRecord: Codable, Equatable {
    /// Slack message timestamp. Non-nil means "already announced; never repost".
    var slackTS: String?
    /// `#AI-XXXXXX` → Todoist task id, for everything this app created.
    var todoistTaskIDs: [String: String] = [:]
    /// Non-fatal delivery problems, surfaced in the UI and the Notion coverage line.
    var errors: [String] = []
}

protocol BriefingHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
extension URLSession: BriefingHTTPClient {}

struct BriefingDeliveryService {
    /// #daily-breifings in the Askadam workspace — the same channel both briefing
    /// runners post to. The misspelling is the real channel name.
    static let slackChannel = "C0BMEG01M1N"
    static let todoistProjectName = "Daily Briefing"
    static let slackTokenKey = "slackBotToken"
    static let todoistTokenKey = "todoistApiToken"

    var http: BriefingHTTPClient = URLSession.shared
    var slackToken: () -> String? = { KeychainHelper.read(key: BriefingDeliveryService.slackTokenKey) }
    var todoistToken: () -> String? = { KeychainHelper.read(key: BriefingDeliveryService.todoistTokenKey) }

    // MARK: - Slack

    /// Posts the new-briefing alert, once. Returns the record unchanged if it has
    /// already been announced, so a retried job cannot double-post.
    func announce(job: BriefingFallbackJob, context: BriefingContext,
                  record: BriefingDeliveryRecord) async -> BriefingDeliveryRecord {
        var record = record
        guard record.slackTS == nil else { return record }
        guard let token = slackToken(), !token.isEmpty else {
            record.errors.append("Slack bot token missing; briefing saved to Notion but not announced.")
            return record
        }
        let text = Self.alertText(job: job, context: context)
        do {
            let response = try await postSlack(token: token, body: [
                "channel": Self.slackChannel, "text": text,
                "unfurl_links": false, "unfurl_media": false])
            guard response["ok"] as? Bool == true, let ts = response["ts"] as? String else {
                record.errors.append("Slack rejected the post: \(response["error"] as? String ?? "unknown error").")
                return record
            }
            record.slackTS = ts
        } catch {
            // Deliberately not the raw error: it can carry the token-bearing request.
            record.errors.append("Slack post failed; the briefing is still in Notion.")
        }
        return record
    }

    /// Threaded follow-up once the main model has enriched the page. Silently does
    /// nothing if the original alert never went out — a reply with no parent would
    /// surface as a new top-level alert for an already-briefed meeting.
    func announceEnrichment(job: BriefingFallbackJob, record: BriefingDeliveryRecord) async -> BriefingDeliveryRecord {
        var record = record
        guard let ts = record.slackTS, let token = slackToken(), !token.isEmpty else { return record }
        let text = "✅ Full briefing ready — Claude has enriched the fallback for “\(job.meeting.title)”."
            + (job.pageURL.map { "\n\($0)" } ?? "")
        do {
            let response = try await postSlack(token: token, body: [
                "channel": Self.slackChannel, "text": text, "thread_ts": ts,
                "unfurl_links": false, "unfurl_media": false])
            if response["ok"] as? Bool != true {
                record.errors.append("Slack enrichment reply failed: \(response["error"] as? String ?? "unknown error").")
            }
        } catch {
            record.errors.append("Slack enrichment reply failed.")
        }
        return record
    }

    private func postSlack(token: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://slack.com/api/chat.postMessage")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let (data, _) = try await http.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Template C shape, trimmed to this one meeting and labelled as a fallback so
    /// the reader knows the summary is Apple-model output awaiting enrichment.
    static func alertText(job: BriefingFallbackJob, context: BriefingContext) -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        time.timeZone = TimeZone(identifier: "Europe/London")
        let metadata = context.metadata
        var lines = ["📬 Fallback briefing — 1 new meeting (\(job.provider ?? "Apple Intelligence"))", ""]
        let partner = metadata?.partner.map { " (\($0))" } ?? ""
        lines.append("🆕 \(time.string(from: job.meeting.startDate)) — \(job.meeting.title)\(partner)")
        if metadata?.isKeyMeeting == true { lines.append("   🔬 Google Colab — Key Meeting.") }
        // One prep cue for this meeting. Splitting on "." to take the first sentence
        // looks right until the summary says "Dr. Migrate" and the cue truncates to
        // "regarding the Dr." — abbreviations make sentence-splitting a trap. Take a
        // word-bounded prefix instead: slightly longer, never mangled.
        if let summary = job.draft?.summary, !summary.isEmpty {
            lines.append("   " + Self.cue(from: summary))
        } else if !context.evidence.contains(where: { $0.id.hasPrefix("notes") }) {
            lines.append("   No prior meeting notes found — treat history as unknown.")
        }
        if let open = metadata?.openActions, !open.isEmpty {
            lines.append("")
            lines.append("⚠️ OPEN ACTION ITEMS")
            lines += open.prefix(5).map { "• \($0.text) (\($0.actionID))" }
        }
        if let url = job.pageURL { lines += ["", "📂 \(url)"] }
        lines += ["", "_Generated without the main model; it will be enriched automatically when access returns._"]
        return lines.joined(separator: "\n")
    }

    /// A single-line cue: the summary, trimmed to a whole word near `limit` and
    /// ellipsised only if it actually had to cut.
    static func cue(from summary: String, limit: Int = 180) -> String {
        let flat = summary.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        let clipped = String(flat.prefix(limit))
        guard let lastSpace = clipped.lastIndex(of: " ") else { return clipped + "…" }
        return clipped[clipped.startIndex..<lastSpace]
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-")) + "…"
    }

    // MARK: - Todoist

    /// Creates a task for each open action carried forward, skipping any whose
    /// `#AI` key is already present in the project or in our own ledger.
    ///
    /// Only carried-forward `- [ ]` items become tasks. The model's "suggested
    /// preparation" is explicitly not agreed work and must never be assigned.
    func syncActions(job: BriefingFallbackJob, context: BriefingContext,
                     record: BriefingDeliveryRecord) async -> BriefingDeliveryRecord {
        var record = record
        let open = context.metadata?.openActions ?? []
        let outstanding = open.filter { record.todoistTaskIDs[$0.actionID] == nil }
        guard !outstanding.isEmpty else { return record }
        guard let token = todoistToken(), !token.isEmpty else {
            record.errors.append("Todoist token missing; action items not synced.")
            return record
        }
        do {
            guard let projectID = try await todoistProjectID(token: token) else {
                record.errors.append("Todoist project “\(Self.todoistProjectName)” not found; action items not synced.")
                return record
            }
            // A live check as well as the ledger: Co Work may have created the same
            // task from the same prior brief before the fallback ever ran.
            let existing = try await todoistExistingActionIDs(token: token, projectID: projectID)
            for action in outstanding where !existing.contains(action.actionID) {
                if let id = try await createTodoistTask(token: token, projectID: projectID,
                                                        action: action, job: job, context: context) {
                    record.todoistTaskIDs[action.actionID] = id
                }
            }
        } catch {
            record.errors.append("Todoist unreachable; action items not synced this run.")
        }
        return record
    }

    private func todoistProjectID(token: String) async throws -> String? {
        let response = try await todoist(token: token, path: "/projects")
        // v1 list responses are paginated and wrapped — a bare array is v2, which
        // is gone (HTTP 410). Reading the wrong shape silently yields no project.
        let projects = response["results"] as? [[String: Any]] ?? []
        return projects.first { $0["name"] as? String == Self.todoistProjectName }?["id"] as? String
    }

    private func todoistExistingActionIDs(token: String, projectID: String) async throws -> Set<String> {
        let response = try await todoist(token: token, path: "/tasks?project_id=\(projectID)")
        let tasks = response["results"] as? [[String: Any]] ?? []
        return Set(tasks.compactMap { task -> String? in
            let description = task["description"] as? String ?? ""
            guard let range = description.range(of: #"#AI-[0-9a-f]{6}"#, options: .regularExpression) else { return nil }
            return String(description[range])
        })
    }

    private func createTodoistTask(token: String, projectID: String, action: BriefingOpenAction,
                                   job: BriefingFallbackJob, context: BriefingContext) async throws -> String? {
        let partner = context.metadata?.partner
        var request = URLRequest(url: URL(string: "https://api.todoist.com/api/v1/tasks")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Collapses a retried POST server-side if the response was lost in flight.
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "content": partner.map { "[\($0)] \(action.text)" } ?? action.text,
            // Co Work's reconciliation parses this description for the join key.
            "description": [partner.map { "Partner: \($0)" }, job.pageURL.map { "Briefing: \($0)" },
                            "ID: \(action.actionID)"].compactMap { $0 }.joined(separator: "\n"),
            "project_id": projectID,
            "due_string": "today",
        ])
        let (data, response) = try await http.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
    }

    private func todoist(token: String, path: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.todoist.com/api/v1\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, _) = try await http.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
