import SwiftUI
import AppKit
import Carbon.HIToolbox
import KlipCore

/// The 8-step journey. Steps read the live integration objects; the window
/// controller supplies `onFinish`.
struct OnboardingView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsManager
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var shellIntegration: ShellIntegration
    @EnvironmentObject var claudeIntegration: ClaudeIntegration
    @EnvironmentObject var chromeIntegration: ChromeIntegration
    @EnvironmentObject var codexIntegration: CodexIntegration

    var onFinish: () -> Void

    @State private var index = 0
    private var steps: [OnboardingStep] { OnboardingStep.allCases }
    private var step: OnboardingStep { steps[index] }

    var body: some View {
        ZStack {
            OnboardingBackground()
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 56)
                    .padding(.top, 44)
                    .id(index)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 28)),
                        removal: .opacity.combined(with: .offset(x: -28))
                    ))
                navigation
            }
        }
        .onAppear { permissions.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStepView()
        case .story: StoryStepView()
        case .accessibility: AccessibilityStepView()
        case .terminal: TerminalStepView()
        case .claude: ClaudeStepView()
        case .codex: CodexStepView()
        case .chrome: ChromeStepView()
        case .finish: FinishStepView()
        }
    }

    // MARK: Navigation rail

    private var navigation: some View {
        HStack(spacing: 14) {
            if index > 0 {
                Button("Back") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { index -= 1 }
                }
                .buttonStyle(GhostPillButtonStyle())
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? OnboardingTheme.purpleLight : .white.opacity(0.18))
                        .frame(width: i == index ? 18 : 6, height: 6)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: index)
                }
            }
            Spacer()
            Button(primaryLabel) {
                if index == steps.count - 1 {
                    onFinish()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { index += 1 }
                }
            }
            .buttonStyle(GlowPillButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Begin"
        case .finish: return "Finish"
        default: return "Continue"
        }
    }
}

// MARK: - Shared step scaffolding

