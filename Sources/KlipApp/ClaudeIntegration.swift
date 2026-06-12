import Foundation
import Combine
import KlipCore

/// Claude Desktop integration via Claude Code hooks: a tiny hook script
/// forwards lifecycle events (prompt submitted, finished, needs input) to
/// Klip's local server, giving event-driven ground truth for Cowork and
/// Claude Code sessions — no AI classification, works for background tabs.
@MainActor
final class ClaudeIntegration: ObservableObject {
    @Published private(set) var isInstalled = false

    static let scriptPath = ShellIntegration.configDir
        .appendingPathComponent("klip-claude-hook.sh")
    static let settingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    static let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    init() {
        refresh()
    }

    func refresh() {
        isInstalled = FileManager.default.fileExists(atPath: Self.scriptPath.path)
            && ClaudeHooksConfigurator.isInstalled(settings: Self.readSettings())
    }

    // MARK: - Install / Uninstall

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ShellIntegration.configDir, withIntermediateDirectories: true)
        try Self.hookScript.write(to: Self.scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.scriptPath.path)

        let updated = ClaudeHooksConfigurator.install(
            settings: Self.readSettings(), scriptPath: Self.scriptPath.path
        )
        try Self.writeSettings(updated)
        refresh()
    }

    func uninstall() {
        let updated = ClaudeHooksConfigurator.uninstall(settings: Self.readSettings())
        try? Self.writeSettings(updated)
        try? FileManager.default.removeItem(at: Self.scriptPath)
        refresh()
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsPath, options: .atomic)
    }

    /// Forwards the hook's stdin JSON to Klip. Synchronous on purpose: when
    /// Klip isn't running the connection is refused instantly, so the hook
    /// never delays Claude noticeably.
    private static var hookScript: String {
        """
        #!/bin/sh
        # Klip Claude Code hook — forwards lifecycle events to the Klip app.
        # Installed by Klip (Settings → Integrations). Safe to remove together
        # with its entries in ~/.claude/settings.json.
        # The parent process is the agent CLI itself; its controlling TTY tells
        # Klip which terminal window this session lives in ("??" when none).
        KLIP_TTY=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
        curl -sf -m 2 -X POST "http://localhost:\(ShellServer.port)/claude?tty=$KLIP_TTY" \\
            -H "Content-Type: application/json" \\
            --data-binary @- >/dev/null 2>&1
        exit 0
        """
    }

    // MARK: - Session index (cliSessionId → local session)

    private var sessionCache: [String: ClaudeLocalSession] = [:]
    private var sessionCacheAt = Date.distantPast

    /// Resolve a hook's session_id to the desktop's local session. Scans the
    /// metadata files on miss (they're few), with a short cache for bursts.
    func localSession(forCLISessionID cliID: String) -> ClaudeLocalSession? {
        if let hit = sessionCache[cliID],
           Date().timeIntervalSince(sessionCacheAt) < 10 {
            return hit
        }
        rebuildSessionCache()
        return sessionCache[cliID]
    }

    private func rebuildSessionCache() {
        var cache: [String: ClaudeLocalSession] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Self.sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("local_"),
                  url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let session = ClaudeLocalSession.parse(data: data)
            else { continue }
            cache[session.cliSessionID] = session
        }
        sessionCache = cache
        sessionCacheAt = Date()
    }
}
