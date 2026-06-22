# CI/CD for SuperIsland (macOS app) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Actions CI/CD that gates every PR and turns a `v*` git tag into a Developer ID–signed, notarized DMG published as a GitHub Release with a Sparkle appcast for in-app auto-updates.

**Architecture:** Approach A — the existing `Scripts/build-app.sh` and `Scripts/package-dmg.sh` remain the single source of truth for build/sign/package; GitHub Actions workflows only prepare the environment (temp keychain, secrets, version injection) and call those scripts. Sparkle is integrated into the app and embedded/signed by `build-app.sh`; the release workflow signs the DMG with Sparkle's EdDSA key and publishes an appcast to GitHub Pages.

**Tech Stack:** Swift 6 toolchain (Swift 5 language mode for the app target), SwiftPM, GitHub Actions (`macos-15` runners), Sparkle 2.x, SwiftLint, `swift format`, `codesign`/`notarytool`/`stapler`, GitHub Pages.

## Global Constraints

- Deployment target: macOS 14.0 (`LSMinimumSystemVersion` 14.0; `platforms: [.macOS(.v14)]`).
- App target `SuperIslandApp` uses Swift 5 language mode (`.swiftLanguageMode(.v5)`) — do not switch it to Swift 6.
- Bundle identifier: `com.superisland.SuperIsland`. Executable name inside the bundle: `SuperIsland`.
- CI (PR) jobs MUST be secret-free so fork PRs run fully; only the tag-triggered release workflow uses secrets.
- Runner image: `macos-15`. Assert the Swift toolchain is 6.x at job start.
- Release versioning: `CFBundleShortVersionString` = tag without leading `v`; `CFBundleVersion` = `git rev-list --count HEAD` (monotonic).
- Distribution requires Developer ID Application signing + Apple notarization + stapling. Sparkle only updates correctly across notarized builds.
- Sparkle pin: `from: "2.6.0"`; the `sign_update` tool version used in CI must match the resolved framework version.

---

## Task 0: One-time manual prerequisites (human-run)

These steps cannot be automated and must be completed before Tasks 2 and 4 can be verified end-to-end. They produce two values consumed later: the **Sparkle EdDSA public key** (Task 2) and the **GitHub Pages appcast URL** (Task 2), plus the repository **secrets** (Task 4). Run them locally with the repo checked out.

**Files:** none (external setup).

**Produces:**
- `SPARKLE_PUBLIC_ED_KEY` — base64 string, goes into `Info.plist` as `SUPublicEDKey` in Task 2.
- `APPCAST_URL` — `https://<OWNER>.github.io/<REPO>/appcast.xml`, goes into `Info.plist` as `SUFeedURL` in Task 2.
- GitHub secrets listed below, consumed by `release.yml` in Task 4.

- [ ] **Step 1: Create the GitHub repo and push**

```bash
cd /Users/akhil/useklip
gh repo create superisland --private --source=. --remote=origin --push
```
Record `<OWNER>` (your GitHub login) and `<REPO>` (`superisland`). The appcast URL is `https://<OWNER>.github.io/<REPO>/appcast.xml`.

- [ ] **Step 2: Export the Developer ID Application certificate as base64**

```bash
# In Keychain Access: right-click your "Developer ID Application: …" identity →
# Export → .p12 (set a password). Save as ~/superisland-dev-id.p12, then:
base64 -i ~/superisland-dev-id.p12 | pbcopy   # this is BUILD_CERTIFICATE_BASE64
```

- [ ] **Step 3: Generate the Sparkle EdDSA key pair**

```bash
# Download Sparkle 2.6.x tools, then:
./bin/generate_keys
# Prints the PUBLIC key (base64) — record as SPARKLE_PUBLIC_ED_KEY.
# Stores the PRIVATE key in your login keychain. Export it for CI:
./bin/generate_keys -x sparkle_private_key.txt   # contents = SPARKLE_PRIVATE_ED_KEY secret
```

- [ ] **Step 4: Set all repository secrets**

