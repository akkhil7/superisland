import XCTest

@testable import SuperIslandCore

/// The island's two counter orbs are backed by these buckets: the left orb
/// counts `inProgress`, the right orb counts `needsAttention`. The headline
/// invariant here is that the right orb counts *only* tasks explicitly waiting
/// on the user — completed (`.done`) drops are deliberately excluded.
final class DropGroupingTests: XCTestCase {
    private func drop(_ status: DropStatus, label: String = "Task") -> Drop {
        Drop(
            label: label,
            target: WindowTarget(
                bundleID: "com.apple.Terminal",
                appName: "Terminal",
                pid: 1,
                windowID: 1,
                windowTitle: label,
                locator: .generic(axWindowTitle: label, axWindowIndex: 0)
            ),
            status: status
        )
    }

    /// The right counter orb: only `.needsAttention`, never `.done`.
    func testNeedsAttentionExcludesDone() {
        let drops = [
            drop(.needsAttention),
            drop(.needsAttention),
            drop(.done),
            drop(.done),
            drop(.done),
            drop(.working),
            drop(.unknown),
            drop(.stale),
        ]

        XCTAssertEqual(drops.needsAttention.count, 2)
    }

    /// The left counter orb: active work is `working` + `unknown`; settled and
    /// stale drops are not "in progress".
    func testInProgressCountsWorkingAndUnknownOnly() {
        let drops = [
            drop(.working),
            drop(.working),
            drop(.unknown),
            drop(.needsAttention),
            drop(.done),
            drop(.stale),
        ]

        XCTAssertEqual(drops.inProgress.count, 3)
    }

    /// `done` is its own bucket, kept separate from needs-attention.
    func testDoneCountsCompletedOnly() {
        let drops = [drop(.done), drop(.done), drop(.needsAttention), drop(.working)]

        XCTAssertEqual(drops.done.count, 2)
    }

    /// `needsYou` (used for the expanded list and the right-orb tint, not its
    /// count) is needs-attention plus done.
    func testNeedsYouIsNeedsAttentionPlusDone() {
        let drops = [
            drop(.needsAttention),
            drop(.done),
            drop(.done),
            drop(.working),
            drop(.stale),
        ]

        XCTAssertEqual(drops.needsYou.count, 3)
    }
}
