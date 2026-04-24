import EventKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage("reminderMinutes") private var reminderMinutes: Int = 5
    @AppStorage("soundEnabled") private var soundEnabled: Bool = true
    @AppStorage("overlayBackground") private var overlayBackground: String = "dark"
    @AppStorage("colorBlindMode") private var colorBlindMode: Bool = false
    @AppStorage("progressiveAlertsEnabled") private var progressiveAlertsEnabled: Bool = true
    @AppStorage("wrapUpMinutes") private var wrapUpMinutes: Int = 10
    @AppStorage("screenDimmingEnabled") private var screenDimmingEnabled: Bool = false
    @AppStorage("breakEnforcementEnabled") private var breakEnforcementEnabled: Bool = true
    @AppStorage("contextSwitchPromptMinutes") private var contextSwitchPromptMinutes: Int = 3
    @AppStorage("inCallMinimalModeEnabled") private var inCallMinimalModeEnabled: Bool = true
    @AppStorage("overlayMonitorMode") private var overlayMonitorModeRaw: String = DisplayMode.all.rawValue
    @AppStorage("overlayMonitorScreenName") private var overlayMonitorScreenName: String = ""
    @ObservedObject var calendarService: CalendarService
    @ObservedObject var minutesService: MinutesService
    @ObservedObject var liveTranscriptService: LiveTranscriptService
    @ObservedObject var obsidianService: ObsidianService
    @ObservedObject var notionService: NotionService
    @AppStorage("preCallBriefsDatabaseID") private var preCallBriefsDatabaseID: String = ""

    @State private var launchAtLogin = false
    @State private var enabledCalendarIDs: Set<String> = []
    @State private var checklistItems: [ChecklistItem] = []
    @State private var newChecklistText: String = ""
    @State private var availableScreens: [NSScreen] = []
    @State private var notionTokenDraft: String = ""
    @State private var notionDatabaseDraft: String = ""
    @State private var preCallBriefDatabaseDraft: String = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            alertsTab
                .tabItem { Label("Alerts", systemImage: "bell.badge") }

            displayTab
                .tabItem { Label("Display", systemImage: "display") }

            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            checklistTab
                .tabItem { Label("Checklist", systemImage: "checklist") }

            calendarsTab
                .tabItem { Label("Calendars", systemImage: "calendar") }

            notionTab
                .tabItem { Label("Notion", systemImage: "square.and.pencil") }

            integrationsTab
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 560, height: 480)
        .onAppear {
            loadSettings()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                Picker("Remind me before meetings:", selection: $reminderMinutes) {
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                }
                .pickerStyle(.menu)
            }

            Section {
                Toggle("Play sound with reminder", isOn: $soundEnabled)
                Toggle("Colour-blind friendly mode", isOn: $colorBlindMode)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section {
                HStack {
                    Text("Calendar access:")
                    Spacer()
                    if calendarService.authorizationStatus == .authorized {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Request Access") {
                            Task { await calendarService.requestAccess() }
                        }
                    }
                }
            }

            Section {
                Button("Re-run Setup Assistant") {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    OnboardingWindowController().show(calendarService: calendarService)
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Alerts Tab

    private var alertsTab: some View {
        Form {
            Section("Progressive Alerts") {
                Toggle("Enable progressive alerts", isOn: $progressiveAlertsEnabled)

                if progressiveAlertsEnabled {
                    ForEach(AlertTier.allCases, id: \.rawValue) { tier in
                        Toggle(isOn: alertTierBinding(for: tier)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tier.displayName)
                                    .font(.body)
                                Text(tier.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Transition Support") {
                Picker("Wrap-up nudge:", selection: $wrapUpMinutes) {
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                }
                .pickerStyle(.menu)

                Picker("Context-switch prompt:", selection: $contextSwitchPromptMinutes) {
                    Text("2 minutes before").tag(2)
                    Text("3 minutes before").tag(3)
                    Text("5 minutes before").tag(5)
                }
                .pickerStyle(.menu)
            }

            Section("Breaks & Dimming") {
                Toggle("Break enforcement between back-to-back meetings", isOn: $breakEnforcementEnabled)

                Toggle("Gentle screen dimming before meetings", isOn: $screenDimmingEnabled)
                if screenDimmingEnabled {
                    Text("Gradually dims to 70% over 5 minutes before meetings. Respects Reduce Motion. Restore on meeting start.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Display Tab

    private var displayTab: some View {
        Form {
            Section("Show overlay on") {
                Picker("Display:", selection: $overlayMonitorModeRaw) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if overlayMonitorModeRaw == DisplayMode.specific.rawValue {
                    Picker("Screen:", selection: $overlayMonitorScreenName) {
                        if availableScreens.isEmpty {
                            Text("No screens detected").tag("")
                        } else {
                            ForEach(availableScreens, id: \.localizedName) { screen in
                                Text(screenLabel(screen)).tag(screen.localizedName)
                            }
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Refresh Screen List") {
                        availableScreens = NSScreen.screens
                    }
                    .controlSize(.small)
                }

                Text("Currently \(availableScreens.count) screen\(availableScreens.count == 1 ? "" : "s") connected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("In-call mode") {
                Toggle("Use minimal alert when on a call", isOn: $inCallMinimalModeEnabled)

                Text("When the microphone is active (you're in a call or sharing your screen), the full-screen overlay is replaced with a small, screen-share-safe notification. Sound is also suppressed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            availableScreens = NSScreen.screens
        }
    }

    private func screenLabel(_ screen: NSScreen) -> String {
        let size = screen.frame.size
        return "\(screen.localizedName) (\(Int(size.width))×\(Int(size.height)))"
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Overlay Background")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                ForEach(OverlayBackground.allCases) { bg in
                    Button {
                        overlayBackground = bg.rawValue
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(bg.previewGradient)
                                .frame(height: 70)
                                .overlay(
                                    Text("Aa")
                                        .font(.title2.bold())
                                        .foregroundColor(.white)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(overlayBackground == bg.rawValue ? Color.accentColor : Color.clear, lineWidth: 3)
                                )

                            Text(bg.displayName)
                                .font(.caption)
                                .foregroundColor(overlayBackground == bg.rawValue ? .accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Checklist Tab

    private var checklistTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pre-Meeting Checklist")
                .font(.headline)

            Text("These items appear when the reminder overlay fires, helping you prepare for meetings.")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach($checklistItems) { $item in
                    HStack {
                        TextField("Item", text: $item.text)
                            .textFieldStyle(.plain)
                        Spacer()
                        Button {
                            checklistItems.removeAll { $0.id == item.id }
                            ChecklistItem.save(checklistItems)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { from, to in
                    checklistItems.move(fromOffsets: from, toOffset: to)
                    ChecklistItem.save(checklistItems)
                }
            }

            HStack {
                TextField("New item…", text: $newChecklistText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addChecklistItem() }
                Button("Add") { addChecklistItem() }
                    .disabled(newChecklistText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button("Reset to Defaults") {
                checklistItems = ChecklistItem.defaults
                ChecklistItem.save(checklistItems)
            }
            .controlSize(.small)
        }
        .padding()
    }

    // MARK: - Calendars Tab

    private var calendarsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select which calendars to monitor:")
                .font(.headline)

            if calendarService.availableCalendars.isEmpty {
                Text("No calendars available. Grant calendar access first.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(calendarService.availableCalendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: calendarBinding(for: calendar.calendarIdentifier)) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(cgColor: calendar.cgColor))
                                    .frame(width: 10, height: 10)
                                Text(calendar.title)
                            }
                        }
                    }
                }
            }

            Text("If none selected, all calendars are monitored.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Integrations Tab
    //
    // Meeting Reminder's default recording/summarisation story is Notion —
    // see the dedicated Notion tab. Minutes and Obsidian are alternative
    // integrations hidden behind feature flags, off by default, because they
    // require a third-party CLI / desktop app and have rougher edges.

    private var integrationsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                integrationCard(
                    title: "Minutes",
                    subtitle: "Local-first transcription via the `minutes` CLI. Auto-records meetings, parses action items, shows a live transcript pane.",
                    isEnabled: $minutesService.integrationEnabled,
                    expanded: minutesContent
                )

                integrationCard(
                    title: "Obsidian",
                    subtitle: "Opens meeting notes in the Obsidian desktop app after a meeting ends. Requires the Minutes integration to produce notes.",
                    isEnabled: $obsidianService.integrationEnabled,
                    expanded: obsidianContent
                )
            }
            .padding()
        }
    }

    @ViewBuilder
    private func integrationCard<Content: View>(
        title: String,
        subtitle: String,
        isEnabled: Binding<Bool>,
        @ViewBuilder expanded: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if isEnabled.wrappedValue {
                Divider()
                expanded()
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(10)
    }

    // MARK: - Minutes sub-content (shown inside integrationsTab when enabled)

    @ViewBuilder
    private func minutesContent() -> some View {
        Form {
            Section("Status") {
                HStack {
                    if minutesService.isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("Not found", systemImage: "xmark.circle.fill")
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    if let v = minutesService.version {
                        Text("v\(v)")
                            .foregroundColor(.secondary)
                            .font(.callout.monospacedDigit())
                    }
                }

                if let path = minutesService.binaryPath {
                    HStack {
                        Text("Binary:")
                            .foregroundColor(.secondary)
                        Text(path.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                if !minutesService.isInstalled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Install with Homebrew:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("brew tap silverstein/tap && brew install minutes")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button("Choose binary…") {
                        chooseMinutesBinary()
                    }
                    .controlSize(.small)

                    Button("Detect") {
                        Task { await minutesService.detectInstall() }
                    }
                    .controlSize(.small)

                    Button("Health check") {
                        Task { _ = await minutesService.checkHealth() }
                    }
                    .controlSize(.small)
                }

                if let health = minutesService.lastHealthOutput, !health.isEmpty {
                    ScrollView {
                        Text(health)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                }
            }

            // Live transcript config health check — Minutes silently disables the
            // recording sidecar when [live_transcript].model is empty in config.toml.
            // We surface that and offer a one-click fix.
            if minutesService.isInstalled && !minutesService.liveTranscriptConfigured {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Live transcripts are disabled in your Minutes config")
                                .font(.callout.weight(.semibold))
                        }
                        Text("`[live_transcript].model` is empty in `~/.config/minutes/config.toml`. The recording sidecar requires a whisper model name to write transcript chunks during recording. Without it, the live transcript pane will stay empty during meetings.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        let installed = minutesService.installedWhisperModels()
                        if installed.isEmpty {
                            Text("No whisper models found in `~/.minutes/models/`. Run `minutes setup --model base` to install one.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else {
                            HStack(spacing: 8) {
                                Text("Installed models:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ForEach(installed, id: \.self) { model in
                                    Button(model) {
                                        if minutesService.setLiveTranscriptModel(model) {
                                            // Backup file lives at config.toml.bak
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Configuration warning")
                }
            }

            Section("Behavior") {
                Toggle("Auto-record meetings when I join", isOn: $minutesService.autoRecord)
                Toggle("Show AI prep brief in context panel", isOn: $minutesService.prepEnabled)
                Toggle("Show live transcript pane during meetings", isOn: $liveTranscriptService.liveTranscriptEnabled)
                Toggle("In-call coach (heuristic alerts)", isOn: $liveTranscriptService.inCallCoachEnabled)
                    .disabled(!liveTranscriptService.liveTranscriptEnabled)
                HStack {
                    Text("Your name (for mention detection):")
                        .foregroundColor(.secondary)
                    TextField(NSFullUserName(), text: $liveTranscriptService.userName)
                        .textFieldStyle(.roundedBorder)
                }
                .disabled(!liveTranscriptService.inCallCoachEnabled)
            }

            Section("Features") {
                Text("Minutes is a local-first conversation memory tool.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    featureRow(icon: "waveform", text: "Local transcription with whisper.cpp (no cloud)")
                    featureRow(icon: "person.2", text: "Speaker diarization (when enabled in Minutes)")
                    featureRow(icon: "checkmark.square", text: "Auto-extracted action items + decisions")
                    featureRow(icon: "brain", text: "Pre-meeting brief from past conversations")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
        .task {
            await minutesService.detectInstall()
        }
    }

    // MARK: - Obsidian sub-content (shown inside integrationsTab when enabled)

    @ViewBuilder
    private func obsidianContent() -> some View {
        Form {
            Section("Status") {
                HStack {
                    if obsidianService.isInstalled {
                        Label("Obsidian installed", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("Not installed", systemImage: "xmark.circle.fill")
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Button("Detect") {
                        obsidianService.detect()
                    }
                    .controlSize(.small)
                }

                if !obsidianService.isInstalled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Obsidian isn't installed. Auto-opening meeting notes requires the Obsidian desktop app.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Button("Install with Homebrew") {
                                copyToClipboard("brew install --cask obsidian")
                            }
                            .controlSize(.small)
                            Text("(copies command)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Link("Download obsidian.md", destination: URL(string: "https://obsidian.md/download")!)
                            .font(.caption)
                    }
                }
            }

            if obsidianService.isInstalled {
                Section("Vaults") {
                    if obsidianService.vaults.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No vaults registered with Obsidian yet.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Text("Open Obsidian and create or open a vault. The vault needs to contain (or symlink to) your Minutes meetings folder — the [vault] section in `~/.config/minutes/config.toml` controls this.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ForEach(obsidianService.vaults) { vault in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.purple)
                                    .font(.system(size: 14))
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vault.name)
                                        .font(.callout.weight(.medium))
                                    Text(vault.path.path)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                    if let ts = vault.lastOpened {
                                        Text("Last opened: \(formattedDate(ts))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Section("Behavior") {
                    Toggle("Auto-open meeting note after meeting ends", isOn: $obsidianService.autoOpenEnabled)

                    Text("When a meeting ends and Minutes has finished transcribing, open the meeting note directly in the Obsidian desktop app.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Meetings Dashboard") {
                    dashboardInstallView
                }

                if let error = obsidianService.lastError {
                    Section("Last error") {
                        Text(error)
                            .font(.caption.monospaced())
                            .foregroundColor(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
        .onAppear {
            obsidianService.detect()
        }
    }

    // MARK: - Notion Tab

    private var notionTab: some View {
        Form {
            Section("Connection") {
                HStack {
                    if notionService.isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                        Text("Testing…")
                            .foregroundColor(.secondary)
                    } else if notionService.isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        if let name = notionService.databaseName {
                            Text("— \(name)")
                                .foregroundColor(.secondary)
                                .font(.callout)
                        }
                    } else if notionService.lastError != nil {
                        Label("Failed", systemImage: "xmark.octagon.fill")
                            .foregroundColor(.red)
                    } else if notionService.isConfigured {
                        Label("Not tested", systemImage: "questionmark.circle.fill")
                            .foregroundColor(.orange)
                    } else {
                        Label("Not configured", systemImage: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                Text("Meeting Reminder creates a new page in your Notion database the moment you join a meeting, then opens it in the Notion desktop app. Notion's own AI Meeting Notes block handles recording and summarisation. The integration is active whenever both credentials below are set — there is no separate on/off toggle.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Credentials") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Internal integration token")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("secret_…", text: $notionTokenDraft)
                        .textFieldStyle(.roundedBorder)
                    Text("Create one at notion.so/my-integrations and share your target database with it.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Database ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("32-character UUID from the database URL", text: $notionDatabaseDraft)
                        .textFieldStyle(.roundedBorder)
                    Text("Required schema: Title (title), Start (date), End (date), Attendees Name (rich text, optional).")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pre-call briefs database ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("32-character UUID for Pre-Call Briefings", text: $preCallBriefDatabaseDraft)
                        .textFieldStyle(.roundedBorder)
                    Text("Used by the floating pre-call brief panel. Reuses the same Notion token above.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Save & Test") {
                        saveAndTestNotion()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(notionService.isTesting)

                    Spacer()

                    Button("Clear") {
                        notionService.clearAPIToken()
                        notionService.databaseID = ""
                        notionTokenDraft = ""
                        notionDatabaseDraft = ""
                        preCallBriefsDatabaseID = ""
                        preCallBriefDatabaseDraft = ""
                    }
                    .foregroundColor(.red)
                }
            }

            if let error = notionService.lastError {
                Section("Last error") {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            notionDatabaseDraft = notionService.databaseID
            preCallBriefDatabaseDraft = preCallBriefsDatabaseID.isEmpty ? PreCallBriefService.defaultDatabaseID : preCallBriefsDatabaseID
            // Don't pre-populate the token field — it's in Keychain and we want
            // to keep it opaque. Empty field = "leave existing token alone".
        }
    }

    // MARK: - Dashboard install subview

    @ViewBuilder
    private var dashboardInstallView: some View {
        let installURL = obsidianService.dashboardInstallURL()
        let isInstalled = obsidianService.dashboardIsInstalled()

        VStack(alignment: .leading, spacing: 8) {
            Text("Install a pre-built Dataview dashboard into your vault. It queries your Minutes meetings folder directly and shows: this week, open action items, recent decisions, people you talk to most, and who you're losing touch with.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let installURL {
                HStack(spacing: 4) {
                    Text("Install location:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(installURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Install location unknown — is Minutes' `[vault]` section configured?")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            HStack(spacing: 8) {
                if isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)

                    Spacer()

                    Button("Open in Obsidian") {
                        if let url = installURL {
                            obsidianService.openMeetingNote(at: url)
                        }
                    }
                    .controlSize(.small)

                    Button("Reinstall") {
                        confirmReinstallDashboard()
                    }
                    .controlSize(.small)
                } else {
                    Spacer()
                    Button("Install Meetings Dashboard") {
                        installDashboard()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(installURL == nil)
                }
            }

            Text("Requires the Dataview and Tasks community plugins to render the queries.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func installDashboard() {
        guard let url = obsidianService.installDashboard() else { return }
        // Offer to open it immediately
        let alert = NSAlert()
        alert.messageText = "Dashboard installed"
        alert.informativeText = "Written to \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).\n\nMake sure you've enabled the Dataview and Tasks community plugins in Obsidian, then open the file to see live meeting data."
        alert.addButton(withTitle: "Open in Obsidian")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            obsidianService.openMeetingNote(at: url)
        }
    }

    private func confirmReinstallDashboard() {
        let alert = NSAlert()
        alert.messageText = "Reinstall dashboard?"
        alert.informativeText = "The existing Meetings Dashboard file will be overwritten. Any local edits you've made to it will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            installDashboard()
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Save the Notion token + database ID drafts (if present), then immediately
    /// test the connection. This is the single-button UX: the user enters fields
    /// and clicks once.
    private func saveAndTestNotion() {
        let trimmedToken = notionTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDB = notionDatabaseDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
        let trimmedBriefDB = preCallBriefDatabaseDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")

        if !trimmedDB.isEmpty {
            notionService.databaseID = trimmedDB
        }
        if !trimmedBriefDB.isEmpty {
            preCallBriefsDatabaseID = trimmedBriefDB
        }
        if !trimmedToken.isEmpty {
            // setAPIToken calls testConnection internally — don't double-fire.
            notionService.setAPIToken(trimmedToken)
            notionTokenDraft = ""  // clear the secure field after saving
        } else {
            Task { await notionService.testConnection() }
        }
    }

    private func chooseMinutesBinary() {
        let panel = NSOpenPanel()
        panel.title = "Choose the minutes binary"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            minutesService.setBinaryPath(url)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }

    // MARK: - Helpers

    private func alertTierBinding(for tier: AlertTier) -> Binding<Bool> {
        Binding(
            get: { tier.isEnabled },
            set: { UserDefaults.standard.set($0, forKey: tier.settingsKey) }
        )
    }

    private func calendarBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: { enabledCalendarIDs.contains(calendarID) },
            set: { enabled in
                if enabled {
                    enabledCalendarIDs.insert(calendarID)
                } else {
                    enabledCalendarIDs.remove(calendarID)
                }
                saveCalendarSelection()
            }
        )
    }

    private func loadSettings() {
        let ids = UserDefaults.standard.stringArray(forKey: "enabledCalendarIDs") ?? []
        enabledCalendarIDs = Set(ids)
        checklistItems = ChecklistItem.load()

        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func saveCalendarSelection() {
        UserDefaults.standard.set(Array(enabledCalendarIDs), forKey: "enabledCalendarIDs")
        calendarService.fetchEvents()
    }

    private func addChecklistItem() {
        let text = newChecklistText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        checklistItems.append(ChecklistItem(text: text))
        ChecklistItem.save(checklistItems)
        newChecklistText = ""
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
            }
        }
    }
}

enum OverlayBackground: String, CaseIterable, Identifiable {
    case dark
    case blue
    case purple
    case gradient
    case red
    case green
    case nightOcean
    case electric
    case cyber

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .gradient: return "Sunset"
        case .red: return "Red"
        case .green: return "Green"
        case .nightOcean: return "Night Ocean"
        case .electric: return "Electric"
        case .cyber: return "Cyber"
        }
    }

    var previewGradient: AnyShapeStyle {
        switch self {
        case .dark:
            return AnyShapeStyle(Color.black.opacity(0.85))
        case .blue:
            return AnyShapeStyle(
                LinearGradient(colors: [Color(red: 0.05, green: 0.1, blue: 0.3).opacity(0.88),
                                        Color(red: 0.1, green: 0.2, blue: 0.5).opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
            )
        case .purple:
            return AnyShapeStyle(
                LinearGradient(colors: [Color(red: 0.2, green: 0.05, blue: 0.3).opacity(0.88),
                                        Color(red: 0.4, green: 0.1, blue: 0.5).opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
            )
        case .gradient:
            return AnyShapeStyle(
                LinearGradient(colors: [Color(red: 0.1, green: 0.05, blue: 0.2).opacity(0.88),
                                        Color(red: 0.4, green: 0.1, blue: 0.2).opacity(0.88),
                                        Color(red: 0.6, green: 0.2, blue: 0.1).opacity(0.88)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        case .red:
            return AnyShapeStyle(
                LinearGradient(colors: [Color(red: 0.3, green: 0.02, blue: 0.02).opacity(0.88),
                                        Color(red: 0.5, green: 0.05, blue: 0.05).opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
            )
        case .green:
            return AnyShapeStyle(
                LinearGradient(colors: [Color(red: 0.02, green: 0.15, blue: 0.1).opacity(0.88),
                                        Color(red: 0.05, green: 0.3, blue: 0.15).opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
            )
        case .nightOcean:
            return AnyShapeStyle(
                LinearGradient(colors: [Color(red: 0.039, green: 0.055, blue: 0.078).opacity(0.92),
                                        Color(red: 0.067, green: 0.094, blue: 0.129).opacity(0.90),
                                        Color(red: 0.106, green: 0.149, blue: 0.196).opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
            )
        case .electric:
            return AnyShapeStyle(
                LinearGradient(colors: [Color(red: 0.059, green: 0.09, blue: 0.165).opacity(0.92),
                                        Color(red: 0.118, green: 0.161, blue: 0.231).opacity(0.90),
                                        Color(red: 0.2, green: 0.255, blue: 0.333).opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
            )
        case .cyber:
            return AnyShapeStyle(
                LinearGradient(colors: [Color(red: 0.02, green: 0.02, blue: 0.02).opacity(0.93),
                                        Color(red: 0.051, green: 0.067, blue: 0.09).opacity(0.91),
                                        Color(red: 0.086, green: 0.106, blue: 0.133).opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
    }
}
