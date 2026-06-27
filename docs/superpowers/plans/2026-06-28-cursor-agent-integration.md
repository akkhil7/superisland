# Cursor Agent Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SuperIsland track Cursor's desktop agent (Composer) as a first-class agent integration — working → done → needs-attention — via Cursor's own hooks, and stop treating Cursor as a VS Code editor.

**Architecture:** A faithful fork of the Claude Code integration. We install `~/.cursor/hooks.json` entries that POST lifecycle events to a new `/cursor` route on the existing `ShellServer`; `AppController.handleCursorHookEvent` binds each event to a drop (by `conversation_id` for the GUI, by TTY for the `cursor-agent` CLI) and maps it to a `DropStatus`. Cursor is removed from the `EditorApp` family so it no longer produces editor-file drops; like Codex it rides `GenericAXAdapter` and is bound via a `cursor://session/<id>` `contentURL`, with the AI monitor gated off by `isExternallyManaged`.

**Tech Stack:** Swift 6 / Swift Package Manager. Two targets: `SuperIslandCore` (pure, dependency-free, unit-tested with XCTest) and `SuperIslandApp` (AppKit/SwiftUI executable, not unit-tested). Local HTTP via `Network.framework`.

## Global Constraints

- **Core stays pure:** files in `Sources/SuperIslandCore/` import only `Foundation`. No AppKit/SwiftUI/Combine. All new pure types are unit-tested.
- **Line length: 100 columns** (`.swift-format`), 4-space indent.
- **Test location:** `Tests/SuperIslandCoreTests/`, one file per type, `final class <Type>Tests: XCTestCase`, `@testable import SuperIslandCore`.
- **Run tests:** `swift test --filter SuperIslandCoreTests.<ClassName>`. **Build:** `swift build`.
- **Cursor hook config path:** `~/.cursor/hooks.json`, schema `{"version": 1, "hooks": {"<event>": [{"command": "<path>", "type": "command"}]}}`.
- **Our hook ownership marker:** the substring `superisland-cursor-hook` in the command path. Install merges, uninstall removes only entries containing the marker, existing user hooks are preserved.
- **Cursor bundle id:** `com.todesktop.230313mzl4w4u92`.
- **Session pseudo-URL prefix:** `cursor://session/` stored in `WindowTarget.contentURL`.
- **Registered hook events (minimal, observational — never return a permission decision):** `beforeSubmitPrompt`, `afterAgentResponse`, `stop`, `sessionEnd`.
- **Status semantics:** reuse the existing `DropStatus` (`working`/`needsAttention`/`done`/`stale`/`unknown`) and `ClaudeHookMapper.Update` value type.

---

## Task 0: Verify live Cursor hook JSON (de-risk the decoder)

**Goal:** Capture the real stdin payloads from the installed Cursor so the `CursorHookEvent` decoder uses correct field names. Cursor hooks are beta; field spellings (especially the `afterAgentResponse` text field and `workspace_roots` shape) must be confirmed before Task 2.

**Files:**
- Create (throwaway): `/tmp/superisland-cursor-probe.sh`
- Create (throwaway): `~/.cursor/hooks.json` (will be replaced by the real installer later; back up any existing file first)
- Create (committed fixture): `Tests/SuperIslandCoreTests/Fixtures/cursor-hook-samples.md`

- [ ] **Step 1: Back up any existing hooks.json**

```bash
[ -f ~/.cursor/hooks.json ] && cp ~/.cursor/hooks.json ~/.cursor/hooks.json.superisland-bak || echo "no existing hooks.json"
```

- [ ] **Step 2: Write a probe hook script that logs stdin**

```bash
cat > /tmp/superisland-cursor-probe.sh <<'EOF'
#!/bin/sh
# Throwaway probe: append the hook's stdin JSON to a log, one line per event.
{ printf '=== %s ===\n' "$(date)"; cat; printf '\n'; } >> /tmp/superisland-cursor-hooks.log
exit 0
EOF
chmod +x /tmp/superisland-cursor-probe.sh
```

- [ ] **Step 3: Point Cursor at the probe for the events we care about**

```bash
cat > ~/.cursor/hooks.json <<'EOF'
{
  "version": 1,
  "hooks": {
    "beforeSubmitPrompt": [{ "command": "/tmp/superisland-cursor-probe.sh", "type": "command" }],
    "afterAgentResponse": [{ "command": "/tmp/superisland-cursor-probe.sh", "type": "command" }],
    "stop": [{ "command": "/tmp/superisland-cursor-probe.sh", "type": "command" }],
    "sessionEnd": [{ "command": "/tmp/superisland-cursor-probe.sh", "type": "command" }]
  }
}
EOF
```

- [ ] **Step 4: Trigger one agent turn, then read the captured payloads**

Manual: open Cursor, fully quit and reopen it so it reloads `hooks.json`, open a workspace folder, submit one short prompt to the agent (e.g. "say hello"), and let it finish. One turn that ends with a plain answer, plus (ideally) a second turn that ends by asking you a question (e.g. "ask me which file to edit, then stop").

Then:

```bash
cat /tmp/superisland-cursor-hooks.log
```

Expected: JSON lines for `beforeSubmitPrompt`, `afterAgentResponse`, `stop`. Note the EXACT keys. Confirm/correct these assumptions used in Task 2:
- conversation id key (`conversation_id`)
- event-name key (`hook_event_name`)
- prompt text key on `beforeSubmitPrompt` (`prompt`)
- assistant text key on `afterAgentResponse` (likely `text` — **confirm**)
- status key on `stop` (`status`, values `completed`/`aborted`/`error`)
- workspace roots key + shape (`workspace_roots`, array — of strings? of objects? **confirm**)

- [ ] **Step 5: Record the canonical samples as a committed fixture**

Paste the real captured JSON (redact any private prompt text) into `Tests/SuperIslandCoreTests/Fixtures/cursor-hook-samples.md` as fenced `json` blocks, one per event. These become the source of truth for Task 2's decoder tests. Example structure:

```markdown
# Cursor hook payload samples (captured from Cursor <version> on <date>)

## beforeSubmitPrompt
```json
{ "hook_event_name": "beforeSubmitPrompt", "conversation_id": "...", "workspace_roots": ["..."], "prompt": "..." }
```

## afterAgentResponse
```json
{ "hook_event_name": "afterAgentResponse", "conversation_id": "...", "text": "..." }
```

## stop
```json
{ "hook_event_name": "stop", "conversation_id": "...", "status": "completed" }
```
```

- [ ] **Step 6: Restore the machine state**

```bash
rm -f ~/.cursor/hooks.json
[ -f ~/.cursor/hooks.json.superisland-bak ] && mv ~/.cursor/hooks.json.superisland-bak ~/.cursor/hooks.json || true
```

- [ ] **Step 7: Commit the fixture**

```bash
git add Tests/SuperIslandCoreTests/Fixtures/cursor-hook-samples.md
git commit -m "test(cursor): capture live Cursor hook payload samples as decoder fixtures"
```

> If any field name differs from the assumptions above, use the REAL names from the fixture wherever Task 2/Task 7 reference them. The plan's code uses the documented names; correct them inline if Step 4 proves otherwise.

---

## Task 1: `CursorDeepLink` (bundle id + session URL)

