import Foundation

/// Decides whether a label is still the auto-derived placeholder a drop is born
/// with (its app name or raw window title) versus a real, meaningful name.
///
/// A drop's label is its identity — once it has a real name, re-classification
/// must never churn it. Sources that re-fire periodically (the AI monitor, a
/// Claude session whose title keeps evolving) name a drop *once*, while it's
/// still a placeholder, and leave it alone thereafter.
///
/// Pure and UI-free so it can be unit-tested and shared.
public enum LabelPolicy {
    public static func isPlaceholder(_ label: String, target: WindowTarget) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || trimmed == target.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmed == target.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Decides whether the AI monitor should spend a classification call on a drop
/// this tick.
///
/// A drop that has *settled* — `done` or `needsAttention`, i.e. it has stopped
/// and is waiting on the user — must not be re-classified while its window is
/// unchanged. Re-running the LLM on a finished conversation only produces
/// flip-flopping verdicts (`done ↔ needsAttention`) and burns quota. A real
/// content change (the user resumed the conversation) lifts the freeze, letting
/// the next classification carry it back to `working`.
///
/// `working`/`unknown` drops always re-classify: that's how completion (or a
/// first confident read) is detected.
///
/// Pure and UI-free so it can be unit-tested.
public enum MonitorPolicy {
    public static func shouldClassify(
        status: DropStatus,
        contentChanged: Bool,
        hasBaseline: Bool
    ) -> Bool {
        switch status {
        case .working, .unknown:
            return true
        case .done, .needsAttention:
            // Freeze a settled drop until its window actually changes. The
            // first read of a run (no baseline hash yet) is always allowed, so
            // a relaunch re-verifies a drop that may have moved on while the
            // app was closed.
            return !hasBaseline || contentChanged
        case .stale:
            // Stale drops are never classified (the tick loop already skips
            // them); treat as frozen for completeness.
            return false
        }
    }
}

/// Reconciles the two status owners for a Chrome web-AI drop: the extension
/// bridge owns the *live* `working` signal (network-detected), and the AI
/// monitor resolves the *resting* state (`done` vs `needsAttention`) from the
/// settled conversation. Pure and UI-free so it can be unit-tested.
public enum ChromeStatusPolicy {
    /// True when the AI monitor should SKIP this drop because the bridge is
    /// actively driving it. Only chrome drops, only while the bridge is
    /// connected AND the drop is live-`working`; once it settles (or the bridge
    /// disconnects) the monitor takes over so it can resolve needsAttention.
    public static func bridgeOwnsLiveStatus(
        locator: Locator,
        status: DropStatus,
        bridgeConnected: Bool
    ) -> Bool {
        guard case .chrome = locator else { return false }
        return bridgeConnected && status == .working
    }

    /// True when the monitor MAY apply this verdict. For a chrome drop the bridge
    /// owns the live `working` signal, so an AI `working` verdict is ignored;
    /// `done` / `needsAttention` / `unknown` / `stale` apply normally.
    public static func monitorMayApply(verdict: DropStatus, locator: Locator) -> Bool {
        if case .chrome = locator, verdict == .working { return false }
        return true
    }
}
