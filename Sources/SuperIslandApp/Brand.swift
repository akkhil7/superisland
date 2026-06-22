import AppKit

/// Loads SuperIsland's bundled brand assets (menu-bar mark, app icon).
///
/// Assets are copied into the .app by `Scripts/build-app.sh`:
///   • `Contents/Resources/AppIcon.icns`              — the app icon
///   • `Contents/Resources/Brand/drop-menubar.png` — menu-bar mascot face
enum Brand {
    private static func brandURL(_ name: String) -> URL? {
        guard
            let url = Bundle.main.resourceURL?
                .appendingPathComponent("Brand/\(name)"),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// The menu-bar mark — the SuperIsland mascot face. It's full-color (not a
    /// template) so the purple/red eyes stay on-brand. Falls back to nil so
    /// callers can use an SF Symbol.
    static var menuBarImage: NSImage? {
        guard let url = brandURL("drop-menubar.png"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = false
        image.size = NSSize(width: 19, height: 19)
        return image
    }

    /// The full-color app icon, for `NSApp.applicationIconImage` and the
    /// Settings/About surfaces (LSUIElement apps don't load it automatically).
    static var appIcon: NSImage? {
        guard
            let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                ?? brandURL("AppIcon.icns")
        else { return nil }
        return NSImage(contentsOf: url)
    }
}
