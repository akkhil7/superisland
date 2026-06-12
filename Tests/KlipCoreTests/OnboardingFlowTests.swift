import XCTest
@testable import KlipCore

final class OnboardingFlowTests: XCTestCase {
    func testStepOrderMatchesTheJourney() {
        XCTAssertEqual(OnboardingStep.allCases, [
            .welcome, .accessibility, .integrations, .finish,
        ])
    }

    func testEveryStepHasATitle() {
        for step in OnboardingStep.allCases {
            XCTAssertFalse(step.title.isEmpty, "missing title for \(step)")
        }
    }

    func testFirstRunGate() {
        XCTAssertTrue(OnboardingFlow.shouldShowOnLaunch(hasCompleted: false))
        XCTAssertFalse(OnboardingFlow.shouldShowOnLaunch(hasCompleted: true))
    }
}
