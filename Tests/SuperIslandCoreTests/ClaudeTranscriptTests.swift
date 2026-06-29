import XCTest
@testable import SuperIslandCore

final class ClaudeTranscriptTests: XCTestCase {
    func testTranscriptPathEncoding() {
        let home = URL(fileURLWithPath: "/Users/akhil")
        XCTAssertEqual(
            ClaudeTranscript.path(home: home, cwd: "/Users/akhil/useklip", cliSessionID: "abc")
                .path,
            "/Users/akhil/.claude/projects/-Users-akhil-useklip/abc.jsonl"
        )
        // cwd containing a dot dir (.claude worktree) — '/' and '.' both → '-'.
        XCTAssertEqual(
            ClaudeTranscript.path(
                home: home,
                cwd: "/Users/akhil/whizibility/.claude/worktrees/x-858d88",
                cliSessionID: "s1"
            ).path,
            "/Users/akhil/.claude/projects/-Users-akhil-whizibility--claude-worktrees-x-858d88/s1.jsonl"
        )
    }

    func testProjectDirectoryEncoding() {
        let home = URL(fileURLWithPath: "/Users/akhil")
        XCTAssertEqual(
            ClaudeTranscript.projectDirectory(home: home, cwd: "/Users/akhil/useklip").path,
            "/Users/akhil/.claude/projects/-Users-akhil-useklip"
        )
    }

    func testTrailingToolUseIsWorking() {
        let tail = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]}}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}
            """
        XCTAssertEqual(ClaudeTranscript.state(fromTail: tail), .working)
    }

    func testTrailingAskUserQuestionIsAwaitingInput() {
        // A pending AskUserQuestion tool_use isn't a tool "running" — it's
        // blocked on the user's answer. It must read as awaitingInput so a
        // hookless Claude Desktop session still surfaces as needs-you.
        let tail = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Pick one."}]}}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion"}]}}
            """
        XCTAssertEqual(ClaudeTranscript.state(fromTail: tail), .awaitingInput)
    }

    func testAnsweredAskUserQuestionIsNoLongerAwaiting() {
        // Once answered, a tool_result follows the tool_use — the session has
        // resumed, so it's no longer awaiting input.
        let tail = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion"}]}}
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Thanks — proceeding."}]}}
            """
        XCTAssertEqual(
            ClaudeTranscript.state(fromTail: tail), .turnEnded(text: "Thanks — proceeding."))
    }

    func testToolResultAfterToolUseIsTurnEnded() {
        let tail = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All tests pass."}]}}
            """
        XCTAssertEqual(ClaudeTranscript.state(fromTail: tail), .turnEnded(text: "All tests pass."))
    }

    func testPartialFirstLineSkipped() {
        let tail = """
            ent":[{"type":"text","text":"garbled half line
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Which option — 1, 2, or 3?"}]}}
            """
        XCTAssertEqual(
            ClaudeTranscript.state(fromTail: tail),
            .turnEnded(text: "Which option — 1, 2, or 3?")
        )
    }

    func testRequestHeuristic() {
        XCTAssertTrue(ClaudeTranscript.looksLikeRequest("Which one do you want?"))
        XCTAssertTrue(ClaudeTranscript.looksLikeRequest("Go ahead and run it, then let me know."))
        XCTAssertTrue(ClaudeTranscript.looksLikeRequest("Please confirm before I continue."))
        XCTAssertFalse(
            ClaudeTranscript.looksLikeRequest("Done. All tests pass and I pushed to main."))
        XCTAssertFalse(ClaudeTranscript.looksLikeRequest(""))
    }
}
