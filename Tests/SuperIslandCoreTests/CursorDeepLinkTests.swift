import XCTest
@testable import SuperIslandCore

final class CursorDeepLinkTests: XCTestCase {
    func testBundleIDIsCursorDesktop() {
        XCTAssertEqual(CursorDeepLink.bundleID, "com.todesktop.230313mzl4w4u92")
    }

    func testSessionURLPrefix() {
        XCTAssertEqual(CursorDeepLink.sessionURLPrefix, "cursor://session/")
    }

    func testDeepLinkReturnsNilForNonSessionURL() {
        XCTAssertNil(CursorDeepLink.deepLink(forContentURL: "https://example.com"))
    }

    func testDeepLinkReturnsNilForEmptyID() {
        XCTAssertNil(CursorDeepLink.deepLink(forContentURL: "cursor://session/"))
    }

    func testDeepLinkBuildsAnchorURLFromSessionURL() {
        XCTAssertEqual(
            CursorDeepLink.deepLink(forContentURL: "cursor://session/abc-123"),
            "cursor://anysphere.cursor-deeplink/composer?id=abc-123"
        )
    }
}
