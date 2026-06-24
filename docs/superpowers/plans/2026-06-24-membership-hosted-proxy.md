# Membership & Hosted Claude Proxy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace SuperIsland's per-machine Anthropic key with an OAuth-gated, server-hosted Claude proxy so any signed-in user runs classification against the owner's single key, bounded by a per-user daily quota.

**Architecture:** A Supabase project provides Auth (Google/Azure/Apple OAuth), a Postgres quota store, and a thin Edge Function (`classify`) that validates the user's JWT, enforces quota, and forwards the client-built Anthropic Messages payload to `api.anthropic.com` with the owner's secret key. The macOS app gains an `AuthService` (one PKCE web flow via `ASWebAuthenticationSession`), a hard sign-in wall, and a classifier "proxy mode" that swaps the `x-api-key` call to Anthropic for a `Bearer <jwt>` call to the Edge Function. All prompt logic stays client-side; the server never duplicates prompts.

**Tech Stack:** Swift 6 (`SuperIslandCore`) / Swift 5 mode (`SuperIslandApp`), CryptoKit, `AuthenticationServices`; Supabase (Postgres + pgTAP, Deno/TypeScript Edge Functions); GitHub Actions; Supabase CLI.

## Global Constraints

- `SuperIslandCore` imports **no AppKit/SwiftUI** — pure, fast-testable logic only. `CryptoKit`/`Foundation` are allowed.
- `SuperIslandApp` and `SuperIslandChromeNativeHost` build in **Swift 5 language mode** (set in `Package.swift`); do not change that.
- Only `SuperIslandCore` has a test target (`SuperIslandCoreTests`). App-target work is verified by `swift build` + documented manual runtime checks. Put every unit-testable behavior in Core.
- **Public, embeddable config:** Supabase project URL, anon key, Edge Function path. **Secret, server-only:** `ANTHROPIC_API_KEY`, `DAILY_CALL_CAP`, `SUPABASE_SERVICE_ROLE_KEY`. Never embed a secret in the app or commit one.
- App bundle id: `com.superisland.SuperIsland`. Custom URL scheme: **`superisland`**, callback host **`auth-callback`** → `superisland://auth-callback`.
- OAuth providers: `google`, `azure` (= Microsoft/Outlook), `apple` — all via Supabase hosted OAuth with **PKCE**. No native Sign-in-with-Apple in this scope.
- Default classifier model stays `claude-haiku-4-5` (`ClassifierProtocolBuilder.defaultModel`). The Edge Function enforces a model allowlist.
- Lint/format: `swift-format` + SwiftLint strict gate runs in CI — match surrounding style (4-space indent, no trailing whitespace).
- Conventional-commit style messages; commit after every green step.

## Spec reference

`docs/superpowers/specs/2026-06-24-membership-hosted-proxy-design.md`

## File Structure

**Created — Core (tested):**
- `Sources/SuperIslandCore/AuthSession.swift` — session model, token-response decode, refresh decision.
- `Sources/SuperIslandCore/OAuthFlow.swift` — provider enum, authorize-URL builder, PKCE challenge derivation, callback parsing.

**Modified — Core (tested):**
- `Sources/SuperIslandCore/Classifier.swift` — proxy auth mode + `quotaExceeded` + quota-header parsing.
- `Sources/SuperIslandCore/OnboardingFlow.swift` — add `signIn` step.

**Created — App:**
- `Sources/SuperIslandApp/BackendConfig.swift` — public Supabase URL/anon-key/function-path constants.
- `Sources/SuperIslandApp/AuthService.swift` — `ASWebAuthenticationSession` PKCE orchestration, Keychain persistence, refresh, published state.
- `Sources/SuperIslandApp/AccountSettingsPane.swift` — Account tab UI.

**Modified — App:**
- `Sources/SuperIslandApp/SuperIslandApp.swift` — `.handlesExternalEvents` / `onOpenURL`, inject `AuthService`.
- `Sources/SuperIslandApp/AppController.swift` — own `AuthService`; hard-wall gate in `createDrop()`; pass bearer token to classifier sites; refine-turn-end path.
- `Sources/SuperIslandApp/Monitor.swift` — classify via proxy token.
- `Sources/SuperIslandApp/ClaudeIntegration.swift` — `classifyFinalMessage` via proxy token.
- `Sources/SuperIslandApp/Settings.swift` — drop `apiKey()`; the Keychain `anthropic-api-key` path is retired.
- `Sources/SuperIslandApp/SettingsPanes.swift` — add Account tab.
- `Sources/SuperIslandApp/Views.swift` (`MenuBarContent`) — locked state when signed out.
- `Sources/SuperIslandApp/Onboarding/OnboardingView.swift` — sign-in step UI.
- `Resources/Info.plist` — `CFBundleURLTypes`.

**Created — Server:**
- `supabase/config.toml`
- `supabase/migrations/0001_profiles_and_quota.sql`
- `supabase/functions/classify/index.ts`
- `supabase/functions/classify/handler.ts` (testable core)
- `supabase/functions/classify/handler_test.ts`
- `supabase/tests/quota_test.sql` (pgTAP)

**Created — CI:**
- `.github/workflows/supabase-deploy.yml`

**Modified — Docs/memory:**
- `docs/architecture-2026-06-23.md` (or successor) — add membership/proxy section.

---

## Phase A — Core (pure, unit-tested) Swift

### Task 1: `AuthSession` model + token-response decode + refresh decision

