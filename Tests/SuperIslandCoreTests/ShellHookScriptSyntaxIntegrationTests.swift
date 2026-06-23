import XCTest
@testable import SuperIslandCore

final class ShellHookScriptSyntaxIntegrationTests: XCTestCase {
    func testGeneratedZshScriptPassesShellSyntaxCheck() throws {
        try assertShellAccepts(
            script: ShellHookScriptBuilder.zshScript(port: 2929), shell: "/bin/zsh")
    }

    func testGeneratedBashScriptPassesShellSyntaxCheck() throws {
        try assertShellAccepts(
            script: ShellHookScriptBuilder.bashScript(port: 2929), shell: "/bin/bash")
    }

    private func assertShellAccepts(script: String, shell: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-shell-\(UUID().uuidString)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-n", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let error =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
    }
}
