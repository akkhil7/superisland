import Foundation

/// Reads a Claude Code session transcript (the per-session `.jsonl` under
/// `~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl`) to recover the
/// session's CURRENT state — needed because hooks only tell us about events as
/// they fire. A drop created after the hooks fired, or a `Stop` that ended a
/// turn by asking the user something, both require reading the transcript.
public enum ClaudeTranscript {
    /// What the tail of the transcript says the session is doing right now.
    public enum State: Equatable, Sendable {
        /// A tool call is in flight (tool_use with no result yet) — running or
        /// awaiting approval.
        case working
        /// Claude ended its turn; `text` is its last message to the user. The
        /// caller decides done-vs-needs-you (a question/request → needs-you).
        case turnEnded(text: String)
        /// No readable assistant turn.
        case unknown
    }

    /// The on-disk transcript path for a session, given its working directory
    /// and CLI session id. Claude encodes the cwd by replacing each `/` and `.`
    /// with `-` (verified against live transcript paths).
    public static func path(home: URL, cwd: String, cliSessionID: String) -> URL {
        projectDirectory(home: home, cwd: cwd)
            .appendingPathComponent("\(cliSessionID).jsonl")
    }

    /// The directory holding all transcripts for a working directory. Lets a
    /// terminal drop find a running session's transcript by recency when the
    /// CLI session id isn't known (no hook has fired yet).
    public static func projectDirectory(home: URL, cwd: String) -> URL {
        let encoded = String(cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
        return
            home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
    }

    /// Parse a chunk from the end of a transcript and determine current state.
    /// Each line is a JSON object; message lines carry `message.role` and
    /// `message.content` (an array of typed blocks). Non-message lines
    /// (summaries, mode markers, partial first lines) are skipped.
    public static func state(fromTail tail: String) -> State {
        var lastToolUseIndex = -1
        var lastToolResultIndex = -1
        var lastAssistantText: String?
        var index = 0

        for line in tail.split(separator: "\n") {
            defer { index += 1 }
            guard let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = obj["message"] as? [String: Any],
                let role = message["role"] as? String
            else { continue }

            let blocks = (message["content"] as? [[String: Any]]) ?? []
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use" where role == "assistant":
                    lastToolUseIndex = index
                case "tool_result" where role == "user":
                    lastToolResultIndex = index
                case "text" where role == "assistant":
                    if let t = (block["text"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
                    {
                        lastAssistantText = t
                    }
                default:
                    break
                }
            }
        }

        // A tool_use more recent than any tool_result means a tool is pending.
        if lastToolUseIndex > lastToolResultIndex {
            return .working
        }
        if let text = lastAssistantText {
            return .turnEnded(text: text)
        }
        return .unknown
    }

    /// Heuristic fallback (when no API key): does Claude's closing message ask
    /// the user to do or answer something? Used only when AI classification
    /// isn't available.
    public static func looksLikeRequest(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        let lower = trimmed.lowercased()
        let cues = [
            "let me know", "could you", "can you ", "please ", "once you",
            "your call", "confirm", "should i ", "do you want", "which ",
            "tell me", "go ahead and", "waiting for you", "say \"", "say '",
            "approve", "let me know once", "ready when you", "over to you",
        ]
        return cues.contains { lower.contains($0) }
    }
}
