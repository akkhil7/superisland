import Foundation

/// Per-drop check schedule: starts at `baseInterval` seconds, multiplies by
/// `backoffFactor` after each check where content is unchanged, and resets to
/// `baseInterval` when content changes. Caps at `maxInterval`.
///
/// `isDue` returns `true` immediately on the first call so a freshly-dropped drop
/// gets its first classification without waiting. Pure and deterministic — drive
/// it with synthetic timestamps in tests.
public final class BackoffScheduler {
    public let baseInterval: TimeInterval
    public let backoffFactor: Double
    public let maxInterval: TimeInterval

    /// Current next-check interval. Readable for testing / display.
    public private(set) var currentInterval: TimeInterval
    private var nextCheckTime: Date = .distantPast

    public init(
        baseInterval: TimeInterval = 20,
        backoffFactor: Double = 1.5,
        maxInterval: TimeInterval = 300
    ) {
        self.baseInterval = baseInterval
        self.backoffFactor = backoffFactor
        self.maxInterval = maxInterval
        self.currentInterval = baseInterval
    }

    /// Whether this drop is due for a check right now.
    public func isDue(now: Date = Date()) -> Bool {
        now >= nextCheckTime
    }

    /// Call after each completed check.
    /// - Parameter contentChanged: true if the window's content hash differed
    ///   from the previous check — resets interval to base so changes are
    ///   watched closely.
    public func advance(contentChanged: Bool, now: Date = Date()) {
        if contentChanged {
            currentInterval = baseInterval
        } else {
            currentInterval = min(currentInterval * backoffFactor, maxInterval)
        }
        nextCheckTime = now.addingTimeInterval(currentInterval)
    }
}
