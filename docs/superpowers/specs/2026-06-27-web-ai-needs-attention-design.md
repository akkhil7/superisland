# Web-AI NEEDS_ATTENTION detection — design

**Date:** 2026-06-27
**Status:** Implemented — see REVISION below
**Area:** Chrome bridge + Monitor (status pipeline for web-AI drops)

## REVISION (post-implementation): the AX assumption was wrong

The original design below routed Chrome needsAttention through the existing
`Monitor` AI classifier, assuming it could read the conversation from the
window's accessibility text. **It can't** — verified live: for a Gemini window
the captured AX text was the Chrome *tab strip + window chrome* ("Google Flights
— Memory usage — New tab — Open Gemini in Chrome…"), not one word of the
conversation. So the classifier returned `done` with reason "no active task or
prompt visible." No prompt change can fix a blind input.

**Corrected approach (implemented):** the conversation is only readable from the
**extension's DOM** (`content.js` reads `document.body.innerText`). So:

- `content.js` sends the **conversation tail** (last ~4000 chars, newlines kept)
  in `domSummary.text` instead of a 600-char nav snippet.
- On the **working→done edge**, `AppController.handleChromeTabEvent` calls the
  **focused `turnEndSystemPrompt`** (`ClaudeClassifier.classifyTurnEndMessage`)
  on that text — the prompt already nails "ends with a question → needsAttention"
  and is validated to ignore `?` in code and treat sign-offs as `done`. If the
  verdict is `needsAttention`, it **upgrades** the still-`done` drop (and only if
  still `done`, so a new turn that started meanwhile is never clobbered).
- Chrome stays fully **bridge-owned**; the `Monitor`/AX path never touches it
  (`isExternallyManaged` returns true for chrome while the bridge is connected).
- The general window `systemPrompt` is **left as-is** (it's for terminals/editors
  with no clean message). `ChromeStatusPolicy` and the Monitor verdict-filter
  from the original design were reverted — not needed.

Verified: question-ending turn → `needsAttention`; plain answer → `done`. The
original design (below) is retained for context.

---

## Problem

Chrome web-AI drops (Gemini, ChatGPT, Claude, Mistral, …) now reach `working`
and `done` reliably via the extension's network detector. They never reach
`needsAttention`. We want a tracked tab to flip to NEEDS_ATTENTION when:

1. **The agent is waiting on you** — it ended its turn by asking a question or an
   imperative ("paste your config", "which do you prefer?").
2. **Rate limit / upgrade wall** — you hit a quota or credit cap.
3. **Logged out / session expired** — the tab needs re-auth.
4. **Generation error** — the turn failed, server is busy, or a Cloudflare
   "verify you are human" challenge is up.

Clearing is **self-healing**: the flag goes away on its own when the condition
resolves (the next turn starts, you re-auth, the limit resets, you retry).

## Key decision: reuse the existing AI classifier

SuperIsland already classifies window content into `working` / `done` /
`needsAttention` via `SuperIslandMonitor.classify` → `ClaudeClassifier`
(`BackendConfig.classifyURL`). It reads the window's accessibility text — for a
Chrome tab, that's the rendered conversation, including any rate-limit / login /
error banner. It understands a real "what's your budget?" vs a rhetorical "you
might ask, why?", catches imperative asks with no `?`, and is multilingual.

We were *bypassing* this for `.chrome` drops (the "extension is ground truth"
wiring marks them externally-managed while the bridge is connected). The design
brings the classifier back **surgically**, as the sole NEEDS_ATTENTION source,
without giving up the instant/free network `working`/`done`.

### Division of labor

| Signal | Owner | When |
|---|---|---|
| `working` (live turn) | Extension network detector (bridge) | Instant, while a generation request is open / debouncing |
| `done` / `needsAttention` (resting state) | App AI classifier (existing `Monitor`) | Once per settled turn, from the rendered conversation text |

The bridge owns the **live** signal; the classifier resolves the **resting**
state. The classifier may **never** override an active turn — for a `.chrome`
drop a `working` verdict from the classifier is ignored (the bridge owns it).

This needs **no extension-side needsAttention detection** — the classifier reads
the banners/questions from the page text. All four triggers above are covered by
one semantic classifier rather than four fragile per-provider heuristics.

## Changes

### 1. `AppController.isExternallyManaged` — skip AI only while a turn is live

Today `.chrome` + bridge-connected is *always* excluded from the Monitor. Change
it to exclude only while the drop is actively `working`:

```swift
if case .chrome = drop.target.locator {
    // Bridge owns working/done. Skip the AI classifier only while a turn is
    // live; once it settles, let the classifier resolve the resting state
    // (done vs needsAttention). Bridge disconnected → full AI fallback.
    return ChromeBridgeStateStore.shared.isConnected && drop.status == .working
}
```

A settled (`done`) chrome drop becomes Monitor-eligible again, so the classifier
runs once (then the existing content-change freeze stops it re-running on a
static conversation).

### 2. `Monitor.classify` — for chrome, ignore a `working` verdict

After obtaining `verdict`, a `.chrome` drop applies `done` / `needsAttention`
but never `working` (the bridge owns the live signal):

```swift
let isChrome: Bool = { if case .chrome = target.locator { return true } else { return false } }()
if isChrome && verdict.status == .working {
    // Bridge reports working; don't let an AI misread drag a settled drop back.
    scheduleNextCheck()
    return
}
store.updateStatus(id: id, to: verdict.status, reason: verdict.reason)
store.nameIfUnnamed(id: id, label: verdict.label)
```

This also fixes a side case for free: a tab dropped on an *already-finished*
conversation (no bridge generation event) gets resolved to `done` (or
`needsAttention`) by the classifier instead of sitting at `unknown`.

### 3. Extension cleanup — classifier is the sole needsAttention source

`content.js` currently emits a coarse `needsAttention` / `done` from a text
regex (`ATTENTION_RE`, `doneAffordancesPresent`). Remove those — they are
fragile and now redundant. `content.js` keeps only the **Stop-button working
confirmation** (`domConfirmsWorking`), which `background.js` `mergeStatus` still
uses as a fallback when it missed the stream. The bridge therefore emits only
`working` / `done` / `unknown`; needsAttention comes solely from the app
classifier. (`mergeStatus` / `handleChromeTabEvent` already tolerate the reduced
signal; no behavior change needed there.)

## Coverage and the deferred follow-up

**Covered:** every chat app's "agent ended its turn by asking you something,"
plus rate-limit / login / error / Cloudflare states — all read from the settled
conversation at turn end.

**Deferred (follow-up):** builder apps (Lovable / v0 / bolt / Emergent) can pause
**mid-build** for a tool approval while the SSE stream stays open. The bridge
reads that as `working`, so the at-done classifier won't see it. Catching this
needs a thin, per-provider DOM approval check (Approve/Reject buttons,
"ask-human" forms) that overrides the open-stream `working`. Out of scope here;
tracked as a separate task.

## Cost & latency

One classifier call per **completed** turn for a tracked chrome tab — not
continuous polling — gated further by the Monitor's content-change freeze
(`MonitorPolicy.shouldClassify`) and the `done`/`needsAttention` settled-recheck
cadence (5s). This is **strictly fewer** calls than pre-bridge behavior, which
classified Chrome on a backoff even while it was working. Subject to the existing
daily classifier quota (`ClassifierError.quotaExceeded`), already handled by the
Monitor. NEEDS_ATTENTION appears ~5s (tick) + classifier round-trip after `done`.

## Testing

- `isExternallyManaged`: `.chrome` + connected + `working` → managed (AI skipped);
  `.chrome` + connected + `done` → not managed (AI eligible); `.chrome` +
  disconnected → not managed (full fallback).
- `Monitor.classify` chrome verdict filter: a `working` verdict on a `.chrome`
  drop does not call `updateStatus`; a `needsAttention` / `done` verdict does.
  (Requires making the classifier injectable/mockable in the Monitor test seam,
  or testing the verdict-filter as an extracted pure function.)
- Self-healing: a `needsAttention` chrome drop returns to `working` when the
  bridge reports a new turn (status precedence already covered by the bridge
  path).
- Extension: `content.js` no longer emits `needsAttention`/`done` text verdicts;
  still emits `domConfirmsWorking`.

## Risks

1. **Classifier accuracy on banners.** The classifier must treat "you've reached
   your limit / upgrade", login walls, and error/"verify you are human" text as
   `needsAttention`. If its prompt under-calls these, tune the classifier prompt
   (separate, backend concern) — the wiring here is agnostic to that.
2. **Chrome AX text availability.** The classifier relies on the window's
   accessibility text. This is the same capture the Monitor used for Chrome
   pre-bridge, so it is known to work, but depends on the user's Accessibility
   grant.
3. **Latency vs the old instant regex.** NEEDS_ATTENTION is a few seconds behind
   `done` (classifier round-trip). Acceptable — it is not time-critical, and the
   trade buys far lower false-positive rate.
4. **Ignored-working for chrome** means the classifier can never set `working` on
   a chrome drop — intentional, the bridge owns it; the only loss is AI working
   detection for a tab the bridge never reports on, which is the desired
   division of labor.
