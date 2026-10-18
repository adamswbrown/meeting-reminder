import SwiftUI

/// Settings → Notion → Calendar Sync: cloud (Managed Agents) execution for the intraday
/// pre-call briefing and the post-meeting follow-up. Everything is opt-in and off by default.
struct ManagedAgentsSettingsSection: View {
    @ObservedObject var followUp: PostMeetingFollowUpService

    @AppStorage(ManagedAgentsSettings.precallEnabledKey) private var precallEnabled = false
    @AppStorage(ManagedAgentsSettings.environmentIDKey) private var environmentID = ""
    @AppStorage(ManagedAgentsSettings.vaultIDKey) private var vaultID = ""
    @AppStorage(ManagedAgentRole.precall.agentIDKey) private var precallAgentID = ""
    @AppStorage(ManagedAgentRole.followUp.agentIDKey) private var followUpAgentID = ""

    @State private var apiKeyDraft = ""
    @State private var hasKey = ManagedAgentsSettings.apiKey != nil

    var body: some View {
        Section {
            HStack {
                SecureField(hasKey ? "API key saved — paste a new one to replace" : "Anthropic API key (sk-ant-…)",
                            text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return }
                    KeychainHelper.save(key: ManagedAgentsSettings.apiKeyKeychainKey, value: key)
                    apiKeyDraft = ""
                    hasKey = true
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("Environment ID (env_…)", text: $environmentID).textFieldStyle(.roundedBorder)
            TextField("Vault ID (vlt_…)", text: $vaultID).textFieldStyle(.roundedBorder)
            TextField("Pre-call briefing agent ID (agent_…)", text: $precallAgentID).textFieldStyle(.roundedBorder)
            TextField("Follow-up agent ID (agent_…)", text: $followUpAgentID).textFieldStyle(.roundedBorder)

            Toggle("Run intraday briefings on a Managed Agent", isOn: $precallEnabled)
                .disabled(!ManagedAgentsSettings.isConfigured(for: .precall))
            Toggle("Draft a follow-up when a meeting with notes ends",
                   isOn: Binding(get: { followUp.isEnabled }, set: { followUp.isEnabled = $0 }))
                .disabled(!ManagedAgentsSettings.isConfigured(for: .followUp))

            if !followUp.lastResult.isEmpty {
                LabeledContent("Last follow-up") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(followUp.lastResult)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        if let at = followUp.lastRunAt {
                            Text(at, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if followUp.isRunning {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Drafting follow-up…").font(.caption) }
            }
        } header: {
            Text("Managed Agents (cloud)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Runs the briefing and the follow-up in an Anthropic-hosted sandbox instead of on this Mac. Billed to your Anthropic API credit; each run has a hard spend cap ($1.50 per briefing, $1 per follow-up). Set up the agents with managed-agents/setup.sh, then paste the IDs it prints.")
                Text("Briefings: if the sandbox can't be started the app falls back to the local `claude` CLI. A run that started and then failed is not re-run locally, to avoid double-posting to Slack.")
                Text("Follow-ups: only for meetings where this app holds a Notion notes page. The agent adds a summary, action items and a draft email to that page — it never sends anything. Log: ~/Library/Logs/MeetingReminder/post-meeting-followup.log.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
