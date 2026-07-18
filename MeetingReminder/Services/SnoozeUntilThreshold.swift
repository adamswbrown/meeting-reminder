import Foundation

/// Snooze-until targets, relative to a meeting's start time.
///
/// Unlike the fixed-duration quick-snooze (30s / 1 min), these snooze the overlay until a
/// point measured backwards from the meeting start — "until 5 min before", "until start".
/// The raw value is minutes-before-start, so it doubles as the offset used to compute the
/// concrete snooze duration. Mirrors the toggle-per-tier pattern of `AlertTier`.
enum SnoozeUntilThreshold: Int, CaseIterable, Identifiable {
    case tenMin = 10
    case fiveMin = 5
    case twoMin = 2
    case start = 0

    var id: Int { rawValue }
    var minutesBeforeStart: Int { rawValue }

    var settingsKey: String {
        switch self {
        case .tenMin:  return "snoozeUntil10Enabled"
        case .fiveMin: return "snoozeUntil5Enabled"
        case .twoMin:  return "snoozeUntil2Enabled"
        case .start:   return "snoozeUntil0Enabled"
        }
    }

    /// Sensible out-of-the-box set: 5 / 2 / 0 on (the flow requested in issue #13),
    /// 10 off so the overlay isn't crowded for people who don't want the longest hop.
    var defaultEnabled: Bool {
        switch self {
        case .tenMin:                      return false
        case .fiveMin, .twoMin, .start:    return true
        }
    }

    var isEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: settingsKey) == nil ? defaultEnabled : defaults.bool(forKey: settingsKey)
    }

    /// Label for the Settings toggle.
    var displayName: String {
        switch self {
        case .start: return "Until start"
        default:     return "\(rawValue) min before"
        }
    }

    /// Compact label for the overlay button.
    var buttonLabel: String {
        switch self {
        case .start: return "Start"
        default:     return "\(rawValue) min"
        }
    }

    /// Seconds from now to snooze so the overlay re-fires at this threshold, given how many
    /// seconds remain until the meeting starts. Returns `nil` when the target is already in
    /// the past or within `minLead` seconds — those would re-fire (near-)instantly, so the
    /// button should not be offered.
    func snoozeSeconds(secondsUntilStart: Double, minLead: Double = 20) -> Int? {
        let target = secondsUntilStart - Double(minutesBeforeStart * 60)
        guard target >= minLead else { return nil }
        return Int(target)
    }

    /// The thresholds that are both enabled and still in the future for a meeting
    /// `secondsUntilStart` seconds away — i.e. the buttons the overlay should render.
    static func available(secondsUntilStart: Double) -> [SnoozeUntilThreshold] {
        allCases.filter { $0.isEnabled && $0.snoozeSeconds(secondsUntilStart: secondsUntilStart) != nil }
    }
}
