import SwiftUI

/// A compact checklist shown alongside the meeting overlay for pre-meeting preparation.
struct ChecklistView: View {
    @State private var items: [ChecklistItem]
    let onDone: () -> Void

    init(onDone: @escaping () -> Void) {
        _items = State(initialValue: ChecklistItem.load().map {
            // Reset all items to unchecked for new meeting
            ChecklistItem(id: $0.id, text: $0.text, isChecked: false)
        })
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checklist")
                    .foregroundColor(.accentColor)
                Text("Pre-Meeting Prep")
                    .font(.headline)
                Spacer()
                Button(action: onDone) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            ForEach($items) { $item in
                HStack(spacing: 8) {
                    Button {
                        item.isChecked.toggle()
                    } label: {
                        Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(item.isChecked ? .green : .secondary)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)

                    Text(item.text)
                        .font(.callout)
                        .strikethrough(item.isChecked)
                        .foregroundColor(item.isChecked ? .secondary : .primary)
                }
            }

            if allChecked {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("All done — you're ready!")
                        .font(.callout.weight(.medium))
                        .foregroundColor(.green)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private var allChecked: Bool {
        items.allSatisfy(\.isChecked)
    }
}

// MARK: - Checklist Window Controller

final class ChecklistWindowController {
    private var panel: NSPanel?

    func show(onDone: @escaping () -> Void) {
        close()

        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.level = .screenSaver - 1 // Just below the overlay
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.title = "Pre-Meeting Checklist"

        let view = ChecklistView(onDone: { [weak self] in
            self?.close()
            onDone()
        })

        panel.contentView = NSHostingView(rootView: view)

        // Position to the right of center
        let x = screen.visibleFrame.midX + 200
        let y = screen.visibleFrame.midY - 150
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
