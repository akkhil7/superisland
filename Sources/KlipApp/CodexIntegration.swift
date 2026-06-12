import Foundation
import Combine
import KlipCore

/// Codex desktop integration — automatic, zero setup.
///
/// The Codex app is opaque to accessibility AND ignores hooks (they're
/// CLI-only), but it journals every turn to per-session rollout files under
/// `~/.codex/sessions/`. Klip watches those: the freshest rollout identifies
/// the thread you just prompted (drop-time binding), its appended events
/// drive klip status, and `codex://threads/<id>` deep-links back to it.
@MainActor
final class CodexIntegration: ObservableObject {
    static let bundleID = CodexDeepLink.bundleID
    /// Pseudo-URL stored in `WindowTarget.contentURL` for Codex klips.
    static let sessionURLPrefix = CodexDeepLink.sessionURLPrefix

    static let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    static let sessionIndexPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/session_index.jsonl")

    /// How much of a rollout's tail to scan for the latest status.
    private static let tailBytes = 64 * 1024

    static let globalStatePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/.codex-global-state.json")

    // MARK: - Drop-time binding

    /// The thread a freshly dropped klip belongs to. The desktop app keeps
    /// `active-workspace-roots` (the visible thread's project folder) fresh in
    /// its global state, so: freshest rollout *inside the active workspace*,
    /// falling back to the freshest rollout overall. Threads in different
    /// projects can never cross-bind; same-project threads resolve by recency
    /// (prompt the thread first and it's deterministic).
    func currentSessionGuess() -> (id: String, title: String?)? {
        let roots = activeWorkspaceRoots()
        let best = latestRollout { url in
            guard !roots.isEmpty else { return true }
            guard let cwd = self.rolloutCWD(url) else { return false }
            return CodexWorkspaceState.cwd(cwd, isUnderAnyOf: roots)
        } ?? latestRollout { _ in true }

        guard let (url, _) = best,
              let id = CodexRollout.sessionID(fromFilename: url.lastPathComponent)
        else { return nil }
        return (id, threadTitle(forID: id))
    }

    private func activeWorkspaceRoots() -> [String] {
        guard let data = try? Data(contentsOf: Self.globalStatePath) else { return [] }
        return CodexWorkspaceState.activeWorkspaceRoots(fromJSON: data)
    }

    private var cwdCache: [URL: String] = [:]

    private func rolloutCWD(_ url: URL) -> String? {
        if let cached = cwdCache[url] { return cached }
        // The first line (session_meta) embeds base instructions and runs
        // tens of KB — read generously so it parses as a complete line.
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 512 * 1024),
              let head = String(data: data, encoding: .utf8)
        else { return nil }
        try? handle.close()
        guard let cwd = CodexRollout.cwd(fromHead: head) else { return nil }
        cwdCache[url] = cwd
        return cwd
    }

    func threadTitle(forID id: String) -> String? {
        sessionIndex()[id]?.threadName
    }

    /// Number of threads in Codex's session index (shown during onboarding).
    var knownThreadCount: Int { sessionIndex().count }

    /// The session whose rollout file was created/touched after `date` — used
    /// to bind a `codex` CLI launch inside a klipped terminal to its session.
    func newestSessionID(modifiedAfter date: Date) -> String? {
        guard let (url, mtime) = latestRollout(where: { _ in true }), mtime > date
        else { return nil }
        return CodexRollout.sessionID(fromFilename: url.lastPathComponent)
    }

    // MARK: - Status polling (called by AppController every few seconds)

    private var rolloutPaths: [String: URL] = [:]
    private var lastMTimes: [String: Date] = [:]

    /// Latest status for a session, or nil when its rollout hasn't changed
    /// since the last call (or can't be found).
    func statusUpdate(forSessionID id: String) -> ClaudeHookMapper.Update? {
        guard let url = rolloutFile(forSessionID: id) else { return nil }
        guard let mtime = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        else { return nil }
        if let seen = lastMTimes[id], seen >= mtime { return nil }
        lastMTimes[id] = mtime

        guard let tail = Self.readTail(of: url, bytes: Self.tailBytes) else { return nil }
        return CodexRollout.latestUpdate(fromTail: tail)
    }

    // MARK: - Rollout discovery

    private func rolloutFile(forSessionID id: String) -> URL? {
        if let cached = rolloutPaths[id],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        rescanRollouts()
        return rolloutPaths[id]
    }

    private func latestRollout(where include: (URL) -> Bool) -> (URL, Date)? {
        rescanRollouts()
        var best: (URL, Date)?
        for url in rolloutPaths.values where include(url) {
            guard let mtime = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            else { continue }
            if best == nil || mtime > best!.1 { best = (url, mtime) }
        }
        return best
    }

    private func rescanRollouts() {
        guard let enumerator = FileManager.default.enumerator(
            at: Self.sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let id = CodexRollout.sessionID(fromFilename: url.lastPathComponent)
            else { continue }
            rolloutPaths[id] = url
        }
    }

    private static func readTail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Thread names

    private var indexCache: [String: CodexSessionEntry] = [:]
    private var indexCacheAt = Date.distantPast

    private func sessionIndex() -> [String: CodexSessionEntry] {
        if Date().timeIntervalSince(indexCacheAt) < 10 { return indexCache }
        let jsonl = (try? String(contentsOf: Self.sessionIndexPath, encoding: .utf8)) ?? ""
        indexCache = CodexSessionIndex.parse(jsonl: jsonl)
        indexCacheAt = Date()
        return indexCache
    }
}
