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
