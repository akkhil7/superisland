import XCTest

@testable import SuperIslandCore

final class ChromeStatusPolicyTests: XCTestCase {
    private let chrome = Locator.chrome(
        windowID: 1, windowIndex: 0, tabIndex: 0, tabID: 5,
        url: "https://gemini.google.com/", title: "Gemini",
        documentID: nil, taskAnchor: nil)
    private let generic = Locator.generic(axWindowTitle: "x", axWindowIndex: 0)

    // bridgeOwnsLiveStatus: AI monitor skips a chrome drop only while live-working.
    func testChromeWorkingConnectedIsManaged() {
        XCTAssertTrue(
            ChromeStatusPolicy.bridgeOwnsLiveStatus(
                locator: chrome, status: .working, bridgeConnected: true))
    }

    func testChromeDoneConnectedIsNotManaged() {
        XCTAssertFalse(
            ChromeStatusPolicy.bridgeOwnsLiveStatus(
                locator: chrome, status: .done, bridgeConnected: true))
    }

    func testChromeWorkingDisconnectedIsNotManaged() {
        XCTAssertFalse(
            ChromeStatusPolicy.bridgeOwnsLiveStatus(
                locator: chrome, status: .working, bridgeConnected: false))
    }

    func testNonChromeIsNeverManagedHere() {
        XCTAssertFalse(
            ChromeStatusPolicy.bridgeOwnsLiveStatus(
                locator: generic, status: .working, bridgeConnected: true))
    }

    // monitorMayApply: an AI `working` verdict on a chrome drop is ignored.
    func testChromeWorkingVerdictIsIgnored() {
        XCTAssertFalse(ChromeStatusPolicy.monitorMayApply(verdict: .working, locator: chrome))
    }

    func testChromeNeedsAttentionVerdictApplies() {
        XCTAssertTrue(ChromeStatusPolicy.monitorMayApply(verdict: .needsAttention, locator: chrome))
    }

    func testChromeDoneVerdictApplies() {
        XCTAssertTrue(ChromeStatusPolicy.monitorMayApply(verdict: .done, locator: chrome))
    }

    func testGenericWorkingVerdictApplies() {
        XCTAssertTrue(ChromeStatusPolicy.monitorMayApply(verdict: .working, locator: generic))
    }
}
