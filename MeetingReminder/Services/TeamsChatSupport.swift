import Foundation

// MARK: - Models

/// One entry in the cached "who do I have a chat with" directory, keyed by the
/// other participant's email (lowercased). Built from `GET /me/chats?$expand=members`.
struct TeamsChatRef: Codable, Equatable {
    let chatID: String
    /// `oneOnOne`, `group`, or `meeting` (Graph `chatType`).
    let chatType: String
    let topic: String?
    let lastUpdated: Date?
}

/// Persisted directory: email → chats that person is a member of. Refreshed daily.
struct TeamsChatDirectory: Codable {
    var fetchedAt: Date
    var byEmail: [String: [TeamsChatRef]]

    static let maxAge: TimeInterval = 24 * 3600

    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > Self.maxAge }
}

/// A single chat message, HTML already stripped to plain text.
struct TeamsChatMessage: Equatable, Identifiable {
    let id: String
    let from: String
    let sentAt: Date
    let text: String
}

/// Recent chat context for one meeting attendee.
struct TeamsChatContext: Equatable, Identifiable {
    /// Attendee email for 1:1 context; empty for a topic-matched group/meeting chat.
    let email: String
    /// Person's name for 1:1 context, or the chat topic for group/meeting chats.
    let displayName: String
    let chatID: String
    let messages: [TeamsChatMessage]
    /// True when this came from a group/meeting chat whose topic matched the meeting.
    var isTopicMatch: Bool = false

    var id: String { chatID }
}

// MARK: - Pure helpers (no networking, no MainActor — unit-testable)

enum TeamsChatSupport {
    /// The app's own scope for chats. `Chat.ReadWrite` rather than the minimal
    /// `Chat.Read` because the altra.cloud tenant blocks *new* user consent on
    /// this client ("Need admin approval" for both `Chat.Read` and `Mail.Read`),
    /// while `Chat.ReadWrite` was already consented via an earlier Graph CLI
    /// sign-in — verified 2026-09-14 with `scripts/graph-scope-probe.py`. Entra
    /// matches consent per exact permission, so asking for `Chat.Read` is
    /// refused even though ReadWrite is granted. Only read endpoints are called.
    static let chatScope = "Chat.ReadWrite"

    /// True when an access token's `scp` claim allows reading chats.
    static func canReadChats(scopes: Set<String>) -> Bool {
        scopes.contains("Chat.Read") || scopes.contains("Chat.ReadWrite")
            || scopes.contains("Chat.Read.All") || scopes.contains("Chat.ReadWrite.All")
    }

