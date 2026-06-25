import Foundation

/// Categories for internal diagnostic entries, used for filtering in the viewer.
public enum DiagnosticCategory: String, CaseIterable, Sendable {
    case app, auth, proxy, monitor, hooks, error
}

/// One diagnostic line: when, which launch produced it, its category, and text.
public struct DiagnosticEntry: Equatable, Sendable {
    public let date: Date
    public let launchID: String
    public let category: DiagnosticCategory
    public let message: String

    public init(date: Date, launchID: String, category: DiagnosticCategory, message: String) {
        self.date = date
        self.launchID = launchID
        self.category = category
        self.message = message
    }
}

/// Fixed-capacity ring buffer of diagnostic entries — oldest dropped first once
/// `capacity` is exceeded. Pure value type so it is trivially unit-testable.
public struct DiagnosticRingBuffer: Sendable {
    public let capacity: Int
    public private(set) var entries: [DiagnosticEntry] = []

    public init(capacity: Int = 1000) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ entry: DiagnosticEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    public func filtered(_ category: DiagnosticCategory?) -> [DiagnosticEntry] {
        guard let category else { return entries }
        return entries.filter { $0.category == category }
    }
}

/// Deterministic text rendering for entries and per-launch headers.
public enum DiagnosticFormat {
    /// `HH:mm:ss.SSS  [launchID]  CATEGORY  message`
    public static func line(_ entry: DiagnosticEntry, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: entry.date)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        let time = String(
            format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
        return
            "\(time)  [\(entry.launchID)]  \(entry.category.rawValue.uppercased())  \(entry.message)"
    }

    /// A divider that identifies a launch in the persisted (multi-session) log.
    public static func launchHeader(
        launchID: String, version: String, build: String, date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return
            "──── LAUNCH \(launchID) · v\(version) (build \(build)) · \(f.string(from: date)) ────"
    }
}
