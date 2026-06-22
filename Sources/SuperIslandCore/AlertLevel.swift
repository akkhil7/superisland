import Foundation

/// How loudly SuperIsland announces a status change. Each level has ONE primary
/// cue, getting progressively harder to miss — the counters are always present;
/// the higher levels swap in a stronger signal rather than stacking them (a
/// banner makes the colored notch redundant, so notify drops it).
///
///  - `.subtle`        — the island counters only.
///  - `.coloredNotch`  — counters + the whole notch pulsing in the status
///                       color, so a glance at the menu bar reads state.
///  - `.notify`        — counters + an explicit banner across the top of the
///                       screen on a change (no colored notch).
///
/// Pure and UI-free so it can be unit-tested and shared by Settings and the
/// island view.
public enum AlertLevel: Int, Codable, CaseIterable, Sendable {
    case subtle = 0
    case coloredNotch = 1
    case notify = 2

    /// Whether the notch should be tinted to the status color — only at the
    /// colored-notch level (notify uses the banner instead).
    public var showsColoredNotch: Bool { self == .coloredNotch }

    /// Whether an explicit top-of-screen banner fires on alerting transitions.
    public var showsBanner: Bool { self == .notify }

    /// Short label for the Settings picker.
    public var title: String {
        switch self {
        case .subtle: return "Counters only"
        case .coloredNotch: return "Colored notch"
        case .notify: return "Notifications"
        }
    }

    /// One-line explanation of how intrusive this level is.
    public var detail: String {
        switch self {
        case .subtle:
            return "Least intrusive — just the counts on the island."
        case .coloredNotch:
            return "Medium — the whole notch turns the status color."
        case .notify:
            return "Most intrusive — a banner drops from the top of the screen."
        }
    }
}

/// Decides when a status change is worth a louder cue. Pure so the rule is
/// unit-tested once and reused by the live transition watcher.
public enum AlertPolicy {
    /// Statuses that represent something the user cares about right now: a task
    /// waiting on them, or one that just finished.
    public static func isAlerting(_ status: DropStatus) -> Bool {
        status == .needsAttention || status == .done
    }

    /// Whether moving from `old` to `new` should raise an alert.
    ///
    /// A nil `old` is the first time we've ever seen this drop — we stay quiet
    /// so loading persisted drops (or dropping a fresh one) never fires a
    /// banner. A no-op transition (`old == new`) is likewise silent.
    public static func shouldAlert(from old: DropStatus?, to new: DropStatus) -> Bool {
        guard let old, old != new else { return false }
        return isAlerting(new)
    }

    /// What a status change should do to the banner row.
    public enum BannerAction: Equatable {
        /// Create the banner (or, if one already shows, replace its contents).
        case raise
        /// Update an existing banner's fields to track the drop's live state
        /// (label / source changes while it stays in an alerting status).
        case refresh
        /// Remove the banner: the drop has left its alerting state.
        case dismiss
        /// Leave the banner row untouched.
        case leave
    }

    /// Decide what to do with a drop's banner when its status changes.
    ///
    /// Banners exist only for alerting states (needsAttention / done): an
    /// alerting transition raises one, and an existing banner stays only while
    /// the drop is still alerting (refreshing its text). The moment the drop
    /// leaves an alerting state (needsAttention → working) the banner is
    /// dismissed — there are never "working" banners. With no banner showing and
    /// no alerting transition, nothing happens.
    public static func bannerAction(
        from old: DropStatus?, to new: DropStatus, hasBanner: Bool
    ) -> BannerAction {
        if shouldAlert(from: old, to: new) { return .raise }
        guard hasBanner else { return .leave }
        return isAlerting(new) ? .refresh : .dismiss
    }
}