    /// Decode the `scp` claim from a JWT access token without verifying it
    /// (we only use it to decide which features to attempt, never for auth).
    static func scopes(fromAccessToken token: String) -> Set<String> {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [] }
        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scp = json["scp"] as? String else { return [] }
        return Set(scp.split(separator: " ").map(String.init))
    }

    /// Build the email → chats directory from one or more pages of
    /// `GET /me/chats?$expand=members` results. `selfEmail` is excluded so a 1:1
    /// chat maps only to the other person.
    static func buildDirectory(chats: [[String: Any]], selfEmail: String?, now: Date = Date()) -> TeamsChatDirectory {
        var byEmail: [String: [TeamsChatRef]] = [:]
        let me = selfEmail?.lowercased()
        for chat in chats {
            guard let id = chat["id"] as? String else { continue }
            let type = (chat["chatType"] as? String) ?? "unknown"
            let topic = chat["topic"] as? String
            let updated = (chat["lastUpdatedDateTime"] as? String).flatMap(parseGraphDate)
            let ref = TeamsChatRef(chatID: id, chatType: type, topic: topic, lastUpdated: updated)
            for member in (chat["members"] as? [[String: Any]]) ?? [] {
                guard let email = (member["email"] as? String)?.lowercased(), !email.isEmpty, email != me else { continue }
                byEmail[email, default: []].append(ref)
            }
        }
        // Prefer 1:1 chats first, then most recently active.
        for key in byEmail.keys {
            byEmail[key]?.sort { a, b in
                if (a.chatType == "oneOnOne") != (b.chatType == "oneOnOne") { return a.chatType == "oneOnOne" }
                return (a.lastUpdated ?? .distantPast) > (b.lastUpdated ?? .distantPast)
            }
        }
        return TeamsChatDirectory(fetchedAt: now, byEmail: byEmail)
    }

    /// Parse the messages page from `GET /chats/{id}/messages`. Drops system
    /// events (`messageType != "message"`), deleted and empty messages.
    static func parseMessages(_ results: [[String: Any]]) -> [TeamsChatMessage] {
        results.compactMap { m in
            guard let id = m["id"] as? String,
                  (m["messageType"] as? String ?? "message") == "message",
                  m["deletedDateTime"] == nil || m["deletedDateTime"] is NSNull,
                  let created = (m["createdDateTime"] as? String).flatMap(parseGraphDate) else { return nil }
            let body = m["body"] as? [String: Any]
            let raw = (body?["content"] as? String) ?? ""
            let isHTML = ((body?["contentType"] as? String) ?? "text").lowercased() == "html"
            let text = (isHTML ? stripHTML(raw) : raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let user = (m["from"] as? [String: Any])?["user"] as? [String: Any]
            let from = (user?["displayName"] as? String) ?? "Unknown"
            return TeamsChatMessage(id: id, from: from, sentAt: created, text: text)
        }
        .sorted { $0.sentAt < $1.sentAt }
    }

    /// Reduce a Teams HTML body to readable plain text: block tags become line
    /// breaks, `<at>` mentions keep their label, images/attachments become a
    /// placeholder, everything else is dropped and entities decoded.
    static func stripHTML(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div|li|tr|h[1-6]|blockquote)>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<img[^>]*>", with: "[image]", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<attachment[^>]*>.*?</attachment>", with: "[attachment]", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<attachment[^>]*/>", with: "[attachment]", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        // Collapse runs of blank lines and trailing whitespace per line.
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for line in lines {
            if line.isEmpty && out.last?.isEmpty == true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let table: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
        ]
        for (k, v) in table { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    /// Graph timestamps come as `2026-09-14T09:12:33.123Z` or without fraction.
    static func parseGraphDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: Relevance

    /// Words that appear in most meeting titles and carry no customer signal.
    private static let titleStopwords: Set<String> = [
        "meeting", "call", "sync", "catch", "catchup", "check", "checkin", "chat", "intro",
        "introduction", "discussion", "session", "review", "advisory", "demo", "discovery",
        "between", "with", "and", "the", "for", "from", "ask", "adam", "brown", "weekly",
        "daily", "monthly", "update", "follow", "followup", "kickoff", "kick", "off", "team",
        "teams", "external", "internal", "invite", "invitation", "migrate", "migration",
        "partner", "customer", "white", "glove", "working", "planning", "prep", "onboarding",
    ]

    /// Keywords that identify *this* meeting's subject: the customer/partner
    /// name (from the Notion brief, when known) plus distinctive title words.
    /// Everything lowercased. Empty when the title is all boilerplate.
    static func relevanceKeywords(title: String, customer: String?) -> Set<String> {
        var out: Set<String> = []
        if let c = customer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), c.count >= 3 {
            out.insert(c)
            // Also the individual words of a multi-word customer name ("Virgin Atlantic").
            for w in c.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where w.count >= 4 {
                out.insert(String(w))
            }
        }
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for w in words where w.count >= 4 && !titleStopwords.contains(w) {
            out.insert(w)
        }
        return out
    }

    /// True when `email` shares the user's own domain (a colleague, not the customer).
    static func isInternal(email: String, selfEmail: String?) -> Bool {
        guard let mine = selfEmail?.split(separator: "@").last?.lowercased(),
              let theirs = email.split(separator: "@").last?.lowercased() else { return false }
        return mine == theirs
    }

    static func matches(_ text: String, keywords: Set<String>) -> Bool {
        guard !keywords.isEmpty else { return false }
        let lower = text.lowercased()
        return keywords.contains { lower.contains($0) }
    }

    /// Chats (of any type) whose topic names this meeting's subject, deduped.
    static func topicMatches(in directory: TeamsChatDirectory, keywords: Set<String>) -> [TeamsChatRef] {
        var seen: Set<String> = []
        var out: [TeamsChatRef] = []
        for refs in directory.byEmail.values {
            for ref in refs where ref.chatType != "oneOnOne" {
                guard let topic = ref.topic, !seen.contains(ref.chatID), matches(topic, keywords: keywords) else { continue }
                seen.insert(ref.chatID)
                out.append(ref)
            }
        }
        return out.sorted { ($0.lastUpdated ?? .distantPast) > ($1.lastUpdated ?? .distantPast) }
    }

    /// Filter to messages within `days` of `now`, keeping at most `limit` (most recent).
    static func recent(_ messages: [TeamsChatMessage], days: Int, limit: Int, now: Date = Date()) -> [TeamsChatMessage] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return Array(messages.filter { $0.sentAt >= cutoff }.suffix(limit))
    }
}