```bash
gh secret set BUILD_CERTIFICATE_BASE64 < <(base64 -i ~/superisland-dev-id.p12)
gh secret set P12_PASSWORD                 # the .p12 password from Step 2
gh secret set KEYCHAIN_PASSWORD            # any strong random string
gh secret set NOTARY_APPLE_ID             # your Apple ID email
gh secret set NOTARY_TEAM_ID              # your 10-char Team ID
gh secret set NOTARY_APP_PASSWORD         # app-specific password from appleid.apple.com
gh secret set SPARKLE_PRIVATE_ED_KEY < sparkle_private_key.txt
rm sparkle_private_key.txt                 # do not commit
```

- [ ] **Step 5: Enable GitHub Pages from the `gh-pages` branch**

In the GitHub repo: Settings → Pages → Source = "Deploy from a branch" → Branch `gh-pages` `/ (root)`. (The branch is created by the release workflow in Task 4; set this after the first release run, or pre-create an empty `gh-pages` branch now.)

---

## Task 1: Lint/format config + CI workflow (PR gates)

Delivers the secret-free quality gate: build, test, lint, format, and an ad-hoc signing dry-run on every PR and push to `main`. Independently valuable and verifiable before any app changes.

**Files:**
- Create: `.swiftlint.yml`
- Create: `.swift-format`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: existing `Scripts/build-app.sh` (ad-hoc path, no secrets).
- Produces: a green CI run; no symbols consumed by later tasks.

- [ ] **Step 1: Write the SwiftLint config**

Create `.swiftlint.yml`:

```yaml
included:
  - Sources
  - Tests
excluded:
  - .build
disabled_rules:
  - todo
  - line_length
analyzer_rules: []
```

- [ ] **Step 2: Write the swift-format config**

Create `.swift-format`:

```json
{
  "version": 1,
  "lineLength": 100,
  "indentation": { "spaces": 4 },
  "rules": {}
}
```

- [ ] **Step 3: Verify formatting/lint pass locally on current sources**

Run:
```bash
swift format lint --strict --recursive Sources Tests
swiftlint --version >/dev/null 2>&1 && swiftlint lint --quiet || echo "swiftlint not installed locally — CI installs it"
```
Expected: `swift format lint` exits 0 (fix any reported issues with `swift format --in-place --recursive Sources Tests` and re-run). SwiftLint may be absent locally; that's fine.

- [ ] **Step 4: Write the CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Assert Swift 6 toolchain
        run: |
          swift --version
          swift --version | grep -q "Swift version 6" || { echo "Expected Swift 6.x"; exit 1; }

      - name: Cache SwiftPM build
        uses: actions/cache@v4
        with:
          path: .build
          key: spm-${{ runner.os }}-${{ hashFiles('Package.resolved', 'Package.swift') }}
          restore-keys: spm-${{ runner.os }}-

      - name: Build (release)
        run: swift build -c release

      - name: Test
        run: swift test

      - name: SwiftLint
        run: |
          brew install swiftlint
          swiftlint lint --strict --quiet

      - name: Format check
        run: swift format lint --strict --recursive Sources Tests

      - name: Signing dry-run (ad-hoc, no secrets)
        run: |
          Scripts/build-app.sh release
          codesign --verify --deep --strict --verbose=2 .build/SuperIsland.app
```

- [ ] **Step 5: Commit**

```bash
git add .swiftlint.yml .swift-format .github/workflows/ci.yml
git commit -m "ci: add PR gate (build, test, lint, format, signing dry-run)"
```

---

## Task 2: Sparkle dependency + updater wiring (app code)

Adds Sparkle to the app, a "Check for Updates…" menu item, automatic background checks, and the required `Info.plist` keys. Requires `SPARKLE_PUBLIC_ED_KEY` and `APPCAST_URL` from Task 0.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SuperIslandApp/SoftwareUpdater.swift`
- Modify: `Sources/SuperIslandApp/SuperIslandApp.swift:6-35` (inject updater into `MenuBarContent`)
- Modify: `Sources/SuperIslandApp/Views.swift` (add the menu button to `MenuBarContent`)
- Modify: `Resources/Info.plist`

