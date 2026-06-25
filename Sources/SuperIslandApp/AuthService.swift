import AppKit
import Combine
import Foundation
import SuperIslandCore

@MainActor
final class AuthService: NSObject, ObservableObject {
    @Published private(set) var session: AuthSession?

    private var pendingPKCE: PKCE?

    private static let keychainAccount = "supabase-session"

    var isSignedIn: Bool { session != nil }

    override init() {
        super.init()
        if let data = Keychain.data(account: Self.keychainAccount),
            let s = try? JSONDecoder().decode(AuthSession.self, from: data)
        {
            session = s
        }
    }

    /// Start sign-in by opening the provider's OAuth page in the user's default
    /// browser (e.g. a new Chrome tab), reusing their existing IdP session per
    /// the OAuth-for-native-apps guidance (RFC 8252). The
    /// `superisland://auth-callback` redirect — registered in Info.plist and
    /// routed via `onOpenURL` / the AppleEvent handler — delivers the code back
    /// to `handleCallback`, which completes the PKCE exchange. PKCE keeps the
    /// code useless without the `pendingPKCE` verifier held here. Returns
    /// immediately; the UI reacts to the published `session`.
    func signIn(provider: OAuthProvider) {
        let pkce = PKCE.generate()
        pendingPKCE = pkce
        let url = OAuthFlow.authorizeURL(
            baseURL: BackendConfig.supabaseURL, provider: provider,
            redirectTo: BackendConfig.redirectURI, codeChallenge: pkce.challenge)
        NSWorkspace.shared.open(url)
    }

    func handleCallback(_ url: URL) {
        switch OAuthFlow.parseCallback(url) {
        case .failure:
            pendingPKCE = nil
        case .success(let code):
            guard let verifier = pendingPKCE?.verifier else { return }
            pendingPKCE = nil
            Task { await self.exchange(code: code, verifier: verifier) }
        }
    }

    func signOut() {
        session = nil
        Keychain.setData(nil, account: Self.keychainAccount)
    }

    /// Return a non-expired access token, refreshing first if needed.
    func validAccessToken() async -> String? {
        guard let current = session else { return nil }
        if current.needsRefresh(now: Date()) {
            await refresh(using: current.refreshToken)
        }
        return session?.accessToken
    }

    // MARK: - Token exchange

    private func exchange(code: String, verifier: String) async {
        var req = URLRequest(url: appending(BackendConfig.tokenURL, query: "grant_type=pkce"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(BackendConfig.anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["auth_code": code, "code_verifier": verifier])
        await sendTokenRequest(req)
    }

    private func refresh(using refreshToken: String) async {
        var req = URLRequest(
            url: appending(BackendConfig.tokenURL, query: "grant_type=refresh_token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(BackendConfig.anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let ok = await sendTokenRequest(req)
        if !ok { signOut() }  // refresh failed → hard wall re-engages
    }

    @discardableResult
    private func sendTokenRequest(_ req: URLRequest) async -> Bool {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            let newSession = try AuthSession.from(tokenResponse: data, now: Date())
            session = newSession
            if let encoded = try? JSONEncoder().encode(newSession) {
                Keychain.setData(encoded, account: Self.keychainAccount)
            }
            return true
        } catch {
            return false
        }
    }

    private func appending(_ url: URL, query: String) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.query = query
        return comps.url!
    }
}
