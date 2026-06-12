import Foundation

// MARK: - Event → status mapping

/// Klip-status semantics for Codex lifecycle events (same stdin payload shape
/// as Claude hooks; decoded with `ClaudeHookEvent`). Codex has no
/// Notification/StopFailure — approval prompts arrive as `PermissionRequest`.
public enum CodexHookMapper {
    public static func update(for event: ClaudeHookEvent) -> ClaudeHookMapper.Update? {
        switch event.event {
        case "UserPromptSubmit":
            return .init(status: .working, reason: "Codex is working…")
        case "Stop":
            return .init(status: .done, reason: "Codex finished — ready for you")
        case "PermissionRequest":
            return .init(status: .needsAttention, reason: event.message ?? "Codex needs your approval")
        default:
            return nil
        }
    }

    public static let events = ["UserPromptSubmit", "Stop", "PermissionRequest"]
    public static let commandMarker = "klip-codex-hook"
}

// MARK: - Session index

/// One thread from `~/.codex/session_index.jsonl` — the join between a hook's
/// session_id and a human-readable thread name. The Codex desktop app exposes
/// nothing through accessibility (no web areas, no titles), so this file is
/// the only identity source for its internal tabs.
public struct CodexSessionEntry: Equatable, Sendable {
    public let id: String
    public let threadName: String?
    public let updatedAt: Date?

    public init(id: String, threadName: String?, updatedAt: Date?) {
        self.id = id
        self.threadName = threadName
        self.updatedAt = updatedAt
    }
}

// MARK: - Rollout journal

/// The Codex desktop app does NOT run hooks (verified: only the embedded CLI
/// core supports them) — but it journals every turn to
/// `~/.codex/sessions/<y>/<m>/<d>/rollout-<ts>-<session-id>.jsonl`, appending
/// `event_msg` lines live. Watching those files is Klip's event source.
public enum CodexRollout {
    /// `rollout-2026-06-09T23-52-55-<uuid>.jsonl` → `<uuid>`.
    public static func sessionID(fromFilename name: String) -> String? {
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(".jsonl".count))
        guard stem.count > 36 else { return nil }
        let id = String(stem.suffix(36))
        // Loose UUID shape check: 8-4-4-4-12.
        let parts = id.split(separator: "-")
        guard parts.count == 5, parts.map(\.count) == [8, 4, 4, 4, 12] else { return nil }
        return id
    }

    /// Scan a chunk from the end of a rollout file and produce the latest
    /// status. Partial first lines (from seeking into the middle of the file)
    /// fail JSON parsing and are skipped naturally.
    public static func latestUpdate(fromTail tail: String) -> ClaudeHookMapper.Update? {
        var last: ClaudeHookMapper.Update?
        for line in tail.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  let kind = payload["type"] as? String
            else { continue }

            switch kind {
            case "task_started", "user_message":
                last = .init(status: .working, reason: "Codex is working…")
            case "task_complete":
                let message = (payload["last_agent_message"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = message.flatMap { $0.isEmpty ? nil : String($0.prefix(90)) }
                last = .init(status: .done, reason: summary ?? "Codex finished — ready for you")
            case "turn_aborted":
                last = .init(status: .unknown, reason: "Interrupted")
            case let k where k.contains("approval"):
                last = .init(status: .needsAttention, reason: "Codex needs your approval")
            default:
                break
            }
        }
        return last
    }
}

// MARK: - Workspace focus signal

/// The Codex desktop app persists no "selected thread" anywhere readable, but
/// `~/.codex/.codex-global-state.json` keeps `active-workspace-roots` — the
/// visible thread's project folder — updated within a second of every thread
/// switch (verified live). Klip binds drops to the freshest rollout *within*
/// that workspace.
public enum CodexWorkspaceState {
    public static func activeWorkspaceRoots(fromJSON data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return (obj["active-workspace-roots"] as? [String]) ?? []
    }

    /// Whether a session cwd belongs to one of the workspace roots.
    public static func cwd(_ cwd: String, isUnderAnyOf roots: [String]) -> Bool {
        roots.contains { root in
            cwd == root || cwd.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }
}

extension CodexRollout {
    /// Extract the session's working directory from the head of a rollout
    /// file (`session_meta` / `turn_context` lines carry `cwd`).
    public static func cwd(fromHead head: String) -> String? {
        for line in head.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { continue }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return nil
    }
}

/// Deep links into the Codex desktop app. `codex://threads/<session-id>`
/// opens the exact thread (verified live).
public enum CodexDeepLink {
    public static let bundleID = "com.openai.codex"
    public static let sessionURLPrefix = "codex://session/"

    public static func deepLink(forContentURL url: String) -> String? {
        guard url.hasPrefix(sessionURLPrefix) else { return nil }
        let id = String(url.dropFirst(sessionURLPrefix.count))
        guard !id.isEmpty else { return nil }
        return "codex://threads/\(id)"
    }
}

public enum CodexSessionIndex {
    /// Parse the JSONL index. Later lines win (the file is append-mostly, so
    /// the last entry for an id is the freshest).
    public static func parse(jsonl: String) -> [String: CodexSessionEntry] {
        var entries: [String: CodexSessionEntry] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in jsonl.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String
            else { continue }
            let dateString = obj["updated_at"] as? String
            let date = dateString.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            entries[id] = CodexSessionEntry(
                id: id,
                threadName: obj["thread_name"] as? String,
                updatedAt: date
            )
        }
        return entries
    }

    /// The most recently updated thread — the best guess for "what the user
    /// is looking at" when no hook event has identified it yet.
    public static func mostRecent(in entries: [String: CodexSessionEntry]) -> CodexSessionEntry? {
        entries.values.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }
}
