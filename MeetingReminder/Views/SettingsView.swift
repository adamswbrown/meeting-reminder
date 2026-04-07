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
    @ObservedObject var calendarService: CalendarService
    @ObservedObject var notionService: NotionService

    @State private var launchAtLogin = false
    @State private var enabledCalendarIDs: Set<String> = []
    @State private var notionTokenInput: String = ""
    @State private var notionDatabaseInput: String = ""
    @State private var checklistItems: [ChecklistItem] = []
    @State private var newChecklistText: String = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            alertsTab
                .tabItem { Label("Alerts", systemImage: "bell.badge") }

            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            checklistTab
                .tabItem { Label("Checklist", systemImage: "checklist") }

            calendarsTab
                .tabItem { Label("Calendars", systemImage: "calendar") }

            notionTab
                .tabItem { Label("Notion", systemImage: "doc.text") }
        }
        .frame(width: 520, height: 440)
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
                SecureField("API Token", text: $notionTokenInput)
                    .onSubmit { notionService.setAPIToken(notionTokenInput) }
                TextField("Database ID", text: $notionDatabaseInput)
                    .onChange(of: notionDatabaseInput) { newValue in
                        notionService.databaseID = newValue
                    }

                HStack {
                    Button("Test Connection") {
                        if !notionTokenInput.isEmpty {
                            notionService.setAPIToken(notionTokenInput)
                        }
                        Task { await notionService.testConnection() }
                    }
                    .controlSize(.small)

                    Spacer()

                    if notionService.isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.callout)
                    } else if let error = notionService.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }

                if let dbName = notionService.databaseName {
                    HStack {
                        Text("Database:")
                            .foregroundColor(.secondary)
                        Text(dbName)
                            .fontWeight(.medium)
                    }
                    .font(.callout)
                }
            }

            Section("Features") {
                Text("When connected, Meeting Reminder will:")
                    .font(.callout)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    featureRow(icon: "doc.badge.plus", text: "Auto-create a meeting notes page when the reminder fires")
                    featureRow(icon: "safari", text: "Open the notes page in your browser")
                    featureRow(icon: "checkmark.square", text: "Surface action items after the meeting ends")
                }
            }

            Section {
                Button("Clear Token") {
                    notionService.clearAPIToken()
                    notionTokenInput = ""
                }
                .foregroundColor(.red)
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .padding()
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
        notionDatabaseInput = notionService.databaseID

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
