import Foundation

// MARK: - Event Type

struct CalComEventType: Codable, Identifiable {
    let id: Int
    let title: String
    let slug: String
    let description: String?
    let lengthInMinutes: Int
    let lengthInMinutesOptions: [Int]?
    let minimumBookingNotice: Int?
    let beforeEventBuffer: Int?
    let afterEventBuffer: Int?
    let hidden: Bool?
    let bookingUrl: String?
    let bookingFields: [CalComBookingField]?
}

struct CalComBookingField: Codable, Identifiable {
    let slug: String
    let label: String?
    let type: String
    let required: Bool?
    let isDefault: Bool?
    let hidden: Bool?
    var id: String { slug }
}

struct CalComEventTypeInput: Codable {
    var title: String?
    var slug: String?
    var description: String?
    var lengthInMinutes: Int?
    var minimumBookingNotice: Int?
    var beforeEventBuffer: Int?
    var afterEventBuffer: Int?
    var hidden: Bool?
}

// MARK: - Schedule

struct CalComSchedule: Codable, Identifiable {
    let id: Int
    let name: String
    let timeZone: String
    let isDefault: Bool?
    let availability: [CalComAvailabilityWindow]?
}

struct CalComAvailabilityWindow: Codable {
    let days: [String]
    let startTime: String
    let endTime: String
}

// MARK: - Booking

struct CalComBooking: Codable, Identifiable {
    let uid: String
    let title: String?
    let start: String
    let end: String
    let status: String
    let attendees: [CalComAttendee]?
    let location: String?
    let eventTypeId: Int?
    var id: String { uid }

    var startDate: Date? { ISO8601DateFormatter().date(from: start) }
    var endDate: Date? { ISO8601DateFormatter().date(from: end) }
}

struct CalComAttendee: Codable {
    let name: String
    let email: String
    let timeZone: String?
}

// MARK: - API response wrappers

struct CalComListResponse<T: Codable>: Codable {
    let status: String
    let data: [T]?
}

struct CalComSingleResponse<T: Codable>: Codable {
    let status: String
    let data: T?
}

// MARK: - Errors

enum CalComError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case httpError(Int, String)
    case decodingError(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:              return "Cal.com API key not configured"
        case .invalidURL:                 return "Invalid Cal.com API URL"
        case .httpError(let c, let b):    return "HTTP \(c)\(b.isEmpty ? "" : ": \(b)")"
        case .decodingError(let s):       return "Decode error: \(s)"
        case .unauthorized:               return "Unauthorized — check your Cal.com API key"
        }
    }
}
