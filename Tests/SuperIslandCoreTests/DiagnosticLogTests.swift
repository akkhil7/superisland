import XCTest

@testable import SuperIslandCore

final class DiagnosticLogTests: XCTestCase {
    private func entry(_ category: DiagnosticCategory, _ msg: String) -> DiagnosticEntry {
        DiagnosticEntry(
            date: Date(timeIntervalSince1970: 0), launchID: "abc123", category: category,
            message: msg)
    }

    func testRingBufferDropsOldestBeyondCapacity() {
        var buf = DiagnosticRingBuffer(capacity: 3)
        for i in 1...5 { buf.append(entry(.app, "m\(i)")) }
        XCTAssertEqual(buf.entries.map(\.message), ["m3", "m4", "m5"])
    }

    func testFilteredByCategory() {
        var buf = DiagnosticRingBuffer(capacity: 10)
        buf.append(entry(.auth, "signed in"))
        buf.append(entry(.proxy, "200 ok"))
        buf.append(entry(.auth, "refreshed"))
        XCTAssertEqual(buf.filtered(.auth).map(\.message), ["signed in", "refreshed"])
        XCTAssertEqual(buf.filtered(nil).count, 3)
    }

    func testClear() {
        var buf = DiagnosticRingBuffer(capacity: 5)
        buf.append(entry(.app, "x"))
        buf.clear()
        XCTAssertTrue(buf.entries.isEmpty)
    }

    func testLineFormatIsDeterministic() {
        // 1970-01-01 00:00:01.250 UTC
        let e = DiagnosticEntry(
            date: Date(timeIntervalSince1970: 1.25), launchID: "L1", category: .proxy,
            message: "classify 429")
        XCTAssertEqual(
            DiagnosticFormat.line(e, timeZone: TimeZone(identifier: "UTC")!),
            "00:00:01.250  [L1]  PROXY  classify 429")
    }

    func testLaunchHeader() {
        let header = DiagnosticFormat.launchHeader(
            launchID: "L1", version: "0.1", build: "42",
            date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(header, "──── LAUNCH L1 · v0.1 (build 42) · 1970-01-01T00:00:00Z ────")
    }
}
