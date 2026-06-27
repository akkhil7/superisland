import XCTest
@testable import SuperIslandCore

final class CursorHooksConfiguratorTests: XCTestCase {
    private let path = "/Users/x/.config/superisland/superisland-cursor-hook.sh"

    func testInstallAddsVersionAndAllEvents() {
        let out = CursorHooksConfigurator.install(config: [:], scriptPath: path)
        XCTAssertEqual(out["version"] as? Int, 1)
        let hooks = out["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks)
        for event in CursorHooksConfigurator.events {
            let entries = hooks?[event] as? [[String: Any]]
            XCTAssertEqual(entries?.count, 1, "event \(event)")
            XCTAssertEqual(entries?.first?["command"] as? String, path)
            XCTAssertEqual(entries?.first?["type"] as? String, "command")
        }
    }

    func testIsInstalledTrueAfterInstall() {
        let out = CursorHooksConfigurator.install(config: [:], scriptPath: path)
        XCTAssertTrue(CursorHooksConfigurator.isInstalled(config: out))
    }

    func testIsInstalledFalseOnEmpty() {
        XCTAssertFalse(CursorHooksConfigurator.isInstalled(config: [:]))
    }

    func testInstallPreservesForeignHooksAndIsIdempotent() {
        var config: [String: Any] = [
            "version": 1,
            "hooks": ["stop": [["command": "/usr/local/bin/user-hook.sh", "type": "command"]]],
        ]
        config = CursorHooksConfigurator.install(config: config, scriptPath: path)
        config = CursorHooksConfigurator.install(config: config, scriptPath: path)  // twice
        let stop = (config["hooks"] as? [String: Any])?["stop"] as? [[String: Any]]
        // foreign hook kept + exactly one of ours (no duplicate on re-install)
        XCTAssertEqual(stop?.count, 2)
        XCTAssertTrue(stop?.contains { ($0["command"] as? String) == path } ?? false)
        XCTAssertTrue(
            stop?.contains { ($0["command"] as? String) == "/usr/local/bin/user-hook.sh" } ?? false)
    }

    func testUninstallRemovesOnlyOurEntries() {
        var config: [String: Any] = [
            "version": 1,
            "hooks": ["stop": [["command": "/usr/local/bin/user-hook.sh", "type": "command"]]],
        ]
        config = CursorHooksConfigurator.install(config: config, scriptPath: path)
        config = CursorHooksConfigurator.uninstall(config: config)
        XCTAssertFalse(CursorHooksConfigurator.isInstalled(config: config))
        let stop = (config["hooks"] as? [String: Any])?["stop"] as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1)
        XCTAssertEqual(stop?.first?["command"] as? String, "/usr/local/bin/user-hook.sh")
    }

    func testUninstallDropsHooksKeyWhenEmpty() {
        var config = CursorHooksConfigurator.install(config: [:], scriptPath: path)
        config = CursorHooksConfigurator.uninstall(config: config)
        XCTAssertNil(config["hooks"])  // no foreign hooks remained
    }
}
