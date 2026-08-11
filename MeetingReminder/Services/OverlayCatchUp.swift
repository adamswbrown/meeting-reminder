import Foundation

/// Pure decision logic for the "catch-up" full-screen overlay.
///
/// The normal blocking overlay in `MeetingMonitor` can only fire in two
/// windows: the pre-meeting window (`0…reminderMinutes` before start) and the
/// just-started window (`0…-60s` after start). If the app isn't running during
/// *both* of those — e.g. it was launched, relaunched, or redeployed after the
/// meeting already began — the overlay never fires and there is no catch-up.
/// The menu bar still shows "(in progress)" because that is recomputed live,
/// so the meeting is silently missed.
///
/// This decides whether an already-underway meeting should get a one-shot
/// catch-up overlay. Extracted so the branching is unit-testable without
/// timers, EventKit, or a live clock. See CLAUDE.md → "Meeting End Detection"
/// for the surrounding fire-window design.
enum OverlayCatchUp {

    /// How long after a meeting's start we'll still fire a catch-up overlay.
    /// Bounded so a long-running meeting the user is already in isn't nudged
    /// on every launch — 10 minutes is late enough to cover an app restart /
    /// redeploy, early enough that you almost certainly haven't settled in yet.
    static let window: TimeInterval = 10 * 60

    /// Decide whether a meeting that's already underway should get a one-shot
    /// catch-up overlay.
    ///
    /// - Parameters:
    ///   - timeUntilStart: `startDate - now` (`MeetingEvent.timeUntilStart`);
    ///     negative once the meeting has started.
    ///   - isInProgress: `now` is within `[startDate, endDate)`.
    ///   - hasEnded: `now >= endDate`.
    ///   - alreadyShown: the overlay has already been shown for this event
    ///     (tracked via `shownEventIDs`).
    ///   - isSnoozed: an active snooze exists for this event.
    ///   - isCurrentMeeting: this event is the one the user has already
    ///     joined / is currently in (`currentMeetingInProgress`).
    ///   - blockingAllowed: the blocking overlay tier is enabled.
    ///
    /// `triggerOverlay` itself downgrades to the screen-share-safe minimal
    /// alert when the mic is hot, so firing catch-up on a meeting the user is
    /// genuinely already in won't produce a full-screen blast.
    static func shouldFire(
        timeUntilStart: TimeInterval,
        isInProgress: Bool,
        hasEnded: Bool,
        alreadyShown: Bool,
        isSnoozed: Bool,
        isCurrentMeeting: Bool,
        blockingAllowed: Bool
    ) -> Bool {
        guard blockingAllowed, isInProgress, !hasEnded else { return false }
        guard !alreadyShown, !isSnoozed, !isCurrentMeeting else { return false }
        // Beyond the normal just-started window (-60s), but no longer than
        // `window` ago. The `0…-60s` case is already handled by the main loop.
        return timeUntilStart <= -60 && timeUntilStart > -window
    }
}
