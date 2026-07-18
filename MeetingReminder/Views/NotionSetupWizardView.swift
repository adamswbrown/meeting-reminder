import AppKit
import SwiftUI

/// Guided, out-of-the-box Notion setup. Walks the user through the two
/// unavoidable manual steps (create an integration, share one page with it),
/// then calls `NotionProvisioningService` to build every database the app needs
/// and wire up the config automatically.
///
/// Reused verbatim from two places:
///   - Settings → Notion tab ("Set up Notion automatically…" button, in a sheet)
///   - First-launch onboarding (optional Notion step, in a sheet)
///
/// It writes token + IDs straight to Keychain/UserDefaults, so callers don't
/// need to thread the app's `NotionService` in — they just refresh their own
/// state in `onFinish`.
struct NotionSetupWizardView: View {
    /// Called when the wizard is dismissed. `provisioned` is true only if the
    /// databases were created successfully — callers use it to refresh their
    /// connection status.
    let onFinish: (_ provisioned: Bool) -> Void

    @StateObject private var prov = NotionProvisioningService()

    @State private var page = 0
    @State private var token = ""
    @State private var parentPage = ""

    private let integrationsURL = URL(string: "https://www.notion.so/my-integrations")!

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 540, height: 480)
    }

    // MARK: - Pages

    @ViewBuilder private var content: some View {
        switch page {
        case 0: introPage
        case 1: tokenPage
        case 2: sharePage
        default: provisionPage
        }
    }

    /// True when a Notion token is already saved — i.e. this workspace is
    /// already connected. Completing the wizard would repoint the app at brand
    /// new, empty databases, so we warn first.
    private var alreadyConnected: Bool {
        (KeychainHelper.read(key: CalendarSyncConstants.tokenKeychainKey)?.isEmpty == false)
    }

    private var introPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Set up Notion", systemImage: "sparkles")
            if alreadyConnected {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Notion is already connected. Finishing this wizard creates a **new, empty** set of databases and switches the app to them — your existing Notion pages stay put, but the app stops writing to them. Only continue for a fresh workspace.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }
            Text("This wizard creates five databases inside a Notion page you choose, each with the exact schema the app needs:")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                dbLine("Meeting Notes", "a notes page for every meeting you join")
                dbLine("Pre-Call Briefings", "prep notes surfaced before a call")
                dbLine("Calendar Events", "a synced ledger of your calendar for automations")
                dbLine("Skip List", "titles to exclude from calendar sync")
                dbLine("Cal Sync Migrations", "internal log of schema changes")
            }
            .padding(.leading, 2)
            Text("You’ll do two things by hand next — create an integration, and share one page with it. Everything above is then built and wired up automatically.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var tokenPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Create an integration", systemImage: "key.fill")
            VStack(alignment: .leading, spacing: 8) {
                stepLine("Open Notion’s integrations page and click “New integration”.")
                Button {
                    NSWorkspace.shared.open(integrationsURL)
                } label: {
                    Label("Open notion.so/my-integrations", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                stepLine("Give it a name (e.g. “Meeting Reminder”), pick your workspace, and create it.")
                stepLine("Copy the “Internal Integration Secret” and paste it below.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Integration token")
                    .font(.caption).foregroundColor(.secondary)
                SecureField("ntn_… or secret_…", text: $token)
                    .textFieldStyle(.roundedBorder)
            }
            Spacer()
        }
    }

    private var sharePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Share a page", systemImage: "person.2.fill")
            Text("Pick (or create) a Notion page to act as the home for the app’s databases — an empty page called “Meeting Reminder” works well.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                stepLine("Open that page in Notion.")
                stepLine("Click ••• (top-right) → Connections → add the integration you just created.")
                stepLine("Copy the page’s URL (Share → Copy link) and paste it below.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Parent page URL or ID")
                    .font(.caption).foregroundColor(.secondary)
                TextField("https://www.notion.so/…", text: $parentPage)
                    .textFieldStyle(.roundedBorder)
            }
            Spacer()
        }
    }

    private var provisionPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(prov.didSucceed ? "All set" : "Creating your databases",
                   systemImage: prov.didSucceed ? "checkmark.seal.fill" : "gearshape.2.fill")

            VStack(alignment: .leading, spacing: 10) {
                ForEach(NotionProvisioningService.Step.allCases) { step in
                    HStack(spacing: 10) {
                        stateIcon(prov.stepStates[step] ?? .pending)
                        Text(step.rawValue)
                            .foregroundColor((prov.stepStates[step] ?? .pending) == .pending ? .secondary : .primary)
                        Spacer()
                    }
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(10)

            if let err = prov.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if prov.didSucceed {
                Text("Notion is connected. New meetings will create pages automatically, and Calendar → Notion sync is ready to enable in the Cal Sync tab.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !prov.createdDatabases.isEmpty {
                    Text("Open in Notion:")
                        .font(.caption).foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(prov.createdDatabases) { db in
                            if let url = db.url {
                                Button {
                                    NotionService.openInNotionApp(url)
                                } label: {
                                    Label(db.name, systemImage: "arrow.up.forward.square")
                                        .font(.callout)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: - Footer / navigation

    private var footer: some View {
        HStack {
            Button("Cancel") { onFinish(prov.didSucceed) }
                .buttonStyle(.bordered)
                .disabled(prov.isRunning)

            Spacer()

            if page > 0 && page < 3 {
                Button("Back") { page -= 1 }
                    .buttonStyle(.bordered)
            }

            switch page {
            case 0:
                Button("Get Started") { page = 1 }
                    .buttonStyle(.borderedProminent)
            case 1:
                Button("Continue") { page = 2 }
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            case 2:
                Button("Create Databases") {
                    page = 3
                    Task { await prov.provision(token: token, parentPageInput: parentPage) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(parentPage.trimmingCharacters(in: .whitespaces).isEmpty)
            default:
                if prov.didSucceed {
                    Button("Done") { onFinish(true) }
                        .buttonStyle(.borderedProminent)
                } else if prov.errorMessage != nil {
                    Button("Try Again") {
                        Task { await prov.provision(token: token, parentPageInput: parentPage) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Working…") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                }
            }
        }
    }

    // MARK: - Small view helpers

    private func header(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(title).font(.title2.bold())
        }
    }

    private func dbLine(_ name: String, _ purpose: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "tablecells").font(.caption).foregroundColor(.accentColor)
            (Text(name).font(.callout.weight(.semibold))
             + Text(" — \(purpose)").font(.callout).foregroundColor(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundColor(.secondary).padding(.top, 6)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: NotionProvisioningService.StepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundColor(.secondary)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        }
    }
}
