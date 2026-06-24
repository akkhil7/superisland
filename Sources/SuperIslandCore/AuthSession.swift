import Foundation

public enum AuthSessionError: Error, Equatable { case malformed }

/// A Supabase auth session held by the app. Persisted (encrypted) in Keychain.
public struct AuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
    }

    /// Decode the JSON body returned by Supabase's `/auth/v1/token` endpoint.
    /// Prefers the absolute `expires_at` (unix seconds); falls back to
    /// `now + expires_in`.
    public static func from(tokenResponse data: Data, now: Date) throws -> AuthSession {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = root["access_token"] as? String,
            let refresh = root["refresh_token"] as? String
        else { throw AuthSessionError.malformed }

        let expiresAt: Date
        if let abs = (root["expires_at"] as? Double) ?? (root["expires_at"] as? NSNumber)?.doubleValue {
            expiresAt = Date(timeIntervalSince1970: abs)
        } else if let inSec = (root["expires_in"] as? Double) ?? (root["expires_in"] as? NSNumber)?.doubleValue {
            expiresAt = now.addingTimeInterval(inSec)
        } else {
            throw AuthSessionError.malformed
        }

        let email = (root["user"] as? [String: Any])?["email"] as? String
        return AuthSession(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, email: email)
    }

    /// True when the access token is expired or within `leeway` of expiring.
    public func needsRefresh(now: Date, leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}
