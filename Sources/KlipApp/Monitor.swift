import AppKit
import KlipCore

/// Background pipeline: on a timer, cheaply probes each klipped window, and when
/// the change detector signals a busy→quiet transition (or the fallback fires),
/// runs the on-device prefilter and, if warranted, the Claude classifier — then
/// writes the resulting status back to the store.
@MainActor
final class KlipMonitor: ObservableObject {
    private let store: KlipStore
    private let settings: Settings
    private var timer: Timer?
    private var detectors: [UUID: ChangeDetector] = [:]
    private var inFlight: Set<UUID> = []
    private let prefilter = Prefilter()

    init(store: KlipStore, settings: Settings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        stop()
        let interval = max(2, settings.pollInterval)
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
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

    /// Discard cached detectors so new interval settings take effect.
    func resetDetectors() { detectors.removeAll() }

    private func tick() {
        let liveIDs = Set(store.klips.map(\.id))
        detectors = detectors.filter { liveIDs.contains($0.key) }

        for klip in store.klips where klip.status != .stale {
            evaluate(klip)
        }
    }

    private func detector(for id: UUID) -> ChangeDetector {
        if let d = detectors[id] { return d }
        let d = ChangeDetector(
            settleInterval: settings.settleInterval,
            fallbackInterval: settings.fallbackInterval
        )
        detectors[id] = d
        return d
    }

    private func evaluate(_ klip: Klip) {
        guard !inFlight.contains(klip.id) else { return }
        let id = klip.id
        let target = klip.target
        let detector = detector(for: id)
        let model = settings.model
        let apiKey = settings.apiKey()
        let allowScreenshots = settings.useScreenshots

        inFlight.insert(id)
        Task { @MainActor in
            defer { inFlight.remove(id) }

            // Window/app gone?
            guard NSRunningApplication(processIdentifier: target.pid) != nil else {
                store.updateStatus(id: id, to: .stale, reason: "app closed")
                return
            }
            let axWindow = WindowFinder.axWindow(pid: target.pid, windowID: target.windowID)

            // Cheap text-first probe to drive change detection.
            let probe = await CaptureService.snapshot(
                pid: target.pid, windowID: target.windowID,
                axWindow: axWindow, wantsScreenshot: false,
                allowScreenshot: allowScreenshots
            )
            guard detector.observe(hash: probe.contentHash, now: Date()) else { return }

            // Evaluate the settled state.
            let pre = prefilter.assess(text: probe.axText)

            // If nothing on-device looks noteworthy, treat it as still-working
            // and don't spend a Claude call.
            guard pre.isInteresting else {
                store.updateStatus(id: id, to: .working, reason: "active")
                return
            }

            // Worth a confident verdict: grab a screenshot for vision context.
            let full = await CaptureService.snapshot(
                pid: target.pid, windowID: target.windowID,
                axWindow: axWindow, wantsScreenshot: true,
                allowScreenshot: allowScreenshots
            )
            let input = ClassificationInput(
                appName: target.appName,
                windowTitle: target.windowTitle,
                axText: full.axText,
                screenshotPNG: full.screenshotPNG
            )

            // No key or a failure: fall back to the on-device heuristic.
            guard apiKey?.isEmpty == false else {
                store.updateStatus(id: id, to: pre.hint, reason: "on-device: \(pre.hint.rawValue)")
                return
            }
            do {
                let verdict = try await ClaudeClassifier(apiKey: apiKey, model: model).classify(input)
                store.updateStatus(id: id, to: verdict.status, reason: verdict.reason)
            } catch {
                store.updateStatus(id: id, to: pre.hint, reason: "AI unavailable; on-device guess")
            }
        }
    }
}
