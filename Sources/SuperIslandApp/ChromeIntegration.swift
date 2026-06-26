import Foundation
import AppKit
import SuperIslandCore

/// One-click Chrome integration. The extension's ID is pinned by the `"key"`
/// field in its manifest (see `ChromeExtensionIdentity`), so no copy/paste of
/// IDs is ever needed: `setUp()` installs the native messaging host for the
/// known ID and opens Chrome at the extensions page; the only step Chrome
/// reserves for the user is dropping the folder onto chrome://extensions.
@MainActor
final class ChromeIntegration: ObservableObject {
    @Published private(set) var isNativeHostInstalled = false
    @Published private(set) var isExtensionLoaded = false
    @Published private(set) var isBridgeConnected = false

    static let extensionID = ChromeExtensionIdentity.extensionID
    /// Both the published store ID and the unpacked dev ID — either can connect.
    static let allowedExtensionIDs = ChromeExtensionIdentity.allowedExtensionIDs

    init() {
        refresh()
    }

    func refresh() {
        isNativeHostInstalled = !installedManifestURLs.isEmpty
        isExtensionLoaded = Self.allowedExtensionIDs.contains { Self.scanChromeProfiles(for: $0) }
        isBridgeConnected = ChromeBridgeStateStore.shared.isConnected
    }

    /// Everything SuperIsland can do without the user: install the native host
    /// manifest for every Chrome-family browser present, then open the
    /// extensions page and reveal the folder to load.
    func setUp() throws {
        try installNativeHost()
        revealExtensionFolder()
        openChromeExtensions()
    }

    func installNativeHost() throws {
        guard let hostPath = hostExecutablePath else {
            throw ChromeIntegrationError.missingHostExecutable
        }
        let manifest = try ChromeNativeHostManifest(
            extensionIDs: Self.allowedExtensionIDs, hostPath: hostPath
        )
        let data = try JSONEncoder.pretty.encode(manifest)

        var wroteAny = false
        for dir in Self.nativeHostDirs
        where FileManager.default.fileExists(
            atPath: dir.deletingLastPathComponent().path
        ) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(Self.manifestFileName), options: .atomic)
            wroteAny = true
        }
        guard wroteAny else { throw ChromeIntegrationError.chromeNotFound }
        refresh()
    }

    func uninstallNativeHost() {
        for url in installedManifestURLs {
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
    }

    var extensionFolderHint: String {
        Bundle.main.resourceURL?
            .appendingPathComponent("ChromeExtension", isDirectory: true)
            .path ?? "Extensions/Chrome"
    }

    func revealExtensionFolder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: extensionFolderHint, isDirectory: true)]
        )
    }

    func openChromeExtensions() {
        // chrome:// URLs can't be opened via NSWorkspace URL routing; ask
        // Chrome itself.
        let script = """
            tell application "Google Chrome"
                activate
                open location "chrome://extensions"
            end tell
            """
        _ = try? AppleScriptRunner.run(script)
    }

    // MARK: - Detection

    /// Look for the extension ID inside each Chrome profile's Preferences.
    /// Unpacked extensions are recorded there (not in the Extensions folder,
    /// which only Web Store installs use), so a plain substring scan is the
    /// cheapest reliable signal.
    static func scanChromeProfiles(for extensionID: String) -> Bool {
        let chromeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome")
        guard
            let profiles = try? FileManager.default.contentsOfDirectory(
                at: chromeDir, includingPropertiesForKeys: nil
            )
        else { return false }

        for profile in profiles {
            for name in ["Secure Preferences", "Preferences"] {
                let url = profile.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                    let text = String(data: data, encoding: .utf8)
                else { continue }
                if text.contains(extensionID) { return true }
            }
        }
        return false
    }

    // MARK: - Paths

    private static let manifestFileName = "com.superisland.chrome_bridge.json"

    /// NativeMessagingHosts dirs for the Chrome-family browsers SuperIsland supports.
    private static var nativeHostDirs: [URL] {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return [
            "Google/Chrome/NativeMessagingHosts",
            "Google/Chrome Canary/NativeMessagingHosts",
            "BraveSoftware/Brave-Browser/NativeMessagingHosts",
        ].map { appSupport.appendingPathComponent($0, isDirectory: true) }
    }

    private var installedManifestURLs: [URL] {
        Self.nativeHostDirs
            .map { $0.appendingPathComponent(Self.manifestFileName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var hostExecutablePath: String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/SuperIslandChromeNativeHost")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled.path }

        let debug = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("SuperIslandChromeNativeHost")
        if FileManager.default.fileExists(atPath: debug.path) { return debug.path }
        return nil
    }
}

enum ChromeIntegrationError: LocalizedError {
    case missingHostExecutable
    case chromeNotFound

    var errorDescription: String? {
        switch self {
        case .missingHostExecutable:
            return "SuperIslandChromeNativeHost is missing from the app bundle."
        case .chromeNotFound:
            return "No Chrome-family browser found on this Mac."
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
