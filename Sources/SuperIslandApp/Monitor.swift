import AppKit
import SuperIslandCore

/// Background pipeline: polls every 5 s to see which drops are due (per-drop
/// exponential backoff starting at 20 s), then takes a full snapshot and calls
/// Claude to classify + label the window.
@MainActor
final class SuperIslandMonitor: ObservableObject {
    private let store: DropStore
    private let settings: Settings
    private var timer: Timer?
    private var schedulers: [UUID: BackoffScheduler] = [:]
    private var lastHashes: [UUID: Int] = [:]
    private var unreadableCounts: [UUID: Int] = [:]
    private var inFlight: Set<UUID> = []

    /// How many consecutive "couldn't read the window yet" results we retry at
    /// the base tick cadence before falling back to exponential backoff. Lets a
    /// freshly-dropped Electron window (Claude Desktop, …) whose AX tree is still
    /// populating reach a real verdict in a few seconds instead of 30–80s.
    private let unreadableFastRetries = 3

    /// Drops driven by an event source (Claude Code hooks) — ground truth that
    /// makes AI polling unnecessary and potentially conflicting.
    var isExternallyManaged: ((Drop) -> Bool)?

    private let auth: AuthService

    init(store: DropStore, settings: Settings, auth: AuthService) {
        self.store = store
        self.settings = settings
        self.auth = auth
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
        let liveIDs = Set(store.drops.map(\.id))
        schedulers = schedulers.filter { liveIDs.contains($0.key) }
        lastHashes = lastHashes.filter { liveIDs.contains($0.key) }
        unreadableCounts = unreadableCounts.filter { liveIDs.contains($0.key) }

        let now = Date()
        for drop in store.drops where drop.status != .stale {
            // Terminal drops are owned by shell hook / agent events, never AI.
            // Classifying one with no API key is what produced the bogus
            // "No API key" status; without shell integration they simply have
            // no live status (still fine as click-to-return bookmarks).
            switch drop.target.locator {
            case .shell, .terminal, .iterm: continue
            default: break
            }
            // Same for drops with a live Claude hook stream.
            if isExternallyManaged?(drop) == true { continue }
            let sched = scheduler(for: drop.id)
            guard sched.isDue(now: now), !inFlight.contains(drop.id) else { continue }
            classify(drop)
        }
    }

    private func classify(_ drop: Drop) {
        let id = drop.id
        let target = drop.target
        let allowScreenshots = settings.useScreenshots

        inFlight.insert(id)
        Task { @MainActor in
            defer { inFlight.remove(id) }

            guard let token = await auth.validAccessToken() else {
                return  // signed out → no classification (the `defer` clears inFlight)
            }

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
            // Advance the backoff schedule only once we've actually *read* the
            // window. A window we couldn't read yet (Electron's AX tree still
            // populating, no screenshot permission) must NOT earn an exponential
            // backoff step — doing that before the readability gate is what
            // pushed the first real verdict out to 30–80s. These retries are
            // local (no API call), so re-checking at the base 5s tick is cheap.
            @MainActor func scheduleNextCheck() {
                schedulers[id]?.advance(contentChanged: contentChanged, now: Date())
            }

            // Apps with internal tabs share one window across many tasks. If
            // this drop's in-app tab isn't the one showing right now, the
            // window contains some OTHER task — classifying it would write
            // that task's status onto this drop. Hold position instead.
            if case .generic = target.locator, let axWindow {
                // Exact signal: Electron SPAs put their route on the AX web
                // area, and it changes per internal tab (Claude Desktop,
                // Codex, …).
                if let dropURL = target.contentURL,
                    let currentURL = AX.webContentURL(of: axWindow),
                    !ContentURL.matches(currentURL, dropURL)
                {
                    store.noteReason(id: id, reason: "In a background tab — click to switch back")
                    scheduleNextCheck()
                    return
                }
                // Fallback signal: apps that mark the selected tab/row in AX.
                if target.contentURL == nil, let anchor = target.contextAnchor {
                    let selected = RestoreAnchorCollector.selectedLabels(from: axWindow)
                    if !selected.isEmpty,
                        !selected.contains(where: { RestoreMatcher.labelsMatch($0, anchor) })
                    {
                        store.noteReason(
                            id: id, reason: "In a background tab — click to switch back")
                        scheduleNextCheck()
                        return
                    }
                }
            }

            // Nothing readable at all — a Claude call would only echo "empty
            // window" back. Say what would actually fix it instead. Retry at the
            // base cadence while the window populates (see unreadableFastRetries)
            // before letting backoff stretch the interval.
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
                let attempts = (unreadableCounts[id] ?? 0) + 1
                unreadableCounts[id] = attempts
                if attempts > unreadableFastRetries { scheduleNextCheck() }
                return
            }
            // We got a real read — clear the fast-retry counter.
            unreadableCounts[id] = nil

            let input = ClassificationInput(
                appName: target.appName,
                windowTitle: target.windowTitle,
                axText: snapshot.axText,
                screenshotPNG: snapshot.screenshotPNG
            )
            do {
                let verdict = try await ClaudeClassifier(
                    auth: .proxy(url: BackendConfig.classifyURL, bearer: token),
                    model: ClassifierProtocolBuilder.defaultModel
                ).classify(input)
                // An event source may have claimed this drop while the API
                // call was in flight — its truth beats our guess.
                guard let current = store.drop(id: id),
                    isExternallyManaged?(current) != true
                else { return }
                store.updateStatusAndLabel(
                    id: id, to: verdict.status, label: verdict.label, reason: verdict.reason
                )
            } catch let ClassifierError.quotaExceeded(used, cap) {
                store.updateStatus(id: id, to: .unknown, reason: "Daily limit reached (\(used)/\(cap))")
            } catch {
                store.updateStatus(id: id, to: .unknown, reason: "AI error: \(error)")
            }
            scheduleNextCheck()
        }
    }
}
