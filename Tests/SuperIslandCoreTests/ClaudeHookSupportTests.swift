import XCTest
@testable import SuperIslandCore

final class ClaudeHookSupportTests: XCTestCase {
    // MARK: - Event decoding

    func testDecodesHookStdinPayload() throws {
        let json = """
            {"session_id":"ef360e63-fcbf","transcript_path":"/t.jsonl","cwd":"/Users/x",
             "hook_event_name":"Notification","message":"Claude needs permission to use Bash"}
            """
        let event = try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.sessionID, "ef360e63-fcbf")
        XCTAssertEqual(event.event, "Notification")
        XCTAssertEqual(event.message, "Claude needs permission to use Bash")
    }

    func testDecodesTranscriptPathAndPermissionMode() throws {
        let json = """
            {"session_id":"s1","hook_event_name":"PreToolUse",
             "transcript_path":"/Users/x/.claude/projects/-Users-x/s1.jsonl",
             "permission_mode":"default","tool_name":"Bash"}
            """
        let event = try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.event, "PreToolUse")
        XCTAssertEqual(event.transcriptPath, "/Users/x/.claude/projects/-Users-x/s1.jsonl")
        XCTAssertEqual(event.permissionMode, "default")
    }

    // MARK: - Status mapping

    func testEventStatusMapping() {
        func status(_ name: String) -> DropStatus? {
            ClaudeHookMapper.update(for: ClaudeHookEvent(sessionID: "s", event: name))?.status
        }
        XCTAssertEqual(status("UserPromptSubmit"), .working)
        XCTAssertEqual(status("Stop"), .done)
        XCTAssertEqual(status("StopFailure"), .needsAttention)
        XCTAssertEqual(status("Notification"), .needsAttention)
        XCTAssertNil(status("SessionEnd"))  // reason-only update
        // Tool-use events mean the agent resumed — they clear a prior
        // needsAttention (e.g. after you approve a permission prompt).
        XCTAssertEqual(status("PreToolUse"), .working)
        XCTAssertEqual(status("PostToolUse"), .working)
        XCTAssertNil(status("SomethingElse"))  // unmapped event ignored
    }

    func testAskUserQuestionPreToolUseNeedsAttention() {
        // The multi-select / question tool always blocks on the user, no matter
        // the permission mode — so a PreToolUse for it is an immediate "needs
        // you", not "working". (A blocked permission prompt fires no hook, but
        // this tool's PreToolUse is itself the signal.)
        let ask = ClaudeHookMapper.update(
            for: ClaudeHookEvent(
                sessionID: "s", event: "PreToolUse", toolName: "AskUserQuestion"
            ))
        XCTAssertEqual(ask?.status, .needsAttention)

        // An ordinary tool is still just "working" while it runs.
        let bash = ClaudeHookMapper.update(
            for: ClaudeHookEvent(sessionID: "s", event: "PreToolUse", toolName: "Bash"))
        XCTAssertEqual(bash?.status, .working)

        // Answering it resumes the agent: PostToolUse clears needsAttention.
        let answered = ClaudeHookMapper.update(
            for: ClaudeHookEvent(
                sessionID: "s", event: "PostToolUse", toolName: "AskUserQuestion"
            ))
        XCTAssertEqual(answered?.status, .working)
    }

    func testManagedEventsCoverToolUse() {
        // Tool-use events must be installed, or the hook never delivers them.
        XCTAssertTrue(ClaudeHooksConfigurator.events.contains("PreToolUse"))
        XCTAssertTrue(ClaudeHooksConfigurator.events.contains("PostToolUse"))
    }

    func testIdleNotificationIsReadyNotAttention() {
        // The ~60s idle notification after Claude finishes must not flip the
        // drop to needsAttention — it means "your turn", not an interruption.
        let idle = ClaudeHookMapper.update(
            for: ClaudeHookEvent(
                sessionID: "s", event: "Notification", message: "Claude is waiting for your input"
            ))
        XCTAssertEqual(idle?.status, .done)

        // A genuine permission notification still needs attention.
        let perm = ClaudeHookMapper.update(
            for: ClaudeHookEvent(
                sessionID: "s", event: "Notification",
                message: "Claude needs your permission to use Bash"
            ))
        XCTAssertEqual(perm?.status, .needsAttention)
    }

    func testNotificationMessageBecomesReason() {
        let update = ClaudeHookMapper.update(
            for: ClaudeHookEvent(
                sessionID: "s", event: "Notification", message: "Permission needed"
            ))
        XCTAssertEqual(update?.reason, "Permission needed")
    }

    func testDecodesNotificationTypeAndLastAssistantMessage() throws {
        let json = """
            {"session_id":"s1","hook_event_name":"Stop",
             "last_assistant_message":"All done — nothing else needed.",
             "notification_type":"idle_prompt"}
            """
        let event = try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.lastAssistantMessage, "All done — nothing else needed.")
        XCTAssertEqual(event.notificationType, "idle_prompt")
    }

    func testNotificationMappingPrefersTypedField() {
        func status(type: String?, message: String? = nil) -> DropStatus? {
            ClaudeHookMapper.update(
                for: ClaudeHookEvent(
                    sessionID: "s", event: "Notification", message: message, notificationType: type
                ))?.status
        }
        // Typed fields are exact ground truth, no string matching.
        XCTAssertEqual(status(type: "idle_prompt"), .done)
        XCTAssertEqual(status(type: "permission_prompt"), .needsAttention)
        XCTAssertEqual(status(type: "elicitation_dialog"), .needsAttention)
        // Non-actionable notifications change no task status.
        XCTAssertNil(status(type: "auth_success"))
        // No type (older Claude Code) → fall back to the message text.
        XCTAssertEqual(status(type: nil, message: "Claude is waiting for your input"), .done)
        XCTAssertEqual(status(type: nil, message: "Claude needs your permission"), .needsAttention)
    }

    // MARK: - settings.json configurator

    private let script = "/Users/x/.config/superisland/superisland-claude-hook.sh"

    func testInstallPreservesExistingHooksAndIsIdempotent() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PostToolUse": [
                    ["matcher": "Edit", "hooks": [["type": "command", "command": "prettier"]]]
                ]
            ],
        ]
        let once = ClaudeHooksConfigurator.install(settings: existing, scriptPath: script)
        let twice = ClaudeHooksConfigurator.install(settings: once, scriptPath: script)

        XCTAssertEqual(twice["model"] as? String, "opus")
        let hooks = twice["hooks"] as? [String: Any] ?? [:]
        XCTAssertNotNil(hooks["PostToolUse"])  // untouched
        for event in ClaudeHooksConfigurator.events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            let ours = groups.filter {
                (($0["hooks"] as? [[String: Any]]) ?? [])
                    .contains {
                        ($0["command"] as? String)?.contains("superisland-claude-hook") == true
                    }
            }
            XCTAssertEqual(ours.count, 1, "exactly one SuperIsland entry for \(event)")
        }
        XCTAssertTrue(ClaudeHooksConfigurator.isInstalled(settings: twice))
    }

    func testUninstallRemovesOnlyOurEntries() {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["matcher": "", "hooks": [["type": "command", "command": "say done"]]]]
            ]
        ]
        let installed = ClaudeHooksConfigurator.install(settings: existing, scriptPath: script)
        let removed = ClaudeHooksConfigurator.uninstall(settings: installed)

        XCTAssertFalse(ClaudeHooksConfigurator.isInstalled(settings: removed))
        let hooks = removed["hooks"] as? [String: Any] ?? [:]
        let stop = hooks["Stop"] as? [[String: Any]] ?? []
        XCTAssertEqual(stop.count, 1, "user's own Stop hook survives")
        XCTAssertNil(hooks["Notification"], "events we added are fully removed")
    }

    // MARK: - Session metadata join

    func testParsesLocalSessionMetadata() {
        let json = """
            {"sessionId":"local_0ead4972-4f52","cliSessionId":"ef360e63-fcbf",
             "title":"macOS task status tracking app","model":"claude-fable-5"}
            """
        let session = ClaudeLocalSession.parse(data: Data(json.utf8))
        XCTAssertEqual(session?.sessionID, "local_0ead4972-4f52")
        XCTAssertEqual(session?.cliSessionID, "ef360e63-fcbf")
        XCTAssertEqual(session?.title, "macOS task status tracking app")
    }
}
