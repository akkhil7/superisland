import Foundation

/// Reasoning about a Claude Code session's permission mode (the `permission_mode`
/// field on hook events).
public enum ClaudePermissionMode {
    /// Whether the next tool call can block on a user-approval prompt in this
    /// mode.
    ///
    /// Modes that auto-run every tool — `bypassPermissions` and `auto` — never
    /// surface a prompt, so a tool that hasn't finished is simply *running*, not
    /// waiting on you. The monitor must not arm its "needs your permission"
    /// stall in those modes, or a long-running tool (a build, a slow command)
    /// false-flips the session to needs-attention while it's actually working.
    ///
    /// `acceptEdits` auto-accepts file edits but STILL prompts for Bash and
    /// other tools, so it counts as prompting. Unknown / unspecified modes are
    /// assumed to prompt, so a genuine in-app permission request isn't missed.
    public static func canPrompt(_ mode: String?) -> Bool {
        switch mode {
        case "bypassPermissions", "auto": return false
        default: return true  // default / plan / acceptEdits / unknown
        }
    }
}
