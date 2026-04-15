import AppKit
import Foundation

enum MeetingLauncher {
    static func open(_ url: URL) {
        let target = nativeAppURL(for: url) ?? url
        NSWorkspace.shared.open(target)
    }

    static func nativeAppURL(for url: URL) -> URL? {
        let s = url.absoluteString
        guard s.hasPrefix("https://teams.microsoft.com/") else { return nil }
        let rewritten = s.replacingOccurrences(
            of: "https://teams.microsoft.com/",
            with: "msteams:/"
        )
        guard let teamsURL = URL(string: rewritten),
              NSWorkspace.shared.urlForApplication(toOpen: teamsURL) != nil
        else { return nil }
        return teamsURL
    }
}
