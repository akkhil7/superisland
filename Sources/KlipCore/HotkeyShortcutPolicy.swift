import Foundation

public enum HotkeyShortcutPolicy {
    public struct Shortcut: Equatable, Sendable {
        public let keyCode: Int
        public let modifiers: Int
    }

    public static func normalized(
        keyCode: Int,
        modifiers: Int,
        defaultKeyCode: Int,
        defaultModifiers: Int
    ) -> Shortcut {
        if isUnsafePlainCommandShortcut(keyCode: keyCode, modifiers: modifiers) {
            return Shortcut(keyCode: defaultKeyCode, modifiers: defaultModifiers)
        }
        return Shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private static func isUnsafePlainCommandShortcut(keyCode: Int, modifiers: Int) -> Bool {
        let commandOnly = modifiers == 256
        let letterKeyCodes: Set<Int> = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
            31, 32, 34, 35, 37, 38, 40, 45, 46
        ]
        return commandOnly && letterKeyCodes.contains(keyCode)
    }
}
