import EventKit
import Foundation

struct VideoLinkDetector {
    // Domains are anchored (subdomains must be dot-separated labels) so
    // look-alikes such as "evilzoom.us" never match. Webex requires a
    // non-"www" subdomain because meeting links live on tenant hosts
    // (company.webex.com) while www.webex.com is marketing pages.
    // Teams covers the classic meetup-join link, the newer short
    // teams.microsoft.com/meet/<id> link, and personal teams.live.com/meet/.
    private static let patterns: [(name: String, pattern: String)] = [
        ("Zoom", #"https?://(?:[\w-]+\.)*zoom\.us/j/\S+"#),
        ("Google Meet", #"https?://meet\.google\.com/[a-z]+-[a-z]+-[a-z]+\S*"#),
        ("Microsoft Teams", #"https?://teams\.(?:microsoft\.com/(?:l/meetup-join|meet)|live\.com/meet)/\S+"#),
        ("Webex", #"https?://(?!www\.)(?:[\w-]+\.)+webex\.com/\S+"#),
        ("Slack Huddle", #"https?://app\.slack\.com/huddle/\S+"#),
    ]

    static func detectLink(in event: EKEvent) -> URL? {
        // Check the event URL first — most reliable source
        if let url = event.url.map(unwrapSafeLink), isVideoLink(url) {
            return url
        }

        // Search through text fields
        let searchTexts = [event.notes, event.location].compactMap { $0 }

        for text in searchTexts {
            if let url = findVideoURL(in: text) {
                return url
            }
        }

        return nil
    }

    static func isVideoLink(_ url: URL) -> Bool {
        let urlString = url.absoluteString
        return patterns.contains { _, pattern in
            urlString.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Microsoft Defender "Safe Links" wraps every link in Outlook/Exchange
    /// invites as `https://<region>.safelinks.protection.outlook.com/?url=<encoded>`.
    /// The percent-encoded target never matches the service patterns, so unwrap
    /// it first. Non-SafeLinks URLs are returned unchanged.
    static func unwrapSafeLink(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host == "safelinks.protection.outlook.com" || host.hasSuffix(".safelinks.protection.outlook.com"),
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let targetURL = URL(string: target) else {
            return url
        }
        return targetURL
    }

    /// Replace every SafeLinks-wrapped URL in `text` with its decoded target.
    private static func unwrapSafeLinks(in text: String) -> String {
        guard text.range(of: "safelinks.protection.outlook.com", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(
                pattern: #"https?://(?:[\w-]+\.)*safelinks\.protection\.outlook\.com/[^\s<>"']*"#,
                options: .caseInsensitive
              ) else {
            return text
        }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Replace back-to-front so earlier ranges stay valid.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let wrapped = URL(string: String(result[range])) else { continue }
            let unwrapped = unwrapSafeLink(wrapped)
            if unwrapped != wrapped {
                result.replaceSubrange(range, with: unwrapped.absoluteString)
            }
        }
        return result
    }

    static func findVideoURL(in text: String) -> URL? {
        let text = unwrapSafeLinks(in: text)

        // Collect the first match of every service and return the one that
        // appears earliest in the text — so a real join link in the body wins
        // over a different service's link in a signature or footer.
        var best: (location: Int, url: URL)?

        for (_, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }

            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            let matchRange = Range(match.range, in: text)!
            var urlString = String(text[matchRange])

            // Clean trailing punctuation that might have been captured
            while let last = urlString.last, ")>\"'.,;".contains(last) {
                urlString = String(urlString.dropLast())
            }

            if let url = URL(string: urlString), best == nil || match.range.location < best!.location {
                best = (match.range.location, url)
            }
        }

        return best?.url
    }

    static func serviceName(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("zoom.us") { return "Zoom" }
        if host.contains("meet.google.com") { return "Google Meet" }
        if host.contains("teams.microsoft.com") || host.contains("teams.live.com") { return "Teams" }
        if host.contains("webex.com") { return "Webex" }
        if host.contains("slack.com") { return "Slack" }
        return "Meeting"
    }
}
