# SuperIsland Onboarding Journey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A premium, landing-page-themed 8-step onboarding window (welcome → story → Accessibility → Terminal → Claude → Codex → Chrome → first superisland) shown on first launch and re-openable from the menu bar and Settings.

**Architecture:** A SuperIslandCore `OnboardingStep`/`OnboardingFlow` enum is the testable source of truth for ordering and the first-run gate. The app target gets `Sources/SuperIslandApp/Onboarding/` with a theme file (colors/fonts/components lifted from `website/index.html`), a pager view whose steps read the existing `PermissionsManager`/`ShellIntegration`/`ClaudeIntegration`/`ChromeIntegration`/`CodexIntegration` objects for live state, and a borderless `NSWindow` controller gated by a UserDefaults flag.

**Tech Stack:** Swift 5/6, SwiftUI + AppKit, XCTest, CoreText (font registration). Spec: `docs/superpowers/specs/2026-06-13-onboarding-design.md`.

---

### Task 1: OnboardingStep + OnboardingFlow in SuperIslandCore (TDD)

**Files:**
- Create: `Sources/SuperIslandCore/OnboardingFlow.swift`
- Test: `Tests/SuperIslandCoreTests/OnboardingFlowTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SuperIslandCore

final class OnboardingFlowTests: XCTestCase {
    func testStepOrderMatchesTheJourney() {
        XCTAssertEqual(OnboardingStep.allCases, [
            .welcome, .story, .accessibility, .terminal, .claude, .codex, .chrome, .finish,
        ])
    }

    func testEveryStepHasATitle() {
        for step in OnboardingStep.allCases {
            XCTAssertFalse(step.title.isEmpty, "missing title for \(step)")
        }
    }

    func testFirstRunGate() {
        XCTAssertTrue(OnboardingFlow.shouldShowOnLaunch(hasCompleted: false))
        XCTAssertFalse(OnboardingFlow.shouldShowOnLaunch(hasCompleted: true))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OnboardingFlowTests 2>&1 | tail -5`
Expected: compile error — `OnboardingStep` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Ordered steps of the first-run journey. The UI lives in the app target;
/// this enum is the testable source of truth for order and titles.
public enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome, story, accessibility, terminal, claude, codex, chrome, finish

    public var title: String {
        switch self {
        case .welcome: return "Welcome to SuperIsland"
        case .story: return "The SuperIsland way"
        case .accessibility: return "Accessibility"
        case .terminal: return "Terminal"
        case .claude: return "Claude Desktop"
        case .codex: return "Codex"
        case .chrome: return "Chrome"
        case .finish: return "Drop your first superisland"
        }
    }
}

public enum OnboardingFlow {
    /// UserDefaults key for the completed flag.
    public static let completedDefaultsKey = "hasCompletedOnboarding"

