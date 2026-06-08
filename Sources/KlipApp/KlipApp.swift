import SwiftUI
import AppKit

@main
struct KlipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Klip", systemImage: "pin.fill") {
            MenuBarContent()
                .environmentObject(appDelegate.controller)
                .environmentObject(appDelegate.controller.store)
                .environmentObject(appDelegate.controller.permissions)
                .environmentObject(appDelegate.controller.settings)
        }
        .menuBarExtraStyle(.window)

        SwiftUI.Settings {
            SettingsView()
                .environmentObject(appDelegate.controller)
                .environmentObject(appDelegate.controller.settings)
                .environmentObject(appDelegate.controller.permissions)
        }
    }
}

/// Owns app-lifetime objects that aren't part of SwiftUI's scene graph: the
/// controller, the notch island panel, the global hotkey, and the Services
/// provider.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    private var island: NotchIslandController?
    private let hotkey = HotkeyManager()
    private var services: KlipServicesProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        controller.start()

        // Notch island.
        let island = NotchIslandController(controller: controller)
        island.show()
        self.island = island

        // Global hotkey → drop a klip.
        hotkey.register { [weak controller] in controller?.dropKlip() }

        // System Services menu item.
        let services = KlipServicesProvider { [weak controller] in controller?.dropKlip() }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        self.services = services
    }
}