**Files:**
- Create: `Sources/SuperIslandCore/CursorDeepLink.swift`
- Test: `Tests/SuperIslandCoreTests/CursorDeepLinkTests.swift`

**Interfaces:**
- Produces: `enum CursorDeepLink { static let bundleID: String; static let sessionURLPrefix: String; static func deepLink(forContentURL: String) -> String? }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SuperIslandCore

final class CursorDeepLinkTests: XCTestCase {
    func testBundleIDIsCursorDesktop() {
        XCTAssertEqual(CursorDeepLink.bundleID, "com.todesktop.230313mzl4w4u92")
    }

    func testSessionURLPrefix() {
        XCTAssertEqual(CursorDeepLink.sessionURLPrefix, "cursor://session/")
    }

    func testDeepLinkReturnsNilForNonSessionURL() {
        XCTAssertNil(CursorDeepLink.deepLink(forContentURL: "https://example.com"))
    }

    func testDeepLinkReturnsNilForEmptyID() {
        XCTAssertNil(CursorDeepLink.deepLink(forContentURL: "cursor://session/"))
    }

    func testDeepLinkBuildsAnchorURLFromSessionURL() {
        XCTAssertEqual(
            CursorDeepLink.deepLink(forContentURL: "cursor://session/abc-123"),
            "cursor://anysphere.cursor-deeplink/composer?id=abc-123"
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SuperIslandCoreTests.CursorDeepLinkTests`
Expected: FAIL — `cannot find 'CursorDeepLink' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Cursor desktop agent identity + the pseudo-URL SuperIsland stores in a
/// drop's `contentURL` to bind it to one Cursor conversation. Mirrors
/// `CodexDeepLink`. `deepLink(forContentURL:)` produces a best-effort URL to
/// refocus the conversation; Cursor's deep-link scheme for a specific
/// conversation is unverified, so refocus falls back to fronting the app when
/// this URL doesn't resolve (handled in the adapter layer).
public enum CursorDeepLink {
    public static let bundleID = "com.todesktop.230313mzl4w4u92"
    public static let sessionURLPrefix = "cursor://session/"

    public static func deepLink(forContentURL url: String) -> String? {
        guard url.hasPrefix(sessionURLPrefix) else { return nil }
        let id = String(url.dropFirst(sessionURLPrefix.count))
        guard !id.isEmpty else { return nil }
        return "cursor://anysphere.cursor-deeplink/composer?id=\(id)"
    }
}
```

> The `composer?id=` deep-link shape is a best guess. If Task 0/Task 10 shows Cursor has no working conversation deep link, simplify `deepLink` to `return nil` (refocus then just fronts the app) and update the test's last case to `XCTAssertNil`. This is cosmetic and does not affect status tracking.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SuperIslandCoreTests.CursorDeepLinkTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandCore/CursorDeepLink.swift Tests/SuperIslandCoreTests/CursorDeepLinkTests.swift
git commit -m "feat(core): add CursorDeepLink (bundle id + cursor://session URL)"
```

---

## Task 2: `CursorHookEvent` (decode the hook stdin JSON)

**Files:**
- Create: `Sources/SuperIslandCore/CursorHookSupport.swift`
- Test: `Tests/SuperIslandCoreTests/CursorHookEventTests.swift`

**Interfaces:**
- Produces: `struct CursorHookEvent: Decodable, Equatable, Sendable` with fields `conversationID: String`, `event: String`, `prompt: String?`, `text: String?`, `status: String?`, `workspaceRoots: [String]`, and a server-filled `var tty: String?`.

- [ ] **Step 1: Write the failing test** (uses the field names confirmed in Task 0)

```swift
import XCTest
@testable import SuperIslandCore

final class CursorHookEventTests: XCTestCase {
    private func decode(_ json: String) throws -> CursorHookEvent {
        try JSONDecoder().decode(CursorHookEvent.self, from: Data(json.utf8))
    }

    func testDecodesBeforeSubmitPrompt() throws {
        let e = try decode("""
            {"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1",
             "workspace_roots":["/Users/x/proj"],"prompt":"fix the bug"}
            """)
        XCTAssertEqual(e.event, "beforeSubmitPrompt")
        XCTAssertEqual(e.conversationID, "c1")
        XCTAssertEqual(e.workspaceRoots, ["/Users/x/proj"])
        XCTAssertEqual(e.prompt, "fix the bug")
        XCTAssertNil(e.tty)
    }

    func testDecodesAfterAgentResponse() throws {
        let e = try decode("""
            {"hook_event_name":"afterAgentResponse","conversation_id":"c1","text":"Done — all green."}
            """)
        XCTAssertEqual(e.event, "afterAgentResponse")
        XCTAssertEqual(e.text, "Done — all green.")
    }

    func testDecodesStopWithStatus() throws {
        let e = try decode("""
            {"hook_event_name":"stop","conversation_id":"c1","status":"completed"}
            """)
        XCTAssertEqual(e.event, "stop")
        XCTAssertEqual(e.status, "completed")
    }

