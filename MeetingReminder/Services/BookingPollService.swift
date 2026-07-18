import EventKit
import Foundation

/// Orchestration service (Task B5) that turns pending bookings in Supabase into
/// real EventKit calendar events + Mail.app confirmation/rejection emails.
///
/// Design notes:
///
/// - **Auth / config**: mirrors `AvailabilityPushService` exactly — reads the
///   Supabase project URL from UserDefaults (`supabaseProjectURL`) and the
///   service-role key from Keychain (`supabaseServiceRoleKey`). The service-role
///   key bypasses RLS; appropriate for a single-user personal tool where the key
///   never leaves the Mac.
/// - **Timer**: polls every 60s while enabled and configured. Same start/stop
///   pattern as `AvailabilityPushService`.
/// - **Idempotency**: for each booking we create the EKEvent and PATCH the row
///   to `confirmed` (carrying `ek_event_id`) *before* sending the email. If the
///   email fails the booking stays confirmed (the event exists) — we never roll
///   back. On the conflict check we exclude any event whose identifier matches
///   the booking's stored `ek_event_id`, so a re-poll of an already-created
///   event doesn't self-reject.
/// - **PATCH-fail recovery (I2)**: every created event is tagged with a
///   deterministic `[booking-id:<id>]` marker in its notes. At the start of
///   processing a pending booking we search EventKit for an event already bearing
///   that marker. If found (a prior attempt saved the event but failed before the
///   `confirmed` PATCH landed, so `ek_event_id` is still nil), we re-PATCH
///   `confirmed` against the existing event instead of creating a duplicate or
///   false-rejecting — and skip the email (the event already exists). The conflict
///   check also excludes the booking's own event by EITHER `ek_event_id` OR marker.
/// - **Resilience**: per-booking work is wrapped in do/catch so one bad booking
///   doesn't stop the others. The loop never crashes.
@MainActor
final class BookingPollService: ObservableObject {
    // MARK: - Published state

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }
    @Published var lastPollDate: Date?
    @Published var lastError: String?
    /// One-line summary of the last poll, e.g. `confirmed=1 rejected=0`.
    @Published var lastResult: String?

    // MARK: - Persistence keys

    private static let enabledKey = "bookingPollEnabled"
    private static let projectURLKey = "supabaseProjectURL"
    private static let serviceKeyKeychainKey = "supabaseServiceRoleKey"

    /// Poll cadence. 60s is comfortably responsive for a personal booking page
    /// and well within Supabase free-tier limits.
    static let pollIntervalSeconds: TimeInterval = 60

    // MARK: - Owner identity

    /// Display name + address used as the Mail.app sender and the ICS organizer.
    static let ownerSenderDisplay = "Adam Brown <adam.brown@altra.cloud>"
    static let ownerOrganizerEmail = "adam.brown@altra.cloud"

    // MARK: - Configuration

    var projectURL: String {
        UserDefaults.standard.string(forKey: Self.projectURLKey) ?? ""
    }

    var serviceRoleKey: String? {
        KeychainHelper.read(key: Self.serviceKeyKeychainKey)
    }

    var isConfigured: Bool {
        guard let key = serviceRoleKey else { return false }
        return !key.isEmpty && !projectURL.isEmpty
    }

    // MARK: - Internals

    private let eventStore: EKEventStore
    private let graph: GraphMailService
    private var timer: Timer?
    private var isPolling = false
    /// Debounces the "Exchange sign-in expired" notification to once per outage.
    private var graphReauthNotified = false

    init(eventStore: EKEventStore = EKEventStore(), graph: GraphMailService) {
        self.eventStore = eventStore
        self.graph = graph
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Lifecycle

    func start() {
        // Legacy Supabase poll — disabled when Cal.com API key is configured.
        guard KeychainHelper.read(key: CalComService.keychainKey) == nil else { return }
        stop()
        guard isEnabled, isConfigured else { return }

        // Fire one immediately so the user gets feedback that it's working.
        Task { await pollOnce() }

        timer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollOnce()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Poll

    func pollOnce() async {
        guard isConfigured else {
            lastError = "Not configured — set Supabase project URL + service-role key in Settings."
            return
        }
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        let pending: [PendingBooking]
        do {
            pending = try await fetchPending()
        } catch {
            lastError = error.localizedDescription
            lastPollDate = Date()
            return
        }

        var confirmed = 0
        var rejected = 0
        var failed = 0

        for booking in pending {
            do {
                let didConfirm = try await process(booking)
                if didConfirm { confirmed += 1 } else { rejected += 1 }
            } catch {
                failed += 1
                NSLog("[BookingPoll] booking \(booking.id) failed: \(error.localizedDescription)")
            }
        }

        lastPollDate = Date()
        lastResult = "confirmed=\(confirmed) rejected=\(rejected) failed=\(failed)"
        lastError = failed > 0 ? "\(failed) booking(s) failed — see Console log" : nil
    }

    /// Handle one booking. Returns true if confirmed, false if rejected.
    private func process(_ booking: PendingBooking) async throws -> Bool {
        let eventType = try? await fetchEventType(id: booking.eventTypeID)

        let title: String
        let bufferBefore: TimeInterval
        let bufferAfter: TimeInterval
        if let eventType {
            title = eventType.title
            bufferBefore = TimeInterval(eventType.bufferBefore * 60)
            bufferAfter = TimeInterval(eventType.bufferAfter * 60)
        } else {
            // Fall back to a generic title + zero buffers; still proceed.
            NSLog("[BookingPoll] could not fetch event type \(booking.eventTypeID ?? "nil") for booking \(booking.id) — using fallback title + zero buffers")
            title = "Meeting with \(booking.bookerName)"
            bufferBefore = 0
            bufferAfter = 0
        }

        // Recovery path (I2): a previous attempt may have saved the EKEvent but
        // failed before/while PATCHing `confirmed` (so ek_event_id was never
        // persisted). Look for an event we already tagged with this booking's
        // deterministic marker. If found, re-confirm against it instead of
        // creating a duplicate or false-rejecting against our own event.
        //
        // We also send the confirmation email here because the prior attempt
        // created the event but failed on the PATCH (which happens before email),
        // so the booker never received a confirmation. There is no double-send risk
        // because email is the last step of confirm() and this branch only fires
        // when the PATCH (the step before email) failed.
        if let existingID = findOwnEvent(booking: booking, bufferBefore: bufferBefore, bufferAfter: bufferAfter) {
            NSLog("[BookingPoll] booking \(booking.id) already has a tagged event \(existingID) from a prior attempt — re-confirming and sending confirmation email")
            try await patchConfirmed(bookingID: booking.id, ekEventID: existingID)
            let eventTitle = title + " — " + booking.bookerName
            do {
                try await sendConfirmationEmail(booking: booking, title: eventTitle, questions: eventType?.questions ?? [])
            } catch {
                NSLog("[BookingPoll] recovery confirmation email failed for booking \(booking.id): \(error.localizedDescription)")
            }
            return true
        }

        // Conflict check: query EventKit across the window (with buffers),
        // excluding the event we may have already created for this booking.
        let conflict = hasConflict(booking: booking, bufferBefore: bufferBefore, bufferAfter: bufferAfter)

        if conflict {
            try await reject(booking)
            return false
        } else {
            try await confirm(booking, title: title, questions: eventType?.questions ?? [])
            return true
        }
    }

    // MARK: - Self-marker (I2)

    /// Deterministic marker line appended to an event's notes so a re-poll can
    /// recognise an event this service already created for a given booking.
    private static func marker(for bookingID: String) -> String {
        "[booking-id:\(bookingID)]"
    }

    /// Search the (buffered) window for an event already bearing this booking's
    /// marker — i.e. one we created on a prior attempt. Returns its identifier.
    private func findOwnEvent(booking: PendingBooking, bufferBefore: TimeInterval, bufferAfter: TimeInterval) -> String? {
        eventStore.refreshSourcesIfNecessary()

        let windowStart = booking.startUTC.addingTimeInterval(-bufferBefore)
        let windowEnd = booking.endUTC.addingTimeInterval(bufferAfter)
        guard windowEnd > windowStart else { return nil }

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: calendars.isEmpty ? nil : calendars
        )

        let marker = Self.marker(for: booking.id)
        let match = eventStore.events(matching: predicate).first { event in
            (event.notes?.contains(marker) ?? false)
        }
        return match?.eventIdentifier
    }

    // MARK: - Conflict detection

    private func hasConflict(booking: PendingBooking, bufferBefore: TimeInterval, bufferAfter: TimeInterval) -> Bool {
        eventStore.refreshSourcesIfNecessary()

        let windowStart = booking.startUTC.addingTimeInterval(-bufferBefore)
        let windowEnd = booking.endUTC.addingTimeInterval(bufferAfter)
        guard windowEnd > windowStart else { return false }

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: calendars.isEmpty ? nil : calendars
        )

        let marker = Self.marker(for: booking.id)
        let tuples: [(Date, Date)] = eventStore.events(matching: predicate)
            .filter { event in
                // Idempotency guard: don't count the event we already created
                // for this booking as a conflict against itself. Exclude it by
                // the persisted ek_event_id OR by our deterministic marker (the
                // latter covers a prior attempt whose PATCH never landed).
                if let ekID = booking.ekEventID, event.eventIdentifier == ekID {
                    return false
                }
                if event.notes?.contains(marker) ?? false {
                    return false
                }
                // All-day events (e.g. public holidays, annual-leave blocks that
                // span the whole day) don't occupy a specific hour-slot; don't
                // block a booking because of them.
                if event.isAllDay { return false }
                // "Free" events are explicitly marked as non-blocking; skip them.
                if event.availability == .free { return false }
                return true
            }
            .map { ($0.startDate, $0.endDate) }

        // C1: test the BUFFERED window (same one used to build the predicate) so
        // an existing meeting sitting inside a buffer correctly counts as a conflict.
        return BookingConflict.overlaps(
            range: DateInterval(start: windowStart, end: windowEnd),
            events: tuples
        )
    }

    // MARK: - Confirm / reject

    private func confirm(_ booking: PendingBooking, title: String, questions: [BookingQuestionDef]) async throws {
        let eventTitle = "\(title) — \(booking.bookerName)"
        // Append a deterministic self-marker (I2) so a re-poll after a failed
        // PATCH can recognise this event and re-confirm it instead of duplicating
        // or false-rejecting.
        let answerLines = BookingAnswers.format(answers: booking.answers, questions: questions)
        let answerBlock = answerLines.isEmpty ? "" : "\n\n" + answerLines.joined(separator: "\n")
        let notes = "Booked via availability page. Booker: \(booking.bookerName) <\(booking.bookerEmail)>\(answerBlock)\n\(Self.marker(for: booking.id))"

        // 1. Create + save the EKEvent on the default (Exchange) calendar.
        let event = EKEvent(eventStore: eventStore)
        event.title = eventTitle
        event.startDate = booking.startUTC
        event.endDate = booking.endUTC
        event.notes = notes
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw BookingPollError.noDefaultCalendar
        }
        event.calendar = calendar
        try eventStore.save(event, span: .thisEvent, commit: true)
        guard let ekEventID = event.eventIdentifier else {
            throw BookingPollError.noEventIdentifier
        }

        // 2. PATCH the row to confirmed with the EK identifier (before email,
        //    for idempotency — the event exists no matter what happens next).
        try await patchConfirmed(bookingID: booking.id, ekEventID: ekEventID)

        // 3. Build the .ics and send the confirmation email. Email failure is
        //    logged but does NOT roll back the confirmation.
        do {
            try await sendConfirmationEmail(booking: booking, title: eventTitle, questions: questions)
        } catch {
            NSLog("[BookingPoll] confirmation email failed for booking \(booking.id) (booking remains confirmed): \(error.localizedDescription)")
        }
    }

    private func reject(_ booking: PendingBooking) async throws {
        try await patchRejected(bookingID: booking.id, reason: "Slot was no longer free")
        do {
            try await sendRejectionEmail(booking: booking)
        } catch {
            NSLog("[BookingPoll] rejection email failed for booking \(booking.id): \(error.localizedDescription)")
        }
    }

    // MARK: - Email

    private func sendConfirmationEmail(booking: PendingBooking, title: String, questions: [BookingQuestionDef]) async throws {
        let description = "Confirmed: \(title)"
        // BookingICS.build validates both email addresses and throws
        // BookingPollError.invalidEmail if either is malformed/injected.
        let ics = try BookingICS.build(
            title: title,
            start: booking.startUTC,
            end: booking.endUTC,
            organizerEmail: Self.ownerOrganizerEmail,
            attendeeEmail: booking.bookerEmail,
            description: description
        )

        let answerLines = BookingAnswers.format(answers: booking.answers, questions: questions)
        let sharedBlock = answerLines.isEmpty
            ? ""
            : "\nWhat you shared:\n" + answerLines.joined(separator: "\n") + "\n"

        let body = """
        Hi \(booking.bookerName),

        You're booked for "\(title)".

        \(formatWhen(start: booking.startUTC, end: booking.endUTC))
        \(sharedBlock)
        A calendar invite (.ics) is attached.

        Thanks,
        Adam
        """

        try await sendEmail(
            to: booking.bookerEmail,
            subject: "Booking confirmed: \(title)",
            body: body,
            icsContent: ics
        )
    }

    private func sendRejectionEmail(booking: PendingBooking) async throws {
        let body = """
        Hi \(booking.bookerName),

        Unfortunately that slot just filled up and is no longer available.

        \(formatWhen(start: booking.startUTC, end: booking.endUTC))

        Please pick another time on the booking page and I'll confirm it.

        Sorry for the inconvenience,
        Adam
        """

        try await sendEmail(
            to: booking.bookerEmail,
            subject: "That slot just filled — please rebook",
            body: body,
            icsContent: nil
        )
    }

    /// Unified send: Microsoft Graph first (sends from Exchange, no Mail.app
    /// needed). On any Graph failure, fall back to Mail.app — which the composer
    /// forces through the Exchange account and ERRORS rather than ever sending
    /// from iCloud. A dead Graph sign-in is surfaced once via a notification so
    /// the user knows to reconnect.
    private func sendEmail(to: String, subject: String, body: String, icsContent: String?) async throws {
        do {
            try await graph.sendMail(to: to, subject: subject, body: body, icsContent: icsContent)
            graphReauthNotified = false
            return
        } catch {
            if case GraphMailError.needsReauth = error, !graphReauthNotified {
                NotificationService.shared.postIntegrationFailure(
                    integration: "Exchange sending",
                    detail: "Sign-in expired — reconnect in Settings → Availability. Falling back to Mail.app meanwhile."
                )
                graphReauthNotified = true
            }
            NSLog("[BookingPoll] Graph send failed (\(error.localizedDescription)); trying Mail.app Exchange fallback")
        }

        // Fallback path. The composed script asserts the Exchange account is
        // enabled in Mail and throws otherwise — so we never send from iCloud.
        var icsPath: String?
        if let ics = icsContent {
            let path = NSTemporaryDirectory() + "booking-fallback-\(UUID().uuidString).ics"
            try ics.write(toFile: path, atomically: true, encoding: .utf8)
            icsPath = path
        }
        defer { if let p = icsPath { try? FileManager.default.removeItem(atPath: p) } }

        // MailAppleScript.compose validates the recipient email address and throws
        // BookingPollError.invalidEmail if it is malformed or contains injection chars.
        let script = try MailAppleScript.compose(
            senderDisplay: Self.ownerSenderDisplay,
            senderEmail: Self.ownerOrganizerEmail,
            to: to,
            subject: subject,
            body: body,
            icsPath: icsPath
        )
        try await Self.runOsascript(script)
    }

    private func formatWhen(start: Date, end: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_GB")
        fmt.timeZone = TimeZone(identifier: "Europe/London")
        fmt.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm"
        let endFmt = DateFormatter()
        endFmt.locale = Locale(identifier: "en_GB")
        endFmt.timeZone = TimeZone(identifier: "Europe/London")
        endFmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: start))–\(endFmt.string(from: end)) (London time)"
    }

    // MARK: - osascript runner

    /// Run an AppleScript via `/usr/bin/osascript -e <script>`, same `Process`
    /// pattern as `BusyLightService`. Throws on non-zero exit.
    ///
    /// I1: this is the multi-second blocking call. It's `nonisolated` + `async`
    /// and only ever takes a Sendable `String`, so callers invoke it inside a
    /// `Task.detached` and the `Process.waitUntilExit()` runs off the MainActor —
    /// the menu-bar UI no longer freezes during a send.
    nonisolated private static func runOsascript(_ script: String) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe()

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let err = String(data: data, encoding: .utf8) ?? "osascript exit \(process.terminationStatus)"
                throw BookingPollError.osascriptFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }

    // MARK: - Supabase REST

    private func fetchPending() async throws -> [PendingBooking] {
        let query = "status=eq.pending&select=id,start_utc,end_utc,status,booker_name,booker_email,event_type_id,ek_event_id,answers"
        let url = try restURL(path: "/rest/v1/booking_requests", query: query)
        let request = try authedRequest(url: url, method: "GET")
        let data = try await sendForData(request)
        return try PendingBooking.decodeList(data)
    }

    private func fetchEventType(id: String?) async throws -> BookingEventType {
        guard let id, !id.isEmpty else { throw BookingPollError.missingEventTypeID }
        let query = "id=eq.\(id)&select=slug,title,duration_min,buffer_before,buffer_after,questions"
        let url = try restURL(path: "/rest/v1/booking_event_types", query: query)
        let request = try authedRequest(url: url, method: "GET")
        let data = try await sendForData(request)
        let list = try JSONDecoder().decode([BookingEventType].self, from: data)
        guard let first = list.first else { throw BookingPollError.eventTypeNotFound(id) }
        return first
    }

    private func patchConfirmed(bookingID: String, ekEventID: String) async throws {
        let payload: [String: Any] = [
            "status": "confirmed",
            "ek_event_id": ekEventID,
            "resolved_at": ISO8601DateFormatter().string(from: Date()),
        ]
        try await patchBooking(id: bookingID, payload: payload)
    }

    private func patchRejected(bookingID: String, reason: String) async throws {
        let payload: [String: Any] = [
            "status": "rejected",
            "reject_reason": reason,
            "resolved_at": ISO8601DateFormatter().string(from: Date()),
        ]
        try await patchBooking(id: bookingID, payload: payload)
    }

    private func patchBooking(id: String, payload: [String: Any]) async throws {
        let url = try restURL(path: "/rest/v1/booking_requests", query: "id=eq.\(id)")
        var request = try authedRequest(url: url, method: "PATCH")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        _ = try await sendForData(request)
    }

    // MARK: - Request helpers

    private func restURL(path: String, query: String) throws -> URL {
        let base = projectURL.hasSuffix("/") ? String(projectURL.dropLast()) : projectURL
        guard let url = URL(string: "\(base)\(path)?\(query)") else {
            throw BookingPollError.invalidURL(base + path)
        }
        return url
    }

    private func authedRequest(url: URL, method: String) throws -> URLRequest {
        guard let key = serviceRoleKey, !key.isEmpty else {
            throw BookingPollError.missingCredentials
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue(key, forHTTPHeaderField: "apikey")
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    @discardableResult
    private func sendForData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BookingPollError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BookingPollError.httpError(http.statusCode, body)
        }
        return data
    }
}

