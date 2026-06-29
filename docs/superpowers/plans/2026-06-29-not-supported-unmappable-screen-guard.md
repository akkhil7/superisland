# "Not supported" Unmappable-Screen Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refuse a drop with a `Not supported` toast whenever the screen showing at drop time carries no tab/session identity to track, even on a supported, integrated app.

**Architecture:** Add one pure, dependency-free predicate `TargetMappability.canMap(locator:contentURL:)` in `SuperIslandCore`, implemented as an exhaustive `switch` over `Locator`. Call it once at the single chokepoint `AppController.createDrop()`, right after the per-bundle `contentURL` binding and before the duplicate-target check — so the guard covers every integration (and every future `Locator` case, by compile-time exhaustiveness).

**Tech Stack:** Swift, SwiftPM, XCTest. macOS app (`SuperIslandApp`) depends on the pure `SuperIslandCore` library.

## Global Constraints

- Toast copy is the exact literal string `Not supported` (uniform; no per-integration copy).
- The reject path must mirror the existing gates in `createDrop()`: `showToast(...)`, `NSSound.beep()`, `return false` — create no drop.
- `TargetMappability` lives in `SuperIslandCore` and must stay pure/dependency-free (Foundation only, no AppKit), like `SupportedApps` — so it is unit-testable without AppKit.
- `canMap` must be `public` (it is called from the separate `SuperIslandApp` module).
- Chrome mappable iff the tab URL scheme is `http`/`https`; block `chrome://*`, `about:`, `data:`, `view-source:`, `chrome-extension:`, the new-tab page, and empty/nil URLs.
- Codex/Cursor (and Claude Desktop, generic Electron) map via `contentURL`: block only when `contentURL == nil`.
- Terminal-family maps via a captured TTY: `.shell` always passes; `.terminal` passes only with a non-nil tty; `.iterm` never passes.
- Editor (`.editor`) passes when any of `filePath`/`fileName`/`workspaceName` is non-nil.
- Tests run with `swift test`; existing core tests use `XCTest` + `@testable import SuperIslandCore`.

---

### Task 1: `TargetMappability` pure predicate + unit tests

**Files:**
- Create: `Sources/SuperIslandCore/TargetMappability.swift`
- Test: `Tests/SuperIslandCoreTests/TargetMappabilityTests.swift`

**Interfaces:**
- Consumes: `Locator` and its cases (`.chrome`, `.generic`, `.shell`, `.terminal`, `.iterm`, `.editor`) and `ChromeTaskAnchor` from `Sources/SuperIslandCore/Models.swift` (all `public`).
- Produces: `public static func canMap(locator: Locator, contentURL: String?) -> Bool` on `public enum TargetMappability`. Internal helper `static func isTrackableWebURL(_ urlString: String?) -> Bool`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SuperIslandCoreTests/TargetMappabilityTests.swift`:

```swift
import XCTest

@testable import SuperIslandCore

final class TargetMappabilityTests: XCTestCase {
    // Helper: a Chrome locator carrying a given tab URL.
    private func chrome(url: String?) -> Locator {
        .chrome(
            windowID: 1, windowIndex: 1, tabIndex: 1, tabID: 42,
            url: url, title: "Title", documentID: nil, taskAnchor: nil
        )
    }

    // MARK: Chrome — http/https only

    func testChromeAllowsHTTPAndHTTPS() {
        XCTAssertTrue(TargetMappability.canMap(locator: chrome(url: "https://claude.ai/x"), contentURL: nil))
        XCTAssertTrue(TargetMappability.canMap(locator: chrome(url: "http://example.com"), contentURL: nil))
    }

    func testChromeBlocksInternalAndEmptyPages() {
        let blocked: [String?] = [
            "chrome://settings",
            "chrome://newtab/",
            "about:blank",
            "data:text/html,<h1>hi</h1>",
            "view-source:https://example.com",
            "chrome-extension://abc/page.html",
            "",
            nil,
        ]
        for url in blocked {
            XCTAssertFalse(
                TargetMappability.canMap(locator: chrome(url: url), contentURL: nil),
                "expected chrome url \(url ?? "nil") to be blocked"
            )
        }
    }

    // MARK: Generic (Claude Desktop / Codex / Cursor / Electron) — needs contentURL

    func testGenericMappableOnlyWithContentURL() {
        let locator = Locator.generic(axWindowTitle: "Claude", axWindowIndex: nil)
        XCTAssertTrue(
            TargetMappability.canMap(
                locator: locator, contentURL: "https://claude.ai/epitaxy/local_abc123"))
        XCTAssertFalse(TargetMappability.canMap(locator: locator, contentURL: nil))
    }