**Files:**
- Create: `Sources/SuperIslandCore/AuthSession.swift`
- Test: `Tests/SuperIslandCoreTests/AuthSessionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct AuthSession: Codable, Equatable, Sendable { public var accessToken: String; public var refreshToken: String; public var expiresAt: Date; public var email: String? }`
  - `public static func AuthSession.from(tokenResponse data: Data, now: Date) throws -> AuthSession`
  - `public func AuthSession.needsRefresh(now: Date, leeway: TimeInterval = 60) -> Bool`
  - `public enum AuthSessionError: Error, Equatable { case malformed }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SuperIslandCoreTests/AuthSessionTests.swift
import XCTest
@testable import SuperIslandCore

final class AuthSessionTests: XCTestCase {
    func testDecodesTokenResponseUsingExpiresAt() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":3600,
         "expires_at":1750000000,"user":{"email":"a@b.com"}}
        """.data(using: .utf8)!
        let s = try AuthSession.from(tokenResponse: json, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(s.accessToken, "at")
        XCTAssertEqual(s.refreshToken, "rt")
        XCTAssertEqual(s.email, "a@b.com")
        XCTAssertEqual(s.expiresAt, Date(timeIntervalSince1970: 1750000000))
    }

    func testFallsBackToExpiresInWhenNoExpiresAt() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":3600,"user":{"email":null}}
        """.data(using: .utf8)!
        let now = Date(timeIntervalSince1970: 1000)
        let s = try AuthSession.from(tokenResponse: json, now: now)
        XCTAssertEqual(s.expiresAt, Date(timeIntervalSince1970: 4600))
        XCTAssertNil(s.email)
    }

    func testMalformedThrows() {
        let json = "{\"refresh_token\":\"rt\"}".data(using: .utf8)!
        XCTAssertThrowsError(try AuthSession.from(tokenResponse: json, now: Date())) {
            XCTAssertEqual($0 as? AuthSessionError, .malformed)
        }
    }

    func testNeedsRefreshWithinLeeway() {
        let s = AuthSession(accessToken: "a", refreshToken: "r",
                            expiresAt: Date(timeIntervalSince1970: 1000), email: nil)
        XCTAssertTrue(s.needsRefresh(now: Date(timeIntervalSince1970: 960), leeway: 60))
        XCTAssertFalse(s.needsRefresh(now: Date(timeIntervalSince1970: 900), leeway: 60))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter AuthSessionTests`
Expected: FAIL — `AuthSession` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/SuperIslandCore/AuthSession.swift
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter AuthSessionTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandCore/AuthSession.swift Tests/SuperIslandCoreTests/AuthSessionTests.swift
git commit -m "feat(core): AuthSession model with token decode and refresh decision"
```

---

### Task 2: `OAuthFlow` — authorize URL, PKCE challenge, callback parsing

**Files:**
- Create: `Sources/SuperIslandCore/OAuthFlow.swift`
- Test: `Tests/SuperIslandCoreTests/OAuthFlowTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum OAuthProvider: String, CaseIterable, Sendable { case google, azure, apple }` with `public var displayName: String`.
  - `public struct PKCE: Equatable, Sendable { public let verifier: String; public let challenge: String }` and `public static func PKCE.generate() -> PKCE`.
  - `public static func OAuthFlow.codeChallenge(forVerifier:) -> String` (SHA256 → base64url).
  - `public static func OAuthFlow.authorizeURL(baseURL: URL, provider: OAuthProvider, redirectTo: String, codeChallenge: String) -> URL`.
  - `public enum OAuthCallbackError: Error, Equatable { case providerError(String); case missingCode }`.
  - `public static func OAuthFlow.parseCallback(_ url: URL) -> Result<String, OAuthCallbackError>`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SuperIslandCoreTests/OAuthFlowTests.swift
import XCTest
@testable import SuperIslandCore

final class OAuthFlowTests: XCTestCase {
    // RFC 7636 Appendix B canonical PKCE vector.
    func testCodeChallengeMatchesRFCVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthFlow.codeChallenge(forVerifier: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedPKCEVerifierIsUrlSafeAndLongEnough() {
        let pkce = PKCE.generate()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertEqual(pkce.challenge, OAuthFlow.codeChallenge(forVerifier: pkce.verifier))
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testAuthorizeURLHasProviderRedirectAndChallenge() throws {
        let url = OAuthFlow.authorizeURL(
            baseURL: URL(string: "https://proj.supabase.co")!,
            provider: .azure,
            redirectTo: "superisland://auth-callback",
            codeChallenge: "CHAL")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path, "/auth/v1/authorize")
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value) })
        XCTAssertEqual(items["provider"], "azure")
        XCTAssertEqual(items["redirect_to"], "superisland://auth-callback")
        XCTAssertEqual(items["code_challenge"], "CHAL")
        XCTAssertEqual(items["code_challenge_method"], "s256")
        XCTAssertEqual(items["flow_type"], "pkce")
    }

    func testParseCallbackExtractsCode() {
        let r = OAuthFlow.parseCallback(URL(string: "superisland://auth-callback?code=abc123")!)
        XCTAssertEqual(try? r.get(), "abc123")
    }

    func testParseCallbackSurfacesProviderError() {
        let r = OAuthFlow.parseCallback(
            URL(string: "superisland://auth-callback?error=access_denied&error_description=nope")!)
        if case .failure(let e) = r { XCTAssertEqual(e, .providerError("access_denied")) }
        else { XCTFail("expected failure") }
    }

    func testParseCallbackMissingCode() {
        let r = OAuthFlow.parseCallback(URL(string: "superisland://auth-callback")!)
        if case .failure(let e) = r { XCTAssertEqual(e, .missingCode) }
        else { XCTFail("expected failure") }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter OAuthFlowTests`
