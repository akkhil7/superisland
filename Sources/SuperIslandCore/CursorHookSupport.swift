import Foundation

// MARK: - Hook event

/// A Cursor agent lifecycle event, delivered to hook commands on stdin and
/// forwarded verbatim to SuperIsland by the hook script. Cursor's payloads are
/// flatter than Claude's; only the fields SuperIsland uses are decoded.
public struct CursorHookEvent: Decodable, Equatable, Sendable {
    public let conversationID: String
    public let event: String
    /// Submitted prompt (beforeSubmitPrompt only) — used to label the drop.
    public let prompt: String?
    /// Assistant message text (afterAgentResponse only) — stashed and
    /// classified at turn end to tell "done" from "waiting on you".
    public let text: String?
    /// Turn outcome (stop only): "completed" | "aborted" | "error".
    public let status: String?
    /// Absolute workspace roots for the conversation — used to bind a GUI drop
    /// to the conversation active in the dropped window's workspace.
    public let workspaceRoots: [String]
    /// Controlling TTY of the hook process. Not in the stdin payload: the hook
    /// script reports it as a query parameter and the server fills it in. nil
    /// for the desktop GUI (no controlling TTY); set for the cursor-agent CLI.
    public var tty: String?

    public init(
        conversationID: String, event: String, prompt: String? = nil,
        text: String? = nil, status: String? = nil,
        workspaceRoots: [String] = [], tty: String? = nil
    ) {
        self.conversationID = conversationID
        self.event = event
        self.prompt = prompt
        self.text = text
        self.status = status
        self.workspaceRoots = workspaceRoots
        self.tty = tty
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case event = "hook_event_name"
        case workspaceRoots = "workspace_roots"
        case prompt, text, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        event = try c.decode(String.self, forKey: .event)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        workspaceRoots = try c.decodeIfPresent([String].self, forKey: .workspaceRoots) ?? []
        tty = nil
    }
}

// MARK: - Event → status mapping

/// SuperIsland-status semantics for Cursor agent lifecycle events. Hooks are
/// ground truth: they replace AI classification for conversations that emit
/// them. `stop` with status "completed" returns the resting baseline `.done`;
/// AppController refines it into done-vs-needsAttention from the assistant's
/// final message (captured via afterAgentResponse), the same way the Claude
/// Stop hook is refined.
public enum CursorHookMapper {
    public static func update(
        for event: CursorHookEvent
    ) -> ClaudeHookMapper.Update? {
        switch event.event {
        case "beforeSubmitPrompt":
            return ClaudeHookMapper.Update(status: .working, reason: "Cursor is working…")
        case "afterAgentResponse":
            // Informational: carries the assistant text to stash. Keep status.
            return ClaudeHookMapper.Update(status: nil, reason: "Cursor is working…")
        case "stop":
            switch event.status {
            case "error":
                return ClaudeHookMapper.Update(
                    status: .needsAttention, reason: "Cursor hit an error")
            case "aborted":
                return ClaudeHookMapper.Update(status: .done, reason: "Cursor stopped")
            default:  // "completed" (and any unknown terminal status)
                return ClaudeHookMapper.Update(
                    status: .done, reason: "Cursor finished — ready for you")
            }
        case "sessionEnd":
            return ClaudeHookMapper.Update(status: nil, reason: "Session ended")
        default:
            return nil
        }
    }
}

// MARK: - hooks.json surgery

/// Pure insert/remove of SuperIsland's entries in a Cursor `hooks.json`
/// dictionary. Cursor's schema is `{"version": 1, "hooks": {"<event>":
/// [{"command": "...", "type": "command"}]}}` — flatter than Claude's, so the
/// surgery is bespoke. Foreign hooks are preserved; ours are identified by the
/// marker substring in the command path.
public enum CursorHooksConfigurator {
    public static let events = [
        "beforeSubmitPrompt", "afterAgentResponse", "stop", "sessionEnd",
    ]
    /// Marker in the command path that identifies entries SuperIsland owns.
    public static let commandMarker = "superisland-cursor-hook"

    public static func isInstalled(config: [String: Any]) -> Bool {
        guard let hooks = config["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            ownsEntry(in: (hooks[event] as? [[String: Any]]) ?? [])
        }
    }

    public static func install(
        config: [String: Any], scriptPath: String
    ) -> [String: Any] {
        var out = config
        out["version"] = 1
        var hooks = (config["hooks"] as? [String: Any]) ?? [:]
        for event in events {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            if !ownsEntry(in: entries) {
                entries.append(["command": scriptPath, "type": "command"])
            }
            hooks[event] = entries
        }
        out["hooks"] = hooks
        return out
    }

    public static func uninstall(config: [String: Any]) -> [String: Any] {
        var out = config
        guard var hooks = config["hooks"] as? [String: Any] else { return out }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurCommand($0) }
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

    private static func ownsEntry(
        in entries: [[String: Any]]
    ) -> Bool {
        entries.contains { isOurCommand($0) }
    }

    private static func isOurCommand(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(commandMarker) == true
    }
}