**Interfaces:**
- Produces: `SoftwareUpdater` — `@MainActor final class SoftwareUpdater: ObservableObject` with `@Published var canCheckForUpdates: Bool` and `func checkForUpdates()`. Consumed by `MenuBarContent` and `SuperIslandApp`.

- [ ] **Step 1: Add the Sparkle dependency to Package.swift**

In `Package.swift`, add the package dependency and link it into `SuperIslandApp`:

```swift
let package = Package(
    name: "SuperIsland",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "SuperIslandCore"),
        .executableTarget(
            name: "SuperIslandApp",
            dependencies: [
                "SuperIslandCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SuperIslandChromeNativeHost",
            dependencies: ["SuperIslandCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SuperIslandCoreTests",
            dependencies: ["SuperIslandCore"]
        ),
    ]
)
```

- [ ] **Step 2: Resolve and verify the dependency builds**

Run:
```bash
swift package resolve
swift build
```
Expected: PASS; `Package.resolved` now pins Sparkle. Note the resolved Sparkle version (e.g. `2.6.4`) — Task 4 must use the matching `sign_update`.

- [ ] **Step 3: Create the SoftwareUpdater wrapper**

Create `Sources/SuperIslandApp/SoftwareUpdater.swift`:

```swift
import Foundation
import Combine
import Sparkle

/// Thin SwiftUI-friendly wrapper around Sparkle's standard updater. Owned by
/// AppDelegate, injected into the menu-bar UI so the "Check for Updates…" item
/// can drive it and reflect availability.
@MainActor
final class SoftwareUpdater: ObservableObject {
    @Published var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
```

- [ ] **Step 4: Own the updater in AppDelegate and inject it**

In `Sources/SuperIslandApp/SuperIslandApp.swift`, add a stored updater to `AppDelegate` and inject it into `MenuBarContent`. Add after line 40 (`let controller = AppController()`):

```swift
    let updater = SoftwareUpdater()
```

And update the `MenuBarExtra` content block (lines 10-16) to inject it:

```swift
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appDelegate.controller)
                .environmentObject(appDelegate.controller.store)
                .environmentObject(appDelegate.controller.permissions)
                .environmentObject(appDelegate.controller.settings)
                .environmentObject(appDelegate.updater)
        } label: {
```

- [ ] **Step 5: Add the "Check for Updates…" button to MenuBarContent**

In `Sources/SuperIslandApp/Views.swift`, inside the `MenuBarContent` view, add the environment object and a button (place it near the existing Quit/Settings controls):

```swift
    @EnvironmentObject private var updater: SoftwareUpdater
```

```swift
    Button("Check for Updates…") { updater.checkForUpdates() }
        .disabled(!updater.canCheckForUpdates)
```

- [ ] **Step 6: Add Sparkle keys to Info.plist**

In `Resources/Info.plist`, add inside the top-level `<dict>` (use the values from Task 0; replace the placeholders):

```xml
    <key>SUFeedURL</key>
    <string>https://<OWNER>.github.io/<REPO>/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
```

- [ ] **Step 7: Build and launch to verify wiring**

Run:
```bash
swift build
Scripts/build-app.sh debug
open .build/SuperIsland.app
```
Expected: app launches; the menu-bar popover shows a "Check for Updates…" item. Clicking it shows Sparkle's "You're up to date" (or a network error against the not-yet-published appcast) — both confirm Sparkle is live. (Full embed/signing correctness is Task 3.)

- [ ] **Step 8: Commit**

```bash
git add Package.swift Package.resolved Sources/SuperIslandApp/SoftwareUpdater.swift \
        Sources/SuperIslandApp/SuperIslandApp.swift Sources/SuperIslandApp/Views.swift \
        Resources/Info.plist
git commit -m "feat: integrate Sparkle auto-update (updater + menu item + Info.plist)"
```

---

## Task 3: Embed and sign Sparkle in build-app.sh

`build-app.sh` assembles the bundle by hand, so it must copy `Sparkle.framework` into `Contents/Frameworks/`, add the loader rpath, and sign the nested components inside-out. A `codesign --verify` gate makes a broken embed fail the build. After this task the Task 1 dry-run exercises the embed on every PR.

