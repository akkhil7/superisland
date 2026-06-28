# Alert Banner Chime — Design

**Date:** 2026-06-29
**Status:** Approved

## Goal

Play a chime sound whenever SuperIsland shows a notification — specifically, when a
top-of-screen **alert banner** is raised for a drop entering an alerting state.

## Scope

- **In scope:** A chime on alert-banner *raise*, a user setting to toggle it, a built-in
  macOS sound source, and tests for the trigger logic.
- **Out of scope:** Chimes for transient toast pills (they keep their current
  `NSSound.beep()` behavior on errors), bundled custom audio assets, per-sound pickers,
  and volume controls.

## Behavior

- When `AppController.evaluateAlerts(_:)` decides to **raise** a banner (a drop newly
  enters an alerting state — `.needsAttention` / `.done`), play the chime.
- The chime fires **only on the `.raise` path**, never on `.refresh`. A `.refresh` only
  updates the text of an already-visible banner; replaying the sound there would chime
  repeatedly while a drop keeps updating in its alerting state. "Showing a notification"
  means a *new* banner appearing.
- No additional alert-level gating is required. `evaluateAlerts` already returns early
  when `settings.alertLevel.showsBanner` is false, so `.raise` only occurs at the
  `.notify` level. The chime inherits that gating automatically.
- The chime is suppressed when the user setting `alertSoundEnabled` is off.

## Sound source

- Use a built-in macOS system sound via `NSSound(named:)`.
- Default sound: **"Glass"** — a clean, pleasant chime.
- No bundled asset and no SPM resource wiring required.

## Setting

- New persisted preference `Settings.alertSoundEnabled: Bool`, default **ON**.
- Backed by `UserDefaults` key `"alertSoundEnabled"`, following the existing
  `@Published` + `didSet` pattern in `Settings.swift` (and a matching entry in
  `Settings.Keys` and the `init()` loader).
- New `Toggle` in `GeneralSettingsPane`, placed directly under the **Alert level**
  picker. Icon `speaker.wave.2`, title "Play sound for alerts".

## Code structure

To keep the trigger logic testable without audio hardware:

- Introduce a `SoundPlaying` protocol with a single method `playChime()`.
- Provide a default `SystemSoundPlayer` implementation that calls
  `NSSound(named: NSSound.Name("Glass"))?.play()`.
- `AppController` holds a `SoundPlaying` dependency, defaulting to `SystemSoundPlayer()`,
  so tests can inject a spy that records calls.
- In `evaluateAlerts`, the `.raise` case becomes:

  ```swift
  case .raise:
      upsertBanner(for: drop)
      if settings.alertSoundEnabled { soundPlayer.playChime() }
  ```

### Affected files

- `Sources/SuperIslandApp/Settings.swift` — add `alertSoundEnabled` property, key, and
  init loader.
- `Sources/SuperIslandApp/SettingsPanes.swift` — add the toggle to `GeneralSettingsPane`.
- `Sources/SuperIslandApp/AppController.swift` — add the `SoundPlaying` dependency and the
  `.raise` chime call.
- New file (App layer) — `SoundPlaying` protocol + `SystemSoundPlayer` (AppKit `NSSound`
  lives in the App layer, not Core).
- Tests — cover the chime trigger logic.

## Testing

- Chime **fires once** on a `.raise` transition when `alertSoundEnabled` is true.
- Chime **does not fire** on a `.refresh` transition.
- Chime **does not fire** when `alertSoundEnabled` is false.
- Fallback: if wiring a spy `SoundPlaying` through `AppController`'s initializer proves
  heavy, extract the trivial decision (`action == .raise && soundEnabled`) as a pure
  helper and unit-test that directly, alongside the existing `AlertPolicy` tests.
