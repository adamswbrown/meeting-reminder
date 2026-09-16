import SwiftUI

/// Settings for the intraday pre-call briefing pipeline.
///
/// This used to live inside Notion → Calendar Sync, which made it undiscoverable:
/// it is a briefing feature, not sync plumbing, and it now spans Claude, Apple
/// Intelligence, Notion, Slack and Todoist. Several things it depends on had no UI
/// at all — the Slack and Todoist tokens existed only as hand-added Keychain
/// entries, and the channel and project name were compile-time constants.
struct BriefingSettingsView: View {
    @ObservedObject var preCallBriefTrigger: PreCallBriefTriggerService

    @AppStorage(BriefingFallbackCoordinator.Keys.enabled) private var fallbackEnabled = false
    @AppStorage(BriefingFallbackCoordinator.Keys.shortcut) private var fallbackShortcut = ""
    @AppStorage(PreCallBriefTriggerService.Keys.cliPath) private var cliPathOverride = ""
    @AppStorage(PreCallBriefTriggerService.Keys.skillPath) private var skillPathOverride = ""
    @AppStorage(PreCallBriefTriggerService.Keys.minInterval) private var minIntervalSeconds = 0
    @AppStorage(BriefingDeliveryService.slackChannelOverrideKey) private var slackChannel = ""
    @AppStorage(BriefingDeliveryService.todoistProjectOverrideKey) private var todoistProject = ""

    /// On-device vs cloud is UI state derived from the stored shortcut name, not a
    /// second persisted source of truth: the service contract is simply "empty
    /// shortcut means on-device", and duplicating that into another key invites the
    /// two disagreeing.
    private enum Engine: String, CaseIterable { case onDevice, cloud }
    @State private var engine: Engine = .onDevice
    @State private var shortcuts: [String] = []
    @State private var shortcutsError: String?
    @State private var loadingShortcuts = false

