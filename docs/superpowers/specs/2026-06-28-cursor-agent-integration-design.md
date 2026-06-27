# Dedicated Cursor agent integration — design

**Date:** 2026-06-28
**Status:** Designed
**Area:** New per-app integration (Cursor), split from the VS Code editor adapter; ShellServer + AppController + DropSource/SupportedApps/IntegrationRouter + onboarding/settings

## Problem

SuperIsland treats **Cursor as a member of the `EditorApp` family** — a VS Code
fork — and tracks it as a *file editor*. A Cursor drop today is one of two
things, neither agent-aware:

- `.editor(filePath, fileName, workspaceName)` when focus is in a pane —
  captured by `EditorAdapter.captureLocator` via `AX.documentPath()` /
  `EditorWindowTitle.parse()`. Routed `.appSpecific` (`IntegrationRouter`), so
  status comes from the generic AI `Classifier` reading window AX text, which
  exposes the chat pane only incidentally and mixes code + chat → fragile,
  often-wrong verdicts. Refocus opens a *file*, not the conversation.
- `.shell(tty)` when focus is in Cursor's integrated terminal — status driven by
  *Claude/Codex* hooks firing inside that terminal; Cursor's own agent
  contributes nothing.

Cursor is no longer a file editor first. Its primary surface is the
**Composer/agent chat pane**. `AXDocument` is stale or points at an incidental
file; title parsing yields "Cursor — Untitled"; the drop has no session id,
`contentURL`, or deep link. There's a half-recognized third identity —
`cursor-agent` the CLI is named in `AgentCommand.agentName()` → "Cursor Agent" —
but nothing consumes it: no `/cursor` endpoint, no `CursorIntegration`, no
mapper, no binding.

We want Cursor promoted to a **first-class agent integration** alongside Claude
Code and Codex: a Cursor drop tracks the active agent conversation through
**working → done → needs-attention**, from event-driven ground truth, not AX
guessing.

## Key facts that determine the approach (verified)

- **Cursor ships a hooks system** (`~/.cursor/hooks.json`, `version: 1`). Agent
  hooks **fire inside the desktop GUI app**, not only the CLI. Relevant events:
  `beforeSubmitPrompt`, `preToolUse` / `postToolUse`, `afterAgentResponse`,
  `stop` (payload carries `status`: completed/aborted/error), `sessionStart` /
  `sessionEnd`, and permission hooks (`beforeShellExecution` /
  `beforeMCPExecution` / `beforeReadFile` with `permission: "ask"`). Each payload
  carries `conversation_id`, `generation_id`, and `workspace_roots`.
- **Cursor's chat history lives in an opaque SQLite DB**
  (`~/Library/Application Support/Cursor/User/globalStorage`), **not** readable
  per-session JSONL like `~/.claude/projects` or `~/.codex/sessions`. So the
  Codex-style "poll a session journal" approach is **not available**.
- AX/screen classification of the GUI is fragile — the same lesson already
  learned with Chrome (the window AX text is chrome/tab-strip, not the
  conversation).
- On this machine: `Cursor.app` installed (`com.todesktop.230313mzl4w4u92`),
  `cursor-agent` CLI **not** on PATH (GUI is the surface), no `hooks.json` yet.

**Conclusion:** hooks are the *only* clean, low-latency source for Cursor GUI
agent status, and they map almost one-to-one onto the existing `ClaudeIntegration`
shape. This is the chosen mechanism.

## Decision: full-replace, hook-based agent integration (mirror Claude)

- **Scope = agent only (full replace).** Every Cursor drop tracks the active
  Composer/agent conversation. The old editor-file treatment for Cursor is
  removed. **VS Code / Insiders / VSCodium stay untouched** as editors.
- **Mechanism = install-based hooks**, mirroring `ClaudeIntegration` (which
  writes `~/.claude/settings.json`). Because Cursor emits nothing until
  `~/.cursor/hooks.json` registers our script, this is an **"Install" button**
  integration like Claude, not a passive toggle like Codex.
- **`cursor-agent` CLI-in-a-terminal comes along for free** — the same hook
  script forwards the same events; a CLI session has a real controlling TTY, so
  it binds by TTY exactly like a Claude terminal session, while the GUI (TTY
  `??`) binds by `conversation_id`.

## Architecture — the pipeline (a fork of the Claude template)

```
Cursor.app agent  ──fires hook──▶  ~/.config/superisland/superisland-cursor-hook.sh
                                          │  curl -sf POST  (stdin JSON, fire-and-forget)
                                          ▼
              ShellServer   /cursor?tty=…  ──▶  onCursorEvent → CursorHookEvent
                                          ▼
              AppController.handleCursorHookEvent   (bind event → drop)
                                          ▼
              CursorHookMapper.update  →  (DropStatus?, reason)  →  DropStore
```

