import XCTest
@testable import SuperIslandCore

final class OnboardingFlowTests: XCTestCase {
    func testStepOrderMatchesTheJourney() {
        XCTAssertEqual(
            OnboardingStep.allCases,
            [
                .welcome, .signIn, .accessibility, .integrations, .finish,
            ])
    }

    func testSignInTitle() {
        XCTAssertEqual(OnboardingStep.signIn.title, "Sign in")
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
