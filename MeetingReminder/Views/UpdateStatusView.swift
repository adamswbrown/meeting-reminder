import SwiftUI

struct UpdateStatusView: View {
    @ObservedObject var checker: UpdateChecker
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Version \(checker.installedVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch checker.status {
            case .idle, .checking:
                Text("Checking for updates…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .upToDate:
                Text("Up to date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .updateAvailable(let version):
                Text("\(version) is available")
                    .font(.caption)
                Button("Download Latest Version") {
                    openURL(UpdateChecker.latestReleaseURL)
                }
            case .failed:
                Text("Unable to check for updates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if checker.status != .idle && checker.status != .checking {
                Button(checker.status == .failed ? "Retry" : "Check for Updates") {
                    Task { await checker.check(force: true) }
                }
                .controlSize(.small)
            }
        }
        .task { await checker.check() }
    }
}
