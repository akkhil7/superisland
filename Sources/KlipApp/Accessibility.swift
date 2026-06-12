import AppKit
import ApplicationServices

// Private API: maps an AXUIElement window to its CGWindowID. Widely used and
// stable; lets us tie a klip to an exact window. If it ever fails we fall back
// to matching via CGWindowList.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin conveniences over the C Accessibility API.
enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return err == .success ? value : nil
    }

    static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(element, name) else { return nil }
        return (v as! AXUIElement)
    }

    static func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(element, name) as? [AXUIElement]) ?? []
    }

    static func windowID(of window: AXUIElement) -> CGWindowID? {
        var id = CGWindowID(0)
        return _AXUIElementGetWindow(window, &id) == .success ? id : nil
    }

    /// Electron apps (Claude Desktop, Slack, VS Code, …) ship an empty AX tree
    /// until a client opts in by setting `AXManualAccessibility` on the app
    /// element. Idempotent and harmless for non-Electron apps (the attribute is
    /// simply unsupported there).
    static func enableManualAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// URL of the window's web content, if any. Chromium/Electron windows
    /// expose `AXWebArea` elements carrying `AXURL` — and the URL tracks the
    /// SPA route, so it changes when the user switches the app's internal tab
    /// (e.g. Claude Desktop sessions). Returns the *deepest* web area's URL:
    /// the outer one is the `file://` app shell, the nested one is the live
    /// content.
    static func webContentURL(of window: AXUIElement) -> String? {
        var best: (depth: Int, url: String)?
        var nodeBudget = 3000

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 30, nodeBudget > 0 else { return }
            nodeBudget -= 1
            if stringAttribute(element, kAXRoleAttribute as String) == "AXWebArea",
               let raw = attribute(element, "AXURL"),
               let url = (raw as? URL)?.absoluteString ?? (raw as? String),
               !url.isEmpty {
                if best == nil || depth > best!.depth || (depth == best!.depth && !url.hasPrefix("file:")) {
                    best = (depth, url)
                }
            }
            for child in elementsAttribute(element, kAXChildrenAttribute as String) {
                visit(child, depth: depth + 1)
            }
        }

        visit(window, depth: 0)
        return best?.url
    }

    /// Path of the document the window represents, if the app sets one
    /// (`AXDocument`). VS Code / Cursor keep it pointed at the active editor
    /// file, which gives an exact "right file" locator with zero setup.
    static func documentPath(of window: AXUIElement) -> String? {
        guard let raw = stringAttribute(window, kAXDocumentAttribute as String),
              !raw.isEmpty
        else { return nil }
        if raw.hasPrefix("file://"), let url = URL(string: raw) { return url.path }
        return raw
    }

    /// Whether the app's keyboard focus is inside an integrated terminal —
    /// detected by walking the focused element and a few ancestors looking for
    /// "terminal" in their role description, description, or title (VS Code /
    /// Cursor label their xterm panes this way).
    static func focusedElementLooksLikeTerminal(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var element = elementAttribute(app, kAXFocusedUIElementAttribute as String)
        var hops = 0
        while let el = element, hops < 6 {
            let texts = [
                stringAttribute(el, kAXRoleDescriptionAttribute as String),
                stringAttribute(el, kAXDescriptionAttribute as String),
                stringAttribute(el, kAXTitleAttribute as String),
            ]
            if texts.contains(where: { $0?.localizedCaseInsensitiveContains("terminal") == true }) {
                return true
            }
            element = elementAttribute(el, kAXParentAttribute as String)
            hops += 1
        }
        return false
    }

    /// Bring a specific AX window to the front: unminimize, raise, and activate
    /// its owning app. This is the generic refocus path that works for any app.
    @discardableResult
    static func raise(window: AXUIElement, pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
        }
        return raised
    }
}

/// Snapshot of the frontmost window at klip time.
struct FrontWindow {
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let windowID: CGWindowID
    /// The live AX element for the window (used to raise it again later).
    let axWindow: AXUIElement
}

enum WindowFinder {
    /// Identify the user's current frontmost window. Requires Accessibility.
    static func frontWindow() -> FrontWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return frontWindow(for: app)
    }

    /// Identify the focused window of a specific app. Requires Accessibility.
    static func frontWindow(for app: NSRunningApplication) -> FrontWindow? {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Prefer the app's focused window; fall back to its first window.
        let window = AX.elementAttribute(appElement, kAXFocusedWindowAttribute as String)
            ?? AX.elementsAttribute(appElement, kAXWindowsAttribute as String).first
        guard let window else { return nil }

        let title = AX.stringAttribute(window, kAXTitleAttribute as String) ?? app.localizedName ?? "Window"
        let windowID = AX.windowID(of: window)
            ?? CGWindowID(frontmostWindowID(forPID: pid) ?? 0)

        return FrontWindow(
            pid: pid,
            bundleID: app.bundleIdentifier ?? "",
            appName: app.localizedName ?? "App",
            title: title,
            windowID: windowID,
            axWindow: window
        )
    }

    /// Re-acquire an AX window for a pid by matching its CGWindowID, used when
    /// refocusing a klip whose original AX element is no longer valid.
    static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        for w in AX.elementsAttribute(appElement, kAXWindowsAttribute as String) {
            if AX.windowID(of: w) == windowID { return w }
        }
        return nil
    }

    /// CGWindowList fallback: topmost layer-0 window owned by pid.
    private static func frontmostWindowID(forPID pid: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in infos {
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let number = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return number
        }
        return nil
    }
}