**Files:**
- Modify: `Scripts/build-app.sh`

**Interfaces:**
- Consumes: `SUPERISLAND_SIGN_IDENTITY` / discovered `$SIGN_ID` (already in the script).
- Produces: a `.app` with `Contents/Frameworks/Sparkle.framework` embedded and signed; consumed by `package-dmg.sh` (Task 4 release path) and the Task 1 dry-run.

- [ ] **Step 1: Add framework embedding before the signing block**

In `Scripts/build-app.sh`, after the bundle assembly and before the signing section (before the `SIGN_ID=...` block near line 58), insert:

```bash
# --- Embed Sparkle.framework -------------------------------------------------
# SPM builds Sparkle into the bin dir; copy it into the bundle and point the
# executable's loader at Contents/Frameworks so the app finds it at runtime.
SPARKLE_FW="$BIN/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/SuperIsland" 2>/dev/null || true
else
    echo "WARNING: Sparkle.framework not found at $SPARKLE_FW — auto-update will not work"
fi
```

- [ ] **Step 2: Replace the final `codesign --deep` with inside-out signing**

In `Scripts/build-app.sh`, replace the existing single signing line:

```bash
codesign --force --deep --sign "$SIGN_ID" "$APP"
```

with inside-out signing of Sparkle's nested components, then the framework, then the app:

```bash
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    # Sign nested helpers first (paths use Sparkle's current version dir).
    for nested in \
        "$FW/Versions/Current/XPCServices/Installer.xpc" \
        "$FW/Versions/Current/XPCServices/Downloader.xpc" \
        "$FW/Versions/Current/Autoupdate" \
        "$FW/Versions/Current/Updater.app"; do
        [ -e "$nested" ] && codesign --force --options runtime --timestamp \
            --sign "$SIGN_ID" "$nested"
    done
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$FW"
fi
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
```

Note: when `$SIGN_ID` is `-` (ad-hoc, CI dry-run), `--options runtime --timestamp` are ignored gracefully by `codesign`.

- [ ] **Step 3: Add a verification gate after signing**

In `Scripts/build-app.sh`, immediately after the signing block, add:

```bash
codesign --verify --deep --strict --verbose=2 "$APP"
```

- [ ] **Step 4: Build and verify the embed + signature**

Run:
```bash
Scripts/build-app.sh release
test -d .build/SuperIsland.app/Contents/Frameworks/Sparkle.framework && echo "framework embedded"
codesign --verify --deep --strict --verbose=2 .build/SuperIsland.app && echo "signature OK"
otool -l .build/SuperIsland.app/Contents/MacOS/SuperIsland | grep -A2 LC_RPATH | grep -q "Frameworks" && echo "rpath OK"
```
Expected: all three echo lines print. If `Versions/Current` paths don't exist, inspect `ls .build/SuperIsland.app/Contents/Frameworks/Sparkle.framework/Versions/` and adjust the version dir.

- [ ] **Step 5: Commit**

```bash
git add Scripts/build-app.sh
git commit -m "build: embed and inside-out sign Sparkle.framework in the app bundle"
```

---

## Task 4: Release workflow (tag → notarized DMG + appcast)

Tagging `v*` builds with injected version, signs with the real Developer ID, notarizes/staples the DMG (via existing `package-dmg.sh`), signs the DMG with Sparkle's EdDSA key, appends an appcast entry, creates the GitHub Release, and publishes the appcast to GitHub Pages. Requires Task 0 secrets and Tasks 2–3.

**Files:**
- Create: `.github/workflows/release.yml`
- Create: `appcast.xml` (initial empty feed, published to `gh-pages`)
- Create: `Scripts/append-appcast.py`

**Interfaces:**
- Consumes: secrets from Task 0; `Scripts/build-app.sh` (Task 3) and `Scripts/package-dmg.sh`.
- Produces: a GitHub Release with `SuperIsland-<version>.dmg`; an updated `appcast.xml` on `gh-pages`.

- [ ] **Step 1: Create the initial appcast feed**

Create `appcast.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SuperIsland</title>
  </channel>
</rss>
```

