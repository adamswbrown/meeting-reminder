import Foundation

/// Creates a Notion meeting-notes page when CalComSyncService adds a new EKEvent
/// for an incoming Cal.com booking. No-ops if Notion isn't configured.
///
/// Keeps CalComSyncService focused on EventKit by extracting the Notion side-effect
/// into this thin coordinator. The bridge is optional in CalComSyncService.init —
/// passing nil disables it without changing any other behaviour.
@MainActor
final class CalComNotionBridge {
    private weak var notion: NotionService?

    init(notion: NotionService) {
        self.notion = notion
    }

    func createPageIfNeeded(for booking: CalComBooking) async {
        guard let notion, notion.isConfigured else { return }
        guard let start = booking.startDate, let end = booking.endDate else { return }

        // Construct a MeetingEvent so we can reuse NotionService's find-or-create
        // path — the same one meeting join uses, including its dedup guard.
        // "calcom-<uid>" is stable across sync runs, and is the key NotionService
        // derives for the tagged EKEvent too (`noteKey`), so joining the meeting
        // later finds this page instead of creating a second one.
        let attendeeNames = booking.attendees?.map { "\($0.name) <\($0.email)>" }
        let videoLink = booking.location.flatMap { URL(string: $0) }
        let event = MeetingEvent(
            id: "calcom-\(booking.uid)",
            title: booking.title ?? "Meeting",
            startDate: start,
            endDate: end,
            calendar: "Cal.com",
            videoLink: videoLink,
            attendees: attendeeNames,
            location: booking.location
        )
        _ = await notion.findOrCreateMeetingPage(for: event)
    }
}
