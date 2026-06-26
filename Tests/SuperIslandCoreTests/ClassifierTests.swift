import XCTest
@testable import SuperIslandCore

final class ClassifierTests: XCTestCase {
    func testRequestBodyIncludesModelAndText() {
        let input = ClassificationInput(
            appName: "Terminal", windowTitle: "build", axText: "make: done"
        )
        let body = ClassifierProtocolBuilder.requestBody(for: input, model: "claude-opus-4-8")
        XCTAssertEqual(body["model"] as? String, "claude-opus-4-8")
        let messages = body["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        // Text-only → single text block.
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
    }

    func testTurnEndRequestBodyUsesDedicatedPromptAndMessage() {
        let body = ClassifierProtocolBuilder.turnEndRequestBody(
            message: "Want me to build this? It's small.", model: "claude-haiku-4-5"
        )
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5")
        // Uses the focused turn-end classifier prompt, not the window monitor one.
        let system = body["system"] as? String
        XCTAssertEqual(system, ClassifierProtocolBuilder.turnEndSystemPrompt)
        XCTAssertNotEqual(system, ClassifierProtocolBuilder.systemPrompt)
        // The assistant's message is carried as the sole user text block.
        let messages = body["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertTrue((content[0]["text"] as? String)?.contains("Want me to build this?") == true)
    }

    func testParsesCleanJSONResponse() throws {
        let json = """
            {"content":[{"type":"text","text":"{\\"status\\":\\"done\\",\\"reason\\":\\"prompt returned\\",\\"confidence\\":0.9}"}]}
            """
        let c = try ClassifierProtocolBuilder.parse(responseData: Data(json.utf8))
        XCTAssertEqual(c.status, .done)
        XCTAssertEqual(c.reason, "prompt returned")
        XCTAssertEqual(c.confidence, 0.9, accuracy: 0.0001)
    }

    func testParsesJSONWrappedInProseAndFences() throws {
        let inner =
            "Here is my analysis:\\n```json\\n{\\\"status\\\": \\\"needsAttention\\\", \\\"reason\\\": \\\"asks for password\\\", \\\"confidence\\\": 0.8}\\n```"
        let json = """
            {"content":[{"type":"text","text":"\(inner)"}]}
            """
        let c = try ClassifierProtocolBuilder.parse(responseData: Data(json.utf8))
        XCTAssertEqual(c.status, .needsAttention)
        XCTAssertEqual(c.reason, "asks for password")
    }

    func testUnknownStatusStringFallsBackToUnknown() throws {
        let json = """
            {"content":[{"type":"text","text":"{\\"status\\":\\"banana\\",\\"reason\\":\\"\\",\\"confidence\\":0.1}"}]}
            """
        let c = try ClassifierProtocolBuilder.parse(responseData: Data(json.utf8))
        XCTAssertEqual(c.status, .unknown)
    }

    func testMalformedResponseThrows() {
        let json = #"{"content":[{"type":"text","text":"no json here"}]}"#
        XCTAssertThrowsError(try ClassifierProtocolBuilder.parse(responseData: Data(json.utf8)))
    }
}