- [ ] **Step 2: Create the appcast-append script**

Create `Scripts/append-appcast.py`:

```python
#!/usr/bin/env python3
"""Insert a new Sparkle <item> at the top of the channel in appcast.xml.

Usage: append-appcast.py APPCAST VERSION BUILD URL ED_SIG LENGTH MIN_OS
"""
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

appcast, version, build, url, ed_sig, length, min_os = sys.argv[1:8]
tree = ET.parse(appcast)
channel = tree.getroot().find("channel")

item = ET.Element("item")
ET.SubElement(item, "title").text = version
ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = min_os
enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", url)
enclosure.set("length", length)
enclosure.set("type", "application/octet-stream")
enclosure.set(f"{{{SPARKLE}}}edSignature", ed_sig)

# Newest first.
channel.insert(list(channel).index(channel.find("title")) + 1, item)
tree.write(appcast, xml_declaration=True, encoding="utf-8")
print(f"Inserted appcast item for {version} (build {build})")
```

- [ ] **Step 3: Verify the append script locally**

Run:
```bash
cp appcast.xml /tmp/appcast.xml
python3 Scripts/append-appcast.py /tmp/appcast.xml 0.2.0 42 \
  "https://example.com/SuperIsland-0.2.0.dmg" "FAKESIG==" 12345 14.0
grep -q "0.2.0" /tmp/appcast.xml && grep -q "edSignature" /tmp/appcast.xml && echo "append OK"
```
Expected: prints "append OK".

