import XCTest
@testable import SuperIslandCore

final class AgentTerminalSupportTests: XCTestCase {
    // MARK: - AgentCommand

    func testAgentNameDetection() {
        XCTAssertEqual(AgentCommand.agentName(forCommand: "claude"), "Claude Code")
        XCTAssertEqual(AgentCommand.agentName(forCommand: "claude --resume abc"), "Claude Code")
        XCTAssertEqual(
            AgentCommand.agentName(forCommand: "/usr/local/bin/claude -p hi"), "Claude Code"
        )
        XCTAssertEqual(AgentCommand.agentName(forCommand: "codex"), "Codex")
        XCTAssertEqual(AgentCommand.agentName(forCommand: "CODEX exec"), "Codex")
        XCTAssertNil(AgentCommand.agentName(forCommand: "npm run build"))
        XCTAssertNil(AgentCommand.agentName(forCommand: "claudette"), "prefix must not match")
        XCTAssertNil(AgentCommand.agentName(forCommand: ""))
    }

    // MARK: - CommandLabel

    func testCommandLabelUsesAgentName() {
        XCTAssertEqual(CommandLabel.label(forCommand: "claude --continue"), "Claude Code")
    }

    func testCommandLabelKeepsShortCommands() {
        XCTAssertEqual(CommandLabel.label(forCommand: "npm run build"), "npm run build")
    }

    func testCommandLabelTruncatesAndFlattens() {
        let long = "cargo build --release --target aarch64-apple-darwin --verbose"
        let label = CommandLabel.label(forCommand: long, maxLength: 20)
        XCTAssertEqual(label.count, 20)
        XCTAssertTrue(label.hasSuffix("…"))

        XCTAssertEqual(CommandLabel.label(forCommand: "make\nall"), "make all")
    }

    // MARK: - AgentSessionLabel

    func testAgentSessionLabelFromPrompt() {
        XCTAssertEqual(
            AgentSessionLabel.label(agent: "Claude Code", prompt: "fix the login bug"),
            "Claude Code: fix the login bug"
        )
        XCTAssertEqual(
            AgentSessionLabel.label(agent: "Codex", prompt: "  line one\nline two  "),
            "Codex: line one line two"
        )
    }

    func testAgentSessionLabelTruncates() {
        let label = AgentSessionLabel.label(
            agent: "Claude Code",
            prompt: String(repeating: "x", count: 200),
            maxLength: 40
        )
        XCTAssertEqual(label?.count, 40)
        XCTAssertTrue(label?.hasSuffix("…") == true)
    }

    func testAgentSessionLabelNilForMissingPrompt() {
        XCTAssertNil(AgentSessionLabel.label(agent: "Claude Code", prompt: nil))
        XCTAssertNil(AgentSessionLabel.label(agent: "Claude Code", prompt: "  \n "))
    }

    // MARK: - HookRequestQuery

    func testQueryValueExtraction() {
        XCTAssertEqual(HookRequestQuery.value(of: "tty", inPath: "/claude?tty=ttys003"), "ttys003")
        XCTAssertEqual(
            HookRequestQuery.value(of: "tty", inPath: "/codex?a=1&tty=ttys007&b=2"), "ttys007"
        )
        XCTAssertEqual(
            HookRequestQuery.value(of: "tty", inPath: "/claude?tty=%2Fdev%2Fttys003"),
            "/dev/ttys003"
        )
        XCTAssertNil(HookRequestQuery.value(of: "tty", inPath: "/claude"))
        XCTAssertNil(HookRequestQuery.value(of: "tty", inPath: "/claude?other=x"))
        XCTAssertNil(HookRequestQuery.value(of: "tty", inPath: "/claude?tty"))
    }

    func testNormalizeTTY() {
        XCTAssertEqual(HookRequestQuery.normalizeTTY("ttys003"), "/dev/ttys003")
        XCTAssertEqual(HookRequestQuery.normalizeTTY("/dev/ttys003"), "/dev/ttys003")
        XCTAssertEqual(HookRequestQuery.normalizeTTY(" ttys003 "), "/dev/ttys003")
        XCTAssertNil(HookRequestQuery.normalizeTTY("??"), "no controlling TTY")
        XCTAssertNil(HookRequestQuery.normalizeTTY(""))
        XCTAssertNil(HookRequestQuery.normalizeTTY(nil))
    }

