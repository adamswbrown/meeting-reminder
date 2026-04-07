import Foundation

/// Progressive alert tiers — escalating urgency as meeting approaches
enum AlertTier: Int, CaseIterable, Comparable {
    case ambient  = 15  // 15 min: menu bar color change only
    case banner   = 10  // 10 min: system notification
    case urgent   = 5   // 5 min: menu bar orange + optional chime
    case blocking = 2   // 2-3 min: full-screen overlay
    case lastChance = 0 // 0 min: re-fire overlay if not dismissed

    var minutesBefore: Int { rawValue }

    var settingsKey: String {
        switch self {
        case .ambient:   return "alertTierAmbientEnabled"
        case .banner:    return "alertTierBannerEnabled"
        case .urgent:    return "alertTierUrgentEnabled"
        case .blocking:  return "alertTierBlockingEnabled"
        case .lastChance: return "alertTierLastChanceEnabled"
        }
    }

    var isEnabled: Bool {
        // All tiers enabled by default
        let defaults = UserDefaults.standard
        return defaults.object(forKey: settingsKey) == nil || defaults.bool(forKey: settingsKey)
    }

    var displayName: String {
        switch self {
        case .ambient:   return "Ambient (15 min)"
        case .banner:    return "Banner notification (10 min)"
        case .urgent:    return "Urgent (5 min)"
        case .blocking:  return "Full overlay (2-3 min)"
        case .lastChance: return "Last chance (at start)"
        }
    }

    var description: String {
        switch self {
        case .ambient:   return "Menu bar turns yellow"
        case .banner:    return "System notification banner"
        case .urgent:    return "Menu bar turns orange, optional chime"
        case .blocking:  return "Full-screen blocking overlay"
        case .lastChance: return "Overlay re-fires if not dismissed"
        }
    }

    static func < (lhs: AlertTier, rhs: AlertTier) -> Bool {
        lhs.rawValue > rhs.rawValue // Lower minutesBefore = higher urgency
    }

    /// Returns the appropriate tier for a given number of minutes until meeting start
    static func tier(forMinutesUntil minutes: Double) -> AlertTier? {
        // Return the most urgent applicable tier
        if minutes <= 0 { return .lastChance }
        if minutes <= 3 { return .blocking }
        if minutes <= 5 { return .urgent }
        if minutes <= 10 { return .banner }
        if minutes <= 15 { return .ambient }
        return nil
    }
}

/// Menu bar urgency level with colour palettes
enum MenuBarUrgency: Equatable {
    case none       // No upcoming meetings or >30min away
    case low        // 15-30 min
    case medium     // 5-15 min
    case high       // <5 min or in progress
    case inProgress // Currently in a meeting

    /// Standard colour palette
    var standardColorName: String {
        switch self {
        case .none:       return "green"
        case .low:        return "yellow"
        case .medium:     return "orange"
        case .high, .inProgress: return "red"
        }
    }

    /// Colour-blind friendly palette — avoids red-green axis
    var colorBlindColorName: String {
        switch self {
        case .none:       return "blue"
        case .low:        return "cyan"
        case .medium:     return "orange"
        case .high, .inProgress: return "magenta"
        }
    }

    /// SF Symbol that changes shape per urgency (accessible without colour)
    var symbolName: String {
        switch self {
        case .none:       return "calendar"
        case .low:        return "calendar.badge.clock"
        case .medium:     return "calendar.badge.exclamationmark"
        case .high:       return "calendar.circle.fill"
        case .inProgress: return "calendar.circle.fill"
        }
    }

    static func from(minutesUntil: Double, isInProgress: Bool) -> MenuBarUrgency {
        if isInProgress { return .inProgress }
        if minutesUntil > 30 { return .none }
        if minutesUntil > 15 { return .low }
        if minutesUntil > 5 { return .medium }
        return .high
    }
}
