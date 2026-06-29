import XCTest

@testable import SuperIslandCore

final class TargetMappabilityTests: XCTestCase {
    // Helper: a Chrome locator carrying a given tab URL.
    private func chrome(url: String?) -> Locator {
        .chrome(
            windowID: 1, windowIndex: 1, tabIndex: 1, tabID: 42,
            url: url, title: "Title", documentID: nil, taskAnchor: nil
        )
    }

    // MARK: Chrome — http/https only

    func testChromeAllowsHTTPAndHTTPS() {
        XCTAssertTrue(TargetMappability.canMap(locator: chrome(url: "https://claude.ai/x"), contentURL: nil))
        XCTAssertTrue(TargetMappability.canMap(locator: chrome(url: "http://example.com"), contentURL: nil))
    }

    func testChromeBlocksInternalAndEmptyPages() {
        let blocked: [String?] = [
            "chrome://settings",
            "chrome://newtab/",
            "about:blank",
            "data:text/html,<h1>hi</h1>",
            "view-source:https://example.com",
            "chrome-extension://abc/page.html",
            "",
            nil,
        ]
        for url in blocked {
            XCTAssertFalse(
                TargetMappability.canMap(locator: chrome(url: url), contentURL: nil),
                "expected chrome url \(url ?? "nil") to be blocked"
            )
        }
    }

    // MARK: Generic (Claude Desktop / Codex / Cursor / Electron) — needs contentURL

    func testGenericMappableOnlyWithContentURL() {
        let locator = Locator.generic(axWindowTitle: "Claude", axWindowIndex: nil)
        XCTAssertTrue(
            TargetMappability.canMap(
                locator: locator, contentURL: "https://claude.ai/epitaxy/local_abc123"))
        XCTAssertFalse(TargetMappability.canMap(locator: locator, contentURL: nil))
    }

    // MARK: Terminal family — needs a captured TTY

    func testShellAlwaysMappable() {
        XCTAssertTrue(
            TargetMappability.canMap(locator: .shell(tty: "/dev/ttys001"), contentURL: nil))
    }

    func testTerminalMappableOnlyWithTTY() {
        XCTAssertTrue(
            TargetMappability.canMap(
                locator: .terminal(windowIndex: 1, tabIndex: nil, tty: "/dev/ttys002"),
                contentURL: nil))
        XCTAssertFalse(
            TargetMappability.canMap(
                locator: .terminal(windowIndex: 1, tabIndex: nil, tty: nil), contentURL: nil))
    }

    func testITermNeverMappable() {
        XCTAssertFalse(
            TargetMappability.canMap(locator: .iterm(sessionID: "uuid-1"), contentURL: nil))
        XCTAssertFalse(TargetMappability.canMap(locator: .iterm(sessionID: nil), contentURL: nil))
    }

    // MARK: Editor — needs some file/workspace identity

    func testEditorMappableWithAnyIdentity() {
        XCTAssertTrue(
            TargetMappability.canMap(
                locator: .editor(filePath: "/a/b.swift", fileName: nil, workspaceName: nil),
                contentURL: nil))
        XCTAssertTrue(
            TargetMappability.canMap(
                locator: .editor(filePath: nil, fileName: "b.swift", workspaceName: nil),
                contentURL: nil))
        XCTAssertTrue(
            TargetMappability.canMap(
                locator: .editor(filePath: nil, fileName: nil, workspaceName: "useklip"),
                contentURL: nil))
    }

    func testEditorBlockedWithNoIdentity() {
        XCTAssertFalse(
            TargetMappability.canMap(
                locator: .editor(filePath: nil, fileName: nil, workspaceName: nil),
                contentURL: nil))
    }
}
