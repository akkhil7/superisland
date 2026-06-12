import XCTest
@testable import KlipCore

final class ShellHookScriptBuilderTests: XCTestCase {
    func testZshScriptUsesPreexecPrecmdAndLocalServer() {
        let script = ShellHookScriptBuilder.zshScript(port: 2929)

        XCTAssertTrue(script.contains("add-zsh-hook preexec __klip_preexec"))
        XCTAssertTrue(script.contains("add-zsh-hook precmd  __klip_precmd"))
        XCTAssertTrue(script.contains("http://localhost:$__klip_port/shell"))
        XCTAssertTrue(script.contains("\"event\":\"start\""))
        XCTAssertTrue(script.contains("\"event\":\"done\""))
    }

    func testBashScriptUsesDebugTrapAndPromptCommand() {
        let script = ShellHookScriptBuilder.bashScript(port: 2929)

        XCTAssertTrue(script.contains("trap '__klip_preexec' DEBUG"))
        XCTAssertTrue(script.contains("PROMPT_COMMAND=\"__klip_precmd"))
        XCTAssertTrue(script.contains("http://localhost:$__klip_port/shell"))
        XCTAssertTrue(script.contains("\"event\":\"register\""))
    }

    func testSourceBlockIsStableAndShellSpecific() {
        let block = ShellHookScriptBuilder.sourceBlock(
            scriptPath: "/Users/me/.config/klip/klip.bash"
        )

        XCTAssertTrue(block.contains("# Klip shell integration"))
        XCTAssertTrue(block.contains("source \"/Users/me/.config/klip/klip.bash\""))
    }
}
