import EventKit
import Foundation

struct VideoLinkDetector {
    // Domains are anchored (subdomains must be dot-separated labels) so
    // look-alikes such as "evilzoom.us" never match. Webex requires a
    // non-"www" subdomain because meeting links live on tenant hosts
    // (company.webex.com) while www.webex.com is marketing pages.
    private static let patterns: [(name: String, pattern: String)] = [
        ("Zoom", #"https?://(?:[\w-]+\.)*zoom\.us/j/\S+"#),
        ("Google Meet", #"https?://meet\.google\.com/[a-z]+-[a-z]+-[a-z]+\S*"#),
        ("Microsoft Teams", #"https?://teams\.microsoft\.com/l/meetup-join/\S+"#),
        ("Webex", #"https?://(?!www\.)(?:[\w-]+\.)+webex\.com/\S+"#),
        ("Slack Huddle", #"https?://app\.slack\.com/huddle/\S+"#),
    ]

    static func detectLink(in event: EKEvent) -> URL? {
        // Check the event URL first — most reliable source
        if let url = event.url, isVideoLink(url) {
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

    static func findVideoURL(in text: String) -> URL? {
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
        if host.contains("teams.microsoft.com") { return "Teams" }
        if host.contains("webex.com") { return "Webex" }
        if host.contains("slack.com") { return "Slack" }
        return "Meeting"
    }
}
