import EventKit
import Foundation

struct MeetingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendar: String
    let calendarColor: String
    let videoLink: URL?
    let isAllDay: Bool
    let attendees: [String]?
    let notes: String?
    let location: String?
    /// Exchange/ICS cross-system UID (`calendarItemExternalIdentifier`) — the key the
    /// Notion Calendar Events DB and the briefing skill match on, unlike the local `id`.
    let externalID: String?
    /// True if the event is part of a recurring series (drives the `_YYYY-MM-DD`
    /// occurrence-suffix convention when building the Notion "Apple Event ID").
    let isRecurring: Bool

    var timeUntilStart: TimeInterval {
        startDate.timeIntervalSinceNow
    }

    var timeUntilEnd: TimeInterval {
        endDate.timeIntervalSinceNow
    }

    var minutesUntilStart: Int {
        Int(ceil(timeUntilStart / 60))
    }

    var isHappeningSoon: Bool {
        timeUntilStart > 0 && timeUntilStart <= 600
    }

    var isInProgress: Bool {
        let now = Date()
        return now >= startDate && now < endDate
    }

    var hasEnded: Bool {
        Date() >= endDate
    }

    var durationMinutes: Int {
        Int(endDate.timeIntervalSince(startDate) / 60)
    }

    var formattedStartTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: startDate)
    }

    var formattedEndTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: endDate)
    }

    var formattedTimeUntil: String {
        let totalMinutes = minutesUntilStart
        if totalMinutes <= 0 {
            return "Now"
        } else if totalMinutes == 1 {
            return "1 minute"
        } else if totalMinutes < 60 {
            return "\(totalMinutes) minutes"
        } else {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if minutes == 0 {
                return "\(hours) h"
            } else {
                return "\(hours) h \(minutes) min"
            }
        }
    }

    /// Short format for menu bar: "12m", "1h 5m"
    var shortTimeUntil: String {
        let totalMinutes = minutesUntilStart
        if totalMinutes <= 0 {
            return "now"
        } else if totalMinutes < 60 {
            return "\(totalMinutes)m"
        } else {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if minutes == 0 {
                return "\(hours)h"
            } else {
                return "\(hours)h \(minutes)m"
            }
        }
    }

    static func == (lhs: MeetingEvent, rhs: MeetingEvent) -> Bool {
        lhs.id == rhs.id
    }

    init(from ekEvent: EKEvent, videoLink: URL?) {
        // Use eventIdentifier + startDate to uniquely identify recurring event occurrences
        let baseID = ekEvent.eventIdentifier ?? UUID().uuidString
        let dateStamp = ISO8601DateFormatter().string(from: ekEvent.startDate)
        self.id = "\(baseID)_\(dateStamp)"
        self.title = ekEvent.title ?? "Untitled Meeting"
        self.startDate = ekEvent.startDate
        self.endDate = ekEvent.endDate
        self.calendar = ekEvent.calendar.title
        self.calendarColor = ""
        self.videoLink = videoLink
        self.isAllDay = ekEvent.isAllDay
        self.notes = ekEvent.notes
        self.location = ekEvent.location
        self.externalID = ekEvent.calendarItemExternalIdentifier
        self.isRecurring = ekEvent.hasRecurrenceRules

        // Extract attendee names
        if let ekAttendees = ekEvent.attendees {
            self.attendees = ekAttendees.compactMap { attendee in
                attendee.name ?? attendee.url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
            }
        } else {
            self.attendees = nil
        }
    }

    init(id: String, title: String, startDate: Date, endDate: Date,
         calendar: String, calendarColor: String = "",
         videoLink: URL? = nil, isAllDay: Bool = false,
         attendees: [String]? = nil, notes: String? = nil, location: String? = nil,
         externalID: String? = nil, isRecurring: Bool = false) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendar = calendar
        self.calendarColor = calendarColor
        self.videoLink = videoLink
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.notes = notes
        self.location = location
        self.externalID = externalID
        self.isRecurring = isRecurring
    }
}
