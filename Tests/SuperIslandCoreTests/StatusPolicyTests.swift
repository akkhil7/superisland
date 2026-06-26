import XCTest
@testable import SuperIslandCore

final class StatusPolicyTests: XCTestCase {
    private func target(appName: String = "Claude", windowTitle: String = "Claude") -> WindowTarget {
        WindowTarget(
            bundleID: "com.anthropic.claudefordesktop",
            appName: appName,
            pid: 1,
            windowID: 1,
            windowTitle: windowTitle,
            locator: .generic(axWindowTitle: nil, axWindowIndex: nil)
        )
    }

    // MARK: - LabelPolicy

    func testBareAppNameIsPlaceholder() {
        XCTAssertTrue(LabelPolicy.isPlaceholder("Claude", target: target()))
    }

    func testEmptyLabelIsPlaceholder() {
        XCTAssertTrue(LabelPolicy.isPlaceholder("", target: target()))
        XCTAssertTrue(LabelPolicy.isPlaceholder("   ", target: target()))
    }

    func testRawWindowTitleIsPlaceholder() {
        let t = target(appName: "Terminal", windowTitle: "akhil — -zsh — 80×24")
        XCTAssertTrue(LabelPolicy.isPlaceholder("akhil — -zsh — 80×24", target: t))
    }

    func testRealNameIsNotPlaceholder() {
        XCTAssertFalse(LabelPolicy.isPlaceholder("Status flickering during Claude work", target: target()))
    }

    // MARK: - MonitorPolicy

    func testWorkingAlwaysClassifies() {
        XCTAssertTrue(MonitorPolicy.shouldClassify(status: .working, contentChanged: false, hasBaseline: true))
        XCTAssertTrue(MonitorPolicy.shouldClassify(status: .working, contentChanged: true, hasBaseline: true))
    }

    func testUnknownAlwaysClassifies() {
        XCTAssertTrue(MonitorPolicy.shouldClassify(status: .unknown, contentChanged: false, hasBaseline: true))
    }

    func testSettledAndUnchangedIsFrozen() {
        XCTAssertFalse(MonitorPolicy.shouldClassify(status: .done, contentChanged: false, hasBaseline: true))
        XCTAssertFalse(MonitorPolicy.shouldClassify(status: .needsAttention, contentChanged: false, hasBaseline: true))
    }

    func testSettledButChangedReclassifies() {
        XCTAssertTrue(MonitorPolicy.shouldClassify(status: .done, contentChanged: true, hasBaseline: true))
        XCTAssertTrue(MonitorPolicy.shouldClassify(status: .needsAttention, contentChanged: true, hasBaseline: true))
    }

    func testSettledWithNoBaselineIsVerifiedOnce() {
        // First sight of a run (e.g. after relaunch): allow one classification
        // even though contentChanged is false, to re-verify a stored verdict.
        XCTAssertTrue(MonitorPolicy.shouldClassify(status: .done, contentChanged: false, hasBaseline: false))
    }
}
