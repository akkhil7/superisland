import XCTest
@testable import SuperIslandCore

final class ChromeBridgeProtocolTests: XCTestCase {
    func testDecodesToolCallRequest() throws {
        let json = """
            {
              "jsonrpc": "2.0",
              "id": "call-1",
              "method": "tools/call",
              "params": {
                "name": "chrome.refocus_tab",
                "arguments": {
                  "tabId": 1234,
                  "windowId": 88
                }
              }
            }
            """

        let request = try JSONDecoder().decode(
            ChromeBridgeToolCall.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(request.id, .string("call-1"))
        XCTAssertEqual(request.tool, .refocusTab)
        XCTAssertEqual(request.arguments["tabId"]?.intValue, 1234)
        XCTAssertEqual(request.arguments["windowId"]?.intValue, 88)
    }

    func testEncodesToolSuccessResponse() throws {
        let response = ChromeBridgeResponse.success(
            id: .string("call-1"),
            result: [
                "ok": .bool(true),
                "tabId": .number(1234),
            ]
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ChromeBridgeResponse.self, from: data)

        XCTAssertEqual(decoded.id, .string("call-1"))
        XCTAssertEqual(decoded.result?["ok"]?.boolValue, true)
        XCTAssertEqual(decoded.result?["tabId"]?.intValue, 1234)
        XCTAssertNil(decoded.error)
    }

    func testDecodesExtensionTabStateEvent() throws {
        let json = """
            {
              "type": "tab_state",
              "tab": {
                "tabId": 1234,
                "windowId": 88,
                "index": 2,
                "url": "https://claude.ai/chat",
                "title": "Claude",
                "documentId": "doc-1",
                "status": "needsAttention"
              },
              "domSummary": {
                "title": "Claude",
                "text": "Done running task",
                "taskState": "done"
              }
            }
            """

        let event = try JSONDecoder().decode(
            ChromeBridgeExtensionEvent.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(event.type, .tabState)
        XCTAssertEqual(event.tab?.tabID, 1234)
        XCTAssertEqual(event.tab?.documentID, "doc-1")
        XCTAssertEqual(event.domSummary?.taskState, .done)
    }
}
