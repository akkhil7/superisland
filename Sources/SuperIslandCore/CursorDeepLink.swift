import Foundation

/// Cursor desktop agent identity + the pseudo-URL SuperIsland stores in a
/// drop's `contentURL` to bind it to one Cursor conversation. Mirrors
/// `CodexDeepLink`. `deepLink(forContentURL:)` produces a best-effort URL to
/// refocus the conversation; Cursor's deep-link scheme for a specific
/// conversation is unverified, so refocus falls back to fronting the app when
/// this URL doesn't resolve (handled in the adapter layer).
public enum CursorDeepLink {
    public static let bundleID = "com.todesktop.230313mzl4w4u92"
    public static let sessionURLPrefix = "cursor://session/"

    public static func deepLink(forContentURL url: String) -> String? {
        guard url.hasPrefix(sessionURLPrefix) else { return nil }
        let id = String(url.dropFirst(sessionURLPrefix.count))
        guard !id.isEmpty else { return nil }
        return "cursor://anysphere.cursor-deeplink/composer?id=\(id)"
    }
}
