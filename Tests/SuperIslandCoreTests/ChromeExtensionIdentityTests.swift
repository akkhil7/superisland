import XCTest
@testable import SuperIslandCore

final class ChromeExtensionIdentityTests: XCTestCase {
    func testPinnedIDMatchesPinnedKey() {
        XCTAssertEqual(
            ChromeExtensionIdentity.extensionID(forBase64Key: ChromeExtensionIdentity.manifestKey),
            ChromeExtensionIdentity.extensionID
        )
    }

    func testManifestJSONKeyMatchesPinnedKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Extensions/Chrome/manifest.json")
        let data = try Data(contentsOf: url)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(manifest["key"] as? String, ChromeExtensionIdentity.manifestKey)
    }

    func testIDIsLowercaseAToP() {
        let id = ChromeExtensionIdentity.extensionID
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { ("a"..."p").contains($0) })
    }

    func testInvalidKeyReturnsNil() {
        XCTAssertNil(ChromeExtensionIdentity.extensionID(forBase64Key: "not base64!!!"))
    }
}
