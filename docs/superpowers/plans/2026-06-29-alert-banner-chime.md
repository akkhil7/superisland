# Alert Banner Chime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play a built-in macOS chime whenever a top-of-screen alert banner is raised for a drop entering an alerting state, with a user toggle to mute it.

**Architecture:** The *decision* of when to chime is a pure function in `SuperIslandCore` (`AlertPolicy.shouldChime`), unit-tested alongside the existing `AlertPolicy` rules. The *side-effect* (playing the sound) is a thin AppKit wrapper (`AlertChime`) in the App layer. `AppController.evaluateAlerts` computes the banner action once, drives banner state through the existing switch, then calls `AlertChime.play()` when the pure decision says so. A persisted `Settings.alertSoundEnabled` (default on) gates the chime and is exposed as a toggle in the General settings pane.

**Tech Stack:** Swift 6 toolchain, Swift Package Manager. `SuperIslandCore` (pure, Swift 6 strict concurrency, no AppKit/SwiftUI). `SuperIslandApp` (executable, Swift 5 language mode, AppKit + SwiftUI). XCTest for tests.

## Global Constraints

- `SuperIslandCore` must NOT import AppKit/SwiftUI — it stays pure and testable. All `NSSound`/AppKit code lives in `SuperIslandApp` only.
- Default sound is the built-in macOS **"Glass"** system sound, played via `NSSound(named:)`.
- New setting `alertSoundEnabled` defaults to **`true`**, persisted to `UserDefaults` under key **`"alertSoundEnabled"`**.
- The chime fires only on the `.raise` banner action — never on `.refresh`, `.dismiss`, or `.leave`.
- Only one test target exists (`SuperIslandCoreTests`); there is no App test target. Do not add one. App-layer changes (Settings, AlertChime, AppController wiring) are verified by build + manual run, not unit tests.
- All code must pass the CI gates: `swift build -c release`, `swift test`, `swiftlint lint --strict`, and `swift format lint --strict --configuration .swift-format --recursive Sources Tests`.
- Follow existing code style: 4-space indentation, doc comments on public API, conventional-commit messages with scopes (e.g. `feat(core):`, `feat(app):`).

---

### Task 1: Chime decision in `AlertPolicy` (Core)

**Files:**
- Modify: `Sources/SuperIslandCore/AlertLevel.swift` (add a static func to the `AlertPolicy` enum, after `bannerAction`, before the closing brace at line 97)
- Test: `Tests/SuperIslandCoreTests/AlertLevelTests.swift` (add a test method to the existing `AlertPolicyTests` class)

**Interfaces:**
- Consumes: `AlertPolicy.BannerAction` (existing enum: `.raise`, `.refresh`, `.dismiss`, `.leave`; already `Equatable`).
- Produces: `AlertPolicy.shouldChime(action: BannerAction, soundEnabled: Bool) -> Bool` — used by `AppController.evaluateAlerts` in Task 3. Returns `true` only when `action == .raise && soundEnabled`.

- [ ] **Step 1: Write the failing test**

