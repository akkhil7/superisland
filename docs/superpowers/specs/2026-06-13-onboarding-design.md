# Klip Onboarding Journey — Design

Date: 2026-06-13
Status: approved by Akhil (chat), pending spec review

## Purpose

Klip currently has no first-run experience: the app lands in the menu bar, the
hotkey beeps without Accessibility, and the integrations that make Klip
magical (shell, Claude Desktop, Codex, Chrome) hide in Settings. The
onboarding journey introduces the product story, secures the one required
permission, and walks every integration to "live" — in a window that looks
and feels like the useklip.com landing page: premium, dark, purple.

## Visual system (from `website/index.html`)

| Token | Value |
| --- | --- |
| Background | `#050409` (near-black), subtle starfield dots, radial purple aurora glow |
| Primary purple | `#7b39fc` → `#8d53ff` gradient (CTAs), glow `rgba(123,57,252,0.4)` |
| Lavender accent | `#ae9ae6`; near-white `#fdf9ff` for headings |
| Glass cards | white 2–5% fills, 1px `rgba(255,255,255,0.08)` borders, 12–16pt radius |
| Status chips | capsule, colored dot + JetBrains-Mono-style label (SF Mono fallback) |
| Type | Inter ≈ system SF for UI; **Instrument Serif Italic** for accent words (bundled TTF, OFL license; fallback New York italic via `.fontDesign(.serif)`); SF Mono for chips/keycaps |
| Buttons | pill, purple gradient + outer glow for primary; ghost (white 6%) for secondary |
| Art | `website/assets/mascot.webp` and `hero-aurora.webp` copied into app Resources |

## The journey — 8 steps

Window: borderless, rounded 16pt, ~760×560, centered, draggable by
background, Esc closes. Dot-progress rail at the bottom with Back/Continue;
every step skippable.

1. **Welcome** — aurora + mascot, "Never babysit a *window* again" (serif
   italic on "window"), subline, primary pill **Begin**.
2. **The Klip way** — four glass rows, copy mirroring the landing page:
   Shells tell Klip when commands finish · Chrome tells Klip which tab
   matters · Agents report themselves · AI covers everything else.
3. **Accessibility** (required) — explanation, live status chip (2s poll via
   the existing `PermissionsManager`), **Grant Access** button
   (`requestAccessibility` + open System Settings), stale-grant reset (⟲)
   beneath. Continue remains enabled; copy states Klip can't work without it.
4. **Terminal** — one-click **Set Up Shell Integration**
   (`ShellIntegration.install`), live "N sessions connected" chip, note to
   restart open terminals.
5. **Claude Desktop** — one-click **Set Up Claude Hooks**
   (`ClaudeIntegration.install`), note: applies to sessions started after.
6. **Codex** — celebration beat: zero setup, already live (rollout
   watching). Shows real detected thread count from `CodexIntegration`'s
   session index.
7. **Chrome** — one-click native host install
   (`ChromeIntegration.setUp`), then load-unpacked guidance with
   **Open Chrome Extensions** / **Reveal Folder** / **Check Again**, live
   "Extension loaded" chip (profile scan).
8. **Drop your first klip** — large keycap rendering of the current hotkey
   (live from `Settings.hotkeyKeyCode/Modifiers`), **Finish** dissolves the
   window and the notch island pulses once as a welcome.

## Behavior

- Shown automatically when `hasCompletedOnboarding` (UserDefaults) is false;
  the flag is set on Finish *and* on close (no nagging).
- Re-openable any time: menu-bar dropdown item "Welcome Tour…" and a button
  in Settings → About.
- Integration steps read/refresh the existing managers — live state, no
  duplicated logic. Errors from install calls render inline in the step
  (same red-caption pattern as Settings).
- The window is an ordinary key window (activates the app while open),
  released on close.

## Architecture

```
Sources/KlipApp/Onboarding/
  OnboardingTheme.swift   // colors, fonts (CTFontManager registration),
                          // chip/pill/card/keycap components, starfield+aurora
  OnboardingWindow.swift  // NSWindow controller, show/close, first-run logic
  OnboardingView.swift    // pager, progress rail, 8 step views
```

- `OnboardingSteps` enum drives ordering/titles; step views take the
  environment objects already provided by `AppController` (permissions,
  settings, shell/claude/chrome/codex integrations).
- `Scripts/build-app.sh` additionally copies `website/assets/mascot.webp`,
  `website/assets/hero-aurora.webp`, and the two Instrument Serif TTFs into
  `Klip.app/Contents/Resources/Onboarding/`.
- Fonts are downloaded once into `Resources/Fonts/` in the repo (not at build
  time); if absent, the UI silently uses New York italic.

## Error handling

- Install failures: inline red caption on the step, journey continues.
- Missing art/fonts: steps render with gradients/system fonts — no crashes,
  no blank panes.
- Permission never granted: Finish still works; the menu bar continues to
  surface the permission warning as today.

## Testing

- Unit: `OnboardingStepsTests` — step order, titles, and the
  first-run/completed-flag decision (`shouldShowOnFirstLaunch(defaults:)`).
- Manual: first-launch flow on a cleared flag; every Set Up button against
  live integrations; reopen from menu; Esc-close sets the flag.

## Out of scope

- API key entry (Keychain-managed, distribution handled externally).
- Animated 3D mascot, confetti physics, video walkthroughs.
- Localization (English only for now).
