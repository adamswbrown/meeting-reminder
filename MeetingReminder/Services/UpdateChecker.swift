import Combine
import Foundation

/// Checks the original project's latest stable release; never installs an update.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(String)
        case failed
    }

    static let latestReleaseURL = URL(string: "https://github.com/adamswbrown/meeting-reminder/releases/latest")!
    static let apiURL = URL(string: "https://api.github.com/repos/adamswbrown/meeting-reminder/releases/latest")!

    let installedVersion: String
    @Published private(set) var status: Status = .idle
    private var lastChecked: Date?
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    init(
        installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
        fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.installedVersion = installedVersion
        self.fetch = fetch
    }

    /// Reopening the menu or settings reuses a successful check for one hour.
    func check(force: Bool = false) async {
        guard status != .checking else { return }
        if !force, let lastChecked, Date().timeIntervalSince(lastChecked) < 3600 { return }
        status = .checking
        do {
            var request = URLRequest(url: Self.apiURL)
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("MeetingReminder", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await fetch(request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard !release.draft, !release.prerelease,
                  let latest = ReleaseVersion(release.tag_name), !latest.isPrerelease,
                  let installed = ReleaseVersion(installedVersion) else {
                throw URLError(.cannotParseResponse)
            }
            status = latest.isNewer(than: installed) ? .updateAvailable(release.tag_name) : .upToDate
            lastChecked = Date()
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }
}

/// Numeric comparison avoids treating 3.10.0 as older than 3.9.0.
struct ReleaseVersion {
    let components: [Int]
    let isPrerelease: Bool

    init?(_ value: String) {
        let version = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let withoutBuild = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard withoutBuild.count == 1 || !withoutBuild[1].isEmpty else { return nil }
        let parts = withoutBuild[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 1 || !parts[1].isEmpty else { return nil }
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let parsed = numbers.compactMap { Int($0) }
        guard parsed.count == 3 else { return nil }
        components = parsed
        isPrerelease = parts.count == 2
    }

    func isNewer(than installed: ReleaseVersion) -> Bool {
        for (latest, current) in zip(components, installed.components) where latest != current {
            return latest > current
        }
        return !isPrerelease && installed.isPrerelease
    }
}
