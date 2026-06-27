import Foundation

// MARK: - Agent command detection

/// Recognizes AI-agent CLIs typed into a terminal, so a terminal drop can
/// switch from plain command tracking to agent-session tracking the moment
/// one launches.
public enum AgentCommand {
    /// `"claude --resume"` / `"/usr/local/bin/codex"` → the agent's display
    /// name; nil for ordinary commands.
    public static func agentName(forCommand cmd: String) -> String? {
        let first = cmd.split(separator: " ").first.map(String.init) ?? cmd
        let bin = (first as NSString).lastPathComponent.lowercased()
        switch bin {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cursor-agent": return "Cursor Agent"
        default: return nil
        }
    }
}

// MARK: - Claude session on a terminal (drop-time status backfill)

/// Resolves the Claude Code session running in a terminal when a drop is
/// created over it. Hooks only fire on lifecycle *events*, so a drop made over
/// an already-running (idle) session has no incoming event — its status must be
/// recovered from the session's transcript, the same way Claude Desktop drops
/// are. These pure helpers do the selection; the app target supplies the live
/// `ps` output and directory listing.
public enum ClaudeTerminalSession {
    /// The pid of the Claude CLI running on a terminal, from
    /// `ps -t <tty> -o pid=,ppid=,command=` output. When claude is nested
    /// inside claude, returns the outermost one (the session that owns the
    /// terminal); nil when no claude is present.
    public static func claudePID(psOutput: String) -> Int32? {
        struct Proc { let pid: Int32; let ppid: Int32 }
        var claudes: [Proc] = []
        for line in psOutput.split(separator: "\n") {
            let cols = line.split(
                separator: " ", maxSplits: 2, omittingEmptySubsequences: true
            )
            guard cols.count >= 3,
                let pid = Int32(cols[0]), let ppid = Int32(cols[1]),
                AgentCommand.agentName(forCommand: String(cols[2])) == "Claude Code"
            else { continue }
            claudes.append(Proc(pid: pid, ppid: ppid))
        }
        let claudePIDs = Set(claudes.map(\.pid))
        // Outermost = a claude whose parent isn't itself a claude on this tty.
        return (claudes.first { !claudePIDs.contains($0.ppid) } ?? claudes.first)?.pid
    }

    /// The most recently modified transcript among candidates — the active
    /// session's, when several share one working directory.
    public static func newestTranscript(among files: [(url: URL, modified: Date)]) -> URL? {
        files.max { $0.modified < $1.modified }?.url
    }

    /// Whether a transcript-derived status is safe to seed onto a terminal drop
    /// at cold start (before any hook has fired). Only resting states qualify:
    /// `.working` is sticky — if the cold-start guess is wrong, or the matched
    /// session already finished, no later hook would ever clear it, leaving the
    /// drop falsely "working" forever. A genuinely active session emits tool
    /// hooks continuously and re-announces "working" within seconds, so leaving
    /// it briefly `.unknown` is the safe choice.
    public static func adoptsColdStartSeed(_ status: DropStatus) -> Bool {
        switch status {
        case .done, .needsAttention: return true
        case .working, .unknown, .stale: return false
        }
    }
}

// MARK: - Command → label

public enum CommandLabel {
    /// Chip-sized label for a shell command: the agent's name when it's an
    /// agent launch, otherwise the command line itself, single-line and
    /// truncated.
    public static func label(forCommand cmd: String, maxLength: Int = 32) -> String {
        if let agent = AgentCommand.agentName(forCommand: cmd) { return agent }
        let oneLine =
            cmd
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > maxLength else { return oneLine }
        return String(oneLine.prefix(maxLength - 1)) + "…"
    }
}

// MARK: - Agent session labels

public enum AgentSessionLabel {
    /// "Claude Code: fix the login bug" — built from the prompt the user just
    /// submitted, the most accurate description of what the agent is doing.
    /// nil when there's no usable prompt (keep the current label).
    public static func label(agent: String, prompt: String?, maxLength: Int = 60) -> String? {
        guard let prompt else { return nil }
        let oneLine =
            prompt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return nil }
        let full = "\(agent): \(oneLine)"
        guard full.count > maxLength else { return full }
        return String(full.prefix(maxLength - 1)) + "…"
    }
}

// MARK: - Hook request query (TTY routing)

