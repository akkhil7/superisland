import Foundation

// MARK: - Hook event

/// A Claude Code lifecycle event, as delivered to hook commands on stdin and
/// forwarded verbatim to Klip by the hook script.
public struct ClaudeHookEvent: Decodable, Equatable, Sendable {
    public let sessionID: String
    public let event: String
    public let message: String?
    public let cwd: String?
    /// The submitted prompt (UserPromptSubmit only) — used to derive a
    /// human-readable label for the session's klip.
    public let prompt: String?
    /// Controlling TTY of the agent process, e.g. "/dev/ttys003". Not part of
    /// the hook's stdin payload: the hook script reports it as a query
    /// parameter and the server fills it in. nil for desktop-app sessions.
    public var tty: String?

    public init(
        sessionID: String, event: String, message: String? = nil,
        cwd: String? = nil, prompt: String? = nil, tty: String? = nil
    ) {
        self.sessionID = sessionID
        self.event = event
        self.message = message
        self.cwd = cwd
        self.prompt = prompt
        self.tty = tty
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case event = "hook_event_name"
        case message, cwd, prompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        event = try container.decode(String.self, forKey: .event)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        tty = nil
    }
}

// MARK: - Event → status mapping

/// Klip-status semantics for Claude Code lifecycle events. Hooks are ground
/// truth: they replace AI classification for sessions that emit them.
public enum ClaudeHookMapper {
    public struct Update: Equatable, Sendable {
        /// nil = keep the current status, only record the reason.
        public let status: KlipStatus?
        public let reason: String

        public init(status: KlipStatus?, reason: String) {
            self.status = status
            self.reason = reason
        }
    }

    public static func update(for event: ClaudeHookEvent) -> Update? {
        switch event.event {
        case "UserPromptSubmit":
            return Update(status: .working, reason: "Claude is working…")
        case "Stop":
            return Update(status: .done, reason: "Claude finished — ready for you")
        case "StopFailure":
            return Update(status: .needsAttention, reason: event.message ?? "Claude hit an error")
        case "Notification":
            return Update(status: .needsAttention, reason: event.message ?? "Claude needs your input")
        case "SessionEnd":
            return Update(status: nil, reason: "Session ended")
        default:
            return nil
        }
    }
}

// MARK: - settings.json surgery

/// Pure insert/remove of Klip's hook entries in a Claude Code settings
/// dictionary. Operates on `[String: Any]` so the caller's settings.json is
/// preserved byte-for-byte in spirit: unknown keys untouched, existing hooks
/// kept, our entries identified by the script path.
public enum ClaudeHooksConfigurator {
    public static let events = ["UserPromptSubmit", "Stop", "StopFailure", "Notification", "SessionEnd"]
    /// Marker in the command path that identifies entries Klip owns.
    public static let commandMarker = "klip-claude-hook"

    public static func isInstalled(settings: [String: Any]) -> Bool {
        AgentHooksConfigurator.isInstalled(settings: settings, events: events, marker: commandMarker)
    }

    public static func install(settings: [String: Any], scriptPath: String) -> [String: Any] {
        AgentHooksConfigurator.install(
            settings: settings, scriptPath: scriptPath, events: events, marker: commandMarker
        )
    }

    public static func uninstall(settings: [String: Any]) -> [String: Any] {
        AgentHooksConfigurator.uninstall(settings: settings, marker: commandMarker)
    }
}

/// Shared insert/remove engine used by both the Claude and Codex hook
/// configurators — their config files share the same `hooks` JSON shape.
public enum AgentHooksConfigurator {
    public static func isInstalled(
        settings: [String: Any], events: [String], marker: String
    ) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            ownsEntry(in: (hooks[event] as? [[String: Any]]) ?? [], marker: marker)
        }
    }

    public static func install(
        settings: [String: Any], scriptPath: String, events: [String], marker: String
    ) -> [String: Any] {
        var out = settings
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            if !ownsEntry(in: groups, marker: marker) {
                groups.append([
                    "hooks": [["type": "command", "command": scriptPath]],
                ])
            }
            hooks[event] = groups
        }
        out["hooks"] = hooks
        return out
    }

    public static func uninstall(settings: [String: Any], marker: String) -> [String: Any] {
        var out = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return out }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                var g = group
                let inner = (group["hooks"] as? [[String: Any]]) ?? []
                let keptInner = inner.filter { !isOurCommand($0, marker: marker) }
                if keptInner.isEmpty, inner.count != keptInner.count { return nil }
                g["hooks"] = keptInner
                return g
            }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        if hooks.isEmpty {
            out.removeValue(forKey: "hooks")
        } else {
            out["hooks"] = hooks
        }
        return out
    }

    private static func ownsEntry(in groups: [[String: Any]], marker: String) -> Bool {
        groups.contains { group in
            ((group["hooks"] as? [[String: Any]]) ?? [])
                .contains { isOurCommand($0, marker: marker) }
        }
    }

    private static func isOurCommand(_ hook: [String: Any], marker: String) -> Bool {
        (hook["command"] as? String)?.contains(marker) == true
    }
}

// MARK: - Desktop session metadata

/// One local session of the Claude Desktop app (Cowork or Claude Code).
/// Parsed from `claude-code-sessions/**/local_<id>.json`, which is the join
/// table between the desktop's `local_` ids (in klip content URLs) and the
/// CLI session ids that hooks report.
public struct ClaudeLocalSession: Equatable, Sendable {
    public let sessionID: String      // local_<uuid> — appears in content URLs
    public let cliSessionID: String   // hook payload session_id
    public let title: String?

    public init(sessionID: String, cliSessionID: String, title: String?) {
        self.sessionID = sessionID
        self.cliSessionID = cliSessionID
        self.title = title
    }

    public static func parse(data: Data) -> ClaudeLocalSession? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = obj["sessionId"] as? String,
              let cliSessionID = obj["cliSessionId"] as? String
        else { return nil }
        return ClaudeLocalSession(
            sessionID: sessionID,
            cliSessionID: cliSessionID,
            title: obj["title"] as? String
        )
    }
}
