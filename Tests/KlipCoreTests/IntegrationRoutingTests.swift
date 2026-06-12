import XCTest
@testable import KlipCore

final class IntegrationRoutingTests: XCTestCase {
    func testStrongIntegrationsBypassVisualRestore() {
        XCTAssertFalse(
            IntegrationRouter.allowsVisualRestore(
                locator: .shell(tty: "/dev/ttys001"),
                bundleID: "com.apple.Terminal"
            )
        )
        XCTAssertFalse(
            IntegrationRouter.allowsVisualRestore(
                locator: .chrome(
                    windowID: 88,
                    windowIndex: 1,
                    tabIndex: 2,
                    tabID: 1234,
                    url: "https://claude.ai/chat",
                    title: "Claude",
                    documentID: "doc-1",
                    taskAnchor: ChromeTaskAnchor(kind: .aiResponse, label: "Claude response")
                ),
                bundleID: "com.google.Chrome"
            )
        )
        XCTAssertFalse(
            IntegrationRouter.allowsVisualRestore(
                locator: .iterm(sessionID: "session-1"),
                bundleID: "com.googlecode.iterm2"
            )
        )
        XCTAssertFalse(
            IntegrationRouter.allowsVisualRestore(
                locator: .terminal(windowIndex: 1, tabIndex: 1, tty: "/dev/ttys002"),
                bundleID: "com.apple.Terminal"
            )
        )
    }

    func testGenericWindowsMayUseVisualRestore() {
        XCTAssertTrue(
            IntegrationRouter.allowsVisualRestore(
                locator: .generic(axWindowTitle: "Project", axWindowIndex: nil),
                bundleID: "com.example.SomeApp"
            )
        )
    }
}
