import Foundation

/// Ordered steps of the first-run journey. The UI lives in the app target;
/// this enum is the testable source of truth for order and titles.
public enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome, story, accessibility, terminal, claude, codex, chrome, finish

    public var title: String {
        switch self {
        case .welcome: return "Welcome to Klip"
        case .story: return "The Klip way"
        case .accessibility: return "Accessibility"
        case .terminal: return "Terminal"
        case .claude: return "Claude Desktop"
        case .codex: return "Codex"
        case .chrome: return "Chrome"
        case .finish: return "Drop your first klip"
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