- **Install** (`CursorIntegration.install()`): write
  `~/.config/superisland/superisland-cursor-hook.sh` (0755), then register it in
  `~/.cursor/hooks.json` via a new `CursorHooksConfigurator`. Cursor's schema is
  `{ "version": 1, "hooks": { "<event>": [ { "command": "<path>", "type":
  "command" } ] } }` — different enough from Claude's `settings.json` to need its
  own configurator, but the same **merge-and-preserve-user-hooks** /
  **remove-only-ours-by-path-marker** semantics as `ClaudeHooksConfigurator`.
- **Events registered** (minimal, observational): `beforeSubmitPrompt`,
  `preToolUse`, `afterAgentResponse`, `stop`, `sessionEnd`. We register **only
  agent-chat events** — never Tab/inline-completion hooks — so editing never
  creates drops. **Our hooks return no permission decision** (purely
  observational); they never change how Cursor itself behaves.
- **Hook script** is the Claude pattern verbatim: derive `$TTY` from
  `ps -o tty= -p $PPID` (real for CLI, `??` for GUI), forward stdin JSON to
  `http://localhost:<ShellServer.port>/cursor?tty=$TTY`, `exit 0`.
- **ShellServer** gains a `/cursor` route + `onCursorEvent` decoding
  `CursorHookEvent`, filling TTY from the query param — the existing `/codex`
  plumbing is the exact template.

## Drop identity & binding (the one genuinely new problem)

Claude binds terminal sessions by **TTY**; the Cursor *GUI* has no TTY. Cursor
payloads instead carry **`conversation_id`** + **`workspace_roots`**.

- SuperIsland keeps a live in-memory **conversation index**
  `conversation_id → { workspace, lastEventAt, lastStatus }`, fed by the event
  stream — the analogue of Codex's session index.
- **At drop time** (`CursorAdapter.captureLocator`, Cursor.app frontmost): read
  the frontmost window's workspace (AX title → `EditorWindowTitle.parse`
  workspace segment, falling back to `~/.cursor/ide_state.json`), then bind to
  the **most-recently-active conversation in that workspace**. Stamp
  `contentURL = "cursor://session/<conversation_id>"` via a new `CursorDeepLink`
  (mirrors `CodexDeepLink` / `codex://session/<id>`), so `DropIdentity.sameTarget()`
  gives one-drop-per-conversation dedup for free.
- **Cold start** (dropped before any event this session — e.g. Cursor just
  opened): create the drop `.unknown`, provisionally workspace-bound; the first
  `beforeSubmitPrompt` for that workspace **adopts** the drop and stamps the
  `conversation_id`. Same adoption pattern Claude uses for idle terminal
  sessions (`ClaudeTerminalSession.adoptsColdStartSeed`).
- **Refocus on click**: front Cursor.app + the workspace. Cursor exposes no known
  public deep link to a *specific* conversation tab, so refocus degrades
  gracefully to "front the app" — a documented limitation, not a blocker.
  (Verify whether a `cursor://` scheme can target a conversation; upgrade if so.)

## Status mapping (`CursorHookMapper`)

| Hook event | Status / action |
|---|---|
| `beforeSubmitPrompt` | `.working` — "Cursor is working…"; set label from the prompt via `AgentSessionLabel.label(agent: "Cursor", prompt:)` |
| `preToolUse` | keep `.working`, refresh liveness timestamp |
| `afterAgentResponse` | stash the assistant message text (the turn may continue) |
| `stop` `completed` | **classify the stashed message** with the existing turn-end classifier (Haiku via `BackendConfig.classifyURL`, structural fallback) → `.done` ("ready for you") or `.needsAttention` ("Cursor is waiting for your reply") |
| `stop` `aborted` / `error` | `.done` / `.needsAttention` with the error reason |
| `sessionEnd` | mark `.stale` / release the binding |

This gives Cursor the **same "done vs. waiting on you" intelligence as Claude**
by reusing the turn-end classifier. Because Cursor's `stop` payload carries only
`status` (no final text), we capture the message from `afterAgentResponse`. The
reusable classification (currently `ClaudeIntegration.classifyFinalMessage`)
should be **extracted into a small shared helper** rather than duplicated.

Permission-blocked-on-approval is a *weak* observational signal (whether Cursor
pauses depends on the user's auto-run config, which hooks don't expose), so
**turn-end classification is the primary needs-attention path** — exactly as it
is for Claude. A future refinement could use the permission hooks for a
mid-turn stall, but it is out of scope here.

## Decoupling Cursor from `EditorApp` (the "split")

Every location coupling Cursor to VS Code, and what it becomes:

