import XCTest
@testable import SuperIslandCore

final class CursorHookMapperTests: XCTestCase {
    private func ev(_ event: String, status: String? = nil) -> CursorHookEvent {
        CursorHookEvent(conversationID: "c1", event: event, status: status)
    }

    func testBeforeSubmitPromptIsWorking() {
        XCTAssertEqual(
            CursorHookMapper.update(for: ev("beforeSubmitPrompt"))?.status, .working)
    }

    func testStopCompletedIsDoneBaseline() {
        XCTAssertEqual(
            CursorHookMapper.update(for: ev("stop", status: "completed"))?.status, .done)
    }

    func testStopErrorIsNeedsAttention() {
        XCTAssertEqual(
            CursorHookMapper.update(for: ev("stop", status: "error"))?.status, .needsAttention)
    }

    func testStopAbortedIsDone() {
        XCTAssertEqual(
            CursorHookMapper.update(for: ev("stop", status: "aborted"))?.status, .done)
    }

    func testAfterAgentResponseKeepsStatus() {
        // Informational — carries the text to stash, but doesn't move status.
        let update = CursorHookMapper.update(for: ev("afterAgentResponse"))
        XCTAssertNotNil(update)
        XCTAssertNil(update?.status)
    }

    func testSessionEndKeepsStatus() {
        let update = CursorHookMapper.update(for: ev("sessionEnd"))
        XCTAssertNil(update?.status)
    }

    func testUnknownEventIsIgnored() {
        XCTAssertNil(CursorHookMapper.update(for: ev("afterFileEdit")))
    }
}