    // MARK: Terminal family — needs a captured TTY

    func testShellAlwaysMappable() {
        XCTAssertTrue(
            TargetMappability.canMap(locator: .shell(tty: "/dev/ttys001"), contentURL: nil))
    }

    func testTerminalMappableOnlyWithTTY() {
        XCTAssertTrue(
            TargetMappability.canMap(
                locator: .terminal(windowIndex: 1, tabIndex: nil, tty: "/dev/ttys002"),
                contentURL: nil))
        XCTAssertFalse(
            TargetMappability.canMap(
                locator: .terminal(windowIndex: 1, tabIndex: nil, tty: nil), contentURL: nil))
    }

    func testITermNeverMappable() {
        XCTAssertFalse(
            TargetMappability.canMap(locator: .iterm(sessionID: "uuid-1"), contentURL: nil))
        XCTAssertFalse(TargetMappability.canMap(locator: .iterm(sessionID: nil), contentURL: nil))
    }

    // MARK: Editor — needs some file/workspace identity

    func testEditorMappableWithAnyIdentity() {
        XCTAssertTrue(
            TargetMappability.canMap(
                locator: .editor(filePath: "/a/b.swift", fileName: nil, workspaceName: nil),
                contentURL: nil))
        XCTAssertTrue(
            TargetMappability.canMap(
                locator: .editor(filePath: nil, fileName: "b.swift", workspaceName: nil),
                contentURL: nil))
        XCTAssertTrue(
            TargetMappability.canMap(
                locator: .editor(filePath: nil, fileName: nil, workspaceName: "useklip"),
                contentURL: nil))
    }

