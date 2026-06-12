import Foundation

public struct HotkeyMatcher: Equatable, Sendable {
    private static let deviceModifierMask = 4096 | 2048 | 512 | 256

    public let keyCode: Int
    public let modifiers: Int

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.deviceModifierMask
    }

    public func matches(eventKeyCode: Int, eventModifiers: Int) -> Bool {
        keyCode == eventKeyCode
            && modifiers == (eventModifiers & Self.deviceModifierMask)
    }
}
