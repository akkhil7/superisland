import Foundation

public enum IntegrationStrength: String, Codable, Sendable {
    case strong
    case appSpecific
    case generic
}

/// Decides which restore/status layer owns a klip.
public enum IntegrationRouter {
    public static func strength(locator: Locator, bundleID: String) -> IntegrationStrength {
        switch locator {
        case .shell, .chrome:
            return .strong
        case .terminal, .iterm, .editor:
            return .appSpecific
        case .generic:
            if isChromeBundle(bundleID) { return .strong }
            if bundleID == "com.apple.Terminal" || bundleID == "com.googlecode.iterm2" {
                return .appSpecific
            }
            if EditorApp.isEditor(bundleID: bundleID) { return .appSpecific }
            return .generic
        }
    }

    public static func allowsVisualRestore(locator: Locator, bundleID: String) -> Bool {
        strength(locator: locator, bundleID: bundleID) == .generic
    }

    private static func isChromeBundle(_ bundleID: String) -> Bool {
        [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.brave.Browser",
        ].contains(bundleID)
    }
}