Expected: FAIL — `OAuthFlow` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/SuperIslandCore/OAuthFlow.swift
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter OAuthFlowTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandCore/OAuthFlow.swift Tests/SuperIslandCoreTests/OAuthFlowTests.swift
git commit -m "feat(core): OAuthFlow PKCE, authorize URL, and callback parsing"
```

---

### Task 3: Classifier proxy mode + `quotaExceeded`

**Files:**
- Modify: `Sources/SuperIslandCore/Classifier.swift`
- Test: `Tests/SuperIslandCoreTests/ClassifierProxyTests.swift`

**Interfaces:**
- Consumes: existing `ClassifierProtocolBuilder`, `Classification`.
- Produces:
  - `ClassifierError` gains `case quotaExceeded(used: Int, cap: Int)`.
  - `public enum ClaudeClassifier.Auth: Sendable { case direct(apiKey: String); case proxy(url: URL, bearer: String) }`.
  - `public init(auth: Auth, model: String = ClassifierProtocolBuilder.defaultModel)`.
  - Back-compat `public init(apiKey: String?, model:)` retained, mapping a present key to `.direct` (used nowhere after Phase C, but keeps the type compiling during migration).
  - `public static func ClaudeClassifier.quotaError(status: Int, headers: [String: String]) -> ClassifierError?` (pure, testable).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SuperIslandCoreTests/ClassifierProxyTests.swift
import XCTest
@testable import SuperIslandCore

final class ClassifierProxyTests: XCTestCase {
    func testQuotaErrorParsesHeadersOn429() {
        let e = ClaudeClassifier.quotaError(
            status: 429, headers: ["x-quota-used": "200", "x-quota-cap": "200"])
        XCTAssertEqual(e, .quotaExceeded(used: 200, cap: 200))
    }

    func testQuotaErrorNilForNon429() {
        XCTAssertNil(ClaudeClassifier.quotaError(status: 200, headers: [:]))
    }

    func testQuotaErrorDefaultsZeroWhenHeadersMissing() {
        let e = ClaudeClassifier.quotaError(status: 429, headers: [:])
        XCTAssertEqual(e, .quotaExceeded(used: 0, cap: 0))
    }

    func testProxyAuthCanBeConstructed() {
        let c = ClaudeClassifier(auth: .proxy(url: URL(string: "https://x/functions/v1/classify")!,
                                              bearer: "jwt"))
        if case .proxy(let url, let bearer) = c.auth {
            XCTAssertEqual(url.absoluteString, "https://x/functions/v1/classify")
            XCTAssertEqual(bearer, "jwt")
        } else { XCTFail("expected proxy auth") }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ClassifierProxyTests`
Expected: FAIL — `quotaError` / `auth` / `Auth` not found.

- [ ] **Step 3: Implement — extend `ClassifierError` and `ClaudeClassifier`**

In `Sources/SuperIslandCore/Classifier.swift`, change the error enum:

```swift
public enum ClassifierError: Error, Equatable {
    case missingAPIKey
    case http(status: Int, body: String)
    case malformedResponse
    case transport(String)
    case quotaExceeded(used: Int, cap: Int)
}
```

Replace the `ClaudeClassifier` struct (lines ~240-300) with:

