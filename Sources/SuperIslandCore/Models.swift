import Foundation

/// The lifecycle state of a dropped task, as surfaced on the island chip.
public enum DropStatus: String, Codable, CaseIterable, Sendable {
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

/// Chrome-specific page/task anchor captured by the extension.
public struct ChromeTaskAnchor: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case aiResponse
        case form
        case document
        case generic
    }

    public var kind: Kind
    public var label: String

    public init(kind: Kind, label: String) {
        self.kind = kind
        self.label = label
    }
}

/// How to find the exact window/tab again, per owning app.
///
/// `generic` works for any app (raise a specific Accessibility window). The
/// app-specific cases let us target an exact Chrome tab or Terminal window.
public enum Locator: Codable, Equatable, Sendable {
    case generic(axWindowTitle: String?, axWindowIndex: Int?)
    /// `tabID` is Chrome's stable per-tab identifier — the most reliable key for
    /// refocusing the exact tab (survives navigation and reordering). `url`/
    /// `title`/`tabIndex` are fallbacks. Extension-backed drops can also carry
    /// Chrome's `windowID`, the current document id, and a task-specific DOM anchor.
    case chrome(
        windowID: Int?,
        windowIndex: Int,
        tabIndex: Int,
        tabID: Int?,
        url: String?,
        title: String?,
        documentID: String?,
        taskAnchor: ChromeTaskAnchor?
    )
    case terminal(windowIndex: Int, tabIndex: Int?, tty: String?)
    /// iTerm2 session id (a stable UUID per split/pane) — selects the exact
    /// tab and split, not just the window.
    case iterm(sessionID: String?)
    /// Shell-integration drop: identified by the TTY device path (/dev/ttysXXX).
    /// Status is driven directly by shell hook events, not AI classification.
    case shell(tty: String)
    /// VS Code / Cursor editor window. `filePath` is the absolute path of the
    /// file active at drop time (readable when the app sets the window's
    /// represented document); `fileName`/`workspaceName` come from the window
    /// title and back the fallback search when the path is unavailable.
    case editor(filePath: String?, fileName: String?, workspaceName: String?)
}

/// Everything needed to monitor and re-focus the window a drop points at.
public struct WindowTarget: Codable, Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var pid: Int32
    /// CGWindowID of the window at drop time (best-effort; may change if reopened).
    public var windowID: UInt32
    public var windowTitle: String
    public var locator: Locator
    /// Label of the in-app tab/section that was selected at drop time (e.g. a
    /// conversation in Claude Desktop, a task tab in Codex). Apps with internal
    /// tab mechanisms share one window across many tasks; this anchor is what
    /// lets two drops on the same window stay distinct: the monitor only reads
    /// the window while this anchor is the selected one, and refocus re-selects
    /// it. nil when the app exposes no selected element.
    public var contextAnchor: String?
    /// URL of the window's web content at drop time. Electron apps expose
    /// their SPA route on the AX web area (e.g. Claude Desktop:
    /// `https://claude.ai/epitaxy/local_<session-id>`), which changes per
    /// internal tab — an exact discriminator even when the app exposes no
    /// selected elements. nil for non-web windows.
    public var contentURL: String?

    public init(
        bundleID: String,
        appName: String,
        pid: Int32,
        windowID: UInt32,
        windowTitle: String,
        locator: Locator,
        contextAnchor: String? = nil,
        contentURL: String? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.pid = pid
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.locator = locator
        self.contextAnchor = contextAnchor
        self.contentURL = contentURL
    }
}

/// A single status transition, kept for the drop's short history.
public struct StatusEvent: Codable, Equatable, Sendable {
    public var status: DropStatus
    public var reason: String
    public var at: Date

    public init(status: DropStatus, reason: String, at: Date) {
        self.status = status
        self.reason = reason
        self.at = at
    }
}

/// A "bookmark" dropped on an in-progress task.
public struct Drop: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var label: String
    public var target: WindowTarget
    public var status: DropStatus
    public var lastChecked: Date?
    public var history: [StatusEvent]
    /// Optional encrypted visual restore memory id. Only populated for generic
    /// app drops that do not have a stronger integration.
    public var restoreMemoryID: UUID?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        label: String,
        target: WindowTarget,
        status: DropStatus = .working,
        lastChecked: Date? = nil,
        history: [StatusEvent] = [],
        restoreMemoryID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.label = label
        self.target = target
        self.status = status
        self.lastChecked = lastChecked
        self.history = history
        self.restoreMemoryID = restoreMemoryID
    }
}