- [ ] **Step 4: Write the release workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release
on:
  push:
    tags: ["v*"]

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # full history so rev-list build number is correct

      - name: Derive version
        id: ver
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          BUILD="$(git rev-list --count HEAD)"
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          echo "build=$BUILD" >> "$GITHUB_OUTPUT"

      - name: Inject version into Info.plist
        run: |
          /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${{ steps.ver.outputs.version }}" Resources/Info.plist
          /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${{ steps.ver.outputs.build }}" Resources/Info.plist

      - name: Import Developer ID certificate
        uses: apple-actions/import-codesign-certs@v3
        with:
          p12-file-base64: ${{ secrets.BUILD_CERTIFICATE_BASE64 }}
          p12-password: ${{ secrets.P12_PASSWORD }}
          keychain-password: ${{ secrets.KEYCHAIN_PASSWORD }}

      - name: Resolve signing identity
        id: sign
        run: |
          ID="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
          echo "identity=$ID" >> "$GITHUB_OUTPUT"

      - name: Build, package, notarize, staple
        env:
          SUPERISLAND_SIGN_IDENTITY: ${{ steps.sign.outputs.identity }}
          DEVELOPER_ID: ${{ steps.sign.outputs.identity }}
          APPLE_ID: ${{ secrets.NOTARY_APPLE_ID }}
          TEAM_ID: ${{ secrets.NOTARY_TEAM_ID }}
          APPLE_APP_PASSWORD: ${{ secrets.NOTARY_APP_PASSWORD }}
        run: Scripts/package-dmg.sh

      - name: Download Sparkle tools
        run: |
          SP_VER="$(grep -A2 'sparkle-project/Sparkle' Package.resolved | grep version | head -1 | sed -E 's/.*"([0-9.]+)".*/\1/')"
          curl -L -o sparkle.tar.xz "https://github.com/sparkle-project/Sparkle/releases/download/${SP_VER}/Sparkle-${SP_VER}.tar.xz"
          mkdir sparkle-tools && tar -xf sparkle.tar.xz -C sparkle-tools

      - name: Sign DMG with Sparkle EdDSA key
        id: sparkle
        env:
          SPARKLE_PRIVATE_ED_KEY: ${{ secrets.SPARKLE_PRIVATE_ED_KEY }}
        run: |
          DMG=".build/SuperIsland-${{ steps.ver.outputs.version }}.dmg"
          OUT="$(./sparkle-tools/bin/sign_update "$DMG" --ed-key-file <(printf '%s' "$SPARKLE_PRIVATE_ED_KEY"))"
          # OUT looks like: sparkle:edSignature="…" length="12345"
          SIG="$(echo "$OUT" | sed -E 's/.*edSignature="([^"]+)".*/\1/')"
          LEN="$(echo "$OUT" | sed -E 's/.*length="([0-9]+)".*/\1/')"
          echo "sig=$SIG" >> "$GITHUB_OUTPUT"
          echo "len=$LEN" >> "$GITHUB_OUTPUT"

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" \
            ".build/SuperIsland-${{ steps.ver.outputs.version }}.dmg" \
            --title "$GITHUB_REF_NAME" --generate-notes

      - name: Update appcast on gh-pages
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          DMG_URL="https://github.com/${{ github.repository }}/releases/download/${GITHUB_REF_NAME}/SuperIsland-${{ steps.ver.outputs.version }}.dmg"
          git fetch origin gh-pages || true
          if git show-ref --verify --quiet refs/remotes/origin/gh-pages; then
            git worktree add gh-pages origin/gh-pages
          else
            git worktree add --orphan -b gh-pages gh-pages
            cp appcast.xml gh-pages/appcast.xml
          fi
          python3 Scripts/append-appcast.py gh-pages/appcast.xml \
            "${{ steps.ver.outputs.version }}" "${{ steps.ver.outputs.build }}" \
            "$DMG_URL" "${{ steps.sparkle.outputs.sig }}" "${{ steps.sparkle.outputs.len }}" "14.0"
          cd gh-pages
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add appcast.xml
          git commit -m "appcast: SuperIsland ${{ steps.ver.outputs.version }}"
          git push origin gh-pages
```

- [ ] **Step 5: Validate workflow YAML syntax**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); yaml.safe_load(open('.github/workflows/ci.yml')); print('YAML OK')"
```
Expected: prints "YAML OK".

- [ ] **Step 6: Commit**

```bash
git add appcast.xml Scripts/append-appcast.py .github/workflows/release.yml
git commit -m "ci: release workflow — notarized DMG, GitHub Release, Sparkle appcast"
```

- [ ] **Step 7: End-to-end release dry run (human-run, after Task 0 secrets exist)**

```bash
git tag v0.2.0 && git push origin v0.2.0
gh run watch   # observe the Release workflow
```
Expected: workflow succeeds; a `v0.2.0` Release appears with `SuperIsland-0.2.0.dmg`; `gh-pages` has `appcast.xml` containing the new item; installing the DMG and choosing "Check for Updates…" against a lower local version offers the update. If notarization fails, read the submission log surfaced by `notarytool --wait` in `package-dmg.sh`.

---

## Self-Review

**Spec coverage:**
- Sparkle integration (spec §1) → Task 2 (+ embedding in Task 3). ✓
- Secrets & keys (spec §2) → Task 0. ✓
- CI workflow / PR gates incl. build, tests, lint/format, signing dry-run (spec §3) → Task 1. ✓
- Release workflow incl. version injection, sign, notarize, staple, sign_update, appcast, Release, Pages (spec §4) → Task 4 (build/sign reuse from Task 3). ✓
- Appcast hosting on GitHub Pages (spec §5) → Task 0 Step 5 + Task 4 Step 4 (gh-pages). ✓
- Notarization via app-specific password → Task 0/Task 4 env. ✓

**Placeholder scan:** Remaining placeholders are intentional human-supplied values (`<OWNER>`, `<REPO>`, `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`, secret values) produced by Task 0 and consumed in Task 2/4 — each is labeled with its source. No unspecified logic.

**Type consistency:** `SoftwareUpdater` API (`canCheckForUpdates`, `checkForUpdates()`) is defined in Task 2 Step 3 and consumed consistently in Steps 4–5. `SUPERISLAND_SIGN_IDENTITY` / `DEVELOPER_ID` env names match `build-app.sh` and `package-dmg.sh`. Version outputs (`steps.ver.outputs.version`/`build`) are referenced consistently in Task 4.

**Risks carried from spec:** Sparkle `Versions/Current` path and rpath handling (Task 3 Step 4 verifies and tells the implementer how to adjust); runner Swift version asserted (Task 1 Step 4); notarization latency handled by existing `package-dmg.sh --wait`.
