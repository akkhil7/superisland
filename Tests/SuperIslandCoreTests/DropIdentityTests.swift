import XCTest

@testable import SuperIslandCore

final class DropIdentityTests: XCTestCase {
    private func target(
        _ locator: Locator, windowID: UInt32 = 1, anchor: String? = nil, url: String? = nil
    ) -> WindowTarget {
        WindowTarget(
            bundleID: "x", appName: "X", pid: 1, windowID: windowID, windowTitle: "t",
            locator: locator, contextAnchor: anchor, contentURL: url)
    }

    // contentURL (Claude/Codex sessions, Electron routes)
    func testSameContentURLIsDuplicate() {
        let a = target(.generic(axWindowTitle: nil, axWindowIndex: nil), url: "x://s/1")
        let b = target(
            .generic(axWindowTitle: nil, axWindowIndex: nil), windowID: 9, url: "x://s/1")
        XCTAssertTrue(DropIdentity.sameTarget(a, b))
    }

    func testDifferentContentURLIsDistinct() {
        let a = target(.generic(axWindowTitle: nil, axWindowIndex: nil), url: "x://s/1")
        let b = target(.generic(axWindowTitle: nil, axWindowIndex: nil), url: "x://s/2")
        XCTAssertFalse(DropIdentity.sameTarget(a, b))
    }

    // Chrome — tabID (extension-spaced) then URL
    func testChromeSameExtensionTabIDIsDuplicate() {
        let a = target(
            .chrome(
                windowID: 5, windowIndex: 0, tabIndex: 0, tabID: 7, url: "u/a", title: nil,
                documentID: nil, taskAnchor: nil))
        let b = target(
            .chrome(
                windowID: 5, windowIndex: 1, tabIndex: 2, tabID: 7, url: "u/b", title: nil,
                documentID: nil, taskAnchor: nil))
        XCTAssertTrue(DropIdentity.sameTarget(a, b))
    }

    func testChromeUrlFallbackWhenNoExtensionID() {
        let a = target(
            .chrome(
                windowID: nil, windowIndex: 0, tabIndex: 0, tabID: 100, url: "https://g/x",
                title: nil, documentID: nil, taskAnchor: nil))
        let b = target(
            .chrome(
                windowID: nil, windowIndex: 0, tabIndex: 0, tabID: 200, url: "https://g/x",
                title: nil, documentID: nil, taskAnchor: nil))
        XCTAssertTrue(DropIdentity.sameTarget(a, b))
    }

    func testChromeDifferentTabIsDistinct() {
        let a = target(
            .chrome(
                windowID: 5, windowIndex: 0, tabIndex: 0, tabID: 7, url: "u/a", title: nil,
                documentID: nil, taskAnchor: nil))
        let b = target(
            .chrome(
                windowID: 5, windowIndex: 0, tabIndex: 0, tabID: 8, url: "u/b", title: nil,
                documentID: nil, taskAnchor: nil))
        XCTAssertFalse(DropIdentity.sameTarget(a, b))
    }

    // Terminal / iTerm / shell — by tty / session id
    func testShellSameTTYIsDuplicate() {
        XCTAssertTrue(
            DropIdentity.sameTarget(
                target(.shell(tty: "/dev/ttys003")), target(.shell(tty: "/dev/ttys003"))))
    }

    func testTerminalSameTTYIsDuplicate() {
        let a = target(.terminal(windowIndex: 1, tabIndex: 0, tty: "/dev/ttys001"))
        let b = target(.terminal(windowIndex: 2, tabIndex: 3, tty: "/dev/ttys001"))
        XCTAssertTrue(DropIdentity.sameTarget(a, b))
    }

    func testTerminalDifferentTTYIsDistinct() {
        let a = target(.terminal(windowIndex: 1, tabIndex: 0, tty: "/dev/ttys001"))
        let b = target(.terminal(windowIndex: 1, tabIndex: 0, tty: "/dev/ttys002"))
        XCTAssertFalse(DropIdentity.sameTarget(a, b))
    }

    func testItermSameSessionIsDuplicate() {
        XCTAssertTrue(
            DropIdentity.sameTarget(
                target(.iterm(sessionID: "ABC")), target(.iterm(sessionID: "ABC"))))
        XCTAssertFalse(
            DropIdentity.sameTarget(
                target(.iterm(sessionID: "ABC")), target(.iterm(sessionID: "DEF"))))
    }

    // Editor — by absolute path
    func testEditorSamePathIsDuplicate() {
        let a = target(.editor(filePath: "/p/f.swift", fileName: "f.swift", workspaceName: "w"))
        let b = target(.editor(filePath: "/p/f.swift", fileName: "f.swift", workspaceName: "w2"))
        XCTAssertTrue(DropIdentity.sameTarget(a, b))
    }

    // Generic — same CG window + anchor; distinct anchors stay separate
    func testGenericSameWindowIsDuplicate() {
        let a = target(.generic(axWindowTitle: "t", axWindowIndex: 0), windowID: 42)
        let b = target(.generic(axWindowTitle: "t", axWindowIndex: 0), windowID: 42)
        XCTAssertTrue(DropIdentity.sameTarget(a, b))
    }

    func testGenericDistinctTabsByAnchorStayDistinct() {
        let a = target(
            .generic(axWindowTitle: "t", axWindowIndex: 0), windowID: 42, anchor: "Conversation A")
        let b = target(
            .generic(axWindowTitle: "t", axWindowIndex: 0), windowID: 42, anchor: "Conversation B")
        XCTAssertFalse(DropIdentity.sameTarget(a, b))
    }

    func testDifferentLocatorKindsAreDistinct() {
        XCTAssertFalse(
            DropIdentity.sameTarget(
                target(.shell(tty: "/dev/ttys001")), target(.iterm(sessionID: "x"))))
    }
}
