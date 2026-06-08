import XCTest
@testable import KlipCore

final class PrefilterTests: XCTestCase {
    private let pf = Prefilter()

    func testDetectsYesNoPromptAsNeedsAttention() {
        let r = pf.assess(text: "Do you want to continue? [y/N]")
        XCTAssertTrue(r.isInteresting)
        XCTAssertEqual(r.hint, .needsAttention)
    }

    func testTrailingQuestionIsNeedsAttention() {
        let r = pf.assess(text: "Building project...\nWhich environment should I deploy to?")
        XCTAssertEqual(r.hint, .needsAttention)
        XCTAssertTrue(r.signals.contains("attention:trailing-?"))
    }

    func testDoneKeyword() {
        let r = pf.assess(text: "Compiling...\nBuild succeeded\n$")
        XCTAssertEqual(r.hint, .done)
        XCTAssertTrue(r.isInteresting)
    }

    func testErrorIsNeedsAttention() {
        let r = pf.assess(text: "npm ERR! something failed")
        XCTAssertEqual(r.hint, .needsAttention)
    }

    func testPromptBeatsDoneWord() {
        // "completed" appears in scrollback but there's a pending question.
        let r = pf.assess(text: "Task completed earlier.\nOverwrite existing file? (yes/no)")
        XCTAssertEqual(r.hint, .needsAttention)
    }

    func testPlainOutputIsNotInteresting() {
        let r = pf.assess(text: "Downloading package 12 of 40\nresolving dependencies")
        XCTAssertFalse(r.isInteresting)
        XCTAssertEqual(r.hint, .working)
    }
}
