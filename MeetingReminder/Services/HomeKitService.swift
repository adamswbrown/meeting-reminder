import Combine
import Foundation
import HomeKit
import SwiftUI

/// Wraps HMHomeManager and exposes a flat list of colour-capable bulbs.
///
/// Persistence model:
///   - `selectedBulbID` (UserDefaults) — the HMAccessory uniqueIdentifier UUID string
///   - `busyEnabled` / `freeEnabled` (UserDefaults) — write the light state for this case
///   - `busyColorHex` / `freeColorHex` — the chosen NSColor encoded as #RRGGBB
///
/// The service writes hue/saturation/brightness in the HomeKit colour space
/// (hue 0–360, sat 0–100, bri 0–100). SwiftUI's ColorPicker hands us an sRGB
/// Color which we convert via NSColor's HSB components.
@MainActor
final class HomeKitService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: HMHomeManagerAuthorizationStatus = []
    @Published private(set) var bulbs: [Bulb] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastAppliedState: AppliedState?

    @AppStorage("homeKitSelectedBulbID") var selectedBulbID: String = ""
    @AppStorage("homeKitBusyEnabled") var busyEnabled: Bool = true
    @AppStorage("homeKitFreeEnabled") var freeEnabled: Bool = true
    @AppStorage("homeKitBusyColorHex") var busyColorHex: String = "#FF0000"
    @AppStorage("homeKitFreeColorHex") var freeColorHex: String = "#22C55E"
    @AppStorage("homeKitBusyBrightness") var busyBrightness: Double = 100
    @AppStorage("homeKitFreeBrightness") var freeBrightness: Double = 60

    private var manager: HMHomeManager?
    private var didStartManager = false

    struct Bulb: Identifiable, Equatable {
        let id: String
        let name: String
        let roomName: String?
        let supportsColor: Bool
    }

    enum AppliedState: String { case busy, free }

    override init() {
        super.init()
    }

    /// Lazily instantiate HMHomeManager. Creating it triggers the system
    /// HomeKit permission prompt the first time, so we only do it when the
    /// user opens the HomeKit Settings tab or actively asks to apply state.
    func start() {
        guard !didStartManager else { return }
        didStartManager = true
        let m = HMHomeManager()
        m.delegate = self
        manager = m
        refresh()
    }

    func refresh() {
        guard let manager else { return }
        authorizationStatus = manager.authorizationStatus
        bulbs = enumerateBulbs(in: manager)
    }

    /// Write the configured colour for `state` to the selected bulb.
    /// No-op when no bulb is selected, when the state is disabled, or when
    /// no change is needed since the last applied state.
    func apply(_ state: AppliedState) {
        // Skip if we just applied this state — avoids hammering the bulb.
        guard lastAppliedState != state else { return }

        let enabled = (state == .busy) ? busyEnabled : freeEnabled
        let accessory = selectedAccessory()
        guard let accessory else { return }

        if !enabled {
            // State explicitly off — turn the bulb off, regardless of colour.
            write(power: false, hue: nil, sat: nil, bri: nil, to: accessory)
            lastAppliedState = state
            return
        }

        let hex = (state == .busy) ? busyColorHex : freeColorHex
        let bri = (state == .busy) ? busyBrightness : freeBrightness
        let (h, s, _) = Self.hsb(fromHex: hex)
        write(power: true, hue: h, sat: s, bri: bri, to: accessory)
        lastAppliedState = state
    }

    // MARK: - Selection helpers

    func selectedBulb() -> Bulb? {
        bulbs.first(where: { $0.id == selectedBulbID })
    }

    private func selectedAccessory() -> HMAccessory? {
        guard let manager else { return nil }
        for home in manager.homes {
            for accessory in home.accessories where accessory.uniqueIdentifier.uuidString == selectedBulbID {
                return accessory
            }
        }
        return nil
    }

    private func enumerateBulbs(in manager: HMHomeManager) -> [Bulb] {
        var out: [Bulb] = []
        for home in manager.homes {
            for accessory in home.accessories {
                guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeLightbulb }) else {
                    continue
                }
                let supportsColor = service.characteristics.contains { $0.characteristicType == HMCharacteristicTypeHue }
                let roomName = home.rooms.first(where: { $0.accessories.contains(where: { $0 == accessory }) })?.name
                out.append(Bulb(
                    id: accessory.uniqueIdentifier.uuidString,
                    name: accessory.name,
                    roomName: roomName,
                    supportsColor: supportsColor
                ))
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - HomeKit writes

    private func write(power: Bool, hue: Double?, sat: Double?, bri: Double?, to accessory: HMAccessory) {
        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeLightbulb }) else {
            return
        }

        func char(_ type: String) -> HMCharacteristic? {
            service.characteristics.first(where: { $0.characteristicType == type })
        }

        // Power first.
        if let powerChar = char(HMCharacteristicTypePowerState) {
            powerChar.writeValue(power) { [weak self] err in
                if let err { Task { @MainActor in self?.lastError = err.localizedDescription } }
            }
        }
        guard power else { return }

        // Hue is the only colour write the user requested; saturation and
        // brightness follow if the bulb supports them.
        if let h = hue, let hueChar = char(HMCharacteristicTypeHue) {
            hueChar.writeValue(NSNumber(value: h)) { [weak self] err in
                if let err { Task { @MainActor in self?.lastError = err.localizedDescription } }
            }
        }
        if let s = sat, let satChar = char(HMCharacteristicTypeSaturation) {
            satChar.writeValue(NSNumber(value: s)) { _ in }
        }
        if let b = bri, let briChar = char(HMCharacteristicTypeBrightness) {
            briChar.writeValue(NSNumber(value: Int(b.rounded()))) { _ in }
        }
    }

    // MARK: - Colour conversion

    /// Convert a #RRGGBB string to HomeKit's HSB (hue 0–360, sat 0–100, bri 0–100).
    static func hsb(fromHex hex: String) -> (hue: Double, saturation: Double, brightness: Double) {
        var trimmed = hex.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let v = UInt32(trimmed, radix: 16) else {
            return (0, 100, 100)
        }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return (Double(hue) * 360.0, Double(sat) * 100.0, Double(bri) * 100.0)
    }

    static func hex(from color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let r = Int((nsColor.redComponent * 255).rounded())
        let g = Int((nsColor.greenComponent * 255).rounded())
        let b = Int((nsColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func color(fromHex hex: String) -> Color {
        var trimmed = hex.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let v = UInt32(trimmed, radix: 16) else { return .red }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

extension HomeKitService: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in
            self.authorizationStatus = status
            self.refresh()
        }
    }
}
