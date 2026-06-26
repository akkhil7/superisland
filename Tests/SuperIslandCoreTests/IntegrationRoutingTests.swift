import XCTest
@testable import SuperIslandCore

final class IntegrationRoutingTests: XCTestCase {
    func testShellLocatorIsStrong() {
        XCTAssertEqual(
            IntegrationRouter.strength(
                locator: .shell(tty: "/dev/ttys001"),
                bundleID: "com.apple.Terminal"
            ),
            .strong
        )
    }

    func testChromeLocatorIsStrong() {
        XCTAssertEqual(
            IntegrationRouter.strength(
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
            ),
            .strong
        )
    }

    func testItermLocatorIsAppSpecific() {
        XCTAssertEqual(
            IntegrationRouter.strength(
                locator: .iterm(sessionID: "session-1"),
                bundleID: "com.googlecode.iterm2"
            ),
            .appSpecific
        )
    }

    func testTerminalLocatorIsAppSpecific() {
        XCTAssertEqual(
            IntegrationRouter.strength(
                locator: .terminal(windowIndex: 1, tabIndex: 1, tty: "/dev/ttys002"),
                bundleID: "com.apple.Terminal"
            ),
            .appSpecific
        )
    }

    func testGenericWindowForUnknownAppIsGeneric() {
        XCTAssertEqual(
            IntegrationRouter.strength(
                locator: .generic(axWindowTitle: "Project", axWindowIndex: nil),
                bundleID: "com.example.SomeApp"
            ),
            .generic
        )
    }
}