    public static func shouldShowOnLaunch(hasCompleted: Bool) -> Bool {
        !hasCompleted
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OnboardingFlowTests 2>&1 | tail -3`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandCore/OnboardingFlow.swift Tests/SuperIslandCoreTests/OnboardingFlowTests.swift
git commit -m "feat: onboarding step order and first-run gate in SuperIslandCore"
```

### Task 2: Brand fonts + art assets into the bundle

**Files:**
- Create: `Resources/Fonts/InstrumentSerif-Regular.ttf`, `Resources/Fonts/InstrumentSerif-Italic.ttf` (downloaded once, committed)
- Modify: `Scripts/build-app.sh` (after the ChromeExtension copy block)

- [ ] **Step 1: Download the OFL-licensed fonts into the repo**

```bash
mkdir -p Resources/Fonts
curl -fsSL -o Resources/Fonts/InstrumentSerif-Regular.ttf \
  "https://github.com/google/fonts/raw/main/ofl/instrumentserif/InstrumentSerif-Regular.ttf"
curl -fsSL -o Resources/Fonts/InstrumentSerif-Italic.ttf \
  "https://github.com/google/fonts/raw/main/ofl/instrumentserif/InstrumentSerif-Italic.ttf"
file Resources/Fonts/*.ttf   # expect: TrueType Font data
```

If the download fails (offline), delete `Resources/Fonts` and continue — the
theme falls back to New York serif italic automatically.

- [ ] **Step 2: Copy fonts + website art into the app bundle**

In `Scripts/build-app.sh`, after the `ChromeExtension` copy block, add:

```bash
# Onboarding art + brand fonts (fall back gracefully when absent).
mkdir -p "$RES/Onboarding"
for f in "$ROOT/website/assets/mascot.webp" "$ROOT/website/assets/hero-aurora.webp" \
         "$ROOT/Resources/Fonts/InstrumentSerif-Regular.ttf" \
         "$ROOT/Resources/Fonts/InstrumentSerif-Italic.ttf"; do
    [ -f "$f" ] && cp "$f" "$RES/Onboarding/"
done
```

- [ ] **Step 3: Verify the bundle picks them up**

Run: `./Scripts/build-app.sh debug >/dev/null && ls .build/SuperIsland.app/Contents/Resources/Onboarding/`
Expected: `InstrumentSerif-Italic.ttf InstrumentSerif-Regular.ttf hero-aurora.webp mascot.webp`

- [ ] **Step 4: Commit**

```bash
git add Resources/Fonts Scripts/build-app.sh
git commit -m "feat: bundle Instrument Serif fonts and onboarding art"
```

### Task 3: OnboardingTheme — colors, fonts, components

**Files:**
- Create: `Sources/SuperIslandApp/Onboarding/OnboardingTheme.swift`

- [ ] **Step 1: Write the theme file**

Tokens come from `website/index.html`: bg `#050409`, purple `#7b39fc`,
purple-light `#8d53ff`, lavender `#ae9ae6`, heading `#fdf9ff`, glass white
2–8%, CTA glow `rgba(123,57,252,0.4)`.

```swift
import SwiftUI
import AppKit
import CoreText

/// Visual system for the onboarding window, lifted from the landing page.
enum OnboardingTheme {
    // MARK: Palette (website/index.html)
    static let bg = Color(red: 0x05 / 255, green: 0x04 / 255, blue: 0x09 / 255)
    static let purple = Color(red: 0x7B / 255, green: 0x39 / 255, blue: 0xFC / 255)
    static let purpleLight = Color(red: 0x8D / 255, green: 0x53 / 255, blue: 0xFF / 255)
    static let lavender = Color(red: 0xAE / 255, green: 0x9A / 255, blue: 0xE6 / 255)
    static let heading = Color(red: 0xFD / 255, green: 0xF9 / 255, blue: 0xFF / 255)
    static let body = Color.white.opacity(0.55)
    static let glow = purple.opacity(0.4)

    // MARK: Fonts
    private static var fontsRegistered = false

    /// Register the bundled Instrument Serif faces (no-op when absent).
    static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        for name in ["InstrumentSerif-Regular.ttf", "InstrumentSerif-Italic.ttf"] {
            guard let url = resourceURL(name) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Serif italic accent ("a window again") — Instrument Serif when bundled,
    /// New York italic otherwise.
    static func serifAccent(_ size: CGFloat) -> Font {
        registerFonts()
        if NSFont(name: "Instrument Serif", size: size) != nil {
            return .custom("Instrument Serif", size: size).italic()
        }
        return .system(size: size, design: .serif).italic()
    }

    // MARK: Resources
    static func resourceURL(_ name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("Onboarding/\(name)"),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    static func art(_ name: String) -> NSImage? {
        resourceURL(name).flatMap { NSImage(contentsOf: $0) }
    }
}

// MARK: - Background (starfield + aurora)

struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            OnboardingTheme.bg
            // Aurora: the website asset when bundled, else radial gradients.
            if let aurora = OnboardingTheme.art("hero-aurora.webp") {
                Image(nsImage: aurora)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.55)
                    .blur(radius: 18)
            } else {
                RadialGradient(
                    colors: [OnboardingTheme.purple.opacity(0.38), .clear],
                    center: .init(x: 0.5, y: 0.1), startRadius: 10, endRadius: 420
                )
                RadialGradient(
                    colors: [OnboardingTheme.lavender.opacity(0.12), .clear],
                    center: .init(x: 0.85, y: 0.9), startRadius: 10, endRadius: 380
                )
            }
            Starfield()
        }
        .ignoresSafeArea()
    }
}

/// Deterministic starfield (seeded LCG — no randomness at render time).
private struct Starfield: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x5EED
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max)
            }
            for _ in 0..<110 {
                let x = next() * size.width
                let y = next() * size.height
                let r = 0.4 + next() * 1.0
                let alpha = 0.10 + next() * 0.35
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                    with: .color(.white.opacity(alpha))
                )
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Buttons

/// Primary CTA: purple gradient pill with outer glow.
struct GlowPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [OnboardingTheme.purple, OnboardingTheme.purpleLight],
                    startPoint: .leading, endPoint: .trailing
                ))
            )
            .shadow(color: OnboardingTheme.glow, radius: 14, y: 2)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Secondary: ghost pill.
struct GhostPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(0.06)))
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Cards, chips, keycaps

struct OnboardingGlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Monospace status chip with a colored dot (landing-page style).
struct OnboardingChip: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: 3)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.05)))
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }
}

struct Keycap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 26, weight: .semibold, design: .monospaced))
            .foregroundStyle(OnboardingTheme.heading)
            .frame(minWidth: 54, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(OnboardingTheme.lavender.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: OnboardingTheme.glow, radius: 10, y: 2)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/SuperIslandApp/Onboarding/OnboardingTheme.swift
git commit -m "feat: onboarding visual system from landing-page tokens"
```

### Task 4: Hotkey keycap tokens helper (TDD-ish, app target)

**Files:**
- Modify: `Sources/SuperIslandApp/Views.swift` — change `private func keyCodeName(` to `func keyCodeName(` (the onboarding finale renders the live shortcut)

- [ ] **Step 1: Make `keyCodeName` internal**

In `Sources/SuperIslandApp/Views.swift` find `private func keyCodeName(_ code: Int) -> String` and remove `private`. (`hotkeyLabel` stays private — onboarding renders separate keycaps, not the joined string.)

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | grep -E "error|Build complete"
git add Sources/SuperIslandApp/Views.swift
git commit -m "refactor: expose keyCodeName for onboarding keycaps"
```

### Task 5: OnboardingView — pager + 8 steps

**Files:**
- Create: `Sources/SuperIslandApp/Onboarding/OnboardingView.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI
import AppKit
import Carbon.HIToolbox
import SuperIslandCore

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
                Button("Back") { withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { index -= 1 } }
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
            Text("SuperIsland bookmarks your long-running work — builds, deploys, Claude, Codex — and pulls you back to the exact window or tab the moment it needs you.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingTheme.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 2 · The SuperIsland way

private struct StoryStepView: View {
    private let rows: [(icon: String, title: String, detail: String)] = [
        ("terminal.fill", "Shells tell SuperIsland when commands finish",
         "A zsh/bash hook reports start and exit — status flips in milliseconds, with the exit code."),
        ("globe", "Chrome tells SuperIsland which tab matters",
         "A lightweight extension tracks tab identity and page signals — even in background tabs."),
        ("sparkle", "Agents report themselves",
         "Claude Code hooks and Codex session journals stream ground truth: working, needs approval, done."),
        ("brain.head.profile", "AI covers everything else",
         "For apps with no signal, Claude classifies the window — and only when content actually settles."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "The SuperIsland way",
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
                title: Text("SuperIsland needs ")
                    + Text("Accessibility").font(OnboardingTheme.serifAccent(31)),
                subtitle: "It's how SuperIsland reads window text and raises the exact window when you click a superisland. Without it, nothing works — this is the only required permission."
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
                    Label("Toggle is ON but SuperIsland still shows “not granted”? Reset & re-prompt.",
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
                subtitle: "One hook in zsh and bash tells SuperIsland the instant any command finishes — in Terminal, iTerm2, Warp, anywhere. Exit 0 → done. Anything else → needs you."
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
                subtitle: "Claude Code hooks stream session events straight to SuperIsland: working, finished, needs your input — even for background tabs, with zero AI calls."
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
                subtitle: "Nothing to set up. SuperIsland reads Codex's own session journals — thread names, working / finished / needs-approval, and Codex's last message — and deep-links you back to the exact thread."
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
                        Text("Prompt a thread, then superisland it — that's the whole gesture.")
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
                subtitle: "The SuperIsland extension tracks the exact tab — identity, page signals, background or not — far beyond what screenshots can see."
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
                        Text("Connected. Chrome superislands now track their exact tab, even in the background.")
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
                + Text("first superisland").font(OnboardingTheme.serifAccent(36)))
                .foregroundStyle(OnboardingTheme.heading)
            HStack(spacing: 10) {
                ForEach(keycaps, id: \.self) { Keycap(symbol: $0) }
            }
            Text("Focus any window with work in progress and press the shortcut. The island by the notch keeps watch — click a superisland there to jump straight back.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingTheme.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity)
    }
}
```

- [ ] **Step 2: Add `knownThreadCount` to CodexIntegration**

In `Sources/SuperIslandApp/CodexIntegration.swift`, after `func threadTitle(forID:)`:

```swift
    /// Number of threads in Codex's session index (shown during onboarding).
    var knownThreadCount: Int { sessionIndex().count }
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/SuperIslandApp/Onboarding/OnboardingView.swift Sources/SuperIslandApp/CodexIntegration.swift
git commit -m "feat: onboarding pager with 8 live-state steps"
```

### Task 6: OnboardingWindow controller + first-run gate

**Files:**
- Create: `Sources/SuperIslandApp/Onboarding/OnboardingWindow.swift`

- [ ] **Step 1: Write the window controller**

```swift
import AppKit
import SwiftUI
import SuperIslandCore

/// Borderless rounded window: Esc closes, background drags. Borderless
/// windows refuse key status by default — override, or buttons won't click.
final class OnboardingPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: OnboardingPanel?
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    /// First launch only (UserDefaults flag).
    func showIfNeeded() {
        let completed = UserDefaults.standard.bool(forKey: OnboardingFlow.completedDefaultsKey)
        guard OnboardingFlow.shouldShowOnLaunch(hasCompleted: completed) else { return }
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = OnboardingView(onFinish: { [weak self] in self?.finish() })
            .environmentObject(controller)
            .environmentObject(controller.permissions)
            .environmentObject(controller.settings)
            .environmentObject(controller.shellIntegration)
            .environmentObject(controller.claudeIntegration)
            .environmentObject(controller.chromeIntegration)
            .environmentObject(controller.codexIntegration)

        let hosting = NSHostingView(rootView: AnyView(
            root.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        ))

        let panel = OnboardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }

    private func finish() {
        markCompleted()
        window?.close()
        controller.welcomePulse()
    }

    func windowWillClose(_ notification: Notification) {
        markCompleted()   // closing = done; no nagging on next launch
        window = nil
    }

    private func markCompleted() {
        UserDefaults.standard.set(true, forKey: OnboardingFlow.completedDefaultsKey)
    }
}
```

- [ ] **Step 2: Add `welcomePulse()` + reopen hook to AppController**

In `Sources/SuperIslandApp/AppController.swift`, after `func dismiss(_:)`:

```swift
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
```

(`AppController.swift` needs `import SwiftUI` for `withAnimation` — add it to the imports if not present.)

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/SuperIslandApp/Onboarding/OnboardingWindow.swift Sources/SuperIslandApp/AppController.swift
git commit -m "feat: onboarding window with first-run gate and welcome pulse"
```

### Task 7: Wire entry points (launch, menu bar, About pane)

**Files:**
- Modify: `Sources/SuperIslandApp/SuperIslandApp.swift` (AppDelegate)
- Modify: `Sources/SuperIslandApp/Views.swift` (MenuBarContent)
- Modify: `Sources/SuperIslandApp/SettingsPanes.swift` (AboutSettingsPane)

- [ ] **Step 1: Show on first launch (AppDelegate)**

In `Sources/SuperIslandApp/SuperIslandApp.swift`, add a property to `AppDelegate`:

```swift
    private var onboarding: OnboardingWindowController?
```

In `applicationDidFinishLaunching`, after `island.show()` / `self.island = island`:

```swift
        let onboarding = OnboardingWindowController(controller: controller)
        controller.showOnboardingRequested = { [weak onboarding] in onboarding?.show() }
        onboarding.showIfNeeded()
        self.onboarding = onboarding
```

- [ ] **Step 2: Menu bar item**

In `Sources/SuperIslandApp/Views.swift` `MenuBarContent`, in the bottom `HStack` next to `OpenSettingsButton()`:

```swift
                Button("Welcome Tour…") { controller.showOnboarding() }
```

- [ ] **Step 3: About pane button**

In `Sources/SuperIslandApp/SettingsPanes.swift` `AboutSettingsPane`: add
`@EnvironmentObject var controller: AppController` at the top of the struct,
and below the `Link("Send Feedback", …)` line:

```swift
            Button("Replay Welcome Tour") { controller.showOnboarding() }
                .font(.caption)
```

- [ ] **Step 4: Build + full test suite**

```bash
swift build 2>&1 | grep -E "error|Build complete"
swift test 2>&1 | grep -E "Executed .* tests" | tail -1
```
Expected: build clean; all tests pass (68 existing + 3 new = 71).

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandApp/SuperIslandApp.swift Sources/SuperIslandApp/Views.swift Sources/SuperIslandApp/SettingsPanes.swift
git commit -m "feat: onboarding entry points — first launch, menu bar, About"
```

### Task 8: Bundle, manual verification

**Files:** none (verification)

- [ ] **Step 1: Rebuild the bundle and reset the flag**

```bash
./Scripts/build-app.sh debug
defaults delete com.superisland.SuperIsland hasCompletedOnboarding 2>/dev/null
pkill -f "MacOS/SuperIsland$"; sleep 1
open .build/SuperIsland.app
```

- [ ] **Step 2: Manual checklist (user-visible)**

- Window appears centered on launch: dark, starfield, aurora glow, mascot.
- Serif italic renders on accent words (Instrument Serif).
- Step 3 chip flips to "granted" within ~2s of granting Accessibility.
- Steps 4/5 Set Up buttons flip to chips; step 6 shows real thread count;
  step 7 walks Chrome states.
- Finish closes the window and the island pulses open/closed.
- Relaunching the app does NOT show the window again.
- Menu bar "Welcome Tour…" and Settings → About → "Replay Welcome Tour" reopen it.

- [ ] **Step 3: Commit any fixes found during verification**

```bash
git add -A && git commit -m "fix: onboarding polish from manual verification"
```

---

## Self-review notes

- Spec coverage: 8 steps ✓, theme tokens ✓, fonts+art bundling (Task 2) ✓,
  first-run flag + close-sets-flag (Task 6) ✓, reopen entry points (Task 7) ✓,
  inline install errors (step views) ✓, island pulse (Task 6) ✓, tests (Task 1) ✓.
- Type consistency: `OnboardingFlow.completedDefaultsKey` used in Task 6;
  `knownThreadCount` defined in Task 5 step 2 and used in Task 5 step 1;
  `keyCodeName` exposure (Task 4) used by `FinishStepView` (Task 5);
  `showOnboardingRequested`/`showOnboarding()`/`welcomePulse()` defined in
  Task 6 and used in Task 7.
- Carbon modifier constants (`optionKey` etc.) come via
  `import Carbon.HIToolbox`, already used elsewhere in the app target.
