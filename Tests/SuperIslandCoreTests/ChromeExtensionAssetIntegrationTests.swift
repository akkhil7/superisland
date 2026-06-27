import XCTest

final class ChromeExtensionAssetIntegrationTests: XCTestCase {
    func testManifestDeclaresNativeMessagingAndContentBridge() throws {
        let manifest = try readJSON("Extensions/Chrome/manifest.json")

        XCTAssertEqual(manifest["manifest_version"] as? Int, 3)
        let permissions = manifest["permissions"] as? [String] ?? []
        XCTAssertTrue(permissions.contains("nativeMessaging"))
        XCTAssertTrue(permissions.contains("tabs"))
        XCTAssertTrue(permissions.contains("scripting"))
        // The network detector observes generation requests via webRequest.
        XCTAssertTrue(permissions.contains("webRequest"))
        // activeTab silently re-opens host access on user gesture — must stay out
        // so the allowlist below is the only host grant.
        XCTAssertFalse(permissions.contains("activeTab"))

        let background = manifest["background"] as? [String: Any]
        XCTAssertEqual(background?["service_worker"] as? String, "background.js")

        let contentScripts = manifest["content_scripts"] as? [[String: Any]] ?? []
        let scripts = contentScripts.first?["js"] as? [String] ?? []
        XCTAssertTrue(scripts.contains("content.js"))

        // Allowlist must be explicit: no <all_urls> in host_permissions or matches.
        let hostPermissions = manifest["host_permissions"] as? [String] ?? []
        XCTAssertFalse(hostPermissions.isEmpty)
        XCTAssertFalse(hostPermissions.contains("<all_urls>"))
        XCTAssertTrue(hostPermissions.allSatisfy { $0.hasPrefix("https://") })
        XCTAssertTrue(hostPermissions.contains("https://claude.ai/*"))

        let matches = contentScripts.first?["matches"] as? [String] ?? []
        XCTAssertFalse(matches.isEmpty)
        XCTAssertFalse(matches.contains("<all_urls>"))
        XCTAssertTrue(matches.allSatisfy { $0.hasPrefix("https://") })
        // Page-document hosts only — generation API hosts live in host_permissions.
        XCTAssertTrue(matches.contains("https://chatgpt.com/*"))
        XCTAssertFalse(matches.contains("https://api.lovable.dev/*"))
    }

    func testNativeHostTemplateMatchesBridgeName() throws {
        let manifest = try readJSON("Extensions/Chrome/native-host-manifest.template.json")

        XCTAssertEqual(manifest["name"] as? String, "com.superisland.chrome_bridge")
        XCTAssertEqual(manifest["type"] as? String, "stdio")
        XCTAssertTrue((manifest["path"] as? String ?? "").contains("SuperIslandChromeNativeHost"))
        let origins = manifest["allowed_origins"] as? [String] ?? []
        XCTAssertEqual(origins, ["chrome-extension://REPLACE_WITH_EXTENSION_ID/"])
    }

    private func readJSON(_ relativePath: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
