import XCTest
@testable import SuperIslandCore

final class AuthSessionTests: XCTestCase {
    func testDecodesTokenResponseUsingExpiresAt() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":3600,
         "expires_at":1750000000,"user":{"email":"a@b.com"}}
        """.data(using: .utf8)!
        let s = try AuthSession.from(tokenResponse: json, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(s.accessToken, "at")
        XCTAssertEqual(s.refreshToken, "rt")
        XCTAssertEqual(s.email, "a@b.com")
        XCTAssertEqual(s.expiresAt, Date(timeIntervalSince1970: 1750000000))
    }

    func testFallsBackToExpiresInWhenNoExpiresAt() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":3600,"user":{"email":null}}
        """.data(using: .utf8)!
        let now = Date(timeIntervalSince1970: 1000)
        let s = try AuthSession.from(tokenResponse: json, now: now)
        XCTAssertEqual(s.expiresAt, Date(timeIntervalSince1970: 4600))
        XCTAssertNil(s.email)
    }

    func testMalformedThrows() {
        let json = "{\"refresh_token\":\"rt\"}".data(using: .utf8)!
        XCTAssertThrowsError(try AuthSession.from(tokenResponse: json, now: Date())) {
            XCTAssertEqual($0 as? AuthSessionError, .malformed)
        }
    }

    func testNeedsRefreshWithinLeeway() {
        let s = AuthSession(accessToken: "a", refreshToken: "r",
                            expiresAt: Date(timeIntervalSince1970: 1000), email: nil)
        XCTAssertTrue(s.needsRefresh(now: Date(timeIntervalSince1970: 960), leeway: 60))
        XCTAssertFalse(s.needsRefresh(now: Date(timeIntervalSince1970: 900), leeway: 60))
    }
}