    // MARK: - ProcessTreeTTY

    private let psOutput = """
        1     0 ??
      300     1 ttys001
      500     1 ??
      510   500 ??
      520   510 ttys004
      530   510 ttys005
      999   998 ttys009
    """

    func testParsePSOutput() {
        let entries = ProcessTreeTTY.parse(psOutput: psOutput)
        XCTAssertEqual(entries.count, 7)
        XCTAssertEqual(entries[0], .init(pid: 1, ppid: 0, tty: nil))
        XCTAssertEqual(entries[4], .init(pid: 520, ppid: 510, tty: "ttys004"))
    }

    func testTTYsUnderAncestor() {
        let entries = ProcessTreeTTY.parse(psOutput: psOutput)
        let ttys = ProcessTreeTTY.ttys(underAncestor: 500, entries: entries)
        XCTAssertEqual(Set(ttys), ["/dev/ttys004", "/dev/ttys005"])
        XCTAssertFalse(ttys.contains("/dev/ttys001"), "sibling tree must not match")
        // Orphan chains (parent missing from the table) terminate cleanly.
        XCTAssertEqual(ProcessTreeTTY.ttys(underAncestor: 12345, entries: entries), [])
    }

    // MARK: - EditorWindowTitle

    func testParseFullVSCodeTitle() {
        let parsed = EditorWindowTitle.parse("● main.swift — drop — Visual Studio Code")
        XCTAssertEqual(parsed.fileName, "main.swift")
        XCTAssertEqual(parsed.workspaceName, "drop")
        XCTAssertTrue(parsed.isDirty)
    }

    func testParseTitleWithoutAppName() {
        let parsed = EditorWindowTitle.parse("main.swift — drop")
        XCTAssertEqual(parsed.fileName, "main.swift")
        XCTAssertEqual(parsed.workspaceName, "drop")
        XCTAssertFalse(parsed.isDirty)
    }

    func testParseWorkspaceOnlyTitle() {
        let parsed = EditorWindowTitle.parse("drop — Cursor")
        XCTAssertNil(parsed.fileName)
        XCTAssertEqual(parsed.workspaceName, "drop")
    }

    func testParseHyphenSeparatedTitle() {
        let parsed = EditorWindowTitle.parse("Untitled-1 - myproj - Cursor")
        XCTAssertEqual(parsed.fileName, "Untitled-1")
        XCTAssertEqual(parsed.workspaceName, "myproj")
    }

    func testParseEmptyTitle() {
        let parsed = EditorWindowTitle.parse("")
        XCTAssertNil(parsed.fileName)
        XCTAssertNil(parsed.workspaceName)
    }

    // MARK: - Editor routing

    func testEditorLocatorIsAppSpecific() {
        let locator = Locator.editor(
            filePath: "/Users/x/proj/main.swift", fileName: "main.swift", workspaceName: "proj"
        )
        XCTAssertEqual(
            IntegrationRouter.strength(locator: locator, bundleID: EditorApp.vsCode),
            .appSpecific
        )
        XCTAssertFalse(
            IntegrationRouter.allowsVisualRestore(locator: locator, bundleID: EditorApp.cursor)
        )
    }

    func testGenericLocatorInEditorBundleSkipsVisualRestore() {
        XCTAssertFalse(
            IntegrationRouter.allowsVisualRestore(
                locator: .generic(axWindowTitle: "x", axWindowIndex: nil),
                bundleID: EditorApp.cursor
            )
        )
    }

    func testEditorLocatorCodableRoundTrip() throws {
        let locator = Locator.editor(
            filePath: "/Users/x/proj/main.swift", fileName: "main.swift", workspaceName: "proj"
        )
        let data = try JSONEncoder().encode(locator)
        XCTAssertEqual(try JSONDecoder().decode(Locator.self, from: data), locator)
    }

    // MARK: - ClaudeHookEvent prompt + tty

    func testHookEventDecodesPromptAndDefaultsTTY() throws {
        let json = """
        {"session_id":"abc","hook_event_name":"UserPromptSubmit",\
        "cwd":"/Users/x/proj","prompt":"fix the login bug"}
        """
        var event = try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.prompt, "fix the login bug")
        XCTAssertNil(event.tty, "tty is server-assigned, never decoded")
        event.tty = "/dev/ttys003"
        XCTAssertEqual(event.tty, "/dev/ttys003")
    }
}
