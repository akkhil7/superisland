# Klip

A macOS menu-bar app that lets you "drop a klip" on the window you're working
in, watches it in the background, and takes you straight back to the **exact**
window or browser tab when its state changes — done, or waiting for your input.

Built for the era of long-running automated tasks: kick something off (a build,
a deploy, an AI agent in a Chrome tab), move on, and let Klip tell you — via the
notch island — which window now needs you.

## How it works

- **Drop a klip** on the frontmost window via the global hotkey **⌥⌘K**, the
  `+` button on the notch island / menu bar, or right-click → **Services → Drop Klip**.
- Klip watches the window with a **change-then-settle** strategy: it cheaply
  polls the window's Accessibility text and only spends an evaluation when the
  content goes busy → quiet (or on a long fallback timer).
- An **on-device prefilter** (keyword/prompt heuristics + Vision OCR) decides
  whether a moment is worth a cloud call; if so, **Claude** classifies the state
  as *working / needs-attention / done* from the text (+ a screenshot).
- The notch **island** chip recolors and pulses on a status change. Click it to
  **refocus the exact window/tab** — generic windows via Accessibility, and the
  exact Chrome tab / Terminal window via app adapters.

## Architecture

- `Sources/KlipCore` — pure, unit-tested logic: domain model, `KlipStore`
  (JSON persistence), `ChangeDetector`, `Prefilter`, `Classifier`
  (request build + response parse).
- `Sources/KlipApp` — the menu-bar agent: Accessibility/window finding, capture
  (ScreenCaptureKit + Vision), app adapters + refocus, the monitoring pipeline,
  notch island, menu bar, settings, global hotkey, Services provider.

## Build & run

```sh
swift test                 # run the KlipCore unit tests
./Scripts/build-app.sh     # build & assemble .build/Klip.app (ad-hoc signed)
open .build/Klip.app
```

Klip runs as a menu-bar agent (no Dock icon).

### Permissions (first run)

Grant these in **System Settings → Privacy & Security** (Settings… in Klip's
menu has buttons and deep links):

- **Accessibility** — read window text and refocus exact windows.
- **Screen Recording** — capture window screenshots for the classifier.
- **Automation** — control Chrome/Terminal to refocus the exact tab/window.

### Claude API key

Open **Settings…** from the menu bar and paste your Anthropic API key (stored in
the Keychain). Pick a model — default `claude-opus-4-8`; `claude-haiku-4-5` is a
cheaper/faster option for frequent checks. Without a key, Klip still updates
status using the on-device heuristics (with reduced accuracy).

## Status

MVP. Deep refocus adapters: generic (any app), Google Chrome, Terminal. Planned:
more adapters (iTerm2, Safari, VS Code), app self-navigation, per-klip custom
checks.
