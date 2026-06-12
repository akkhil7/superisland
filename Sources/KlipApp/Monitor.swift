import AppKit
import KlipCore

/// Background pipeline: polls every 5 s to see which klips are due (per-klip
/// exponential backoff starting at 20 s), then takes a full snapshot and calls
/// Claude to classify + label the window.
@MainActor
final class KlipMonitor: ObservableObject {
    private let store: KlipStore
    private let settings: Settings
    private var timer: Timer?
    private var schedulers: [UUID: BackoffScheduler] = [:]
    private var lastHashes: [UUID: Int] = [:]
    private var inFlight: Set<UUID> = []

    /// Klips driven by an event source (Claude Code hooks) — ground truth that
    /// makes AI polling unnecessary and potentially conflicting.
    var isExternallyManaged: ((Klip) -> Bool)?

    init(store: KlipStore, settings: Settings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        stop()
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func resetSchedulers() {
        schedulers.removeAll()
        lastHashes.removeAll()
    }

    private func scheduler(for id: UUID) -> BackoffScheduler {
        if let s = schedulers[id] { return s }
        let s = BackoffScheduler()
        schedulers[id] = s
        return s
    }

    private func tick() {
        let liveIDs = Set(store.klips.map(\.id))
        schedulers = schedulers.filter { liveIDs.contains($0.key) }
        lastHashes = lastHashes.filter { liveIDs.contains($0.key) }

        let now = Date()
        for klip in store.klips where klip.status != .stale {
            // Shell-integration klips are updated by shell hook events — skip AI polling.
            if case .shell = klip.target.locator { continue }
            // Same for klips with a live Claude hook stream.
            if isExternallyManaged?(klip) == true { continue }
            let sched = scheduler(for: klip.id)
            guard sched.isDue(now: now), !inFlight.contains(klip.id) else { continue }
            classify(klip)
        }
    }

    private func classify(_ klip: Klip) {
        let id = klip.id
        let target = klip.target
        let apiKey = settings.apiKey()
        let allowScreenshots = settings.useScreenshots

        inFlight.insert(id)
        Task { @MainActor in
            defer { inFlight.remove(id) }

            guard NSRunningApplication(processIdentifier: target.pid) != nil else {
                store.updateStatus(id: id, to: .stale, reason: "app closed")
                return
            }

            let axWindow = WindowFinder.axWindow(pid: target.pid, windowID: target.windowID)
            let snapshot = await CaptureService.snapshot(
                pid: target.pid, windowID: target.windowID,
                axWindow: axWindow, wantsScreenshot: true,
                allowScreenshot: allowScreenshots
            )

            let contentChanged = lastHashes[id].map { $0 != snapshot.contentHash } ?? false
            lastHashes[id] = snapshot.contentHash
            schedulers[id]?.advance(contentChanged: contentChanged, now: Date())

            // Apps with internal tabs share one window across many tasks. If
            // this klip's in-app tab isn't the one showing right now, the
            // window contains some OTHER task — classifying it would write
            // that task's status onto this klip. Hold position instead.
            if case .generic = target.locator, let axWindow {
                // Exact signal: Electron SPAs put their route on the AX web
                // area, and it changes per internal tab (Claude Desktop,
                // Codex, …).
                if let klipURL = target.contentURL,
                   let currentURL = AX.webContentURL(of: axWindow),
                   !ContentURL.matches(currentURL, klipURL) {
                    store.noteReason(id: id, reason: "In a background tab — click to switch back")
                    return
                }
                // Fallback signal: apps that mark the selected tab/row in AX.
                if target.contentURL == nil, let anchor = target.contextAnchor {
                    let selected = RestoreAnchorCollector.selectedLabels(from: axWindow)
                    if !selected.isEmpty,
                       !selected.contains(where: { RestoreMatcher.labelsMatch($0, anchor) }) {
                        store.noteReason(id: id, reason: "In a background tab — click to switch back")
                        return
                    }
                }
            }

            guard let key = apiKey, !key.isEmpty else {
                store.updateStatus(id: id, to: .unknown, reason: "No API key")
                return
            }

            // Nothing readable at all — a Claude call would only echo "empty
            // window" back. Say what would actually fix it instead.
            if snapshot.axText.count < 30, snapshot.screenshotPNG == nil {
                let reason: String
                if !allowScreenshots {
                    reason = "Can't read this window — enable screenshots in Settings"
                } else if !CGPreflightScreenCaptureAccess() {
                    reason = "Can't read this window — grant Screen Recording"
                } else {
                    reason = "Window not readable yet — retrying"
                }
                store.updateStatus(id: id, to: .unknown, reason: reason)
                return
            }

            let input = ClassificationInput(
                appName: target.appName,
                windowTitle: target.windowTitle,
                axText: snapshot.axText,
                screenshotPNG: snapshot.screenshotPNG
            )
            do {
                let verdict = try await ClaudeClassifier(
                    apiKey: key, model: ClassifierProtocolBuilder.defaultModel
                ).classify(input)
                // An event source may have claimed this klip while the API
                // call was in flight — its truth beats our guess.
                guard let current = store.klip(id: id),
                      isExternallyManaged?(current) != true
                else { return }
                store.updateStatusAndLabel(
                    id: id, to: verdict.status, label: verdict.label, reason: verdict.reason
                )
            } catch {
                store.updateStatus(id: id, to: .unknown, reason: "AI error: \(error)")
            }
        }
    }
}
