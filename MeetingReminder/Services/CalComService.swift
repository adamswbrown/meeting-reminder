import Foundation

/// REST wrapper around https://api.cal.com/v2/
/// API key is stored in Keychain as `calComAPIKey`.
@MainActor
final class CalComService: ObservableObject {

    static let keychainKey = "calComAPIKey"
    private static let baseURL = "https://api.cal.com/v2"
    private static let eventTypeVersion = "2024-06-14"
    private static let bookingVersion = "2024-08-13"
    private static let scheduleVersion = "2024-06-11"

    // MARK: - Key management

    var apiKey: String? {
        KeychainHelper.read(key: Self.keychainKey)
    }

    var isConfigured: Bool {
        guard let k = apiKey else { return false }
        return !k.isEmpty
    }

    func saveAPIKey(_ key: String) {
        if key.isEmpty {
            KeychainHelper.delete(key: Self.keychainKey)
        } else {
            KeychainHelper.save(key: Self.keychainKey, value: key)
        }
    }

    func deleteAPIKey() {
        KeychainHelper.delete(key: Self.keychainKey)
    }

    // MARK: - Event Types

    func fetchEventTypes() async throws -> [CalComEventType] {
        let data = try await get(path: "/event-types", version: Self.eventTypeVersion)
        let resp = try decode(CalComListResponse<CalComEventType>.self, from: data)
        return resp.data ?? []
    }

    func updateEventType(id: Int, input: CalComEventTypeInput) async throws -> CalComEventType {
        let body = try JSONEncoder().encode(input)
        let data = try await patch(path: "/event-types/\(id)", version: Self.eventTypeVersion, body: body)
        let resp = try decode(CalComSingleResponse<CalComEventType>.self, from: data)
        guard let et = resp.data else { throw CalComError.decodingError("no data in response") }
        return et
    }

    // MARK: - Schedules

    func fetchSchedules() async throws -> [CalComSchedule] {
        let data = try await get(path: "/schedules", version: Self.scheduleVersion)
        let resp = try decode(CalComListResponse<CalComSchedule>.self, from: data)
        return resp.data ?? []
    }

    // MARK: - Bookings

    func fetchUpcomingBookings(after: Date? = nil) async throws -> [CalComBooking] {
        var query = "status[]=upcoming&take=50"
        if let after {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            let iso = fmt.string(from: after)
            query += "&afterStart=\(iso.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? iso)"
        }
        let data = try await get(path: "/bookings?\(query)", version: Self.bookingVersion)
        let resp = try decode(CalComListResponse<CalComBooking>.self, from: data)
        return resp.data ?? []
    }

    func cancelBooking(uid: String, reason: String? = nil) async throws {
        var payload: [String: String] = [:]
        if let reason { payload["cancellationReason"] = reason }
        let body = try JSONEncoder().encode(payload)
        _ = try await deleteRequest(path: "/bookings/\(uid)", version: Self.bookingVersion, body: body)
    }

    // MARK: - Connection test

    func testConnection() async throws -> String {
        let types = try await fetchEventTypes()
        return "Connected — \(types.count) event type\(types.count == 1 ? "" : "s")"
    }

    // MARK: - HTTP helpers

    private func get(path: String, version: String) async throws -> Data {
        guard let key = apiKey else { throw CalComError.missingAPIKey }
        guard let url = URL(string: Self.baseURL + path) else { throw CalComError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "cal-api-version")
        return try await send(req)
    }

    private func patch(path: String, version: String, body: Data) async throws -> Data {
        guard let key = apiKey else { throw CalComError.missingAPIKey }
        guard let url = URL(string: Self.baseURL + path) else { throw CalComError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "cal-api-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await send(req)
    }

    private func deleteRequest(path: String, version: String, body: Data) async throws -> Data {
        guard let key = apiKey else { throw CalComError.missingAPIKey }
        guard let url = URL(string: Self.baseURL + path) else { throw CalComError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "cal-api-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await send(req)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalComError.invalidURL }
        if http.statusCode == 401 { throw CalComError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CalComError.httpError(http.statusCode, body)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CalComError.decodingError(error.localizedDescription)
        }
    }
}
