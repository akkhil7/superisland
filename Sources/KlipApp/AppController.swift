import AppKit
import ApplicationServices
import Combine
import KlipCore
import SwiftUI

/// Central coordinator: owns store/settings/monitor/permissions, handles
/// drop-a-klip, refocus, dismiss, and auto-dismiss of finished klips.
@MainActor
final class AppController: ObservableObject {
    let store: KlipStore
    let settings: Settings
    let permissions: PermissionsManager
    let monitor: KlipMonitor
    let shellServer = ShellServer()
    let shellIntegration = ShellIntegration()
    let chromeBridgeServer = ChromeBridgeServer()
    let chromeIntegration = ChromeIntegration()
    let claudeIntegration = ClaudeIntegration()
    let codexIntegration = CodexIntegration()
    let restoreGuidance = RestoreGuidanceManager()

    /// Klips that have received at least one Claude hook event this run —
    /// hooks are ground truth, so the AI monitor leaves these alone.
    private var hookManagedKlips = Set<UUID>()

    @Published var islandExpanded = false
    @Published var hotkeyDiagnostic: HotkeyRegistrationDiagnostic?

    private var lastForegroundApp: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var codexTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var autoDismissScheduled = Set<UUID>()

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
        startAutoDismissWatcher()
        // Event sources and the externally-managed guard MUST be wired before
        // the monitor's first tick, or its immediate classification pass races
        // ahead of (and can overwrite) event-driven truth.
        startShellServer()
        monitor.start()
        chromeBridgeServer.start()
        // Keep the native host manifest pointing at the current bundle path —
        // the pinned extension ID never changes, but the app might move.
        if chromeIntegration.isNativeHostInstalled {
            try? chromeIntegration.installNativeHost()
        }
    }

    // MARK: - Shell server

    private func startShellServer() {
        shellServer.onEvent = { [weak self] event in
            self?.handleShellEvent(event)
        }
        shellServer.onClaudeEvent = { [weak self] event in
            self?.handleClaudeHookEvent(event)
        }
        shellServer.onCodexEvent = { [weak self] event in
            self?.handleCodexHookEvent(event)
        }
        shellServer.start()
        monitor.isExternallyManaged = { [weak self] klip in
            guard let self else { return false }
            if self.hookManagedKlips.contains(klip.id) { return true }
            // Codex klips are rollout-driven; AI polling would read whatever
            // thread happens to be visible onto them.
            return klip.target.contentURL?.hasPrefix(CodexIntegration.sessionURLPrefix) == true
        }
        startCodexWatcher()
    }

    // MARK: - Codex (rollout watching; /codex endpoint serves CLI hooks only)

    private func handleCodexHookEvent(_ event: ClaudeHookEvent) {
        guard let update = CodexHookMapper.update(for: event) else { return }
        if let klip = store.klips.first(where: {
            $0.target.contentURL == CodexIntegration.sessionURLPrefix + event.sessionID
        }) {
            hookManagedKlips.insert(klip.id)
            applyCodexUpdate(update, to: klip, sessionID: event.sessionID)
            return
        }
        // Terminal klips: the hook reports the CLI's controlling TTY. Bind the
        // session id too, so the rollout watcher can keep driving status.
        if let klip = terminalKlip(tty: event.tty) {
            hookManagedKlips.insert(klip.id)
            store.setContentURL(
                id: klip.id, url: CodexIntegration.sessionURLPrefix + event.sessionID
            )
            apply(
                update, to: klip,
                label: AgentSessionLabel.label(agent: "Codex", prompt: event.prompt)
                    ?? codexIntegration.threadTitle(forID: event.sessionID)
            )
        }
    }

    /// The Codex desktop app doesn't run hooks — its rollout journal is the
    /// event source. Poll the files of klipped sessions every few seconds
    /// (mtime-gated, so unchanged files cost one stat each).
    private func startCodexWatcher() {
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCodexKlips() }
        }
        RunLoop.main.add(t, forMode: .common)
        codexTimer = t
        pollCodexKlips()   // rollout truth lands before anything else runs
    }

    private func pollCodexKlips() {
        // One mtime-gated read per session per tick, applied to EVERY klip on
        // that session (duplicates would otherwise race for the single update).
        var updates: [String: ClaudeHookMapper.Update] = [:]
        for klip in store.klips {
            guard let url = klip.target.contentURL,
                  url.hasPrefix(CodexIntegration.sessionURLPrefix)
            else { continue }
            let sessionID = String(url.dropFirst(CodexIntegration.sessionURLPrefix.count))
            if updates[sessionID] == nil,
               let fresh = codexIntegration.statusUpdate(forSessionID: sessionID) {
                updates[sessionID] = fresh
            }
            if let update = updates[sessionID] {
                applyCodexUpdate(update, to: klip, sessionID: sessionID)
            }
        }
    }

    private func applyCodexUpdate(
        _ update: ClaudeHookMapper.Update, to klip: Klip, sessionID: String
    ) {
        let title = codexIntegration.threadTitle(forID: sessionID)
        if let status = update.status {
            store.updateStatusAndLabel(id: klip.id, to: status, label: title, reason: update.reason)
        } else {
            store.noteReason(id: klip.id, reason: update.reason)
        }
    }

    // MARK: - Claude Code hooks

    private func handleClaudeHookEvent(_ event: ClaudeHookEvent) {
        guard let update = ClaudeHookMapper.update(for: event) else { return }

        // Desktop klips (Cowork / Claude Code tabs): match by local session id.
        if let session = claudeIntegration.localSession(forCLISessionID: event.sessionID),
           let klip = store.klips.first(where: {
               $0.target.bundleID == ClaudeDeepLink.bundleID
                   && ($0.target.contentURL?.contains(session.sessionID) ?? false)
           }) {
            hookManagedKlips.insert(klip.id)
            apply(update, to: klip, label: session.title)
            return
        }

        // Terminal klips: a CLI session's hooks report its controlling TTY —
        // route the event to the klip watching that terminal and label it
        // with the prompt the user submitted.
        if let klip = terminalKlip(tty: event.tty) {
            hookManagedKlips.insert(klip.id)
            apply(
                update, to: klip,
                label: AgentSessionLabel.label(agent: "Claude Code", prompt: event.prompt)
            )
        }
    }

    private func apply(_ update: ClaudeHookMapper.Update, to klip: Klip, label: String?) {
        if let status = update.status {
            store.updateStatusAndLabel(id: klip.id, to: status, label: label, reason: update.reason)
        } else {
            store.noteReason(id: klip.id, reason: update.reason)
        }
    }

    /// The klip bound to a terminal by TTY — shell-integration klips and
    /// Terminal.app klips that captured their tty.
    private func terminalKlip(tty: String?) -> Klip? {
        guard let tty else { return nil }
        return store.klips.first {
            switch $0.target.locator {
            case .shell(let t): return t == tty
            case .terminal(_, _, let t): return t == tty
            default: return false
            }
        }
    }

    private func handleShellEvent(_ event: ShellEvent) {
        switch event.event {
        case "register":
            shellIntegration.sessionRegistered()

        case "start":
            guard let klip = shellKlip(tty: event.tty) else { return }
            let cmd = event.cmd ?? ""
            if let agent = AgentCommand.agentName(forCommand: cmd) {
                // An AI agent is starting in this terminal: its hooks (Claude)
                // or rollout journal (Codex) own the klip from here.
                store.updateStatusAndLabel(
                    id: klip.id, to: .working, label: agent, reason: "\(agent) session"
                )
                if agent == "Codex" { bindCodexCLISession(to: klip.id, startedAt: Date()) }
            } else {
                // A plain command supersedes any previous agent session.
                hookManagedKlips.remove(klip.id)
                if klip.target.contentURL?.hasPrefix(CodexIntegration.sessionURLPrefix) == true {
                    store.setContentURL(id: klip.id, url: nil)
                }
                let label = event.cmd.map { CommandLabel.label(forCommand: $0) }
                store.updateStatusAndLabel(
                    id: klip.id, to: .working, label: label, reason: "running…"
                )
            }

        case "done":
            guard let klip = shellKlip(tty: event.tty) else { return }
            let isAgent = event.cmd.flatMap { AgentCommand.agentName(forCommand: $0) } != nil
            let isSuccess = (event.exitCode ?? 1) == 0
            let status: KlipStatus = isSuccess ? .done : .needsAttention
            let reason: String
            if isAgent {
                // The agent exited; keep its session label, free the klip for
                // whatever runs next.
                hookManagedKlips.remove(klip.id)
                reason = isSuccess ? "session ended" : "exited with code \(event.exitCode ?? -1)"
                store.updateStatus(id: klip.id, to: status, reason: reason)
                return
            }
            let label = event.cmd.map { CommandLabel.label(forCommand: $0) }
            if isSuccess, let dur = event.duration {
                reason = "finished in \(dur)s"
            } else if isSuccess {
                reason = "finished"
            } else {
                reason = "exited with code \(event.exitCode ?? -1)"
            }
            store.updateStatusAndLabel(id: klip.id, to: status, label: label, reason: reason)

        default: break
        }
    }

    /// A `codex` CLI launch journals its rollout within a few seconds. Bind
    /// the terminal klip to that session so the rollout watcher drives status
    /// (the desktop and CLI share the journal format).
    private func bindCodexCLISession(to klipID: UUID, startedAt: Date, attempt: Int = 0) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, let current = self.store.klip(id: klipID) else { return }
            // Another command may have taken the terminal over meanwhile —
            // its `start` event clears the binding and renames the klip.
            guard current.label.hasPrefix("Codex")
                || current.target.contentURL?
                    .hasPrefix(CodexIntegration.sessionURLPrefix) == true
            else { return }
            if let id = self.codexIntegration.newestSessionID(modifiedAfter: startedAt) {
                self.store.setContentURL(
                    id: klipID, url: CodexIntegration.sessionURLPrefix + id
                )
            } else if attempt < 5 {
                self.bindCodexCLISession(to: klipID, startedAt: startedAt, attempt: attempt + 1)
            }
        }
    }

    private func shellKlip(tty: String) -> Klip? {
        store.klips.first {
            if case .shell(let t) = $0.target.locator { return t == tty }
            return false
        }
    }

    // MARK: - Auto-dismiss

    private func startAutoDismissWatcher() {
        store.$klips
            .receive(on: DispatchQueue.main)
            .sink { [weak self] klips in
                guard let self else { return }
                guard self.settings.autoDismissMinutes > 0 else { return }
                for klip in klips where klip.status == .done {
                    guard !self.autoDismissScheduled.contains(klip.id) else { continue }
                    self.autoDismissScheduled.insert(klip.id)
                    let id = klip.id
                    let delay = TimeInterval(self.settings.autoDismissMinutes) * 60
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(delay))
                        guard let self else { return }
                        self.autoDismissScheduled.remove(id)
                        guard self.settings.autoDismissMinutes > 0 else { return }
                        guard self.store.klip(id: id)?.status == .done else { return }
                        self.store.remove(id: id)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Permission polling

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.permissions.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    // MARK: - Foreground app tracking

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
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastForegroundApp = app
        }
    }

    private func targetApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier { return front }
        return lastForegroundApp
    }

    // MARK: - Actions

    @discardableResult
    func dropKlip() -> Bool {
        guard AXIsProcessTrusted() else { permissions.requestAccessibility(); return false }
        guard let app = targetApp(), let front = WindowFinder.frontWindow(for: app) else {
            NSSound.beep(); return false
        }
        // Electron apps build their AX tree lazily; opt in now so it's ready
        // by the time the monitor takes its first snapshot.
        AX.enableManualAccessibility(pid: front.pid)
        let adapter = AdapterRegistry.adapter(for: front.bundleID)
        let locator = adapter.captureLocator(front: front)

        // For apps with internal tabs (Claude Desktop, Codex, …) many tasks
        // share one window. Remember which in-app tab/section is selected right
        // now — it becomes this klip's identity within the window. Two signals:
        // the web content URL (Electron SPAs route per tab — exact) and the
        // selected element's label (apps that mark selection in AX).
        var contextAnchor: String?
        var contentURL: String?
        var threadLabel: String?
        if case .generic = locator {
            contextAnchor = capturedContextAnchor(for: front)
            contentURL = AX.webContentURL(of: front.axWindow)
        }
        // Codex desktop exposes nothing via accessibility — bind the klip to
        // the session whose rollout journal was written most recently (i.e.
        // the thread the user just prompted).
        if front.bundleID == CodexIntegration.bundleID,
           let session = codexIntegration.currentSessionGuess() {
            contentURL = CodexIntegration.sessionURLPrefix + session.id
            threadLabel = session.title
        }

        let target = WindowTarget(
            bundleID: front.bundleID, appName: front.appName, pid: front.pid,
            windowID: front.windowID, windowTitle: front.title, locator: locator,
            contextAnchor: contextAnchor, contentURL: contentURL
        )
        // Editor klips: "file · workspace" beats the raw window title.
        if case let .editor(_, fileName, workspaceName) = locator {
            threadLabel = [fileName, workspaceName].compactMap { $0 }
                .joined(separator: " · ")
            if threadLabel?.isEmpty == true { threadLabel = nil }
        }
        let fallbackLabel = front.title.isEmpty ? front.appName : front.title
        let label = threadLabel
            ?? contextAnchor.map { String($0.prefix(60)) }
            ?? fallbackLabel
        let restoreMemoryID: UUID? = (
            settings.rememberVisualState
                && IntegrationRouter.allowsVisualRestore(
                    locator: locator,
                    bundleID: front.bundleID
                )
        ) ? UUID() : nil
        let klip = Klip(label: label, target: target, restoreMemoryID: restoreMemoryID)
        store.add(klip)
        if let restoreMemoryID {
            Task { @MainActor [restoreGuidance] in
                await restoreGuidance.captureMemory(id: restoreMemoryID, target: target)
            }
        }
        suggestAILabelIfTerminal(for: klip)
        return true
    }

    /// Terminal klips skip AI status polling (shell events own them), so they
    /// never get the monitor's AI label either — their initial label is a raw
    /// window title like "akhil — -zsh — 80×24". One cheap drop-time Claude
    /// call names what's actually running. Skipped silently without an API
    /// key; an agent/shell event arriving first wins.
    private func suggestAILabelIfTerminal(for klip: Klip) {
        switch klip.target.locator {
        case .shell, .terminal, .iterm: break
        default: return
        }
        guard let key = settings.apiKey(), !key.isEmpty else { return }
        let initialLabel = klip.label
        let target = klip.target
        Task { @MainActor [weak self] in
            let snapshot = await CaptureService.snapshot(
                pid: target.pid, windowID: target.windowID,
                axWindow: WindowFinder.axWindow(pid: target.pid, windowID: target.windowID),
                wantsScreenshot: false, allowScreenshot: false
            )
            guard snapshot.axText.count >= 30 else { return }
            let input = ClassificationInput(
                appName: target.appName,
                windowTitle: target.windowTitle,
                axText: snapshot.axText
            )
            guard let self,
                  let verdict = try? await ClaudeClassifier(
                      apiKey: key, model: ClassifierProtocolBuilder.defaultModel
                  ).classify(input),
                  let aiLabel = verdict.label, !aiLabel.isEmpty
            else { return }
            // Only fill in the placeholder — don't overwrite a label a shell
            // or agent event set while the API call was in flight.
            guard let current = self.store.klip(id: klip.id),
                  current.label == initialLabel
            else { return }
            self.store.updateLabel(id: klip.id, label: aiLabel)
        }
    }

    /// Read the selected in-app tab label, retrying once: Electron builds its
    /// AX tree asynchronously after `AXManualAccessibility` is enabled, so the
    /// first walk on a freshly-opted-in app can come back empty.
    private func capturedContextAnchor(for front: FrontWindow) -> String? {
        if let anchor = RestoreAnchorCollector.selectedContextAnchor(from: front.axWindow) {
            return anchor
        }
        usleep(150_000)
        return RestoreAnchorCollector.selectedContextAnchor(from: front.axWindow)
    }

    func refocus(_ klip: Klip) {
        Refocuser.refocus(klip)
        guard settings.rememberVisualState else { return }
        Task { @MainActor [restoreGuidance] in
            await restoreGuidance.suggestRestore(for: klip)
        }
    }

    func dismiss(_ klip: Klip) { store.remove(id: klip.id) }

    // MARK: - Onboarding

    /// Set by the AppDelegate so menu/Settings can reopen the tour.
    var showOnboardingRequested: (() -> Void)?

    func showOnboarding() { showOnboardingRequested?() }

    /// Brief island expansion after onboarding finishes — a visual "it lives
    /// here" pointer at the notch.
    func welcomePulse() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            islandExpanded = true
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                self.islandExpanded = false
            }
        }
    }
}
