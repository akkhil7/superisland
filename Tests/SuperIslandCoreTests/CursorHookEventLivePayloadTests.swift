import XCTest

@testable import SuperIslandCore

/// Decodes payloads captured verbatim from a live Cursor 3.8.24 GUI agent
/// (`Tests/.../Fixtures/cursor-hook-samples.md`, email redacted). This proves
/// `CursorHookEvent` decodes real Cursor events — correct field names AND
/// graceful ignoring of Cursor's many extra fields (generation_id, model,
/// token counts, attachments, transcript_path, …).
final class CursorHookEventLivePayloadTests: XCTestCase {
    private func decode(_ fragments: [String]) throws -> CursorHookEvent {
        try JSONDecoder().decode(CursorHookEvent.self, from: Data(fragments.joined().utf8))
    }

    func testDecodesRealBeforeSubmitPrompt() throws {
        let e = try decode([
            #"{"conversation_id":"2dd698cf","generation_id":"f202b57e","#,
            #""model":"composer-2.5-fast","model_params":[{"id":"fast","value":"true"}],"#,
            #""composer_mode":"agent","prompt":"Ask me a question please","attachments":[],"#,
            #""session_id":"2dd698cf","hook_event_name":"beforeSubmitPrompt","#,
            #""cursor_version":"3.8.24","workspace_roots":["/Users/akhil/memorial-app"],"#,
            #""user_email":"redacted","transcript_path":null}"#,
        ])
        XCTAssertEqual(e.event, "beforeSubmitPrompt")
        XCTAssertEqual(e.conversationID, "2dd698cf")
        XCTAssertEqual(e.prompt, "Ask me a question please")
        XCTAssertEqual(e.workspaceRoots, ["/Users/akhil/memorial-app"])
        XCTAssertNil(e.text)
        XCTAssertNil(e.status)
    }

    func testDecodesRealAfterAgentResponseExtractsText() throws {
        let e = try decode([
            #"{"conversation_id":"2dd698cf","generation_id":"b24cb514","#,
            #""model":"composer-2.5-fast","#,
            #""text":"Sounds good. If you want to dig into any part later, just ask.","#,
            #""input_tokens":46939,"output_tokens":65,"session_id":"2dd698cf","#,
            #""hook_event_name":"afterAgentResponse","cursor_version":"3.8.24","#,
            #""workspace_roots":["/Users/akhil/memorial-app"],"#,
            #""transcript_path":"/Users/akhil/.cursor/projects/x/y.jsonl"}"#,
        ])
        XCTAssertEqual(e.event, "afterAgentResponse")
        XCTAssertEqual(e.text, "Sounds good. If you want to dig into any part later, just ask.")
        XCTAssertNil(e.status)
    }

    func testDecodesRealStopCompleted() throws {
        let e = try decode([
            #"{"conversation_id":"2dd698cf","generation_id":"b24cb514","status":"completed","#,
            #""loop_count":0,"input_tokens":46939,"output_tokens":65,"session_id":"2dd698cf","#,
            #""hook_event_name":"stop","cursor_version":"3.8.24","#,
            #""workspace_roots":["/Users/akhil/memorial-app"]}"#,
        ])
        XCTAssertEqual(e.event, "stop")
        XCTAssertEqual(e.status, "completed")
        XCTAssertEqual(e.conversationID, "2dd698cf")
        XCTAssertNil(e.text)
    }
}
