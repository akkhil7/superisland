import XCTest
@testable import SuperIslandCore

final class DropSourceTests: XCTestCase {
    private func name(
        _ bundleID: String, _ locator: Locator,
        url: String? = nil, label: String = "task"
    ) -> String {
        DropSource.identify(bundleID: bundleID, locator: locator, contentURL: url, label: label)
            .name
    }

    func testClaudeDesktopVsClaudeCodeAreDistinct() {
        // Claude Desktop: the app itself, generic locator.
        XCTAssertEqual(
            name(
                ClaudeDeepLink.bundleID, .generic(axWindowTitle: nil, axWindowIndex: nil),
                url: "https://claude.ai/x/local_abc", label: "Add design system"),
            "Claude Desktop"
        )
        // Claude Code: a terminal whose label the hook stamped with the agent.
        XCTAssertEqual(
            name(
                "com.googlecode.iterm2", .iterm(sessionID: "s"), label: "Claude Code: fix the bug"),
            "Claude Code"
        )
    }

    func testCodexAppAndCli() {
        XCTAssertEqual(
            name(CodexDeepLink.bundleID, .generic(axWindowTitle: nil, axWindowIndex: nil)), "Codex")
        // Codex CLI in a terminal — identified by its bound session URL.
        XCTAssertEqual(
            name(
                "com.apple.Terminal", .shell(tty: "/dev/ttys1"),
                url: CodexDeepLink.sessionURLPrefix + "abc", label: "running…"),
            "Codex"
        )
    }

    func testPlainTerminalUsesAppName() {
        XCTAssertEqual(
            name(
                "com.apple.Terminal", .terminal(windowIndex: 0, tabIndex: nil, tty: nil),
                label: "npm test"),
            "Terminal"
        )
        XCTAssertEqual(
            name("com.googlecode.iterm2", .shell(tty: "/dev/ttys2"), label: "git status"),
            "iTerm"
        )
    }

    func testBrowserAndEditor() {
        XCTAssertEqual(
            name(
                "com.google.Chrome",
                .chrome(
                    windowID: nil, windowIndex: 0, tabIndex: 0, tabID: nil,
                    url: nil, title: nil, documentID: nil, taskAnchor: nil)),
            "Google Chrome"
        )
        XCTAssertEqual(
            name(
                CursorDeepLink.bundleID,
                .editor(filePath: "/a.swift", fileName: "a.swift", workspaceName: "proj")),
            "Cursor"
        )
        XCTAssertEqual(
            name(EditorApp.vsCode, .editor(filePath: nil, fileName: nil, workspaceName: nil)),
            "VS Code"
        )
    }
}
