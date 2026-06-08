import AppKit

/// Exposes a system-wide Services menu item ("Drop Klip"). macOS can't inject
/// items into other apps' right-click menus, but the Services menu is the
/// supported system-wide equivalent — available via right-click → Services and
/// the app menu's Services submenu.
final class KlipServicesProvider: NSObject {
    private let onDrop: () -> Void

    init(onDrop: @escaping () -> Void) {
        self.onDrop = onDrop
        super.init()
    }

    /// Bound to the `NSMessage` declared in Info.plist (`dropKlip`).
    @objc func dropKlip(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        onDrop()
    }
}
