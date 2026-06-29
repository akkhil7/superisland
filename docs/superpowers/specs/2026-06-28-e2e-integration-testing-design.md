# SuperIsland — Comprehensive E2E / Integration Testing Design

- **Date:** 2026-06-28
- **Status:** Draft, awaiting sign-off on the test-case catalog
- **Branch context:** authored alongside `feat/cursor-agent-integration`

## Goal

A comprehensive, CI-runnable testing solution that exercises **all** SuperIsland integrations
(Chrome, Claude Code hooks, Codex, Shell, Cursor, and the Supabase backend) end-to-end at the
highest fidelity that can run automatically, plus a real-app layer for the parts that
fundamentally need a real Mac. The deliverable the owner signs off on **first** is the
per-integration test-case catalog below.

## Why this shape (the macOS constraint)

A native macOS app cannot run in a Docker/`apple/container` container (those are Linux). The
GUI integrations (Chrome native messaging, Accessibility/ScreenCaptureKit/AppleScript, the
global hotkey, the Cursor/Codex desktop agents) need a real macOS GUI session with TCC
permissions pre-granted — which GitHub-hosted runners cannot provide. The macOS-testing
consensus for OS-heavy apps is the "humble object" pattern: push logic out of the untestable
shell into pure modules (SuperIslandCore already does this — 35 XCTest files), black-box the
seams, and keep a thin real-GUI smoke layer on a real Mac. This design applies exactly that.

## Architecture — three test tiers

| Tier | What it tests | Where it runs | Cadence | Containerizable? |
|---|---|---|---|---|
| **T1 — Seam/contract** | Real Swift glue against *simulated* peers: boot the real in-process `ShellServer`/`ChromeBridgeServer` on an ephemeral port and POST recorded payloads; run the real native-host binary as a subprocess via piped stdin; run `install()`/`uninstall()` against a temp `$HOME`; deep-link routing; file parsing against committed fixtures | GitHub `macos-15` (headless) | **Every PR** | No (no macOS containers) — but runs headless, no GUI/TCC needed |
| **T2 — Backend** | `classify` edge function (Deno) + quota/RLS (`pgTAP`) against a real Postgres + edge runtime | `ubuntu-latest` via `supabase start` (containerized) | **Every PR** | **Yes** |
| **T3 — Real-app** | Real Chrome+extension, real Claude/Codex/Cursor CLIs firing real hooks, real OAuth → observe real drop status | Local Mac now; self-hosted runner/VM later (workflow file checked in, flip `runs-on:`) | Manual / nightly | No — needs real macOS GUI + TCC |

## Decisions locked

- **Both layers** (T1+T2 on every PR; T3 manual/nightly).
- **Real-app host:** local dev scripts + a checked-in `e2e-real.yml` (one-line `runs-on:` flip to a self-hosted/VM Mac later). Zero infra to maintain now.
- **New tests use the Swift Testing framework** (`@Test`/`#expect`), coexisting with the existing XCTest files.
- **New `SuperIslandAppTests` target** added to `Package.swift` (the App + ChromeNativeHost targets have none today).
- **Committed, PII-scrubbed fixtures library** of recorded-real payloads as golden files.
- **T2 runs on `ubuntu-latest`** (Docker is native there; decouples from scarce macOS runners), always against the **local/containerized** Supabase stack, never the cloud project.
- **Production-code test seams are in scope** (this is not tests-only): injectable ports on both servers, `SUPERISLAND_BRIDGE_URL` in the native host, injectable `$HOME`/base-URLs on the installers, extracted AppController hook→store handlers, and BackendConfig/Keychain seams. These are small, low-risk DI changes that unlock essentially all of Tier 1.
- **The single-`receive()` caps are fixed, not just documented:** `ChromeBridgeServer.accept` (64KB) and `ShellServer.accept` (256KB) will loop until `Content-Length`, and the affected cases (CHR-T1-05, CLA-T1-10, SHL-T1-15, CUR-T1-12) assert *correct* full-body receipt rather than current drop behavior.
- **Cursor is built in this effort via TDD on `ShellServer`:** the CUR-T1 specs are written first (red), then `CursorIntegration` + a `/cursor` dispatch branch + `onCursorEvent` are built on the 2929 ShellServer (mirroring the existing `/claude` and `/codex` hook routes). This completes the `feat/cursor-agent-integration` branch.

---

## Harness & fixtures to build

**Shared helpers (new `SuperIslandAppTests` target, Swift Testing):**

- **TempHomeSandbox** — unique temp dir; redirects `$HOME` (and an injected Application Support base URL) for the test's duration; recursive teardown even on throw. *Prerequisite:* confirm `FileManager.url(for:.applicationSupportDirectory)` honors a redirected HOME, or add a base-URL injection point to `DropStore.defaultFileURL` and each integration (see XCUT-T1-18).
- **EphemeralServerHarness** — boots real `ShellServer` / `ChromeBridgeServer` on OS-assigned port 0, exposes the bound port, waits for `.ready` before the first request, fully cancels on teardown. *Prerequisite:* `init(port:)` + bound-port readback on both servers (today hardcoded 2929/2931).
- **LocalHTTPClient** — POST-with-deadline (mirrors the hook `curl -sf -m 2`); returns status/body/timeout-flag for deterministic latency assertions.
- **NativeHostDriver** — launches the built `SuperIslandChromeNativeHost` as a `Process` with piped stdio; writes 4-byte LE length + JSON; reads the framed reply with a deadline (fails, never hangs). *Prerequisite:* `SUPERISLAND_BRIDGE_URL` env override in `main.swift` (bridge URL is a hardcoded top-level `let`).
- **StubBridge** — in-process HTTP responder the native host is aimed at; records call count + body.
- **FixturesLoader** — loads committed PII-scrubbed payloads from `Bundle.module` by stable name; **fails loudly** on a missing fixture; PII-scrub guard + golden checksum.
- **DropStoreFactory** — builds a `DropStore` on a sandbox file, seeded with Claude/Codex/Cursor/shell drops.
- **AppController handler extraction** — extract `handleClaudeHookEvent` / `handleChromeTabEvent` / `handleShellEvent` (currently on the `@MainActor` AppController, GUI/auth/hotkey-bound) into a small testable type, or wire `onClaudeEvent`/`onTabState`/`onEvent` directly to a bare DropStore+mapper.
- **BackendConfig/Keychain seams** — injectable `tokenURL`/`classifyURL` override (or `URLProtocol` stub) + a keychain-store protocol for a headless `AuthService`.