```swift
/// Live classifier. In `.direct` mode it talks to Anthropic with an API key;
/// in `.proxy` mode it talks to the SuperIsland Edge Function with a Supabase
/// bearer token (the function injects the Anthropic key server-side).
public struct ClaudeClassifier: Sendable {
    public enum Auth: Sendable {
        case direct(apiKey: String)
        case proxy(url: URL, bearer: String)
    }

    public var auth: Auth
    public var model: String

    public init(auth: Auth, model: String = ClassifierProtocolBuilder.defaultModel) {
        self.auth = auth
        self.model = model
    }

    /// Back-compat shim used during migration; a present key maps to `.direct`.
    public init(apiKey: String?, model: String = ClassifierProtocolBuilder.defaultModel) {
        self.auth = .direct(apiKey: apiKey ?? "")
        self.model = model
    }

    /// Map an HTTP status + response headers to a quota error, if applicable.
    public static func quotaError(status: Int, headers: [String: String]) -> ClassifierError? {
        guard status == 429 else { return nil }
        let used = Int(headers["x-quota-used"] ?? "") ?? 0
        let cap = Int(headers["x-quota-cap"] ?? "") ?? 0
        return .quotaExceeded(used: used, cap: cap)
    }

    public func classify(_ input: ClassificationInput) async throws -> Classification {
        let b64 = input.screenshotPNG?.base64EncodedString()
        let body = ClassifierProtocolBuilder.requestBody(
            for: input, model: model, screenshotBase64: b64)
        return try await send(body)
    }

    public func classifyTurnEndMessage(_ message: String) async throws -> Classification {
        let body = ClassifierProtocolBuilder.turnEndRequestBody(message: message, model: model)
        return try await send(body)
    }

    private func send(_ body: [String: Any]) async throws -> Classification {
        let request = try buildRequest(body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClassifierError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClassifierError.malformedResponse
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { headers[ks.lowercased()] = vs }
        }
        if let quota = Self.quotaError(status: http.statusCode, headers: headers) { throw quota }
        guard (200..<300).contains(http.statusCode) else {
            throw ClassifierError.http(
                status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try ClassifierProtocolBuilder.parse(responseData: data)
    }

    private func buildRequest(_ body: [String: Any]) throws -> URLRequest {
        let url: URL
        switch auth {
        case .direct: url = ClassifierProtocolBuilder.endpoint
        case .proxy(let proxyURL, _): url = proxyURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch auth {
        case .direct(let key):
            guard !key.isEmpty else { throw ClassifierError.missingAPIKey }
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(ClassifierProtocolBuilder.apiVersion,
                             forHTTPHeaderField: "anthropic-version")
        case .proxy(_, let bearer):
            guard !bearer.isEmpty else { throw ClassifierError.missingAPIKey }
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ClassifierProxyTests && swift test --filter ClassifierTests`
Expected: PASS — new proxy tests pass and existing `ClassifierTests` still pass (pure builder/parse unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandCore/Classifier.swift Tests/SuperIslandCoreTests/ClassifierProxyTests.swift
git commit -m "feat(core): classifier proxy auth mode and quotaExceeded error"
```

---

### Task 4: Add `signIn` onboarding step

**Files:**
- Modify: `Sources/SuperIslandCore/OnboardingFlow.swift`
- Test: `Tests/SuperIslandCoreTests/OnboardingFlowTests.swift`

**Interfaces:**
- Produces: `OnboardingStep` gains `case signIn` as the **second** step (after `welcome`), with title `"Sign in"`.

- [ ] **Step 1: Update the failing test**

Open `Tests/SuperIslandCoreTests/OnboardingFlowTests.swift`. Find the test asserting the ordered cases (it currently expects `[.welcome, .accessibility, .integrations, .finish]`) and change the expectation to include `signIn`:

```swift
func testStepOrder() {
    XCTAssertEqual(OnboardingStep.allCases,
                   [.welcome, .signIn, .accessibility, .integrations, .finish])
}

func testSignInTitle() {
    XCTAssertEqual(OnboardingStep.signIn.title, "Sign in")
}
```

(If the file has no order test, add both above into the existing `OnboardingFlowTests` class.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter OnboardingFlowTests`
Expected: FAIL — `signIn` not a member / order mismatch.

- [ ] **Step 3: Implement**

In `Sources/SuperIslandCore/OnboardingFlow.swift`:

```swift
public enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome, signIn, accessibility, integrations, finish

    public var title: String {
        switch self {
        case .welcome: return "Welcome to SuperIsland"
        case .signIn: return "Sign in"
        case .accessibility: return "Accessibility"
        case .integrations: return "Integrations"
        case .finish: return "Drop your first drop"
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter OnboardingFlowTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SuperIslandCore/OnboardingFlow.swift Tests/SuperIslandCoreTests/OnboardingFlowTests.swift
git commit -m "feat(core): add sign-in onboarding step"
```

---

## Phase B — Server (Supabase)

> **Cloud-only workflow (no Docker):** This project always runs against the
> **real cloud Supabase project**, never local Docker. Do not use `supabase
> start`, `supabase test db` (local), or `supabase functions serve` (local) —
> all spin up a local Docker Postgres/edge-runtime. Instead: `supabase link
> --project-ref <ref>`, `supabase db push` (applies migrations to the remote),
> `supabase functions deploy classify`, and verify against the remote DB
> connection / deployed function URL. Requires `SUPABASE_ACCESS_TOKEN` + the
> project ref (owner provides). `supabase init` (which only writes
> `supabase/config.toml`, no Docker) is fine to run once if `supabase/` is absent.

### Task 5: Database schema — profiles, usage_daily, quota function, RLS (pgTAP-tested)

**Files:**
- Create: `supabase/config.toml` (via `supabase init`, if absent)
- Create: `supabase/migrations/0001_profiles_and_quota.sql`
- Create: `supabase/tests/quota_test.sql`

**Interfaces:**
- Produces SQL function `public.check_and_increment_quota(p_user uuid, p_cap int) returns table(allowed boolean, used int)` used by the Edge Function (Task 6).

- [ ] **Step 1: Scaffold Supabase (only if `supabase/config.toml` is absent)**

Run: `supabase init`
Expected: creates `supabase/config.toml`, `supabase/.gitignore`.

- [ ] **Step 2: Write the migration**

```sql
-- supabase/migrations/0001_profiles_and_quota.sql

-- One profile row per auth user.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles are self-readable"
  on public.profiles for select
  using (auth.uid() = id);

-- Auto-create a profile when an auth user is created.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Per-user, per-UTC-day call counter.
create table if not exists public.usage_daily (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  count int not null default 0,
  primary key (user_id, day)
);

alter table public.usage_daily enable row level security;

create policy "usage is self-readable"
  on public.usage_daily for select
  using (auth.uid() = user_id);

-- Atomic: increment today's counter for a user unless it would exceed the cap.
-- Returns whether the call is allowed and the resulting used-count.
create or replace function public.check_and_increment_quota(p_user uuid, p_cap int)
returns table(allowed boolean, used int)
language plpgsql security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_count int;
begin
  insert into public.usage_daily (user_id, day, count)
    values (p_user, v_today, 0)
    on conflict (user_id, day) do nothing;

  select count into v_count from public.usage_daily
    where user_id = p_user and day = v_today for update;

  if v_count >= p_cap then
    return query select false, v_count;
  else
    update public.usage_daily set count = count + 1
      where user_id = p_user and day = v_today
      returning count into v_count;
    return query select true, v_count;
  end if;
end;
$$;
```

- [ ] **Step 3: Write the pgTAP test**

```sql
-- supabase/tests/quota_test.sql
begin;
select plan(4);

-- Seed a fake auth user (FK target).
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'q@test.com');

-- First call under a cap of 2 → allowed, used = 1.
select results_eq(
  $$ select allowed, used from public.check_and_increment_quota(
       '00000000-0000-0000-0000-000000000001', 2) $$,
  $$ values (true, 1) $$,
  'first call allowed, used=1');

-- Second call → allowed, used = 2.
select results_eq(
  $$ select allowed, used from public.check_and_increment_quota(
       '00000000-0000-0000-0000-000000000001', 2) $$,
  $$ values (true, 2) $$,
  'second call allowed, used=2');

-- Third call → blocked, used stays 2.
select results_eq(
  $$ select allowed, used from public.check_and_increment_quota(
       '00000000-0000-0000-0000-000000000001', 2) $$,
  $$ values (false, 2) $$,
  'third call blocked at cap');

-- Profile row was auto-created by the trigger.
select is(
  (select count(*)::int from public.profiles
     where id = '00000000-0000-0000-0000-000000000001'),
  1, 'profile auto-created on user insert');

select * from finish();
rollback;
```

- [ ] **Step 4: Apply migrations to the cloud project and run the pgTAP test against the remote DB**

No Docker. Link + push migrations to the remote, ensure pgTAP is available, then run the test file against the remote connection:

```bash
supabase link --project-ref "$SUPABASE_PROJECT_REF"   # needs SUPABASE_ACCESS_TOKEN
supabase db push                                       # applies migrations to remote
# Enable pgTAP once on the remote (idempotent) and run the test:
REMOTE_DB_URL="$(supabase db dump --dry-run 2>/dev/null >/dev/null; echo)"   # or paste the project's pooled connection string
psql "$REMOTE_DB_URL" -c 'create extension if not exists pgtap;'
psql "$REMOTE_DB_URL" -f supabase/tests/quota_test.sql
```

Expected: the migration applies cleanly and the pgTAP run prints `ok 1..4` with no `not ok`. (The `quota_test.sql` wraps everything in `begin … rollback`, so it leaves no rows behind on the remote.) Use the project's pooled/direct connection string from the Supabase dashboard for `REMOTE_DB_URL`.

- [ ] **Step 5: Commit**

```bash
git add supabase/config.toml supabase/migrations/0001_profiles_and_quota.sql supabase/tests/quota_test.sql
git commit -m "feat(server): profiles, usage_daily, atomic quota function with pgTAP tests"
```

---

### Task 6: Edge Function `classify` — auth + quota + forward (Deno-tested)

**Files:**
- Create: `supabase/functions/classify/handler.ts` (testable core, deps injected)
- Create: `supabase/functions/classify/index.ts` (wires real deps + `serve`)
- Create: `supabase/functions/classify/handler_test.ts`

**Interfaces:**
- Consumes: `check_and_increment_quota` (Task 5).
- Produces: an HTTP endpoint at `/functions/v1/classify` that the client calls in proxy mode (Task 8).

- [ ] **Step 1: Write the failing tests**

```ts
// supabase/functions/classify/handler_test.ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { handle, type Deps } from "./handler.ts";

const baseDeps = (over: Partial<Deps> = {}): Deps => ({
  cap: 200,
  modelAllowlist: ["claude-haiku-4-5", "claude-opus-4-8"],
  maxBodyBytes: 200_000,
  getUserId: async () => "user-1",
  incrementQuota: async () => ({ allowed: true, used: 5 }),
  anthropicFetch: async () =>
    new Response(JSON.stringify({ content: [{ type: "text", text: "{}" }] }), { status: 200 }),
  ...over,
});

const req = (body: unknown, auth = "Bearer jwt") =>
  new Request("https://x/functions/v1/classify", {
    method: "POST",
    headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("401 when no bearer token", async () => {
  const res = await handle(req({ model: "claude-haiku-4-5" }, ""), baseDeps());
  assertEquals(res.status, 401);
});

Deno.test("401 when token does not resolve to a user", async () => {
  const res = await handle(req({ model: "claude-haiku-4-5" }),
    baseDeps({ getUserId: async () => null }));
  assertEquals(res.status, 401);
});

Deno.test("400 when model not in allowlist", async () => {
  const res = await handle(req({ model: "gpt-4" }), baseDeps());
  assertEquals(res.status, 400);
});

Deno.test("429 with quota headers when over cap", async () => {
  const res = await handle(req({ model: "claude-haiku-4-5" }),
    baseDeps({ incrementQuota: async () => ({ allowed: false, used: 200 }) }));
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("x-quota-used"), "200");
  assertEquals(res.headers.get("x-quota-cap"), "200");
});

Deno.test("200 forwards to anthropic and sets quota headers", async () => {
  let forwarded = false;
  const res = await handle(req({ model: "claude-haiku-4-5" }),
    baseDeps({
      anthropicFetch: async () => {
        forwarded = true;
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      },
    }));
  assertEquals(res.status, 200);
  assertEquals(forwarded, true);
  assertEquals(res.headers.get("x-quota-used"), "5");
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `deno test supabase/functions/classify/handler_test.ts --allow-net`
Expected: FAIL — `./handler.ts` not found.

- [ ] **Step 3: Implement the testable handler**

```ts
// supabase/functions/classify/handler.ts
export interface Deps {
  cap: number;
  modelAllowlist: string[];
  maxBodyBytes: number;
  getUserId: (jwt: string) => Promise<string | null>;
  incrementQuota: (userId: string, cap: number) => Promise<{ allowed: boolean; used: number }>;
  anthropicFetch: (body: string) => Promise<Response>;
}

const json = (status: number, obj: unknown, extra: HeadersInit = {}) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", ...extra },
  });

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const auth = req.headers.get("authorization") ?? "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!jwt) return json(401, { error: "missing_token" });

  const userId = await deps.getUserId(jwt);
  if (!userId) return json(401, { error: "invalid_token" });

  const raw = await req.text();
  if (raw.length > deps.maxBodyBytes) return json(413, { error: "payload_too_large" });

  let parsed: { model?: string };
  try { parsed = JSON.parse(raw); } catch { return json(400, { error: "invalid_json" }); }
  if (!parsed.model || !deps.modelAllowlist.includes(parsed.model)) {
    return json(400, { error: "model_not_allowed" });
  }

  const { allowed, used } = await deps.incrementQuota(userId, deps.cap);
  const quotaHeaders = { "x-quota-used": String(used), "x-quota-cap": String(deps.cap) };
  if (!allowed) return json(429, { error: "quota_exceeded", used, cap: deps.cap }, quotaHeaders);

  const upstream = await deps.anthropicFetch(raw);
  return new Response(upstream.body, {
    status: upstream.status,
    headers: { "content-type": "application/json", ...quotaHeaders },
  });
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `deno test supabase/functions/classify/handler_test.ts --allow-net`
Expected: PASS (5 tests).

