import Foundation
import UserNotifications

/// Handles system notification delivery for progressive alerts
@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private init() {}

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("Notification permission error: \(error)")
            return false
        }
    }

    /// Post a banner notification for an upcoming meeting
    func postMeetingBanner(eventID: String, title: String, minutesUntil: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting in \(minutesUntil) min"
        content.body = title
        content.sound = .default
        content.categoryIdentifier = "MEETING_REMINDER"

        let request = UNNotificationRequest(
            identifier: "meeting-banner-\(eventID)-\(minutesUntil)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Failed to post notification: \(error)")
            }
        }
    }

    /// Post a wrap-up notification
    func postWrapUpBanner(eventID: String, title: String, minutesUntil: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Start wrapping up"
        content.body = "\(title) in \(minutesUntil) min"
        content.sound = nil // Ambient — no sound

        let request = UNNotificationRequest(
            identifier: "meeting-wrapup-\(eventID)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Post a break reminder between back-to-back meetings
    func postBreakReminder(nextMeetingTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Take a breather"
        content.body = "Quick break before \(nextMeetingTitle)"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "meeting-break-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Post a post-meeting nudge
    func postPostMeetingNudge(eventID: String, title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Capture action items?"
        content.body = "Meeting ended: \(title)"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "meeting-post-\(eventID)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)
        )

        UNUserNotificationCenter.current().add(request)
    }

    func removeNotifications(for eventID: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [
            "meeting-banner-\(eventID)",
            "meeting-wrapup-\(eventID)",
            "meeting-post-\(eventID)",
        ])
    }
}
