import XCTest
@testable import SuperIslandCore

final class ChromeCaptureMatchingTests: XCTestCase {
    private func store(withTabs tabs: [ChromeTabState], lastActive: Int? = nil) -> ChromeBridgeStateStore {
        let s = ChromeBridgeStateStore()
        for tab in tabs {
            s.update(event: ChromeBridgeExtensionEvent(type: .tabState, tab: tab, domSummary: nil))
        }
        if let lastActive, let tab = tabs.first(where: { $0.tabID == lastActive }) {
            // Re-report to make it the last active.
            s.update(event: ChromeBridgeExtensionEvent(type: .tabState, tab: tab, domSummary: nil))
        }
        return s
    }

    private func tab(_ id: Int, title: String, url: String) -> ChromeTabState {
        ChromeTabState(tabID: id, windowID: 1, index: id, url: url, title: title, documentID: nil, status: nil)
    }

    func testStaleLastActiveTabIsRejectedWhenTitleDisagrees() {
        let s = store(
            withTabs: [
                tab(1, title: "CI pipeline run", url: "https://ci.example.com"),
                tab(2, title: "Claude conversation", url: "https://claude.ai/chat/x"),
            ],
            lastActive: 1   // extension lags: still claims tab 1 is active
        )
        // The user is actually dropping the Claude tab (window title says so).
        let best = s.bestActiveTab(matchingTitle: "Claude conversation - Google Chrome")
        XCTAssertEqual(best?.tabID, 2)
    }

    func testLastActiveTabAcceptedWhenTitleAgrees() {
        let s = store(
            withTabs: [tab(1, title: "CI pipeline run", url: "https://ci.example.com")],
            lastActive: 1
        )
        XCTAssertEqual(s.bestActiveTab(matchingTitle: "CI pipeline run - Google Chrome")?.tabID, 1)
    }

    func testTabLookupPrefersExactURL() {
        let s = store(withTabs: [
            tab(1, title: "Docs", url: "https://example.com/a"),
            tab(2, title: "Docs", url: "https://example.com/b"),
        ])
        XCTAssertEqual(s.tab(matchingURL: "https://example.com/b", orTitle: "Docs")?.tabID, 2)
    }

    func testTabLookupFallsBackToTitle() {
        let s = store(withTabs: [tab(7, title: "Deploy dashboard", url: "https://x.dev")])
        XCTAssertEqual(
            s.tab(matchingURL: "", orTitle: "Deploy dashboard - Google Chrome")?.tabID, 7
        )
        XCTAssertNil(s.tab(matchingURL: nil, orTitle: "Unrelated"))
    }
}
