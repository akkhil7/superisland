import Foundation
import SuperIslandCore
import ServiceManagement

/// User preferences, backed by UserDefaults. The Anthropic API key now lives
/// server-side (the hosted classify proxy); classification is gated behind the
/// signed-in user's bearer token rather than a local Keychain entry.
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Capture window screenshots for richer AI context (needs Screen Recording).
    /// Off by default — text-only mode works without that permission.
    @Published var useScreenshots: Bool {
        didSet { defaults.set(useScreenshots, forKey: Keys.useScreenshots) }
    }

    /// Persist encrypted local visual state for generic-app restore guidance.
    @Published var rememberVisualState: Bool {
        didSet { defaults.set(rememberVisualState, forKey: Keys.rememberVisualState) }
    }

    /// Expand the notch island on hover (true) or only on click (false).
    @Published var islandExpandOnHover: Bool {
        didSet { defaults.set(islandExpandOnHover, forKey: Keys.islandExpandOnHover) }
    }

    /// How intrusively SuperIsland announces status changes (counters → colored notch
    /// → explicit banner). See `AlertLevel`.
    @Published var alertLevel: AlertLevel {
        didSet { defaults.set(alertLevel.rawValue, forKey: Keys.alertLevel) }
    }

    /// Allow SuperIsland to read Codex's session journals (rollout files) for live
    /// thread status. No install involved — this is the on/off switch.
    @Published var codexIntegrationEnabled: Bool {
        didSet { defaults.set(codexIntegrationEnabled, forKey: Keys.codexIntegrationEnabled) }
    }

    /// Register SuperIsland as a Login Item.
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }

    /// Minutes after a drop reaches "done" before it is automatically dismissed.
    /// 0 = never.
    @Published var autoDismissMinutes: Int {
        didSet { defaults.set(autoDismissMinutes, forKey: Keys.autoDismiss) }
    }

    /// Carbon virtual key code for the drop-drop hotkey. Default = kVK_ANSI_K (40).
    @Published var hotkeyKeyCode: Int {
        didSet { defaults.set(hotkeyKeyCode, forKey: Keys.hotkeyKeyCode) }
    }

    /// Carbon modifier flags for the drop-drop hotkey. Default = optionKey | cmdKey.
    @Published var hotkeyModifiers: Int {
        didSet { defaults.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers) }
    }

    enum Keys {
        static let useScreenshots = "useScreenshots"
        static let rememberVisualState = "rememberVisualState"
        static let islandExpandOnHover = "islandExpandOnHover"
        static let alertLevel = "alertLevel"
        static let codexIntegrationEnabled = "codexIntegrationEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let autoDismiss = "autoDismissMinutes"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
    }

    static let defaultKeyCode: Int = 40  // kVK_ANSI_K
    static let defaultModifiers: Int = 2304  // optionKey | cmdKey

    init() {
        useScreenshots = defaults.object(forKey: Keys.useScreenshots) as? Bool ?? false
        rememberVisualState = defaults.object(forKey: Keys.rememberVisualState) as? Bool ?? false
        islandExpandOnHover = defaults.object(forKey: Keys.islandExpandOnHover) as? Bool ?? true
        alertLevel =
            (defaults.object(forKey: Keys.alertLevel) as? Int)
            .flatMap(AlertLevel.init(rawValue:)) ?? .coloredNotch
        codexIntegrationEnabled =
            defaults.object(forKey: Keys.codexIntegrationEnabled) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        autoDismissMinutes = defaults.object(forKey: Keys.autoDismiss) as? Int ?? 0
        let storedKeyCode =
            defaults.object(forKey: Keys.hotkeyKeyCode) as? Int ?? Self.defaultKeyCode
        let storedModifiers =
            defaults.object(forKey: Keys.hotkeyModifiers) as? Int ?? Self.defaultModifiers
        let normalizedShortcut = HotkeyShortcutPolicy.normalized(
            keyCode: storedKeyCode,
            modifiers: storedModifiers,
            defaultKeyCode: Self.defaultKeyCode,
            defaultModifiers: Self.defaultModifiers
        )
        hotkeyKeyCode = normalizedShortcut.keyCode
        hotkeyModifiers = normalizedShortcut.modifiers
        defaults.set(hotkeyKeyCode, forKey: Keys.hotkeyKeyCode)
        defaults.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers)
    }

}
