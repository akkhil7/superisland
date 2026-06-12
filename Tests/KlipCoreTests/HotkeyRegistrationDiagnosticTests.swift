import Testing
@testable import KlipCore

@Suite("Hotkey registration diagnostics")
struct HotkeyRegistrationDiagnosticTests {
    @Test("successful registration is shown as ready")
    func successfulRegistrationIsReady() {
        let diagnostic = HotkeyRegistrationDiagnostic(
            keyCode: 40,
            modifiers: 2304,
            installStatus: 0,
            registerStatus: 0
        )

        #expect(diagnostic.isRegistered)
        #expect(diagnostic.summary == "Ready: Option-Command-K")
    }

    @Test("conflicting shortcut explains that another app owns it")
    func conflictingShortcutExplainsOwnership() {
        let diagnostic = HotkeyRegistrationDiagnostic(
            keyCode: 40,
            modifiers: 2304,
            installStatus: 0,
            registerStatus: -9878
        )

        #expect(!diagnostic.isRegistered)
        #expect(diagnostic.summary == "Shortcut unavailable: Option-Command-K is already used by another app.")
    }

    @Test("handler install failure is surfaced")
    func handlerInstallFailureIsSurfaced() {
        let diagnostic = HotkeyRegistrationDiagnostic(
            keyCode: 40,
            modifiers: 2304,
            installStatus: -1,
            registerStatus: nil
        )

        #expect(!diagnostic.isRegistered)
        #expect(diagnostic.summary == "Shortcut unavailable: event handler failed with OSStatus -1.")
    }
}
