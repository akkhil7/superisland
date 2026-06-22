import AppKit

/// Exposes a system-wide Services menu item ("New Drop"). macOS can't inject
/// items into other apps' right-click menus, but the Services menu is the
/// supported system-wide equivalent — available via right-click → Services and
/// the app menu's Services submenu.
final class SuperIslandServicesProvider: NSObject {
    private let onDrop: () -> Void

    init(onDrop: @escaping () -> Void) {
        self.onDrop = onDrop
        super.init()
    }

    /// Bound to the `NSMessage` declared in Info.plist (`createDrop`).
    @objc func createDrop(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        onDrop()
    }
}
