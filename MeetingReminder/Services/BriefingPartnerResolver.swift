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

/// The mapping rules plus enough diagnostics to tell "no rule matched" apart from
/// "nothing parsed". Those look identical downstream — both yield the convener
/// fallback — but one is normal and the other means partner resolution is dead.
struct BriefingMappingRuleSet: Equatable {
    var rules: [BriefingMappingRule] = []
    var rowsSeen = 0
    var looksBroken: Bool { rowsSeen > 0 && rules.isEmpty }
}

struct BriefingPartnerResolution: Equatable {
    /// Canonical `Customer / Partner` select value, or nil when nothing resolved.
    var partner: String?
    /// True when no mapping rule fired and the value came from the convener or
    /// internal fallback. The skill raises a Mapping Rule Suggestion in this case;
    /// the fallback records it in source coverage instead.
    var byInference = false
    /// Most-represented external email domain. A reasonable default, but NOT
    /// necessarily the partner's: on a Microsoft-convened partner call the
    /// convener usually outnumbers the partner.
    var primaryDomain: String?
    /// The domain(s) that actually matched the winning Email Domain rule — the
    /// partner's own. Empty when the partner came from a title keyword, the
    /// convener fallback or the internal fallback.
    var partnerDomains: [String] = []
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

    /// Outcome of applying the tier ladder to one kind of rule.
    private enum Winner {
        case won(partner: String, tier: Int, isPartner: Bool, domains: [String])
        case tie([String], tier: Int)
        case none
    }

    /// Applies Tier 1 (Partner) then Tier 2 (Customer) over one set of candidate
    /// rules, weighting each candidate by how many attendees back it.
    private static func apply(_ candidates: [BriefingMappingRule], isEmailDomain: Bool,
                              external: [String]) -> Winner {
        for (tier, isPartner) in [(1, true), (2, false)] {
            let tierRules = candidates.filter { $0.isPartner == isPartner }
            guard !tierRules.isEmpty else { continue }
            let weighted = Dictionary(grouping: tierRules, by: \.customerPartner).mapValues { group in
                group.reduce(0) { total, rule in
                    total + (isEmailDomain ? external.filter { rule.matchesDomain($0) }.count : 1)
                }
            }
            let best = weighted.values.max() ?? 0
            let winners = weighted.filter { $0.value == best }.keys.sorted()
            guard winners.count == 1, let partner = winners.first else {
                return .tie(winners, tier: tier)
            }
            let domains = isEmailDomain
                ? Set(tierRules.filter { $0.customerPartner == partner }
                    .flatMap { rule in external.filter { rule.matchesDomain($0) } }).sorted()
                : []
            return .won(partner: partner, tier: tier, isPartner: isPartner, domains: domains)
        }
        return .none
    }

    /// The Step 4 precedence ladder. Domains are counted so the tie-break can
    /// prefer the most-represented org, and `@altra.cloud` never competes.
    ///
    /// One deliberate divergence from the skill's "email domain rules first, then
    /// title keywords": when the only thing an email rule matched is a **convener**
    /// domain, a matching title keyword wins instead. Concentrix and other partners
    /// attend Microsoft-convened calls on `v-*@microsoft.com` vendor accounts, so
    /// there is no partner domain to match and `microsoft.com` is present on nearly
    /// every external meeting — strict email-first resolves "CNX Fy27 Office Hours"
    /// to Microsoft and buries the `cnx fy27 -> Concentrix` rule. A convener
    /// attendee says who convened, not who the meeting is with.
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
        let byEmail = apply(live.filter { rule in external.contains { rule.matchesDomain($0) } },
                            isEmailDomain: true, external: external)
        let byTitle = apply(live.filter { $0.matchesTitle(title) }, isEmailDomain: false, external: external)

        func accept(_ partner: String, tier: Int, isPartner: Bool, domains: [String], why: String) {
            result.partner = partner
            result.partnerDomains = domains
            result.rationale = "Tier \(tier) (\(isPartner ? "Partner" : "Customer")) \(why) matched \(partner)."
        }

        switch byEmail {
        case .won(let partner, let tier, let isPartner, let domains):
            // Convener-only email match loses to a more specific title keyword.
            if domains.allSatisfy({ conveners.keys.contains($0) }),
               case .won(let tPartner, let tTier, let tIsPartner, _) = byTitle, tPartner != partner {
                accept(tPartner, tier: tTier, isPartner: tIsPartner, domains: [],
                       why: "title keyword rule (preferred over the \(partner) convener-domain match)")
                return result
            }
            accept(partner, tier: tier, isPartner: isPartner, domains: domains, why: "email domain rule")
            return result
        case .tie(let winners, let tier):
            // A tie the attendee count cannot break. The skill would fall through to
            // the organiser's domain, which MeetingEvent does not carry.
            result.rationale = "Tier \(tier) email domain rules tied between \(winners.joined(separator: ", ")); left blank for review."
            return result
        case .none:
            break
        }

        switch byTitle {
        case .won(let partner, let tier, let isPartner, _):
            accept(partner, tier: tier, isPartner: isPartner, domains: [], why: "title keyword rule")
            return result
        case .tie(let winners, let tier):
            result.rationale = "Tier \(tier) title keyword rules tied between \(winners.joined(separator: ", ")); left blank for review."
            return result
        case .none:
            break
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