// MARK: - Event type payload

/// Decodes a row from `booking_event_types`. Buffers are in minutes.
struct BookingEventType: Decodable {
    let slug: String
    let title: String
    let durationMin: Int
    let bufferBefore: Int
    let bufferAfter: Int
    let questions: [BookingQuestionDef]

    enum CodingKeys: String, CodingKey {
        case slug, title, questions
        case durationMin = "duration_min"
        case bufferBefore = "buffer_before"
        case bufferAfter = "buffer_after"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decode(String.self, forKey: .title)
        durationMin = try c.decode(Int.self, forKey: .durationMin)
        bufferBefore = try c.decode(Int.self, forKey: .bufferBefore)
        bufferAfter = try c.decode(Int.self, forKey: .bufferAfter)
        questions = (try? c.decode([BookingQuestionDef].self, forKey: .questions)) ?? []
    }
}

// MARK: - Errors

enum BookingPollError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case missingCredentials
    case missingEventTypeID
    case eventTypeNotFound(String)
    case noDefaultCalendar
    case noEventIdentifier
    case osascriptFailed(String)
    case httpError(Int, String)
    case invalidEmail(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s):        return "Invalid Supabase URL: \(s)"
        case .invalidResponse:          return "Invalid response from Supabase"
        case .missingCredentials:       return "Missing Supabase service-role key"
        case .missingEventTypeID:       return "Booking has no event_type_id"
        case .eventTypeNotFound(let id): return "Event type \(id) not found"
        case .noDefaultCalendar:        return "No default calendar for new events"
        case .noEventIdentifier:        return "Saved event has no identifier"
        case .osascriptFailed(let e):   return "osascript failed: \(e)"
        case .httpError(let c, let body):
            return "HTTP \(c)\(body.isEmpty ? "" : " — \(body)")"
        case .invalidEmail(let e):      return "Invalid booker email address: \(e)"
        }
    }
}
