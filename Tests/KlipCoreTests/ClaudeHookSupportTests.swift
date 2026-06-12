import XCTest
@testable import KlipCore

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

    // MARK: - Status mapping

    func testEventStatusMapping() {
        func status(_ name: String) -> KlipStatus? {
            ClaudeHookMapper.update(for: ClaudeHookEvent(sessionID: "s", event: name))?.status
        }
        XCTAssertEqual(status("UserPromptSubmit"), .working)
        XCTAssertEqual(status("Stop"), .done)
        XCTAssertEqual(status("StopFailure"), .needsAttention)
        XCTAssertEqual(status("Notification"), .needsAttention)
        XCTAssertNil(status("SessionEnd"))            // reason-only update
        XCTAssertNil(ClaudeHookMapper.update(
            for: ClaudeHookEvent(sessionID: "s", event: "PreToolUse")
        ))                                            // unmapped event ignored
    }

    func testNotificationMessageBecomesReason() {
        let update = ClaudeHookMapper.update(for: ClaudeHookEvent(
            sessionID: "s", event: "Notification", message: "Permission needed"
        ))
        XCTAssertEqual(update?.reason, "Permission needed")
    }

    // MARK: - settings.json configurator

    private let script = "/Users/x/.config/klip/klip-claude-hook.sh"

    func testInstallPreservesExistingHooksAndIsIdempotent() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PostToolUse": [
                    ["matcher": "Edit", "hooks": [["type": "command", "command": "prettier"]]],
                ],
            ],
        ]
        let once = ClaudeHooksConfigurator.install(settings: existing, scriptPath: script)
        let twice = ClaudeHooksConfigurator.install(settings: once, scriptPath: script)

        XCTAssertEqual(twice["model"] as? String, "opus")
        let hooks = twice["hooks"] as? [String: Any] ?? [:]
        XCTAssertNotNil(hooks["PostToolUse"])         // untouched
        for event in ClaudeHooksConfigurator.events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            let ours = groups.filter {
                (($0["hooks"] as? [[String: Any]]) ?? [])
                    .contains { ($0["command"] as? String)?.contains("klip-claude-hook") == true }
            }
            XCTAssertEqual(ours.count, 1, "exactly one Klip entry for \(event)")
        }
        XCTAssertTrue(ClaudeHooksConfigurator.isInstalled(settings: twice))
    }

    func testUninstallRemovesOnlyOurEntries() {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["matcher": "", "hooks": [["type": "command", "command": "say done"]]]],
            ],
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
