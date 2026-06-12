import Foundation

/// Comparison rules for web-content URLs used as in-app tab identity.
public enum ContentURL {
    /// Normalize for identity comparison: drop the fragment (SPAs append
    /// scroll/frame fragments like `#dframe-main`) and any trailing slash.
    public static func normalize(_ url: String) -> String {
        var s = url
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Whether two URLs identify the same in-app tab/route.
    public static func matches(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        // Route aliases: some apps expose one resource under several path
        // prefixes (claude.ai serves a session as both /epitaxy/<id> and
        // /cowork/<id>). Same host + same id-like leaf = same tab.
        guard let ua = URLComponents(string: na), let ub = URLComponents(string: nb),
              let ha = ua.host, ha == ub.host
        else { return false }
        let la = ua.path.split(separator: "/").last.map(String.init) ?? ""
        let lb = ub.path.split(separator: "/").last.map(String.init) ?? ""
        return !la.isEmpty && la == lb && looksLikeResourceID(la)
    }

    /// Only id-like leaves qualify for alias matching — generic words would
    /// wrongly equate routes like /docs/intro and /blog/intro.
    static func looksLikeResourceID(_ s: String) -> Bool {
        s.count >= 16 && s.contains(where: \.isNumber)
            && (s.contains("-") || s.contains("_"))
    }
}

/// Deep links into the Claude Desktop app. Discovered from the app's own URL
/// handler: it registers the `claude://` scheme and routes
/// `claude://claude.ai/<route>/…` like web URLs.
///
/// Local sessions (Cowork AND Claude Code) both live natively at
/// `/epitaxy/local_<id>` — the URL doesn't encode the session kind. Verified
/// live: the `claude-code-desktop` deep-link route opens either kind in its
/// native surface, whereas the `cowork` route forces the Cowork UI onto Code
/// sessions. So all local sessions go through `claude-code-desktop`.
public enum ClaudeDeepLink {
    public static let bundleID = "com.anthropic.claudefordesktop"

    /// Map a captured claude.ai content URL to a `claude://` deep link that
    /// reopens that session/conversation. nil when the URL isn't claude.ai.
    public static func deepLink(forContentURL url: String) -> String? {
        guard let comps = URLComponents(string: ContentURL.normalize(url)),
              comps.host == "claude.ai"
        else { return nil }
        var parts = comps.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        // Local sessions: route via claude-code-desktop (native surface for
        // both Cowork and Code sessions). "cowork" appears as a path when a
        // previous deep link put the app there — same sessions, same fix.
        if parts.count >= 2, ["epitaxy", "cowork"].contains(parts[0]),
           parts[1].hasPrefix("local_") {
            parts[0] = "claude-code-desktop"
        }
        return "claude://claude.ai/" + parts.joined(separator: "/")
    }
}
