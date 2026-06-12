import Foundation
import Combine

/// Owns the list of klips, applies status transitions, and persists to disk as
/// JSON so klips survive an app restart or crash.
///
/// `@Published klips` lets SwiftUI observe changes directly. Mutations are
/// expected on the main thread (the UI and pipeline callbacks hop to main).
@MainActor
public final class KlipStore: ObservableObject {
    @Published public private(set) var klips: [Klip] = []

    private let fileURL: URL
    /// How many history events to keep per klip.
    private let historyLimit: Int

    public init(fileURL: URL, historyLimit: Int = 20) {
        self.fileURL = fileURL
        self.historyLimit = historyLimit
        load()
    }

    /// Default on-disk location: ~/Library/Application Support/Klip/klips.json
    public static func defaultFileURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Klip", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("klips.json")
    }

    // MARK: - Mutations

    public func add(_ klip: Klip) {
        klips.append(klip)
        save()
    }

    public func remove(id: Klip.ID) {
        klips.removeAll { $0.id == id }
        save()
    }

    public func rename(id: Klip.ID, label: String) {
        guard let i = index(of: id) else { return }
        klips[i].label = label
        save()
    }

    /// Update only the label (e.g. an async AI-suggested name), leaving
    /// status and history untouched.
    public func updateLabel(id: Klip.ID, label: String) {
        guard let i = index(of: id), !label.isEmpty else { return }
        klips[i].label = label
        save()
    }

    /// Re-bind a klip's content URL (e.g. attach a Codex CLI session that
    /// started inside an already-klipped terminal). nil clears the binding.
    public func setContentURL(id: Klip.ID, url: String?) {
        guard let i = index(of: id) else { return }
        klips[i].target.contentURL = url
        save()
    }

    /// Apply a new status and, optionally, an AI-generated label to a klip.
    public func updateStatusAndLabel(
        id: Klip.ID,
        to status: KlipStatus,
        label: String?,
        reason: String,
        at date: Date = Date()
    ) {
        guard let i = index(of: id) else { return }
        if let label, !label.isEmpty {
            klips[i].label = label
        }
        updateStatus(id: id, to: status, reason: reason, at: date)
    }

    /// Apply a new status to a klip, recording it in history and updating
    /// `lastChecked`. A no-op transition (same status) only refreshes
    /// `lastChecked` and does not append history.
    public func updateStatus(
        id: Klip.ID,
        to status: KlipStatus,
        reason: String,
        at date: Date = Date()
    ) {
        guard let i = index(of: id) else { return }
        klips[i].lastChecked = date
        if klips[i].status != status {
            klips[i].status = status
            klips[i].history.append(
                StatusEvent(status: status, reason: reason, at: date)
            )
            if klips[i].history.count > historyLimit {
                klips[i].history.removeFirst(klips[i].history.count - historyLimit)
            }
        }
        save()
    }

    /// Record a new reason without changing status (e.g. "in a background
    /// tab"). Appends to history only when the reason actually changed, so
    /// periodic re-checks don't flood it.
    public func noteReason(id: Klip.ID, reason: String, at date: Date = Date()) {
        guard let i = index(of: id) else { return }
        klips[i].lastChecked = date
        if klips[i].history.last?.reason != reason {
            klips[i].history.append(
                StatusEvent(status: klips[i].status, reason: reason, at: date)
            )
            if klips[i].history.count > historyLimit {
                klips[i].history.removeFirst(klips[i].history.count - historyLimit)
            }
        }
        save()
    }

    public func klip(id: Klip.ID) -> Klip? {
        index(of: id).map { klips[$0] }
    }

    // MARK: - Persistence

    private func index(of id: Klip.ID) -> Int? {
        klips.firstIndex { $0.id == id }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder.klip.decode([Klip].self, from: data) {
            klips = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder.klip.encode(klips) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var klip: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var klip: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