    func testEditorBlockedWithNoIdentity() {
        XCTAssertFalse(
            TargetMappability.canMap(
                locator: .editor(filePath: nil, fileName: nil, workspaceName: nil),
                contentURL: nil))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TargetMappabilityTests`
Expected: FAIL — compile error, `cannot find 'TargetMappability' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/SuperIslandCore/TargetMappability.swift`:

```swift
import Foundation

/// Whether a resolved drop target carries the tab/session identity its
/// integration needs to actually track status. Used as the third `createDrop`
/// gate (after "is the app supported" and "is its integration set up"): a
/// drop on a screen that resolves to nothing — an in-app Settings pane, a
/// `chrome://` page, a window with no session — is refused instead of becoming
/// a dead chip that never updates.
///
/// Pure and dependency-free (Foundation only) so it can be unit-tested without
/// AppKit, like `SupportedApps`.
public enum TargetMappability {
    /// The switch is exhaustive over `Locator` on purpose: adding a new locator
    /// case won't compile until it declares whether it is mappable here, so the
    /// guard can never silently miss a future integration.
    public static func canMap(locator: Locator, contentURL: String?) -> Bool {
        switch locator {
        case let .chrome(_, _, _, _, url, _, _, _):
            // Only real web pages are trackable; internal/empty pages have a tab
            // id but never produce status.
            return isTrackableWebURL(url)
        case .shell:
            // A TTY was captured — shell hook events can drive status.
            return true
        case let .terminal(_, _, tty):
            // The no-TTY fallback can't receive shell events.
            return tty != nil
        case .iterm:
            // Reached only when no TTY could be captured (Automation denied);
            // a session id alone can't receive shell events.
            return false
        case let .editor(filePath, fileName, workspaceName):
            return filePath != nil || fileName != nil || workspaceName != nil
        case .generic:
            // Electron desktop agents (Claude Desktop, Codex, Cursor) and other
            // generic windows bind their session through the web content URL.
            return contentURL != nil
        }
    }

    /// `http`/`https` only. Blocks `chrome://`, `about:`, `data:`,
    /// `view-source:`, `chrome-extension:`, the new-tab page, and empty/nil URLs.
    static func isTrackableWebURL(_ urlString: String?) -> Bool {
        guard let urlString, !urlString.isEmpty,
            let scheme = URL(string: urlString)?.scheme?.lowercased()
        else { return false }
        return scheme == "http" || scheme == "https"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TargetMappabilityTests`
Expected: PASS — all `TargetMappabilityTests` cases green.

- [ ] **Step 5: Run the full core suite to check for regressions**

Run: `swift test`
Expected: PASS — the whole `SuperIslandCoreTests` suite is green (no existing test broken).

- [ ] **Step 6: Commit**

```bash
git add Sources/SuperIslandCore/TargetMappability.swift Tests/SuperIslandCoreTests/TargetMappabilityTests.swift
git commit -m "feat(core): add TargetMappability predicate for drop targets

Pure, exhaustive-over-Locator check of whether a resolved drop target
carries a trackable tab/session identity. http/https for Chrome, a
captured TTY for terminals, contentURL for Electron agents, a file or
workspace for editors. Foundation-only so it unit-tests without AppKit.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Wire the guard into `createDrop()`

**Files:**
- Modify: `Sources/SuperIslandApp/AppController.swift` (in `createDrop()`, immediately after the Claude Desktop title block that ends near line 1093, before `let target = WindowTarget(`)

**Interfaces:**
- Consumes: `TargetMappability.canMap(locator:contentURL:)` from Task 1; the local `locator` and `contentURL` already computed earlier in `createDrop()`; the existing `showToast(_:)` method and `NSSound.beep()` already used in this function.
- Produces: no new symbols — adds a third early-return gate to `createDrop()`.

- [ ] **Step 1: Add the guard**

In `Sources/SuperIslandApp/AppController.swift`, find this existing block in `createDrop()`:

```swift
        if front.bundleID == ClaudeDeepLink.bundleID, let url = contentURL {
            threadLabel = claudeIntegration.sessionTitle(forContentURL: url)
        }

        let target = WindowTarget(
```

Replace it with (insert the guard between the `}` and `let target`):

```swift
        if front.bundleID == ClaudeDeepLink.bundleID, let url = contentURL {
            threadLabel = claudeIntegration.sessionTitle(forContentURL: url)
        }

        // Third gate (after "is the app supported" and "is its integration set
        // up"): the screen showing right now must resolve to a concrete tab or
        // session we can track. A drop on an in-app Settings pane, a chrome://
        // page, or a window with no session would otherwise be a dead chip.
        guard TargetMappability.canMap(locator: locator, contentURL: contentURL) else {
            showToast("Not supported")
            NSSound.beep()
            return false
        }

        let target = WindowTarget(
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` — `TargetMappability` resolves (AppController already `import SuperIslandCore`); no errors.

- [ ] **Step 3: Run the full test suite (no regressions)**

Run: `swift test`
Expected: PASS — full suite green.

- [ ] **Step 4: Manual verification (AppKit-bound; not unit-tested, like the existing gates)**

Build and run the app (`Scripts/build-app.sh` or run from Xcode), then with each integration set up, summon the island (⌥⌘K) and drop while focused on:
  - Chrome on `chrome://settings` or a new tab → toast `Not supported`, no chip created.
  - Chrome on a normal `https://` page → chip created as before (allowed).
  - Claude Desktop on its Settings pane → toast `Not supported`; on a conversation → chip created.
  - Codex/Cursor with no active session/conversation → toast `Not supported`; with one → chip created.
  - Terminal/iTerm with shell integration installed → chip created (TTY captured). (A no-TTY case requires denying Automation permission; optional to verify.)
Confirm a beep accompanies each `Not supported` toast and that no chip appears for the blocked cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandApp/AppController.swift
git commit -m "feat(app): block drops on screens that can't map to a tab/session

createDrop() now refuses with a 'Not supported' toast when the resolved
target carries no trackable tab/session identity (TargetMappability),
mirroring the existing unsupported-app and missing-integration gates.
Applies to every integration via the shared chokepoint.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- Block + uniform `Not supported` toast + beep + no drop → Task 2 Step 1. ✓
- Reactive at drop time (single chokepoint) → Task 2 (guard in `createDrop`). ✓
- Applies to all integrations incl. all Chrome surfaces → exhaustive `Locator` switch, Task 1 Step 3. ✓
- Chrome internal/empty pages blocked → `isTrackableWebURL`, Task 1 Steps 1 & 3. ✓
- Codex/Cursor block only when no session (`contentURL == nil`) → `.generic` branch, Task 1. ✓
- Terminal-family TTY rule / `.iterm` never / `.editor` identity rule → Task 1 switch + tests. ✓
- Pure, AppKit-free, unit-testable in Core → Task 1 file is Foundation-only, tested via `swift test`. ✓
- New files match spec's "Files touched" (TargetMappability.swift, TargetMappabilityTests.swift, AppController.swift). ✓
- Non-goals (proactive notch-disable, per-integration copy, VS Code internal-settings detection, provider-host restriction, `store.add` return fix) → not implemented. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". All code shown in full. ✓

**3. Type consistency:** `canMap(locator:contentURL:) -> Bool` and `isTrackableWebURL(_:)` are named identically in the implementation, the tests, and the call site. The `.chrome` pattern `(_, _, _, _, url, _, _, _)` matches `Locator.chrome`'s 8 associated values (url is 5th). `Locator` cases used in tests match `Models.swift`. ✓
