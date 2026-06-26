# Web-AI NEEDS_ATTENTION Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Chrome web-AI drops reach NEEDS_ATTENTION by reusing the existing AI classifier at turn-end, while the extension keeps owning instant working/done.

**Architecture:** The extension's network detector owns the *live* `working` signal (via the bridge). The existing `SuperIslandMonitor` AI classifier resolves the *resting* state (`done` vs `needsAttention`) once a turn settles. A new pure `ChromeStatusPolicy` (Core) encodes the two rules — "skip the AI only while a chrome drop is actively working" and "ignore an AI `working` verdict for chrome" — so both the App-side call sites stay one-liners and the logic is unit-tested. The coarse needsAttention regex is removed from `content.js`; the classifier is the sole source.

**Tech Stack:** Swift 6 (Core) / Swift 5 mode (App target), XCTest, MV3 Chrome extension JS.

Full design: `docs/superpowers/specs/2026-06-27-web-ai-needs-attention-design.md`.

## Global Constraints

- `SuperIslandApp` target builds in **Swift 5 language mode**; `SuperIslandCore` in Swift 6. Don't change either.
- `DropStatus` cases are exactly: `working`, `needsAttention`, `done`, `stale`, `unknown`.
- Core logic is unit-tested in `Tests/SuperIslandCoreTests`; the App target has no test target — App-side changes are build-verified + manually verified.
- CI lint MUST pass: `swift format lint --strict --configuration .swift-format --recursive Sources Tests`.
- Extension JS is validated with `node --check` (modules copied to a `.mjs` temp first). The extension is loaded **unpacked from source** (`Extensions/Chrome`); reload it + hard-refresh the tab to test.
- **Setup (we are on `main`):** before Task 1, create a working branch: `git checkout -b feat/web-ai-needs-attention`.

---

### Task 1: `ChromeStatusPolicy` (pure Core logic)

**Files:**
- Modify: `Sources/SuperIslandCore/StatusPolicy.swift` (append a new `ChromeStatusPolicy` enum after `MonitorPolicy`)
- Test: `Tests/SuperIslandCoreTests/ChromeStatusPolicyTests.swift` (create)

**Interfaces:**
- Produces:
  - `ChromeStatusPolicy.bridgeOwnsLiveStatus(locator: Locator, status: DropStatus, bridgeConnected: Bool) -> Bool`
  - `ChromeStatusPolicy.monitorMayApply(verdict: DropStatus, locator: Locator) -> Bool`

- [ ] **Step 1: Write the failing test**

Create `Tests/SuperIslandCoreTests/ChromeStatusPolicyTests.swift`:

```swift
import XCTest

@testable import SuperIslandCore

final class ChromeStatusPolicyTests: XCTestCase {
    private let chrome = Locator.chrome(
        windowID: 1, windowIndex: 0, tabIndex: 0, tabID: 5,
        url: "https://gemini.google.com/", title: "Gemini",
        documentID: nil, taskAnchor: nil)
    private let generic = Locator.generic(axWindowTitle: "x", axWindowIndex: 0)

    // bridgeOwnsLiveStatus: AI monitor skips a chrome drop only while live-working.
    func testChromeWorkingConnectedIsManaged() {
        XCTAssertTrue(
            ChromeStatusPolicy.bridgeOwnsLiveStatus(
                locator: chrome, status: .working, bridgeConnected: true))
    }

    func testChromeDoneConnectedIsNotManaged() {
        XCTAssertFalse(
            ChromeStatusPolicy.bridgeOwnsLiveStatus(
                locator: chrome, status: .done, bridgeConnected: true))
    }

    func testChromeWorkingDisconnectedIsNotManaged() {
        XCTAssertFalse(
            ChromeStatusPolicy.bridgeOwnsLiveStatus(
                locator: chrome, status: .working, bridgeConnected: false))
    }

    func testNonChromeIsNeverManagedHere() {
        XCTAssertFalse(
            ChromeStatusPolicy.bridgeOwnsLiveStatus(
                locator: generic, status: .working, bridgeConnected: true))
    }

    // monitorMayApply: an AI `working` verdict on a chrome drop is ignored.
    func testChromeWorkingVerdictIsIgnored() {
        XCTAssertFalse(ChromeStatusPolicy.monitorMayApply(verdict: .working, locator: chrome))
    }

    func testChromeNeedsAttentionVerdictApplies() {
        XCTAssertTrue(ChromeStatusPolicy.monitorMayApply(verdict: .needsAttention, locator: chrome))
    }

    func testChromeDoneVerdictApplies() {
        XCTAssertTrue(ChromeStatusPolicy.monitorMayApply(verdict: .done, locator: chrome))
    }

    func testGenericWorkingVerdictApplies() {
        XCTAssertTrue(ChromeStatusPolicy.monitorMayApply(verdict: .working, locator: generic))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChromeStatusPolicyTests`
