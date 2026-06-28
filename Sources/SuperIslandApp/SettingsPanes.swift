import SwiftUI
import AppKit
import SuperIslandCore

// MARK: - Settings window

/// Tabbed, System Settings-style preferences window.
struct SettingsView: View {
    @EnvironmentObject var auth: AuthService

    var body: some View {
        TabView {
            AccountSettingsPane()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            // Signed out, the app is locked — only the Account (sign-in) tab is
            // reachable; the rest appear once signed in.
            if auth.isSignedIn {
                GeneralSettingsPane()
                    .tabItem { Label("General", systemImage: "gearshape") }
                IntegrationsSettingsPane()
                    .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
                PermissionsSettingsPane()
                    .tabItem { Label("Permissions", systemImage: "lock.shield") }
                AboutSettingsPane()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
        }
        .frame(width: 540)
    }
}

// MARK: - Shared building blocks

/// Tinted squircle icon, System Settings style.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.85), color],
                            startPoint: .top, endPoint: .bottom
                        ))
            )
    }
}

/// Icon + title (+ optional caption) used as the label side of settings rows.
struct SettingsRowLabel: View {
    let icon: String
    let color: Color
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(systemName: icon, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Capsule status chip with a leading dot.
struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundStyle(color)
    }
}

/// Card container used on the Integrations pane.
struct IntegrationCard<Content: View>: View {
    let icon: String
    let color: Color
    let title: String
    let status: (text: String, color: Color)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SettingsIcon(systemName: icon, color: color)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                StatusChip(text: status.text, color: status.color)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var controller: AppController

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.launchAtLogin) {
                    SettingsRowLabel(icon: "power", color: .green, title: "Launch at Login")
                }
                Picker(selection: $settings.autoDismissMinutes) {
                    Text("Never").tag(0)
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                } label: {
                    SettingsRowLabel(
                        icon: "timer", color: .orange,
                        title: "Auto-dismiss done drops"
                    )
                }
                Picker(selection: $settings.islandExpandOnHover) {
                    Text("On hover").tag(true)
                    Text("On click").tag(false)
                } label: {
                    SettingsRowLabel(
                        icon: "cursorarrow.motionlines", color: .indigo,
                        title: "Expand island"
                    )
                }
                Picker(selection: $settings.alertLevel) {
                    ForEach(AlertLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                } label: {
                    SettingsRowLabel(
                        icon: "bell.badge", color: .pink,
                        title: "Alert level",
                        subtitle: settings.alertLevel.detail
                    )
                }
                Toggle(isOn: $settings.alertSoundEnabled) {
                    SettingsRowLabel(
                        icon: "speaker.wave.2", color: .blue,
                        title: "Play sound for alerts"
                    )
                }
            }

            Section {
                LabeledContent {
                    KeyRecorderField(
                        keyCode: $settings.hotkeyKeyCode,
                        modifiers: $settings.hotkeyModifiers
                    )
                } label: {
                    SettingsRowLabel(
                        icon: "command", color: .purple,
                        title: "New Drop shortcut"
                    )
                }
                if let diagnostic = controller.hotkeyDiagnostic, !diagnostic.isRegistered {
                    Label(diagnostic.summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}

// MARK: - Integrations

struct IntegrationsSettingsPane: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var shellIntegration: ShellIntegration
    @EnvironmentObject var chromeIntegration: ChromeIntegration
    @EnvironmentObject var claudeIntegration: ClaudeIntegration
    @EnvironmentObject var cursorIntegration: CursorIntegration
    @EnvironmentObject var codexIntegration: CodexIntegration

    @State private var shellError: String?
    @State private var chromeError: String?
    @State private var claudeError: String?
    @State private var cursorError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                shellCard
                claudeCard
                cursorCard
                codexCard
                chromeCard
            }
            .padding(16)
        }
        .frame(height: 640)
        .onAppear {
            shellIntegration.refresh()
            chromeIntegration.refresh()
            claudeIntegration.refresh()
            cursorIntegration.refresh()
        }
    }

    // MARK: Codex

    private var codexCard: some View {
        IntegrationCard(
            icon: "chevron.left.forwardslash.chevron.right", color: .teal,
            title: "Codex",
            status: settings.codexIntegrationEnabled ? ("Active", .green) : ("Off", .gray)
        ) {
            Text(
                "No setup. SuperIsland reads Codex's session journals directly: working, finished (with Codex's last message), or waiting for approval, even in background tabs. Clicking a drop jumps to the exact thread."
            )
            .settingsCaption()
            Toggle("Read Codex session journals", isOn: $settings.codexIntegrationEnabled)
                .controlSize(.small)
            Text(
                "Prompt a thread first, then place the drop — the freshest journal tells SuperIsland which thread it is."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Claude Desktop

    private var claudeCard: some View {
        IntegrationCard(
            icon: "sparkle", color: .orange,
            title: "Claude Desktop",
            status: claudeIntegration.isInstalled ? ("Active", .green) : ("Not set up", .gray)
        ) {
            Text(
                "Live status for Claude Code and Cowork sessions via Claude's own hooks: the instant Claude finishes or needs you, your drop updates — even in background tabs. No AI calls."
            )
            .settingsCaption()

            if let claudeError {
                Text(claudeError).font(.caption).foregroundStyle(.red)
            }

            if claudeIntegration.isInstalled {
                HStack {
                    Text("Applies to sessions started after setup.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Uninstall", role: .destructive) {
                        claudeIntegration.uninstall()
                    }
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Button("Set Up Claude Hooks") {
                        do {
                            try claudeIntegration.install()
                            claudeError = nil
                        } catch {
                            claudeError = "Setup failed: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Text("Adds hook entries to ~/.claude/settings.json")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }

    // MARK: Cursor

    private var cursorCard: some View {
        IntegrationCard(
            icon: "cursorarrow.rays", color: .indigo,
            title: "Cursor",
            status: cursorIntegration.isInstalled ? ("Active", .green) : ("Not set up", .gray)
        ) {
            Text(
                "Live status for Cursor's agent (Composer) via Cursor's own hooks: the instant Cursor finishes or needs you, your drop updates — even in background windows. No AI calls."
            )
            .settingsCaption()

            if let cursorError {
                Text(cursorError).font(.caption).foregroundStyle(.red)
            }

            if cursorIntegration.isInstalled {
                HStack {
                    Text("Applies to conversations after setup. Restart Cursor to load hooks.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Uninstall", role: .destructive) {
                        cursorIntegration.uninstall()
                    }
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Button("Set Up Cursor Hooks") {
                        do {
                            try cursorIntegration.install()
                            cursorError = nil
                        } catch {
                            cursorError = "Setup failed: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Text("Adds hook entries to ~/.cursor/hooks.json")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }

    // MARK: Shell

    private var shellCard: some View {
        IntegrationCard(
            icon: "terminal.fill", color: .indigo,
            title: "Shell Integration",
            status: shellIntegration.isInstalled ? ("Active", .green) : ("Not set up", .gray)
        ) {
            Text(
                "Tracks commands in Terminal, iTerm2, Warp, and any other terminal through zsh/bash hooks. Status flips the instant a command finishes — no AI, no screenshots."
            )
            .settingsCaption()

            if let shellError {
                Text(shellError).font(.caption).foregroundStyle(.red)
            }

            if shellIntegration.isInstalled {
                HStack {
                    Text(
                        shellIntegration.activeSessions > 0
                            ? "\(shellIntegration.activeSessions) session\(shellIntegration.activeSessions == 1 ? "" : "s") connected"
                            : "Open a new terminal window to connect."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Uninstall", role: .destructive) {
                        shellIntegration.uninstall()
                    }
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Button("Set Up Shell Integration") {
                        do {
                            try shellIntegration.install()
                            shellError = nil
                        } catch {
                            shellError = "Setup failed: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Text("Adds one line to ~/.zshrc · restart open terminals")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }

    // MARK: Chrome

    private var chromeStatus: (text: String, color: Color) {
        if chromeIntegration.isBridgeConnected { return ("Connected", .green) }
        if chromeIntegration.isExtensionLoaded { return ("Extension loaded", .green) }
        if chromeIntegration.isNativeHostInstalled { return ("Waiting for Chrome", .orange) }
        return ("Not set up", .gray)
    }

    private var chromeCard: some View {
        IntegrationCard(
            icon: "globe", color: .blue,
            title: "Chrome Extension",
            status: chromeStatus
        ) {
            Text(
                "Tracks the exact tab — even in the background — using Chrome's own tab identity and page signals. Far stronger than screenshots for Claude, ChatGPT, CI pages, and deploys."
            )
            .settingsCaption()

            if let chromeError {
                Text(chromeError).font(.caption).foregroundStyle(.red)
            }

            if !chromeIntegration.isNativeHostInstalled {
                HStack {
                    Button("Set Up Chrome Integration") {
                        do {
                            try chromeIntegration.setUp()
                            chromeError = nil
                        } catch {
                            chromeError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Text("One click — no extension ID to copy")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else if !chromeIntegration.isExtensionLoaded {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "Native host installed. One step left in Chrome:",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                    Text(
                        "Turn on **Developer mode** on the extensions page, then drag the revealed **ChromeExtension** folder onto it (or click \u{201c}Load unpacked\u{201d})."
                    )
                    .settingsCaption()
                    HStack(spacing: 8) {
                        Button("Open Chrome Extensions") {
                            chromeIntegration.openChromeExtensions()
                        }
                        .controlSize(.small)
                        Button("Reveal Folder") { chromeIntegration.revealExtensionFolder() }
                            .controlSize(.small)
                        Button("Check Again") { chromeIntegration.refresh() }
                            .controlSize(.small)
                        Spacer()
                        Button("Uninstall", role: .destructive) {
                            chromeIntegration.uninstallNativeHost()
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                HStack {
                    Label(
                        chromeIntegration.isBridgeConnected
                            ? "Live — Chrome is reporting tab state."
                            : "Extension loaded. Reload it (or restart Chrome) if events don't arrive.",
                        systemImage: chromeIntegration.isBridgeConnected
                            ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                    Spacer()
                    Button("Check Again") { chromeIntegration.refresh() }
                        .controlSize(.small)
                    Button("Uninstall", role: .destructive) {
                        chromeIntegration.uninstallNativeHost()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

}

private extension Text {
    func settingsCaption() -> some View {
        self.font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Permissions

struct PermissionsSettingsPane: View {
    @EnvironmentObject var permissions: PermissionsManager

    var body: some View {
        Form {
            Section {
                permissionRow(
                    icon: "accessibility", color: .blue,
                    title: "Accessibility",
                    subtitle:
                        "Reads window text and raises the exact window when you click a drop. Required.",
                    granted: permissions.accessibility == .granted,
                    tccService: "Accessibility"
                ) {
                    permissions.requestAccessibility()
                    permissions.openAccessibilitySettings()
                }
            } footer: {
                Text(
                    "Toggle ON in System Settings but SuperIsland still shows \u{201c}not granted\u{201d}? The grant went stale after a rebuild \u{2014} click \u{27f2} to reset SuperIsland\u{2019}s permission entry and get a fresh prompt."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    SettingsRowLabel(
                        icon: "gearshape.2", color: .gray,
                        title: "Automation",
                        subtitle:
                            "Lets SuperIsland select exact Chrome tabs and terminal panes via Apple Events. macOS asks per-app on first use."
                    )
                    Spacer()
                    Button("Open Settings…") { permissions.openAutomationSettings() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
        .onAppear { permissions.refresh() }
    }

    private func permissionRow(
        icon: String, color: Color, title: String, subtitle: String,
        granted: Bool, tccService: String, action: @escaping () -> Void
    ) -> some View {
        HStack {
            SettingsRowLabel(icon: icon, color: color, title: title, subtitle: subtitle)
            Spacer()
            if granted {
                StatusChip(text: "Granted", color: .green)
            } else {
                Button("Grant…", action: action).controlSize(.small)
                Button {
                    permissions.resetStaleGrant(service: tccService)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .help(
                    "Reset SuperIsland's \(title) entry and re-prompt (fixes a stale grant after a rebuild)"
                )
            }
        }
    }
}

// MARK: - About

struct AboutSettingsPane: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var updater: SoftwareUpdater

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("SuperIsland")
                .font(.title2.weight(.semibold))
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("A bookmark for everything you're waiting on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Divider()
                .padding(.vertical, 10)
                .padding(.horizontal, 60)

            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
                .padding(.bottom, 4)

            Link("Send Feedback", destination: URL(string: "mailto:hi@drop.dev")!)
                .font(.caption)
            Button("Replay Welcome Tour") { controller.showOnboarding() }
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .frame(height: 300)
    }
}
