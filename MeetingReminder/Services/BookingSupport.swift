import Foundation

struct PendingBooking: Decodable {
    let id: String
    let startUTC: Date
    let endUTC: Date
    let status: String
    let bookerName: String
    let bookerEmail: String
    let eventTypeID: String?
    let ekEventID: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case startUTC = "start_utc"
        case endUTC = "end_utc"
        case bookerName = "booker_name"
        case bookerEmail = "booker_email"
        case eventTypeID = "event_type_id"
        case ekEventID = "ek_event_id"
    }

    static func decodeList(_ data: Data) throws -> [PendingBooking] {
        let dec = JSONDecoder()
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()
        noFrac.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = withFrac.date(from: s) ?? noFrac.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad date \(s)"))
        }
        return try dec.decode([PendingBooking].self, from: data)
    }
}