**Fixtures library** (`Tests/Fixtures/`, shared by the Swift target and T2):
- *chrome/* `tab_state.{claude.valid,disallowed_host,userinfo_trick,large_dom,multi_tab_a,multi_tab_b,multi_tab_a_v2}.json`, `event.command_poll.json`, `toolcall.{list_tabs,capture_active,dom_summary,refocus_tab,get_status,observe,unsupported_tool}.json`, `frame.{length_zero,length_oversized_header,truncated_body}.bin`, `http.no_separator.bin`, `body.{garbage.txt,unknown_shape.json}`, `foreign_native_host.json`, `stale_superisland_manifest.json`.
- *claude/* `hook-{userpromptsubmit,pretooluse,posttooluse,stop,stopfailure,notification-permission,notification-idle,notification-authsuccess,notification-waiting-untyped,sessionend,malformed.bin,missing-sessionid,unknown-event}.json`, `settings-{with-user-hooks,partial-managed-events,malformed}.json`, `transcript-{tool-pending,turn-ended-question,turn-ended-statement}.jsonl`, `local_session-{valid,missing-clisessionid,nested/local_other}.json`.
- *codex/* rollout tails (task_complete / task_started / approval / turn_aborted / partial-tail / >64KB / >512KB-head), `session_index.jsonl` (rename + dup id), `.codex-global-state.json` (active-workspace-roots), non-rollout decoys.
- *shell/* recorded `/shell` register/start/done frames incl. quotes+backslash+newline, oversized cmd, missing exit_code, two-TTY interleaved.
- *cursor/* `{beforeSubmitPrompt,afterAgentResponse,stop-completed,stop-error,stop-aborted,sessionEnd,malformed,oversized,unicode-prompt,missing-conversation_id}.json`, hooks.json fixtures (empty/user-only/already-ours/partial-ours/malformed).
- *supabase/* recorded Anthropic Messages success body, `/auth/v1/token` success body, oversized classify request body, `classify_request.json`.
- *cross-cutting/* `drops_with_duplicate_session.json`, `all_committed_fixtures` golden manifest.

---

## Coverage summary

| Integration | T1 | T2 | T3 | Biggest gap closed |
|---|---|---|---|---|
| Chrome | 18 | – | 1 | Native-host subprocess framing + allowlist trust boundary (host *and* server), exposes 64KB single-receive defect |
| Claude | 20 | 3 | 2 | On-disk settings.json merge/migrate/preserve + live `/claude` decode→tty→mapper + cold-start transcript backfill |
| Codex | 18 | 1 | 2 | mtime-gated tail reads, workspace-scoped session binding, stale `rolloutPaths` non-clearing, cold-start robustness |
| Shell | 20 | – | 1 | RC-block surgery (preserve/idempotent/concurrent), executed-script JSON sanitization + curl `-m` timeout |
| Cursor | 16 | 1 | 2 | TDD specs gating CursorIntegration + `/cursor` route; route-prefix collision |
| Supabase backend | 9 | 17 | 2 | classify handler branches incl. 401 auth fail-closed, atomic quota + RLS read/write, client HTTP mapping, PKCE deep-link exchange/refresh |
| Cross-cutting | 13 + 4 CI | – | – | Shared harness guarantees, server→mapper→DropStore pipeline, HOME-isolation proof, fixtures determinism, CI wiring |

---

## Chrome

### T1
- **CHR-T1-01 — Valid tab_state round-trips host→bridge→stored→framed reply** (none). Host subprocess + bridge on ephemeral port; allowlisted tab_state frame → host POSTs `/chrome`, server stores tab + returns `{ok:true,commands:[]}`, host writes that JSON back framed. *Assert:* store has the tab; `onTabState` fires once; `isConnected` true. *Gate: `SUPERISLAND_BRIDGE_URL` + injectable port.*
- **CHR-T1-02 — Disallowed host dropped early by native host (no round-trip)** (none). Non-allowlisted tab_state → `hasDisallowedHost()` short-circuits, reply `{ok:false,error:'rejected: host not allowlisted'}`, **zero** bridge requests.
- **CHR-T1-02b — Host loops after rejection/unreachable; next valid frame still forwarded** (none). rejected frame → unreachable-forward frame → valid frame on the same stdin; stream not desynced, final valid frame **is** forwarded (only `readNativeMessage()==nil` ends the loop).
- **CHR-T1-03 — Bridge re-checks allowlist independently of host** (none). Disallowed-host body POSTed directly to `/chrome` → rejection, store unchanged, `onTabState` not fired, `lastSeenAt` not advanced.
- **CHR-T1-04 — Native host rejects malformed/oversized frames without forwarding** (none). length=0, length≥4MiB, truncated-body+EOF → `readNativeMessage` returns nil, no forward, no huge alloc, loop exits cleanly.
- **CHR-T1-04b — Length-prefix endianness round-trips on the built binary** (none). Host reads LE prefix written by the driver and writes a header the driver reads as LE. *Guards arch/codec drift.*
- **CHR-T1-05 — Oversized-but-wellformed body exposes 64KB single-receive defect** (none, *defect*). ~200KB valid tab_state forwards but `ChromeBridgeServer.accept` does one `receive(max:64KB)` and **drops** bodies past that. *Assert current behavior + file the fix.*
- **CHR-T1-06 — command_poll drains queued refocus exactly once** (partial). poll #1 returns the command, #2 returns empty; no host allowlist check (no tab field).
- **CHR-T1-07 — tools/call JSON-RPC round-trips for every ChromeBridgeTool** (partial). Each tool-call body decoded as ToolCall first; listTabs sorted, capture/getStatus from seed, refocus enqueues, JSON-RPC id (string+number) preserved.
- **CHR-T1-08 — Malformed/unknown body returns structured error, no state change** (none). garbage / unknown-shape / unsupported-tool → 200 with `ok:false` + non-nil error; unsupported tool rejected at decode (before the `ChromeBridgeTool(rawValue:)!` force-unwrap).
- **CHR-T1-09 — Malformed HTTP framing (no CRLFCRLF) ignored without crash** (none). TCP payload with no header separator → `accept()` returns early, no state change; a following valid request still returns `ok:true`.
- **CHR-T1-10 — Manifest install: pinned, both-ID, only into existing browser dirs, idempotent** (partial). Sandbox HOME with only Chrome → manifest only into Chrome (not absent Canary/Brave), both store+dev origins, name+path correct; second install byte-identical (atomic). *Gate: injectable Application Support base.*
- **CHR-T1-11 — Uninstall removes only our manifest, preserves foreign** (none). our + `com.someoneelse.host.json` → only ours gone, foreign byte-unchanged, `isNativeHostInstalled` false.
- **CHR-T1-12 — Reinstall over stale manifest heals to current pinned content** (none). Stale single-ID/old-path manifest → upgraded to both-ID + current path, full replace.
- **CHR-T1-13 — isConnected tracks lastSeenAt; only accepted events refresh it** (partial). valid event → true within 10s; after 10s → false; a rejected event does **not** refresh the window.
- **CHR-T1-14 — Port-in-use: second server fails gracefully** (none). server A on a chosen port; B starts on it → B doesn't crash (`try?` NWListener), A keeps answering. *`allowLocalEndpointReuse=true` → assert observed; run serially.*
- **CHR-T1-15 — Concurrent multi-tab frames update distinct entries (last-write-wins)** (none). N distinct-tabId frames + one duplicate-tabId-with-newer-status → one entry per tabId, duplicate overwritten, `listTabs` sorted, no interleave corruption.
- **CHR-T1-16 — Forward timeout: host returns reachability error when bridge down** (none). No bridge; allowlisted frame → host writes `{ok:false,error:'SuperIsland app is not reachable'}` after its wait, ≤5s bound, loop continues. *Gate: injectable host timeout.*
- **CHR-T1-17 — Cross-impl allowlist parity in pure Swift** (none). Swift `ChromeHostAllowlist.hosts` set vs `Extensions/Chrome/providers.js` `ALLOWED_HOSTS` parsed from disk as text → equal (no host gated on only one side). *Re-scoped off Jest to stay in the swift-test job.*
- **CHR-T1-18 — providers.js detector classification (separate Node job, optional)** (none, gated). `providerForHost`/`isExcluded`/`pathLooksLikeGeneration` over recorded URLs. *Runs only if a Node+Jest CI job is approved; otherwise omit (parity covered by CHR-T1-17).*

### T3
- **CHR-T3-01 — Real Chrome + loaded extension reaches app, reports real tab status** (none). Real generation on an allowlisted provider → store working→done, `isBridgeConnected` true. *Validates the connectNative handshake/manifest pinning T1 can't fake.*
- *(CHR-T3-02 Playwright smoke dropped — Playwright not in toolchain.)*

---

## Claude

### T1 — install/uninstall/reconcile (*gate: injectable scriptPath/settingsPath/sessionsDir or HOME override*)
- **CLA-T1-01 — install() writes hook script at 0755** (none). File exists, perms `0o755`, body has `POST … /claude?tty=$SUPERISLAND_TTY` + `curl -sf -m 2`, parent dir created.
- **CLA-T1-02 — install() merges into existing settings.json without clobbering user hooks** (partial). settings.json with user PreToolUse + unmanaged PreCompact + top-level model/env → re-read valid, all 7 managed events own our entry, user PreToolUse/PreCompact survive, model/env preserved.
- **CLA-T1-02b — install() over a MALFORMED settings.json does not silently destroy user content** (none, *data-loss*). Non-JSON / top-level-array / JSONC (`readSettings()` returns `[:]` on parse failure) → install must **not** overwrite with only our entries. *Assert abort/back-up.*
- **CLA-T1-03 — Re-install idempotent on disk** (partial). Exactly one superisland entry per managed event, no array growth, script still 0755, `isInstalled()` true.
- **CLA-T1-04 — uninstall() removes only our entries + script, prunes empty events** (partial). Script deleted, no superisland command anywhere, user PreToolUse/Stop intact, ours-only events dropped, JSON valid.
- **CLA-T1-05 — uninstall() with no settings.json doesn't crash** (none). Script present, settings absent → no throw, script removed, `isInstalled()` false.
- **CLA-T1-06 — reconcile() backfills newly-managed events when opted-in; no-op when script absent** (none). Script + subset of events → all 7 covered; script absent → settings unchanged, no script created.
- **CLA-T1-06b — reconcile()/install() never PRUNES a now-unmanaged event (downgrade gap)** (none, *migration*). superisland entry under an event dropped from the managed set → assert current behavior (orphan remains) and decide cleanup.

### T1 — live `/claude` server (*gate: injectable port; handler reachable without full AppController*)
- **CLA-T1-07 — Live `/claude` decodes payload + fills tty, fires onClaudeEvent** (none). Fixture POSTed to `/claude?tty=ttys003` → `onClaudeEvent` once on main queue, `event.tty=/dev/ttys003` (from query), HTTP 200, mapper→`.working`.
- **CLA-T1-08 — All lifecycle events map to expected drop status (server-decode→mapper table)** (partial). One fixture per event: UserPromptSubmit/PreToolUse/PostToolUse→working, Stop→done, StopFailure→needsAttention, Notification(permission/idle/auth_success)→needsAttention/done/nil, SessionEnd→nil.
- **CLA-T1-09 — Malformed/unknown-event payloads dropped without firing/crash** (none). bad JSON → no callback, 200; missing session_id → decode fails; unknown hook_event_name → callback fires, mapper nil; server still responsive.
- **CLA-T1-10 — 256KB single-receive boundary: 200KB prompt accepted; >256KB fails gracefully** (none, *defect-aware*). One bounded `receive(max:256KB)` → ~200KB decodes; >256KB or segment-split → no crash, no fire, server serves next.
- **CLA-T1-11 — tty query edge cases normalize through the server** (partial). no tty→nil, `??`→nil, `ttys004`→`/dev/ttys004`, `%2Fdev%2Fttys005`→`/dev/ttys005`.
- **CLA-T1-12 — Two concurrent `/claude` POSTs retain per-connection tty** (none). ttys001 + ttys009 on separate connections → exactly 2 callbacks, each its own tty, no cross-contamination.
- **CLA-T1-13 — Hook script vs live/absent/slow server (curl -m 2)** (none). live → received, exit 0 fast; no listener → exit 0 <500ms; black-hole listener → exit 0 within ≥~2s bound, never hangs/nonzero. *Gate: injectable ShellServer port; stub stalling listener.*
- **CLA-T1-13b — Hook script emits the correct tty VALUE via `ps -o tty= -p $PPID`** (none). Controlled `$PPID`/tty → URL query `??` for no controlling tty, `ttysNNN` for a CLI; var quoted. *The only session↔terminal join — untested today.*
- **CLA-T1-14 — ShellServer.start() port-in-use degrades, no crash** (none). second start() on same port → no crash, first still serves.

### T1 — cold-start backfill (*gate: injectable HOME*)
- **CLA-T1-15 — Backfill resolves transcript path from on-disk session metadata + classifies resting state** (none). `local_<id>.json` + matching `.jsonl` → path == `projects/<enc>/<cliSessionId>.jsonl`; tool-pending→working, question(no bearer)→needsAttention, statement→done.
- **CLA-T1-16 — Backfill robustness: missing transcript / malformed session JSON / multiple sessions per cwd** (none). Missing transcript→nil no crash; malformed `local_*.json` skipped; cache keyed by cliSessionID; non-`local_`/non-`.json` ignored; newest transcript chosen.
- **CLA-T1-17 — Cold-start seed gating: only resting states seed** (partial). `adoptsColdStartSeed`: done/needsAttention true, working/unknown/stale false — verified wired into backfill (no sticky `.working`).

### T2 (*gate: BackendConfig URL seam, or test at Deno `handle()` level — preferred*)
- **CLA-T2-01 — classify turns turn-end message into needsAttention/done verdict** (none). asking→needsAttention, finished→done; response shape matches `ClaudeClassifier`.
- **CLA-T2-02 — Quota exceeded → .unknown with limit reason, no crash** (none). Bearer over cap → `ClassifierError.quotaExceeded` → `(.unknown,"Daily limit reached")`; structural fallback **not** used.
- **CLA-T2-03 — Transport error falls back to structural heuristic** (none). Failing/dead classify + bearer → generic catch → `ClaudeTranscript.looksLikeRequest` drives result.

### T3
- **CLA-T3-01 — Real `claude` CLI run drives drop working→done bound to the right TTY** (none). UserPromptSubmit→working, tools→working, Stop→done; drop tty == launching terminal; label from prompt.
- **CLA-T3-02 — Real permission prompt → needsAttention, clears on approval** (none). permission_prompt→needsAttention; approve→PostToolUse→working; bypassPermissions raises none. *Nightly harness snapshots/restores real `~/.claude/settings.json`.*

---

## Codex (*gate: injectable `codexHome` or HOME override; @MainActor harness*)

### T1
- **CDX-T1-01 — statusUpdate tails rollout → working/done/needsAttention** (partial). task_complete→done(reason=last_agent_message), task_started→working, *_approval_request→needsAttention, via real `rolloutFile`+`readTail`+`latestUpdate`.
- **CDX-T1-02 — statusUpdate mtime-gated (nil when unchanged)** (none). 1st non-nil; 2nd (unchanged mtime) nil; 3rd after bumping mtime non-nil again.
- **CDX-T1-03 — statusUpdate detects appended event after mtime advances** (none). working at T0; append task_complete at T0+1 → done.
- **CDX-T1-04 — nil for unknown id and deleted rollout** (none). unknown id→nil; delete cached file→rescan→nil (no stale path).
- **CDX-T1-04b — rescanRollouts never clears stale id→URL; vanished session not returned** (none). Deleted rollout key lingers in `rolloutPaths` → `currentSessionGuess`/`latestRollout` never return it.
- **CDX-T1-05 — rescan enumerates nested y/m/d, accepts only well-formed `rollout-*.jsonl`** (none). Two valid nested rollouts resolve; `notes.jsonl`/`rollout-short.jsonl`/`.txt`/hidden ignored.
- **CDX-T1-06 — currentSessionGuess scopes to active workspace roots, falls back to freshest** (none). roots=[projA] → older projA over newer projB; roots=[] → freshest overall; sibling prefix `projA-v2` doesn't bind to projA.
- **CDX-T1-07 — Freshest in-workspace among same-project threads** (none). Three projA rollouts → max-mtime id; title from session_index.
- **CDX-T1-08 — rolloutCWD reads cwd from large multi-line session_meta head + caches** (partial). cwd parsed from tens-of-KB first line (512KB window); cached even after on-disk cwd changes.
- **CDX-T1-09 — Oversized session_meta head (>512KB) yields no cwd, graceful** (none). truncated mid-line → not valid JSON → excluded → falls back to freshest; no crash.
- **CDX-T1-10 — newestSessionID(modifiedAfter:) binds CLI launch only to fresher rollout** (none). nil when only pre-existing; returns new id once mtime>startedAt; never the stale session.
- **CDX-T1-11 — Truncated/partial-line tail skips bad lines, keeps last valid** (partial). 64KB tail mid-line + interior garbage → working, no crash, reason not from garbage.
- **CDX-T1-12 — Rotation: follows new rollout file** (none). After rotation, statusUpdate resolves the live file via the `fileExists` recheck.
- **CDX-T1-13 — session_index 10s cache serves then refreshes after TTL** (partial). 1st parse caches; mutate within 10s → old name; fresh instance → new; `knownThreadCount` reflects cached count.
- **CDX-T1-13b — First-call refresh + absent index during onboarding** (none). `indexCacheAt` starts distantPast → first call parses; absent index → `knownThreadCount`==0, no re-read storm.
- **CDX-T1-14 — Empty/missing `~/.codex` + missing global-state degrade to nil/0/[]** (none). currentSessionGuess nil, statusUpdate nil, knownThreadCount 0, activeWorkspaceRoots [].
- **CDX-T1-15 — turn_aborted → unknown('Interrupted'), clears prior needsAttention** (partial). last-line-wins tail ending task_started→approval→turn_aborted → `.unknown`/"Interrupted".
- **CDX-T1-16 — Concurrency parity: interleaved currentSessionGuess + statusUpdate never cross-bind** (none). Under `@MainActor`, interleaved calls for several sessions never return a cross-bound id.

### T2
- **CDX-T2-01 — classify categorizes a Codex thread payload** (none, *drop-candidate*). Valid→200 schema, oversized/empty→4xx, quota decremented. **Drop if Codex titles/summaries are not sent server-side** (open question) — Codex status is purely local file-watching.

### T3
- **CDX-T3-01 — Real Codex desktop drives working→done on a real drop** (none). working during turn, done at task_complete, label=thread_name, `codex://threads/<id>` opens the exact thread.
- **CDX-T3-02 — Real `codex` CLI launch in a dropped terminal binds to its new session** (none). startedAt recorded; launch journals new rollout → contentURL `codex://session/<id>`; no bind if another command takes over first. *Validates the 4s/5-attempt retry timing.*

---

## Shell (*gate: injectable home/port; never run install against real `$HOME`*)

### T1 — installer surgery
- **SHL-T1-01 — install() writes scripts + sources block into all three RC files once** (none). `.config/superisland/superisland.{zsh,bash}` exist at 0o644; `.zshrc` one zsh block, `.bashrc`+`.bash_profile` one bash block each; content == builder output at `ShellServer.port`.
- **SHL-T1-01b — Generated-and-written scripts pass `zsh -n` / `bash -n`** (none). The files actually written by install() (at the resolved port) parse under the real interpreters. *Guards port/interpolation regressions.*
- **SHL-T1-02 — install() idempotent — no duplicate source block** (none). Second install → exactly 1 block per RC, scripts rewritten valid, no dup headers.
- **SHL-T1-02b — Concurrent install() calls don't lose each other's block (read-modify-write race)** (none). Two near-simultaneous installs against the same `.zshrc` → both blocks survive (or document the lost-update race). `appendSourceLine` is non-atomic.
- **SHL-T1-03 — install() PRESERVES user RC content, append-only** (none). Every original line intact, block appended after.
- **SHL-T1-04 — uninstall() removes only our block + scripts, leaves user content** (none). Scripts gone, no block/source line, user content byte-identical, `isInstalled` false, `activeSessions` 0.
- **SHL-T1-04b — uninstall() when user edited inside our block (exact-string mismatch)** (none, *migration*). On-disk block drifted → exact-string replace no longer matches → assert stale-source-line behavior and decide marker-delimited removal.
- **SHL-T1-05 — uninstall() on never/partially-installed HOME is a clean no-op** (none). Missing scripts don't crash; user content unchanged.

### T1 — executed scripts → stub collector
- **SHL-T1-06 — Executed zsh fires register on source, start+done with correct exit/duration** (none). Source with `__drop_tty`/`__drop_port`=stub; `__drop_preexec` then `__drop_precmd($?=0)` → register, start(cmd≤120), done(exit 0, numeric duration); all decodable as ShellEvent.
- **SHL-T1-07 — Nonzero exit reported** (none). precmd with `$?=7` → done `exit_code:7` → `.needsAttention`. *Pins precmd grabbing `$?` first line.*
- **SHL-T1-08 — JSON-sanitizes quotes/backslashes/newlines** (none). `git commit -m "fix: a\"b"` w/ newline → start body valid JSON, cmd has no raw `"`/`\`/newline. *Most likely real-world breakage.*
- **SHL-T1-09 — Truncates oversized command to 120 chars** (none). 500-char cmd → emitted cmd ≤120, body valid (zsh `${c[1,120]}` / bash `${c:0:120}`).
- **SHL-T1-10 — Agent CLI launch carried verbatim for agent routing** (partial). `claude --resume`→"Claude Code", `codex exec`→"Codex", `cursor-agent`→"Cursor Agent", `npm run build`→nil, `/usr/local/bin/claude`→detected.
- **SHL-T1-16 — curl -m 1 timeout: hung server doesn't block the prompt** (none). Black-hole listener; `__drop_preexec` returns promptly (backgrounded curl), foreground cmd unaffected, no zombie.
- **SHL-T1-17 — bash: no double-install on re-source; skips internal commands; dedups identical** (none). Second source no-ops; preexec emits nothing for `__drop_*`/trap/local/PROMPT_COMMAND; same cmd twice → one start; existing PROMPT_COMMAND preserved.
- **SHL-T1-19 — Injected port == ShellServer.port (config coherence)** (partial). Script `__drop_port` == `ShellServer.port`; an executed script reaches a server bound there.

### T1 — server routing/decode (*gate: injectable port*)
- **SHL-T1-11 — Two concurrent TTYs grouped independently** (none). Interleaved register/start/done for ttys001 + ttys002 → both in `registeredTTYs`, correct tty per event, no cross-talk.
- **SHL-T1-12 — dispatch routes `/shell` vs `/claude` vs `/codex`; prefix behavior documented** (none). Each path fires only its callback once; tty from query applied to hook events; document `hasPrefix` for `/shellfoo`/`/claudex`.
- **SHL-T1-13 — Malformed/partial/wrong-CT bodies rejected without firing/crash** (none). bad JSON / missing fields / no CRLFCRLF / empty → no callback, server alive, `registeredTTYs` unchanged.
- **SHL-T1-14 — done without exit_code/duration → nil optionals** (none). `exitCode==nil`,`duration==nil`; AppController maps nil exit via `?? 1` → needsAttention.
- **SHL-T1-15 — 256KB single-receive boundary characterized** (none, *defect-aware*). ~200KB single-segment valid → fires; segment-split → fully read or cleanly dropped. Record limitation.
- **SHL-T1-18 — start() port-in-use fails silently — characterize + flag gap** (none). Second start() → listener nil, no crash, no traffic stolen.

### T3
- **SHL-T3-01 — Real interactive zsh & bash fire register/start/done** (none). New interactive shell → `activeSessions` increments; `sleep 1; false` → drop working→needsAttention, duration ~1s; bash via DEBUG trap + PROMPT_COMMAND. *Nightly: snapshot/restore real RC; genuinely interactive.*

---

## Cursor

> **CUR-T1-00 — Feasibility guard (RED until built)** (none). Confirmed: no `CursorIntegration.swift`; `ShellServer.dispatch` has only `/claude` + `/codex`; no `onCursorEvent`. **All CUR-T1-01..15 are TDD specs that GATE building (a) CursorIntegration mirroring ClaudeIntegration with an injectable config dir, (b) a `/cursor` dispatch branch + `onCursorEvent`.** Fails loudly until the route exists. *Resolve first: which server hosts `/cursor` (2929 ShellServer vs 2931 ChromeBridgeServer)?*

### T1 — installer (*gate: injectable home*)
- **CUR-T1-01 — Installer writes hook (0755) + merges into fresh hooks.json** (none). script 0755; `hooks.json` version 1; one entry per `CursorHooksConfigurator.events`; `isInstalled()` true.
- **CUR-T1-02 — Install preserves a foreign hook entry** (partial). Seeded foreign `stop` → stop has 2 after install, other events 1.
- **CUR-T1-03 — Re-install idempotent (no dup entries)** (partial). Each event one entry with marker `superisland-cursor-hook`; script still executable.
- **CUR-T1-04 — Uninstall removes only ours + deletes script, preserves foreign** (partial). script gone, `isInstalled` false, foreign stop entry remains.
- **CUR-T1-05 — Uninstall drops the entire `hooks` key when nothing foreign remains** (partial). Re-read has no `hooks` key, still valid JSON.
- **CUR-T1-06 — reconcile() backfills newly-managed events when script exists** (none). Partial-ours → missing events added, no dups; no-op when already installed.
- **CUR-T1-07 — reconcile() no-op when script absent (never auto-install)** (none). hooks.json byte-unchanged, no script created.

### T1 — `/cursor` route (*gate: route + onCursorEvent + injectable port*)
- **CUR-T1-08 — beforeSubmitPrompt → .working bound to conversation_id** (none). POST `/cursor?tty=/dev/ttys004` → 200, `onCursorEvent` once, conversationID from body, tty `ttys004`, mapper `.working`.
- **CUR-T1-09 — stop status: error→needsAttention, aborted→done, completed→done** (partial). Each decodes its optional `status`; a regression must not collapse error into done.
- **CUR-T1-10 — afterAgentResponse keeps status (nil), carries assistant text** (partial). `event.text` non-nil, `event.prompt` nil, mapper status nil. *Must not prematurely mark done mid-turn.*
- **CUR-T1-11 — Malformed/missing-conversation_id dropped, still 200** (none). Neither fires; both 200; follow-up valid POST still fires.
- **CUR-T1-12 — Oversized prompt (≤256KB) decodes; beyond cap dropped; unicode boundary safe** (none, *defect-aware*). ~200KB → fires; >256KB single-receive → dropped no hang; multibyte UTF-8 split safe.
- **CUR-T1-13 — Concurrent POSTs from N TTYs/conversations, no cross-talk** (none). N callbacks, each (conversationID,tty) preserved.
- **CUR-T1-14 — tty normalization + absence (GUI vs CLI)** (none). no tty→nil, `/dev/ttys003`→`ttys003`, `??`→nil.
- **CUR-T1-14b — Route-prefix collision: `/cursorx` / `/cursor-foo` don't leak to the handler** (none). hasPrefix routing must not match collisions.
- **CUR-T1-15 — Server bind on in-use port fails gracefully** (none). Second start() no crash; first still dispatches `/cursor`.
- **CUR-T1-16 — CursorDeepLink (COVERED — do NOT re-author)**. Already in `CursorDeepLinkTests`.

### T2
- **CUR-T2-01 — Cursor final-message reuses shared classify (thin)** (partial). A Cursor `afterAgentResponse` text flows through the same `classifyFinalMessage`/edge fn: question→needsAttention, completion→done, over-cap→quotaExceeded. *One assertion — not a re-run of the full classify matrix.*

### T3
- **CUR-T3-01 — Real Cursor desktop hooks drive a real drop** (none). Submit→working; complete→done; question-ending→needsAttention; refocus via deeplink fronts the right conversation.
- **CUR-T3-02 — Real install/uninstall round-trip preserves user's existing Cursor hooks** (none). user hook still honored after install; zero `superisland-cursor-hook` after uninstall; Cursor never reports hooks.json invalid.

---

## Supabase backend

### T2 — classify edge `handle()` (Deno test)
- **SUP-T2-00 — Missing/invalid Authorization → 401 before quota/body (fail-closed)** (none, *security*). No/expired/garbage JWT → 401; `incrementQuota` and `anthropicFetch` **not** called. *Highest-value branch: a fail-open regression leaks the shared Anthropic key.*
- **SUP-T2-01 — Non-POST → 405** (none). GET/PUT/DELETE → 405 before auth/quota.
- **SUP-T2-01b — CORS/OPTIONS preflight contract** (none). OPTIONS → assert documented behavior (405 vs handled).
- **SUP-T2-02 — Oversized body → 413 before quota** (none). `raw.length` > `maxBodyBytes` → 413, no quota/upstream.
- **SUP-T2-03 — Malformed JSON → 400 `invalid_json`** (none). JSON.parse catch, no quota/upstream.
- **SUP-T2-04 — Missing model → 400 `model_not_allowed`** (partial). `!parsed.model` (distinct from present-but-disallowed).
- **SUP-T2-05 — Under cap → 200 forwards raw body verbatim, mirrors upstream status + quota headers** (partial). forwarded body === raw request body; status == upstream; `x-quota-used`/`x-quota-cap` set.
- **SUP-T2-06 — Upstream non-200 (e.g. 529) mirrored with quota headers** (none).
- **SUP-T2-07 — At cap → 429 with quota headers, no upstream call** (partial). 429 `quota_exceeded{used,cap}`, `anthropicFetch` not called.
- **SUP-T2-08 — incrementQuota RPC error fails closed → 429** (none). RPC error → `{allowed:false,used:cap}` → 429, no upstream.

### T2 — quota + RLS (pgTAP / SQL)
- **SUP-T2-09 — check_and_increment increments + blocks at cap (COVERED — ensure-runs only)**. In `quota_test.sql`; do not re-author.
- **SUP-T2-10 — Quota resets per UTC day** (none). Yesterday at cap → today (true,1), new row, yesterday untouched.
- **SUP-T2-11 — Concurrent increments at cap-1 don't exceed cap (row lock)** (none, *not pgTAP*). Two real concurrent sessions (psql/pgbench against `supabase start`) → exactly one allowed=true, final count ≤ cap. *Cannot live in a single pgTAP rollback tx.*
- **SUP-T2-12 — RLS: user reads only own profile/usage rows** (none, *security*). As A only A visible; anon → 0 rows.
- **SUP-T2-13 — No client INSERT/UPDATE to usage_daily (definer/service only)** (none). Direct INSERT/UPDATE by authenticated role → RLS violation; definer fn still succeeds.
- **SUP-T2-13b — profiles write-side RLS: cannot UPDATE another user's profile** (none, *security*). No over-broad UPDATE policy.
- **SUP-T2-14 — handle_new_user trigger creates exactly one profile, idempotent on conflict** (partial). One row, email copied, re-insert no dup/error.

### T1 — client (*gate: BackendConfig URL seam or URLProtocol stub; Keychain protocol seam; confirm NSWorkspace headless*)
- **SUP-T1-15 — ClaudeClassifier maps mock 200 → Classification** (none). Valid verdict body → parsed; `Authorization: Bearer jwt`, POST with `requestBody(model:)` shape.
- **SUP-T1-16 — Mock 429 → quotaExceeded(used,cap) from headers (case-insensitive)** (partial). Mixed-case `X-Quota-Used`/`Cap` → `.quotaExceeded(200,200)`.
- **SUP-T1-17 — Mock 401/400 → .http(status,body); empty bearer → .missingAPIKey (no request)** (none). empty-bearer throws before any network call.
- **SUP-T1-18 — Transport timeout → .transport** (none). Hanging/closed socket → wrapped `.transport`, bounded by injected short timeout.
- **SUP-T1-19 — Deep-link `superisland://auth-callback?code=…` with pending sign-in → token exchange** (none). pendingPKCE set; handleCallback → POST `tokenURL?grant_type=pkce`, body `{auth_code,code_verifier(==pending)}`; 200 → session persisted (sandbox Keychain); pendingPKCE cleared.
- **SUP-T1-20 — Callback with NO pending sign-in dropped (no token request)** (none). Stale/replayed link → 0 token requests, session nil.
- **SUP-T1-21 — Callback carrying provider error clears pending, no exchange** (none). `?error=access_denied` → `.providerError`, 0 token requests, session nil.
- **SUP-T1-22 — validAccessToken refreshes near expiry; refresh failure signs out** (none). Near-expiry → `grant_type=refresh_token` → new token; non-2xx → `signOut()`.
- **SUP-T1-23 — AuthSession.from rejects malformed token body via exchange path** (partial). 200 missing access_token / non-JSON → session nil, no Keychain write, no crash.

### T3
- **SUP-T3-24 — Real OAuth round-trip against live Supabase establishes a session** (none). signIn → browser consent → `superisland://auth-callback` via onOpenURL → real `/auth/v1/token` exchange → signed-in; subsequent classify 200.
- **SUP-T3-25 — Real classify against deployed edge fn returns verdict + decrements quota** (none). forwards to Anthropic → 200 verdict; `x-quota-used` +1; expired token → 401.

---

## Cross-cutting harness + status pipeline

### T1 — harness seams
- **XCUT-T1-01 — TempHomeSandbox isolates + cleans up $HOME-rooted writes** (none). DropStore.defaultFileURL + installers resolve under temp dir; parallel sandboxes distinct; teardown removes dir on throw.
- **XCUT-T1-18 — PROVE HOME redirection is honored (or force injection)** (none, *linchpin*). Assert `FileManager.url(for:.applicationSupportDirectory)` honors redirected HOME on macos-15, or require base-URL injection. (`DropStore.defaultFileURL` already accepts an injectable FileManager.)
- **XCUT-T1-02 — EphemeralServerHarness boots real servers on free port + tears down** (none). OS-assigned port, POST only after `.ready`, immediate re-boot succeeds, two harnesses → two ports.
- **XCUT-T1-03 — Port-in-use: second server on same fixed port fails, no crash** (none). B's listener nil, A keeps serving.
- **XCUT-T1-04 — NativeHostDriver round-trips a length-prefixed message** (none). Correct 4-byte LE length, body unmodified, deadline-enforced, loops. *Gate: `SUPERISLAND_BRIDGE_URL`; build the executable in CI.*
- **XCUT-T1-05 — Native host rejects oversized/malformed frames; unreachable bridge → fixed error** (none). ≥4MB / truncated / 0-length → no forward; closed bridge → `{ok:false,error:"SuperIsland app is not reachable"}`, no hang.
- **XCUT-T1-06 — Host pre-filters disallowed host before any localhost round-trip** (none). evil.com, userinfo trick `https://chatgpt.com@evil.com/`, http scheme, suffix `evil-lovable.dev` → rejected, StubBridge call-count 0.
- **XCUT-T1-07 — FixturesLoader loads every committed payload + they decode against current models** (none). Each fixture decodes; missing fixture fails loudly; PII-scrub guard (no `/Users/<name>/`, no email-shaped strings); golden checksum.

### T1 — pipeline (*gate: extracted handlers + injectable port*)
- **XCUT-T1-08 — Claude hooks drive a desktop drop working→done via real server** (partial). UserPromptSubmit→working, Stop→done; `lastChecked` advances. Owns the server-decode→store wiring (not the mapper table).
- **XCUT-T1-09 — Claude Notification typing maps correctly through the pipeline** (partial). permission_prompt→needsAttention, idle_prompt→done, untyped "waiting…"→done, auth_success→unchanged, unknown→needsAttention.
- **XCUT-T1-10 — Codex hook over `/codex` routes by `codex://session/<id>`** (partial). Located by contentURL; unknown session_id → no-op (no phantom drop).
- **XCUT-T1-11 — Chrome tab_state over the bridge updates matching drop + enforces allowlist** (partial). allowlisted→ok:true+working; disallowed→rejection unchanged; malformed→`{ok:false,error:"malformed chrome bridge message"}`.
- **XCUT-T1-12 — Shell start/done drive a tty-keyed terminal drop** (partial). register→registeredTTYs; start→working(CommandLabel); done exit 0→done(duration); exit≠0→needsAttention; agent cmd → label=agent.
- **XCUT-T1-17 — Timeout budget: hook POST honors deadline; slow consumer doesn't wedge server** (none). round-trip <2s; server always replies `200 OK … ok` then cancels even on decode failure.
- **XCUT-T1-19 — Cold-start end-to-end: empty DropStore at launch seeds only resting states** (none). backfill from Codex rollouts + Claude sessions; only `.done`/`.needsAttention` seed, `.working` gated.

### T1 — DropStore deltas only (*round-trip/dedup/concurrency invariants already in `DropStoreTests`*)
- **XCUT-T1-14 — DropStore persistence DELTAS** (partial). ISO8601 date drift across encode/decode, `historyLimit` enforced on disk, atomic save (no partial file).
- **XCUT-T1-15 — Cold-start dedup RE-SAVE side effect** (partial). When `deduped.count != decoded.count`, the repaired file is re-saved so re-loading is a no-op.

---

## CI wiring

### ci.yml — T1 (every PR + push to main, macos-15, headless)
- **XCUT-CI-01** — After `swift build -c release` and `swift test`, the new `SuperIslandAppTests` seam target runs with **no** TCC/GUI/Accessibility/hotkey/real-Chrome/real-CLI. SwiftLint `--strict`, swift-format lint `--strict`, ad-hoc signing dry-run, Swift 6 toolchain assertion remain gating. *Prereq: add `SuperIslandAppTests` to Package.swift; build the native-host executable so the subprocess driver has a binary.*
- **XCUT-CI-04** — Determinism + flake/timeout budget: no cross-process reliance on `ContentDigest.hashValue` (per-process seeded); inject synthetic `Date`s so nothing is wall-clock dependent; every network test has a deadline; re-recording a fixture caught by the golden checksum.

### T2 — containerized backend (separate job, ubuntu-latest)
- **XCUT-CI-02** — `supabase start` (Postgres + edge runtime in containers), serve `classify` locally, run `deno test` for handler branches (SUP-T2-00..08) and `supabase test db`/pgTAP for quota+RLS (SUP-T2-09..14, +13b); the row-lock case (SUP-T2-11) runs as a separate two-session psql/pgbench step. **Always the local/containerized stack, never the cloud project.**
- *(Optional Node job)* CHR-T1-18 (Jest `providers.js` detector) only if approved — not in the Swift T1 target.

### e2e-real.yml — T3 (gated, self-hosted Mac, off PRs)
- **XCUT-CI-03** — `schedule` + `workflow_dispatch` only (no `pull_request`); `runs-on` a self-hosted/TCC-pre-granted Mac label; the only place real Chrome+extension / real CLIs / real OAuth / real drop-status run; concurrency/`if` guard prevents it blocking merges; harness snapshots/restores real `~/.claude/settings.json`, `~/.cursor/hooks.json`, shell RC files.

---

## Open questions for sign-off

### Code-change prerequisites — ACCEPTED, in scope (gate whole tiers — land before authoring tests)
1. **Injectable port** on `ShellServer` (2929) and `ChromeBridgeServer` (2931) — `init(port:)` / port-0 + bound-port readback. Blocks all ephemeral-port/parallel/port-in-use cases.
2. **`SUPERISLAND_BRIDGE_URL` env override** in native-host `main.swift`. Blocks CHR-T1-01/02/04/16, XCUT-T1-04/05/06.
3. **Injectable home/base-URL** on Claude/Shell/Codex/Chrome integrations (all `static let` from `homeDirectoryForCurrentUser`). XCUT-T1-18 must prove `$HOME` redirection works on macOS, or injection is mandatory. ShellIntegration cases must NOT run against real `$HOME` (data-loss).
4. **Extract AppController hook→store handlers** into a testable type, else XCUT pipeline cases become T3.
5. **BackendConfig URL seam + Keychain protocol seam**; confirm `NSWorkspace` works headless on macos-15. Blocks SUP-T1-19..23.
6. **Build CursorIntegration + `/cursor` route + `onCursorEvent`** (none exist) — RESOLVED: built via TDD on **ShellServer (2929)**, mirroring `/claude` + `/codex`. All CUR-T1 cases are TDD-red until then.
7. **Add `SuperIslandAppTests` target** to Package.swift; build the native-host executable in CI.

### Defects — RESOLVED: fix now, assert correct behavior
8. **Single-receive caps** — `ChromeBridgeServer.accept` (64KB) and `ShellServer.accept` (256KB) → **fix to loop until Content-Length**; tests assert full-body receipt. (CHR-T1-05, CLA-T1-10, SHL-T1-15, CUR-T1-12.)

### Still open — implementation defaults proposed (confirm during spec review or defer to the plan)
9. **Wall-clock timeouts** — native-host 2s + curl `-m 2`/`-m 1`: make the host timeout injectable; assert bounded ranges, not tight windows. *(Default: do it — small, removes flake.)*
10. **Migration gaps** — `reconcile()`/`install()` never prune a now-unmanaged event (CLA-T1-06b); shell `removeSourceLine` exact-string replace leaves a stale line if the block drifted (SHL-T1-04b). *(Default: move to marker-delimited block removal so uninstall/upgrade is robust.)*
11. **`readSettings()` returns `[:]` on parse failure** → install() risks overwriting a malformed-but-user-authored settings.json (CLA-T1-02b). *(Default: abort + back up to `settings.json.superisland-bak` rather than overwrite.)*

### Backend / product decisions
12. Should the client surface `413 payload_too_large` distinctly (today only 429 is special-cased)?
13. Is `OPTIONS`/CORS intended to 405 or be handled (SUP-T2-01b)?
14. Is there a committed `seed.sql` (config.toml references it) and is it test-safe vs the pgTAP/quota fixtures?
15. Are Codex thread titles/summaries actually sent to the classify edge function? If not, **drop CDX-T2-01** (Codex is purely local file-watching). Is `mtime` the right freshness signal?
16. Confirm current Codex `session_index.jsonl` field names (`thread_name`/`updated_at`/`id`) and capture a fresh PII-scrubbed sample; does Codex honor a configurable `CODEX_HOME`?

### Toolchain expansions
17. **Deno + supabase CLI + pgTAP + Docker** for T2 → run on **ubuntu-latest**, never macos-15, never the cloud project.
18. **Jest/Node** — declined for the Swift T1 contract; CHR-T1-17 parity is pure-Swift. CHR-T1-18 only if a standalone Node CI job is wanted.
19. **Playwright/Chromium** — declined (`CHR-T3-02` dropped); rely on the manual real-Chrome smoke (CHR-T3-01).
20. **Fixtures location** — committed PII-scrubbed payloads where both the Swift seam target (`Bundle.module`) and the T2 supabase tests can share them.
21. **PII provenance** — do we have recorded-real payloads for every event (incl. all `notification_type` variants, `last_assistant_message`), or must some be hand-authored (which weakens schema-drift value)? T3 must snapshot/restore the user's real config files.
