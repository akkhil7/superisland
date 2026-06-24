import SwiftUI
import AppKit
import Combine

@main
struct SuperIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appDelegate.controller)
                .environmentObject(appDelegate.controller.store)
                .environmentObject(appDelegate.controller.permissions)
                .environmentObject(appDelegate.controller.settings)
                .environmentObject(appDelegate.updater)
        } label: {
            if let mark = Brand.menuBarImage {
                Image(nsImage: mark)
                    .renderingMode(.original)
            } else {
                Image(systemName: "pin.fill")
            }
        }
        .menuBarExtraStyle(.window)

        SwiftUI.Settings {
            SettingsView()
                .environmentObject(appDelegate.controller)
                .environmentObject(appDelegate.controller.settings)
                .environmentObject(appDelegate.controller.permissions)
                .environmentObject(appDelegate.controller.shellIntegration)
                .environmentObject(appDelegate.controller.chromeIntegration)
                .environmentObject(appDelegate.controller.claudeIntegration)
                .environmentObject(appDelegate.controller.codexIntegration)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    let updater = SoftwareUpdater()
    private var island: NotchIslandController?
    private var bannerHost: AlertBannerHostController?
    private let hotkey = HotkeyManager()
    private var services: SuperIslandServicesProvider?
    private var onboarding: OnboardingWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // LSUIElement apps don't load the bundle icon automatically; set it so
        // Settings, the About panel, and notifications show the SuperIsland mark.
        if let icon = Brand.appIcon { NSApp.applicationIconImage = icon }
        controller.start()

        let island = NotchIslandController(controller: controller)
        island.show()
        self.island = island

        let bannerHost = AlertBannerHostController(controller: controller)
        bannerHost.show()
        self.bannerHost = bannerHost

        let onboarding = OnboardingWindowController(controller: controller)
        controller.showOnboardingRequested = { [weak onboarding] in onboarding?.show() }
        onboarding.showIfNeeded()
        self.onboarding = onboarding

        // Register hotkey using stored key/modifier settings.
        controller.hotkeyDiagnostic = hotkey.register(
            keyCode: UInt32(controller.settings.hotkeyKeyCode),
            modifiers: UInt32(controller.settings.hotkeyModifiers)
        ) { [weak self] in
            self?.controller.createDrop()
        }

        // Re-register whenever the user changes the shortcut in Settings.
        controller.settings.$hotkeyKeyCode
            .combineLatest(controller.settings.$hotkeyModifiers)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] code, mods in
                guard let self else { return }
                self.controller.hotkeyDiagnostic = self.hotkey.update(
                    keyCode: UInt32(code),
                    modifiers: UInt32(mods)
                )
            }
            .store(in: &cancellables)

        let services = SuperIslandServicesProvider { [weak self] in self?.controller.createDrop() }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        self.services = services
    }
}
