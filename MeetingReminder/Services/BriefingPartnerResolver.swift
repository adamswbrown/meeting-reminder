import CryptoKit
import Foundation

/// Pure retrieval-and-classification logic shared by the fallback briefing path.
///
/// This mirrors the private briefing skill's Step 4 (customer/partner ladder),
/// Step 6 (prior-history targeting) and Step 7 (`#AI-XXXXXX` action IDs) so a
/// fallback briefing joins the same Notion rows and Todoist tasks the main
/// runner would have produced. Kept free of EventKit and Notion transport so
/// the ladder can be tested against table-driven cases, like
/// `CalendarEventMapper`.
///
/// One deliberate divergence from the skill: its tie-break ladder ends
/// "most-attendee-emails → organiser's domain → blank + Suggestion", and
/// `MeetingEvent` does not carry the organiser. A tie that the email count
/// cannot break therefore resolves to blank-with-inference rather than
/// silently guessing a partner, which is the safe half of that rule.
struct BriefingMappingRule: Equatable {
    enum MatchType: String { case emailDomain = "Email Domain", titleKeyword = "Title Keyword" }
    var matchValue: String
    var matchType: MatchType
    var customerPartner: String
    var isPartner: Bool
    var active: Bool

    /// Exact domain, or a subdomain suffix (`emea.contoso.com` matches `contoso.com`).
    func matchesDomain(_ domain: String) -> Bool {
        guard matchType == .emailDomain else { return false }
        let value = matchValue.lowercased(), candidate = domain.lowercased()
        return candidate == value || candidate.hasSuffix(".\(value)")
    }
    func matchesTitle(_ title: String) -> Bool {
        guard matchType == .titleKeyword, !matchValue.isEmpty else { return false }
        return title.lowercased().contains(matchValue.lowercased())
    }
}

struct BriefingPartnerResolution: Equatable {
    /// Canonical `Customer / Partner` select value, or nil when nothing resolved.
    var partner: String?
    /// True when no mapping rule fired and the value came from the convener or
    /// internal fallback. The skill raises a Mapping Rule Suggestion in this case;
    /// the fallback records it in source coverage instead.
    var byInference = false
    /// Primary external email domain, used to target prior-history queries.
    var primaryDomain: String?
    /// Any `@google.com` attendee: always brief, and flag as a Key Meeting.
    var isGoogleColab = false
    /// Human-readable account of which rule/tier won, for the coverage line.
    var rationale = "No mapping rule matched."
}

enum BriefingPartnerResolver {
    static let conveners = ["microsoft.com": "Microsoft", "google.com": "Google"]

    /// Extracts lowercase email addresses from EventKit's mixed "Name <a@b>" /
    /// bare-name attendee strings. Display-name-only attendees yield nothing.
    static func emails(in attendees: [String]) -> [String] {
        let pattern = #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        return attendees.compactMap { value in
            guard let range = value.range(of: pattern, options: .regularExpression) else { return nil }
            return String(value[range]).lowercased()
        }
    }

    static func domain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = String(email[email.index(after: at)...]).lowercased()
        return domain.isEmpty ? nil : domain
    }

    /// The Step 4 precedence ladder. Domains are counted so the tie-break can
    /// prefer the most-represented org, and `@altra.cloud` never competes.
    static func resolve(attendees: [String], title: String, rules: [BriefingMappingRule]) -> BriefingPartnerResolution {
        let addresses = emails(in: attendees)
        let external = addresses.compactMap(domain(of:)).filter { $0 != CalendarSyncConstants.internalDomain }
        var counts: [String: Int] = [:]
        for domain in external { counts[domain, default: 0] += 1 }

        var result = BriefingPartnerResolution()
        result.isGoogleColab = external.contains("google.com")
        result.primaryDomain = counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key

        let live = rules.filter(\.active)
        // Tier 1 then Tier 2, over email-domain rules, then the same over title
        // keywords. Weight each candidate by how many attendees back it.
        for (matchKind, candidates) in [
            ("email domain", live.filter { rule in external.contains { rule.matchesDomain($0) } }),
            ("title keyword", live.filter { $0.matchesTitle(title) }),
        ] where !candidates.isEmpty {
            for (tier, isPartner) in [(1, true), (2, false)] {
                let tierRules = candidates.filter { $0.isPartner == isPartner }
                guard !tierRules.isEmpty else { continue }
                let weighted = Dictionary(grouping: tierRules, by: \.customerPartner).mapValues { group in
                    group.reduce(0) { total, rule in
                        total + (matchKind == "email domain"
                                 ? external.filter { rule.matchesDomain($0) }.count
                                 : 1)
                    }
                }
                let best = weighted.values.max() ?? 0
                let winners = weighted.filter { $0.value == best }.keys.sorted()
                guard winners.count == 1, let partner = winners.first else {
                    // A tie the attendee count cannot break. The skill would fall
                    // through to the organiser's domain, which we do not have.
                    result.rationale = "Tier \(tier) \(matchKind) rules tied between \(winners.joined(separator: ", ")); left blank for review."
                    return result
                }
                result.partner = partner
                result.rationale = "Tier \(tier) (\(isPartner ? "Partner" : "Customer")) \(matchKind) rule matched \(partner)."
                return result
            }
        }

        // Tier 3 — convener, only when no Tier 1/2 rule matched at all.
        for (domain, name) in conveners where external.contains(domain) {
            result.partner = name
            result.byInference = true
            result.rationale = "Tier 3 convener rule inferred \(name) from \(domain); no mapping rule exists."
            return result
        }
        if !addresses.isEmpty, external.isEmpty {
            result.partner = "Altra"
            result.byInference = true
            result.rationale = "All attendees are internal; resolved to Altra."
        }
        return result
    }

    /// Step 7's stage inference. Unknown shapes stay blank rather than guessing.
    static func stage(forTitle title: String) -> String? {
        let lower = title.lowercased()
        if lower.contains("kickoff") || lower.contains("kick-off") || lower.contains("first steps") {
            return "New Partner Kickoff"
        }
        if lower.contains("scoping") || lower.contains("assessment") { return "Scoping" }
        if lower.contains("demo") || lower.contains("discovery") { return "Discovery" }
        return nil
    }

    /// `#AI-XXXXXX` — first 6 hex of md5("<canonical partner>|<normalised item>").
    /// This is a *join key*, not a security primitive; it must stay byte-identical
    /// to the skill's definition or Todoist dedup silently stops matching.
    static func actionID(partner: String?, item: String) -> String {
        let normalised = item.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: #"[.,;:!?]+$"#, with: "", options: .regularExpression)
        let digest = Insecure.MD5.hash(data: Data("\(partner ?? "")|\(normalised)".utf8))
        return "#AI-" + digest.map { String(format: "%02x", $0) }.joined().prefix(6)
    }

    /// Pulls `- [ ] text (#AI-xxxxxx)` checkboxes out of a prior briefing's text.
    /// Only unticked items are carried forward; a ticked box is completed work and
    /// must never be recreated as a task.
    static func openActionItems(in text: String) -> [(text: String, id: String)] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("* [ ]") else { return nil }
            var body = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let range = body.range(of: #"\(#AI-[0-9a-f]{6}\)$"#, options: .regularExpression) else { return nil }
            let id = String(body[range]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            body = String(body[body.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return nil }
            return (body, id)
        }
    }
}
