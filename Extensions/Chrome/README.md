# SuperIsland Chrome Bridge

Development install:

1. Build `SuperIsland.app`.
2. Load this folder as an unpacked extension from `chrome://extensions`.
3. Copy `native-host-manifest.template.json` to:
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.superisland.chrome_bridge.json`
4. Replace `REPLACE_WITH_EXTENSION_ID` with the unpacked extension id.
5. Ensure `path` points to the built `SuperIslandChromeNativeHost` executable.

The extension sends tab and DOM summaries to the native host. The host forwards
them to the running SuperIsland app on `127.0.0.1:2931`.
