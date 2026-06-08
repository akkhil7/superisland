import Foundation

/// The lifecycle state of a klipped task, as surfaced on the island chip.
public enum KlipStatus: String, Codable, CaseIterable, Sendable {
    /// The task is actively running / producing output.
    case working
    /// The task has stopped and appears to be waiting for the user (a prompt, a question).
    case needsAttention
    /// The task finished.
    case done
    /// The window is gone / can no longer be located.
    case stale
    /// We don't yet have a confident read on the state.
    case unknown
}

/// How to find the exact window/tab again, per owning app.
///
/// `generic` works for any app (raise a specific Accessibility window). The
/// app-specific cases let us target an exact Chrome tab or Terminal window.
public enum Locator: Codable, Equatable, Sendable {
    case generic(axWindowTitle: String?, axWindowIndex: Int?)
    case chrome(windowIndex: Int, tabIndex: Int, url: String?, title: String?)
    case terminal(windowIndex: Int, tabIndex: Int?, tty: String?)
}

/// Everything needed to monitor and re-focus the window a klip points at.
public struct WindowTarget: Codable, Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var pid: Int32
    /// CGWindowID of the window at klip time (best-effort; may change if reopened).
    public var windowID: UInt32
    public var windowTitle: String
    public var locator: Locator

    public init(
        bundleID: String,
        appName: String,
        pid: Int32,
        windowID: UInt32,
        windowTitle: String,
        locator: Locator
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.pid = pid
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.locator = locator
    }
}

/// A single status transition, kept for the klip's short history.
public struct StatusEvent: Codable, Equatable, Sendable {
    public var status: KlipStatus
    public var reason: String
    public var at: Date

    public init(status: KlipStatus, reason: String, at: Date) {
        self.status = status
        self.reason = reason
        self.at = at
    }
}

/// A "bookmark" dropped on an in-progress task.
public struct Klip: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var label: String
    public var target: WindowTarget
    public var status: KlipStatus
    public var lastChecked: Date?
    public var history: [StatusEvent]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        label: String,
        target: WindowTarget,
        status: KlipStatus = .working,
        lastChecked: Date? = nil,
        history: [StatusEvent] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.label = label
        self.target = target
        self.status = status
        self.lastChecked = lastChecked
        self.history = history
    }
}
