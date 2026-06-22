import Testing
@testable import SuperIslandCore

@Suite("Hotkey shortcut policy")
struct HotkeyShortcutPolicyTests {
    @Test("plain command letter shortcuts reset to the default")
    func plainCommandLetterShortcutsResetToDefault() {
        let shortcut = HotkeyShortcutPolicy.normalized(
            keyCode: 0,
            modifiers: 256,
            defaultKeyCode: 40,
            defaultModifiers: 2304
        )

        #expect(shortcut.keyCode == 40)
        #expect(shortcut.modifiers == 2304)
    }

    @Test("option command letter shortcuts are allowed")
    func optionCommandLetterShortcutsAreAllowed() {
        let shortcut = HotkeyShortcutPolicy.normalized(
            keyCode: 40,
            modifiers: 2304,
            defaultKeyCode: 40,
            defaultModifiers: 2304
        )

        #expect(shortcut.keyCode == 40)
        #expect(shortcut.modifiers == 2304)
    }
}
