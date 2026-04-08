import AppKit
import Foundation

/// Resolves which screens the overlay should appear on, based on user preferences.
enum DisplayMode: String, CaseIterable, Identifiable {
    case all
    case primary
    case specific

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:      return "All screens"
        case .primary:  return "Primary screen only"
        case .specific: return "Specific screen"
        }
    }
}

enum DisplayPreferences {
    static let modeKey = "overlayMonitorMode"
    static let specificScreenKey = "overlayMonitorScreenName"

    static var mode: DisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: modeKey) ?? DisplayMode.all.rawValue
            return DisplayMode(rawValue: raw) ?? .all
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
        }
    }

    static var specificScreenName: String? {
        get { UserDefaults.standard.string(forKey: specificScreenKey) }
        set { UserDefaults.standard.set(newValue, forKey: specificScreenKey) }
    }

    /// Returns the screens the overlay should appear on, given current preferences.
    static func targetScreens() -> [NSScreen] {
        let allScreens = NSScreen.screens
        guard !allScreens.isEmpty else { return [] }

        switch mode {
        case .all:
            return allScreens
        case .primary:
            // NSScreen.main can change based on focused window; use screens[0] which is the
            // screen containing the menu bar — the most stable "primary" definition
            return [allScreens[0]]
        case .specific:
            if let name = specificScreenName,
               let match = allScreens.first(where: { $0.localizedName == name }) {
                return [match]
            }
            // Fallback if the saved screen is no longer connected
            return [allScreens[0]]
        }
    }

    /// All currently connected screens, for use in Settings UI
    static func availableScreens() -> [NSScreen] {
        NSScreen.screens
    }
}
