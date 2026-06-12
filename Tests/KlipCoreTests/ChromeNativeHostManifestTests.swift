import XCTest
@testable import KlipCore

final class ChromeNativeHostManifestTests: XCTestCase {
    func testBuildsChromeNativeHostManifestForExtensionID() throws {
        let manifest = try ChromeNativeHostManifest(
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            hostPath: "/Applications/Klip.app/Contents/MacOS/KlipChromeNativeHost"
        )

        XCTAssertEqual(manifest.name, "com.useklip.chrome_bridge")
        XCTAssertEqual(manifest.allowedOrigins, [
            "chrome-extension://abcdefghijklmnopabcdefghijklmnop/",
        ])

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ChromeNativeHostManifest.self, from: data)
        XCTAssertEqual(decoded.path, "/Applications/Klip.app/Contents/MacOS/KlipChromeNativeHost")
    }

    func testRejectsEmptyExtensionID() {
        XCTAssertThrowsError(
            try ChromeNativeHostManifest(extensionID: "   ", hostPath: "/host")
        )
    }
}
