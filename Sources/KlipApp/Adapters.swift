import AppKit
import KlipCore

/// Per-app strategy for capturing a precise `Locator` at klip time and for
/// re-focusing the exact window/tab later. New apps get deep support by adding
/// an adapter; everything else falls back to `GenericAXAdapter`.
protocol AppAdapter {
    func canHandle(bundleID: String) -> Bool
    /// Build the locator for the just-klipped front window.
    func captureLocator(front: FrontWindow) -> Locator
    /// Bring the target back to the foreground. Returns true on success.
    @discardableResult
    func refocus(target: WindowTarget) -> Bool
}

/// Picks the right adapter for a bundle id. Generic is always last.
enum AdapterRegistry {
    static let adapters: [AppAdapter] = [ChromeAdapter(), TerminalAdapter()]
    static let generic = GenericAXAdapter()

    static func adapter(for bundleID: String) -> AppAdapter {
        adapters.first { $0.canHandle(bundleID: bundleID) } ?? generic
    }
}

// MARK: - Generic (any app)

/// Works for any app: raise the exact window via Accessibility, keyed on the
/// CGWindowID captured at klip time.
struct GenericAXAdapter: AppAdapter {
    func canHandle(bundleID: String) -> Bool { true }

    func captureLocator(front: FrontWindow) -> Locator {
        .generic(axWindowTitle: front.title, axWindowIndex: nil)
    }

    @discardableResult
    func refocus(target: WindowTarget) -> Bool {
        let pid = target.pid
        if let window = WindowFinder.axWindow(pid: pid, windowID: target.windowID) {
            return AX.raise(window: window, pid: pid)
        }
        // Window id no longer matches (reopened?). Try by title, else just
        // activate the app so the user lands in the right place.
        let appElement = AXUIElementCreateApplication(pid)
        if case let .generic(axTitle?, _) = target.locator {
            for w in AX.elementsAttribute(appElement, kAXWindowsAttribute as String)
            where AX.stringAttribute(w, kAXTitleAttribute as String) == axTitle {
                return AX.raise(window: w, pid: pid)
            }
        }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        return false
    }
}

// MARK: - Google Chrome (exact tab)

struct ChromeAdapter: AppAdapter {
    private let bundleIDs = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser"]
    private var appName = "Google Chrome"

    func canHandle(bundleID: String) -> Bool { bundleIDs.contains(bundleID) }

    func captureLocator(front: FrontWindow) -> Locator {
        // The klipped tab is the active tab of Chrome's front window.
        let script = """
        tell application "\(appName)"
            set w to front window
            set t to active tab of w
            return (URL of t) & "\n" & (title of t) & "\n" & (active tab index of w)
        end tell
        """
        let parts = (try? AppleScriptRunner.run(script))?
            .components(separatedBy: "\n") ?? []
        let url = parts.indices.contains(0) ? parts[0] : nil
        let title = parts.indices.contains(1) ? parts[1] : front.title
        let tabIndex = parts.indices.contains(2) ? Int(parts[2]) ?? 1 : 1
        return .chrome(windowIndex: 1, tabIndex: tabIndex, url: url, title: title)
    }

    @discardableResult
    func refocus(target: WindowTarget) -> Bool {
        guard case let .chrome(_, tabIndex, url, title) = target.locator else { return false }
        // Prefer matching by URL (stable across reordering); fall back to title,
        // then to the captured tab index.
        let matchClause: String
        if let url, !url.isEmpty {
            matchClause = "URL of t is \"\(escape(url))\""
        } else if let title, !title.isEmpty {
            matchClause = "title of t is \"\(escape(title))\""
        } else {
            matchClause = "false"
        }
        let script = """
        tell application "\(appName)"
            activate
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if \(matchClause) then
                        set active tab index of w to i
                        set index of w to 1
                        return "ok"
                    end if
                end repeat
            end repeat
            -- fallback: select the captured tab index of the front window
            try
                set active tab index of front window to \(tabIndex)
            end try
            return "fallback"
        end tell
        """
        let result = (try? AppleScriptRunner.run(script)) ?? ""
        return result == "ok" || result == "fallback"
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Terminal (exact window)

struct TerminalAdapter: AppAdapter {
    func canHandle(bundleID: String) -> Bool { bundleID == "com.apple.Terminal" }

    func captureLocator(front: FrontWindow) -> Locator {
        let tty = (try? AppleScriptRunner.run(
            "tell application \"Terminal\" to return tty of selected tab of front window"
        ))
        return .terminal(windowIndex: 1, tabIndex: nil, tty: tty)
    }

    @discardableResult
    func refocus(target: WindowTarget) -> Bool {
        // Raising the exact CGWindow via AX already lands on the right Terminal
        // window even with many open; activate the app to bring it forward.
        if let window = WindowFinder.axWindow(pid: target.pid, windowID: target.windowID) {
            return AX.raise(window: window, pid: target.pid)
        }
        NSRunningApplication(processIdentifier: target.pid)?
            .activate(options: [.activateAllWindows])
        return false
    }
}

// MARK: - Refocuser

/// Entry point used by the UI: route a klip to the adapter that owns it.
enum Refocuser {
    @discardableResult
    static func refocus(_ klip: Klip) -> Bool {
        AdapterRegistry.adapter(for: klip.target.bundleID).refocus(target: klip.target)
    }
}
