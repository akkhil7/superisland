import XCTest
@testable import SuperIslandCore

final class ClassifierProxyTests: XCTestCase {
    func testQuotaErrorParsesHeadersOn429() {
        let e = ClaudeClassifier.quotaError(
            status: 429, headers: ["x-quota-used": "200", "x-quota-cap": "200"])
        XCTAssertEqual(e, .quotaExceeded(used: 200, cap: 200))
    }

    func testQuotaErrorNilForNon429() {
        XCTAssertNil(ClaudeClassifier.quotaError(status: 200, headers: [:]))
    }

    func testQuotaErrorDefaultsZeroWhenHeadersMissing() {
        let e = ClaudeClassifier.quotaError(status: 429, headers: [:])
        XCTAssertEqual(e, .quotaExceeded(used: 0, cap: 0))
    }

    func testProxyAuthCanBeConstructed() {
        let c = ClaudeClassifier(
            auth: .proxy(
                url: URL(string: "https://x/functions/v1/classify")!,
                bearer: "jwt"))
        if case .proxy(let url, let bearer) = c.auth {
            XCTAssertEqual(url.absoluteString, "https://x/functions/v1/classify")
            XCTAssertEqual(bearer, "jwt")
        } else {
            XCTFail("expected proxy auth")
        }
    }
}
