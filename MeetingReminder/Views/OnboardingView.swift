import EventKit
import SwiftUI
import UserNotifications

struct OnboardingView: View {
    @ObservedObject var calendarService: CalendarService
    let onComplete: () -> Void

    @State private var currentStep = 0
    @State private var calendarGranted = false
    @State private var notificationsGranted = false
    @State private var notificationsDenied = false

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

            // Steps
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: calendarStep
                case 2: notificationStep
                case 3: doneStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 440)
        .onAppear {
            updatePermissionStates()
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Welcome to Meeting Reminder")
                .font(.title.bold())

            Text("Designed to help you stay on track with meetings — with progressive alerts, visual countdowns, and tools to support focus and transitions.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Text("Let's set up a few permissions so everything works smoothly.")
                .font(.callout)
                .foregroundColor(.secondary)

            Spacer()

            navigationButtons(backEnabled: false, nextLabel: "Get Started")
        }
        .padding(30)
    }

    // MARK: - Step 2: Calendar

    private var calendarStep: some View {
        VStack(spacing: 20) {
            Spacer()

            permissionIcon(granted: calendarGranted, systemImage: "calendar")

            Text("Calendar Access")
                .font(.title2.bold())

            Text("Meeting Reminder reads your calendar to show upcoming meetings, countdowns, and video call links. No data leaves your Mac.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if calendarGranted {
                permissionBadge(text: "Access Granted", color: .green)
            } else {
                Button("Grant Calendar Access") {
                    Task {
                        await calendarService.requestAccess()
                        updatePermissionStates()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()

            navigationButtons(
                backEnabled: true,
                nextLabel: "Continue",
                nextEnabled: calendarGranted
            )
        }
        .padding(30)
    }

    // MARK: - Step 3: Notifications

    private var notificationStep: some View {
        VStack(spacing: 20) {
            Spacer()

            permissionIcon(granted: notificationsGranted, systemImage: "bell.badge")

            Text("Notifications")
                .font(.title2.bold())

            Text("Progressive alerts send gentle banner notifications before meetings escalate to the full-screen overlay. This helps you wrap up without being startled.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if notificationsGranted {
                permissionBadge(text: "Notifications Enabled", color: .green)
            } else if notificationsDenied {
                VStack(spacing: 10) {
                    permissionBadge(text: "Notifications Denied", color: .orange)
                    Text("You previously denied notifications. You can enable them in System Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Notification Settings") {
                        openNotificationSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            } else {
                VStack(spacing: 8) {
                    Button("Enable Notifications") {
                        requestNotificationPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("This will show the standard macOS permission prompt.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            navigationButtons(
                backEnabled: true,
                nextLabel: notificationsGranted ? "Continue" : "Skip for Now"
            )
        }
        .padding(30)
    }

    // MARK: - Step 4: Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("You're All Set")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 10) {
                statusRow(icon: "calendar", text: "Calendar access", granted: calendarGranted)
                statusRow(icon: "bell.badge", text: "Notifications", granted: notificationsGranted)
            }
            .padding(20)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(12)

            Text("You can change any of these in Settings at any time.")
                .font(.callout)
                .foregroundColor(.secondary)

            Spacer()

            Button("Start Using Meeting Reminder") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(30)
    }

    // MARK: - Shared Components

    private func permissionIcon(granted: Bool, systemImage: String) -> some View {
        ZStack {
            Circle()
                .fill(granted ? Color.green.opacity(0.15) : Color.accentColor.opacity(0.1))
                .frame(width: 80, height: 80)
            Image(systemName: granted ? "checkmark.circle.fill" : systemImage)
                .font(.system(size: 40))
                .foregroundColor(granted ? .green : .accentColor)
        }
    }

    private func permissionBadge(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .cornerRadius(20)
    }

    private func statusRow(icon: String, text: String, granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 24)
            Text(text)
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "minus.circle")
                .foregroundColor(granted ? .green : .orange)
        }
    }

    private func navigationButtons(
        backEnabled: Bool = true,
        nextLabel: String = "Continue",
        nextEnabled: Bool = true
    ) -> some View {
        HStack {
            if backEnabled {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) { currentStep -= 1 }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button(nextLabel) {
                withAnimation(.easeInOut(duration: 0.2)) { currentStep += 1 }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!nextEnabled)
        }
    }

    // MARK: - Permission Helpers

    private func updatePermissionStates() {
        calendarGranted = calendarService.authorizationStatus == .authorized

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationsGranted = settings.authorizationStatus == .authorized
                notificationsDenied = settings.authorizationStatus == .denied
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                notificationsGranted = granted
                notificationsDenied = !granted
            }
        }
    }

    private func openNotificationSettings() {
        // Deep link to this app's notification settings
        if let bundleID = Bundle.main.bundleIdentifier,
           let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Onboarding Window Controller

/// Presents onboarding as a standalone, centered NSWindow — not a sheet on the menu bar popover.
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(calendarService: CalendarService) {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView(
            calendarService: calendarService,
            onComplete: { [weak self] in
                self?.close()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Meeting Reminder Setup"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating  // Above other windows so user doesn't lose it

        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}
