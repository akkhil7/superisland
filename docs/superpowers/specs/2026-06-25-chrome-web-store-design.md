# Publishing the SuperIsland Chrome Bridge to the Chrome Web Store

Date: 2026-06-25
Status: Approved design + submission runbook. Prep done in-repo; submission + review are owner steps.

## Problem

Chrome integration doesn't work out of the box: the extension installs as a
developer-style **unpacked** load (`chrome://extensions` → enable Developer Mode →
drag the folder). That's high-friction and Chrome nags about dev-mode extensions
on every launch. The only one-click consumer path is the **Chrome Web Store**.

## Decisions

- **Publish to the Chrome Web Store** (one-click "Add to Chrome", auto-updates).
- **Keep the current permissions** (`<all_urls>` content script + `tabs` /
  `scripting` / `webNavigation` / `nativeMessaging`) and justify them via a
  privacy policy, rather than re-architect status detection. Narrow only if
  Google rejects.
- **One stable extension ID** for both unpacked dev and the published item, so
  the native-messaging host's `allowed_origins` keeps working.

## Extension ID consistency (the one tricky part)

Native messaging binds the app to a fixed ID: the native-host manifest sets
`allowed_origins: ["chrome-extension://<ID>/"]`, generated at runtime from
`ChromeExtensionIdentity.extensionID` (currently the pinned-key ID
`nojmmgbfjaohlfclonopaeaenadfjeji`).

The Web Store **assigns its own ID** and **ignores** the manifest `key`. To make
unpacked dev and the published item share one ID:

1. Create the Web Store item and upload the package (gets an assigned **item ID**).
2. In the Developer Dashboard, copy the item's **public key** (Package → "View
   public key" / shown on the item).
3. Set `manifest.json` `"key"` to that public key, and set
   `ChromeExtensionIdentity.extensionID` to the **item ID**. (Update the test
   `ChromeExtensionIdentityTests` expectation too.)
4. Re-run `Scripts/package-chrome-extension.sh`, re-upload, and submit.

After this, unpacked installs and the store install both resolve to the item ID,
and `ChromeNativeHostManifest` (built from `ChromeExtensionIdentity.extensionID`)
authorizes the right origin.

## Prepared in-repo (done)

- **Icons** — `Extensions/Chrome/icons/icon{16,48,128}.png` (from the AppIcon
  mascot) + `"icons"` added to `manifest.json`. The store requires a 128px icon.
- **Packaging script** — `Scripts/package-chrome-extension.sh` → builds
  `.build/SuperIslandChromeBridge.zip` containing only the runtime files
  (manifest, background.js, content.js, icons). Excludes README + the native-host
  template.
- **Privacy policy** — hosted at
  `https://akkhil7.github.io/superisland/privacy.html` (required because the
  extension reads page content).

## Listing copy (paste into the dashboard)

- **Name:** SuperIsland Chrome Bridge
- **Summary (≤132 chars):** Lets the SuperIsland macOS app track your in-progress
  Chrome tasks and take you back to the exact tab when one needs you.
- **Category:** Productivity
- **Description:**
  > SuperIsland Chrome Bridge connects your Chrome tabs to the SuperIsland macOS
  > app. Drop a marker on a tab where something is running — a build, an AI
  > assistant, a long task — and SuperIsland watches it and pulls you back the
  > moment it finishes or needs your input, then returns you to the exact tab.
  >
  > This extension only works alongside the SuperIsland macOS app, which it talks
  > to locally over Chrome native messaging. See the privacy policy for what it
  > reads and why.
- **Privacy policy URL:** `https://akkhil7.github.io/superisland/privacy.html`
- **Single purpose:** Detect the status of in-progress tasks in Chrome tabs and
  let the SuperIsland desktop app return the user to the relevant tab.

### Permission justifications (Google will ask)

- **`<all_urls>` / host permissions + content script:** Tasks the user tracks can
  run on any website (CI dashboards, AI assistants, web apps), so status
  detection must be able to read the active page's visible text on any site.
- **`tabs`:** Identify and re-focus the exact tab a tracked task lives in.
- **`scripting`:** Read a lightweight summary of the current page to judge task
  status.
- **`webNavigation`:** Detect when a tracked tab navigates so status stays current.
- **`nativeMessaging`:** The only data sink — send tab/page state to the local
  SuperIsland app (no remote server from the extension itself).
- **Remote code:** none. All code is bundled.

## Owner submission runbook

1. Register a Chrome Web Store developer account (one-time $5):
   <https://chrome.google.com/webstore/devconsole>.
2. `./Scripts/package-chrome-extension.sh` → upload
   `.build/SuperIslandChromeBridge.zip` as a **new item**.
3. Fill the listing from the copy above; add the privacy policy URL; upload at
   least one **screenshot** (1280×800 or 640×400 — e.g. the notch island over a
   Chrome tab) and the 128px icon (auto-picked from the package).
4. Do the **ID-consistency** steps above (copy public key → manifest `key` +
   `ChromeExtensionIdentity.extensionID` = item ID → repackage → re-upload).
5. Submit for review. Expect days+ and possible permission follow-ups.

## After it's published (staged client change)

Once the item is live we have a store URL (`https://chromewebstore.google.com/detail/<item-id>`):

- Replace the unpacked-install onboarding ("drag the revealed folder onto
  chrome://extensions") with a single **"Add to Chrome"** button linking to the
  store URL. Touch points: `ChromeIntegration.swift` (`revealExtensionFolder` /
  setup), `Onboarding/OnboardingView.swift` (the Chrome integration row caption),
  and the Settings → Integrations Chrome row.
- Keep the native-host install (the app still installs the native-messaging host
  manifest); only the *extension acquisition* changes from unpacked → store.
- `ChromeExtensionIdentity.extensionID` now equals the store item ID (from step 4).

## Out of scope / external

- Google review time and any permission negotiation.
- The $5 account + actual submission (owner's Google account).
- A demo screenshot/marketing tile beyond one required screenshot (can iterate).
