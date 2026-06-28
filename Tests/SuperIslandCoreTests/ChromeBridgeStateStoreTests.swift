import XCTest
@testable import SuperIslandCore

final class ChromeBridgeStateStoreTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testTabStateEventUpdatesConnectionAndToolResults() throws {
        let store = ChromeBridgeStateStore()
        let event = ChromeBridgeExtensionEvent(
            type: .tabState,
            tab: ChromeTabState(
                tabID: 1234,
                windowID: 88,
                index: 2,
                url: "https://claude.ai/chat",
                title: "Claude",
                documentID: "doc-1",
                status: .working,
                statusSource: nil
            ),
            domSummary: ChromeDOMSummary(
                title: "Claude",
                text: "running task",
                taskState: .working
            )
        )

        store.update(event: event, now: date(10))

        XCTAssertTrue(store.isConnected(now: date(15)))
        XCTAssertFalse(store.isConnected(now: date(25)))
        XCTAssertEqual(store.bestActiveTab(matchingTitle: "Claude")?.tabID, 1234)

        let call = try JSONDecoder().decode(
            ChromeBridgeToolCall.self,
            from: Data(
                """
                {"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"chrome.get_tab_status","arguments":{"tabId":1234}}}
                """.utf8)
        )
        let response = store.handleToolCall(call)

        XCTAssertEqual(response.result?["taskState"], .string("working"))
        XCTAssertNil(response.error)
    }

    func testRefocusToolQueuesCommandForExtensionPoll() throws {
        let store = ChromeBridgeStateStore()
        let call = try JSONDecoder().decode(
            ChromeBridgeToolCall.self,
            from: Data(
                """
                {"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"chrome.refocus_tab","arguments":{"tabId":1234,"windowId":88}}}
                """.utf8)
        )

        let response = store.handleToolCall(call)
        let commands = store.consumeCommands()

        XCTAssertEqual(response.result?["queued"], .bool(true))
        XCTAssertEqual(
            commands,
            [
                ChromeBridgeCommand(type: "refocus_tab", tabID: 1234, windowID: 88)
            ])
        XCTAssertTrue(store.consumeCommands().isEmpty)
    }
}
