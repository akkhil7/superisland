import XCTest
@testable import SuperIslandCore

final class ShellHookScriptBuilderTests: XCTestCase {
    func testZshScriptUsesPreexecPrecmdAndLocalServer() {
        let script = ShellHookScriptBuilder.zshScript(port: 2929)

        XCTAssertTrue(script.contains("add-zsh-hook preexec __drop_preexec"))
        XCTAssertTrue(script.contains("add-zsh-hook precmd  __drop_precmd"))
        XCTAssertTrue(script.contains("http://localhost:$__drop_port/shell"))
        XCTAssertTrue(script.contains("\"event\":\"start\""))
        XCTAssertTrue(script.contains("\"event\":\"done\""))
    }

    func testBashScriptUsesDebugTrapAndPromptCommand() {
        let script = ShellHookScriptBuilder.bashScript(port: 2929)

        XCTAssertTrue(script.contains("trap '__drop_preexec' DEBUG"))
        XCTAssertTrue(script.contains("PROMPT_COMMAND=\"__drop_precmd"))
        XCTAssertTrue(script.contains("http://localhost:$__drop_port/shell"))
        XCTAssertTrue(script.contains("\"event\":\"register\""))
    }

    func testSourceBlockIsStableAndShellSpecific() {
        let block = ShellHookScriptBuilder.sourceBlock(
            scriptPath: "/Users/me/.config/superisland/superisland.bash"
        )

        XCTAssertTrue(block.contains("# SuperIsland shell integration"))
        XCTAssertTrue(block.contains("source \"/Users/me/.config/superisland/superisland.bash\""))
    }
}
