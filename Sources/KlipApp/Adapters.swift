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
    static let adapters: [AppAdapter] = [
        ChromeAdapter(), TerminalAdapter(), ITermAdapter(), EditorAdapter(),
    ]
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
            let raised = AX.raise(window: window, pid: pid)
            reselectContextTab(target: target)
            return raised
        }
        // Window id no longer matches (reopened?). Try by title, else just
        // activate the app so the user lands in the right place.
        let appElement = AXUIElementCreateApplication(pid)
        if case let .generic(axTitle?, _) = target.locator {
            for w in AX.elementsAttribute(appElement, kAXWindowsAttribute as String)
            where AX.stringAttribute(w, kAXTitleAttribute as String) == axTitle {
                let raised = AX.raise(window: w, pid: pid)
                reselectContextTab(target: target)
                return raised
            }
        }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        return false
    }

    /// For apps with internal tabs: after raising the window, press the in-app
    /// tab/section that was selected when the klip was dropped. Runs slightly
    /// delayed so the freshly-raised app has settled.
    private func reselectContextTab(target: WindowTarget) {
        guard target.contextAnchor != nil || target.contentURL != nil else { return }
        let pid = target.pid
        let windowID = target.windowID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let window = WindowFinder.axWindow(pid: pid, windowID: windowID) else { return }
            if let klipURL = target.contentURL {
                // Already on the right in-app tab? (Electron route matches.)
                if let currentURL = AX.webContentURL(of: window),
                   ContentURL.matches(currentURL, klipURL) {
                    return
                }
                // Claude Desktop handles claude:// deep links — navigate
                // straight to the klipped session.
                if target.bundleID == ClaudeDeepLink.bundleID,
                   let link = ClaudeDeepLink.deepLink(forContentURL: klipURL),
                   let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                    return
                }
                // Codex desktop: codex://threads/<id> opens the exact thread.
                if target.bundleID == CodexDeepLink.bundleID,
                   let link = CodexDeepLink.deepLink(forContentURL: klipURL),
                   let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                    return
                }
            }
            guard let anchor = target.contextAnchor else { return }
            let candidates = RestoreAnchorCollector.collect(from: window)
                .filter { !$0.anchor.label.isEmpty && $0.element != nil }
            // Prefer an exact-label match that isn't already selected; fall
            // back to any match (pressing the selected tab is a no-op).
            let matches = candidates.filter {
                RestoreMatcher.labelsMatch($0.anchor.label, anchor)
            }
            guard let best = matches.first(where: { !$0.anchor.isSelected }) ?? matches.first,
                  let element = best.element
            else { return }
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }
}

// MARK: - Google Chrome (exact tab)

struct ChromeAdapter: AppAdapter {
    private let bundleIDs = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser"]
    private var appName = "Google Chrome"

    func canHandle(bundleID: String) -> Bool { bundleIDs.contains(bundleID) }

    func captureLocator(front: FrontWindow) -> Locator {
        // AppleScript reads the ACTUAL active tab at klip time — ground truth.
        // The bridge's "last active tab" can lag a fast tab switch, which used
        // to bind klips (and their refocus) to the wrong tab.
        let script = """
        tell application "\(appName)"
            set w to front window
            set t to active tab of w
            return ((id of t) as string) & "\\n" & (URL of t) & "\\n" & (title of t) & "\\n" & (active tab index of w)
        end tell
        """
        let parts = (try? AppleScriptRunner.run(script))?
            .components(separatedBy: "\n") ?? []
        if parts.count >= 4 {
            let appleScriptID = Int(parts[0])
            let url = parts[1]
            let title = parts[2].isEmpty ? front.title : parts[2]
            let tabIndex = Int(parts[3]) ?? 1
            // Enrich with the extension's ids — a DIFFERENT id space than
            // AppleScript's. windowID != nil marks tabID as an extension id.
            let bridgeTab = ChromeBridgeStateStore.shared.tab(matchingURL: url, orTitle: title)
            return .chrome(
                windowID: bridgeTab?.windowID,
                windowIndex: 1,
                tabIndex: bridgeTab?.index ?? tabIndex,
                tabID: bridgeTab?.tabID ?? appleScriptID,
                url: url.isEmpty ? bridgeTab?.url : url,
                title: title,
                documentID: bridgeTab?.documentID,
                taskAnchor: ChromeTaskAnchor(kind: .generic, label: title)
            )
        }

        // Automation unavailable: the bridge's title-verified view is the best
        // we have.
        if let tab = ChromeBridgeStateStore.shared.bestActiveTab(matchingTitle: front.title) {
            return .chrome(
                windowID: tab.windowID,
                windowIndex: 1,
                tabIndex: tab.index,
                tabID: tab.tabID,
                url: tab.url,
                title: tab.title ?? front.title,
                documentID: tab.documentID,
                taskAnchor: tab.title.map { ChromeTaskAnchor(kind: .generic, label: $0) }
            )
        }
        return .chrome(
            windowID: nil, windowIndex: 1, tabIndex: 1, tabID: nil,
            url: nil, title: front.title, documentID: nil, taskAnchor: nil
        )
    }

