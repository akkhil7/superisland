import SwiftUI
import AppKit
import Carbon.HIToolbox
import KlipCore

/// The 4-step journey. Steps read the live integration objects; the window
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
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 52)
                .padding(.top, 30)
                .clipped()   // content may never push the nav rail out
                .id(index)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 28)),
                    removal: .opacity.combined(with: .offset(x: -28))
                ))
            navigation
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // As a `.background` the aurora can never drive layout — as a ZStack
        // sibling its scaledToFill width (image aspect × 560) became the
        // stack's layout width and pushed the UI past the window edges.
        .background(OnboardingBackground())
        .onAppear { permissions.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStepView()
        case .accessibility: AccessibilityStepView()
        case .integrations: IntegrationsStepView()
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
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Begin"
        case .finish: return "Finish"
        default: return "Continue"
        }
    }
}

// MARK: - 1 · Welcome

private struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            if let mascot = OnboardingTheme.art("mascot.webp") {
                Image(nsImage: mascot)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 160)
                    .shadow(color: OnboardingTheme.glow, radius: 30)
            }
            (Text("Never babysit a ").font(.system(size: 36, weight: .bold))
                + Text("window").font(OnboardingTheme.serifAccent(38))
                + Text(" again").font(.system(size: 36, weight: .bold)))
                .foregroundStyle(OnboardingTheme.heading)
                .multilineTextAlignment(.center)
            Text("Klip watches your long-running work and pulls you back the moment it needs you.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingTheme.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 2 · Accessibility

private struct AccessibilityStepView: View {
    @EnvironmentObject var permissions: PermissionsManager

    private var granted: Bool { permissions.accessibility == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(
                plain: "One permission: ", accent: "Accessibility",
                subtitle: "How Klip reads windows and brings them back. Required."
            )
            OnboardingGlassCard {
                HStack {
                    Image(systemName: "accessibility")
                        .font(.system(size: 22))
                        .foregroundStyle(OnboardingTheme.purpleLight)
                    Text("Accessibility")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OnboardingTheme.heading)
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
                    Label("Already ON in System Settings? Reset & re-prompt.",
                          systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingTheme.lavender)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 3 · Integrations (all on one screen)

private struct IntegrationsStepView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var shellIntegration: ShellIntegration
    @EnvironmentObject var claudeIntegration: ClaudeIntegration
    @EnvironmentObject var chromeIntegration: ChromeIntegration
    @EnvironmentObject var codexIntegration: CodexIntegration

    @State private var error: String?
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(
                plain: "Wire in ", accent: "your tools",
                subtitle: "Each one reports its own truth — no screenshots, no guessing."
            )
            VStack(spacing: 8) {
                // Terminal
                IntegrationRow(
                    icon: "terminal.fill", name: "Terminal",
                    caption: "zsh & bash · instant exit-code status"
                ) {
                    statusChip(active: shellIntegration.isInstalled)
                    installToggle(isOn: shellIntegration.isInstalled) { on in
                        if on { try shellIntegration.install() }
                        else { shellIntegration.uninstall() }
                    }
                }

                // Claude Desktop
                IntegrationRow(
                    icon: "sparkle", name: "Claude Desktop",
                    caption: "session hooks · live even in background tabs"
                ) {
                    statusChip(active: claudeIntegration.isInstalled)
                    installToggle(isOn: claudeIntegration.isInstalled) { on in
                        if on { try claudeIntegration.install() }
                        else { claudeIntegration.uninstall() }
                    }
                }

                // Codex — no install; the switch gates journal reading.
                IntegrationRow(
                    icon: "chevron.left.forwardslash.chevron.right", name: "Codex",
                    caption: "session journals · automatic"
                ) {
                    statusChip(active: settings.codexIntegrationEnabled)
                    Toggle("", isOn: $settings.codexIntegrationEnabled)
                        .labelsHidden()
                        .toggleStyle(PurpleSwitchToggleStyle())
                }

                // Chrome — active only once the extension is actually loaded.
                IntegrationRow(
                    icon: "globe", name: "Chrome",
                    caption: chromeCaption
                ) {
                    statusChip(active: chromeIntegration.isNativeHostInstalled
                               && chromeIntegration.isExtensionLoaded)
                    installToggle(isOn: chromeIntegration.isNativeHostInstalled) { on in
                        if on { try chromeIntegration.setUp() }
                        else { chromeIntegration.uninstallNativeHost() }
                    }
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onAppear { refreshAll() }
        .onReceive(refresh) { _ in refreshAll() }
    }

    private func refreshAll() {
        shellIntegration.refresh()
        claudeIntegration.refresh()
        chromeIntegration.refresh()
    }

    private var chromeCaption: String {
        if chromeIntegration.isNativeHostInstalled, !chromeIntegration.isExtensionLoaded {
            return "drag the revealed folder onto chrome://extensions"
        }
        return "exact tabs · background included"
    }

    private func statusChip(active: Bool) -> some View {
        OnboardingChip(
            text: active ? "active" : "inactive",
            color: active ? .green : .gray
        )
    }

    /// Purple switch that runs install/uninstall side effects. State comes
    /// from the integration objects, so a failed install snaps back off.
    private func installToggle(
        isOn: Bool, perform: @escaping (Bool) throws -> Void
    ) -> some View {
        Toggle("", isOn: Binding(
            get: { isOn },
            set: { on in
                do { try perform(on); error = nil }
                catch { self.error = error.localizedDescription }
            }
        ))
        .labelsHidden()
        .toggleStyle(PurpleSwitchToggleStyle())
    }
}

/// One compact integration row: icon · name + caption · trailing status/action.
private struct IntegrationRow<Trailing: View>: View {
    let icon: String
    let name: String
    let caption: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        OnboardingGlassCard {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.purpleLight)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OnboardingTheme.heading)
                    Text(caption)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(OnboardingTheme.body)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

// MARK: - 4 · Finish

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
        VStack(spacing: 22) {
            (Text("Drop your ").font(.system(size: 32, weight: .bold))
                + Text("first klip").font(OnboardingTheme.serifAccent(34)))
                .foregroundStyle(OnboardingTheme.heading)
            HStack(spacing: 10) {
                ForEach(keycaps, id: \.self) { Keycap(symbol: $0) }
            }
            Text("Press it on any window with work in progress. The island by the notch takes it from there.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingTheme.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared title

private struct StepTitle: View {
    let plain: String
    let accent: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text(plain).font(.system(size: 28, weight: .bold))
                + Text(accent).font(OnboardingTheme.serifAccent(29)))
                .foregroundStyle(OnboardingTheme.heading)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(OnboardingTheme.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
