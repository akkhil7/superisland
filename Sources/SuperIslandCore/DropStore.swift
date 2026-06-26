import Foundation
import Combine

/// Owns the list of drops, applies status transitions, and persists to disk as
/// JSON so drops survive an app restart or crash.
///
/// `@Published drops` lets SwiftUI observe changes directly. Mutations are
/// expected on the main thread (the UI and pipeline callbacks hop to main).
@MainActor
public final class DropStore: ObservableObject {
    @Published public private(set) var drops: [Drop] = []

    private let fileURL: URL
    /// How many history events to keep per drop.
    private let historyLimit: Int

    public init(fileURL: URL, historyLimit: Int = 20) {
        self.fileURL = fileURL
        self.historyLimit = historyLimit
        load()
    }

    /// Default on-disk location: ~/Library/Application Support/SuperIsland/drops.json
    public static func defaultFileURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("SuperIsland", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("drops.json")
    }

    // MARK: - Mutations

    /// Append a new drop, unless it already points at a session another drop
    /// holds. A drop's non-nil `contentURL` is its session pointer; the store
    /// guarantees at most one drop per session, so a task is never tracked
    /// twice. Drops without a session pointer (nil contentURL) always append.
    /// Returns false when the drop was rejected as a duplicate session.
    @discardableResult
    public func add(_ drop: Drop) -> Bool {
        if let url = drop.target.contentURL,
            sessionOwnerIndex(forContentURL: url, excluding: drop.id) != nil
        {
            return false
        }
        drops.append(drop)
        save()
        return true
    }

    public func remove(id: Drop.ID) {
        drops.removeAll { $0.id == id }
        save()
    }

    public func rename(id: Drop.ID, label: String) {
        guard let i = index(of: id) else { return }
        drops[i].label = label
        save()
    }

    /// Update only the label (e.g. an async AI-suggested name), leaving
    /// status and history untouched.
    public func updateLabel(id: Drop.ID, label: String) {
        guard let i = index(of: id), !label.isEmpty else { return }
        drops[i].label = label
        save()
    }

    /// Name a drop only if it has no real name yet — its label is still the
    /// app/window-title placeholder it was born with. Sources that re-fire
    /// periodically (the AI monitor, an evolving Claude session title) use this
    /// so a drop is named *once* and its identity never churns afterward.
    public func nameIfUnnamed(id: Drop.ID, label: String?) {
        guard let label,
            !label.isEmpty,
            let i = index(of: id),
            LabelPolicy.isPlaceholder(drops[i].label, target: drops[i].target)
        else { return }
        drops[i].label = label
        save()
    }

    /// Re-bind a drop's content URL (e.g. attach a Codex CLI session that
    /// started inside an already-dropped terminal). nil clears the binding.
    /// Refuses — and returns false — when another drop already holds that
    /// session, so binding can never produce two drops on one session.
    /// Clearing (nil) and re-setting a drop's own URL always succeed.
    @discardableResult
    public func setContentURL(id: Drop.ID, url: String?) -> Bool {
        guard let i = index(of: id) else { return false }
        if let url, sessionOwnerIndex(forContentURL: url, excluding: id) != nil {
            return false
        }
        drops[i].target.contentURL = url
        save()
        return true
    }

    /// The drop currently bound to `url`, if any. A drop's non-nil
    /// `contentURL` is its session pointer; at most one drop holds a session.
    public func drop(forContentURL url: String) -> Drop? {
        sessionOwnerIndex(forContentURL: url).map { drops[$0] }
    }

    /// Apply a new status and, optionally, an AI-generated label to a drop.
    public func updateStatusAndLabel(
        id: Drop.ID,
        to status: DropStatus,
        label: String?,
        reason: String,
        at date: Date = Date()
    ) {
        guard let i = index(of: id) else { return }
        if let label, !label.isEmpty {
            drops[i].label = label
        }
        updateStatus(id: id, to: status, reason: reason, at: date)
    }

    /// Apply a new status to a drop, recording it in history and updating
    /// `lastChecked`. A no-op transition (same status) only refreshes
    /// `lastChecked` and does not append history.
    public func updateStatus(
        id: Drop.ID,
        to status: DropStatus,
        reason: String,
        at date: Date = Date()
    ) {
        guard let i = index(of: id) else { return }
        drops[i].lastChecked = date
        if drops[i].status != status {
            drops[i].status = status
            drops[i].history.append(
                StatusEvent(status: status, reason: reason, at: date)
            )
            if drops[i].history.count > historyLimit {
                drops[i].history.removeFirst(drops[i].history.count - historyLimit)
            }
        }
        save()
    }

    /// Record a new reason without changing status (e.g. "in a background
    /// tab"). Appends to history only when the reason actually changed, so
    /// periodic re-checks don't flood it.
    public func noteReason(id: Drop.ID, reason: String, at date: Date = Date()) {
        guard let i = index(of: id) else { return }
        drops[i].lastChecked = date
        if drops[i].history.last?.reason != reason {
            drops[i].history.append(
                StatusEvent(status: drops[i].status, reason: reason, at: date)
            )
            if drops[i].history.count > historyLimit {
                drops[i].history.removeFirst(drops[i].history.count - historyLimit)
            }
        }
        save()
    }

    public func drop(id: Drop.ID) -> Drop? {
        index(of: id).map { drops[$0] }
    }

    // MARK: - Persistence

    private func index(of id: Drop.ID) -> Int? {
        drops.firstIndex { $0.id == id }
    }

    /// Index of the drop holding session `url`, ignoring `id` (so a drop never
    /// collides with itself). nil when the session is free.
    private func sessionOwnerIndex(
        forContentURL url: String, excluding id: Drop.ID? = nil
    ) -> Int? {
        drops.firstIndex { $0.target.contentURL == url && $0.id != id }
    }

    /// Keep only the first drop for each session pointer (content URL),
    /// preserving order. Repairs any duplicates persisted before the
    /// uniqueness guard existed so the invariant holds from launch onward.
    static func deduplicatingSessions(_ drops: [Drop]) -> [Drop] {
        var seen = Set<String>()
        return drops.filter { drop in
            guard let url = drop.target.contentURL else { return true }
            return seen.insert(url).inserted
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder.drop.decode([Drop].self, from: data) {
            let deduped = Self.deduplicatingSessions(decoded)
            drops = deduped
            // Persist the repair so the file itself stops carrying duplicates.
            if deduped.count != decoded.count { save() }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder.drop.encode(drops) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var drop: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var drop: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