- [ ] **Step 5: Implement `index.ts` (real deps)**

```ts
// supabase/functions/classify/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handle, type Deps } from "./handler.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const CAP = Number(Deno.env.get("DAILY_CALL_CAP") ?? "200");

const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

const deps: Deps = {
  cap: CAP,
  modelAllowlist: ["claude-haiku-4-5", "claude-opus-4-8"],
  maxBodyBytes: 200_000,
  getUserId: async (jwt) => {
    const client = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });
    const { data } = await client.auth.getUser();
    return data.user?.id ?? null;
  },
  incrementQuota: async (userId, cap) => {
    const { data, error } = await admin.rpc("check_and_increment_quota", {
      p_user: userId, p_cap: cap,
    });
    if (error || !data?.[0]) return { allowed: false, used: cap };
    return { allowed: data[0].allowed, used: data[0].used };
  },
  anthropicFetch: (body) =>
    fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body,
    }),
};

serve((req) => handle(req, deps));
```

- [ ] **Step 6: Deploy to the cloud project and smoke-test the live function (no Docker)**

The pure branch logic is already proven by the Deno tests in Step 4. Verify the deployed function rejects unauthenticated calls against the real project:

```bash
supabase functions deploy classify   # needs SUPABASE_ACCESS_TOKEN + linked project
# Unauthenticated POST → expect HTTP 401 from our handler:
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "https://$SUPABASE_PROJECT_REF.functions.supabase.co/classify" \
  -H "content-type: application/json" -d '{"model":"claude-haiku-4-5"}'
```

Expected: `401` (missing bearer token). Function secrets (`ANTHROPIC_API_KEY`, `DAILY_CALL_CAP`) must already be set on the project via `supabase secrets set` (owner setup). A full happy-path round-trip needs a real user JWT.

- [ ] **Step 7: Commit**

```bash
git add supabase/functions/classify/handler.ts supabase/functions/classify/index.ts supabase/functions/classify/handler_test.ts
git commit -m "feat(server): classify Edge Function — auth, quota, model allowlist, forward"
```

---

## Phase C — Client integration (app target)

