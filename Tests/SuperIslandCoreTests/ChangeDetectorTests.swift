import XCTest
@testable import SuperIslandCore

final class BackoffSchedulerTests: XCTestCase {
    private func date(_ s: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: s) }

    func testFiresImmediatelyOnFirstCall() {
        let s = BackoffScheduler(baseInterval: 20)
        XCTAssertTrue(s.isDue(now: date(0)))
    }

    func testNotDueRightAfterAdvance() {
        let s = BackoffScheduler(baseInterval: 20)
        s.advance(contentChanged: false, now: date(0))
        XCTAssertFalse(s.isDue(now: date(1)))
    }

    func testDueAfterBackoffInterval() {
        let s = BackoffScheduler(baseInterval: 20, backoffFactor: 1.5)
        s.advance(contentChanged: false, now: date(0))
        // First no-change advance: interval = 20 * 1.5 = 30
        XCTAssertFalse(s.isDue(now: date(29)))
        XCTAssertTrue(s.isDue(now: date(31)))
    }

    func testIntervalGrowsOnRepeatedNoChange() {
        let s = BackoffScheduler(baseInterval: 20, backoffFactor: 1.5)
        s.advance(contentChanged: false, now: date(0))
        XCTAssertEqual(s.currentInterval, 30, accuracy: 0.01)
        s.advance(contentChanged: false, now: date(30))
        XCTAssertEqual(s.currentInterval, 45, accuracy: 0.01)
        s.advance(contentChanged: false, now: date(75))
        XCTAssertEqual(s.currentInterval, 67.5, accuracy: 0.01)
    }

    func testIntervalResetsOnContentChange() {
        let s = BackoffScheduler(baseInterval: 20, backoffFactor: 1.5)
        s.advance(contentChanged: false, now: date(0))
        s.advance(contentChanged: false, now: date(30))
        XCTAssertGreaterThan(s.currentInterval, 20)
        s.advance(contentChanged: true, now: date(75))
        XCTAssertEqual(s.currentInterval, 20, accuracy: 0.01)
    }

    func testIntervalCapsAtMax() {
        let s = BackoffScheduler(baseInterval: 20, backoffFactor: 2, maxInterval: 100)
        var t: TimeInterval = 0
        for _ in 0..<20 {
            s.advance(contentChanged: false, now: date(t))
            t += s.currentInterval
        }
        XCTAssertEqual(s.currentInterval, 100, accuracy: 0.01)
    }

    func testResetAfterMaxStillFiresAtBase() {
        let s = BackoffScheduler(baseInterval: 20, backoffFactor: 2, maxInterval: 100)
        var t: TimeInterval = 0
        for _ in 0..<20 {
            s.advance(contentChanged: false, now: date(t))
            t += s.currentInterval
        }
        // Now trigger a content change — should snap back to 20s.
        s.advance(contentChanged: true, now: date(t))
        XCTAssertEqual(s.currentInterval, 20, accuracy: 0.01)
        XCTAssertFalse(s.isDue(now: date(t + 19)))
        XCTAssertTrue(s.isDue(now: date(t + 21)))
    }
}
