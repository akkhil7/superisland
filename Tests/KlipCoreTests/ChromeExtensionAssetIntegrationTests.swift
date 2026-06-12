import XCTest

final class ChromeExtensionAssetIntegrationTests: XCTestCase {
    func testManifestDeclaresNativeMessagingAndContentBridge() throws {
        let manifest = try readJSON("Extensions/Chrome/manifest.json")

        XCTAssertEqual(manifest["manifest_version"] as? Int, 3)
        let permissions = manifest["permissions"] as? [String] ?? []
        XCTAssertTrue(permissions.contains("nativeMessaging"))
        XCTAssertTrue(permissions.contains("tabs"))
        XCTAssertTrue(permissions.contains("scripting"))

        let background = manifest["background"] as? [String: Any]
        XCTAssertEqual(background?["service_worker"] as? String, "background.js")

        let contentScripts = manifest["content_scripts"] as? [[String: Any]] ?? []
        let scripts = contentScripts.first?["js"] as? [String] ?? []
        XCTAssertTrue(scripts.contains("content.js"))
    }

    func testNativeHostTemplateMatchesBridgeName() throws {
        let manifest = try readJSON("Extensions/Chrome/native-host-manifest.template.json")

        XCTAssertEqual(manifest["name"] as? String, "com.useklip.chrome_bridge")
        XCTAssertEqual(manifest["type"] as? String, "stdio")
        XCTAssertTrue((manifest["path"] as? String ?? "").contains("KlipChromeNativeHost"))
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
