import XCTest
@testable import SuperIslandCore

final class ClaudePermissionModeTests: XCTestCase {
    func testModesThatAutoRunNeverPrompt() {
        // Tools auto-run → no approval prompt can ever appear, so a "stalled"
        // tool in these modes is just a long-running tool, not a permission
        // request. Must NOT arm the needs-attention stall.
        XCTAssertFalse(ClaudePermissionMode.canPrompt("bypassPermissions"))
        XCTAssertFalse(ClaudePermissionMode.canPrompt("auto"))
    }

    func testModesThatCanPrompt() {
        // default & plan prompt for everything; acceptEdits auto-accepts file
        // edits but STILL prompts for Bash and other tools.
        XCTAssertTrue(ClaudePermissionMode.canPrompt("default"))
        XCTAssertTrue(ClaudePermissionMode.canPrompt("plan"))
        XCTAssertTrue(ClaudePermissionMode.canPrompt("acceptEdits"))
    }

    func testUnknownOrMissingModeAssumedToPrompt() {
        // Unknown / older Claude Code → assume it can prompt, so we don't miss a
        // genuine in-app permission request.
        XCTAssertTrue(ClaudePermissionMode.canPrompt(nil))
        XCTAssertTrue(ClaudePermissionMode.canPrompt("somethingNew"))
    }
}
