import XCTest
@testable import SuperIslandCore

final class SupportedAppsTests: XCTestCase {
    func testSupportedBundleIDsArePresent() {
        let supported = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.brave.Browser",
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            EditorApp.cursor,
            EditorApp.vsCode,
            ClaudeDeepLink.bundleID,
            CodexDeepLink.bundleID,
        ]
        for id in supported {
            XCTAssertTrue(
                SupportedApps.isSupported(bundleID: id),
                "expected \(id) to be supported"
            )
        }
    }

    func testUnsupportedAppsAreRejected() {
        let unsupported = [
            "com.apple.finder",
            "com.apple.Safari",
            "com.tinyspeck.slackmacgap",
            "com.microsoft.VSCodeInsiders",  // Insiders intentionally excluded
            "com.vscodium",  // VSCodium intentionally excluded
            "com.example.SomeApp",
            "",
        ]
        for id in unsupported {
            XCTAssertFalse(
                SupportedApps.isSupported(bundleID: id),
                "expected \(id) to be unsupported"
            )
        }
    }

    func testDisplayNamesForKnownApps() {
        XCTAssertEqual(SupportedApps.displayName(bundleID: "com.google.Chrome"), "Google Chrome")
        XCTAssertEqual(SupportedApps.displayName(bundleID: "com.apple.Terminal"), "Terminal")
        XCTAssertEqual(SupportedApps.displayName(bundleID: "com.googlecode.iterm2"), "iTerm")
        XCTAssertEqual(SupportedApps.displayName(bundleID: EditorApp.cursor), "Cursor")
        XCTAssertEqual(SupportedApps.displayName(bundleID: EditorApp.vsCode), "VS Code")
        XCTAssertEqual(
            SupportedApps.displayName(bundleID: ClaudeDeepLink.bundleID), "Claude Desktop")
        XCTAssertEqual(SupportedApps.displayName(bundleID: CodexDeepLink.bundleID), "Codex")
    }

    func testRequiredIntegrationMapping() {
        XCTAssertEqual(RequiredIntegration.required(forBundleID: "com.google.Chrome"), .chrome)
        XCTAssertEqual(RequiredIntegration.required(forBundleID: "com.brave.Browser"), .chrome)
        XCTAssertEqual(RequiredIntegration.required(forBundleID: "com.apple.Terminal"), .shell)
        XCTAssertEqual(RequiredIntegration.required(forBundleID: "com.googlecode.iterm2"), .shell)
        XCTAssertEqual(RequiredIntegration.required(forBundleID: EditorApp.cursor), .shell)
        XCTAssertEqual(RequiredIntegration.required(forBundleID: EditorApp.vsCode), .shell)
        XCTAssertEqual(RequiredIntegration.required(forBundleID: ClaudeDeepLink.bundleID), .claude)
        XCTAssertEqual(RequiredIntegration.required(forBundleID: CodexDeepLink.bundleID), .codex)
        XCTAssertNil(RequiredIntegration.required(forBundleID: "com.apple.finder"))
        XCTAssertNil(RequiredIntegration.required(forBundleID: ""))
    }

    /// Guards against drift: every supported app must declare which integration
    /// it needs, or the drop gate would silently let it through unchecked.
    func testEverySupportedAppHasARequiredIntegration() {
        for id in SupportedApps.bundleIDs {
            XCTAssertNotNil(
                RequiredIntegration.required(forBundleID: id),
                "no required integration mapped for supported app \(id)"
            )
        }
    }

    func testDisplayNameFallsBackToAppNameThenBundleID() {
        XCTAssertEqual(
            SupportedApps.displayName(bundleID: "com.apple.finder", appName: "Finder"),
            "Finder"
        )
        XCTAssertEqual(
            SupportedApps.displayName(bundleID: "com.unknown.app", appName: ""),
            "com.unknown.app"
        )
        XCTAssertEqual(
            SupportedApps.displayName(bundleID: "com.unknown.app"),
            "com.unknown.app"
        )
    }
}
