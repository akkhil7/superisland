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
