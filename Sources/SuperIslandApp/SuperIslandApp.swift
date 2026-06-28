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
                .environmentObject(appDelegate.controller.auth)
                .environmentObject(appDelegate.updater)
                .onOpenURL { url in
                    appDelegate.controller.auth.handleCallback(url)
                }
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
                .environmentObject(appDelegate.updater)
                .environmentObject(appDelegate.controller.settings)
                .environmentObject(appDelegate.controller.permissions)
                .environmentObject(appDelegate.controller.shellIntegration)
                .environmentObject(appDelegate.controller.chromeIntegration)
                .environmentObject(appDelegate.controller.claudeIntegration)
                .environmentObject(appDelegate.controller.cursorIntegration)
                .environmentObject(appDelegate.controller.codexIntegration)
                .environmentObject(appDelegate.controller.auth)
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
    private let diagnosticsHotkey = DiagnosticsHotkey()
    private let logsWindow = LogsWindowController()
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
        // The island is part of the app's active surface — only show it while
        // signed in. `onActiveChange` fires on every later sign-in/out.
        controller.onActiveChange = { [weak island] active in
            active ? island?.show() : island?.hide()
        }
        if controller.auth.isSignedIn { island.show() }
        self.island = island

        let bannerHost = AlertBannerHostController(controller: controller)
        bannerHost.show()
        self.bannerHost = bannerHost

        let onboarding = OnboardingWindowController(controller: controller)
        controller.showOnboardingRequested = { [weak onboarding] in onboarding?.show() }
        onboarding.showIfNeeded()

        // Internal diagnostics: ⌃⌥⌘L toggles the hidden "Logs…" affordance and
        // opens the viewer. The menu-bar "Logs…" item routes here too.
        controller.showLogsRequested = { [weak self] in self?.logsWindow.show() }
        diagnosticsHotkey.install { [weak self] in
            guard let self else { return }
            let nowOn = !self.controller.settings.diagnosticsEnabled
            self.controller.settings.diagnosticsEnabled = nowOn
            DiagnosticLogger.shared.log(.app, "diagnostics \(nowOn ? "enabled" : "disabled")")
            if nowOn { self.logsWindow.show() } else { self.logsWindow.close() }
        }
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

        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor)
    {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
            let url = URL(string: s)
        else { return }
        controller.auth.handleCallback(url)
    }
}
