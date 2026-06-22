# CI/CD for SuperIsland (macOS app) — Design

**Date:** 2026-06-23
**Status:** Approved (design); implementation plan pending

## Goal

Stand up CI/CD for SuperIsland — a SwiftPM-based macOS menu-bar app — on GitHub
Actions. Every pull request runs a quality gate; pushing a version tag produces a
Developer ID–signed, notarized, stapled `.dmg`, publishes it as a GitHub Release,
and updates a Sparkle appcast so installed apps auto-update.

## Context

- SwiftPM package (`swift-tools-version: 6.0`), targets `SuperIslandApp`,
  `SuperIslandCore`, `SuperIslandChromeNativeHost`; tests in `SuperIslandCoreTests`.
- No git remote and no CI config exist yet — greenfield.
- Existing local scripts are the build/package source of truth and will be reused:
  - `Scripts/build-app.sh` — `swift build` + assemble `.build/SuperIsland.app`, sign.
  - `Scripts/package-dmg.sh` — Developer ID hardened-runtime sign → DMG → notarize → staple.
  - `Scripts/create-local-codesign-cert.sh` — local dev self-signed cert helper.
- Bundle identifier `com.superisland.SuperIsland`; current version `0.1` / build `1`.

## Chosen approach

**Approach A — shell scripts as core, thin GitHub Actions wrappers.**
`build-app.sh` and `package-dmg.sh` remain the single source of truth for how the
app is built, signed, and packaged. Workflows only prepare the environment
(import the cert into a temporary keychain, inject secrets and version) and invoke
those scripts, so local and CI builds stay identical and releases are reproducible
on a developer Mac.

Rejected: **Fastlane** (Xcode-project-oriented; fights a SwiftPM + hand-assembled
bundle; pulls in a Ruby toolchain for little gain) and **all-inline YAML**
(duplicates script logic, not locally reproducible).

## Decisions locked in

- **Platform:** GitHub + GitHub Actions, GitHub-hosted `macos-15` runners.
- **Release trigger:** pushing a git tag matching `v*`.
- **Updates:** Sparkle 2.x auto-update via an appcast feed.
- **PR gates:** release build, tests, lint/format, and an ad-hoc signing dry-run.
- **Notarization auth:** app-specific password (App Store Connect API key is a
  documented future alternative).
- **Appcast hosting:** GitHub Pages (custom website domain is a future alternative).

---

## Component 1 — Sparkle integration (app code)

- Add Sparkle 2.x as an SPM dependency in `Package.swift`, linked into
  `SuperIslandApp`.
- Add an `SPUStandardUpdaterController` with a **"Check for Updates…"** menu item
  and automatic background checks.
- New `Info.plist` keys:
  - `SUFeedURL` — appcast URL (the GitHub Pages location).
  - `SUPublicEDKey` — base64 EdDSA public key (private half is a CI secret).
  - `SUEnableAutomaticChecks` — `true`.
- **Bundle embedding (primary risk):** `build-app.sh` assembles the `.app` by
  hand. Sparkle ships `Sparkle.framework` plus nested XPC services and
  `Autoupdate` / `Updater.app` that must be copied into `Contents/Frameworks/` and
  **signed inside-out** with the Developer ID identity *before* notarization.
  Extend `build-app.sh` to perform this copy + nested sign, and add a
  `codesign --verify --deep --strict` gate so a broken embed fails the build
  rather than shipping a non-updatable app.

## Component 2 — Secrets & keys (one-time, run locally)

GitHub Actions repository secrets:

| Secret | Purpose |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application cert exported as `.p12`, base64-encoded |
| `P12_PASSWORD` | Password for the `.p12` |
| `KEYCHAIN_PASSWORD` | Ephemeral password for the temporary CI keychain |
| `NOTARY_APPLE_ID` | Apple ID for notarytool (matches `package-dmg.sh`) |
| `NOTARY_TEAM_ID` | Developer Team ID |
| `NOTARY_APP_PASSWORD` | App-specific password for notarization |
| `SPARKLE_PRIVATE_ED_KEY` | EdDSA private key from Sparkle `generate_keys`; used by `sign_update` |

One-time local setup steps (documented in the plan): export the Developer ID
cert, run Sparkle `generate_keys`, place the public key in `Info.plist`, set all
secrets via `gh secret set`.

## Component 3 — CI workflow (`.github/workflows/ci.yml`)

- **Triggers:** `pull_request`, and `push` to `main`.
- **Runner:** `macos-15`; pin and assert Swift 6.2 toolchain.
- **Secret-free** so fork PRs run fully. Steps:
  1. Cache `.build`.
  2. `swift build -c release`.
  3. `swift test`.
  4. SwiftLint + `swift format lint` (adds `.swiftlint.yml` and `.swift-format`).
  5. Signing dry-run: run `build-app.sh` with ad-hoc signing to catch bundle /
     packaging / Sparkle-embed breakage before any tag is cut.

## Component 4 — Release workflow (`.github/workflows/release.yml`)

- **Trigger:** push of a tag matching `v*`.
- **Runner:** `macos-15`.
- Steps:
  1. Import the Developer ID cert into a temporary keychain
     (`apple-actions/import-codesign-certs`).
  2. **Version injection:** `CFBundleShortVersionString` from the tag
     (`v0.2.0` → `0.2.0`); `CFBundleVersion` = `git rev-list --count HEAD`
     (monotonic, so Sparkle compares builds correctly).
  3. `build-app.sh` with the Developer ID identity (now embeds + signs Sparkle).
  4. `package-dmg.sh` — hardened-runtime sign → DMG → notarize → staple.
  5. `sign_update` the DMG to produce the Sparkle `edSignature`.
  6. Generate/update `appcast.xml` with the new release entry.
  7. Create the GitHub Release with the `.dmg` attached.
  8. Publish the updated `appcast.xml` to GitHub Pages.

## Component 5 — Appcast hosting

- `appcast.xml` committed to the repo and served via **GitHub Pages** over HTTPS
  at a stable URL referenced by `SUFeedURL`.
- The release workflow commits the new appcast entry; Pages redeploys
  automatically.
- Custom website domain (the existing `website/`) remains a future option.

---

## Risks & mitigations

- **Sparkle framework embedding in a hand-assembled bundle** (highest risk):
  mitigated by inside-out signing in `build-app.sh` and a
  `codesign --verify --deep --strict` gate, exercised on every PR via the
  signing dry-run.
- **Runner toolchain drift** (`macos-15` Xcode/Swift version changes): pin the
  image and assert the Swift version in CI; fail fast on mismatch.
- **Notarization flakiness / latency:** `notarytool --wait`; surface the
  submission log on failure.
- **Secret exposure on fork PRs:** CI is secret-free; only the tag-triggered
  release workflow (which forks cannot trigger) uses secrets.

## Out of scope

- App Store / TestFlight distribution.
- App sandboxing.
- App Store Connect API-key notarization (documented as a future swap).
- Multi-architecture concerns beyond what `swift build` already produces.