private struct StepHeader: View {
    let eyebrow: String
    let title: Text
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(OnboardingTheme.lavender)
            title
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(OnboardingTheme.heading)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingTheme.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 1 · Welcome

private struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 22) {
            if let mascot = OnboardingTheme.art("mascot.webp") {
                Image(nsImage: mascot)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 150)
                    .shadow(color: OnboardingTheme.glow, radius: 30)
            }
            (Text("Never babysit\na ").font(.system(size: 38, weight: .bold))
                + Text("window").font(OnboardingTheme.serifAccent(40))
                + Text(" again").font(.system(size: 38, weight: .bold)))
                .foregroundStyle(OnboardingTheme.heading)
                .multilineTextAlignment(.center)
            Text("Klip bookmarks your long-running work — builds, deploys, Claude, Codex — and pulls you back to the exact window or tab the moment it needs you.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingTheme.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 2 · The Klip way

private struct StoryStepView: View {
    private let rows: [(icon: String, title: String, detail: String)] = [
        ("terminal.fill", "Shells tell Klip when commands finish",
         "A zsh/bash hook reports start and exit — status flips in milliseconds, with the exit code."),
        ("globe", "Chrome tells Klip which tab matters",
         "A lightweight extension tracks tab identity and page signals — even in background tabs."),
        ("sparkle", "Agents report themselves",
         "Claude Code hooks and Codex session journals stream ground truth: working, needs approval, done."),
        ("brain.head.profile", "AI covers everything else",
         "For apps with no signal, Claude classifies the window — and only when content actually settles."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "The Klip way",
                title: Text("The best truth source ")
                    + Text("for every app").font(OnboardingTheme.serifAccent(31))
            )
            VStack(spacing: 10) {
                ForEach(rows, id: \.title) { row in
                    OnboardingGlassCard {
                        HStack(spacing: 13) {
                            Image(systemName: row.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(OnboardingTheme.purpleLight)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(OnboardingTheme.heading)
                                Text(row.detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(OnboardingTheme.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 3 · Accessibility

private struct AccessibilityStepView: View {
    @EnvironmentObject var permissions: PermissionsManager

    private var granted: Bool { permissions.accessibility == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "One permission",
                title: Text("Klip needs ")
                    + Text("Accessibility").font(OnboardingTheme.serifAccent(31)),
                subtitle: "It's how Klip reads window text and raises the exact window when you click a klip. Without it, nothing works — this is the only required permission."
            )
            OnboardingGlassCard {
                HStack {
                    Image(systemName: "accessibility")
                        .font(.system(size: 22))
                        .foregroundStyle(OnboardingTheme.purpleLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OnboardingTheme.heading)
                        Text("System Settings → Privacy & Security")
                            .font(.system(size: 11))
                            .foregroundStyle(OnboardingTheme.body)
                    }
                    Spacer()
                    if granted {
                        OnboardingChip(text: "granted", color: .green)
                    } else {
                        Button("Grant Access") {
                            permissions.requestAccessibility()
                            permissions.openAccessibilitySettings()
                        }
                        .buttonStyle(GlowPillButtonStyle())
                    }
                }
            }
            if !granted {
                Button {
                    permissions.resetStaleGrant(service: "Accessibility")
                } label: {
                    Label("Toggle is ON but Klip still shows “not granted”? Reset & re-prompt.",
                          systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingTheme.lavender)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 4 · Terminal

private struct TerminalStepView: View {
    @EnvironmentObject var shellIntegration: ShellIntegration
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Integration 1 of 4",
                title: Text("Your shell, ")
                    + Text("wired in").font(OnboardingTheme.serifAccent(31)),
                subtitle: "One hook in zsh and bash tells Klip the instant any command finishes — in Terminal, iTerm2, Warp, anywhere. Exit 0 → done. Anything else → needs you."
            )
            OnboardingGlassCard {
                HStack {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(OnboardingTheme.purpleLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shell Integration")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OnboardingTheme.heading)
                        Text(shellIntegration.isInstalled
                             ? "Restart open terminals to connect them."
                             : "Adds one line to ~/.zshrc and ~/.bashrc.")
                            .font(.system(size: 11))
                            .foregroundStyle(OnboardingTheme.body)
                    }
                    Spacer()
                    if shellIntegration.isInstalled {
                        OnboardingChip(
                            text: shellIntegration.activeSessions > 0
                                ? "\(shellIntegration.activeSessions) connected" : "active",
                            color: .green
                        )
                    } else {
                        Button("Set Up") { install() }
                            .buttonStyle(GlowPillButtonStyle())
                    }
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onAppear { shellIntegration.refresh() }
    }

    private func install() {
        do { try shellIntegration.install(); error = nil }
        catch { self.error = "Setup failed: \(error.localizedDescription)" }
    }
}

// MARK: - 5 · Claude Desktop

private struct ClaudeStepView: View {
    @EnvironmentObject var claudeIntegration: ClaudeIntegration
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Integration 2 of 4",
                title: Text("Claude reports ")
                    + Text("itself").font(OnboardingTheme.serifAccent(31)),
                subtitle: "Claude Code hooks stream session events straight to Klip: working, finished, needs your input — even for background tabs, with zero AI calls."
            )
            OnboardingGlassCard {
                HStack {
                    Image(systemName: "sparkle")
                        .font(.system(size: 20))
                        .foregroundStyle(OnboardingTheme.purpleLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Desktop")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OnboardingTheme.heading)
                        Text(claudeIntegration.isInstalled
                             ? "Applies to sessions started from now on."
                             : "Adds hook entries to ~/.claude/settings.json.")
                            .font(.system(size: 11))
                            .foregroundStyle(OnboardingTheme.body)
                    }
                    Spacer()
                    if claudeIntegration.isInstalled {
                        OnboardingChip(text: "active", color: .green)
                    } else {
                        Button("Set Up") { install() }
                            .buttonStyle(GlowPillButtonStyle())
                    }
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onAppear { claudeIntegration.refresh() }
    }

    private func install() {
        do { try claudeIntegration.install(); error = nil }
        catch { self.error = "Setup failed: \(error.localizedDescription)" }
    }
}

// MARK: - 6 · Codex

private struct CodexStepView: View {
    @EnvironmentObject var codexIntegration: CodexIntegration

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Integration 3 of 4",
                title: Text("Codex is ")
                    + Text("already live").font(OnboardingTheme.serifAccent(31)),
                subtitle: "Nothing to set up. Klip reads Codex's own session journals — thread names, working / finished / needs-approval, and Codex's last message — and deep-links you back to the exact thread."
            )
            OnboardingGlassCard {
                HStack {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 20))
                        .foregroundStyle(OnboardingTheme.purpleLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OnboardingTheme.heading)
                        Text("Prompt a thread, then klip it — that's the whole gesture.")
                            .font(.system(size: 11))
                            .foregroundStyle(OnboardingTheme.body)
                    }
                    Spacer()
                    OnboardingChip(
                        text: codexIntegration.knownThreadCount > 0
                            ? "\(codexIntegration.knownThreadCount) threads found" : "ready",
                        color: .green
                    )
                }
            }
        }
    }
}

// MARK: - 7 · Chrome

private struct ChromeStepView: View {
    @EnvironmentObject var chromeIntegration: ChromeIntegration
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Integration 4 of 4",
                title: Text("Exact tabs in ")
                    + Text("Chrome").font(OnboardingTheme.serifAccent(31)),
                subtitle: "The Klip extension tracks the exact tab — identity, page signals, background or not — far beyond what screenshots can see."
            )
            OnboardingGlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "globe")
                            .font(.system(size: 20))
                            .foregroundStyle(OnboardingTheme.purpleLight)
                        Text("Chrome Extension")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OnboardingTheme.heading)
                        Spacer()
                        OnboardingChip(text: chromeStatus.0, color: chromeStatus.1)
                    }
                    if !chromeIntegration.isNativeHostInstalled {
                        Button("Set Up Chrome Integration") { setUp() }
                            .buttonStyle(GlowPillButtonStyle())
                    } else if !chromeIntegration.isExtensionLoaded {
                        Text("Native host installed. In Chrome: turn on Developer mode, then drag the revealed ChromeExtension folder onto the extensions page.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(OnboardingTheme.body)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button("Open Chrome Extensions") { chromeIntegration.openChromeExtensions() }
                                .buttonStyle(GhostPillButtonStyle())
                            Button("Reveal Folder") { chromeIntegration.revealExtensionFolder() }
                                .buttonStyle(GhostPillButtonStyle())
                            Button("Check Again") { chromeIntegration.refresh() }
                                .buttonStyle(GhostPillButtonStyle())
                        }
                    } else {
                        Text("Connected. Chrome klips now track their exact tab, even in the background.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(OnboardingTheme.body)
                    }
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onAppear { chromeIntegration.refresh() }
    }

    private var chromeStatus: (String, Color) {
        if chromeIntegration.isBridgeConnected { return ("connected", .green) }
        if chromeIntegration.isExtensionLoaded { return ("loaded", .green) }
        if chromeIntegration.isNativeHostInstalled { return ("waiting for Chrome", .orange) }
        return ("not set up", .gray)
    }

    private func setUp() {
        do { try chromeIntegration.setUp(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - 8 · Finish

private struct FinishStepView: View {
    @EnvironmentObject var settings: Settings

    private var keycaps: [String] {
        var caps: [String] = []
        if settings.hotkeyModifiers & controlKey != 0 { caps.append("⌃") }
        if settings.hotkeyModifiers & optionKey != 0 { caps.append("⌥") }
        if settings.hotkeyModifiers & shiftKey != 0 { caps.append("⇧") }
        if settings.hotkeyModifiers & cmdKey != 0 { caps.append("⌘") }
        caps.append(keyCodeName(settings.hotkeyKeyCode))
        return caps
    }

    var body: some View {
        VStack(spacing: 24) {
            (Text("Drop your ").font(.system(size: 34, weight: .bold))
                + Text("first klip").font(OnboardingTheme.serifAccent(36)))
                .foregroundStyle(OnboardingTheme.heading)
            HStack(spacing: 10) {
                ForEach(keycaps, id: \.self) { Keycap(symbol: $0) }
            }
            Text("Focus any window with work in progress and press the shortcut. The island by the notch keeps watch — click a klip there to jump straight back.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingTheme.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity)
    }
}
