import AppKit
import ApplicationServices
import Combine
import SuperIslandCore
import SwiftUI

/// Central coordinator: owns store/settings/monitor/permissions, handles
/// drop-a-drop, refocus, dismiss, and auto-dismiss of finished drops.
@MainActor
final class AppController: ObservableObject {
    let store: DropStore
    let settings: Settings
    let permissions: PermissionsManager
    let monitor: SuperIslandMonitor
    let shellServer = ShellServer()
    let shellIntegration = ShellIntegration()
    let chromeBridgeServer = ChromeBridgeServer()
    let chromeIntegration = ChromeIntegration()
    let claudeIntegration = ClaudeIntegration()
    let codexIntegration = CodexIntegration()
    let cursorIntegration = CursorIntegration()
    let auth = AuthService()

    /// Set by the AppDelegate to show/hide the notch island as the user signs
    /// in/out — when signed out the app is locked and nothing should run.
    var onActiveChange: ((Bool) -> Void)?

    /// Drops that have received at least one Claude hook event this run —
    /// hooks are ground truth, so the AI monitor leaves these alone.
    private var hookManagedDrops = Set<UUID>()
    /// Chrome drops we've classified at rest at least once (so a bare tab focus
    /// never re-classifies) and drops with a working turn in flight (so the next
    /// settle re-classifies). Together: classify once per turn, never on focus.
    private var chromeSeen = Set<UUID>()
    private var chromeTurnPending = Set<UUID>()

    /// Per-drop counter bumped on every Claude hook event, used to detect a
    /// `PreToolUse` that no later event supersedes (a tool blocked on your
    /// approval — Claude Desktop fires no Notification for in-app prompts).
    private var claudeToolGeneration: [UUID: Int] = [:]

    /// Last `afterAgentResponse` text per Cursor conversation id, classified at
    /// `stop` to tell "done" from "waiting on you" (the stop payload has no text).
    private var cursorLastResponse: [String: String] = [:]

    @Published var islandExpanded = false
    @Published var hotkeyDiagnostic: HotkeyRegistrationDiagnostic?
    /// Transient message shown as a toast bar under the notch island (e.g.
    /// "SuperIsland doesn't support Finder"). nil when no toast is visible.
    @Published var toast: ToastBanner?

    /// A short-lived island toast. Carries its own id so re-showing the same
    /// message still re-triggers the appear animation.
    struct ToastBanner: Equatable {
        let id = UUID()
        var message: String
    }

    private var toastDismissWork: DispatchWorkItem?

    /// Explicit status-change banners shown at the `notify` alert level. These
    /// persist (no auto-dismiss) and are laid out as a horizontal row across
    /// the top of the screen — one per drop, keyed by the drop's id.
    @Published var alertBanners: [AlertBanner] = []

    struct AlertBanner: Identifiable, Equatable {
        /// Equals the drop's id — one banner per drop.
        let id: UUID
        var status: DropStatus
        var label: String
        var source: DropSource
    }

    /// Last status we observed per drop, so the watcher fires a banner only on
    /// a real transition (not on every store mutation, nor on first sighting).
    private var lastAlertedStatus: [UUID: DropStatus] = [:]

    private var lastForegroundApp: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var codexTimer: Timer?
    private var claudeTimer: Timer?
    /// Per-drop transcript modification date last classified, so the Claude
    /// Desktop watcher only re-reads a transcript that actually changed.
    private var claudeTranscriptMtime: [UUID: Date] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var autoDismissScheduled = Set<UUID>()