    @discardableResult
    func refocus(target: WindowTarget) -> Bool {
        guard case let .chrome(windowID, _, tabIndex, tabID, url, title, _, _) = target.locator else {
            return false
        }
        // Bridge refocus needs an EXTENSION tab id. windowID != nil is the
        // marker that tabID came from the bridge — an AppleScript id sent to
        // chrome.tabs.update() would target a different (or no) tab.
        if let tabID, windowID != nil, ChromeBridgeStateStore.shared.isConnected {
            ChromeBridgeStateStore.shared.enqueueRefocus(tabID: tabID, windowID: windowID)
            return true
        }

        // AppleScript: match by any identity we hold — the id clause only hits
        // for AppleScript-captured ids, so URL/title carry bridge-captured
        // klips.
        var clauses: [String] = []
        if let tabID { clauses.append("(id of t) is \(tabID)") }
        if let url, !url.isEmpty { clauses.append("URL of t is \"\(escape(url))\"") }
        if let title, !title.isEmpty { clauses.append("title of t is \"\(escape(title))\"") }
        let matchClause = clauses.isEmpty ? "false" : clauses.joined(separator: " or ")
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
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        // If shell integration is installed and we have a TTY, hand off to the
        // shell event pipeline for status updates + TTY-based refocus.
        if ShellIntegration.isScriptInstalled, let tty, !tty.isEmpty {
            return .shell(tty: tty)
        }
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

// MARK: - iTerm2 (exact tab + split)

struct ITermAdapter: AppAdapter {
    // Target iTerm2 by bundle id to avoid the "iTerm" vs "iTerm2" name ambiguity.
    private let appRef = "id \"com.googlecode.iterm2\""

    func canHandle(bundleID: String) -> Bool { bundleID == "com.googlecode.iterm2" }

    func captureLocator(front: FrontWindow) -> Locator {
        // If shell integration is installed, capture the TTY for shell-event-driven updates.
        if ShellIntegration.isScriptInstalled {
            let ttyScript = "tell application \(appRef) to return tty of current session of current tab of current window"
            let tty = (try? AppleScriptRunner.run(ttyScript))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let tty, !tty.isEmpty { return .shell(tty: tty) }
        }
        // Fall back to stable session UUID (iTerm2-specific).
        let script = """
        tell application \(appRef)
            return id of current session of current tab of current window
        end tell
        """
        let sid = (try? AppleScriptRunner.run(script))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .iterm(sessionID: (sid?.isEmpty == false) ? sid : nil)
    }

    @discardableResult
    func refocus(target: WindowTarget) -> Bool {
        guard case let .iterm(sessionID) = target.locator, let sid = sessionID else {
            // No session id (e.g. captured before Automation was granted): fall
            // back to raising the exact window.
            if let window = WindowFinder.axWindow(pid: target.pid, windowID: target.windowID) {
                return AX.raise(window: window, pid: target.pid)
            }
            return false
        }
        let script = """
        tell application \(appRef)
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is "\(sid)" then
                            select w
                            select t
                            select s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "miss"
        end tell
        """
        let result = (try? AppleScriptRunner.run(script)) ?? ""
        return result == "ok"
    }
}

// MARK: - VS Code / Cursor (exact file + integrated terminal)

/// Zero-setup adapter for VS Code-family editors and Cursor.
///
/// Two kinds of klips, picked by where keyboard focus is at drop time:
/// - Focus in an integrated terminal → `.shell(tty:)`, found by walking the
///   process tree for shells under the editor's pid; the shell/agent hook
///   pipeline then drives status exactly like a standalone terminal.
/// - Focus in the editor → `.editor`, carrying the active file's absolute
///   path (AXDocument) plus title-derived names as fallback. Refocus raises
///   the exact window, then re-opens the file so the right tab is selected.
struct EditorAdapter: AppAdapter {
    func canHandle(bundleID: String) -> Bool { EditorApp.isEditor(bundleID: bundleID) }

    func captureLocator(front: FrontWindow) -> Locator {
        if ShellIntegration.isScriptInstalled,
           AX.focusedElementLooksLikeTerminal(pid: front.pid),
           let tty = Self.activeIntegratedTerminalTTY(appPID: front.pid) {
            return .shell(tty: tty)
        }
        let parsed = EditorWindowTitle.parse(front.title)
        return .editor(
            filePath: AX.documentPath(of: front.axWindow),
            fileName: parsed.fileName,
            workspaceName: parsed.workspaceName
        )
    }

    @discardableResult
    func refocus(target: WindowTarget) -> Bool {
        guard case let .editor(filePath, _, workspaceName) = target.locator else {
            return false
        }
        // 1. Raise the exact window (or one showing the same workspace).
        var raised = false
        if let window = WindowFinder.axWindow(pid: target.pid, windowID: target.windowID) {
            raised = AX.raise(window: window, pid: target.pid)
        } else if let workspaceName {
            let appElement = AXUIElementCreateApplication(target.pid)
            for w in AX.elementsAttribute(appElement, kAXWindowsAttribute as String)
            where AX.stringAttribute(w, kAXTitleAttribute as String)?
                .contains(workspaceName) == true {
                raised = AX.raise(window: w, pid: target.pid)
                break
            }
        }
        if !raised {
            NSRunningApplication(processIdentifier: target.pid)?
                .activate(options: [.activateAllWindows])
        }
        // 2. Re-select the exact file: opening it routes to the window that
        //    has it (the one we just raised) and focuses its editor tab.
        if let filePath, FileManager.default.fileExists(atPath: filePath),
           let appURL = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: target.bundleID
           ) {
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: filePath)],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return true
        }
        return raised
    }

    /// The TTY of the editor's most recently active integrated terminal:
    /// shells under the editor's process tree, newest device activity wins.
    static func activeIntegratedTerminalTTY(appPID: pid_t) -> String? {
        guard let psOutput = runPS() else { return nil }
        let ttys = ProcessTreeTTY.ttys(
            underAncestor: appPID, entries: ProcessTreeTTY.parse(psOutput: psOutput)
        )
        return ttys.max { deviceActivity($0) < deviceActivity($1) }
    }

    private static func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func deviceActivity(_ tty: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: tty)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
    }
}

