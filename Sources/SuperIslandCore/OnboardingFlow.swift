import Foundation

/// Ordered steps of the first-run journey. The UI lives in the app target;
/// this enum is the testable source of truth for order and titles.
public enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome, accessibility, integrations, finish

    public var title: String {
        switch self {
        case .welcome: return "Welcome to SuperIsland"
        case .accessibility: return "Accessibility"
        case .integrations: return "Integrations"
        case .finish: return "Drop your first drop"
        }
    }
}

public enum OnboardingFlow {
    /// UserDefaults key for the completed flag.
    public static let completedDefaultsKey = "hasCompletedOnboarding"

    public static func shouldShowOnLaunch(hasCompleted: Bool) -> Bool {
        !hasCompleted
    }
}
