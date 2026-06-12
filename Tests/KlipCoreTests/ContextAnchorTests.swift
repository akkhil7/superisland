import XCTest
@testable import KlipCore

final class ContextAnchorTests: XCTestCase {
    // MARK: - Label matching

    func testExactAndCaseInsensitiveMatch() {
        XCTAssertTrue(RestoreMatcher.labelsMatch("Fix login bug", "fix login bug"))
        XCTAssertTrue(RestoreMatcher.labelsMatch("  Fix login bug ", "Fix  login bug"))
    }

    func testTruncatedTabTitleMatches() {
        XCTAssertTrue(RestoreMatcher.labelsMatch(
            "Refactor the authentication mod…",
            "Refactor the authentication module in api/auth"
        ))
    }

    func testDifferentTabsDoNotMatch() {
        XCTAssertFalse(RestoreMatcher.labelsMatch("Fix login bug", "Write release notes"))
        XCTAssertFalse(RestoreMatcher.labelsMatch("", "Write release notes"))
    }

    // MARK: - Content URL identity

    func testSameRouteMatchesDespiteFragmentAndSlash() {
        XCTAssertTrue(ContentURL.matches(
            "https://claude.ai/epitaxy/local_0ead4972#dframe-main",
            "https://claude.ai/epitaxy/local_0ead4972/"
        ))
    }

    func testDifferentSessionsDoNotMatch() {
        XCTAssertFalse(ContentURL.matches(
            "https://claude.ai/epitaxy/local_0ead4972",
            "https://claude.ai/epitaxy/local_77aa00bb"
        ))
        XCTAssertFalse(ContentURL.matches("", ""))
    }

    func testRouteAliasesOfSameSessionMatch() {
        // claude.ai serves one Cowork session as /epitaxy/<id> and /cowork/<id>.
        XCTAssertTrue(ContentURL.matches(
            "https://claude.ai/epitaxy/local_24dee658-486a-495d-aa49-dc3b94dc3a0a",
            "https://claude.ai/cowork/local_24dee658-486a-495d-aa49-dc3b94dc3a0a"
        ))
        // Generic words must not alias-match across different routes.
        XCTAssertFalse(ContentURL.matches(
            "https://example.com/docs/intro",
            "https://example.com/blog/intro"
        ))
    }

    // MARK: - Claude deep links

    func testLocalSessionRoutesViaClaudeCodeDesktop() {
        // Native surface for any local session (Cowork or Code).
        XCTAssertEqual(
            ClaudeDeepLink.deepLink(
                forContentURL: "https://claude.ai/epitaxy/local_24dee658-486a#dframe-main"
            ),
            "claude://claude.ai/claude-code-desktop/local_24dee658-486a"
        )
        // A cowork-path URL (left behind by an earlier deep link) maps the same.
        XCTAssertEqual(
            ClaudeDeepLink.deepLink(
                forContentURL: "https://claude.ai/cowork/local_24dee658-486a"
            ),
            "claude://claude.ai/claude-code-desktop/local_24dee658-486a"
        )
        // Non-local cowork paths pass through untouched.
        XCTAssertEqual(
            ClaudeDeepLink.deepLink(forContentURL: "https://claude.ai/cowork/shared-artifact"),
            "claude://claude.ai/cowork/shared-artifact"
        )
    }

    func testChatURLKeepsItsRoute() {
        XCTAssertEqual(
            ClaudeDeepLink.deepLink(forContentURL: "https://claude.ai/chat/abc-123-def-456"),
            "claude://claude.ai/chat/abc-123-def-456"
        )
    }

    func testNonClaudeURLProducesNoDeepLink() {
        XCTAssertNil(ClaudeDeepLink.deepLink(forContentURL: "https://chatgpt.com/codex/tasks/x"))
    }

    // MARK: - WindowTarget backward compatibility

    func testDecodingOldTargetWithoutContextAnchor() throws {
        // JSON persisted before contextAnchor existed must still decode.
        let old = WindowTarget(
            bundleID: "com.example", appName: "Example", pid: 1,
            windowID: 2, windowTitle: "T",
            locator: .generic(axWindowTitle: "T", axWindowIndex: nil)
        )
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(old)
        ) as! [String: Any]
        json.removeValue(forKey: "contextAnchor")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(WindowTarget.self, from: data)
        XCTAssertNil(decoded.contextAnchor)
        XCTAssertEqual(decoded.bundleID, "com.example")
    }

    // MARK: - noteReason

    @MainActor
    func testNoteReasonKeepsStatusAndDeduplicates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = KlipStore(fileURL: dir.appendingPathComponent("klips.json"))

        let target = WindowTarget(
            bundleID: "com.example", appName: "Example", pid: 1,
            windowID: 2, windowTitle: "T",
            locator: .generic(axWindowTitle: "T", axWindowIndex: nil)
        )
        let klip = Klip(label: "L", target: target, status: .working)
        store.add(klip)

        store.noteReason(id: klip.id, reason: "In a background tab")
        store.noteReason(id: klip.id, reason: "In a background tab")
        store.noteReason(id: klip.id, reason: "In a background tab")

        let stored = try XCTUnwrap(store.klip(id: klip.id))
        XCTAssertEqual(stored.status, .working)
        XCTAssertEqual(stored.history.filter { $0.reason == "In a background tab" }.count, 1)
        XCTAssertNotNil(stored.lastChecked)
    }
}