> No app test target exists; verify each task with `swift build` and the noted runtime check. Run `Scripts/build-app.sh` and `open .build/SuperIsland.app` where a manual check is specified.

### Task 7: Backend config + `AuthService`

**Files:**
- Create: `Sources/SuperIslandApp/BackendConfig.swift`
- Create: `Sources/SuperIslandApp/AuthService.swift`

**Interfaces:**
- Consumes: `AuthSession` (Task 1), `OAuthFlow`/`PKCE`/`OAuthProvider` (Task 2), `Keychain` (existing).
- Produces:
  - `enum BackendConfig { static let supabaseURL: URL; static let anonKey: String; static var classifyURL: URL }`
  - `@MainActor final class AuthService: ObservableObject` with:
    - `@Published private(set) var session: AuthSession?`
    - `var isSignedIn: Bool { session != nil }`
    - `func signIn(provider: OAuthProvider) async throws`
    - `func handleCallback(_ url: URL)` — completes a pending PKCE exchange.
    - `func signOut()`
    - `func validAccessToken() async -> String?` — returns a fresh token, refreshing if needed; nil if signed out / refresh failed.

- [ ] **Step 1: Implement `BackendConfig`**

```swift
// Sources/SuperIslandApp/BackendConfig.swift
import Foundation

/// Public Supabase configuration. The anon key and project URL are designed to
/// be shipped in clients; no secret lives here.
enum BackendConfig {
    static let supabaseURL = URL(string: "https://REPLACE_WITH_PROJECT.supabase.co")!
    static let anonKey = "REPLACE_WITH_ANON_KEY"
    static let redirectURI = "superisland://auth-callback"
    static var classifyURL: URL { supabaseURL.appendingPathComponent("functions/v1/classify") }
    static var tokenURL: URL { supabaseURL.appendingPathComponent("auth/v1/token") }
}
```

(The two `REPLACE_WITH_…` values are filled from the real project before release; tracked as a one-time owner setup step, not a secret.)

- [ ] **Step 2: Implement `AuthService`**

```swift
// Sources/SuperIslandApp/AuthService.swift
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
                guard let self else { return }
                if let error { self.finishPending(.failure(error)); return }
                if let callbackURL { self.handleCallback(callbackURL) }
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
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds (you'll wire `AuthService` into `AppController` in Task 9). No call sites yet — confirm the file compiles in isolation.

- [ ] **Step 4: Commit**

```bash
git add Sources/SuperIslandApp/BackendConfig.swift Sources/SuperIslandApp/AuthService.swift
git commit -m "feat(app): AuthService PKCE sign-in with Keychain-persisted session"
```

---

### Task 8: URL scheme registration + callback routing

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `Sources/SuperIslandApp/SuperIslandApp.swift`
- Modify: `Sources/SuperIslandApp/AppController.swift` (add an `auth` property — minimal, full wiring in Task 9)

**Interfaces:**
- Consumes: `AuthService.handleCallback(_:)`.
- Produces: incoming `superisland://auth-callback?...` URLs reach `AuthService`.

- [ ] **Step 1: Add the URL type to Info.plist**

Insert before the closing `</dict></plist>` in `Resources/Info.plist`:

```xml
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.superisland.SuperIsland.auth</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>superisland</string>
            </array>
        </dict>
    </array>
```

- [ ] **Step 2: Expose `AuthService` on the controller**

In `AppController.swift`, add a stored property near the other services (e.g. by `settings`):

```swift
    let auth = AuthService()
```

- [ ] **Step 3: Route incoming URLs to AuthService**

In `SuperIslandApp.swift`, add an `onOpenURL` to the `MenuBarExtra` content (SwiftUI delivers custom-scheme URLs here for the active scene):

```swift
            MenuBarContent()
                .environmentObject(appDelegate.controller)
                .environmentObject(appDelegate.controller.store)
                .environmentObject(appDelegate.controller.permissions)
                .environmentObject(appDelegate.controller.settings)
                .environmentObject(appDelegate.controller.auth)
                .environmentObject(appDelegate.updater)
                .onOpenURL { url in
                    appDelegate.controller.auth.handleCallback(url)
                }
```

Also add, in `AppDelegate.applicationDidFinishLaunching`, an AppKit fallback so the callback works even when no SwiftUI scene is frontmost:

```swift
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
```

And add the handler method to `AppDelegate`:

```swift
    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        controller.auth.handleCallback(url)
    }
```

- [ ] **Step 4: Build + manual scheme check**

