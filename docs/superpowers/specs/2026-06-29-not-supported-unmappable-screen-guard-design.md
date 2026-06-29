# "Not supported" guard for unmappable screens

**Date:** 2026-06-29
**Status:** Approved design — ready for implementation plan

## Summary

Refuse a drop, with a `Not supported` toast, whenever the screen showing at
drop time carries no tab/session identity to track — even when the front app is
otherwise supported and its integration is installed. This closes the gap where
dropping on an in-app Settings pane (or any non-task screen) silently creates a
"dead" chip that never tracks anything.

The guard is a single pure predicate evaluated at the one chokepoint every
integration passes through, so it applies to **all** integrations — including
every Chrome surface — by construction.

## Background: the three gates

Every drop flows through one function, `AppController.createDrop()`
(`Sources/SuperIslandApp/AppController.swift:1018`). It already has two
rejection gates:

1. **Unsupported app** — `SupportedApps.isSupported(bundleID:)`
   (`AppController.swift:1032`). Apps with no adapter (macOS Settings.app,
   Finder, arbitrary native apps) are refused with
   "SuperIsland doesn't support X".
2. **Integration not set up** — `missingIntegration(for:)`
   (`AppController.swift:1041`). A supported app whose integration backend isn't
   installed/enabled is refused with a setup-pointing toast.

This spec adds the missing **third gate**: the app *is* supported and the
integration *is* set up, but the **specific screen** can't be mapped to a tab or
session. Today (`AppController.swift:1050`–`1128`) those drops are created
anyway and become permanently frozen or AI-misclassified chips — never an error.

## Requirements (from the user)

- Block the drop entirely (create nothing) and show the literal string
  `Not supported`, with a beep — matching the existing reject paths.
- Enforcement is **reactive, at drop time** (no proactive notch-disabling in
  this iteration).
- Applies to **all** integrations and **all** Chrome integrations.
- **Chrome:** treat internal/empty pages (`chrome://*`, `about:`, `data:`,
  `view-source:`, the new-tab page) as not supported even though they carry a
  tab id.
- **Codex/Cursor:** block only when **no** session resolves (the recency guess
  returns nil); a resolved guess is allowed (unchanged binding behavior).

## Architecture

### The chokepoint

`createDrop()` is the single entry point for every integration's drop. By the
time control reaches `AppController.swift:1093`, both signals that prove a
successful mapping are known:

- the `Locator` returned by the app's adapter (`captureLocator`), and
- the resolved `contentURL` (set in the per-bundle branches for Claude Desktop,
  Codex, Cursor, and generic Electron windows).

So the guard needs no new data collection — it inspects values already computed.

### The predicate

Add a pure, dependency-free type to Core (mirroring `SupportedApps`, which is
"pure and dependency-free so it can be unit-tested without AppKit"):

```swift
// Sources/SuperIslandCore/TargetMappability.swift
public enum TargetMappability {
    /// Whether the resolved drop target carries a tab/session identity we can
    /// actually track. Exhaustive over `Locator` on purpose: a new locator case
    /// won't compile until it declares its rule here.
    public static func canMap(locator: Locator, contentURL: String?) -> Bool {
        switch locator {
        case let .chrome(_, _, _, _, url, _, _, _):
            return isTrackableWebURL(url)
        case .shell:
            return true                          // a TTY was captured
        case let .terminal(_, _, tty):
            return tty != nil
        case .iterm:
            return false                         // no TTY ⇒ can't receive shell events
        case let .editor(filePath, fileName, workspaceName):
            return filePath != nil || fileName != nil || workspaceName != nil
        case .generic:
            return contentURL != nil             // Claude/Codex/Cursor/Electron session
        }
    }

    /// http/https only. Blocks chrome://, about:, data:, view-source:,
    /// chrome-extension:, the new-tab page, and empty/nil URLs.
    static func isTrackableWebURL(_ urlString: String?) -> Bool {
        guard let urlString, !urlString.isEmpty,
              let scheme = URL(string: urlString)?.scheme?.lowercased()
        else { return false }
        return scheme == "http" || scheme == "https"
    }
}
```

Rationale for the exhaustive switch: it turns "applies to ALL integrations" into
a compile-time guarantee. The gap being fixed arose because per-app binding had
no shared check; a single switch the compiler forces every future `Locator` case
to satisfy prevents the same drift.

### Why the rule is locator-based

The supported set maps cleanly onto adapters/locators:

| App(s) | Adapter | Locator | Identity that proves a mapping |
|---|---|---|---|
| Chrome, Chrome Canary, Brave | `ChromeAdapter` | `.chrome` | `url` (http/https) / tab id |
| Terminal | `TerminalAdapter` | `.shell` (TTY) or `.terminal` (no TTY) | TTY |
| iTerm | `ITermAdapter` | `.shell` (TTY) or `.iterm` (no TTY) | TTY |
| VS Code | `EditorAdapter` | `.shell` (integrated terminal) or `.editor` (file) | TTY or file/workspace |
| Claude Desktop, Codex, Cursor | `GenericAXAdapter` | `.generic` | `contentURL` (the SPA route / session URL) |

