import XCTest
@testable import SuperIslandCore

final class CursorDecouplingTests: XCTestCase {
    private let cursor = CursorDeepLink.bundleID

    func testCursorIsNotAnEditor() {
        XCTAssertFalse(EditorApp.isEditor(bundleID: cursor))
        XCTAssertTrue(EditorApp.isEditor(bundleID: EditorApp.vsCode))
    }

    func testCursorIsStillSupported() {
        XCTAssertTrue(SupportedApps.isSupported(bundleID: cursor))
    }

    func testCursorRequiresCursorIntegrationNotShell() {
        XCTAssertEqual(RequiredIntegration.required(forBundleID: cursor), .cursor)
        XCTAssertEqual(
            RequiredIntegration.required(forBundleID: EditorApp.vsCode), .shell)
    }

    func testCursorDisplayName() {
        XCTAssertEqual(SupportedApps.displayName(bundleID: cursor), "Cursor")
    }

    func testCursorDropSourceIsAgentBadge() {
        let source = DropSource.identify(
            bundleID: cursor, locator: .generic(axWindowTitle: nil, axWindowIndex: nil),
            contentURL: "cursor://session/abc", label: "Cursor"
        )
        XCTAssertEqual(source.name, "Cursor")
        XCTAssertNotEqual(source.icon, "curlybraces")  // not the editor badge
    }
}
