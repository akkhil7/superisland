import Foundation

/// Decides *when* to spend an evaluation on a klip's window.
///
/// Strategy: "change-then-settle". We feed it a cheap content hash of the
/// window on every tick. While the content keeps changing the task is busy, so
/// we wait. When the content stops changing for `settleInterval`, that
/// busy→quiet transition is exactly when a task tends to finish or start
/// waiting for input — so we evaluate. A long `fallbackInterval` guarantees we
/// still evaluate periodically for windows that never clearly settle.
///
/// One instance tracks one klip. Pure and deterministic: drive it with
/// `(hash, now)` pairs in tests.
public final class ChangeDetector {
    public let settleInterval: TimeInterval
    public let fallbackInterval: TimeInterval

    private var lastHash: Int?
    private var lastChangeTime: Date = .distantPast
    private var lastEvaluateTime: Date = .distantPast
    /// True when content has changed since the last evaluation — i.e. there is
    /// something new worth settling on.
    private var dirty: Bool = false

    public init(settleInterval: TimeInterval = 6, fallbackInterval: TimeInterval = 180) {
        self.settleInterval = settleInterval
        self.fallbackInterval = fallbackInterval
    }

    /// Feed one observation. Returns `true` when the caller should evaluate the
    /// window's state now (run the prefilter/classifier).
    public func observe(hash: Int, now: Date) -> Bool {
        guard let last = lastHash else {
            // First observation: prime state and schedule an initial settle.
            lastHash = hash
            lastChangeTime = now
            lastEvaluateTime = now
            dirty = true
            return false
        }

        let changed = hash != last
        if changed {
            lastHash = hash
            lastChangeTime = now
            dirty = true
        }

        // Settle: content was dirty and has now been quiet long enough. Only
        // possible when this tick did NOT change (otherwise it's still busy).
        if !changed && dirty && now.timeIntervalSince(lastChangeTime) >= settleInterval {
            dirty = false
            lastEvaluateTime = now
            return true
        }

        // Fallback safety net — checked on every tick, including ones where the
        // content changed, so windows that never go quiet (spinners, live logs)
        // still get evaluated periodically.
        if now.timeIntervalSince(lastEvaluateTime) >= fallbackInterval {
            lastEvaluateTime = now
            return true
        }

        return false
    }
}
