import Foundation

/// Whether a resolved drop target carries the tab/session identity its
/// integration needs to actually track status. Used as the third `createDrop`
/// gate (after "is the app supported" and "is its integration set up"): a
/// drop on a screen that resolves to nothing — an in-app Settings pane, a
/// `chrome://` page, a window with no session — is refused instead of becoming
/// a dead chip that never updates.
///
/// Pure and dependency-free (Foundation only) so it can be unit-tested without
/// AppKit, like `SupportedApps`.
public enum TargetMappability {
    /// The switch is exhaustive over `Locator` on purpose: adding a new locator
    /// case won't compile until it declares whether it is mappable here, so the
    /// guard can never silently miss a future integration.
    public static func canMap(locator: Locator, contentURL: String?) -> Bool {
        switch locator {
        case let .chrome(_, _, _, _, url, _, _, _):
            // Only real web pages are trackable; internal/empty pages have a tab
            // id but never produce status.
            return isTrackableWebURL(url)
        case .shell:
            // A TTY was captured — shell hook events can drive status.
            return true
        case let .terminal(_, _, tty):
            // The no-TTY fallback can't receive shell events.
            return tty != nil
        case .iterm:
            // Reached only when no TTY could be captured (Automation denied);
            // a session id alone can't receive shell events.
            return false
        case let .editor(filePath, fileName, workspaceName):
            return filePath != nil || fileName != nil || workspaceName != nil
        case .generic:
            // Electron desktop agents (Claude Desktop, Codex, Cursor) and other
            // generic windows bind their session through the web content URL.
            return contentURL != nil
        }
    }

    /// `http`/`https` only. Blocks `chrome://`, `about:`, `data:`,
    /// `view-source:`, `chrome-extension:`, the new-tab page, and empty/nil URLs.
    static func isTrackableWebURL(_ urlString: String?) -> Bool {
        guard let urlString, !urlString.isEmpty,
            let scheme = URL(string: urlString)?.scheme?.lowercased()
        else { return false }
        return scheme == "http" || scheme == "https"
    }
}
