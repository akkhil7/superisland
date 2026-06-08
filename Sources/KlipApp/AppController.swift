import AppKit
import ApplicationServices
import Combine
import KlipCore

/// Central coordinator: owns the store/settings/monitor/permissions, performs
/// the drop-a-klip and refocus actions, and tracks the previously-frontmost app
/// so dropping from the island/menu button klips the right window (not Klip).
@MainActor
final class AppController: ObservableObject {
    let store: KlipStore
    let settings: Settings
    let permissions: PermissionsManager
    let monitor: KlipMonitor

    /// The last non-Klip app the user was in front of.
    private var lastForegroundApp: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?

    init() {
        let url = (try? KlipStore.defaultFileURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("klips.json")
        store = KlipStore(fileURL: url)
        settings = Settings()
        permissions = PermissionsManager()
        monitor = KlipMonitor(store: store, settings: settings)
    }

    func start() {
        permissions.refresh()
        trackForegroundApp()
        startPermissionPolling()
        monitor.start()
    }

    /// Permission grants happen in System Settings, out of band — poll so the
    /// UI (and the "permissions needed" banner) reflects a grant within seconds
    /// without needing an app restart.
    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.permissions.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    private func trackForegroundApp() {
        let center = NSWorkspace.shared.notificationCenter
        let obs = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.lastForegroundApp = app }
        }
        observers.append(obs)
        // Seed with whatever is frontmost right now.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastForegroundApp = app
        }
    }

    /// The app whose window a new klip should target: the current frontmost
    /// unless that's Klip itself, in which case the last app the user was in.
    private func targetApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front
        }
        return lastForegroundApp
    }

    // MARK: - Actions

    @discardableResult
    func dropKlip() -> Bool {
        // Check live trust state, not the cached/polled value, so we never
        // prompt when access is actually already granted.
        guard AXIsProcessTrusted() else {
            permissions.requestAccessibility()
            return false
        }
        guard let app = targetApp(), let front = WindowFinder.frontWindow(for: app) else {
            NSSound.beep()
            return false
        }
        let adapter = AdapterRegistry.adapter(for: front.bundleID)
        let locator = adapter.captureLocator(front: front)
        let target = WindowTarget(
            bundleID: front.bundleID, appName: front.appName, pid: front.pid,
            windowID: front.windowID, windowTitle: front.title, locator: locator
        )
        let label = front.title.isEmpty ? front.appName : front.title
        store.add(Klip(label: label, target: target))
        return true
    }

    func refocus(_ klip: Klip) {
        Refocuser.refocus(klip)
    }

    func dismiss(_ klip: Klip) {
        store.remove(id: klip.id)
    }
}
