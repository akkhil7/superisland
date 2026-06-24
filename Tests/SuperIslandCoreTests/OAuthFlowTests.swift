// Tests/SuperIslandCoreTests/OAuthFlowTests.swift
import XCTest
@testable import SuperIslandCore

final class OAuthFlowTests: XCTestCase {
    // RFC 7636 Appendix B canonical PKCE vector.
    func testCodeChallengeMatchesRFCVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            OAuthFlow.codeChallenge(forVerifier: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedPKCEVerifierIsUrlSafeAndLongEnough() {
        let pkce = PKCE.generate()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertEqual(pkce.challenge, OAuthFlow.codeChallenge(forVerifier: pkce.verifier))
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testAuthorizeURLHasProviderRedirectAndChallenge() throws {
        let url = OAuthFlow.authorizeURL(
            baseURL: URL(string: "https://proj.supabase.co")!,
            provider: .azure,
            redirectTo: "superisland://auth-callback",
            codeChallenge: "CHAL")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path, "/auth/v1/authorize")
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value) })
        XCTAssertEqual(items["provider"], "azure")
        XCTAssertEqual(items["redirect_to"], "superisland://auth-callback")
        XCTAssertEqual(items["code_challenge"], "CHAL")
        XCTAssertEqual(items["code_challenge_method"], "s256")
        XCTAssertEqual(items["flow_type"], "pkce")
    }

    func testParseCallbackExtractsCode() {
        let r = OAuthFlow.parseCallback(URL(string: "superisland://auth-callback?code=abc123")!)
        XCTAssertEqual(try? r.get(), "abc123")
    }

    func testParseCallbackSurfacesProviderError() {
        let r = OAuthFlow.parseCallback(
            URL(string: "superisland://auth-callback?error=access_denied&error_description=nope")!)
        if case .failure(let e) = r {
            XCTAssertEqual(e, .providerError("access_denied"))
        } else {
            XCTFail("expected failure")
        }
    }

    func testParseCallbackMissingCode() {
        let r = OAuthFlow.parseCallback(URL(string: "superisland://auth-callback")!)
        if case .failure(let e) = r {
            XCTAssertEqual(e, .missingCode)
        } else {
            XCTFail("expected failure")
        }
    }
}
