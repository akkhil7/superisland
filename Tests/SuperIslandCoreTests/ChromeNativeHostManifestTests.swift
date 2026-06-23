import XCTest
@testable import SuperIslandCore

final class ChromeNativeHostManifestTests: XCTestCase {
    func testBuildsChromeNativeHostManifestForExtensionID() throws {
        let manifest = try ChromeNativeHostManifest(
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            hostPath: "/Applications/SuperIsland.app/Contents/MacOS/SuperIslandChromeNativeHost"
        )

        XCTAssertEqual(manifest.name, "com.superisland.chrome_bridge")
        XCTAssertEqual(
            manifest.allowedOrigins,
            [
                "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"
            ])

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ChromeNativeHostManifest.self, from: data)
        XCTAssertEqual(
            decoded.path, "/Applications/SuperIsland.app/Contents/MacOS/SuperIslandChromeNativeHost"
        )
    }

    func testRejectsEmptyExtensionID() {
        XCTAssertThrowsError(
            try ChromeNativeHostManifest(extensionID: "   ", hostPath: "/host")
        )
    }
}
