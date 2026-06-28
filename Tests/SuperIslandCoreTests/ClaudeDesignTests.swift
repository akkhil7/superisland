import XCTest

@testable import SuperIslandCore

/// Claude Desktop's "Design" feature is a distinct surface: its window is a
/// `claude.ai/design/p/<projectId>` drop, and the agent drives it through the
/// `DesignSync` tool from a separate session whose hook events carry the
/// `projectId`. These tests cover the pure pieces that tie the two together.
final class ClaudeDesignTests: XCTestCase {
    // MARK: - DesignSync event decoding

    /// A DesignSync tool event carries the design project id in
    /// `tool_input.projectId` — the only key that links an otherwise unmatched
    /// session's lifecycle to the `/design/p/<id>` drop on screen.
    func testDecodesDesignSyncProjectID() throws {
        let json = """
            {"session_id":"e7584c77","hook_event_name":"PostToolUse",
             "tool_name":"DesignSync",
             "tool_input":{"method":"get_file","projectId":"114c975a-ea8d-4e8f","path":"x.html"}}
            """
        let event = try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.toolName, "DesignSync")
        XCTAssertEqual(event.designProjectID, "114c975a-ea8d-4e8f")
    }

    /// A normal tool event (e.g. Bash) exposes no design project id.
    func testNonDesignToolEventHasNoProjectID() throws {
        let json = """
            {"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash",
             "tool_input":{"command":"ls"}}
            """
        let event = try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.designProjectID)
    }

    // MARK: - Design content URL

    /// A Design window's drop URL is `claude.ai/design/p/<projectId>`; the
    /// project id is its last path component.
    func testExtractsProjectIDFromDesignURL() {
        XCTAssertEqual(
            ClaudeDesignURL.projectID(
                forContentURL: "https://claude.ai/design/p/114c975a-ea8d-4e8f-9243-7bdd7ced5194"),
            "114c975a-ea8d-4e8f-9243-7bdd7ced5194")
    }

    /// SPAs append scroll/frame fragments; the id must survive normalization.
    func testExtractsProjectIDIgnoringFragment() {
        XCTAssertEqual(
            ClaudeDesignURL.projectID(
                forContentURL: "https://claude.ai/design/p/abc123-def#dframe-main"),
            "abc123-def")
    }

    /// Cowork/Code sessions, foreign hosts, and empty strings are not Design.
    func testNonDesignURLsHaveNoProjectID() {
        XCTAssertNil(
            ClaudeDesignURL.projectID(
                forContentURL: "https://claude.ai/epitaxy/local_4cd4cf52-4a54"))
        XCTAssertNil(ClaudeDesignURL.projectID(forContentURL: "https://example.com/design/p/x"))
        XCTAssertNil(ClaudeDesignURL.projectID(forContentURL: ""))
    }

    // MARK: - Session → project association

    /// A DesignSync event teaches the router which project a session is driving,
    /// so a later `Stop` (whose payload carries no projectId) can still be routed
    /// to the Design drop.
    func testRouterLearnsProjectFromDesignSyncEvent() {
        var router = DesignSessionRouter()
        router.note(
            ClaudeHookEvent(
                sessionID: "S", event: "PostToolUse", toolName: "DesignSync", designProjectID: "P"))
        XCTAssertEqual(router.projectID(forSession: "S"), "P")
    }

    /// Ordinary tool events (no design project) teach the router nothing.
    func testRouterIgnoresNonDesignEvents() {
        var router = DesignSessionRouter()
        router.note(ClaudeHookEvent(sessionID: "S", event: "PreToolUse", toolName: "Bash"))
        XCTAssertNil(router.projectID(forSession: "S"))
    }

    /// A session that switches to a new design project rebinds to the latest one.
    func testRouterUpdatesToLatestProject() {
        var router = DesignSessionRouter()
        router.note(
            ClaudeHookEvent(
                sessionID: "S", event: "PostToolUse", toolName: "DesignSync", designProjectID: "P1")
        )
        router.note(
            ClaudeHookEvent(
                sessionID: "S", event: "PostToolUse", toolName: "DesignSync", designProjectID: "P2")
        )
        XCTAssertEqual(router.projectID(forSession: "S"), "P2")
    }

    // MARK: - End-to-end (real payload shapes)

    /// The exact bug: a Design window's `design/p/<id>` drop is driven by a
    /// separate session through DesignSync, and the session's `Stop` carries no
    /// projectId. Proves the pieces compose against real diagnostics.log shapes —
    /// the DesignSync event teaches the router the project, the association
    /// survives to the Stop, the Stop maps to a settled status, and the routed
    /// project equals the drop URL's project.
    func testDesignSyncEventsBindSessionStopToDesignDrop() throws {
        let designSync = """
            {"session_id":"e7584c77-23e6-49c3-a65c-08a96f184e7f","hook_event_name":"PostToolUse",
             "tool_name":"DesignSync",
             "tool_input":{"method":"get_file","projectId":"114c975a-ea8d-4e8f-9243-7bdd7ced5194",
             "path":"Whizibility Dashboard.dc.html"}}
            """
        let stop = """
            {"session_id":"e7584c77-23e6-49c3-a65c-08a96f184e7f","hook_event_name":"Stop",
             "last_assistant_message":"Done — the landing page is ready."}
            """
        let dropURL = "https://claude.ai/design/p/114c975a-ea8d-4e8f-9243-7bdd7ced5194"

        var router = DesignSessionRouter()
        router.note(try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(designSync.utf8)))
        let stopEvent = try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(stop.utf8))
        router.note(stopEvent)  // Stop carries no projectId — association must persist.

        let routed = router.projectID(forSession: stopEvent.sessionID)
        XCTAssertNotNil(routed)
        XCTAssertEqual(routed, ClaudeDesignURL.projectID(forContentURL: dropURL))
        // The Stop resolves to a settled status (done), not the stuck "working".
        XCTAssertEqual(ClaudeHookMapper.update(for: stopEvent)?.status, .done)
    }
}
