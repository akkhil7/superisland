import XCTest
@testable import KlipCore

@MainActor
final class KlipStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("klip-test-\(UUID().uuidString).json")
    }

    private func sampleKlip(label: String = "Build") -> Klip {
        Klip(
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

    func testAddAndRemove() {
        let store = KlipStore(fileURL: tempURL())
        let k = sampleKlip()
        store.add(k)
        XCTAssertEqual(store.klips.count, 1)
        store.remove(id: k.id)
        XCTAssertTrue(store.klips.isEmpty)
    }

    func testStatusTransitionAppendsHistoryOnce() {
        let store = KlipStore(fileURL: tempURL())
        let k = sampleKlip()
        store.add(k)

        store.updateStatus(id: k.id, to: .done, reason: "prompt returned")
        XCTAssertEqual(store.klip(id: k.id)?.status, .done)
        XCTAssertEqual(store.klip(id: k.id)?.history.count, 1)

        // Same status again: refreshes lastChecked but no new history entry.
        store.updateStatus(id: k.id, to: .done, reason: "still done")
        XCTAssertEqual(store.klip(id: k.id)?.history.count, 1)

        store.updateStatus(id: k.id, to: .needsAttention, reason: "asking y/n")
        XCTAssertEqual(store.klip(id: k.id)?.history.count, 2)
    }

    func testPersistenceRoundTrip() {
        let url = tempURL()
        let k = sampleKlip(label: "Deploy")
        do {
            let store = KlipStore(fileURL: url)
            store.add(k)
            store.updateStatus(id: k.id, to: .working, reason: "running")
        }
        // New instance loads from disk.
        let reloaded = KlipStore(fileURL: url)
        XCTAssertEqual(reloaded.klips.count, 1)
        XCTAssertEqual(reloaded.klips.first?.label, "Deploy")
        XCTAssertEqual(reloaded.klips.first?.target.bundleID, "com.apple.Terminal")
    }

    func testLocatorCodableRoundTrip() throws {
        let locators: [Locator] = [
            .generic(axWindowTitle: "Notes", axWindowIndex: 0),
            .chrome(windowIndex: 2, tabIndex: 5, url: "https://x.com", title: "X"),
            .terminal(windowIndex: 1, tabIndex: 3, tty: "ttys002"),
        ]
        for loc in locators {
            let data = try JSONEncoder().encode(loc)
            let decoded = try JSONDecoder().decode(Locator.self, from: data)
            XCTAssertEqual(loc, decoded)
        }
    }
}