Cursor was verified to use `GenericAXAdapter`, **not** `EditorAdapter`: its
bundle id `com.todesktop.230313mzl4w4u92` is not in
`EditorApp.bundleIDs = {vsCode, vsCodeInsiders, vsCodium}`
(`Sources/SuperIslandCore/AgentTerminalSupport.swift:210`). So Claude, Codex, and
Cursor all bind their session through `contentURL`, and the single
`.generic ⇒ contentURL != nil` rule covers all three.

### Call site

In `createDrop()`, immediately after the per-bundle `contentURL` binding
(after `AppController.swift:1093`) and **before** the duplicate-target check
(`AppController.swift:1103`):

```swift
guard TargetMappability.canMap(locator: locator, contentURL: contentURL) else {
    showToast("Not supported")
    NSSound.beep()
    return false
}
```

Placing it before the duplicate check means we never compare an unmappable
target against existing drops.

## Per-integration behavior

| Integration | Blocked when (→ "Not supported") | Allowed |
|---|---|---|
| Chrome (all surfaces) | `chrome://*`, `about:`, `data:`, `view-source:`, new-tab, empty/nil URL | any http/https page |
| Claude Desktop | Settings pane / any screen with no web route (`contentURL == nil`) | a conversation (incl. Claude Design via its content URL) |
| Codex | no resolvable rollout session (`currentSessionGuess()` nil) | a resolved session |
| Cursor | no resolvable conversation (`currentConversationGuess(...)` nil) | a resolved conversation |
| Terminal / iTerm | no TTY captured (`.terminal` no-TTY / `.iterm`) | shell drop with a TTY (`.shell`) |
| VS Code | editor window exposing no file/workspace identity at all | a file (`.editor`) or integrated-terminal shell drop |

## Edge decisions (approved)

1. **iTerm/Terminal with no TTY → blocked.** The normal path captures a TTY and
   produces `.shell`, which passes. The `.iterm` / no-TTY `.terminal` fallbacks
   only occur when Automation permission is denied, and such a chip can never
   receive shell events (it would sit gray forever). The uniform `Not supported`
   copy is slightly opaque here (the real cause is Automation permission); a
   future refinement could special-case that message, but the uniform string is
   used now per the requirement.
2. **VS Code internal Settings UI → not detected (known limitation).** A drop on
   a real file maps to that file's tab and is allowed. VS Code's own Settings
   screen presents to AX as a titled window, so it can't be cleanly distinguished
   from a file without a title heuristic. Out of scope for this iteration.
3. **Non-provider https Chrome pages (e.g. github.com) → allowed (residual).**
   The chosen rule blocks internal/empty pages, not "only allowlisted provider
   hosts." A drop on an ordinary https page is allowed even though the Chrome
   bridge emits no status for non-provider hosts (the chip may stay at its
   initial state). Tightening to the provider allowlist is a possible future
   change, deliberately not made here.

## Testing

- **`Tests/SuperIslandCoreTests/TargetMappabilityTests.swift`** (pure, no
  AppKit), mirroring `SupportedAppsTests.swift` and `IntegrationRoutingTests.swift`:
  - `.chrome` — `https`/`http` allowed; `chrome://settings`, `chrome://newtab`,
    `about:blank`, `data:...`, `view-source:...`, empty, nil all blocked.
  - `.generic` — `contentURL` non-nil allowed; nil blocked.
  - `.shell` — allowed.
  - `.terminal` — non-nil tty allowed; nil tty blocked.
  - `.iterm` — blocked regardless of sessionID.
  - `.editor` — allowed when any of filePath/fileName/workspaceName is set;
    blocked when all nil.
- The `createDrop` toast/beep/`return false` wiring is verified manually (it is
  AX/AppKit-bound, like the two existing reject paths, which are also not
  unit-tested).

## Non-goals

- Proactive notch-disabling before the drop gesture (reactive only this round).
- Per-integration / remediation-specific copy (uniform `Not supported` per
  requirement).
- Detecting VS Code's internal Settings UI.
- Restricting Chrome to provider-allowlisted hosts.
- Fixing the separate, pre-existing silent `store.add` duplicate-session return
  (`DropStore.swift:44`–`56`); noted but out of scope.

## Files touched

- **New:** `Sources/SuperIslandCore/TargetMappability.swift`
- **New:** `Tests/SuperIslandCoreTests/TargetMappabilityTests.swift`
- **Edit:** `Sources/SuperIslandApp/AppController.swift` — one guard in
  `createDrop()` after the `contentURL` binding.
