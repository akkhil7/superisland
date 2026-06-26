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

    // MARK: - recheck(after:) — fast fixed cadence for settled drops

    func testRecheckSchedulesAtFixedShortDelay() {
        let s = BackoffScheduler(baseInterval: 20, backoffFactor: 1.5)
        // Pretend the drop backed off to a long interval first.
        s.advance(contentChanged: false, now: date(0))
        s.advance(contentChanged: false, now: date(30))
        XCTAssertGreaterThan(s.currentInterval, 30)
        // A settled drop asks to be sampled again soon, regardless of backoff.
        s.recheck(after: 5, now: date(100))
        XCTAssertFalse(s.isDue(now: date(104)))
        XCTAssertTrue(s.isDue(now: date(106)))
    }

    func testRecheckDoesNotGrowTheBackoffWindow() {
        // recheck is a fixed re-sample, not a backoff step: calling it
        // repeatedly must keep firing at the same short cadence (so a parked
        // settled drop never stretches out to minutes).
        let s = BackoffScheduler(baseInterval: 20, backoffFactor: 1.5)
        var t: TimeInterval = 0
        for _ in 0..<10 {
            s.recheck(after: 5, now: date(t))
            t += 5
            XCTAssertTrue(s.isDue(now: date(t)))
        }
    }

    func testAdvanceAfterRecheckStillResetsToBaseOnChange() {
        // After a settled drop resumes (content changed → AI runs → working),
        // the normal backoff takes back over from base.
        let s = BackoffScheduler(baseInterval: 20, backoffFactor: 1.5)
        s.recheck(after: 5, now: date(0))
        s.advance(contentChanged: true, now: date(5))
        XCTAssertEqual(s.currentInterval, 20, accuracy: 0.01)
    }
}
