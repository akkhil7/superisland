import Foundation
import Combine
import SuperIslandCore

/// Claude Desktop integration via Claude Code hooks: a tiny hook script
/// forwards lifecycle events (prompt submitted, finished, needs input) to
/// SuperIsland's local server, giving event-driven ground truth for Cowork and
/// Claude Code sessions — no AI classification, works for background tabs.
@MainActor
final class ClaudeIntegration: ObservableObject {
    @Published private(set) var isInstalled = false

    static let scriptPath = ShellIntegration.configDir
        .appendingPathComponent("superisland-claude-hook.sh")
    static let settingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    static let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    init() {
        refresh()
    }

    func refresh() {
        isInstalled =
            FileManager.default.fileExists(atPath: Self.scriptPath.path)
            && ClaudeHooksConfigurator.isInstalled(settings: Self.readSettings())
    }

    /// Re-sync our hook entries when the managed event set has grown across an
    /// app update: if the user already opted in (the script is present) but
    /// settings.json no longer lists every event we now manage, re-install to
    /// add the missing ones. Idempotent and preserves the user's own hooks.
    func reconcile() {
        guard FileManager.default.fileExists(atPath: Self.scriptPath.path),
            !ClaudeHooksConfigurator.isInstalled(settings: Self.readSettings())
        else { return }
        try? install()
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

    /// Forwards the hook's stdin JSON to SuperIsland. Synchronous on purpose: when
    /// SuperIsland isn't running the connection is refused instantly, so the hook
    /// never delays Claude noticeably.
    private static var hookScript: String {
        """
        #!/bin/sh
        # SuperIsland Claude Code hook — forwards lifecycle events to the SuperIsland app.
        # Installed by SuperIsland (Settings → Integrations). Safe to remove together
        # with its entries in ~/.claude/settings.json.
        # The parent process is the agent CLI itself; its controlling TTY tells
        # SuperIsland which terminal window this session lives in ("??" when none).
        SUPERISLAND_TTY=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
        curl -sf -m 2 -X POST "http://localhost:\(ShellServer.port)/claude?tty=$SUPERISLAND_TTY" \\
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
            Date().timeIntervalSince(sessionCacheAt) < 10
        {
            return hit
        }
        rebuildSessionCache()
        return sessionCache[cliID]
    }

    /// The conversation title for a Claude Desktop drop, resolved from the
    /// `local_<uuid>` embedded in its content URL (the session metadata is the
    /// only place the title lives). Lets a drop be named at drop time instead
    /// of waiting for a hook event — an idle/background conversation never
    /// emits one, so it would otherwise stay labelled just "Claude".
    func sessionTitle(forContentURL url: String) -> String? {
        func match() -> String? {
            sessionCache.values.first { url.contains($0.sessionID) }?.title
        }
        if Date().timeIntervalSince(sessionCacheAt) < 10, let title = match() {
            return title
        }
        rebuildSessionCache()
        return match()
    }

    /// The cached desktop session whose `local_<id>` appears in the content URL.
    func localSession(forContentURL url: String) -> ClaudeLocalSession? {
        func match() -> ClaudeLocalSession? {
            sessionCache.values.first { url.contains($0.sessionID) }
        }
        if Date().timeIntervalSince(sessionCacheAt) < 10, let hit = match() { return hit }
        rebuildSessionCache()
        return match()
    }

    /// On-disk transcript path for the Claude Desktop drop bound to this content
    /// URL, derived from the session's cwd + CLI id. nil if unresolved.
    func transcriptPath(forContentURL url: String) -> String? {
        guard let session = localSession(forContentURL: url),
            let cwd = session.cwd, !cwd.isEmpty
        else { return nil }
        return ClaudeTranscript.path(
            home: FileManager.default.homeDirectoryForCurrentUser,
            cwd: cwd,
            cliSessionID: session.cliSessionID
        ).path
    }

    /// Classify a Claude session's current state from its transcript tail:
    /// `.working` when a tool is mid-flight, otherwise — for an ended turn —
    /// done vs needsAttention. Uses Haiku via the proxy when a bearer token is
    /// available; falls back to a structural heuristic. nil = can't tell.
    func classifyTurnEnd(
        transcriptPath: String, bearer: String?
    ) async -> (status: DropStatus, reason: String)? {
        guard let tail = Self.readTail(path: transcriptPath, bytes: 64 * 1024) else { return nil }
        switch ClaudeTranscript.state(fromTail: tail) {
        case .working:
            return (.working, "Claude is working…")
        case .unknown:
            return nil
        case .turnEnded(let text):
            return await classifyFinalMessage(text, bearer: bearer)
        }
    }

    /// Classify an ended turn from Claude's final message directly — used for the
    /// `Stop` hook, whose payload carries `last_assistant_message`, so there's no
    /// need to read (and guess at) the transcript file. Uses the hosted proxy when
    /// a bearer token is provided; structural heuristic otherwise. nil for an empty message.
    func classifyFinalMessage(
        _ text: String, bearer: String?
    ) async -> (status: DropStatus, reason: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let bearer, !bearer.isEmpty {
            do {
                let verdict = try await ClaudeClassifier(
                    auth: .proxy(url: BackendConfig.classifyURL, bearer: bearer),
                    model: ClassifierProtocolBuilder.defaultModel
                ).classifyTurnEndMessage(trimmed)
                switch verdict.status {
                case .needsAttention: return (.needsAttention, verdict.reason)
                case .working: return (.working, "Claude is working…")
                default: return (.done, verdict.reason)
                }
            } catch let ClassifierError.quotaExceeded(used, cap) {
                return (.unknown, "Daily limit reached (\(used)/\(cap))")
            } catch {
                // transport/other error — fall through to the structural heuristic below
            }
        }
        return ClaudeTranscript.looksLikeRequest(trimmed)
            ? (.needsAttention, "Claude is waiting for your reply")
            : (.done, "Claude finished — ready for you")
    }

    private static func readTail(path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func rebuildSessionCache() {
        var cache: [String: ClaudeLocalSession] = [:]
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: Self.sessionsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return }
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
