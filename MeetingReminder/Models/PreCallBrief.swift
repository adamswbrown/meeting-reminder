import Foundation

/// A matched pre-call brief fetched from the Notion "Pre-Call Briefings" database.
struct PreCallBrief: Equatable {
    let pageID: String
    let pageURL: URL
    let title: String
    let customerPartner: String?
    let date: Date?
    let attendees: String?
    let briefingStatus: String?
    /// Rendered markdown body of the page.
    let markdown: String
}

/// Persistent record of which Notion page is attached to a calendar event.
/// Stored in UserDefaults under `preCallBriefMatches` as JSON dict keyed by eventID.
struct BriefMatch: Codable, Equatable {
    let pageID: String
    let pageURL: String
    let title: String
    let matchedAt: Date
    /// true when the user manually attached; protects from being overwritten by auto-match.
    let userAttached: Bool
}

/// Lightweight summary of a brief page used in the "Attach brief…" picker.
struct BriefSummary: Identifiable, Equatable {
    let pageID: String
    let pageURL: URL
    let title: String
    let customerPartner: String?
    let date: Date?

    var id: String { pageID }
}