| File:symbol | Change |
|---|---|
| `AgentTerminalSupport.swift:208` `EditorApp.cursor` | Remove Cursor from `EditorApp.bundleIDs` / `displayName`; move the bundle id to `CursorDeepLink.bundleID`. Cursor is no longer "an editor". |
| `SupportedApps.swift:33,54,83` | Cursor's allowlist entry, `displayName`, and `RequiredIntegration` move from `.shell` to a **new `.cursor` case** (+ `setupMessage`). |
| `IntegrationRouter.swift:22` | Cursor routes `.strong` (hook is ground truth, AI monitor blind), not `.appSpecific`. |
| `Adapters.swift:331,340+` | Cursor leaves `EditorAdapter.canHandle`; a new **`CursorAdapter`** captures the agent locator + `contentURL`. |
| `DropSource.swift:49` | Split Cursor out of the `curlybraces` case → a distinct **"Cursor"** agent badge + icon. |
| `Models.swift:62` | `Locator.editor` doc → VS Code only; add `CursorDeepLink`. **Mirror Codex's desktop session-drop binding** — the same `Locator` kind Codex uses for a `codex://session/<id>` drop, carrying the `cursor://session/<id>` `contentURL`. Add a dedicated locator case only if Codex's doesn't fit; do not invent a parallel mechanism. |
| `Classifier.swift:65,69` | Tighten the system prompt now that Cursor is hook-owned, not AI-classified. |

## New code surface

- **New** `Sources/SuperIslandApp/CursorIntegration.swift` — `@MainActor
  ObservableObject`, `@Published isInstalled`, `install()` / `uninstall()` /
  `refresh()` / `reconcile()`. A fork of `ClaudeIntegration`.
- **New** core (pure, AppKit-free, unit-testable):
  - `CursorHooksConfigurator` — install/uninstall/isInstalled over Cursor's
    `hooks.json` schema, preserving user hooks.
  - `CursorHookEvent` — decode the stdin JSON (`conversation_id`,
    `workspace_roots`, event name, `stop.status`, `afterAgentResponse` text).
  - `CursorHookMapper` — event → `(DropStatus?, reason)` per the table above.
  - `CursorDeepLink` — `bundleID`, `sessionURLPrefix = "cursor://session/"`.
- `ShellServer.swift` — `/cursor` route + `onCursorEvent`.
- `AppController.swift` — instantiate `cursorIntegration`; wire
  `handleCursorHookEvent`; maintain the conversation index; extend
  `isExternallyManaged` to cover `cursor://session/` drops.
- Shared: extract the turn-end final-message classifier into a helper used by
  both Claude and Cursor.

## UI wiring (identical to the existing four integrations)

A fifth integration row/card + env-object:

- `SuperIslandApp.swift` + `Onboarding/OnboardingWindow.swift` —
  `.environmentObject(controller.cursorIntegration)`.
- `Onboarding/OnboardingView.swift` `IntegrationsStepView` — `@EnvironmentObject`
  + a fifth `IntegrationRow` (with an "Install" action, like Claude).
- `SettingsPanes.swift` `IntegrationsSettingsPane` — `@EnvironmentObject` + a
  `cursorCard` (Install / Uninstall).

## Verification (do first, de-risks the decoder)

1. **Capture the live hook JSON.** Install a throwaway hook that appends stdin to
   a log file for `beforeSubmitPrompt`, `afterAgentResponse`, and `stop`; submit
   one prompt in the installed Cursor; inspect the captured payloads. This pins
   the exact field spelling (`conversation_id` vs `conversationId`,
   `workspace_roots` shape, `stop.status` values, where the assistant text
   lives) **before** building `CursorHookEvent`.
2. **Confirm GUI firing** for this Cursor version (hooks are beta).
3. **Check for a `cursor://` deep link** that can target a conversation; if it
   exists, upgrade refocus from front-the-app to front-the-conversation.

## Testing

Lean on the repo's pure-core convention:

- `CursorHookEvent` decoding — each event's payload → typed event; tolerate
  missing/extra fields.
- `CursorHookMapper` — every row of the status table, including `stop`
  completed/aborted/error and the cold-start adoption path.
- `CursorDeepLink` — prefix/round-trip; `DropIdentity.sameTarget()` dedup for two
  events on the same `conversation_id`.
- `SupportedApps` / `RequiredIntegration` re-mapping — Cursor now resolves to
  `.cursor`, not `.shell`; VS Code still `.shell`.
- `CursorHooksConfigurator` — install merges into existing `hooks.json`,
  uninstall removes only our entries, `isInstalled` round-trips.
- `ShellServer` `/cursor` — POST sample payloads, assert `onCursorEvent` fires
  with correct decode + TTY from the query param.

## Risks

1. **Cursor hooks are beta.** Field names/availability vary by version.
   Mitigated by the capture-live-JSON verification step and a lenient decoder.
2. **No per-conversation refocus** without a `cursor://` deep link — front-the-app
   fallback. Acceptable; upgradeable.
3. **Multiple agent tabs per workspace** — the recency heuristic picks the last
   active conversation for an ambiguous workspace drop. Status is still precise
   per `conversation_id`; only the *initial bind* uses recency.
4. **hooks.json ownership** — must preserve existing user hooks and remove only
   ours (path-marker keyed), same discipline as `ClaudeHooksConfigurator`.
5. **Classifier quota** — turn-end classification shares the existing daily
   quota (`ClassifierError.quotaExceeded`), already handled; structural fallback
   covers exhaustion.

## Out of scope (YAGNI)

AX/screen classification of the Cursor GUI; SQLite session-journal polling;
hook output that alters Cursor's permission prompts; per-conversation deep-link
refocus (unless it already exists); cloud / background-agent tracking.
