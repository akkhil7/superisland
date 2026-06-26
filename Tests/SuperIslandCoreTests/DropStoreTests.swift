import XCTest
@testable import SuperIslandCore

@MainActor
final class DropStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-test-\(UUID().uuidString).json")
    }

    private func sampleDrop(label: String = "Build") -> Drop {
        Drop(
            label: label,
            target: WindowTarget(
                bundleID: "com.apple.Terminal",
                appName: "Terminal",
                pid: 123,
                windowID: 42,
                windowTitle: label,
                locator: .terminal(windowIndex: 1, tabIndex: nil, tty: "ttys001")
            )
        )
    }

    private func sessionDrop(label: String = "Session", url: String) -> Drop {
        Drop(
            label: label,
            target: WindowTarget(
                bundleID: "ai.perplexity.comet",
                appName: "Claude",
                pid: 1,
                windowID: 1,
                windowTitle: label,
                locator: .generic(axWindowTitle: label, axWindowIndex: 0),
                contentURL: url
            )
        )
    }

    func testAddAndRemove() {
        let store = DropStore(fileURL: tempURL())
        let k = sampleDrop()
        store.add(k)
        XCTAssertEqual(store.drops.count, 1)
        store.remove(id: k.id)
        XCTAssertTrue(store.drops.isEmpty)
    }

    func testStatusTransitionAppendsHistoryOnce() {
        let store = DropStore(fileURL: tempURL())
        let k = sampleDrop()
        store.add(k)

        store.updateStatus(id: k.id, to: .done, reason: "prompt returned")
        XCTAssertEqual(store.drop(id: k.id)?.status, .done)
        XCTAssertEqual(store.drop(id: k.id)?.history.count, 1)

        // Same status again: refreshes lastChecked but no new history entry.
        store.updateStatus(id: k.id, to: .done, reason: "still done")
        XCTAssertEqual(store.drop(id: k.id)?.history.count, 1)

        store.updateStatus(id: k.id, to: .needsAttention, reason: "asking y/n")
        XCTAssertEqual(store.drop(id: k.id)?.history.count, 2)
    }

    func testPersistenceRoundTrip() {
        let url = tempURL()
        let k = sampleDrop(label: "Deploy")
        do {
            let store = DropStore(fileURL: url)
            store.add(k)
            store.updateStatus(id: k.id, to: .working, reason: "running")
        }
        // New instance loads from disk.
        let reloaded = DropStore(fileURL: url)
        XCTAssertEqual(reloaded.drops.count, 1)
        XCTAssertEqual(reloaded.drops.first?.label, "Deploy")
        XCTAssertEqual(reloaded.drops.first?.target.bundleID, "com.apple.Terminal")
    }

    func testNameIfUnnamedFillsPlaceholderThenSticks() {
        let store = DropStore(fileURL: tempURL())
        // Born with the bare app name as its label — a placeholder.
        let k = sampleDrop(label: "Terminal")
        store.add(k)

        // First naming replaces the placeholder.
        store.nameIfUnnamed(id: k.id, label: "Deploy the API")
        XCTAssertEqual(store.drop(id: k.id)?.label, "Deploy the API")

        // A later re-classification must NOT churn an already-named drop.
        store.nameIfUnnamed(id: k.id, label: "Some other guess")
        XCTAssertEqual(store.drop(id: k.id)?.label, "Deploy the API")
    }

    func testNameIfUnnamedIgnoresEmptyLabel() {
        let store = DropStore(fileURL: tempURL())
        let k = sampleDrop(label: "Terminal")
        store.add(k)
        store.nameIfUnnamed(id: k.id, label: "")
        XCTAssertEqual(store.drop(id: k.id)?.label, "Terminal")
        store.nameIfUnnamed(id: k.id, label: nil)
        XCTAssertEqual(store.drop(id: k.id)?.label, "Terminal")
    }

    // MARK: - Session uniqueness (one drop per session/content URL)

    func testAddRefusesSecondDropOnSameSession() {
        let store = DropStore(fileURL: tempURL())
        let url = "codex://session/abc"
        let first = sessionDrop(label: "First", url: url)
        XCTAssertTrue(store.add(first))
        // A second drop pointing at the same session is rejected.
        XCTAssertFalse(store.add(sessionDrop(label: "Second", url: url)))
        XCTAssertEqual(store.drops.count, 1)
        XCTAssertEqual(store.drops.first?.id, first.id)
    }

    func testAddAllowsDistinctSessionsAndNilURLs() {
        let store = DropStore(fileURL: tempURL())
        XCTAssertTrue(store.add(sessionDrop(label: "A", url: "codex://session/a")))
        XCTAssertTrue(store.add(sessionDrop(label: "B", url: "codex://session/b")))
        // Drops with no session pointer (nil contentURL) never collide.
        XCTAssertTrue(store.add(sampleDrop(label: "T1")))
        XCTAssertTrue(store.add(sampleDrop(label: "T2")))
        XCTAssertEqual(store.drops.count, 4)
    }

    func testSetContentURLRefusesSessionHeldByAnother() {
        let store = DropStore(fileURL: tempURL())
        let url = "codex://session/xyz"
        let owner = sessionDrop(label: "Owner", url: url)
        store.add(owner)
        let terminal = sampleDrop(label: "Terminal")
        store.add(terminal)
        // The terminal cannot grab a session another drop already holds.
        XCTAssertFalse(store.setContentURL(id: terminal.id, url: url))
        XCTAssertNil(store.drop(id: terminal.id)?.target.contentURL)
        XCTAssertEqual(store.drop(id: owner.id)?.target.contentURL, url)
    }

    func testSetContentURLIsIdempotentForOwner() {
        let store = DropStore(fileURL: tempURL())
        let url = "codex://session/self"
        let owner = sessionDrop(label: "Owner", url: url)
        store.add(owner)
        // Re-setting a drop's own session URL is a no-op success, not a collision.
        XCTAssertTrue(store.setContentURL(id: owner.id, url: url))
        XCTAssertEqual(store.drop(id: owner.id)?.target.contentURL, url)
        // Clearing is always allowed.
        XCTAssertTrue(store.setContentURL(id: owner.id, url: nil))
    }

    func testDropForContentURLFindsOwner() {
        let store = DropStore(fileURL: tempURL())
        let url = "codex://session/lookup"
        let owner = sessionDrop(label: "Owner", url: url)
        store.add(owner)
        XCTAssertEqual(store.drop(forContentURL: url)?.id, owner.id)
        XCTAssertNil(store.drop(forContentURL: "codex://session/missing"))
    }

    func testLoadDedupesDuplicateSessions() throws {
        let url = tempURL()
        // Persist a file that already contains two drops on the same session
        // (e.g. created before the uniqueness guard existed).
        let dupURL = "codex://session/dup"
        let drops = [sessionDrop(label: "A", url: dupURL), sessionDrop(label: "B", url: dupURL)]
        try JSONEncoder.drop.encode(drops).write(to: url)

        let store = DropStore(fileURL: url)
        XCTAssertEqual(store.drops.count, 1)
        XCTAssertEqual(store.drops.first?.label, "A")
    }

    func testLocatorCodableRoundTrip() throws {
        let locators: [Locator] = [
            .generic(axWindowTitle: "Notes", axWindowIndex: 0),
            .chrome(
                windowID: 9,
                windowIndex: 2,
                tabIndex: 5,
                tabID: 1234,
                url: "https://x.com",
                title: "X",
                documentID: "doc-1",
                taskAnchor: ChromeTaskAnchor(kind: .document, label: "X")
            ),
            .chrome(
                windowID: nil,
                windowIndex: 1,
                tabIndex: 0,
                tabID: nil,
                url: nil,
                title: nil,
                documentID: nil,
                taskAnchor: nil
            ),
            .terminal(windowIndex: 1, tabIndex: 3, tty: "ttys002"),
        ]
        for loc in locators {
            let data = try JSONEncoder().encode(loc)
            let decoded = try JSONDecoder().decode(Locator.self, from: data)
            XCTAssertEqual(loc, decoded)
        }
    }
}
