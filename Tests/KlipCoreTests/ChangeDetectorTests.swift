import XCTest
@testable import KlipCore

final class ChangeDetectorTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testNoEvaluateWhileContentKeepsChanging() {
        let d = ChangeDetector(settleInterval: 5, fallbackInterval: 100)
        XCTAssertFalse(d.observe(hash: 1, now: date(0)))   // prime
        XCTAssertFalse(d.observe(hash: 2, now: date(2)))   // changed → busy
        XCTAssertFalse(d.observe(hash: 3, now: date(4)))   // changed → busy
        XCTAssertFalse(d.observe(hash: 4, now: date(6)))   // changed → busy
    }

    func testEvaluatesOnSettleAfterChange() {
        let d = ChangeDetector(settleInterval: 5, fallbackInterval: 100)
        _ = d.observe(hash: 1, now: date(0))               // prime, dirty
        XCTAssertFalse(d.observe(hash: 2, now: date(2)))    // change at t=2
        XCTAssertFalse(d.observe(hash: 2, now: date(5)))    // quiet 3s < 5s
        XCTAssertTrue(d.observe(hash: 2, now: date(8)))     // quiet 6s ≥ 5s → evaluate
        // After settling, no repeat evaluation until next change.
        XCTAssertFalse(d.observe(hash: 2, now: date(10)))
    }

    func testInitialSettleTriggersFirstEvaluation() {
        let d = ChangeDetector(settleInterval: 5, fallbackInterval: 100)
        XCTAssertFalse(d.observe(hash: 1, now: date(0)))    // prime sets dirty
        XCTAssertTrue(d.observe(hash: 1, now: date(6)))     // settled → first evaluate
    }

    func testFallbackEvaluatesWhenNeverSettlesCleanly() {
        // settle never reached because content changes every tick within settle window,
        // but fallback fires on the long interval.
        let d = ChangeDetector(settleInterval: 5, fallbackInterval: 30)
        _ = d.observe(hash: 0, now: date(0))
        var evaluations = 0
        for t in stride(from: 2, through: 70, by: 2) {
            // Always-changing content (hash = t) keeps resetting settle.
            if d.observe(hash: t, now: date(TimeInterval(t))) { evaluations += 1 }
        }
        // Over 70s with a 30s fallback we expect ~2 forced evaluations despite
        // settle never being reached.
        XCTAssertGreaterThanOrEqual(evaluations, 2,
            "fallback should force periodic evaluation despite constant change")
    }
}
