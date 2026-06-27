import XCTest

@testable import SuperIslandCore

final class ChromeHostAllowlistTests: XCTestCase {
    func testAcceptsEveryAllowlistedProviderHost() {
        for host in ChromeHostAllowlist.hosts {
            XCTAssertTrue(
                ChromeHostAllowlist.isAllowed(urlString: "https://\(host)/some/path?q=1"),
                "expected \(host) to be allowed")
        }
    }

    func testRejectsNonAllowlistedHosts() {
        for url in [
            "https://example.com/a",
            "https://ci.example.com",
            "https://x.dev",
            "https://openai.com/",
            "https://mail.google.com/",  // not gemini.google.com
        ] {
            XCTAssertFalse(
                ChromeHostAllowlist.isAllowed(urlString: url), "expected \(url) to be rejected")
        }
    }

    func testRejectsLookalikeAndSuffixTricks() {
        for url in [
            "https://evil-lovable.dev/",  // prefix glued on
            "https://lovable.dev.attacker.com/",  // suffix glued on
            "https://grok.com.evil.io/",
            "https://notclaude.ai/",
        ] {
            XCTAssertFalse(
                ChromeHostAllowlist.isAllowed(urlString: url), "expected \(url) to be rejected")
        }
    }

    func testRejectsUserinfoSpoof() {
        // Host resolves to evil.com, not chatgpt.com.
        XCTAssertFalse(
            ChromeHostAllowlist.isAllowed(urlString: "https://chatgpt.com@evil.com/backend-api"))
    }

    func testRejectsNonHTTPSAndMalformed() {
        XCTAssertFalse(ChromeHostAllowlist.isAllowed(urlString: "http://claude.ai/"))
        XCTAssertFalse(ChromeHostAllowlist.isAllowed(urlString: "file:///etc/passwd"))
        XCTAssertFalse(ChromeHostAllowlist.isAllowed(urlString: "not a url"))
        XCTAssertFalse(ChromeHostAllowlist.isAllowed(urlString: ""))
        XCTAssertFalse(ChromeHostAllowlist.isAllowed(urlString: nil))
    }

    func testHostMatchIsCaseInsensitive() {
        XCTAssertTrue(ChromeHostAllowlist.isAllowed(urlString: "https://Claude.AI/chat"))
    }
}
