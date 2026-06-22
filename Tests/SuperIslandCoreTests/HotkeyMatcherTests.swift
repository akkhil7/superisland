import Testing
@testable import SuperIslandCore

@Suite("Hotkey matcher")
struct HotkeyMatcherTests {
    @Test("matches exact key and required modifiers")
    func matchesExactKeyAndRequiredModifiers() {
        let matcher = HotkeyMatcher(keyCode: 40, modifiers: 2304)

        #expect(matcher.matches(eventKeyCode: 40, eventModifiers: 2304))
    }

    @Test("ignores non-device modifiers such as caps lock")
    func ignoresNonDeviceModifiers() {
        let matcher = HotkeyMatcher(keyCode: 40, modifiers: 2304)

        #expect(matcher.matches(eventKeyCode: 40, eventModifiers: 2304 | 65536))
    }

    @Test("rejects a different key or modifiers")
    func rejectsDifferentKeyOrModifiers() {
        let matcher = HotkeyMatcher(keyCode: 40, modifiers: 2304)

        #expect(!matcher.matches(eventKeyCode: 0, eventModifiers: 2304))
        #expect(!matcher.matches(eventKeyCode: 40, eventModifiers: 256))
    }
}
