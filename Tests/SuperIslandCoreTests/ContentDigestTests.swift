import XCTest
@testable import SuperIslandCore

final class ContentDigestTests: XCTestCase {
    func testRelativeTimestampsDoNotCountAsChange() {
        // The same finished conversation whose only delta is a relative
        // timestamp ticking must hash identically — otherwise a *settled* drop
        // would re-classify (and flip-flop) every few seconds.
        let a = "Claude finished — ready for you\nEdited 2 minutes ago"
        let b = "Claude finished — ready for you\nEdited 3 minutes ago"
        XCTAssertEqual(ContentDigest.hash(a), ContentDigest.hash(b))
    }

    func testJustNowAndSecondsAgoNormalized() {
        XCTAssertEqual(
            ContentDigest.hash("Saved just now"),
            ContentDigest.hash("Saved 45 seconds ago")
        )
    }

    func testWallClockTimesNormalized() {
        XCTAssertEqual(
            ContentDigest.hash("Message sent 10:42 PM"),
            ContentDigest.hash("Message sent 11:07 PM")
        )
    }

    func testWhitespaceCollapsed() {
        XCTAssertEqual(
            ContentDigest.hash("hello   world\n\n  foo"),
            ContentDigest.hash("hello world foo")
        )
    }

    func testRealContentChangeStillDiffers() {
        // A genuine new message (the user resumed) must change the hash.
        let before = "Claude finished — ready for you"
        let after = "Claude finished — ready for you\nUser: now refactor the parser"
        XCTAssertNotEqual(ContentDigest.hash(before), ContentDigest.hash(after))
    }

    func testDistinctConversationsDiffer() {
        XCTAssertNotEqual(
            ContentDigest.hash("Reviewing the auth flow"),
            ContentDigest.hash("Deploying the website")
        )
    }
}