// MARK: - Shell (TTY-based refocus for shell-integration klips)

struct ShellAdapter: AppAdapter {
    func canHandle(bundleID: String) -> Bool { false }

    func captureLocator(front: FrontWindow) -> Locator {
        .generic(axWindowTitle: front.title, axWindowIndex: nil)
    }

    @discardableResult
    func refocus(target: WindowTarget) -> Bool {
        guard case let .shell(tty) = target.locator else { return false }

        // Integrated terminals (VS Code / Cursor): the TTY lives inside the
        // editor, so skip the terminal-app searches — they'd miss AND launch
        // Terminal.app as a side effect. Raise the editor window directly.
        if EditorApp.isEditor(bundleID: target.bundleID) {
            if let window = WindowFinder.axWindow(pid: target.pid, windowID: target.windowID) {
                return AX.raise(window: window, pid: target.pid)
            }
            NSRunningApplication(processIdentifier: target.pid)?
                .activate(options: [.activateAllWindows])
            return false
        }

        let escaped = tty.replacingOccurrences(of: "\"", with: "\\\"")

        // Search by TTY first, activate ONLY on a match — activating up front
        // raised the wrong terminal app whenever its search missed (a klip
        // saved in iTerm could end up opening Terminal.app).
        let iterm = """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escaped)" then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "miss"
        end tell
        """
        if (try? AppleScriptRunner.run(iterm)) == "ok" { return true }

        let terminal = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escaped)" then
                        set selected of t to true
                        set frontmost of w to true
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
            return "miss"
        end tell
        """
        if (try? AppleScriptRunner.run(terminal)) == "ok" { return true }

        // Last resort: raise by CGWindowID if the window is still open.
        if let window = WindowFinder.axWindow(pid: target.pid, windowID: target.windowID) {
            return AX.raise(window: window, pid: target.pid)
        }
        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [.activateAllWindows])
        return false
    }
}

// MARK: - Refocuser

/// Entry point used by the UI: route a klip to the adapter that owns it.
enum Refocuser {
    @discardableResult
    static func refocus(_ klip: Klip) -> Bool {
        if case .shell = klip.target.locator {
            return ShellAdapter().refocus(target: klip.target)
        }
        return AdapterRegistry.adapter(for: klip.target.bundleID).refocus(target: klip.target)
    }
}