    @State private var slackTokenDraft = ""
    @State private var todoistTokenDraft = ""
    @State private var slackTestResult = ""
    @State private var todoistTestResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            intradaySection
            claudeSection
            appleSection
            deliverySection
        }
        .formStyle(.grouped)
        .onAppear {
            slackTokenDraft = KeychainHelper.read(key: BriefingDeliveryService.slackTokenKey) ?? ""
            todoistTokenDraft = KeychainHelper.read(key: BriefingDeliveryService.todoistTokenKey) ?? ""
            engine = fallbackShortcut.isEmpty ? .onDevice : .cloud
            if engine == .cloud { Task { await loadShortcuts() } }
        }
    }

    // MARK: - Intraday

    private var intradaySection: some View {
        Section {
            Toggle("Auto-brief new meetings during the day",
                   isOn: Binding(get: { preCallBriefTrigger.isEnabled },
                                 set: { preCallBriefTrigger.isEnabled = $0 }))
            if !preCallBriefTrigger.lastResult.isEmpty {
                LabeledContent("Last run") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(preCallBriefTrigger.lastResult)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        if let at = preCallBriefTrigger.lastRunAt {
                            Text(at, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if preCallBriefTrigger.isRunning {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Briefing…").font(.caption) }
            }
            if !preCallBriefTrigger.fallbackReviewItems.isEmpty {
                BriefingReviewList(items: preCallBriefTrigger.fallbackReviewItems,
                                   resume: preCallBriefTrigger.resumeFallbackReview,
                                   dismiss: preCallBriefTrigger.dismissFallbackReview)
            }
        } header: {
            Text("Intraday briefings")
        } footer: {
            Text("When a genuinely new meeting lands in the diary on a weekday between 09:00 and 17:00, it is briefed automatically. The morning digest is produced separately in the cloud and is not affected by anything on this page.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Claude

    private var claudeSection: some View {
        Section {
            pathRow(title: "Claude CLI", override: $cliPathOverride,
                    resolved: preCallBriefTrigger.resolvedCLIPath,
                    placeholder: "auto-detect")
            pathRow(title: "Skill file", override: $skillPathOverride,
                    resolved: preCallBriefTrigger.resolvedSkillPath,
                    placeholder: "default location")
            Picker("Minimum gap between runs", selection: $minIntervalSeconds) {
                Text("1 min").tag(60)
                Text("2 min (default)").tag(0)
                Text("5 min").tag(300)
                Text("15 min").tag(900)
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("Leave the paths blank to auto-detect. A ✗ means the file is not there — this is the usual cause of briefings silently not running, for example after the CLI moves between npm and Homebrew locations.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Shows the *resolved* path and whether it exists, because an override that is
    /// blank still resolves to something and a stale one fails invisibly.
    private func pathRow(title: String, override: Binding<String>,
                         resolved: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField(placeholder, text: override)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            }
            let exists = FileManager.default.fileExists(atPath: resolved)
            HStack(spacing: 4) {
                Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(exists ? .green : .red)
                Text(resolved).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: - Apple Intelligence

    @ViewBuilder
    private var appleSection: some View {
        Section {
            if #available(macOS 26.4, *) {
                Toggle("Use Apple Intelligence when Claude reaches its usage limit", isOn: $fallbackEnabled)
                    .disabled(!preCallBriefTrigger.isEnabled)
                if fallbackEnabled {
                    Picker("Generate with", selection: $engine) {
                        Text("On-device model").tag(Engine.onDevice)
                        Text("Apple cloud (via a Shortcut)").tag(Engine.cloud)
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: engine) { _, new in
                        // On-device is expressed as "no shortcut", so switching away
                        // must clear it or the cloud route would still run.
                        if new == .onDevice { fallbackShortcut = "" }
                        else if shortcuts.isEmpty { Task { await loadShortcuts() } }
                    }

                    if engine == .cloud {
                        shortcutPicker
                        if fallbackShortcut.isEmpty {
                            Label("Pick a Shortcut — until you do, briefings stay on-device.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let shortcutsError {
                            Text(shortcutsError).font(.caption).foregroundStyle(.red)
                        }
                    }

                    LabeledContent("Queue", value: preCallBriefTrigger.fallbackStatus)
                    if let until = preCallBriefTrigger.fallbackCooldownUntil {
                        LabeledContent("Retrying Claude") {
                            HStack(spacing: 8) {
                                Text(until, style: .relative).font(.caption).foregroundStyle(.secondary)
                                Button("Retry now") { preCallBriefTrigger.clearFallbackCooldown() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            } else {
                Text("Requires macOS 26.4 or later.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Apple Intelligence fallback")
        } footer: {
            Text("Only a confirmed usage or credit limit hands over to Apple Intelligence — a rate limit, an authentication failure or a timeout does not, so a transient blip cannot replace a good briefing with a thin one.\n\nOn-device keeps everything on this Mac but has a much smaller context window. The cloud route sends the meeting context to Apple through a Shortcut you choose; that Shortcut must take Shortcut Input, generate only, and return its response via Stop and Output. The app cannot tell which model a Shortcut uses, so if you change the model inside it nothing here will say so.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var shortcutPicker: some View {
        HStack {
            if shortcuts.isEmpty {
                Text(loadingShortcuts ? "Looking for Shortcuts…"
                     : "No Shortcuts found. Create one in Shortcuts.app, then refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Shortcut", selection: $fallbackShortcut) {
                    Text("Choose…").tag("")
                    ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Spacer()
            Button {
                Task { await loadShortcuts() }
            } label: {
                if loadingShortcuts { ProgressView().controlSize(.small).scaleEffect(0.7) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .disabled(loadingShortcuts)
        }
    }

    private func loadShortcuts() async {
        loadingShortcuts = true
        defer { loadingShortcuts = false }
        switch await ShortcutsCatalog.list() {
        case .success(let names):
            shortcuts = names
            shortcutsError = nil
            // A Shortcut that has been renamed or deleted would otherwise sit in the
            // picker as a selection that silently fails at briefing time.
            if !fallbackShortcut.isEmpty, !names.contains(fallbackShortcut) {
                shortcutsError = "“\(fallbackShortcut)” no longer exists — pick another."
            }
        case .failure(let message):
            shortcutsError = "Could not list Shortcuts: \(message)"
        }
    }

    // MARK: - Delivery

    private var deliverySection: some View {
        Section {
            LabeledContent("Slack bot token") {
                SecureField("xoxb-…", text: $slackTokenDraft)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            }
            LabeledContent("Slack channel") {
                TextField(BriefingDeliveryService.defaultSlackChannel, text: $slackChannel)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            }
            LabeledContent("Todoist API token") {
                SecureField("Settings → Integrations → Developer", text: $todoistTokenDraft)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            }
            LabeledContent("Todoist project") {
                TextField(BriefingDeliveryService.defaultTodoistProject, text: $todoistProject)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            }
            HStack(spacing: 8) {
                Button("Save & test") { Task { await saveAndTest() } }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !slackTestResult.isEmpty {
                Text(slackTestResult).font(.caption)
                    .foregroundStyle(slackTestResult.hasPrefix("✓") ? .green : .red)
            }
            if !todoistTestResult.isEmpty {
                Text(todoistTestResult).font(.caption)
                    .foregroundStyle(todoistTestResult.hasPrefix("✓") ? .green : .red)
            }
        } header: {
            Text("Delivery")
        } footer: {
            Text("Used only by Apple Intelligence briefings — when Claude runs normally it delivers these itself. Tokens are stored in the Keychain, never in preferences. Testing reads only: it checks the token and resolves the project, and sends nothing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func saveAndTest() async {
        testing = true
        defer { testing = false }
        let slack = slackTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let todoist = todoistTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if slack.isEmpty { KeychainHelper.delete(key: BriefingDeliveryService.slackTokenKey) }
        else { KeychainHelper.save(key: BriefingDeliveryService.slackTokenKey, value: slack) }
        if todoist.isEmpty { KeychainHelper.delete(key: BriefingDeliveryService.todoistTokenKey) }
        else { KeychainHelper.save(key: BriefingDeliveryService.todoistTokenKey, value: todoist) }

        slackTestResult = slack.isEmpty ? "No Slack token — briefings will be saved but not announced."
            : await BriefingDeliveryService().verifySlack()
        todoistTestResult = todoist.isEmpty ? "No Todoist token — action items will not be synced."
            : await BriefingDeliveryService().verifyTodoist()
    }
}