    init() {
        let url =
            (try? DropStore.defaultFileURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("drops.json")
        store = DropStore(fileURL: url)
        settings = Settings()
        permissions = PermissionsManager()
        monitor = SuperIslandMonitor(store: store, settings: settings, auth: auth)
    }

    func start() {
        permissions.refresh()
        trackForegroundApp()
        startPermissionPolling()
        startAutoDismissWatcher()
        startAlertWatcher()
        // Event sources and the externally-managed guard MUST be wired before
        // the monitor's first tick, or its immediate classification pass races
        // ahead of (and can overwrite) event-driven truth.
        startShellServer()
        // Pick up newly-managed hook events (e.g. PreToolUse/PostToolUse) for
        // users who enabled the Claude integration on an earlier version.
        claudeIntegration.reconcile()
        cursorIntegration.reconcile()
        backfillClaudeLabels()
        // Monitoring (and the island) only run while signed in. This subscription
        // fires immediately with the current auth state and on every change.
        observeAuthForActivity()
        chromeBridgeServer.start()
        // Keep the native host manifest pointing at the current bundle path —
        // the pinned extension ID never changes, but the app might move.
        if chromeIntegration.isNativeHostInstalled {
            try? chromeIntegration.installNativeHost()
        }
    }

    /// Gate all activity on sign-in: run the monitor and show the island only
    /// while signed in; pause and hide them when signed out. Event handlers and
    /// refocus are guarded separately, so a signed-out app is fully inert.
    private func observeAuthForActivity() {
        auth.$session
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] signedIn in
                guard let self else { return }
                dlog(.app, signedIn ? "active — monitoring on" : "locked — signed out")
                if signedIn { self.monitor.start() } else { self.monitor.stop() }
                self.onActiveChange?(signedIn)
            }
            .store(in: &cancellables)
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
        shellServer.onCursorEvent = { [weak self] event in
            self?.handleCursorHookEvent(event)
        }
        shellServer.start()
        chromeBridgeServer.onTabState = { [weak self] event in
            self?.handleChromeTabEvent(event)
        }
        monitor.isExternallyManaged = { [weak self] drop in
            guard let self else { return false }
            if self.hookManagedDrops.contains(drop.id) { return true }
            // The AI window classifier is BLIND to Chrome — its AX tree exposes
            // only the tab strip / window chrome, never the page — so it must
            // NEVER classify a chrome drop, not even when the bridge briefly goes
            // stale on an idle settled tab (otherwise it overwrites a correct
            // needsAttention with a blind "done"). Chrome status is owned entirely
            // by the bridge + turn-end classifier (see handleChromeTabEvent).
            if case .chrome = drop.target.locator {
                return true
            }
            // Claude Desktop conversations: the AI window-reader is BLIND to any
            // conversation that isn't the one on screen (the AX tree exposes only
            // the visible web area), so a background session waiting on the user
            // gets frozen at a stale status. Status is owned by the Claude hooks
            // and the transcript watcher (pollClaudeDesktopDrops) — both of which
            // see every session regardless of which is foreground.
            if drop.target.bundleID == ClaudeDeepLink.bundleID {
                return true
            }
            // Codex drops are rollout-driven; AI polling would read whatever
            // thread happens to be visible onto them.
            if drop.target.contentURL?.hasPrefix(CursorIntegration.sessionURLPrefix) == true {
                return true
            }
            return self.settings.codexIntegrationEnabled
                && drop.target.contentURL?.hasPrefix(CodexIntegration.sessionURLPrefix) == true
        }
        startCodexWatcher()
        startClaudeWatcher()
    }

    // MARK: - Chrome bridge (extension is ground truth for web-AI drops)

    /// A `tab_state` event carries the extension's network-derived status for one
    /// Chrome tab. Route it to the matching `.chrome` drop; the AI monitor leaves
    /// that drop alone while the bridge is live (see `isExternallyManaged`). The
    /// host allowlist is already enforced by `ChromeBridgeServer` before this runs.
    private func handleChromeTabEvent(_ event: ChromeBridgeExtensionEvent) {
        guard auth.isSignedIn else { return }  // signed out → app is locked
        guard let tab = event.tab,
            let status = tab.status ?? event.domSummary?.taskState
        else { return }
        guard let drop = chromeDrop(matching: tab) else {
            dlog(.proxy, "chrome tab_state \(status.rawValue) — no drop for \(tab.url ?? "?")")
            return
        }

        // The bridge owns the LIVE `working` signal. The resting verdict (done vs
        // needsAttention) is owned by the turn-end classifier — so we never write
        // the bridge's settled status onto the drop, or a bare tab-focus event
        // (which re-emits `unknown`) would clobber a needsAttention back to "done".
        if status == .working {
            store.updateStatus(id: drop.id, to: .working, reason: Self.chromeReason(.working))
            chromeTurnPending.insert(drop.id)
            return
        }

        // Settled (done / unknown). Classify the conversation exactly ONCE per
        // turn: when a working turn just ended, or the first time we see this drop
        // settled (a tab dropped onto an already-finished conversation). A bare
        // re-focus of an already-classified drop does nothing. The extension's DOM
        // text is the only readable source — Chrome's AX tree can't see the page.
        guard let text = event.domSummary?.text, text.count >= 40 else { return }
        let shouldClassify = !chromeSeen.contains(drop.id) || chromeTurnPending.contains(drop.id)
        if shouldClassify {
            chromeSeen.insert(drop.id)
            chromeTurnPending.remove(drop.id)
            classifyChromeTurnEnd(dropID: drop.id, conversationTail: text)
        }
    }

    /// Classify a settled chrome turn's conversation tail with the focused
    /// turn-end prompt and set the drop's resting verdict (done / needsAttention).
    /// Never sets `working` (the bridge owns that) and never clobbers a turn that
    /// started while the call was in flight. Falls back to `done` so a failed call
    /// can't leave the drop hanging.
    private func classifyChromeTurnEnd(dropID: UUID, conversationTail: String) {
        Task { @MainActor [weak self] in
            guard let self, let token = await self.auth.validAccessToken() else { return }
            let verdict = try? await ClaudeClassifier(
                auth: .proxy(url: BackendConfig.classifyURL, bearer: token),
                model: ClassifierProtocolBuilder.defaultModel
            ).classifyTurnEndMessage(conversationTail)
            // If a NEW turn started while we were waiting (a fresh `working` event
            // re-armed the pending flag), it owns the drop now — don't overwrite.
            // The drop being `working` from the turn we're resolving is expected.
            guard !self.chromeTurnPending.contains(dropID) else { return }
            let status: DropStatus = (verdict?.status == .needsAttention) ? .needsAttention : .done
            let reason = verdict?.reason ?? "Response ready"
            dlog(.proxy, "chrome turn-end → \(status.rawValue)")
            self.store.updateStatus(id: dropID, to: status, reason: reason)
        }
    }

    private func chromeDrop(matching tab: ChromeTabState) -> Drop? {
        chromeDrop(tabID: tab.tabID, url: tab.url)
    }

    /// The `.chrome` drop for a tab. Primary key is the extension `tabID` — matched
    /// only against drops whose `windowID != nil`, which marks an extension-id-space
    /// tabID (see `Adapters`). Falls back to exact URL for drops captured while the
    /// bridge was down (their tabID is an AppleScript id that never equals an
    /// extension id). Used both to route bridge events and to dedup at drop time.
    private func chromeDrop(tabID: Int?, url: String?) -> Drop? {
        if let tabID,
            let hit = store.drops.first(where: { drop in
                guard case let .chrome(windowID, _, _, t, _, _, _, _) = drop.target.locator
                else { return false }
                return windowID != nil && t == tabID
            })
        {
            return hit
        }
        guard let url, !url.isEmpty else { return nil }
        return store.drops.first { drop in
            guard case let .chrome(_, _, _, _, dropURL, _, _, _) = drop.target.locator
            else { return false }
            return dropURL == url
        }
    }

    private static func chromeReason(_ status: DropStatus) -> String {
        switch status {
        case .working: return "Generating…"
        case .done: return "Response ready"
        case .needsAttention: return "Needs your input"
        case .stale: return "Tab closed"
        case .unknown: return "Idle"
        }
    }

    // MARK: - Codex (rollout watching; /codex endpoint serves CLI hooks only)

    private func handleCodexHookEvent(_ event: ClaudeHookEvent) {
        guard auth.isSignedIn else { return }  // signed out → app is locked
        guard let update = CodexHookMapper.update(for: event) else { return }
        if let drop = store.drops.first(where: {
            $0.target.contentURL == CodexIntegration.sessionURLPrefix + event.sessionID
        }) {
            hookManagedDrops.insert(drop.id)
            applyCodexUpdate(update, to: drop, sessionID: event.sessionID)
            return
        }
        // Terminal drops: the hook reports the CLI's controlling TTY. Bind the
        // session id too, so the rollout watcher can keep driving status. If
        // another drop already holds this session the bind is refused — leave
        // that drop as the session's sole owner rather than double-tracking.
        if let drop = terminalDrop(tty: event.tty),
            store.setContentURL(
                id: drop.id, url: CodexIntegration.sessionURLPrefix + event.sessionID
            )
        {
            hookManagedDrops.insert(drop.id)
            apply(
                update, to: drop,
                label: AgentSessionLabel.label(agent: "Codex", prompt: event.prompt)
                    ?? codexIntegration.threadTitle(forID: event.sessionID)
            )
        }
    }

    /// The Codex desktop app doesn't run hooks — its rollout journal is the
    /// event source. Poll the files of dropped sessions every few seconds
    /// (mtime-gated, so unchanged files cost one stat each).
    private func startCodexWatcher() {
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCodexDrops() }
        }
        RunLoop.main.add(t, forMode: .common)
        codexTimer = t
        pollCodexDrops()  // rollout truth lands before anything else runs
    }

    private func pollCodexDrops() {
        guard settings.codexIntegrationEnabled else { return }
        // One mtime-gated read per session per tick, applied to EVERY drop on
        // that session (duplicates would otherwise race for the single update).
        var updates: [String: ClaudeHookMapper.Update] = [:]
        for drop in store.drops {
            guard let url = drop.target.contentURL,
                url.hasPrefix(CodexIntegration.sessionURLPrefix)
            else { continue }
            let sessionID = String(url.dropFirst(CodexIntegration.sessionURLPrefix.count))
            if updates[sessionID] == nil,
                let fresh = codexIntegration.statusUpdate(forSessionID: sessionID)
            {
                updates[sessionID] = fresh
            }
            if let update = updates[sessionID] {
                applyCodexUpdate(update, to: drop, sessionID: sessionID)
            }
        }
    }

    private func applyCodexUpdate(
        _ update: ClaudeHookMapper.Update, to drop: Drop, sessionID: String
    ) {
        let title = codexIntegration.threadTitle(forID: sessionID)
        if let status = update.status {
            store.updateStatusAndLabel(id: drop.id, to: status, label: title, reason: update.reason)
        } else {
            store.noteReason(id: drop.id, reason: update.reason)
        }
    }

    // MARK: - Cursor agent hooks

    private func handleCursorHookEvent(_ event: CursorHookEvent) {
        guard auth.isSignedIn else { return }  // signed out → app is locked
        // Feed the conversation index regardless of whether a drop exists yet,
        // so a drop placed moments later can bind to this conversation.
        cursorIntegration.recordEvent(
            conversationID: event.conversationID, workspaceRoots: event.workspaceRoots,
            prompt: event.prompt, at: Date()
        )
        // Stash the assistant message for turn-end classification at `stop`.
        if event.event == "afterAgentResponse", let text = event.text, !text.isEmpty {
            cursorLastResponse[event.conversationID] = text
        }

        guard let update = CursorHookMapper.update(for: event) else { return }
        let label = AgentSessionLabel.label(agent: "Cursor", prompt: event.prompt)

        guard let drop = cursorDrop(for: event) else { return }
        hookManagedDrops.insert(drop.id)

        // `stop` ends the turn — refine completed into done vs needsAttention
        // from the stashed assistant message (the stop payload carries no text).
        if event.event == "stop", event.status != "error" {
            let stashed = cursorLastResponse[event.conversationID]
            cursorLastResponse[event.conversationID] = nil
            refineCursorTurnEnd(dropID: drop.id, label: label, message: stashed)
            return
        }
        apply(update, to: drop, label: label)
    }

    /// The drop a Cursor hook event belongs to: a GUI drop matched by the
    /// `cursor://session/<id>` content URL, a cursor-agent CLI drop matched by
    /// TTY, or an unbound Cursor drop adopted on its first event (cold start).
    private func cursorDrop(for event: CursorHookEvent) -> Drop? {
        let sessionURL = CursorIntegration.sessionURLPrefix + event.conversationID
        if let drop = store.drops.first(where: { $0.target.contentURL == sessionURL }) {
            return drop
        }
        if let drop = terminalDrop(tty: event.tty),
            store.setContentURL(id: drop.id, url: sessionURL)
        {
            return drop
        }
        // Cold start: a Cursor drop placed before any event this session has no
        // session URL yet. Adopt the most recent unbound Cursor drop and bind it.
        if let drop = store.drops.last(where: { d in
            d.target.bundleID == CursorIntegration.bundleID
                && (d.target.contentURL?.hasPrefix(CursorIntegration.sessionURLPrefix) != true)
        }), store.setContentURL(id: drop.id, url: sessionURL) {
            return drop
        }
        return nil
    }

    /// Resolve a Cursor `stop` into done vs needs-attention from the stashed
    /// assistant message (Haiku when a token is set, structural heuristic
    /// otherwise). Falls back to plain "done" when there's no message.
    private func refineCursorTurnEnd(dropID: UUID, label: String?, message: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let token = await self.auth.validAccessToken()
            let result: (status: DropStatus, reason: String)?
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = await self.cursorIntegration.classifyFinalMessage(message, bearer: token)
            } else {
                result = nil
            }
            guard self.store.drop(id: dropID) != nil else { return }
            self.store.updateStatusAndLabel(
                id: dropID,
                to: result?.status ?? .done,
                label: label,
                reason: result?.reason ?? "Cursor finished — ready for you"
            )
        }
    }

    // MARK: - Claude Desktop transcript watcher

    /// Claude Desktop conversations that aren't the one on screen are invisible
    /// to the AI window-reader, so we drive their status from the on-disk
    /// transcript instead — which is readable for every session regardless of
    /// which is foreground. Hook-managed (actively-running) sessions are left to
    /// the hooks; this covers the idle / background / not-yet-bound ones.
    private func startClaudeWatcher() {
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClaudeDesktopDrops() }
        }
        RunLoop.main.add(t, forMode: .common)
        claudeTimer = t
        pollClaudeDesktopDrops()
    }

    private func pollClaudeDesktopDrops() {
        guard auth.isSignedIn else { return }
        let live = Set(store.drops.map(\.id))
        claudeTranscriptMtime = claudeTranscriptMtime.filter { live.contains($0.key) }
        for drop in store.drops where drop.target.bundleID == ClaudeDeepLink.bundleID {
            // Active sessions are owned by the hooks; don't double-classify them.
            if hookManagedDrops.contains(drop.id) { continue }
            guard let url = drop.target.contentURL,
                let path = claudeIntegration.transcriptPath(forContentURL: url)
            else { continue }
            // mtime-gate: only re-read a transcript that actually changed (idle
            // sessions stay put, so this costs one classify when they settle).
            let mtime =
                (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
                as? Date
            guard let mtime, claudeTranscriptMtime[drop.id] != mtime else { continue }
            claudeTranscriptMtime[drop.id] = mtime
            classifyClaudeDesktopTranscript(dropID: drop.id, path: path)
        }
    }

    private func classifyClaudeDesktopTranscript(dropID: UUID, path: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let token = await self.auth.validAccessToken()
            guard
                let result = await self.claudeIntegration.classifyTurnEnd(
                    transcriptPath: path, bearer: token),
                self.store.drop(id: dropID) != nil,
                // A hook may have claimed the drop while the read was in flight.
                !self.hookManagedDrops.contains(dropID)
            else { return }
            self.store.updateStatus(id: dropID, to: result.status, reason: result.reason)
        }
    }

    // MARK: - Claude Code hooks

    private func handleClaudeHookEvent(_ event: ClaudeHookEvent) {
        guard auth.isSignedIn else { return }  // signed out → app is locked
        HookDebugLog.log(
            "EVENT \(event.event) notif=\(event.notificationType ?? "-") "
                + "permMode=\(event.permissionMode ?? "-") sid=\(event.sessionID.prefix(8)) "
                + "tty=\(event.tty ?? "-") msg=\(event.message?.prefix(120) ?? "-")"
        )
        guard let update = ClaudeHookMapper.update(for: event) else {
            HookDebugLog.log("  → unmapped, ignored")
            return
        }
        guard let (drop, label) = matchClaudeDrop(event) else {
            HookDebugLog.log(
                "  → NO DROP MATCHED (would-be status=\(update.status?.rawValue ?? "keep") "
                    + "reason=\(update.reason))"
            )
            return
        }
        HookDebugLog.log(
            "  → drop=\(drop.id.uuidString.prefix(8)) status=\(update.status?.rawValue ?? "keep") "
                + "reason=\(update.reason)"
        )
        hookManagedDrops.insert(drop.id)
        // Every event supersedes a pending "waiting for permission" timer.
        let generation = (claudeToolGeneration[drop.id] ?? 0) + 1
        claudeToolGeneration[drop.id] = generation

        // Stop ends the turn — but "ended" can mean finished OR handed back
        // asking you something. Read the transcript's last message to decide,
        // instead of blindly marking done.
        if event.event == "Stop" {
            refineClaudeTurnEnd(
                dropID: drop.id, label: label,
                message: event.lastAssistantMessage, transcriptPath: event.transcriptPath
            )
            return
        }
        apply(update, to: drop, label: label)

        // Claude Desktop fires no Notification hook for its in-app permission
        // prompts (confirmed: a blocked tool emits PreToolUse then silence, no
        // Notification), so a tool blocked on your approval looks identical to
        // one that's running. Treat a PreToolUse that nothing supersedes within
        // a few seconds as "needs you". Only bypassPermissions auto-runs every
        // tool; acceptEdits still prompts for Bash and friends, so it must arm.
        if event.event == "PreToolUse", ClaudePermissionMode.canPrompt(event.permissionMode) {
            HookDebugLog.log(
                "  → armed permission-stall (gen=\(generation)) for drop=\(drop.id.uuidString.prefix(8))"
            )
            armPermissionStall(
                dropID: drop.id, label: label, generation: generation,
                transcriptPath: event.transcriptPath
            )
        }
    }

    /// If no later event arrives for this drop within a few seconds, the tool
    /// *may* be blocked on the user. Before surfacing needs-attention, verify
    /// against the transcript that a tool is genuinely pending — otherwise the
    /// gap was just Claude thinking between tools, and flipping to
    /// needs-attention would be a false alarm that bounces straight back to
    /// working on the next event.
    private func armPermissionStall(
        dropID: UUID, label: String?, generation: Int, transcriptPath: String?
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self,
                self.claudeToolGeneration[dropID] == generation,
                self.hookManagedDrops.contains(dropID),
                self.store.drop(id: dropID)?.status == .working
            else {
                HookDebugLog.log(
                    "  → permission-stall (gen=\(generation)) superseded/skipped for drop=\(dropID.uuidString.prefix(8))"
                )
                return
            }
            // Ground-truth gate: a tool blocked on your approval shows up as a
            // pending tool_use (no tool_result yet) in the transcript. If the
            // tool already completed, this stall is a think-gap, not a prompt —
            // don't false-flag it. (No transcript path → can't verify → stay
            // silent rather than risk a false red.)
            guard let transcriptPath,
                self.claudeIntegration.isToolPending(transcriptPath: transcriptPath)
            else {
                HookDebugLog.log(
                    "  → permission-stall (gen=\(generation)) skipped — no pending tool (think-gap) for drop=\(dropID.uuidString.prefix(8))"
                )
                return
            }
            HookDebugLog.log(
                "  → permission-stall FIRED → needsAttention for drop=\(dropID.uuidString.prefix(8))"
            )
            self.store.updateStatus(
                id: dropID, to: .needsAttention, reason: "Claude needs your permission"
            )
            self.store.nameIfUnnamed(id: dropID, label: label)
        }
    }

    /// The drop a Claude hook event belongs to: a Claude Desktop drop matched by
    /// session id, or a terminal drop matched by the CLI's controlling TTY.
    private func matchClaudeDrop(_ event: ClaudeHookEvent) -> (drop: Drop, label: String?)? {
        if let session = claudeIntegration.localSession(forCLISessionID: event.sessionID),
            let drop = store.drops.first(where: {
                $0.target.bundleID == ClaudeDeepLink.bundleID
                    && ($0.target.contentURL?.contains(session.sessionID) ?? false)
            })
        {
            return (drop, session.title)
        }
        if let drop = terminalDrop(tty: event.tty) {
            return (drop, AgentSessionLabel.label(agent: "Claude Code", prompt: event.prompt))
        }
        return nil
    }

    /// Resolve a Stop into done vs needs-attention from the transcript's last
    /// message (Haiku when a key is set, structural heuristic otherwise), then
    /// apply it. Falls back to plain "done" when the transcript can't be read.
    private func refineClaudeTurnEnd(
        dropID: UUID, label: String?, message: String?, transcriptPath: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let token = await self.auth.validAccessToken()
            // The Stop hook carries Claude's final message directly — classify
            // it without touching the transcript. Only fall back to reading the
            // file if the payload didn't include it (older Claude Code).
            let result: (status: DropStatus, reason: String)?
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = await self.claudeIntegration.classifyFinalMessage(message, bearer: token)
            } else if let transcriptPath {
                result = await self.claudeIntegration.classifyTurnEnd(
                    transcriptPath: transcriptPath, bearer: token
                )
            } else {
                result = nil
            }
            guard self.store.drop(id: dropID) != nil else { return }
            self.store.updateStatusAndLabel(
                id: dropID,
                to: result?.status ?? .done,
                label: label,
                reason: result?.reason ?? "Claude finished — ready for you"
            )
        }
    }

    private func apply(_ update: ClaudeHookMapper.Update, to drop: Drop, label: String?) {
        if let status = update.status {
            store.updateStatusAndLabel(id: drop.id, to: status, label: label, reason: update.reason)
        } else {
            store.noteReason(id: drop.id, reason: update.reason)
        }
    }

    /// The drop bound to a terminal by TTY — shell-integration drops and
    /// Terminal.app drops that captured their tty.
    private func terminalDrop(tty: String?) -> Drop? {
        guard let tty else { return nil }
        return store.drops.first {
            switch $0.target.locator {
            case .shell(let t): return t == tty
            case .terminal(_, _, let t): return t == tty
            default: return false
            }
        }
    }

    /// Name existing Claude Desktop drops that are still showing the bare app
    /// name ("Claude") from before drop-time title resolution existed — the
    /// title is in the session metadata, keyed by the local_<id> in the URL.
    private func backfillClaudeLabels() {
        for drop in store.drops where drop.target.bundleID == ClaudeDeepLink.bundleID {
            guard drop.label == drop.target.appName || drop.label == drop.target.windowTitle,
                let url = drop.target.contentURL,
                let title = claudeIntegration.sessionTitle(forContentURL: url),
                !title.isEmpty, title != drop.label
            else { continue }
            store.updateLabel(id: drop.id, label: title)
        }
    }

    private func handleShellEvent(_ event: ShellEvent) {
        guard auth.isSignedIn else { return }  // signed out → app is locked
        switch event.event {
        case "register":
            shellIntegration.sessionRegistered()

        case "start":
            guard let drop = shellDrop(tty: event.tty) else { return }
            let cmd = event.cmd ?? ""
            if let agent = AgentCommand.agentName(forCommand: cmd) {
                // An AI agent is starting in this terminal: its hooks (Claude)
                // or rollout journal (Codex) own the drop from here.
                store.updateStatusAndLabel(
                    id: drop.id, to: .working, label: agent, reason: "\(agent) session"
                )
                if agent == "Codex" { bindCodexCLISession(to: drop.id, startedAt: Date()) }
            } else {
                // A plain command supersedes any previous agent session.
                hookManagedDrops.remove(drop.id)
                if drop.target.contentURL?.hasPrefix(CodexIntegration.sessionURLPrefix) == true {
                    store.setContentURL(id: drop.id, url: nil)
                }
                let label = event.cmd.map { CommandLabel.label(forCommand: $0) }
                store.updateStatusAndLabel(
                    id: drop.id, to: .working, label: label, reason: "running…"
                )
            }

        case "done":
            guard let drop = shellDrop(tty: event.tty) else { return }
            let isAgent = event.cmd.flatMap { AgentCommand.agentName(forCommand: $0) } != nil
            let isSuccess = (event.exitCode ?? 1) == 0
            let status: DropStatus = isSuccess ? .done : .needsAttention
            let reason: String
            if isAgent {
                // The agent exited; keep its session label, free the drop for
                // whatever runs next.
                hookManagedDrops.remove(drop.id)
                reason = isSuccess ? "session ended" : "exited with code \(event.exitCode ?? -1)"
                store.updateStatus(id: drop.id, to: status, reason: reason)
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
            store.updateStatusAndLabel(id: drop.id, to: status, label: label, reason: reason)

        default: break
        }
    }

    /// A `codex` CLI launch journals its rollout within a few seconds. Bind
    /// the terminal drop to that session so the rollout watcher drives status
    /// (the desktop and CLI share the journal format).
    private func bindCodexCLISession(to dropID: UUID, startedAt: Date, attempt: Int = 0) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, let current = self.store.drop(id: dropID) else { return }
            // Another command may have taken the terminal over meanwhile —
            // its `start` event clears the binding and renames the drop.
            guard
                current.label.hasPrefix("Codex")
                    || current.target.contentURL?
                        .hasPrefix(CodexIntegration.sessionURLPrefix) == true
            else { return }
            if let id = self.codexIntegration.newestSessionID(modifiedAfter: startedAt) {
                self.store.setContentURL(
                    id: dropID, url: CodexIntegration.sessionURLPrefix + id
                )
            } else if attempt < 5 {
                self.bindCodexCLISession(to: dropID, startedAt: startedAt, attempt: attempt + 1)
            }
        }
    }

    private func shellDrop(tty: String) -> Drop? {
        store.drops.first {
            if case .shell(let t) = $0.target.locator { return t == tty }
            return false
        }
    }

    // MARK: - Auto-dismiss

    private func startAutoDismissWatcher() {
        store.$drops
            .receive(on: DispatchQueue.main)
            .sink { [weak self] drops in
                guard let self else { return }
                guard self.settings.autoDismissMinutes > 0 else { return }
                for drop in drops where drop.status == .done {
                    guard !self.autoDismissScheduled.contains(drop.id) else { continue }
                    self.autoDismissScheduled.insert(drop.id)
                    let id = drop.id
                    let delay = TimeInterval(self.settings.autoDismissMinutes) * 60
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(delay))
                        guard let self else { return }
                        self.autoDismissScheduled.remove(id)
                        guard self.settings.autoDismissMinutes > 0 else { return }
                        guard self.store.drop(id: id)?.status == .done else { return }
                        self.store.remove(id: id)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Status-change alerts (colored notch is rendered by the island;
    // the explicit banner is fired here on real transitions)

    private func startAlertWatcher() {
        store.$drops
            .receive(on: DispatchQueue.main)
            .sink { [weak self] drops in self?.evaluateAlerts(drops) }
            .store(in: &cancellables)
        // Lowering the alert level below `notify` clears any banners on screen
        // immediately, without waiting for the next drop change.
        settings.$alertLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard let self, !level.showsBanner, !self.alertBanners.isEmpty else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    self.alertBanners.removeAll()
                }
            }
            .store(in: &cancellables)
    }

    /// Raise a banner when a drop transitions into an alerting status
    /// (needsAttention / done) at the `notify` level. Edge-triggered via the
    /// per-drop status map: label/reason-only updates raise nothing, and a
    /// drop's first appearance is recorded silently. Banners persist until the
    /// user dismisses them (or the drop goes away); they never time out.
    private func evaluateAlerts(_ drops: [Drop]) {
        // Banners only exist at the notify level. Keep tracking statuses so a
        // later re-enable doesn't replay stale transitions, but show nothing.
        guard settings.alertLevel.showsBanner else {
            lastAlertedStatus = Dictionary(
                drops.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
            if !alertBanners.isEmpty {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    alertBanners.removeAll()
                }
            }
            return
        }

        var present = Set<UUID>()
        for drop in drops {
            present.insert(drop.id)
            let previous = lastAlertedStatus[drop.id]
            lastAlertedStatus[drop.id] = drop.status
            let hasBanner = alertBanners.contains { $0.id == drop.id }
            let action = AlertPolicy.bannerAction(
                from: previous, to: drop.status, hasBanner: hasBanner)
            switch action {
            case .raise:
                upsertBanner(for: drop)
            case .refresh:
                // Keep an already-showing banner's text fresh while the drop
                // stays in its alerting state.
                if let i = alertBanners.firstIndex(where: { $0.id == drop.id }) {
                    alertBanners[i].status = drop.status
                    alertBanners[i].label = drop.label
                    alertBanners[i].source = drop.source
                }
            case .dismiss:
                // The drop left its alerting state (e.g. needsAttention →
                // working): banners only exist for alerting states, so it goes.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    alertBanners.removeAll { $0.id == drop.id }
                }
            case .leave:
                break
            }
            // A newly-raised banner is "showing a notification" — chime once.
            // Refreshes stay silent so a drop that keeps updating doesn't repeat.
            if AlertPolicy.shouldChime(action: action, soundEnabled: settings.alertSoundEnabled) {
                AlertChime.play()
            }
        }
        lastAlertedStatus = lastAlertedStatus.filter { present.contains($0.key) }
        // Drop banners whose drop no longer exists (dismissed / auto-dismissed).
        if alertBanners.contains(where: { !present.contains($0.id) }) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                alertBanners.removeAll { !present.contains($0.id) }
            }
        }
    }

    private func upsertBanner(for drop: Drop) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            if let i = alertBanners.firstIndex(where: { $0.id == drop.id }) {
                alertBanners[i].status = drop.status
                alertBanners[i].label = drop.label
                alertBanners[i].source = drop.source
            } else {
                alertBanners.append(
                    AlertBanner(
                        id: drop.id, status: drop.status, label: drop.label, source: drop.source
                    )
                )
            }
        }
    }

    /// Manually remove a banner (its close button).
    func dismissBanner(id: UUID) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            alertBanners.removeAll { $0.id == id }
        }
    }

    /// Click a banner: jump to its drop, then clear the banner.
    func activateBanner(id: UUID) {
        if let drop = store.drop(id: id) { refocus(drop) }
        dismissBanner(id: id)
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
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            lastForegroundApp = app
        }
    }

    /// The integration this app needs but doesn't have set up, or nil when the
    /// drop may proceed. Each manager is refreshed first so the check reflects
    /// live state (the Chrome bridge in particular is only re-read on refresh).
    private func missingIntegration(for bundleID: String) -> RequiredIntegration? {
        guard let required = RequiredIntegration.required(forBundleID: bundleID) else { return nil }
        let installed: Bool
        switch required {
        case .chrome:
            chromeIntegration.refresh()
            installed = chromeIntegration.isBridgeConnected
        case .shell:
            shellIntegration.refresh()
            installed = shellIntegration.isInstalled
        case .claude:
            claudeIntegration.refresh()
            installed = claudeIntegration.isInstalled
        case .codex:
            installed = settings.codexIntegrationEnabled
        case .cursor:
            cursorIntegration.refresh()
            installed = cursorIntegration.isInstalled
        }
        return installed ? nil : required
    }

    private func targetApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
            front.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            return front
        }
        return lastForegroundApp
    }

    // MARK: - Toast

    /// Show a transient toast bar under the island, auto-dismissing after
    /// `duration`. Replaces any toast already on screen.
    func showToast(_ message: String, duration: TimeInterval = 3) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            toast = ToastBanner(message: message)
        }
        toastDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                self?.toast = nil
            }
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Actions

    @discardableResult
    func createDrop() -> Bool {
        guard auth.isSignedIn else {
            showToast("Sign in to use SuperIsland")
            showOnboarding()
            NSSound.beep()
            return false
        }
        guard AXIsProcessTrusted() else { permissions.requestAccessibility(); return false }
        guard let app = targetApp(), let front = WindowFinder.frontWindow(for: app) else {
            NSSound.beep(); return false
        }
        // SuperIsland only supports apps it has an integration for (browsers,
        // terminals, the AI editors and desktop agents). Refuse anything else
        // and tell the user why instead of dropping a dead chip.
        guard SupportedApps.isSupported(bundleID: front.bundleID) else {
            let name = SupportedApps.displayName(bundleID: front.bundleID, appName: front.appName)
            showToast("SuperIsland doesn't support \(name)")
            NSSound.beep()
            return false
        }
        // Being supported isn't enough — the app's status integration must
        // actually be set up, or the drop can't track anything. Refuse with a
        // toast pointing at Settings, mirroring the unsupported-app path.
        if let missing = missingIntegration(for: front.bundleID) {
            showToast(missing.setupMessage)
            NSSound.beep()
            return false
        }
        // Electron apps build their AX tree lazily; opt in now so it's ready
        // by the time the monitor takes its first snapshot.
        AX.enableManualAccessibility(pid: front.pid)
        let adapter = AdapterRegistry.adapter(for: front.bundleID)
        let locator = adapter.captureLocator(front: front)

        // For apps with internal tabs (Claude Desktop, Codex, …) many tasks
        // share one window. Remember which in-app tab/section is selected right
        // now — it becomes this drop's identity within the window. Two signals:
        // the web content URL (Electron SPAs route per tab — exact) and the
        // selected element's label (apps that mark selection in AX).
        var contextAnchor: String?
        var contentURL: String?
        var threadLabel: String?
        if case .generic = locator {
            contextAnchor = capturedContextAnchor(for: front)
            contentURL = AX.webContentURL(of: front.axWindow)
        }
        // Codex desktop exposes nothing via accessibility — bind the drop to
        // the session whose rollout journal was written most recently (i.e.
        // the thread the user just prompted).
        if front.bundleID == CodexIntegration.bundleID,
            settings.codexIntegrationEnabled,
            let session = codexIntegration.currentSessionGuess()
        {
            contentURL = CodexIntegration.sessionURLPrefix + session.id
            threadLabel = session.title
        }
        // Cursor desktop: no TTY for the GUI — bind to the conversation most
        // recently active in the dropped window's workspace (the one you're
        // looking at), the same recency rule Codex uses for threads.
        if front.bundleID == CursorIntegration.bundleID, cursorIntegration.isInstalled {
            let workspaceName = EditorWindowTitle.parse(front.title).workspaceName
            if let convo = cursorIntegration.currentConversationGuess(workspaceName: workspaceName)
            {
                contentURL = CursorIntegration.sessionURLPrefix + convo.id
                threadLabel =
                    AgentSessionLabel.label(agent: "Cursor", prompt: convo.title)
                    ?? threadLabel
            }
        }
        // Claude Desktop: the conversation title lives in the session metadata,
        // keyed by the local_<id> in the content URL. Resolve it now so an idle
        // or background conversation is named without waiting for a hook event
        // (otherwise the drop falls back to the bare app name "Claude").
        if front.bundleID == ClaudeDeepLink.bundleID, let url = contentURL {
            threadLabel = claudeIntegration.sessionTitle(forContentURL: url)
        }

        let target = WindowTarget(
            bundleID: front.bundleID, appName: front.appName, pid: front.pid,
            windowID: front.windowID, windowTitle: front.title, locator: locator,
            contextAnchor: contextAnchor, contentURL: contentURL
        )
        // One drop per tracked thing, across EVERY integration: if a drop already
        // targets this exact tab / session / window / file / tty, refuse instead
        // of creating a duplicate that would race the original for status updates.
        if store.drops.contains(where: { DropIdentity.sameTarget($0.target, target) }) {
            showToast("Already tracking this")
            NSSound.beep()
            return false
        }
        // Editor drops: "file · workspace" beats the raw window title.
        if case let .editor(_, fileName, workspaceName) = locator {
            threadLabel = [fileName, workspaceName].compactMap { $0 }
                .joined(separator: " · ")
            if threadLabel?.isEmpty == true { threadLabel = nil }
        }
        let fallbackLabel = front.title.isEmpty ? front.appName : front.title
        let label =
            threadLabel
            ?? contextAnchor.map { String($0.prefix(60)) }
            ?? fallbackLabel
        // Terminal drops start idle (gray): their state is unknown until a
        // shell/agent event arrives, and they're never AI-classified. Other
        // apps start optimistic (working) and the monitor refines them.
        let initialStatus: DropStatus
        switch locator {
        case .shell, .terminal, .iterm: initialStatus = .unknown
        default: initialStatus = .working
        }
        let drop = Drop(label: label, target: target, status: initialStatus)
        store.add(drop)
        dlog(.app, "drop created: \(drop.label) [\(front.bundleID)]")
        suggestAILabelIfTerminal(for: drop)
        suggestClaudeStatusIfDesktop(for: drop)
        suggestClaudeStatusIfTerminal(for: drop)
        return true
    }

    /// A Claude Desktop drop created on an already-finished or already-waiting
    /// session has no incoming hook event to set its status (the hooks fired
    /// before the drop existed). Derive the current state from the transcript.
    private func suggestClaudeStatusIfDesktop(for drop: Drop) {
        guard drop.target.bundleID == ClaudeDeepLink.bundleID,
            let url = drop.target.contentURL,
            let path = claudeIntegration.transcriptPath(forContentURL: url)
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let token = await self.auth.validAccessToken()
            guard
                let result = await self.claudeIntegration.classifyTurnEnd(
                    transcriptPath: path, bearer: token
                ),
                self.store.drop(id: drop.id) != nil
            else { return }
            self.store.updateStatus(id: drop.id, to: result.status, reason: result.reason)
        }
    }

    /// A terminal drop made over an already-running Claude Code session has no
    /// incoming hook event either — hooks fire on lifecycle *events*, and an
    /// idle session emits none. Mirror the Desktop path: find the claude process
    /// on the drop's TTY, read its newest transcript, and seed the status so the
    /// drop doesn't sit at "unknown" until the next prompt. A later hook event
    /// supersedes this.
    private func suggestClaudeStatusIfTerminal(for drop: Drop) {
        let ttyDevice: String?
        switch drop.target.locator {
        case .shell(let t): ttyDevice = t
        case .terminal(_, _, let t): ttyDevice = t
        default: return
        }
        guard let tty = ttyDevice else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let token = await self.auth.validAccessToken()
            guard let path = await Self.claudeTranscriptOnTTY(tty),
                let result = await self.claudeIntegration.classifyTurnEnd(
                    transcriptPath: path, bearer: token
                ),
                // Never seed sticky `.working` cold — see adoptsColdStartSeed.
                ClaudeTerminalSession.adoptsColdStartSeed(result.status),
                let current = self.store.drop(id: drop.id),
                // A shell/agent hook event arriving first owns the drop.
                current.status == .unknown,
                !self.hookManagedDrops.contains(drop.id)
            else { return }
            self.store.updateStatus(id: drop.id, to: result.status, reason: result.reason)
        }
    }

    /// The transcript path of the Claude session running on a terminal's TTY,
    /// resolved off the main thread: TTY → claude pid → its cwd → newest
    /// transcript in that working directory. nil when no claude is there.
    nonisolated private static func claudeTranscriptOnTTY(_ tty: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let device = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
            guard let psOut = runProcess("/bin/ps", ["-t", device, "-o", "pid=,ppid=,command="]),
                let pid = ClaudeTerminalSession.claudePID(psOutput: psOut),
                let cwd = processCWD(pid: pid)
            else { return nil }
            let dir = ClaudeTranscript.projectDirectory(
                home: FileManager.default.homeDirectoryForCurrentUser, cwd: cwd
            )
            let fm = FileManager.default
            guard
                let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
                )
            else { return nil }
            let candidates: [(url: URL, modified: Date)] =
                entries
                .filter { $0.pathExtension == "jsonl" }
                .map { url in
                    let date =
                        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return (url: url, modified: date)
                }
            return ClaudeTerminalSession.newestTranscript(among: candidates)?.path
        }.value
    }

    /// A process's current working directory via `lsof` (no /proc on macOS).
    nonisolated private static func processCWD(pid: Int32) -> String? {
        guard let out = runProcess("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        else { return nil }
        // -Fn output is field-prefixed lines; the cwd path is the line after
        // "fcwd", prefixed with "n".
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    nonisolated private static func runProcess(_ launchPath: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Terminal drops skip AI status polling (shell events own them), so they
    /// never get the monitor's AI label either — their initial label is a raw
    /// window title like "akhil — -zsh — 80×24". One cheap drop-time Claude
    /// call names what's actually running. Skipped silently without an API
    /// key; an agent/shell event arriving first wins.
    private func suggestAILabelIfTerminal(for drop: Drop) {
        switch drop.target.locator {
        case .shell, .terminal, .iterm: break
        default: return
        }
        // Lazily fetched inside the Task below.
        let initialLabel = drop.label
        let target = drop.target
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let token = await self.auth.validAccessToken() else { return }
            let snapshot = await CaptureService.snapshot(
                pid: target.pid, windowID: target.windowID,
                axWindow: WindowFinder.axWindow(pid: target.pid, windowID: target.windowID)
            )
            guard snapshot.axText.count >= 30 else { return }
            let input = ClassificationInput(
                appName: target.appName,
                windowTitle: target.windowTitle,
                axText: snapshot.axText
            )
            guard
                let verdict = try? await ClaudeClassifier(
                    auth: .proxy(url: BackendConfig.classifyURL, bearer: token),
                    model: ClassifierProtocolBuilder.defaultModel
                ).classify(input),
                let aiLabel = verdict.label, !aiLabel.isEmpty
            else { return }
            // Only fill in the placeholder — don't overwrite a label a shell
            // or agent event set while the API call was in flight.
            guard let current = self.store.drop(id: drop.id),
                current.label == initialLabel
            else { return }
            self.store.updateLabel(id: drop.id, label: aiLabel)
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

    func refocus(_ drop: Drop) {
        guard auth.isSignedIn else { return }  // signed out → app is locked
        Refocuser.refocus(drop)
    }

    func dismiss(_ drop: Drop) { store.remove(id: drop.id) }

    // MARK: - Onboarding

    /// Set by the AppDelegate so menu/Settings can reopen the tour.
    var showOnboardingRequested: (() -> Void)?

    func showOnboarding() { showOnboardingRequested?() }

    /// Set by the AppDelegate so the menu-bar "Logs…" item can open the viewer.
    var showLogsRequested: (() -> Void)?

    func showLogs() { showLogsRequested?() }

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
