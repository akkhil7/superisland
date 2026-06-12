import AppKit
import Carbon.HIToolbox
import KlipCore

/// Registers a single global hotkey to drop a klip from anywhere.
/// Default shortcut is ⌥⌘K; call `update` to re-register after a user change.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onTrigger: (() -> Void)?
    private var lastKeyCode: UInt32 = UInt32(kVK_ANSI_K)
    private var lastModifiers: UInt32 = UInt32(optionKey | cmdKey)
    private var matcher = HotkeyMatcher(keyCode: Int(kVK_ANSI_K), modifiers: Int(optionKey | cmdKey))
    private var lastTriggerAt = Date.distantPast

    private let signature: OSType = {
        let chars = Array("KLIP".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16)
            | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()

    /// Install the event handler and register the initial hotkey.
    func register(
        keyCode: UInt32 = UInt32(kVK_ANSI_K),
        modifiers: UInt32 = UInt32(optionKey | cmdKey),
        handler: @escaping () -> Void
    ) -> HotkeyRegistrationDiagnostic {
        onTrigger = handler
        lastKeyCode = keyCode
        lastModifiers = modifiers
        matcher = HotkeyMatcher(keyCode: Int(keyCode), modifiers: Int(modifiers))

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.trigger()
                _ = event
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )

        let registerStatus = installStatus == noErr
            ? registerKey(keyCode: keyCode, modifiers: modifiers)
            : nil
        installKeyboardMonitors()
        return diagnostic(
            keyCode: keyCode,
            modifiers: modifiers,
            installStatus: installStatus,
            registerStatus: registerStatus
        )
    }

    /// Swap to a new key combination without reinstalling the event handler.
    func update(keyCode: UInt32, modifiers: UInt32) -> HotkeyRegistrationDiagnostic {
        lastKeyCode = keyCode
        lastModifiers = modifiers
        matcher = HotkeyMatcher(keyCode: Int(keyCode), modifiers: Int(modifiers))
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        let registerStatus = registerKey(keyCode: keyCode, modifiers: modifiers)
        return diagnostic(
            keyCode: keyCode,
            modifiers: modifiers,
            installStatus: handlerRef == nil ? -1 : noErr,
            registerStatus: registerStatus
        )
    }

    private func registerKey(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        let id = EventHotKeyID(signature: signature, id: 1)
        return RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    private func installKeyboardMonitors() {
        removeKeyboardMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyboardEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyboardEvent(event)
            return event
        }
    }

    private func removeKeyboardMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handleKeyboardEvent(_ event: NSEvent) {
        let mods = carbonMods(from: event.modifierFlags)
        guard matcher.matches(eventKeyCode: Int(event.keyCode), eventModifiers: mods) else { return }
        trigger()
    }

    private func trigger() {
        let now = Date()
        guard now.timeIntervalSince(lastTriggerAt) > 0.35 else { return }
        lastTriggerAt = now
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?()
        }
    }

    private func carbonMods(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option)  { m |= optionKey }
        if flags.contains(.shift)   { m |= shiftKey }
        if flags.contains(.control) { m |= controlKey }
        return m
    }

    private func diagnostic(
        keyCode: UInt32,
        modifiers: UInt32,
        installStatus: OSStatus,
        registerStatus: OSStatus?
    ) -> HotkeyRegistrationDiagnostic {
        HotkeyRegistrationDiagnostic(
            keyCode: Int(keyCode),
            modifiers: Int(modifiers),
            installStatus: Int32(installStatus),
            registerStatus: registerStatus.map { Int32($0) }
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        removeKeyboardMonitors()
    }
}
