import SwiftUI

struct CalComSettingsView: View {
    @ObservedObject var calComService: CalComService
    @ObservedObject var calComSyncService: CalComSyncService

    @State private var apiKeyDraft: String = ""
    @State private var isTestingConnection = false
    @State private var connectionStatus: String?
    @State private var connectionOK = false

    @State private var eventTypes: [CalComEventType] = []
    @State private var isLoadingEventTypes = false

    @State private var schedules: [CalComSchedule] = []
    @State private var isLoadingSchedules = false

    @State private var upcomingBookings: [CalComBooking] = []
    @State private var isLoadingBookings = false
    @State private var cancellingUID: String?
    @State private var reschedulingBooking: CalComBooking? = nil
    @State private var rescheduleDate: Date = Date()
    @State private var isRescheduling = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionSection
                if calComService.isConfigured {
                    syncSection
                    eventTypesSection
                    schedulesSection
                    bookingsSection
                }
            }
            .padding()
        }
        .onAppear {
            apiKeyDraft = calComService.apiKey ?? ""
            if calComService.isConfigured { loadAll() }
        }
        .sheet(item: $reschedulingBooking) { booking in
            VStack(alignment: .leading, spacing: 16) {
                Text("Reschedule").font(.headline)
                Text(booking.title ?? "Meeting").foregroundStyle(.secondary)
                DatePicker("New time", selection: $rescheduleDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                HStack {
                    Button("Cancel") { reschedulingBooking = nil }
                    Spacer()
                    Button(isRescheduling ? "Saving…" : "Confirm") {
                        Task { await rescheduleBooking(uid: booking.uid, newStart: rescheduleDate) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRescheduling)
                }
            }
            .padding()
            .frame(minWidth: 380)
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        GroupBox("Cal.com Connection") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("API key  (cal_live_...)", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { saveKey() }
                        .disabled(apiKeyDraft.isEmpty)
                    if calComService.isConfigured {
                        Button("Disconnect", role: .destructive) { disconnect() }
                    }
                }
                HStack(spacing: 8) {
                    Button(isTestingConnection ? "Testing…" : "Test connection") {
                        Task { await testConnection() }
                    }
                    .disabled(apiKeyDraft.isEmpty || isTestingConnection)
                    if let status = connectionStatus {
                        Image(systemName: connectionOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(connectionOK ? .green : .red)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Get your API key at cal.com → Settings → Developer → API Keys")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(8)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        GroupBox("Booking Sync") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Sync Cal.com bookings to Calendar every 5 minutes", isOn: $calComSyncService.isEnabled)
                if let at = calComSyncService.lastSyncedAt {
                    Text("Last sync: \(at.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let result = calComSyncService.lastSyncResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
                if let err = calComSyncService.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Button("Sync now") { Task { await calComSyncService.syncOnce() } }
                    .controlSize(.small)
            }
            .padding(8)
        }
    }

    // MARK: - Event Types

    private var eventTypesSection: some View {
        GroupBox("Event Types") {
            VStack(alignment: .leading, spacing: 8) {
                if isLoadingEventTypes {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if eventTypes.isEmpty {
                    Text("No event types found").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(eventTypes) { et in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(et.title).fontWeight(.medium)
                                    Text("/\(et.slug) · \(et.lengthInMinutes) min")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if et.hidden == true {
                                    Text("Hidden")
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary).clipShape(Capsule())
                                }
                                if let url = et.bookingUrl, let u = URL(string: url) {
                                    Link(destination: u) {
                                        Image(systemName: "arrow.up.right.square")
                                            .font(.caption)
                                    }
                                }
                            }
                            if let desc = et.description, !desc.isEmpty {
                                Text(desc).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 3)
                        if et.id != eventTypes.last?.id { Divider() }
                    }
                }
                Button("Refresh") { Task { await loadEventTypes() } }.controlSize(.small)
            }
            .padding(8)
        }
    }

    // MARK: - Schedules

    private var schedulesSection: some View {
        GroupBox("Schedules") {
            VStack(alignment: .leading, spacing: 8) {
                if isLoadingSchedules {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if schedules.isEmpty {
                    Text("No schedules found").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(schedules) { schedule in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(schedule.name).fontWeight(.medium)
                                Text(schedule.timeZone).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if schedule.isDefault == true {
                                Text("Default")
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.blue.opacity(0.15)).clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 3)
                        if schedule.id != schedules.last?.id { Divider() }
                    }
                }
                Button("Refresh") { Task { await loadSchedules() } }.controlSize(.small)
            }
            .padding(8)
        }
    }

    // MARK: - Bookings

    private var bookingsSection: some View {
        GroupBox("Upcoming Bookings") {
            VStack(alignment: .leading, spacing: 8) {
                if isLoadingBookings {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if upcomingBookings.isEmpty {
                    Text("No upcoming bookings").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(upcomingBookings) { booking in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(booking.title ?? "Meeting").fontWeight(.medium)
                                if let start = booking.startDate {
                                    Text(start.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let attendee = booking.attendees?.first {
                                    Text(attendee.name).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button("Reschedule") {
                                rescheduleDate = booking.startDate ?? Date()
                                reschedulingBooking = booking
                            }
                            .controlSize(.small)
                            Button("Cancel") { Task { await cancelBooking(uid: booking.uid) } }
                                .controlSize(.small)
                                .disabled(cancellingUID == booking.uid)
                                .foregroundStyle(.red)
                        }
                        .padding(.vertical, 3)
                        if booking.uid != upcomingBookings.last?.uid { Divider() }
                    }
                }
                Button("Refresh") { Task { await loadBookings() } }.controlSize(.small)
            }
            .padding(8)
        }
    }

    // MARK: - Actions

    private func saveKey() {
        calComService.saveAPIKey(apiKeyDraft)
        connectionStatus = nil
        if calComService.isConfigured { loadAll() }
    }

    private func disconnect() {
        calComService.deleteAPIKey()
        apiKeyDraft = ""
        eventTypes = []
        schedules = []
        upcomingBookings = []
        connectionStatus = nil
    }

    private func testConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }
        let previousKey = calComService.apiKey
        calComService.saveAPIKey(apiKeyDraft)
        do {
            connectionStatus = try await calComService.testConnection()
            connectionOK = true
        } catch {
            connectionStatus = error.localizedDescription
            connectionOK = false
            // Restore previous key if test was using a new draft that failed
            if let prev = previousKey { calComService.saveAPIKey(prev) }
            else { calComService.deleteAPIKey() }
        }
    }

    private func loadAll() {
        Task { await loadEventTypes() }
        Task { await loadSchedules() }
        Task { await loadBookings() }
    }

    private func loadEventTypes() async {
        isLoadingEventTypes = true
        defer { isLoadingEventTypes = false }
        do { eventTypes = try await calComService.fetchEventTypes() }
        catch { NSLog("[CalComSettings] eventTypes error: \(error)") }
    }

    private func loadSchedules() async {
        isLoadingSchedules = true
        defer { isLoadingSchedules = false }
        do { schedules = try await calComService.fetchSchedules() }
        catch { NSLog("[CalComSettings] schedules error: \(error)") }
    }

    private func loadBookings() async {
        isLoadingBookings = true
        defer { isLoadingBookings = false }
        do { upcomingBookings = try await calComService.fetchUpcomingBookings() }
        catch { NSLog("[CalComSettings] bookings error: \(error)") }
    }

    private func cancelBooking(uid: String) async {
        cancellingUID = uid
        defer { cancellingUID = nil }
        do {
            try await calComService.cancelBooking(uid: uid)
            upcomingBookings.removeAll { $0.uid == uid }
        } catch {
            NSLog("[CalComSettings] cancel \(uid) error: \(error)")
        }
    }

    private func rescheduleBooking(uid: String, newStart: Date) async {
        isRescheduling = true
        defer { isRescheduling = false }
        do {
            let updated = try await calComService.rescheduleBooking(uid: uid, newStart: newStart)
            if let idx = upcomingBookings.firstIndex(where: { $0.uid == uid }) {
                upcomingBookings[idx] = updated
            }
            reschedulingBooking = nil
        } catch {
            NSLog("[CalComSettings] reschedule \(uid) error: \(error)")
        }
    }
}
