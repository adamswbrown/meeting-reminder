import HomeKit
import SwiftUI

struct HomeKitSettingsView: View {
    @ObservedObject var service: HomeKitService

    @State private var busyColor: Color = .red
    @State private var freeColor: Color = .green

    var body: some View {
        Form {
            Section("Authorization") {
                authorizationRow
            }

            Section("Bulb") {
                if service.bulbs.isEmpty {
                    Text(emptyStateMessage)
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Refresh") { service.refresh() }
                        .controlSize(.small)
                } else {
                    Picker("Lightbulb:", selection: Binding(
                        get: { service.selectedBulbID },
                        set: { service.selectedBulbID = $0 }
                    )) {
                        Text("None").tag("")
                        ForEach(service.bulbs) { bulb in
                            Text(displayName(for: bulb)).tag(bulb.id)
                        }
                    }
                    .pickerStyle(.menu)

                    if let chosen = service.selectedBulb(), !chosen.supportsColor {
                        Label("This bulb doesn't report a hue characteristic — only power and brightness will be set.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    Button("Refresh list") { service.refresh() }
                        .controlSize(.small)
                }
            }

            Section("In a meeting (busy)") {
                Toggle("Turn light on", isOn: Binding(
                    get: { service.busyEnabled },
                    set: { service.busyEnabled = $0 }
                ))

                ColorPicker("Colour:", selection: $busyColor, supportsOpacity: false)
                    .disabled(!service.busyEnabled)
                    .onChange(of: busyColor) { newValue in
                        service.busyColorHex = HomeKitService.hex(from: newValue)
                    }

                HStack {
                    Text("Brightness:")
                    Slider(value: Binding(
                        get: { service.busyBrightness },
                        set: { service.busyBrightness = $0 }
                    ), in: 1...100)
                    Text("\(Int(service.busyBrightness))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                        .foregroundColor(.secondary)
                }
                .disabled(!service.busyEnabled)

                Button("Preview") { service.apply(.busy) }
                    .controlSize(.small)
                    .disabled(service.selectedBulbID.isEmpty)
            }

            Section("Free (not in a meeting)") {
                Toggle("Turn light on", isOn: Binding(
                    get: { service.freeEnabled },
                    set: { service.freeEnabled = $0 }
                ))

                ColorPicker("Colour:", selection: $freeColor, supportsOpacity: false)
                    .disabled(!service.freeEnabled)
                    .onChange(of: freeColor) { newValue in
                        service.freeColorHex = HomeKitService.hex(from: newValue)
                    }

                HStack {
                    Text("Brightness:")
                    Slider(value: Binding(
                        get: { service.freeBrightness },
                        set: { service.freeBrightness = $0 }
                    ), in: 1...100)
                    Text("\(Int(service.freeBrightness))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                        .foregroundColor(.secondary)
                }
                .disabled(!service.freeEnabled)

                Button("Preview") { service.apply(.free) }
                    .controlSize(.small)
                    .disabled(service.selectedBulbID.isEmpty)
            }

            Section {
                Text("Busy = a calendar meeting is in progress, OR your microphone is currently active. Free = neither.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = service.lastError {
                Section("Last error") {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            service.start()
            busyColor = HomeKitService.color(fromHex: service.busyColorHex)
            freeColor = HomeKitService.color(fromHex: service.freeColorHex)
        }
    }

    @ViewBuilder
    private var authorizationRow: some View {
        let status = service.authorizationStatus
        HStack {
            if status.contains(.authorized) {
                Label("Authorized", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if status.contains(.restricted) {
                Label("Restricted", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            } else if status.contains(.determined) {
                Label("Denied", systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
            } else {
                Label("Not determined", systemImage: "questionmark.circle")
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Request / refresh") {
                service.start()
                service.refresh()
            }
            .controlSize(.small)
        }
    }

    private var emptyStateMessage: String {
        if service.authorizationStatus.contains(.authorized) {
            return "No colour-capable bulbs found in your Home. Make sure your Mac is signed into the same iCloud account as your Home and the bulb is configured in the Home app."
        }
        return "Click \"Request / refresh\" above to grant HomeKit access. Your Mac must be signed into the same iCloud account as the Home that contains your bulbs."
    }

    private func displayName(for bulb: HomeKitService.Bulb) -> String {
        if let room = bulb.roomName, !room.isEmpty {
            return "\(bulb.name) — \(room)"
        }
        return bulb.name
    }
}
