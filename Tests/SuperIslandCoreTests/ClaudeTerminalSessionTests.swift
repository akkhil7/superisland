import XCTest
@testable import SuperIslandCore

final class ClaudeTerminalSessionTests: XCTestCase {
    // MARK: - claudePID(psOutput:)

    func testFindsClaudeProcessOnTTY() {
        // `ps -t ttys002 -o pid=,ppid=,command=` — the login shell, zsh, a
        // gitstatus helper, and the claude CLI sharing one terminal.
        let ps = """
              72006  1147 login -fp akhil
              72007 72006 -zsh
              72135 72042 /Users/akhil/.cache/gitstatus/gitstatusd-darwin-arm64 -s
              72315 72007 claude
            """
        XCTAssertEqual(ClaudeTerminalSession.claudePID(psOutput: ps), 72315)
    }

    func testNilWhenNoClaudeOnTTY() {
        let ps = """
              72006  1147 login -fp akhil
              72007 72006 -zsh
            """
        XCTAssertNil(ClaudeTerminalSession.claudePID(psOutput: ps))
    }

    func testMatchesFullPathClaudeInvocation() {
        let ps = "  500   42 /opt/homebrew/bin/claude --resume abc123"
        XCTAssertEqual(ClaudeTerminalSession.claudePID(psOutput: ps), 500)
    }

    func testPicksOutermostWhenClaudeNested() {
        // A claude spawned by another claude on the same tty: the session that
        // owns the terminal is the outer one (parent is the shell, not claude).
        let ps = """
              200 100 -zsh
              300 200 claude
              400 300 claude
            """
        XCTAssertEqual(ClaudeTerminalSession.claudePID(psOutput: ps), 300)
    }

    func testIgnoresLookalikeCommands() {
        let ps = "  900   1 claudette --serve"
        XCTAssertNil(ClaudeTerminalSession.claudePID(psOutput: ps))
    }

    // MARK: - adoptsColdStartSeed(_:)

    func testColdStartSeedAdoptsRestingStatesOnly() {
        // A drop made before any hook fired can't be certain which session owns
        // the terminal. Resting states are safe to seed; an active session
        // re-announces "working" via its own tool hooks within seconds.
        XCTAssertTrue(ClaudeTerminalSession.adoptsColdStartSeed(.done))
        XCTAssertTrue(ClaudeTerminalSession.adoptsColdStartSeed(.needsAttention))
        // `.working` is sticky: if the guess is wrong (or the session already
        // finished), no Stop hook follows to clear it — never seed it cold.
        XCTAssertFalse(ClaudeTerminalSession.adoptsColdStartSeed(.working))
        XCTAssertFalse(ClaudeTerminalSession.adoptsColdStartSeed(.unknown))
        XCTAssertFalse(ClaudeTerminalSession.adoptsColdStartSeed(.stale))
    }

    // MARK: - newestTranscript(among:)

    func testNewestTranscriptPicksMostRecentlyModified() {
        let old = URL(fileURLWithPath: "/p/a.jsonl")
        let new = URL(fileURLWithPath: "/p/b.jsonl")
        let result = ClaudeTerminalSession.newestTranscript(among: [
            (url: old, modified: Date(timeIntervalSince1970: 1_000)),
            (url: new, modified: Date(timeIntervalSince1970: 2_000)),
        ])
        XCTAssertEqual(result, new)
    }

    func testNewestTranscriptNilWhenEmpty() {
        XCTAssertNil(ClaudeTerminalSession.newestTranscript(among: []))
    }
}
