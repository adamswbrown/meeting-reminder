import SwiftUI

struct BusyLightSettingsView: View {
    @ObservedObject var service: BusyLightService

    var body: some View {
        Form {
            Section("How it works") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Meeting Reminder runs one of your Shortcuts when you go into a meeting, and another when you're free. The Shortcut decides what happens — typically setting a HomeKit bulb to a colour.")
                        .font(.callout)
                    Text("Busy = a calendar meeting is in progress, OR your microphone is currently active. Free = neither, after a 30-second debounce.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Quick setup") {
                VStack(alignment: .leading, spacing: 10) {
                    setupStep(
                        number: 1,
                        text: "Install the two starter Shortcuts. Shortcuts.app will open with an \"Add Shortcut\" sheet for each — click Add Shortcut.",
                        button: nil,
                        action: nil
                    )
                    HStack {
                        Button("Install \"Meeting Busy\"") {
                            service.installStarter(.busy)
                        }
                        Button("Install \"Meeting Free\"") {
                            service.installStarter(.free)
                        }
                    }
                    .controlSize(.regular)
                    .padding(.leading, 28)

                    setupStep(
                        number: 2,
                        text: "Open each newly added Shortcut and pick your bulb in the \"Control My Home\" action — by default they target an accessory called \"Lamp\" in a room called \"Office\". For Meeting Busy: Power On, Colour Red, Brightness 100%. For Meeting Free: Power Off.",
                        button: "Open Shortcuts",
                        action: { service.openShortcutsApp() }
                    )

                    setupStep(
                        number: 3,
                        text: "Come back here and pick each Shortcut from the dropdowns below.",
                        button: "Refresh list",
                        action: { service.refresh() }
                    )
                }
                .padding(.vertical, 4)
            }

            Section("In a meeting (busy)") {
                Toggle("Run a Shortcut when busy", isOn: Binding(
                    get: { service.busyEnabled },
                    set: { service.busyEnabled = $0 }
                ))

                shortcutPicker(
                    selection: Binding(
                        get: { service.busyShortcut },
                        set: { service.busyShortcut = $0 }
                    ),
                    label: "Shortcut:"
                )
                .disabled(!service.busyEnabled)

                HStack {
                    Button("Test") { service.apply(.busy) }
                        .disabled(service.busyShortcut.isEmpty || !service.busyEnabled)
                    if !service.busyShortcut.isEmpty {
                        Button("Edit in Shortcuts") {
                            service.openShortcutsApp(name: service.busyShortcut)
                        }
                    }
                }
                .controlSize(.small)
            }

            Section("Free (not in a meeting)") {
                Toggle("Run a Shortcut when free", isOn: Binding(
                    get: { service.freeEnabled },
                    set: { service.freeEnabled = $0 }
                ))

                shortcutPicker(
                    selection: Binding(
                        get: { service.freeShortcut },
                        set: { service.freeShortcut = $0 }
                    ),
                    label: "Shortcut:"
                )
                .disabled(!service.freeEnabled)

                HStack {
                    Button("Test") { service.apply(.free) }
                        .disabled(service.freeShortcut.isEmpty || !service.freeEnabled)
                    if !service.freeShortcut.isEmpty {
                        Button("Edit in Shortcuts") {
                            service.openShortcutsApp(name: service.freeShortcut)
                        }
                    }
                }
                .controlSize(.small)
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
        .onAppear { service.refresh() }
    }

    @ViewBuilder
    private func shortcutPicker(selection: Binding<String>, label: String) -> some View {
        HStack {
            if service.availableShortcuts.isEmpty {
                Text("No Shortcuts found yet. Create some in Shortcuts.app and click Refresh.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker(label, selection: selection) {
                    Text("None").tag("")
                    ForEach(service.availableShortcuts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
            }
            Spacer()
            Button {
                service.refresh()
            } label: {
                if service.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh the list of Shortcuts")
        }
    }

    @ViewBuilder
    private func setupStep(number: Int, text: String, button: String?, action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .font(.callout.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let button, let action {
                    Button(button, action: action)
                        .controlSize(.small)
                }
            }
            Spacer()
        }
    }
}
