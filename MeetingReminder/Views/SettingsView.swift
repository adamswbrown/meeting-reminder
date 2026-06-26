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
    @ObservedObject var notionService: NotionService
    @ObservedObject var calendarNotionSync: CalendarNotionSyncService
    @ObservedObject var availabilityPushService: AvailabilityPushService
    @ObservedObject var graphMailService: GraphMailService
    @ObservedObject var bookingPollService: BookingPollService
    @ObservedObject var busyLightService: BusyLightService
    @AppStorage("preCallBriefsDatabaseID") private var preCallBriefsDatabaseID: String = ""

    @State private var launchAtLogin = false
    @State private var enabledCalendarIDs: Set<String> = []
    @State private var checklistItems: [ChecklistItem] = []
    @State private var newChecklistText: String = ""
    @State private var availableScreens: [NSScreen] = []
    @State private var notionTokenDraft: String = ""
    @State private var notionDatabaseDraft: String = ""
    @State private var preCallBriefDatabaseDraft: String = ""
    @State private var calendarSyncEnabledDraft: Bool = false
    @State private var rollingWeekViewDraft: String = ""
    @State private var calendarSyncEnabledCalendarIDs: Set<String> = []
    @State private var supabaseURLDraft: String = ""
    @State private var supabaseKeyDraft: String = ""

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

            availabilityTab
                .tabItem { Label("Availability", systemImage: "globe") }

            calendarSyncTab
                .tabItem { Label("Cal Sync", systemImage: "arrow.triangle.2.circlepath") }

            BusyLightSettingsView(service: busyLightService)
                .tabItem { Label("Busy Light", systemImage: "lightbulb.fill") }
        }
        .frame(width: 720, height: 520)
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

    // MARK: - Availability Tab

    private var availabilityTab: some View {
        Form {
            Section("Status") {
                HStack {
                    if availabilityPushService.isSyncing {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Syncing…").foregroundColor(.secondary)
                    } else if !availabilityPushService.isConfigured {
                        Label("Not configured", systemImage: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    } else if !availabilityPushService.isEnabled {
                        Label("Paused", systemImage: "pause.circle.fill")
                            .foregroundColor(.orange)
                    } else if let last = availabilityPushService.lastSyncDate {
                        Label("Synced", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("— \(availabilityPushService.lastSyncCount) events, \(relativeTimeString(last)) ago")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        Label("Idle", systemImage: "clock")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                Text("Pushes the next \(availabilityPushService.windowDays) days of your free/busy state to Supabase every \(availabilityPushService.intervalMinutes) minutes. A public Vercel page can read the sanitised view (no titles, no attendees) to show when you're free. The push only runs while this Mac is awake.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable availability push", isOn: $availabilityPushService.isEnabled)
            }

            Section("Supabase project") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        TextField("https://<ref>.supabase.co", text: $supabaseURLDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Paste") {
                            if let s = NSPasteboard.general.string(forType: .string) {
                                supabaseURLDraft = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Service-role key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        SecureField("eyJ… (Settings → API → service_role)", text: $supabaseKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Paste") {
                            if let s = NSPasteboard.general.string(forType: .string) {
                                supabaseKeyDraft = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .controlSize(.small)
                    }
                    Text("Stored in Keychain. Never sent anywhere except your own Supabase project.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Save & Sync now") {
                        saveAndSyncAvailability()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(availabilityPushService.isSyncing)

                    Spacer()

                    Button("Clear") {
                        availabilityPushService.clearCredentials()
                        availabilityPushService.isEnabled = false
                        supabaseURLDraft = ""
                        supabaseKeyDraft = ""
                    }
                    .foregroundColor(.red)
                }
            }

            Section("Schedule") {
                Picker("Push every", selection: Binding(
                    get: { availabilityPushService.intervalMinutes },
                    set: { availabilityPushService.intervalMinutes = $0 }
                )) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                .pickerStyle(.menu)

                Picker("Look ahead", selection: Binding(
                    get: { availabilityPushService.windowDays },
                    set: { availabilityPushService.windowDays = $0 }
                )) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("21 days").tag(21)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.menu)
            }

            if let error = availabilityPushService.lastError {
                Section("Last error") {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }
            }

            Section("Exchange sending") {
                HStack {
                    if graphMailService.isConnected {
                        Label("Connected", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        if let email = graphMailService.connectedEmail {
                            Text("— \(email)")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Label("Not connected", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    Spacer()
                }

                Text("Booking emails send from your Exchange account via Microsoft Graph — no Mail.app, no admin, works while this Mac is awake. If the sign-in lapses, the app falls back to Mail.app (which needs the Exchange account enabled there) and never sends from another account.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if graphMailService.isConnecting {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Waiting for sign-in…").foregroundColor(.secondary)
                        }
                        if let code = graphMailService.deviceCodeUserCode {
                            Text("Go to \(graphMailService.deviceCodeVerificationURI ?? "https://login.microsoft.com/device") and enter:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(code)
                                .font(.title3.monospaced().bold())
                                .textSelection(.enabled)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button(graphMailService.isConnected ? "Reconnect" : "Connect Exchange") {
                        Task { await graphMailService.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(graphMailService.isConnecting)

                    if graphMailService.isConnected {
                        Spacer()
                        Button("Disconnect") { graphMailService.disconnect() }
                            .foregroundColor(.red)
                    }
                }

                if let error = graphMailService.lastAuthError {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Booking") {
                Text("Polls the booking page's pending requests every 60s, creates a calendar event for each free slot, and emails a confirmation (or a rejection if the slot is no longer free). Sending uses the Exchange connection above. Uses the same Supabase project URL + service-role key as the availability push.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable booking confirmations", isOn: $bookingPollService.isEnabled)

                HStack {
                    if let last = bookingPollService.lastPollDate {
                        Label("Last checked", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("— \(relativeTimeString(last)) ago\(bookingPollService.lastResult.map { " (\($0))" } ?? "")")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else if !bookingPollService.isConfigured {
                        Label("Not configured", systemImage: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    } else {
                        Label("Idle", systemImage: "clock")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                if let error = bookingPollService.lastError {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            supabaseURLDraft = availabilityPushService.projectURL
            // Leave key field blank — Keychain value stays opaque.
        }
    }

    private func saveAndSyncAvailability() {
        let trimmedURL = supabaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = supabaseKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedURL.isEmpty {
            availabilityPushService.projectURL = trimmedURL
        }
        if !trimmedKey.isEmpty {
            availabilityPushService.setServiceRoleKey(trimmedKey)
            supabaseKeyDraft = ""
        }

        // Push once immediately, then (re)start the timer so subsequent
        // pushes happen on schedule. start() no-ops if disabled.
        Task { await availabilityPushService.pushNow() }
        if availabilityPushService.isEnabled {
            availabilityPushService.start()
        }
    }

    private func relativeTimeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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
            // The Cal Sync service shares this token (same Keychain entry). Its
            // daily timer and reactive watcher gate on `isConfigured`, so a
            // token saved *after* enabling those toggles would otherwise stay
            // inert until the next launch. Re-run the scheduler now so they
            // activate immediately.
            calendarNotionSync.startScheduleIfEnabled()
        } else {
            Task { await notionService.testConnection() }
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
        calendarSyncEnabledDraft = calendarNotionSync.isEnabled
        rollingWeekViewDraft = calendarNotionSync.rollingWeekViewID
        calendarSyncEnabledCalendarIDs = Set(
            UserDefaults.standard.stringArray(forKey: CalendarSyncConstants.prefEnabledCalendarIDsKey) ?? []
        )

        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Calendar → Notion Sync Tab

    private var calendarSyncTab: some View {
        calendarSyncForm
            .onAppear {
                // Re-pull every time the tab appears so a defaults-write or a
                // change from another window is reflected in the field.
                rollingWeekViewDraft = calendarNotionSync.rollingWeekViewID
                calendarSyncEnabledDraft = calendarNotionSync.isEnabled
                calendarSyncEnabledCalendarIDs = Set(
                    UserDefaults.standard.stringArray(forKey: CalendarSyncConstants.prefEnabledCalendarIDsKey) ?? []
                )
            }
    }

    private var calendarSyncForm: some View {
        Form {
            Section {
                if let last = calendarNotionSync.lastRunAt {
                    LabeledContent("Last run", value: last.formatted(date: .abbreviated, time: .standard))
                } else {
                    LabeledContent("Last run", value: "never")
                }
                if let result = calendarNotionSync.lastResult {
                    LabeledContent("Result", value: result)
                }
                if calendarNotionSync.isRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Syncing…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Status")
            }

            Section {
                HStack {
                    Image(systemName: calendarNotionSync.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(calendarNotionSync.isConfigured ? .green : .orange)
                    Text(calendarNotionSync.isConfigured
                         ? "Using the Notion token from the Notion tab."
                         : "No Notion token set. Add one in the Notion tab first.")
                }
            } header: {
                Text("Notion Token")
            } footer: {
                Text("This sync reuses the token from the Notion tab. Make sure that integration has access to the Operations parent page in Notion (the Calendar Events and Skip List databases live under it).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Run daily at 06:00", isOn: $calendarSyncEnabledDraft)
                    .onChange(of: calendarSyncEnabledDraft) { newValue in
                        calendarNotionSync.isEnabled = newValue
                    }
            } header: {
                Text("Schedule")
            }

            Section {
                if calendarService.availableCalendars.isEmpty {
                    Text("Grant Calendar access first (Calendars tab) to choose calendars to sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(calendarService.availableCalendars, id: \.calendarIdentifier) { cal in
                        Toggle(isOn: Binding(
                            get: { calendarSyncEnabledCalendarIDs.contains(cal.calendarIdentifier) },
                            set: { isOn in
                                if isOn {
                                    calendarSyncEnabledCalendarIDs.insert(cal.calendarIdentifier)
                                } else {
                                    calendarSyncEnabledCalendarIDs.remove(cal.calendarIdentifier)
                                }
                                UserDefaults.standard.set(
                                    Array(calendarSyncEnabledCalendarIDs),
                                    forKey: CalendarSyncConstants.prefEnabledCalendarIDsKey
                                )
                            }
                        )) {
                            HStack {
                                Text(cal.title)
                                Spacer()
                                Text(cal.source.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Calendars to Sync")
            } footer: {
                Text("Tick each calendar to include in the Notion sync. When nothing is ticked, the sync falls back to the single Exchange calendar (v1 behaviour).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Archive orphaned rows",
                       isOn: Binding(get: { calendarNotionSync.archiveOrphansEnabled },
                                     set: { calendarNotionSync.archiveOrphansEnabled = $0 }))
                Toggle("Skip Free / Out-of-Office events",
                       isOn: Binding(get: { calendarNotionSync.skipFreeAndOOOEnabled },
                                     set: { calendarNotionSync.skipFreeAndOOOEnabled = $0 }))
                Toggle("Auto-link Meeting Notes & Pre-Call Briefings",
                       isOn: Binding(get: { calendarNotionSync.autoLinkRelationsEnabled },
                                     set: { calendarNotionSync.autoLinkRelationsEnabled = $0 }))
                Toggle("Watch for changes (reactive sync)",
                       isOn: Binding(get: { calendarNotionSync.reactiveEnabled },
                                     set: { calendarNotionSync.reactiveEnabled = $0 }))
            } header: {
                Text("Cleanup")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Archive orphaned rows: rows in Notion whose source calendar event has disappeared get classified as Orphaned and archived. Rows with manual Meeting Notes or Pre-Call Briefing relations are marked Stale instead — never archived. Both states are reversible from Notion.")
                    Text("Skip Free / OOO: drops events marked Free or Out of Office (e.g. Annual Leave) before they reach Notion. Off by default — keeps holidays in the ledger.")
                    Text("Auto-link: after each upsert, query Meeting Notes and Pre-Call Briefings for a single same-day-same-title match and link it. Append-only — manual links are never overwritten. Ambiguous matches (>1 candidate) are skipped with a log warning.")
                    Text("Watch for changes (reactive sync): sync changed events to Notion within ~2 min of a calendar change, instead of waiting for the daily 06:00 run. Feeds Co-Work pre-call briefs via a Notion automation.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                TextField("Notion view URL or UUID",
                          text: Binding(
                            get: { calendarNotionSync.rollingWeekViewID },
                            set: { calendarNotionSync.rollingWeekViewID = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                          ))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Paste from clipboard") {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            calendarNotionSync.rollingWeekViewID = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    Button("Patch now") {
                        Task { await calendarNotionSync.patchRollingWeekNow() }
                    }
                    .disabled(!calendarNotionSync.isConfigured || calendarNotionSync.rollingWeekViewID.isEmpty)
                    if !calendarNotionSync.rollingWeekViewID.isEmpty {
                        Spacer()
                        Button("Clear") {
                            calendarNotionSync.rollingWeekViewID = ""
                        }
                    }
                }
            } header: {
                Text("Rolling-Week View")
            } footer: {
                Text("Optional. When set, every sync run also patches this Notion view's filter to \"Date is within Mon–Sun (Europe/London) of the current week\". Paste the view URL (with the ?v=… parameter) or the bare view UUID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Sync Now") {
                        Task { await calendarNotionSync.runNow(dryRun: false) }
                    }
                    .disabled(!calendarNotionSync.isConfigured || calendarNotionSync.isRunning)
                    Button("Dry Run") {
                        Task { await calendarNotionSync.runNow(dryRun: true) }
                    }
                    .disabled(!calendarNotionSync.isConfigured || calendarNotionSync.isRunning)
                    Button("Scan Duplicates") {
                        Task { await calendarNotionSync.scanForDuplicates() }
                    }
                    .disabled(!calendarNotionSync.isConfigured || calendarNotionSync.isRunning)
                    Spacer()
                    Button("Open Log") { calendarNotionSync.openLogFile() }
                }
            } header: {
                Text("Manual Trigger")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("One-way sync from Apple Calendar (Exchange) → Notion Calendar Events.")
                    Text("Existing rows are updated, never deleted. Manual relations to Meeting Notes and Pre-Call Briefings are preserved.")
                    Text("Trigger from anywhere with the URL meetingreminder://calsync (use in Apple Shortcuts).")
                        .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
