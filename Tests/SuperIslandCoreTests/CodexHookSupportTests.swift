import XCTest
@testable import SuperIslandCore

final class CodexHookSupportTests: XCTestCase {
    // MARK: - Status mapping

    func testEventStatusMapping() {
        func status(_ name: String) -> DropStatus? {
            CodexHookMapper.update(for: ClaudeHookEvent(sessionID: "s", event: name))?.status
        }
        XCTAssertEqual(status("UserPromptSubmit"), .working)
        XCTAssertEqual(status("Stop"), .done)
        XCTAssertEqual(status("PermissionRequest"), .needsAttention)
        XCTAssertNil(
            CodexHookMapper.update(
                for: ClaudeHookEvent(sessionID: "s", event: "PreToolUse")
            ))
    }

    // MARK: - Session index parsing

    func testParsesSessionIndexJSONL() {
        let jsonl = """
            {"id":"019deab5-43c0","thread_name":"Polish UI and fix gaps","updated_at":"2026-05-02T22:03:11.701915Z"}
            {"id":"019ead9f-8e6c","thread_name":"Understand project purpose","updated_at":"2026-06-09T18:23:25.457995Z"}
            not json
            {"id":"019deab5-43c0","thread_name":"Polish UI (renamed)","updated_at":"2026-06-10T01:00:00.000000Z"}
            """
        let entries = CodexSessionIndex.parse(jsonl: jsonl)
        XCTAssertEqual(entries.count, 2)
        // Later lines win for the same id.
        XCTAssertEqual(entries["019deab5-43c0"]?.threadName, "Polish UI (renamed)")
        XCTAssertNotNil(entries["019ead9f-8e6c"]?.updatedAt)
    }

    func testMostRecentPicksLatestUpdatedThread() {
        let entries = CodexSessionIndex.parse(
            jsonl: """
                {"id":"a","thread_name":"Old","updated_at":"2026-05-02T22:03:11.701915Z"}
                {"id":"b","thread_name":"New","updated_at":"2026-06-09T18:23:25.457995Z"}
                """)
        XCTAssertEqual(CodexSessionIndex.mostRecent(in: entries)?.id, "b")
    }

    // MARK: - Rollout journal scanning

    func testSessionIDFromRolloutFilename() {
        XCTAssertEqual(
            CodexRollout.sessionID(
                fromFilename:
                    "rollout-2026-06-09T23-52-55-019ead9f-8e6c-7173-abb5-69277fdcc142.jsonl"
            ),
            "019ead9f-8e6c-7173-abb5-69277fdcc142"
        )
        XCTAssertNil(CodexRollout.sessionID(fromFilename: "notes.jsonl"))
        XCTAssertNil(CodexRollout.sessionID(fromFilename: "rollout-short.jsonl"))
    }

    func testRolloutTailProducesLatestStatus() {
        let tail = """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
            {"type":"response_item","payload":{"type":"message","role":"assistant"}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"All tests pass."}}
            """
        let update = CodexRollout.latestUpdate(fromTail: tail)
        XCTAssertEqual(update?.status, .done)
        XCTAssertEqual(update?.reason, "All tests pass.")
    }

    func testRolloutWorkingAndPartialFirstLine() {
        let tail = """
            d","content":[{"type":"input_text"}]}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"t0"}}
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
            """
        let update = CodexRollout.latestUpdate(fromTail: tail)
        XCTAssertEqual(update?.status, .working)
    }

    func testRolloutApprovalNeedsAttention() {
        let tail = """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
            {"type":"event_msg","payload":{"type":"exec_approval_request","command":"rm -rf build"}}
            """
        XCTAssertEqual(CodexRollout.latestUpdate(fromTail: tail)?.status, .needsAttention)
    }

    func testRolloutResumesWorkingAfterApproval() {
        // You approve the command in the terminal → Codex runs it. The begin
        // event must clear the approval's needsAttention.
        let tail = """
            {"type":"event_msg","payload":{"type":"exec_approval_request","command":"rm -rf build"}}
            {"type":"event_msg","payload":{"type":"exec_command_begin","command":"rm -rf build"}}
            """
        XCTAssertEqual(CodexRollout.latestUpdate(fromTail: tail)?.status, .working)
    }

    // MARK: - Workspace focus signal

    func testActiveWorkspaceRootsParsing() {
        let json = #"{"active-workspace-roots":["/Users/akhil/drop"],"project-order":[]}"#
        XCTAssertEqual(
            CodexWorkspaceState.activeWorkspaceRoots(fromJSON: Data(json.utf8)),
            ["/Users/akhil/drop"]
        )
        XCTAssertEqual(CodexWorkspaceState.activeWorkspaceRoots(fromJSON: Data("{}".utf8)), [])
    }

    func testCwdWorkspaceMatching() {
        let roots = ["/Users/akhil/drop"]
        XCTAssertTrue(CodexWorkspaceState.cwd("/Users/akhil/drop", isUnderAnyOf: roots))
        XCTAssertTrue(CodexWorkspaceState.cwd("/Users/akhil/drop/Sources", isUnderAnyOf: roots))
        // Sibling with a shared prefix must NOT match.
        XCTAssertFalse(CodexWorkspaceState.cwd("/Users/akhil/drop-v2", isUnderAnyOf: roots))
        XCTAssertFalse(CodexWorkspaceState.cwd("/Users/akhil/whizibility", isUnderAnyOf: roots))
    }

    func testRolloutCwdFromHead() {
        let head = """
            {"type":"session_meta","payload":{"id":"019ead9f","timestamp":"2026-06-09","cwd":"/Users/akhil/drop"}}
            {"type":"turn_context","payload":{"turn_id":"t1","cwd":"/Users/akhil/drop"}}
            """
        XCTAssertEqual(CodexRollout.cwd(fromHead: head), "/Users/akhil/drop")
        XCTAssertNil(
            CodexRollout.cwd(fromHead: #"{"type":"event_msg","payload":{"type":"task_started"}}"#))
    }

    // MARK: - Deep links

    func testThreadDeepLink() {
        XCTAssertEqual(
            CodexDeepLink.deepLink(forContentURL: "codex://session/019ead9f-8e6c"),
            "codex://threads/019ead9f-8e6c"
        )
        XCTAssertNil(CodexDeepLink.deepLink(forContentURL: "https://example.com"))
    }

    // MARK: - hooks.json configurator (shared engine, Codex parameters)

    func testInstallAndUninstallRoundTrip() {
        let script = "/Users/x/.config/superisland/superisland-codex-hook.sh"
        let installed = AgentHooksConfigurator.install(
            settings: [:], scriptPath: script,
            events: CodexHookMapper.events, marker: CodexHookMapper.commandMarker
        )
        XCTAssertTrue(
            AgentHooksConfigurator.isInstalled(
                settings: installed,
                events: CodexHookMapper.events, marker: CodexHookMapper.commandMarker
            ))
        let hooks = installed["hooks"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(hooks.keys), Set(["UserPromptSubmit", "Stop", "PermissionRequest"]))

        let removed = AgentHooksConfigurator.uninstall(
            settings: installed, marker: CodexHookMapper.commandMarker
        )
        XCTAssertNil(removed["hooks"], "empty hooks object is removed entirely")
    }
}