/// Hook scripts append the agent process's controlling TTY as a query
/// parameter (`POST /claude?tty=ttys003`) — the join between a CLI agent
/// session and the terminal drop it runs in.
public enum HookRequestQuery {
    /// Extract a query parameter from a raw HTTP request path.
    public static func value(of name: String, inPath path: String) -> String? {
        guard let qIndex = path.firstIndex(of: "?") else { return nil }
        let query = path[path.index(after: qIndex)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == name else { continue }
            return String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return nil
    }

    /// `ps -o tty=` output → a device path: "ttys003" → "/dev/ttys003".
    /// "??" (no controlling TTY — e.g. a desktop-app session) → nil.
    public static func normalizeTTY(_ raw: String?) -> String? {
        guard var tty = raw?.trimmingCharacters(in: .whitespaces),
            !tty.isEmpty, tty != "??"
        else { return nil }
        if !tty.hasPrefix("/dev/") { tty = "/dev/" + tty }
        return tty
    }
}

// MARK: - Process-tree TTY discovery

/// Finds the TTYs of shells running *inside* another app (VS Code / Cursor
/// integrated terminals): their pty processes are descendants of the editor's
/// process tree.
public enum ProcessTreeTTY {
    public struct Entry: Equatable, Sendable {
        public let pid: Int32
        public let ppid: Int32
        public let tty: String?

        public init(pid: Int32, ppid: Int32, tty: String?) {
            self.pid = pid
            self.ppid = ppid
            self.tty = tty
        }
    }

    /// Parse `ps -axo pid=,ppid=,tty=` output (one process per line).
    public static func parse(psOutput: String) -> [Entry] {
        psOutput.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2,
                let pid = Int32(cols[0]), let ppid = Int32(cols[1])
            else { return nil }
            let tty = cols.count >= 3 ? String(cols[2]) : nil
            return Entry(pid: pid, ppid: ppid, tty: (tty == "??") ? nil : tty)
        }
    }

    /// Normalized TTY device paths of all processes whose ancestry includes
    /// `ancestorPID`, deduped, order unspecified.
    public static func ttys(underAncestor ancestorPID: Int32, entries: [Entry]) -> [String] {
        let parentOf = Dictionary(
            entries.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a }
        )
        func hasAncestor(_ pid: Int32) -> Bool {
            var current = pid
            var hops = 0
            while let parent = parentOf[current], hops < 32 {
                if parent == ancestorPID { return true }
                if parent == current || parent <= 1 { return false }
                current = parent
                hops += 1
            }
            return false
        }
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries {
            guard let tty = HookRequestQuery.normalizeTTY(entry.tty),
                hasAncestor(entry.pid),
                seen.insert(tty).inserted
            else { continue }
            out.append(tty)
        }
        return out
    }
}

// MARK: - Editor apps (VS Code)

public enum EditorApp {
    /// VS Code family. (Cursor was here until it became an agent integration —
    /// see CursorDeepLink / CursorIntegration.)
    public static let vsCode = "com.microsoft.VSCode"
    public static let vsCodeInsiders = "com.microsoft.VSCodeInsiders"
    public static let vsCodium = "com.vscodium"

    public static let bundleIDs: Set<String> = [vsCode, vsCodeInsiders, vsCodium]

    public static func isEditor(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    public static func displayName(bundleID: String) -> String {
        switch bundleID {
        case vsCodeInsiders: return "VS Code Insiders"
        case vsCodium: return "VSCodium"
        default: return "VS Code"
        }
    }

    /// Trailing window-title segments that are the app's own name, not content.
    static let appNameSegments: Set<String> = [
        "Visual Studio Code", "Visual Studio Code - Insiders", "VSCodium", "Cursor",
    ]
}

/// Parses VS Code / Cursor window titles. The default title shape is
/// `● activeEditor — rootName[ — appName]`; a window with no open editor is
/// just `rootName[ — appName]`.
public struct EditorWindowTitle: Equatable, Sendable {
    public let fileName: String?
    public let workspaceName: String?
    public let isDirty: Bool

    public init(fileName: String?, workspaceName: String?, isDirty: Bool) {
        self.fileName = fileName
        self.workspaceName = workspaceName
        self.isDirty = isDirty
    }

    public static func parse(_ title: String) -> EditorWindowTitle {
        var text = title.trimmingCharacters(in: .whitespaces)
        var isDirty = false
        if text.hasPrefix("●") {
            isDirty = true
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // VS Code uses an em-dash separator; tolerate en-dash and hyphen too.
        var segments: [String] = []
        for separator in [" — ", " – ", " - "] {
            segments = text.components(separatedBy: separator)
            if segments.count > 1 { break }
        }
        segments =
            segments
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let last = segments.last, EditorApp.appNameSegments.contains(last) {
            segments.removeLast()
        }
        switch segments.count {
        case 0:
            return EditorWindowTitle(fileName: nil, workspaceName: nil, isDirty: isDirty)
        case 1:
            // A lone segment is the workspace (no active editor).
            return EditorWindowTitle(fileName: nil, workspaceName: segments[0], isDirty: isDirty)
        default:
            return EditorWindowTitle(
                fileName: segments[0], workspaceName: segments.last, isDirty: isDirty
            )
        }
    }
}