Expected: FAIL to compile — "cannot find 'ChromeStatusPolicy' in scope".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/SuperIslandCore/StatusPolicy.swift` (after the `MonitorPolicy` enum):

```swift

/// Reconciles the two status owners for a Chrome web-AI drop: the extension
/// bridge owns the *live* `working` signal (network-detected), and the AI
/// monitor resolves the *resting* state (`done` vs `needsAttention`) from the
/// settled conversation. Pure and UI-free so it can be unit-tested.
public enum ChromeStatusPolicy {
    /// True when the AI monitor should SKIP this drop because the bridge is
    /// actively driving it. Only chrome drops, only while the bridge is
    /// connected AND the drop is live-`working`; once it settles (or the bridge
    /// disconnects) the monitor takes over so it can resolve needsAttention.
    public static func bridgeOwnsLiveStatus(
        locator: Locator,
        status: DropStatus,
        bridgeConnected: Bool
    ) -> Bool {
        guard case .chrome = locator else { return false }
        return bridgeConnected && status == .working
    }

    /// True when the monitor MAY apply this verdict. For a chrome drop the bridge
    /// owns the live `working` signal, so an AI `working` verdict is ignored;
    /// `done` / `needsAttention` / `unknown` / `stale` apply normally.
    public static func monitorMayApply(verdict: DropStatus, locator: Locator) -> Bool {
        if case .chrome = locator, verdict == .working { return false }
        return true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ChromeStatusPolicyTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Lint**

Run: `swift format lint --strict --configuration .swift-format --recursive Sources Tests`
Expected: exit 0, no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/SuperIslandCore/StatusPolicy.swift Tests/SuperIslandCoreTests/ChromeStatusPolicyTests.swift
git commit -m "feat(core): ChromeStatusPolicy reconciles bridge vs AI status for chrome drops"
```

---

### Task 2: Wire the policy into the App (skip-gate + verdict filter)

**Files:**
- Modify: `Sources/SuperIslandApp/AppController.swift` (the `monitor.isExternallyManaged` closure, currently ~`:142-151`)
- Modify: `Sources/SuperIslandApp/Monitor.swift` (the verdict-application block in `classify`, currently ~`:214-220`)

**Interfaces:**
- Consumes: `ChromeStatusPolicy.bridgeOwnsLiveStatus(locator:status:bridgeConnected:)`, `ChromeStatusPolicy.monitorMayApply(verdict:locator:)` from Task 1.

- [ ] **Step 1: Update `isExternallyManaged` to skip the AI only while live-working**

In `Sources/SuperIslandApp/AppController.swift`, replace the chrome clause inside the `monitor.isExternallyManaged` closure:

```swift
            // A Chrome web-AI drop is owned by the extension's network detector
            // whenever the bridge is live (10s freshness window) — never the AI
            // window classifier. On bridge disconnect this falls back to AI
            // classification automatically, which is the correct degradation.
            if case .chrome = drop.target.locator, ChromeBridgeStateStore.shared.isConnected {
                return true
            }
```

with:

```swift
            // The extension bridge owns a chrome drop's live `working` signal.
            // Skip the AI classifier only while a turn is actively working; once
            // it settles, let the classifier resolve done vs needsAttention. On
            // bridge disconnect this falls back to full AI classification.
            if case .chrome = drop.target.locator {
                return ChromeStatusPolicy.bridgeOwnsLiveStatus(
                    locator: drop.target.locator,
                    status: drop.status,
                    bridgeConnected: ChromeBridgeStateStore.shared.isConnected)
            }
```

- [ ] **Step 2: Filter the verdict for chrome in `Monitor.classify`**

In `Sources/SuperIslandApp/Monitor.swift`, replace:

```swift
                dlog(.proxy, "classify \(target.appName) → \(verdict.status.rawValue)")
                // Status updates every time; the label is set ONCE (while the
                // drop is still an app/window-title placeholder) and never
                // re-derived — a drop's name is its identity and must not churn
                // across re-classifications.
                store.updateStatus(id: id, to: verdict.status, reason: verdict.reason)
                store.nameIfUnnamed(id: id, label: verdict.label)
```

with:

```swift
                dlog(.proxy, "classify \(target.appName) → \(verdict.status.rawValue)")
                // Status updates every time; the label is set ONCE (while the
                // drop is still an app/window-title placeholder) and never
                // re-derived — a drop's name is its identity and must not churn
                // across re-classifications.
                //
                // For chrome drops the extension bridge owns the live `working`
                // signal, so an AI `working` verdict is ignored (the bridge will
                // report working itself). `done`/`needsAttention` still apply —
                // that's how a settled chrome turn reaches needsAttention.
                if ChromeStatusPolicy.monitorMayApply(
                    verdict: verdict.status, locator: target.locator)
                {
                    store.updateStatus(id: id, to: verdict.status, reason: verdict.reason)
                }
                store.nameIfUnnamed(id: id, label: verdict.label)
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!` (the pre-existing `DiagnosticLogger` actor-isolation warning is fine; no errors).

- [ ] **Step 4: Run the full test suite (no regressions)**

Run: `swift test 2>&1 | grep -E "Test Suite 'All tests'|Executed [0-9]+ tests|error:"`
Expected: `Executed 203 tests, with 0 failures` (195 prior + 8 new), all suites pass.

- [ ] **Step 5: Lint**

Run: `swift format lint --strict --configuration .swift-format --recursive Sources Tests`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/SuperIslandApp/AppController.swift Sources/SuperIslandApp/Monitor.swift
git commit -m "feat(app): classify settled chrome drops for needsAttention; bridge keeps working"
```

---

### Task 3: Extension cleanup — classifier is the sole needsAttention source

**Files:**
- Modify: `Extensions/Chrome/content.js`

**Interfaces:**
- Produces: `content.js` posts `superisland_dom_signal` carrying only `{ domConfirmsWorking, text }` (no `domStatus`). `background.js` `mergeStatus` already treats a missing `domStatus` as no DOM verdict and still honors `domConfirmsWorking` — no background change needed.

- [ ] **Step 1: Replace the verdict-scraping with the Stop-button confirmation only**

Replace the top of `Extensions/Chrome/content.js` from the header comment through `collectSignal()` (lines 1–53) with:

```javascript
// content.js — DEMOTED to a one-bit side channel.
//
// background.js (network) is the source of truth for working/done, and the app's
// AI classifier owns needsAttention (it reads the settled conversation). This
// script only reports the one thing the network can't see and the DOM does
// reliably: whether a Stop/▣ button is present, used to CORROBORATE working when
// the service worker missed the stream.

// A Stop/abort control replaces Send in every provider's composer while generating.
function stopButtonPresent() {
  const sel = [
    '[data-testid="stop-button"]',
    'button[aria-label*="stop generating" i]',
    'button[aria-label*="stop response" i]',
    'button[aria-label*="stop streaming" i]',
    'button[aria-label="Stop" i]',
  ].join(",");
  if (document.querySelector(sel)) return true;
  // Fallback: a button whose visible/aria label is exactly a stop verb.
  for (const b of document.querySelectorAll("button")) {
    const t = (b.getAttribute("aria-label") || b.innerText || "").trim().toLowerCase();
    if (t === "stop" || t === "stop generating" || t === "stop response") return true;
  }
  return false;
}

function collectSignal() {
  const working = stopButtonPresent();
  const text = (document.body?.innerText || "").replace(/\s+/g, " ").trim().slice(0, 600);
  return { domConfirmsWorking: working, text };
}
```

This deletes `ATTENTION_RE` and `doneAffordancesPresent()` and the `domStatus` computation. Leave the rest of the file (`report()`, the `superisland_collect_dom` listener, the `MutationObserver`, and the trailing `report()`) unchanged — note the `superisland_collect_dom` reply now sends `taskState: s.domStatus` where `s.domStatus` is `undefined`; change that one line in the listener to `taskState: collectSignal().domConfirmsWorking ? "working" : "unknown"`:

```javascript
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "superisland_collect_dom") {
    const s = collectSignal();
    sendResponse({
      title: document.title || "",
      text: s.text,
      taskState: s.domConfirmsWorking ? "working" : "unknown",
    });
  }
  return true;
});
```

- [ ] **Step 2: Syntax-check**

Run: `node --check Extensions/Chrome/content.js`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add Extensions/Chrome/content.js
git commit -m "refactor(ext): drop content.js needsAttention regex; AI classifier owns it now"
```

---

### Task 4: End-to-end verification

**Files:** none (manual verification).

- [ ] **Step 1: Rebuild the app bundle and relaunch**

```bash
Scripts/build-app.sh debug
pkill -f '/Users/akhil/useklip/.build/SuperIsland.app/Contents/MacOS/SuperIsland$' || true
sleep 2
open /Users/akhil/useklip/.build/SuperIsland.app
```

- [ ] **Step 2: Reload the extension + hard-refresh a provider tab**

In Chrome: `chrome://extensions` → reload the unpacked SuperIsland extension; hard-refresh a Gemini/ChatGPT tab (⌘⇧R). (Extension JS only changed in `content.js`; no manifest change.)

- [ ] **Step 3: Drive a question turn and confirm the upgrade**

In the provider tab, drop the tab (⌥⌘K), then send a prompt whose answer ends by asking *you* a question (e.g. "Help me plan a trip — ask me what you need to know."). Let it finish.

Run (watch the app log):
```bash
grep -E "PROXY[[:space:]]+(chrome tab_state|classify Google Chrome)" ~/.config/superisland/diagnostics.log | tail -15
```
Expected sequence: `chrome tab_state working …` during the turn → `chrome tab_state done …` at the end → then `classify Google Chrome → needsAttention` (the classifier upgrade). The island pill ends on **NEEDS_ATTENTION**.

- [ ] **Step 4: Confirm self-healing**

Send a normal follow-up prompt. Expected: the island returns to **working** (bridge), confirming the flag cleared on the next turn. A plain completed answer (no question) should settle on **done**, not needsAttention.

- [ ] **Step 5: Commit the design + plan docs**

```bash
git add docs/superpowers/specs/2026-06-27-web-ai-needs-attention-design.md docs/superpowers/plans/2026-06-27-web-ai-needs-attention.md
git commit -m "docs: web-AI needsAttention design + implementation plan"
```

---

## Notes / deferred

- **Builder mid-build approvals** (Lovable/v0/bolt/Emergent pausing for a tool approval while the SSE stream stays open) are NOT covered — the bridge reads that as `working` so the at-done classifier never runs. Deferred to a follow-up: a thin per-provider DOM approval check that overrides the open-stream `working`.
- **Classifier prompt tuning** (ensuring rate-limit/login/error banners are called `needsAttention`) is a separate backend concern; this plan is agnostic to it.
