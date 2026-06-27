import Foundation

/// The ONLY hosts SuperIsland will accept Chrome tab state for — the AI-prompting
/// web apps the bridge integrates with. Any inbound bridge event whose tab URL
/// host is not in this set is rejected.
///
/// The extension is treated as UNTRUSTED (it could be compromised or replaced),
/// so the app — not the extension — is the enforcement point. This mirrors the
/// extension-side allowlist in `Extensions/Chrome/providers.js`; keep the two in
/// sync.
public enum ChromeHostAllowlist {
    /// Exact hosts only — no wildcards. `gemini.google.com` is listed explicitly
    /// so no other `*.google.com` property is ever accepted.
    public static let hosts: Set<String> = [
        // Lovable (editor + generation API)
        "lovable.dev", "api.lovable.dev", "lovable-api.com",
        // Gemini
        "gemini.google.com",
        // ChatGPT
        "chatgpt.com", "chat.openai.com",
        // Claude
        "claude.ai",
        // Emergent (app + generation API + provider infra subdomains)
        "app.emergent.sh", "emergent.sh", "api.emergent.sh",
        "auth.emergent.sh", "ap.emergent.sh", "files.emergent.sh",
        "mcp.emergent.sh", "assets.emergent.sh", "job-connect.api.emergent.sh",
        // v0
        "v0.app", "v0.dev",
        // Grok
        "grok.com",
        // Mistral (Le Chat)
        "chat.mistral.ai",
        // DeepSeek
        "chat.deepseek.com",
        // Perplexity
        "www.perplexity.ai", "perplexity.ai",
        // bolt.new
        "bolt.new",
    ]

    /// True only when `urlString` is an https URL whose EXACT host is allowlisted.
    /// Rejects non-https, unparseable URLs, and any host not in the set. Host
    /// comparison is case-insensitive and never substring/suffix based, so
    /// `evil-lovable.dev`, `lovable.dev.attacker.com`, and userinfo tricks like
    /// `https://chatgpt.com@evil.com/` (host resolves to `evil.com`) are rejected.
    public static func isAllowed(urlString: String?) -> Bool {
        guard let urlString, !urlString.isEmpty,
            let components = URLComponents(string: urlString),
            let scheme = components.scheme?.lowercased(), scheme == "https",
            let host = components.host?.lowercased()
        else { return false }
        return hosts.contains(host)
    }
}
