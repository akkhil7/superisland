import Foundation
import CryptoKit

public enum OAuthProvider: String, CaseIterable, Sendable {
    case google, azure, apple
    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .azure: return "Microsoft"
        case .apple: return "Apple"
        }
    }
}

public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    /// 32 random bytes → base64url verifier, plus its S256 challenge.
    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let verifier = Data(bytes).base64URLEncodedString()
        return PKCE(verifier: verifier, challenge: OAuthFlow.codeChallenge(forVerifier: verifier))
    }
}

public enum OAuthCallbackError: Error, Equatable {
    case providerError(String)
    case missingCode
}

public enum OAuthFlow {
    public static func codeChallenge(forVerifier verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    public static func authorizeURL(
        baseURL: URL, provider: OAuthProvider, redirectTo: String, codeChallenge: String
    ) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.path = "/auth/v1/authorize"
        comps.queryItems = [
            .init(name: "provider", value: provider.rawValue),
            .init(name: "redirect_to", value: redirectTo),
            .init(name: "flow_type", value: "pkce"),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "code_challenge_method", value: "s256"),
        ]
        return comps.url!
    }

    public static func parseCallback(_ url: URL) -> Result<String, OAuthCallbackError> {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            return .failure(.providerError(err))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .failure(.missingCode)
        }
        return .success(code)
    }
}

extension Data {
    /// base64url without padding (RFC 7636).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