    func testMissingWorkspaceRootsDefaultsToEmpty() throws {
        let e = try decode("""
            {"hook_event_name":"stop","conversation_id":"c1"}
            """)
        XCTAssertEqual(e.workspaceRoots, [])
        XCTAssertNil(e.prompt)
        XCTAssertNil(e.text)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SuperIslandCoreTests.CursorHookEventTests`
Expected: FAIL — `cannot find 'CursorHookEvent' in scope`.

- [ ] **Step 3: Write minimal implementation** (in `CursorHookSupport.swift`)

```swift
import Foundation

// MARK: - Hook event

/// A Cursor agent lifecycle event, delivered to hook commands on stdin and
/// forwarded verbatim to SuperIsland by the hook script. Cursor's payloads are
/// flatter than Claude's; only the fields SuperIsland uses are decoded.
public struct CursorHookEvent: Decodable, Equatable, Sendable {
    public let conversationID: String
    public let event: String
    /// Submitted prompt (beforeSubmitPrompt only) — used to label the drop.
    public let prompt: String?
    /// Assistant message text (afterAgentResponse only) — stashed and
    /// classified at turn end to tell "done" from "waiting on you".
    public let text: String?
    /// Turn outcome (stop only): "completed" | "aborted" | "error".
    public let status: String?
    /// Absolute workspace roots for the conversation — used to bind a GUI drop
    /// to the conversation active in the dropped window's workspace.
    public let workspaceRoots: [String]
    /// Controlling TTY of the hook process. Not in the stdin payload: the hook
    /// script reports it as a query parameter and the server fills it in. nil
    /// for the desktop GUI (no controlling TTY); set for the cursor-agent CLI.
    public var tty: String?

    public init(
        conversationID: String, event: String, prompt: String? = nil,
        text: String? = nil, status: String? = nil,
        workspaceRoots: [String] = [], tty: String? = nil
    ) {
        self.conversationID = conversationID
        self.event = event
        self.prompt = prompt
        self.text = text
        self.status = status
        self.workspaceRoots = workspaceRoots
        self.tty = tty
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case event = "hook_event_name"
        case workspaceRoots = "workspace_roots"
        case prompt, text, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        event = try c.decode(String.self, forKey: .event)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        workspaceRoots = try c.decodeIfPresent([String].self, forKey: .workspaceRoots) ?? []
        tty = nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SuperIslandCoreTests.CursorHookEventTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandCore/CursorHookSupport.swift Tests/SuperIslandCoreTests/CursorHookEventTests.swift
git commit -m "feat(core): decode Cursor hook events (CursorHookEvent)"
```

---

## Task 3: `CursorHookMapper` (event → status)

**Files:**
- Modify: `Sources/SuperIslandCore/CursorHookSupport.swift` (append the mapper)
- Test: `Tests/SuperIslandCoreTests/CursorHookMapperTests.swift`

**Interfaces:**
- Consumes: `CursorHookEvent` (Task 2), `ClaudeHookMapper.Update` (existing: `{ status: DropStatus?, reason: String }`).
- Produces: `enum CursorHookMapper { static func update(for: CursorHookEvent) -> ClaudeHookMapper.Update? }`. Note: `stop` returns the **baseline** resting status; AppController refines `completed` into done-vs-needsAttention via the stashed assistant text (Task 8). A `nil` return means "ignore".

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SuperIslandCore

final class CursorHookMapperTests: XCTestCase {
    private func ev(_ event: String, status: String? = nil) -> CursorHookEvent {
        CursorHookEvent(conversationID: "c1", event: event, status: status)
    }

    func testBeforeSubmitPromptIsWorking() {
        XCTAssertEqual(CursorHookMapper.update(for: ev("beforeSubmitPrompt"))?.status, .working)
    }

    func testStopCompletedIsDoneBaseline() {
        XCTAssertEqual(
            CursorHookMapper.update(for: ev("stop", status: "completed"))?.status, .done)
    }

    func testStopErrorIsNeedsAttention() {
        XCTAssertEqual(
            CursorHookMapper.update(for: ev("stop", status: "error"))?.status, .needsAttention)
    }

    func testStopAbortedIsDone() {
        XCTAssertEqual(
            CursorHookMapper.update(for: ev("stop", status: "aborted"))?.status, .done)
    }

    func testAfterAgentResponseKeepsStatus() {
        // Informational — carries the text to stash, but doesn't move status.
        let update = CursorHookMapper.update(for: ev("afterAgentResponse"))
        XCTAssertNotNil(update)
        XCTAssertNil(update?.status)
    }

    func testSessionEndKeepsStatus() {
        let update = CursorHookMapper.update(for: ev("sessionEnd"))
        XCTAssertNil(update?.status)
    }

    func testUnknownEventIsIgnored() {
        XCTAssertNil(CursorHookMapper.update(for: ev("afterFileEdit")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SuperIslandCoreTests.CursorHookMapperTests`
Expected: FAIL — `cannot find 'CursorHookMapper' in scope`.

- [ ] **Step 3: Append the implementation to `CursorHookSupport.swift`**

```swift
// MARK: - Event → status mapping

/// SuperIsland-status semantics for Cursor agent lifecycle events. Hooks are
/// ground truth: they replace AI classification for conversations that emit
/// them. `stop` with status "completed" returns the resting baseline `.done`;
/// AppController refines it into done-vs-needsAttention from the assistant's
/// final message (captured via afterAgentResponse), the same way the Claude
/// Stop hook is refined.
public enum CursorHookMapper {
    public static func update(for event: CursorHookEvent) -> ClaudeHookMapper.Update? {
        switch event.event {
        case "beforeSubmitPrompt":
            return ClaudeHookMapper.Update(status: .working, reason: "Cursor is working…")
        case "afterAgentResponse":
            // Informational: carries the assistant text to stash. Keep status.
            return ClaudeHookMapper.Update(status: nil, reason: "Cursor is working…")
        case "stop":
            switch event.status {
            case "error":
                return ClaudeHookMapper.Update(
                    status: .needsAttention, reason: "Cursor hit an error")
            case "aborted":
                return ClaudeHookMapper.Update(status: .done, reason: "Cursor stopped")
            default:  // "completed" (and any unknown terminal status)
                return ClaudeHookMapper.Update(
                    status: .done, reason: "Cursor finished — ready for you")
            }
        case "sessionEnd":
            return ClaudeHookMapper.Update(status: nil, reason: "Session ended")
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SuperIslandCoreTests.CursorHookMapperTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandCore/CursorHookSupport.swift Tests/SuperIslandCoreTests/CursorHookMapperTests.swift
git commit -m "feat(core): map Cursor hook events to drop status (CursorHookMapper)"
```

---

## Task 4: `CursorHooksConfigurator` (~/.cursor/hooks.json surgery)

**Files:**
- Modify: `Sources/SuperIslandCore/CursorHookSupport.swift` (append the configurator)
- Test: `Tests/SuperIslandCoreTests/CursorHooksConfiguratorTests.swift`

**Interfaces:**
- Produces: `enum CursorHooksConfigurator { static let events: [String]; static let commandMarker: String; static func isInstalled(config: [String: Any]) -> Bool; static func install(config: [String: Any], scriptPath: String) -> [String: Any]; static func uninstall(config: [String: Any]) -> [String: Any] }`

> Cursor's `hooks.json` shape differs from Claude's `settings.json` (flat `{command,type}` entries directly in the per-event array, plus a top-level `"version"`), so this needs its own surgery and does **not** reuse `AgentHooksConfigurator`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SuperIslandCore

final class CursorHooksConfiguratorTests: XCTestCase {
    private let path = "/Users/x/.config/superisland/superisland-cursor-hook.sh"

    func testInstallAddsVersionAndAllEvents() {
        let out = CursorHooksConfigurator.install(config: [:], scriptPath: path)
        XCTAssertEqual(out["version"] as? Int, 1)
        let hooks = out["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks)
        for event in CursorHooksConfigurator.events {
            let entries = hooks?[event] as? [[String: Any]]
            XCTAssertEqual(entries?.count, 1, "event \(event)")
            XCTAssertEqual(entries?.first?["command"] as? String, path)
            XCTAssertEqual(entries?.first?["type"] as? String, "command")
        }
    }

    func testIsInstalledTrueAfterInstall() {
        let out = CursorHooksConfigurator.install(config: [:], scriptPath: path)
        XCTAssertTrue(CursorHooksConfigurator.isInstalled(config: out))
    }

    func testIsInstalledFalseOnEmpty() {
        XCTAssertFalse(CursorHooksConfigurator.isInstalled(config: [:]))
    }

    func testInstallPreservesForeignHooksAndIsIdempotent() {
        var config: [String: Any] = [
            "version": 1,
            "hooks": ["stop": [["command": "/usr/local/bin/user-hook.sh", "type": "command"]]],
        ]
        config = CursorHooksConfigurator.install(config: config, scriptPath: path)
        config = CursorHooksConfigurator.install(config: config, scriptPath: path)  // twice
        let stop = (config["hooks"] as? [String: Any])?["stop"] as? [[String: Any]]
        // foreign hook kept + exactly one of ours (no duplicate on re-install)
        XCTAssertEqual(stop?.count, 2)
        XCTAssertTrue(stop?.contains { ($0["command"] as? String) == path } ?? false)
        XCTAssertTrue(
            stop?.contains { ($0["command"] as? String) == "/usr/local/bin/user-hook.sh" } ?? false)
    }

    func testUninstallRemovesOnlyOurEntries() {
        var config: [String: Any] = [
            "version": 1,
            "hooks": ["stop": [["command": "/usr/local/bin/user-hook.sh", "type": "command"]]],
        ]
        config = CursorHooksConfigurator.install(config: config, scriptPath: path)
        config = CursorHooksConfigurator.uninstall(config: config)
        XCTAssertFalse(CursorHooksConfigurator.isInstalled(config: config))
        let stop = (config["hooks"] as? [String: Any])?["stop"] as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1)
        XCTAssertEqual(stop?.first?["command"] as? String, "/usr/local/bin/user-hook.sh")
    }

    func testUninstallDropsHooksKeyWhenEmpty() {
        var config = CursorHooksConfigurator.install(config: [:], scriptPath: path)
        config = CursorHooksConfigurator.uninstall(config: config)
        XCTAssertNil(config["hooks"])  // no foreign hooks remained
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SuperIslandCoreTests.CursorHooksConfiguratorTests`
Expected: FAIL — `cannot find 'CursorHooksConfigurator' in scope`.

- [ ] **Step 3: Append the implementation to `CursorHookSupport.swift`**

```swift
// MARK: - hooks.json surgery

/// Pure insert/remove of SuperIsland's entries in a Cursor `hooks.json`
/// dictionary. Cursor's schema is `{"version": 1, "hooks": {"<event>":
/// [{"command": "...", "type": "command"}]}}` — flatter than Claude's, so the
/// surgery is bespoke. Foreign hooks are preserved; ours are identified by the
/// marker substring in the command path.
public enum CursorHooksConfigurator {
    public static let events = [
        "beforeSubmitPrompt", "afterAgentResponse", "stop", "sessionEnd",
    ]
    /// Marker in the command path that identifies entries SuperIsland owns.
    public static let commandMarker = "superisland-cursor-hook"

    public static func isInstalled(config: [String: Any]) -> Bool {
        guard let hooks = config["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            ownsEntry(in: (hooks[event] as? [[String: Any]]) ?? [])
        }
    }

    public static func install(config: [String: Any], scriptPath: String) -> [String: Any] {
        var out = config
        out["version"] = 1
        var hooks = (config["hooks"] as? [String: Any]) ?? [:]
        for event in events {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            if !ownsEntry(in: entries) {
                entries.append(["command": scriptPath, "type": "command"])
            }
            hooks[event] = entries
        }
        out["hooks"] = hooks
        return out
    }

    public static func uninstall(config: [String: Any]) -> [String: Any] {
        var out = config
        guard var hooks = config["hooks"] as? [String: Any] else { return out }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurCommand($0) }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        if hooks.isEmpty {
            out.removeValue(forKey: "hooks")
        } else {
            out["hooks"] = hooks
        }
        return out
    }

    private static func ownsEntry(in entries: [[String: Any]]) -> Bool {
        entries.contains { isOurCommand($0) }
    }

    private static func isOurCommand(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(commandMarker) == true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SuperIslandCoreTests.CursorHooksConfiguratorTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandCore/CursorHookSupport.swift Tests/SuperIslandCoreTests/CursorHooksConfiguratorTests.swift
git commit -m "feat(core): merge/remove SuperIsland entries in Cursor hooks.json (CursorHooksConfigurator)"
```

---

## Task 5: Decouple Cursor from the `EditorApp` family

**Goal:** Cursor stops being an editor. It leaves `EditorApp`, joins the allowlist via `CursorDeepLink.bundleID`, maps to a new `RequiredIntegration.cursor`, and gets its own `DropSource` badge.

**Files:**
- Modify: `Sources/SuperIslandCore/AgentTerminalSupport.swift:205-229` (`EditorApp`)
- Modify: `Sources/SuperIslandCore/SupportedApps.swift` (allowlist, displayName, `RequiredIntegration`)
- Modify: `Sources/SuperIslandCore/DropSource.swift:42-55`
- Modify: `Sources/SuperIslandCore/Models.swift:62` (doc only)
- Test: `Tests/SuperIslandCoreTests/CursorDecouplingTests.swift`

**Interfaces:**
- Consumes: `CursorDeepLink.bundleID` (Task 1).
- Produces: `RequiredIntegration.cursor` case; `SupportedApps.cursor` constant; Cursor no longer in `EditorApp.bundleIDs`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SuperIslandCore

final class CursorDecouplingTests: XCTestCase {
    private let cursor = CursorDeepLink.bundleID

    func testCursorIsNotAnEditor() {
        XCTAssertFalse(EditorApp.isEditor(bundleID: cursor))
        XCTAssertTrue(EditorApp.isEditor(bundleID: EditorApp.vsCode))
    }

    func testCursorIsStillSupported() {
        XCTAssertTrue(SupportedApps.isSupported(bundleID: cursor))
    }

    func testCursorRequiresCursorIntegrationNotShell() {
        XCTAssertEqual(RequiredIntegration.required(forBundleID: cursor), .cursor)
        XCTAssertEqual(
            RequiredIntegration.required(forBundleID: EditorApp.vsCode), .shell)
    }

    func testCursorDisplayName() {
        XCTAssertEqual(SupportedApps.displayName(bundleID: cursor), "Cursor")
    }

    func testCursorDropSourceIsAgentBadge() {
        let source = DropSource.identify(
            bundleID: cursor, locator: .generic(axWindowTitle: nil, axWindowIndex: nil),
            contentURL: "cursor://session/abc", label: "Cursor"
        )
        XCTAssertEqual(source.name, "Cursor")
        XCTAssertNotEqual(source.icon, "curlybraces")  // not the editor badge
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SuperIslandCoreTests.CursorDecouplingTests`
Expected: FAIL — `.cursor` is not a member of `RequiredIntegration`; `EditorApp.isEditor(cursor)` still true.

- [ ] **Step 3: Remove Cursor from `EditorApp`** in `AgentTerminalSupport.swift`

Change lines 203-210 from:

```swift
public enum EditorApp {
    /// VS Code family + Cursor.
    public static let vsCode = "com.microsoft.VSCode"
    public static let vsCodeInsiders = "com.microsoft.VSCodeInsiders"
    public static let vsCodium = "com.vscodium"
    public static let cursor = "com.todesktop.230313mzl4w4u92"

    public static let bundleIDs: Set<String> = [vsCode, vsCodeInsiders, vsCodium, cursor]
```

to:

```swift
public enum EditorApp {
    /// VS Code family. (Cursor was here until it became an agent integration —
    /// see CursorDeepLink / CursorIntegration.)
    public static let vsCode = "com.microsoft.VSCode"
    public static let vsCodeInsiders = "com.microsoft.VSCodeInsiders"
    public static let vsCodium = "com.vscodium"

    public static let bundleIDs: Set<String> = [vsCode, vsCodeInsiders, vsCodium]
```

Then change the `displayName` `case cursor:` line (was line 217-218). Remove:

```swift
        case cursor: return "Cursor"
```

and remove `"Cursor",` from `appNameSegments` (line 226-228) is **kept** — Cursor's window title still ends in "Cursor" and `EditorWindowTitle.parse` is still used at bind time to read the workspace name. Leave `appNameSegments` unchanged.

- [ ] **Step 4: Update `SupportedApps.swift`**

Add a Cursor constant near the editor section and swap the allowlist/displayName/required mapping. Change lines 26-37 (`bundleIDs`):

```swift
    public static let bundleIDs: Set<String> = [
        // Browsers
        chrome, chromeCanary, brave,
        // Terminals
        terminal, iterm,
        // Editor — VS Code (stable). Insiders/VSCodium excluded.
        EditorApp.vsCode,
        // AI desktop agents
        ClaudeDeepLink.bundleID,  // Claude Desktop
        CodexDeepLink.bundleID,  // Codex
        CursorDeepLink.bundleID,  // Cursor (agent)
    ]
```

Change the `displayName` editor cases (lines 54-55) from:

```swift
        case EditorApp.cursor: return "Cursor"
        case EditorApp.vsCode: return "VS Code"
```

to:

```swift
        case CursorDeepLink.bundleID: return "Cursor"
        case EditorApp.vsCode: return "VS Code"
```

In `RequiredIntegration`, add the case (line 70-75):

```swift
public enum RequiredIntegration: String, Sendable {
    case chrome
    case shell  // terminals + editors (status via integrated-terminal shell hooks)
    case claude
    case codex
    case cursor
```

Update `required(forBundleID:)` (lines 79-91) so Cursor maps to `.cursor` and only VS Code stays `.shell`:

```swift
        switch bundleID {
        case SupportedApps.chrome, SupportedApps.chromeCanary, SupportedApps.brave:
            return .chrome
        case SupportedApps.terminal, SupportedApps.iterm, EditorApp.vsCode:
            return .shell
        case ClaudeDeepLink.bundleID:
            return .claude
        case CodexDeepLink.bundleID:
            return .codex
        case CursorDeepLink.bundleID:
            return .cursor
        default:
            return nil
        }
```

Add the `setupMessage` case (after the `.codex` case, ~line 104):

```swift
        case .cursor:
            return "Cursor integration isn't installed — set it up in Settings → Integrations"
```

- [ ] **Step 5: Update `DropSource.swift`** — give Cursor its own badge

In the `switch bundleID` block (lines 42-55), add a Cursor case before the editor case and drop Cursor from the editor case:

```swift
        switch bundleID {
        case ClaudeDeepLink.bundleID:
            return DropSource(name: "Claude Desktop", icon: "sparkles")
        case CodexDeepLink.bundleID:
            return DropSource(name: "Codex", icon: "chevron.left.forwardslash.chevron.right")
        case CursorDeepLink.bundleID:
            return DropSource(name: "Cursor", icon: "cursorarrow.rays")
        case SupportedApps.chrome, SupportedApps.chromeCanary, SupportedApps.brave:
            return DropSource(name: SupportedApps.displayName(bundleID: bundleID), icon: "globe")
        case EditorApp.vsCode:
            return DropSource(
                name: SupportedApps.displayName(bundleID: bundleID), icon: "curlybraces")
        default:
            return DropSource(
                name: SupportedApps.displayName(bundleID: bundleID), icon: "app.dashed")
        }
```

- [ ] **Step 6: Update the `Locator.editor` doc** in `Models.swift:62`

Change `/// VS Code / Cursor editor window.` to `/// VS Code editor window.` (Cursor is now an agent, bound via `contentURL`).

- [ ] **Step 7: Run tests and build**

Run: `swift test --filter SuperIslandCoreTests.CursorDecouplingTests`
Expected: PASS (5 tests). Then run the full core suite to catch fallout in existing tests that referenced `EditorApp.cursor`:

Run: `swift test`
Expected: PASS. If an existing test references `EditorApp.cursor`, update it to `CursorDeepLink.bundleID` (those drops are no longer editor drops).

Then build the app target too — removing the `EditorApp.cursor` constant must not break any app-side reference:

Run: `swift build`
Expected: builds. (Verified: no app file references `EditorApp.cursor` directly — they use `EditorApp.isEditor`, unaffected — but build to be sure.)

- [ ] **Step 8: Commit**

```bash
git add Sources/SuperIslandCore/ Tests/SuperIslandCoreTests/CursorDecouplingTests.swift
git commit -m "feat(core): split Cursor out of the EditorApp family into its own agent source"
```

---

## Task 6: Add the `/cursor` route to `ShellServer`

**Files:**
- Modify: `Sources/SuperIslandApp/ShellServer.swift`

**Interfaces:**
- Consumes: `CursorHookEvent` (Task 2).
- Produces: `var onCursorEvent: ((CursorHookEvent) -> Void)?` on `ShellServer`, fired for `POST /cursor`.

- [ ] **Step 1: Add the event closure** after `onCodexEvent` (line 41):

```swift
    /// Called on the main queue for Cursor agent hook events (POST /cursor).
    var onCursorEvent: ((CursorHookEvent) -> Void)?
```

- [ ] **Step 2: Add the route** in `dispatch(path:body:)` after the `/codex` block (after line 117, before the `ShellEvent` decode):

```swift
        if path.hasPrefix("/cursor") {
            HookDebugLog.log("RAW /cursor tty=\(hookTTY ?? "-") body=\(body)")
            if var event = try? JSONDecoder().decode(CursorHookEvent.self, from: data) {
                event.tty = hookTTY
                onCursorEvent?(event)
            } else {
                HookDebugLog.log("  → DECODE FAILED for /cursor payload")
            }
            return
        }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds (no test target for the app; verified by compile + Task 10 manual run).

- [ ] **Step 4: Commit**

```bash
git add Sources/SuperIslandApp/ShellServer.swift
git commit -m "feat(app): accept Cursor hook events on POST /cursor"
```

---

## Task 7: `CursorIntegration` (install/uninstall + conversation index + turn-end classify)

**Files:**
- Create: `Sources/SuperIslandApp/CursorIntegration.swift`
- Modify: `Sources/SuperIslandApp/ClaudeIntegration.swift` (extract `classifyFinalMessage` into a shared free function both call)

**Interfaces:**
- Consumes: `CursorHooksConfigurator`, `CursorDeepLink`, `CursorHookEvent`, `ShellServer.port`, `ShellIntegration.configDir`, `AgentTurnEndClassifier` (new shared helper).
- Produces:
  - `final class CursorIntegration: ObservableObject { @Published var isInstalled: Bool; static let bundleID: String; static let sessionURLPrefix: String; func refresh(); func reconcile(); func install() throws; func uninstall(); func recordEvent(conversationID:workspaceRoots:prompt:at:); func currentConversationGuess(workspaceName:) -> (id: String, title: String?)?; func classifyFinalMessage(_:bearer:) async -> (status: DropStatus, reason: String)? }`

- [ ] **Step 1: Extract the shared turn-end classifier** out of `ClaudeIntegration`.

In `ClaudeIntegration.swift`, the body of `classifyFinalMessage` (lines 177-202) is reused verbatim. Move its logic into a free async function at file scope in `ClaudeIntegration.swift` (or a new `AgentTurnEndClassifier.swift`), keeping `ClaudeIntegration.classifyFinalMessage` as a thin delegate so the Claude path is unchanged:

```swift
/// Classify an agent's final turn message into done vs needsAttention, shared
/// by the Claude and Cursor integrations. Uses the hosted Haiku proxy when a
/// bearer token is available; falls back to a structural request-detection
/// heuristic. nil for an empty message.
@MainActor
func classifyAgentFinalMessage(
    _ text: String, agentName: String, bearer: String?
) async -> (status: DropStatus, reason: String)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let bearer, !bearer.isEmpty {
        do {
            let verdict = try await ClaudeClassifier(
                auth: .proxy(url: BackendConfig.classifyURL, bearer: bearer),
                model: ClassifierProtocolBuilder.defaultModel
            ).classifyTurnEndMessage(trimmed)
            switch verdict.status {
            case .needsAttention: return (.needsAttention, verdict.reason)
            case .working: return (.working, "\(agentName) is working…")
            default: return (.done, verdict.reason)
            }
        } catch let ClassifierError.quotaExceeded(used, cap) {
            return (.unknown, "Daily limit reached (\(used)/\(cap))")
        } catch {
            // fall through to the structural heuristic
        }
    }
    return ClaudeTranscript.looksLikeRequest(trimmed)
        ? (.needsAttention, "\(agentName) is waiting for your reply")
        : (.done, "\(agentName) finished — ready for you")
}
```

Then replace the body of `ClaudeIntegration.classifyFinalMessage` (lines 177-202) with:

```swift
    func classifyFinalMessage(
        _ text: String, bearer: String?
    ) async -> (status: DropStatus, reason: String)? {
        await classifyAgentFinalMessage(text, agentName: "Claude", bearer: bearer)
    }
```

- [ ] **Step 2: Run the existing Claude tests / build to confirm no regression**

Run: `swift build`
Expected: builds. (Claude classification behavior is unchanged — same code, parameterized agent name.)

- [ ] **Step 3: Create `CursorIntegration.swift`**

```swift
import Foundation
import Combine
import SuperIslandCore

/// Cursor desktop agent integration via Cursor hooks: a tiny hook script
/// forwards lifecycle events (prompt submitted, response, stop) to
/// SuperIsland's local server, giving event-driven ground truth for the
/// Composer/agent pane — no AI classification, works for background windows.
///
/// Mirrors ClaudeIntegration's install model. Binding differs: the GUI has no
/// TTY, so drops bind by `conversation_id`. An in-memory conversation index,
/// fed by the event stream, answers "which conversation is active in this
/// workspace" at drop time (the analogue of Codex's currentSessionGuess).
@MainActor
final class CursorIntegration: ObservableObject {
    @Published private(set) var isInstalled = false

    static let bundleID = CursorDeepLink.bundleID
    static let sessionURLPrefix = CursorDeepLink.sessionURLPrefix

    static let scriptPath = ShellIntegration.configDir
        .appendingPathComponent("superisland-cursor-hook.sh")
    static let hooksPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cursor/hooks.json")

    init() { refresh() }

    func refresh() {
        isInstalled =
            FileManager.default.fileExists(atPath: Self.scriptPath.path)
            && CursorHooksConfigurator.isInstalled(config: Self.readConfig())
    }

    /// Re-sync our hook entries if the managed event set grew across an app
    /// update. Idempotent; preserves the user's own hooks.
    func reconcile() {
        guard FileManager.default.fileExists(atPath: Self.scriptPath.path),
            !CursorHooksConfigurator.isInstalled(config: Self.readConfig())
        else { return }
        try? install()
    }

    // MARK: - Install / Uninstall

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ShellIntegration.configDir, withIntermediateDirectories: true)
        try Self.hookScript.write(to: Self.scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.scriptPath.path)

        let updated = CursorHooksConfigurator.install(
            config: Self.readConfig(), scriptPath: Self.scriptPath.path
        )
        try Self.writeConfig(updated)
        refresh()
    }

    func uninstall() {
        let updated = CursorHooksConfigurator.uninstall(config: Self.readConfig())
        try? Self.writeConfig(updated)
        try? FileManager.default.removeItem(at: Self.scriptPath)
        refresh()
    }

    private static func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: hooksPath),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func writeConfig(_ config: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: hooksPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: hooksPath, options: .atomic)
    }

    /// Forwards the hook's stdin JSON to SuperIsland. The parent process is the
    /// agent itself; its controlling TTY (if any) tells SuperIsland which
    /// terminal a cursor-agent CLI session lives in ("??" for the GUI).
    private static var hookScript: String {
        """
        #!/bin/sh
        # SuperIsland Cursor hook — forwards lifecycle events to the SuperIsland app.
        # Installed by SuperIsland (Settings → Integrations). Safe to remove together
        # with its entries in ~/.cursor/hooks.json.
        SUPERISLAND_TTY=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
        curl -sf -m 2 -X POST "http://localhost:\(ShellServer.port)/cursor?tty=$SUPERISLAND_TTY" \\
            -H "Content-Type: application/json" \\
            --data-binary @- >/dev/null 2>&1
        exit 0
        """
    }

    // MARK: - Conversation index (fed by the event stream)

    private struct Conversation {
        var workspaceRoots: [String]
        var lastPrompt: String?
        var lastEventAt: Date
    }
    private var conversations: [String: Conversation] = [:]

    /// Record any hook event so drop-time binding can find the active
    /// conversation. Called by AppController on every Cursor hook event.
    func recordEvent(
        conversationID: String, workspaceRoots: [String], prompt: String?, at date: Date
    ) {
        var convo = conversations[conversationID]
            ?? Conversation(workspaceRoots: workspaceRoots, lastPrompt: nil, lastEventAt: date)
        if !workspaceRoots.isEmpty { convo.workspaceRoots = workspaceRoots }
        if let prompt, !prompt.isEmpty { convo.lastPrompt = prompt }
        convo.lastEventAt = date
        conversations[conversationID] = convo
    }

    /// The conversation a freshly dropped Cursor window belongs to: the most
    /// recently active conversation whose workspace basename matches the
    /// dropped window's workspace name, falling back to the most recently
    /// active conversation overall. Mirrors CodexIntegration.currentSessionGuess.
    func currentConversationGuess(workspaceName: String?) -> (id: String, title: String?)? {
        func basename(_ path: String) -> String {
            (path as NSString).lastPathComponent
        }
        let inWorkspace = conversations.filter { _, c in
            guard let workspaceName, !workspaceName.isEmpty else { return false }
            return c.workspaceRoots.contains { basename($0) == workspaceName }
        }
        let pool = inWorkspace.isEmpty ? conversations : inWorkspace
        guard let best = pool.max(by: { $0.value.lastEventAt < $1.value.lastEventAt })
        else { return nil }
        return (best.key, best.value.lastPrompt)
    }

    /// Classify a Cursor turn-end message into done vs needsAttention, shared
    /// with the Claude path.
    func classifyFinalMessage(
        _ text: String, bearer: String?
    ) async -> (status: DropStatus, reason: String)? {
        await classifyAgentFinalMessage(text, agentName: "Cursor", bearer: bearer)
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds.

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandApp/CursorIntegration.swift Sources/SuperIslandApp/ClaudeIntegration.swift
git commit -m "feat(app): CursorIntegration — install hooks, conversation index, shared turn-end classify"
```

---

## Task 8: Wire `CursorIntegration` into `AppController`

**Files:**
- Modify: `Sources/SuperIslandApp/AppController.swift`

**Interfaces:**
- Consumes: `CursorIntegration` (Task 7), `CursorHookMapper`/`CursorHookEvent` (Tasks 2-3), `EditorWindowTitle` (existing pure parser, still used to read the dropped window's workspace name).
- Produces: `let cursorIntegration` on `AppController`; `handleCursorHookEvent`; Cursor binding in `createDrop`; Cursor branch in `isExternallyManaged` and `missingIntegration`.

- [ ] **Step 1: Declare the integration** after `codexIntegration` (line 20):

```swift
    let cursorIntegration = CursorIntegration()
```

- [ ] **Step 2: Add a per-conversation response stash** near `claudeToolGeneration` (line 39):

```swift
    /// Last `afterAgentResponse` text per Cursor conversation id, classified at
    /// `stop` to tell "done" from "waiting on you" (the stop payload has no text).
    private var cursorLastResponse: [String: String] = [:]
```

- [ ] **Step 3: Reconcile hooks on launch** — in `start()`, after `claudeIntegration.reconcile()` (line 102):

```swift
        cursorIntegration.reconcile()
```

- [ ] **Step 4: Route the event** — in `startShellServer()`, after the `onCodexEvent` assignment (lines 140-142):

```swift
        shellServer.onCursorEvent = { [weak self] event in
            self?.handleCursorHookEvent(event)
        }
```

- [ ] **Step 5: Gate the AI monitor off** — in the `isExternallyManaged` closure, before its final `return` (after line 162, inside the closure):

```swift
            if drop.target.contentURL?.hasPrefix(CursorIntegration.sessionURLPrefix) == true {
                return true
            }
```

(Place it right before the Codex `return self.settings.codexIntegrationEnabled && …` line; make that Codex line the last statement, and add the Cursor `if` above it.)

- [ ] **Step 6: Add the event handler** — a new section after the Codex handlers (after line 339):

```swift
    // MARK: - Cursor agent hooks

    private func handleCursorHookEvent(_ event: CursorHookEvent) {
        guard auth.isSignedIn else { return }  // signed out → app is locked
        // Feed the conversation index regardless of whether a drop exists yet,
        // so a drop placed moments later can bind to this conversation.
        cursorIntegration.recordEvent(
            conversationID: event.conversationID, workspaceRoots: event.workspaceRoots,
            prompt: event.prompt, at: Date()
        )
        // Stash the assistant message for turn-end classification at `stop`.
        if event.event == "afterAgentResponse", let text = event.text, !text.isEmpty {
            cursorLastResponse[event.conversationID] = text
        }

        guard let update = CursorHookMapper.update(for: event) else { return }
        let label = AgentSessionLabel.label(agent: "Cursor", prompt: event.prompt)

        guard let drop = cursorDrop(for: event) else { return }
        hookManagedDrops.insert(drop.id)

        // `stop` ends the turn — refine completed into done vs needsAttention
        // from the stashed assistant message (the stop payload carries no text).
        if event.event == "stop", event.status != "error" {
            let stashed = cursorLastResponse[event.conversationID]
            cursorLastResponse[event.conversationID] = nil
            refineCursorTurnEnd(dropID: drop.id, label: label, message: stashed)
            return
        }
        apply(update, to: drop, label: label)
    }

    /// The drop a Cursor hook event belongs to: a GUI drop matched by the
    /// `cursor://session/<id>` content URL, a cursor-agent CLI drop matched by
    /// TTY, or an unbound Cursor drop adopted on its first event (cold start).
    private func cursorDrop(for event: CursorHookEvent) -> Drop? {
        let sessionURL = CursorIntegration.sessionURLPrefix + event.conversationID
        if let drop = store.drops.first(where: { $0.target.contentURL == sessionURL }) {
            return drop
        }
        if let drop = terminalDrop(tty: event.tty),
            store.setContentURL(id: drop.id, url: sessionURL)
        {
            return drop
        }
        // Cold start: a Cursor drop placed before any event this session has no
        // session URL yet. Adopt the most recent unbound Cursor drop and bind it.
        if let drop = store.drops.last(where: { d in
            d.target.bundleID == CursorIntegration.bundleID
                && (d.target.contentURL?.hasPrefix(CursorIntegration.sessionURLPrefix) != true)
        }), store.setContentURL(id: drop.id, url: sessionURL) {
            return drop
        }
        return nil
    }

    /// Resolve a Cursor `stop` into done vs needs-attention from the stashed
    /// assistant message (Haiku when a token is set, structural heuristic
    /// otherwise). Falls back to plain "done" when there's no message.
    private func refineCursorTurnEnd(dropID: UUID, label: String?, message: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let token = await self.auth.validAccessToken()
            let result: (status: DropStatus, reason: String)?
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = await self.cursorIntegration.classifyFinalMessage(message, bearer: token)
            } else {
                result = nil
            }
            guard self.store.drop(id: dropID) != nil else { return }
            self.store.updateStatusAndLabel(
                id: dropID,
                to: result?.status ?? .done,
                label: label,
                reason: result?.reason ?? "Cursor finished — ready for you"
            )
        }
    }
```

- [ ] **Step 7: Bind the drop at drop time** — in `createDrop()`, after the Codex binding block (after line 883, before the Claude Desktop block):

```swift
        // Cursor desktop: no TTY for the GUI — bind to the conversation most
        // recently active in the dropped window's workspace (the one you're
        // looking at), the same recency rule Codex uses for threads.
        if front.bundleID == CursorIntegration.bundleID, cursorIntegration.isInstalled {
            let workspaceName = EditorWindowTitle.parse(front.title).workspaceName
            if let convo = cursorIntegration.currentConversationGuess(workspaceName: workspaceName) {
                contentURL = CursorIntegration.sessionURLPrefix + convo.id
                threadLabel = AgentSessionLabel.label(agent: "Cursor", prompt: convo.title)
                    ?? threadLabel
            }
        }
```

- [ ] **Step 8: Resolve the required-integration check** — in `missingIntegration(for:)`, add a case to the `switch required` (after the `.codex` case, line 792-793):

```swift
        case .cursor:
            cursorIntegration.refresh()
            installed = cursorIntegration.isInstalled
```

- [ ] **Step 9: Build**

Run: `swift build`
Expected: builds. Fix any compile errors (e.g. closure placement in `isExternallyManaged`).

- [ ] **Step 10: Commit**

```bash
git add Sources/SuperIslandApp/AppController.swift
git commit -m "feat(app): wire Cursor hooks into AppController (bind, status, cold-start adopt)"
```

---

## Task 9: UI wiring — onboarding row + settings card + env objects

**Files:**
- Modify: `Sources/SuperIslandApp/SuperIslandApp.swift:31-42`
- Modify: `Sources/SuperIslandApp/Onboarding/OnboardingWindow.swift:37-45`
- Modify: `Sources/SuperIslandApp/Onboarding/OnboardingView.swift` (env objects + row + refresh)
- Modify: `Sources/SuperIslandApp/SettingsPanes.swift` (env object + card + refresh)

**Interfaces:**
- Consumes: `controller.cursorIntegration` (Task 8). `IntegrationCard`, `IntegrationRow`, the `statusChip`/`installToggle` helpers (existing).

- [ ] **Step 1: Inject the env object — Settings scene** (`SuperIslandApp.swift`, after the `claudeIntegration` line):

```swift
        .environmentObject(appDelegate.controller.cursorIntegration)
```

- [ ] **Step 2: Inject the env object — Onboarding** (`OnboardingWindow.swift`, after the `claudeIntegration` line):

```swift
    .environmentObject(controller.cursorIntegration)
```

- [ ] **Step 3: Declare the env object in `OnboardingView` and `IntegrationsStepView`** (`OnboardingView.swift`) — after each `@EnvironmentObject var claudeIntegration: ClaudeIntegration` declaration (two sites: lines ~12 and ~253):

```swift
    @EnvironmentObject var cursorIntegration: CursorIntegration
```

- [ ] **Step 4: Add the Cursor onboarding row** (`OnboardingView.swift`) — immediately after the Claude `IntegrationRow` block (ends ~line 294):

```swift
                // Cursor
                IntegrationRow(
                    icon: "cursorarrow.rays", name: "Cursor",
                    caption: "agent hooks · live even in background windows"
                ) {
                    statusChip(active: cursorIntegration.isInstalled)
                    installToggle(isOn: cursorIntegration.isInstalled) { on in
                        if on {
                            try cursorIntegration.install()
                        } else {
                            cursorIntegration.uninstall()
                        }
                    }
                }
```

- [ ] **Step 5: Refresh Cursor during onboarding** (`OnboardingView.swift`, in `refreshAll()`, after `claudeIntegration.refresh()`):

```swift
        cursorIntegration.refresh()
```

- [ ] **Step 6: Declare the env object + error state in `IntegrationsSettingsPane`** (`SettingsPanes.swift`) — after `claudeIntegration` (line ~205) and after `claudeError` (line ~209):

```swift
    @EnvironmentObject var cursorIntegration: CursorIntegration
```
```swift
    @State private var cursorError: String?
```

- [ ] **Step 7: Render the card** (`SettingsPanes.swift`) — add `cursorCard` to the `VStack` after `claudeCard` (line ~215):

```swift
                claudeCard
                cursorCard
                codexCard
```

And refresh it in `.onAppear` after `claudeIntegration.refresh()` (line ~225):

```swift
            cursorIntegration.refresh()
```

- [ ] **Step 8: Define `cursorCard`** (`SettingsPanes.swift`) — immediately after the `claudeCard` computed property (after line ~299):

```swift
    // MARK: Cursor

    private var cursorCard: some View {
        IntegrationCard(
            icon: "cursorarrow.rays", color: .indigo,
            title: "Cursor",
            status: cursorIntegration.isInstalled ? ("Active", .green) : ("Not set up", .gray)
        ) {
            Text(
                "Live status for Cursor's agent (Composer) via Cursor's own hooks: the instant Cursor finishes or needs you, your drop updates — even in background windows. No AI calls."
            )
            .settingsCaption()

            if let cursorError {
                Text(cursorError).font(.caption).foregroundStyle(.red)
            }

            if cursorIntegration.isInstalled {
                HStack {
                    Text("Applies to conversations after setup. Restart Cursor to load hooks.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Uninstall", role: .destructive) {
                        cursorIntegration.uninstall()
                    }
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Button("Set Up Cursor Hooks") {
                        do {
                            try cursorIntegration.install()
                            cursorError = nil
                        } catch {
                            cursorError = "Setup failed: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Text("Adds hook entries to ~/.cursor/hooks.json")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }
```

- [ ] **Step 9: Build**

Run: `swift build`
Expected: builds. (A missing `@EnvironmentObject` declaration crashes at runtime, not compile — double-check all four sites are wired before Task 10.)

- [ ] **Step 10: Commit**

```bash
git add Sources/SuperIslandApp/SuperIslandApp.swift Sources/SuperIslandApp/Onboarding/ Sources/SuperIslandApp/SettingsPanes.swift
git commit -m "feat(app): Cursor integration UI — onboarding row + settings card"
```

---

## Task 10: End-to-end manual verification

**Goal:** Confirm the whole pipeline works against the real Cursor app, since the app target has no unit tests.

- [ ] **Step 1: Build and run the app**

Run: `swift build && swift run SuperIslandApp` (or launch the built app). Sign in.

- [ ] **Step 2: Install the integration**

In SuperIsland → Settings → Integrations → Cursor → "Set Up Cursor Hooks". Verify:

```bash
cat ~/.cursor/hooks.json
ls -l ~/.config/superisland/superisland-cursor-hook.sh
```
Expected: `hooks.json` has our script under `beforeSubmitPrompt`/`afterAgentResponse`/`stop`/`sessionEnd`; the script is executable.

- [ ] **Step 3: Restart Cursor** (so it reloads `hooks.json`), open a workspace, and submit a prompt to the agent.

- [ ] **Step 4: Drop on the Cursor window** (⌥⌘K or the configured gesture) while/just after the agent runs. Expected: a drop badged **"Cursor"** (not "VS Code"/curlybraces), label from your prompt, status **working** (orange).

- [ ] **Step 5: Let the turn finish.** Expected: status flips to **done** ("ready for you"). Then run a turn that ends by asking you a question; expected: **needsAttention** ("waiting for your reply").

- [ ] **Step 6: Confirm no editor drop.** Dropping on Cursor never produces a `.editor` "file · workspace" drop anymore. VS Code still does (drop on a VS Code window → editor drop, unchanged).

- [ ] **Step 7: Uninstall** via Settings. Verify our entries are gone from `~/.cursor/hooks.json` and the script file is removed; any pre-existing user hooks remain.

- [ ] **Step 8: Tail the hook debug log if anything misbehaves**

The `/cursor` route logs raw payloads via `HookDebugLog`. If a field didn't decode, the log shows `DECODE FAILED for /cursor payload` — compare against the Task 0 fixture and correct `CursorHookEvent` CodingKeys.

- [ ] **Step 9: Commit any field-name corrections** discovered here (to `CursorHookEvent`/tests), then the feature branch is ready for review/merge.

---

## Notes for the implementer

- **Order matters:** Tasks 1-5 are pure `SuperIslandCore` with real unit tests — do them first and keep `swift test` green. Tasks 6-9 are app glue verified by `swift build` + Task 10. Task 0 should run before Task 2 so the decoder uses real field names.
- **DRY:** the turn-end classifier is extracted once (Task 7, Step 1) and shared by Claude and Cursor. Don't duplicate it.
- **YAGNI:** no `CursorAdapter` (Cursor rides `GenericAXAdapter` like Codex), no `IntegrationRouter` change (Cursor is `.generic`+contentURL like Codex), no permission-hook needsAttention (turn-end classification is the primary path), no SQLite/session-journal polling.
- **Intentional spec deviation — `Classifier.swift` is left unchanged.** The spec's decoupling table suggested tightening the classifier system prompt. We skip it deliberately: that prompt is **shared** by the Claude/Chrome/terminal classification paths, so editing it risks regressing working integrations, and it buys nothing here — Cursor drops are externally-managed (`isExternallyManaged` returns true for `cursor://session/` drops), so the AI classifier never runs on them. Leaving "Cursor" in the prompt is harmless.
- **If Cursor field names differ** from the documented ones (Task 0), the only places to fix are `CursorHookEvent.CodingKeys` and the Task 2 test JSON. Everything downstream uses the decoded Swift fields.
