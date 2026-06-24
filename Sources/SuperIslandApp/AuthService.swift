import Foundation
import AuthenticationServices
import Combine
import SuperIslandCore

@MainActor
final class AuthService: NSObject, ObservableObject {
    @Published private(set) var session: AuthSession?

    private var webSession: ASWebAuthenticationSession?
    private var pendingPKCE: PKCE?
    private var pendingContinuation: CheckedContinuation<Void, Error>?

    private static let keychainAccount = "supabase-session"

    var isSignedIn: Bool { session != nil }

    override init() {
        super.init()
        if let data = Keychain.data(account: Self.keychainAccount),
           let s = try? JSONDecoder().decode(AuthSession.self, from: data) {
            session = s
        }
    }

    func signIn(provider: OAuthProvider) async throws {
        let pkce = PKCE.generate()
        pendingPKCE = pkce
        let url = OAuthFlow.authorizeURL(
            baseURL: BackendConfig.supabaseURL, provider: provider,
            redirectTo: BackendConfig.redirectURI, codeChallenge: pkce.challenge)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingContinuation = cont
            let web = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "superisland"
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error { self.finishPending(.failure(error)); return }
                    if let callbackURL { self.handleCallback(callbackURL) }
                    else { self.finishPending(.failure(URLError(.unknown))) }
                }
            }
            web.presentationContextProvider = self
            web.prefersEphemeralWebBrowserSession = false
            self.webSession = web
            web.start()
        }
    }

    func handleCallback(_ url: URL) {
        switch OAuthFlow.parseCallback(url) {
        case .failure(let e):
            finishPending(.failure(e))
        case .success(let code):
            guard let verifier = pendingPKCE?.verifier else {
                finishPending(.failure(OAuthCallbackError.missingCode)); return
            }
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
        var req = URLRequest(url: appending(BackendConfig.tokenURL, query: "grant_type=refresh_token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(BackendConfig.anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let ok = await sendTokenRequest(req, finishesPending: false)
        if !ok { signOut() }  // refresh failed → hard wall re-engages
    }

    @discardableResult
    private func sendTokenRequest(_ req: URLRequest, finishesPending: Bool = true) async -> Bool {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                if finishesPending { finishPending(.failure(URLError(.userAuthenticationRequired))) }
                return false
            }
            let newSession = try AuthSession.from(tokenResponse: data, now: Date())
            session = newSession
            if let encoded = try? JSONEncoder().encode(newSession) {
                Keychain.setData(encoded, account: Self.keychainAccount)
            }
            if finishesPending { finishPending(.success(())) }
            return true
        } catch {
            if finishesPending { finishPending(.failure(error)) }
            return false
        }
    }

    private func finishPending(_ result: Result<Void, Error>) {
        pendingContinuation?.resume(with: result)
        pendingContinuation = nil
        pendingPKCE = nil
        webSession = nil
    }

    private func appending(_ url: URL, query: String) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.query = query
        return comps.url!
    }
}

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.windows.first { $0.isKeyWindow } ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
