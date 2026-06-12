import SwiftUI
import AppKit
import Combine

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
    private var island: NotchIslandController?
    private let hotkey = HotkeyManager()
    private var services: KlipServicesProvider?
    private var onboarding: OnboardingWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()

        let island = NotchIslandController(controller: controller)
        island.show()
        self.island = island

        let onboarding = OnboardingWindowController(controller: controller)
        controller.showOnboardingRequested = { [weak onboarding] in onboarding?.show() }
        onboarding.showIfNeeded()
        self.onboarding = onboarding

        // Register hotkey using stored key/modifier settings.
        controller.hotkeyDiagnostic = hotkey.register(
            keyCode: UInt32(controller.settings.hotkeyKeyCode),
            modifiers: UInt32(controller.settings.hotkeyModifiers)
        ) { [weak self] in
            self?.controller.dropKlip()
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

        let services = KlipServicesProvider { [weak self] in self?.controller.dropKlip() }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        self.services = services
    }
}
