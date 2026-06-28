import Foundation

/// The fixed allowlist of apps SuperIsland supports. Placing a drop on anything
/// outside this set is refused (and the app surfaces a toast). SuperIsland's value is
/// its per-app integrations — Chrome's extension bridge, terminal shell hooks,
/// the editor agent panels, and the Claude/Codex session journals — so a drop
/// on an app with no integration would be a dead chip. We keep the supported
/// set explicit rather than "anything with a window".
///
/// Pure and dependency-free so it can be unit-tested without AppKit.
public enum SupportedApps {
    // MARK: Browser family (Chrome bridge / extension)
    public static let chrome = "com.google.Chrome"
    public static let chromeCanary = "com.google.Chrome.canary"
    public static let brave = "com.brave.Browser"

    // MARK: Terminals (shell-hook integration)
    public static let terminal = "com.apple.Terminal"
    public static let iterm = "com.googlecode.iterm2"

    /// The complete set of supported application bundle identifiers.
    ///
    /// Cursor, VS Code, Claude Desktop and Codex reuse the bundle-id constants
    /// already defined by their respective integrations so the allowlist can
    /// never drift out of sync with them.
    public static let bundleIDs: Set<String> = [
        // Browsers
        chrome, chromeCanary, brave,
        // Terminals
        terminal, iterm,
        // Editor — VS Code (stable). Insiders/VSCodium excluded.
        EditorApp.vsCode,
        // AI desktop agents
        ClaudeDeepLink.bundleID,  // Claude Desktop
        CodexDeepLink.bundleID,  // Codex
        CursorDeepLink.bundleID,  // Cursor (agent)
    ]

    /// Whether SuperIsland supports placing a drop on the app with this bundle id.
    public static func isSupported(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// A friendly name for an app, used in the "not supported" toast when the
    /// running app reports no readable name. Falls back to the given
    /// `appName` (or the bundle id) for apps we don't have a fixed label for.
    public static func displayName(bundleID: String, appName: String? = nil) -> String {
        switch bundleID {
        case chrome: return "Google Chrome"
        case chromeCanary: return "Chrome Canary"
        case brave: return "Brave"
        case terminal: return "Terminal"
        case iterm: return "iTerm"
        case CursorDeepLink.bundleID: return "Cursor"
        case EditorApp.vsCode: return "VS Code"
        case ClaudeDeepLink.bundleID: return "Claude Desktop"
        case CodexDeepLink.bundleID: return "Codex"
        default:
            if let appName, !appName.isEmpty { return appName }
            return bundleID
        }
    }
}

/// The per-app status integration a drop requires. Dropping a supported app
/// whose integration isn't installed/enabled is refused with a toast, the same
/// way dropping an unsupported app is — otherwise the drop can't track status.
///
/// Pure mapping; the live install/enabled state is resolved by the app layer.
public enum RequiredIntegration: String, Sendable {
    case chrome
    case shell  // terminals + editors (status via integrated-terminal shell hooks)
    case claude
    case codex
    case cursor

    /// The integration the app with this bundle id needs, or nil if it needs
    /// none. Every entry in `SupportedApps.bundleIDs` maps to a case.
    public static func required(forBundleID bundleID: String) -> RequiredIntegration? {
        switch bundleID {
        case SupportedApps.chrome, SupportedApps.chromeCanary, SupportedApps.brave:
            return .chrome
        case SupportedApps.terminal, SupportedApps.iterm, EditorApp.vsCode:
            return .shell
        case ClaudeDeepLink.bundleID:
            return .claude
        case CodexDeepLink.bundleID:
            return .codex
        case CursorDeepLink.bundleID:
            return .cursor
        default:
            return nil
        }
    }

    /// Toast copy shown when this integration is required but not set up.
    public var setupMessage: String {
        switch self {
        case .chrome:
            return "Chrome integration isn't connected — set it up in Settings → Integrations"
        case .shell:
            return "Shell integration isn't installed — set it up in Settings → Integrations"
        case .claude:
            return "Claude integration isn't installed — set it up in Settings → Integrations"
        case .codex:
            return "Codex integration is off — turn it on in Settings → Integrations"
        case .cursor:
            return "Cursor integration isn't installed — set it up in Settings → Integrations"
        }
    }
}