Add this method inside the `AlertPolicyTests` class in `Tests/SuperIslandCoreTests/AlertLevelTests.swift` (e.g. after `testShowingBannerRefreshesOnSameStatusLabelUpdate`, before the class's closing brace at line 107):

```swift
    // MARK: - shouldChime (raised banners only, gated by the sound setting)

    func testChimesOnlyOnRaiseWhenSoundEnabled() {
        XCTAssertTrue(AlertPolicy.shouldChime(action: .raise, soundEnabled: true))

        // A refresh of an already-showing banner must stay silent, or a drop
        // that keeps updating while alerting would replay the chime.
        XCTAssertFalse(AlertPolicy.shouldChime(action: .refresh, soundEnabled: true))
        XCTAssertFalse(AlertPolicy.shouldChime(action: .dismiss, soundEnabled: true))
        XCTAssertFalse(AlertPolicy.shouldChime(action: .leave, soundEnabled: true))
    }

    func testNeverChimesWhenSoundDisabled() {
        XCTAssertFalse(AlertPolicy.shouldChime(action: .raise, soundEnabled: false))
        XCTAssertFalse(AlertPolicy.shouldChime(action: .refresh, soundEnabled: false))
        XCTAssertFalse(AlertPolicy.shouldChime(action: .dismiss, soundEnabled: false))
        XCTAssertFalse(AlertPolicy.shouldChime(action: .leave, soundEnabled: false))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AlertPolicyTests`
Expected: FAIL — compile error, `type 'AlertPolicy' has no member 'shouldChime'`.

- [ ] **Step 3: Write the minimal implementation**

In `Sources/SuperIslandCore/AlertLevel.swift`, add this method to the `AlertPolicy` enum, immediately after the `bannerAction(from:to:hasBanner:)` method and before the enum's closing brace (currently line 96–97):

```swift
    /// Whether to play the alert chime for a given banner action.
    ///
    /// We chime only when a banner is newly *raised* (a fresh alerting
    /// transition) and the user has the sound enabled. A `.refresh` keeps an
    /// already-showing banner's text current while the drop stays alerting —
    /// replaying the chime there would sound repeatedly, so it stays silent.
    public static func shouldChime(action: BannerAction, soundEnabled: Bool) -> Bool {
        action == .raise && soundEnabled
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter AlertPolicyTests`
Expected: PASS — all `AlertPolicyTests` methods green, including the two new ones.

- [ ] **Step 5: Verify the full gates**

Run: `swift build && swift test`
Expected: build succeeds; all tests pass.

Run: `swift format lint --strict --configuration .swift-format --recursive Sources Tests`
Expected: no output (clean). If it reports issues, run `swift format --in-place --configuration .swift-format --recursive Sources Tests` and re-check.

- [ ] **Step 6: Commit**

```bash
git add Sources/SuperIslandCore/AlertLevel.swift Tests/SuperIslandCoreTests/AlertLevelTests.swift
git commit -m "feat(core): add AlertPolicy.shouldChime for raised banners

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `alertSoundEnabled` setting + General settings toggle (App)

**Files:**
- Modify: `Sources/SuperIslandApp/Settings.swift` (add the `@Published` property, a `Keys` entry, and an `init()` loader line)
- Modify: `Sources/SuperIslandApp/SettingsPanes.swift` (add a `Toggle` to `GeneralSettingsPane`, directly under the Alert level picker)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Settings.alertSoundEnabled: Bool` (default `true`) — read by `AppController.evaluateAlerts` in Task 3 and bound by the toggle in this task.

**Note:** No unit test — `Settings` lives in `SuperIslandApp`, which has no test target, and this is a UserDefaults mirror identical in shape to the existing settings (e.g. `codexIntegrationEnabled`). Verified by build.

- [ ] **Step 1: Add the persisted property**

In `Sources/SuperIslandApp/Settings.swift`, add this property after the `diagnosticsEnabled` block (after line 61, before the `enum Keys` declaration at line 63):

```swift

    /// Play a chime when a top-of-screen alert banner is raised (a drop enters
    /// an alerting state). Only audible at the `.notify` alert level, since that
    /// is the only level that shows banners. Default on.
    @Published var alertSoundEnabled: Bool {
        didSet { defaults.set(alertSoundEnabled, forKey: Keys.alertSoundEnabled) }
    }
```

- [ ] **Step 2: Add the UserDefaults key**

In the same file, inside `enum Keys`, add this line after `static let diagnosticsEnabled = "diagnosticsEnabled"` (line 64):

```swift
        static let alertSoundEnabled = "alertSoundEnabled"
```

- [ ] **Step 3: Load the value in `init()`**

In the same file, in `init()`, add this line after the `diagnosticsEnabled` loader (after line 86, `diagnosticsEnabled = defaults.object(forKey: Keys.diagnosticsEnabled) as? Bool ?? false`):

```swift
        alertSoundEnabled = defaults.object(forKey: Keys.alertSoundEnabled) as? Bool ?? true
```

- [ ] **Step 4: Add the toggle to the General settings pane**

In `Sources/SuperIslandApp/SettingsPanes.swift`, in `GeneralSettingsPane.body`, add this `Toggle` immediately after the Alert level `Picker` (after its closing `}` on line 170, still inside the first `Section`):

```swift
                Toggle(isOn: $settings.alertSoundEnabled) {
                    SettingsRowLabel(
                        icon: "speaker.wave.2", color: .blue,
                        title: "Play sound for alerts"
                    )
                }
```

- [ ] **Step 5: Verify the build and gates**

Run: `swift build`
Expected: build succeeds.

Run: `swift format lint --strict --configuration .swift-format --recursive Sources Tests`
Expected: clean (auto-fix with `swift format --in-place ...` if needed, then re-check).

- [ ] **Step 6: Commit**

```bash
git add Sources/SuperIslandApp/Settings.swift Sources/SuperIslandApp/SettingsPanes.swift
git commit -m "feat(app): add alertSoundEnabled setting and toggle

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `AlertChime` player + wire into `evaluateAlerts` (App)

**Files:**
- Create: `Sources/SuperIslandApp/AlertChime.swift`
- Modify: `Sources/SuperIslandApp/AppController.swift` (the `.raise` handling in `evaluateAlerts`, lines 842–862)

**Interfaces:**
- Consumes: `AlertPolicy.shouldChime(action:soundEnabled:)` (Task 1), `Settings.alertSoundEnabled` (Task 2), existing `AlertPolicy.bannerAction(from:to:hasBanner:)` and `AlertPolicy.BannerAction`.
- Produces: `AlertChime.play()` — a no-throw, no-arg side-effect that plays the chime once.

**Note:** No unit test — `NSSound` is an AppKit side-effect in the App layer (no test target). The chime *decision* is already covered by Task 1's tests. Verified by build + a manual smoke check.

- [ ] **Step 1: Create the chime player**

Create `Sources/SuperIslandApp/AlertChime.swift` with exactly this content:

```swift
import AppKit

/// Plays the alert chime that accompanies a freshly-raised banner. A thin
/// wrapper over a built-in macOS system sound so the call site stays a
/// one-liner. AppKit-only, so it lives in the App layer (never in Core).
enum AlertChime {
    /// The built-in macOS sound used for the chime. "Glass" is a short, clean
    /// tone that reads as a notification without being jarring.
    static let soundName = NSSound.Name("Glass")

    /// Play the chime once. A no-op if the named sound can't be resolved (e.g.
    /// a future macOS that drops it), so a missing sound never crashes.
    static func play() {
        NSSound(named: soundName)?.play()
    }
}
```

- [ ] **Step 2: Wire the chime into `evaluateAlerts`**

In `Sources/SuperIslandApp/AppController.swift`, replace the existing block (lines 842–862):

```swift
            let hasBanner = alertBanners.contains { $0.id == drop.id }
            switch AlertPolicy.bannerAction(from: previous, to: drop.status, hasBanner: hasBanner) {
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
```

with this version (computes the action once, then chimes after driving banner state):

```swift
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
```

- [ ] **Step 3: Verify the build and full gates**

Run: `swift build -c release && swift test`
Expected: build succeeds; all tests pass.

Run: `swift format lint --strict --configuration .swift-format --recursive Sources Tests`
Expected: clean (auto-fix with `swift format --in-place ...` if needed, then re-check).

Run (if SwiftLint is installed locally; otherwise rely on CI): `swiftlint lint --strict --quiet`
Expected: no violations.

- [ ] **Step 4: Manual smoke check**

Build and run the app, sign in, and set Settings → General → Alert level to **Notifications** (`.notify`) with **Play sound for alerts** ON. Drive a drop into an alerting state (e.g. a tracked agent finishing / needing attention) and confirm:
- A banner appears AND the "Glass" chime plays once on raise.
- While the banner stays up and only its text updates, no repeated chime.
- Toggling **Play sound for alerts** OFF and re-triggering a raise: banner appears, no chime.

(If manual run isn't possible in the execution environment, note it as skipped — do not claim it passed.)

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandApp/AlertChime.swift Sources/SuperIslandApp/AppController.swift
git commit -m "feat(app): chime when an alert banner is raised

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes / Known behavior

- If multiple drops raise banners within a single `evaluateAlerts` pass, the chime plays once per raised drop. In practice transitions arrive one event at a time, so this is rare; no debounce is added (YAGNI). Revisit only if overlapping chimes become a real annoyance.
- The chime is inherently gated to the `.notify` alert level: `evaluateAlerts` returns early when `settings.alertLevel.showsBanner` is false, so the `.raise` path (and thus the chime) is never reached at lower levels.
