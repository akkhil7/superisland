import Foundation

/// A drop's origin, shown as a small badge so the same underlying app can be
/// told apart by how it's being used — e.g. "Claude Desktop" vs "Claude Code"
/// running in a terminal. Pure: derived from fields already on the drop.
public struct DropSource: Equatable, Sendable {
    public let name: String
    /// SF Symbol name for the badge icon.
    public let icon: String

    public init(name: String, icon: String) {
        self.name = name
        self.icon = icon
    }

    public static func identify(
        bundleID: String, locator: Locator, contentURL: String?, label: String
    ) -> DropSource {
        // Agents run *inside* a terminal, so the host app (Terminal/iTerm) isn't
        // the useful identity — what's running is. Derive it from the signals
        // the hook/rollout handlers stamp on the drop (its content URL + label).
        switch locator {
        case .shell, .terminal, .iterm:
            if contentURL?.hasPrefix(CodexDeepLink.sessionURLPrefix) == true
                || label.hasPrefix("Codex")
            {
                return DropSource(name: "Codex", icon: "chevron.left.forwardslash.chevron.right")
            }
            if label.hasPrefix("Claude Code") {
                return DropSource(name: "Claude Code", icon: "sparkles")
            }
            return DropSource(name: SupportedApps.displayName(bundleID: bundleID), icon: "terminal")
        case .editor:
            return DropSource(
                name: SupportedApps.displayName(bundleID: bundleID), icon: "curlybraces")
        case .chrome:
            return DropSource(name: SupportedApps.displayName(bundleID: bundleID), icon: "globe")
        case .generic:
            break
        }

        switch bundleID {
        case ClaudeDeepLink.bundleID:
            return DropSource(name: "Claude Desktop", icon: "sparkles")
        case CodexDeepLink.bundleID:
            return DropSource(name: "Codex", icon: "chevron.left.forwardslash.chevron.right")
        case CursorDeepLink.bundleID:
            return DropSource(name: "Cursor", icon: "cursorarrow.rays")
        case SupportedApps.chrome, SupportedApps.chromeCanary, SupportedApps.brave:
            return DropSource(name: SupportedApps.displayName(bundleID: bundleID), icon: "globe")
        case EditorApp.vsCode:
            return DropSource(
                name: SupportedApps.displayName(bundleID: bundleID), icon: "curlybraces")
        default:
            return DropSource(
                name: SupportedApps.displayName(bundleID: bundleID), icon: "app.dashed")
        }
    }
}
