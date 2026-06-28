import Foundation
import Combine
import SuperIslandCore

/// Cursor desktop agent integration via Cursor hooks: a tiny hook script
/// forwards lifecycle events (prompt submitted, response, stop) to
/// SuperIsland's local server, giving event-driven ground truth for the
/// Composer/agent pane — no AI classification, works for background windows.
///
/// Mirrors ClaudeIntegration's install model. Binding differs: the GUI has no
/// TTY, so drops bind by `conversation_id`. An in-memory conversation index,
/// fed by the event stream, answers "which conversation is active in this
/// workspace" at drop time (the analogue of Codex's currentSessionGuess).
@MainActor
final class CursorIntegration: ObservableObject {
    @Published private(set) var isInstalled = false

    static let bundleID = CursorDeepLink.bundleID
    static let sessionURLPrefix = CursorDeepLink.sessionURLPrefix

    static let scriptPath = ShellIntegration.configDir
        .appendingPathComponent("superisland-cursor-hook.sh")
    static let hooksPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cursor/hooks.json")

    init() { refresh() }

    func refresh() {
        isInstalled =
            FileManager.default.fileExists(atPath: Self.scriptPath.path)
            && CursorHooksConfigurator.isInstalled(config: Self.readConfig())
    }

    /// Re-sync our hook entries if the managed event set grew across an app
    /// update. Idempotent; preserves the user's own hooks.
    func reconcile() {
        guard FileManager.default.fileExists(atPath: Self.scriptPath.path),
            !CursorHooksConfigurator.isInstalled(config: Self.readConfig())
        else { return }
        try? install()
    }

    // MARK: - Install / Uninstall

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ShellIntegration.configDir, withIntermediateDirectories: true)
        try Self.hookScript.write(to: Self.scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.scriptPath.path)

        let updated = CursorHooksConfigurator.install(
            config: Self.readConfig(), scriptPath: Self.scriptPath.path
        )
        try Self.writeConfig(updated)
        refresh()
    }

    func uninstall() {
        let updated = CursorHooksConfigurator.uninstall(config: Self.readConfig())
        try? Self.writeConfig(updated)
        try? FileManager.default.removeItem(at: Self.scriptPath)
        refresh()
    }

    private static func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: hooksPath),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func writeConfig(_ config: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: hooksPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: hooksPath, options: .atomic)
    }

    /// Forwards the hook's stdin JSON to SuperIsland. The parent process is the
    /// agent itself; its controlling TTY (if any) tells SuperIsland which
    /// terminal a cursor-agent CLI session lives in ("??" for the GUI).
    private static var hookScript: String {
        """
        #!/bin/sh
        # SuperIsland Cursor hook — forwards lifecycle events to the SuperIsland app.
        # Installed by SuperIsland (Settings → Integrations). Safe to remove together
        # with its entries in ~/.cursor/hooks.json.
        SUPERISLAND_TTY=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
        curl -sf -m 2 -X POST "http://localhost:\(ShellServer.port)/cursor?tty=$SUPERISLAND_TTY" \\
            -H "Content-Type: application/json" \\
            --data-binary @- >/dev/null 2>&1
        exit 0
        """
    }

    // MARK: - Conversation index (fed by the event stream)

    private struct Conversation {
        var workspaceRoots: [String]
        var lastPrompt: String?
        var lastEventAt: Date
    }
    private var conversations: [String: Conversation] = [:]

    /// Record any hook event so drop-time binding can find the active
    /// conversation. Called by AppController on every Cursor hook event.
    func recordEvent(
        conversationID: String, workspaceRoots: [String], prompt: String?, at date: Date
    ) {
        var convo =
            conversations[conversationID]
            ?? Conversation(workspaceRoots: workspaceRoots, lastPrompt: nil, lastEventAt: date)
        if !workspaceRoots.isEmpty { convo.workspaceRoots = workspaceRoots }
        if let prompt, !prompt.isEmpty { convo.lastPrompt = prompt }
        convo.lastEventAt = date
        conversations[conversationID] = convo
    }

    /// The conversation a freshly dropped Cursor window belongs to: the most
    /// recently active conversation whose workspace basename matches the
    /// dropped window's workspace name, falling back to the most recently
    /// active conversation overall. Mirrors CodexIntegration.currentSessionGuess.
    func currentConversationGuess(workspaceName: String?) -> (id: String, title: String?)? {
        func basename(_ path: String) -> String {
            (path as NSString).lastPathComponent
        }
        let inWorkspace = conversations.filter { _, c in
            guard let workspaceName, !workspaceName.isEmpty else { return false }
            return c.workspaceRoots.contains { basename($0) == workspaceName }
        }
        let pool = inWorkspace.isEmpty ? conversations : inWorkspace
        guard let best = pool.max(by: { $0.value.lastEventAt < $1.value.lastEventAt })
        else { return nil }
        return (best.key, best.value.lastPrompt)
    }

    /// Classify a Cursor turn-end message into done vs needsAttention, shared
    /// with the Claude path.
    func classifyFinalMessage(
        _ text: String, bearer: String?
    ) async -> (status: DropStatus, reason: String)? {
        await classifyAgentFinalMessage(text, agentName: "Cursor", bearer: bearer)
    }
}