Run: `Scripts/build-app.sh && open .build/SuperIsland.app`
Then run: `open "superisland://auth-callback?error=test"`
Expected: app is frontmost target for the scheme (no crash; `handleCallback` logs/handles the error branch — it will no-op since there's no pending sign-in). Confirms the OS routes the scheme to the app.

- [ ] **Step 5: Commit**

```bash
git add Resources/Info.plist Sources/SuperIslandApp/SuperIslandApp.swift Sources/SuperIslandApp/AppController.swift
git commit -m "feat(app): register superisland:// scheme and route OAuth callback to AuthService"
```

---

### Task 9: Route the 3 classifier sites through the proxy + hard-wall gate

**Files:**
- Modify: `Sources/SuperIslandApp/Monitor.swift`
- Modify: `Sources/SuperIslandApp/ClaudeIntegration.swift`
- Modify: `Sources/SuperIslandApp/AppController.swift`
- Modify: `Sources/SuperIslandApp/Settings.swift`

**Interfaces:**
- Consumes: `AuthService.validAccessToken()`, `ClaudeClassifier(auth: .proxy(...))`, `BackendConfig.classifyURL`.
- Produces: classification runs only for signed-in users via the proxy; dropping is blocked when signed out.

- [ ] **Step 1: `Monitor` — classify via proxy token**

`Monitor` needs the `AuthService`. Add it to `Monitor`'s init (passed from `AppController` where `Monitor` is constructed) as `private let auth: AuthService`. Then replace the classify body (around line 86 + 182):

Replace `let apiKey = settings.apiKey()` with nothing (remove), and inside the `Task { @MainActor in … }` replace the classifier construction:

```swift
            guard let token = await auth.validAccessToken() else {
                return  // signed out → no classification (the `defer` clears inFlight)
            }
            ...
            do {
                let verdict = try await ClaudeClassifier(
                    auth: .proxy(url: BackendConfig.classifyURL, bearer: token),
                    model: ClassifierProtocolBuilder.defaultModel
                ).classify(input)
```

In the `catch`, map quota explicitly:

```swift
            } catch let ClassifierError.quotaExceeded(used, cap) {
                store.updateStatus(id: id, to: .unknown, reason: "Daily limit reached (\(used)/\(cap))")
            } catch {
                store.updateStatus(id: id, to: .unknown, reason: "AI error: \(error)")
            }
```

- [ ] **Step 2: `AppController.suggestAILabelIfTerminal` — proxy token**

Replace `guard let key = settings.apiKey(), !key.isEmpty else { return }` with:

```swift
        // Lazily fetched inside the Task below.
```

and inside the `Task`:

```swift
            guard let token = await self?.auth.validAccessToken() else { return }
            ...
                let verdict = try? await ClaudeClassifier(
                    auth: .proxy(url: BackendConfig.classifyURL, bearer: token),
                    model: ClassifierProtocolBuilder.defaultModel
                ).classify(input),
```

- [ ] **Step 3: `AppController.refineClaudeTurnEnd` + `ClaudeIntegration.classifyFinalMessage` — proxy token**

In `refineClaudeTurnEnd`, replace `let key = settings.apiKey()` with a token fetch inside the Task, and change the call to pass a token:

```swift
        Task { @MainActor [weak self] in
            guard let self else { return }
            let token = await self.auth.validAccessToken()
            ...
                result = await self.claudeIntegration.classifyFinalMessage(message, bearer: token)
```

In `ClaudeIntegration.classifyFinalMessage`, change the signature and body:

```swift
    func classifyFinalMessage(
        _ text: String, bearer: String?
    ) async -> (status: DropStatus, reason: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let bearer, !bearer.isEmpty,
            let verdict = try? await ClaudeClassifier(
                auth: .proxy(url: BackendConfig.classifyURL, bearer: bearer),
                model: ClassifierProtocolBuilder.defaultModel
            ).classifyTurnEndMessage(trimmed)
        {
            switch verdict.status {
            case .needsAttention: return (.needsAttention, verdict.reason)
            case .working: return (.working, "Claude is working…")
            default: return (.done, verdict.reason)
            }
        }
        return ClaudeTranscript.looksLikeRequest(trimmed)
            ? (.needsAttention, "Claude is waiting for your reply")
            : (.done, "Claude finished — ready for you")
    }
```

- [ ] **Step 4: Hard-wall gate in `createDrop()`**

At the top of `AppController.createDrop()` (before the `AXIsProcessTrusted` guard, line ~673):

```swift
        guard auth.isSignedIn else {
            showToast("Sign in to use SuperIsland")
            showOnboarding()
            NSSound.beep()
            return false
        }
```

- [ ] **Step 5: Retire `Settings.apiKey()`**

In `Settings.swift`, delete `func apiKey() -> String? { Keychain.apiKey() }` and update the doc comment on the class to note the key now lives server-side. Remove any remaining references (search `settings.apiKey()` — all four were replaced in Steps 1–4).

- [ ] **Step 6: Build + manual gate check**

Run: `swift build`
Then: `Scripts/build-app.sh && open .build/SuperIsland.app`
Expected: with no session in Keychain, triggering a drop (hotkey / menu) shows the "Sign in to use SuperIsland" toast and opens onboarding; no classification network calls fire. Verify with: `grep -rn "settings.apiKey()" Sources` returns nothing.

- [ ] **Step 7: Commit**

```bash
git add Sources/SuperIslandApp/Monitor.swift Sources/SuperIslandApp/ClaudeIntegration.swift Sources/SuperIslandApp/AppController.swift Sources/SuperIslandApp/Settings.swift
git commit -m "feat(app): route classification through hosted proxy and gate behind sign-in"
```

---

### Task 10: Account settings pane + sign-in onboarding step + locked menu-bar state

**Files:**
- Create: `Sources/SuperIslandApp/AccountSettingsPane.swift`
- Modify: `Sources/SuperIslandApp/SettingsPanes.swift`
- Modify: `Sources/SuperIslandApp/SuperIslandApp.swift`
- Modify: `Sources/SuperIslandApp/Views.swift`
- Modify: `Sources/SuperIslandApp/Onboarding/OnboardingView.swift`

**Interfaces:**
- Consumes: `AuthService` (published `session`/`isSignedIn`), `OAuthProvider`.
- Produces: Account tab, sign-in onboarding step, locked menu-bar state.

- [ ] **Step 1: Account pane**

```swift
// Sources/SuperIslandApp/AccountSettingsPane.swift
import SwiftUI
import SuperIslandCore

struct AccountSettingsPane: View {
    @EnvironmentObject var auth: AuthService

    var body: some View {
        Form {
            if let session = auth.session {
                Section("Signed in") {
                    LabeledContent("Account", value: session.email ?? "—")
                    Button("Sign out") { auth.signOut() }
                }
            } else {
                Section("Sign in to use SuperIsland") {
                    ForEach(OAuthProvider.allCases, id: \.self) { provider in
                        Button("Continue with \(provider.displayName)") {
                            Task { try? await auth.signIn(provider: provider) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
    }
}
```

- [ ] **Step 2: Add the Account tab**

In `SettingsPanes.swift` `SettingsView`'s `TabView`, add as the first tab:

```swift
            AccountSettingsPane()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
```

In `SuperIslandApp.swift`, add `.environmentObject(appDelegate.controller.auth)` to the `SwiftUI.Settings { SettingsView()… }` modifier chain.

- [ ] **Step 3: Locked menu-bar state**

In `Views.swift` `MenuBarContent`, add at the top of the body, gating the normal content:

```swift
    @EnvironmentObject var auth: AuthService
    ...
    var body: some View {
        if !auth.isSignedIn {
            VStack(spacing: 8) {
                Text("Sign in to use SuperIsland").font(.headline)
                Button("Sign in…") { controller.showOnboarding() }
            }
            .padding(16)
        } else {
            // existing menu content
        }
    }
```

- [ ] **Step 4: Sign-in onboarding step UI**

In `Onboarding/OnboardingView.swift`, add a view branch for `.signIn` that mirrors the Account pane's provider buttons and only allows advancing once `auth.isSignedIn` is true (disable the Continue/Next button on `!auth.isSignedIn`). Inject `auth` via `@EnvironmentObject`; ensure `OnboardingWindowController` passes `controller.auth` into the environment.

```swift
        case .signIn:
            VStack(spacing: 12) {
                Text("Sign in to continue").font(.title2.bold())
                Text("SuperIsland uses your account to run AI status checks.")
                    .foregroundStyle(.secondary)
                ForEach(OAuthProvider.allCases, id: \.self) { provider in
                    Button("Continue with \(provider.displayName)") {
                        Task { try? await auth.signIn(provider: provider) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if auth.isSignedIn {
                    Label("Signed in as \(auth.session?.email ?? "")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
```

Gate the step's "Next" control with `.disabled(!auth.isSignedIn)`.

- [ ] **Step 5: Build + manual flow check**

Run: `Scripts/build-app.sh && open .build/SuperIsland.app`
Expected: menu bar shows the locked "Sign in" state; Settings has an Account tab; onboarding's second step is Sign in and blocks Next until signed in. (A real OAuth round-trip requires the configured Supabase project; structurally verify the UI here.)

- [ ] **Step 6: Commit**

```bash
git add Sources/SuperIslandApp/AccountSettingsPane.swift Sources/SuperIslandApp/SettingsPanes.swift Sources/SuperIslandApp/SuperIslandApp.swift Sources/SuperIslandApp/Views.swift Sources/SuperIslandApp/Onboarding/OnboardingView.swift
git commit -m "feat(app): account pane, sign-in onboarding step, locked menu-bar state"
```

---

## Phase D — CI/CD

### Task 11: Supabase deploy workflow

**Files:**
- Create: `.github/workflows/supabase-deploy.yml`

**Interfaces:**
- Consumes repo secrets: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`.
- Produces: migrations pushed and `classify` deployed on push to `main` touching `supabase/**` (and via manual dispatch).

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/supabase-deploy.yml
name: Supabase Deploy

on:
  push:
    branches: [main]
    paths: ["supabase/**"]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    env:
      SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
      PROJECT_REF: ${{ secrets.SUPABASE_PROJECT_REF }}
    steps:
      - uses: actions/checkout@v4
      - uses: supabase/setup-cli@v1
        with:
          version: latest
      - name: Link project
        run: supabase link --project-ref "$PROJECT_REF"
      - name: Push migrations
        run: supabase db push
      - name: Deploy classify function
        run: supabase functions deploy classify
```

- [ ] **Step 2: Validate the workflow file**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/supabase-deploy.yml')); print('ok')"`
Expected: `ok`.

- [ ] **Step 3: Document required repo secrets + function secrets**

Add a short note to the spec's "owner setup" (or a `supabase/README.md`): repo secrets `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`; function secrets set once with `supabase secrets set ANTHROPIC_API_KEY=… DAILY_CALL_CAP=…`.

```bash
cat > supabase/README.md <<'EOF'
# SuperIsland Supabase backend

Deploy is automated by `.github/workflows/supabase-deploy.yml` on pushes to
`main` under `supabase/**`.

## One-time setup
- Repo secrets: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`.
- Function secrets: `supabase secrets set ANTHROPIC_API_KEY=… DAILY_CALL_CAP=200`.
- Auth providers (Supabase dashboard → Authentication → Providers): Google,
  Azure, Apple. Add redirect `superisland://auth-callback` to the URL allowlist.
- Fill `BackendConfig.supabaseURL` / `anonKey` in the app.
EOF
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/supabase-deploy.yml supabase/README.md
git commit -m "ci: Supabase migrations + classify function deploy workflow"
```

---

## Phase E — Docs

### Task 12: Update architecture doc

**Files:**
- Modify: `docs/architecture-2026-06-23.md`

- [ ] **Step 1: Add a "Membership & Hosted Claude Proxy" section**

Document: sign-in is required (hard wall); OAuth via Supabase (Google/Azure/Apple, PKCE); classification routes through the `classify` Edge Function with a per-user daily quota; the Anthropic key lives only on the server; `BackendConfig` holds the public URL/anon key. Update the Classifier line in the High-Level Architecture to note proxy mode, and the "Local Servers" / config sections to mention the Supabase backend.

- [ ] **Step 2: Run the full test suite + build**

Run: `swift test && swift build`
Expected: all Core tests pass (existing + new `AuthSessionTests`, `OAuthFlowTests`, `ClassifierProxyTests`, updated `OnboardingFlowTests`); app builds.

- [ ] **Step 3: Commit**

```bash
git add docs/architecture-2026-06-23.md
git commit -m "docs: document membership and hosted Claude proxy architecture"
```

---

## Self-review notes (coverage vs spec)

- **Auth (Google/Azure/Apple, PKCE web flow):** Tasks 2, 7, 10. ✅
- **Server: Supabase Auth + Postgres quota + Edge proxy:** Tasks 5, 6. ✅
- **Per-user daily quota, atomic:** Task 5 (`check_and_increment_quota` + pgTAP); enforced Task 6; surfaced Task 9. ✅
- **Owner key server-only; client uses bearer token:** Tasks 3, 6, 9. ✅
- **Hard sign-in wall:** Task 9 (`createDrop` gate), Task 10 (locked menu bar + onboarding gate). ✅
- **Retire per-machine key (`Settings.apiKey`):** Task 9 Step 5. ✅
- **URL scheme + callback:** Task 8. ✅
- **Account UI (email, sign out):** Task 10. *(Live quota display deferred — `x-quota-used/cap` are returned by the proxy and parsed in Core; surfacing a remaining-quota number in the Account pane is a small follow-up once a successful call has run. Noted, not blocking.)*
- **CI Supabase deploy:** Task 11. ✅
- **Billing-ready, billing out of scope:** schema isolates `usage_daily`; no payment code. ✅

## Post-implementation

Update memory: extend `cicd-pipeline.md` / add a membership note (Supabase project ref, that sign-in is now required, quota cap value) so future sessions know the proxy is live.
