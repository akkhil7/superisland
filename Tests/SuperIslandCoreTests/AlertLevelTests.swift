import XCTest
@testable import SuperIslandCore

final class AlertLevelTests: XCTestCase {
    func testEachLevelHasOnePrimaryCue() {
        XCTAssertFalse(AlertLevel.subtle.showsColoredNotch)
        XCTAssertFalse(AlertLevel.subtle.showsBanner)

        XCTAssertTrue(AlertLevel.coloredNotch.showsColoredNotch)
        XCTAssertFalse(AlertLevel.coloredNotch.showsBanner)

        // notify uses the banner instead of the colored notch (not both).
        XCTAssertFalse(AlertLevel.notify.showsColoredNotch)
        XCTAssertTrue(AlertLevel.notify.showsBanner)
    }

    func testRawValueOrderingMatchesIntrusiveness() {
        XCTAssertLessThan(AlertLevel.subtle.rawValue, AlertLevel.coloredNotch.rawValue)
        XCTAssertLessThan(AlertLevel.coloredNotch.rawValue, AlertLevel.notify.rawValue)
    }

    func testRoundTripsThroughRawValue() {
        for level in AlertLevel.allCases {
            XCTAssertEqual(AlertLevel(rawValue: level.rawValue), level)
        }
    }
}

final class AlertPolicyTests: XCTestCase {
    func testAlertingStatuses() {
        XCTAssertTrue(AlertPolicy.isAlerting(.needsAttention))
        XCTAssertTrue(AlertPolicy.isAlerting(.done))
        XCTAssertFalse(AlertPolicy.isAlerting(.working))
        XCTAssertFalse(AlertPolicy.isAlerting(.unknown))
        XCTAssertFalse(AlertPolicy.isAlerting(.stale))
    }

    func testTransitionsThatAlert() {
        XCTAssertTrue(AlertPolicy.shouldAlert(from: .working, to: .needsAttention))
        XCTAssertTrue(AlertPolicy.shouldAlert(from: .working, to: .done))
        XCTAssertTrue(AlertPolicy.shouldAlert(from: .unknown, to: .needsAttention))
    }

    func testFirstSightingIsSilent() {
        // nil "old" = we've never seen this drop — loading persisted drops or
        // dropping a fresh one must not fire a banner.
        XCTAssertFalse(AlertPolicy.shouldAlert(from: nil, to: .needsAttention))
        XCTAssertFalse(AlertPolicy.shouldAlert(from: nil, to: .done))
    }

    func testNoOpTransitionIsSilent() {
        XCTAssertFalse(AlertPolicy.shouldAlert(from: .needsAttention, to: .needsAttention))
        XCTAssertFalse(AlertPolicy.shouldAlert(from: .done, to: .done))
    }

    func testTransitionsIntoNonAlertingAreSilent() {
        XCTAssertFalse(AlertPolicy.shouldAlert(from: .needsAttention, to: .working))
        XCTAssertFalse(AlertPolicy.shouldAlert(from: .done, to: .unknown))
        XCTAssertFalse(AlertPolicy.shouldAlert(from: .working, to: .stale))
    }

    // MARK: - bannerAction (raise / refresh / leave)

    func testAlertingTransitionRaisesBanner() {
        XCTAssertEqual(
            AlertPolicy.bannerAction(from: .working, to: .needsAttention, hasBanner: false),
            .raise
        )
        XCTAssertEqual(
            AlertPolicy.bannerAction(from: .needsAttention, to: .done, hasBanner: true),
            .raise
        )
    }

    func testFirstSightingWithoutBannerLeavesEverythingAlone() {
        // Loading a persisted needsAttention drop must not raise a banner.
        XCTAssertEqual(
            AlertPolicy.bannerAction(from: nil, to: .needsAttention, hasBanner: false),
            .leave
        )
        XCTAssertEqual(
            AlertPolicy.bannerAction(from: nil, to: .working, hasBanner: false),
            .leave
        )
    }

    func testShowingBannerDismissesWhenDropLeavesAlertingStatus() {
        // The bug: a needsAttention banner that becomes `working` (WIP/purple)
        // must disappear — banners only exist for alerting states, never for
        // "working", so the card never freezes on the red "Needs you" alert.
        XCTAssertEqual(
            AlertPolicy.bannerAction(from: .needsAttention, to: .working, hasBanner: true),
            .dismiss
        )
        XCTAssertEqual(
            AlertPolicy.bannerAction(from: .done, to: .unknown, hasBanner: true),
            .dismiss
        )
    }

    func testShowingBannerRefreshesOnSameStatusLabelUpdate() {
        XCTAssertEqual(
            AlertPolicy.bannerAction(from: .needsAttention, to: .needsAttention, hasBanner: true),
            .refresh
        )
    }

    // MARK: - shouldChime (raised banners only, gated by the sound setting)

    func testChimesOnlyOnRaiseWhenSoundEnabled() {
        XCTAssertTrue(AlertPolicy.shouldChime(action: .raise, soundEnabled: true))

        // A refresh of an already-showing banner must stay silent, or a drop
        // that keeps updating while alerting would replay the chime.
        XCTAssertFalse(AlertPolicy.shouldChime(action: .refresh, soundEnabled: true))
        XCTAssertFalse(AlertPolicy.shouldChime(action: .dismiss, soundEnabled: true))
        XCTAssertFalse(AlertPolicy.shouldChime(action: .leave, soundEnabled: true))
    }

    func testNeverChimesWhenSoundDisabled() {
        XCTAssertFalse(AlertPolicy.shouldChime(action: .raise, soundEnabled: false))
        XCTAssertFalse(AlertPolicy.shouldChime(action: .refresh, soundEnabled: false))
        XCTAssertFalse(AlertPolicy.shouldChime(action: .dismiss, soundEnabled: false))
        XCTAssertFalse(AlertPolicy.shouldChime(action: .leave, soundEnabled: false))
    }
}
