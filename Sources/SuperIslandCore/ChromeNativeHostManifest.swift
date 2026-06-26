import Foundation

public enum ChromeNativeHostManifestError: Error, Equatable {
    case missingExtensionID
    case missingHostPath
}

public struct ChromeNativeHostManifest: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var path: String
    public var type: String
    public var allowedOrigins: [String]

    public init(extensionID: String, hostPath: String) throws {
        try self.init(extensionIDs: [extensionID], hostPath: hostPath)
    }

    /// Authorize multiple extension IDs (e.g. the published store build and a
    /// locally loaded unpacked dev build) so either can connect to the host.
    public init(extensionIDs: [String], hostPath: String) throws {
        let ids =
            extensionIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let path = hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ids.isEmpty else { throw ChromeNativeHostManifestError.missingExtensionID }
        guard !path.isEmpty else { throw ChromeNativeHostManifestError.missingHostPath }

        self.name = "com.superisland.chrome_bridge"
        self.description = "SuperIsland Chrome native messaging bridge"
        self.path = path
        self.type = "stdio"
        self.allowedOrigins = ids.map { "chrome-extension://\($0)/" }
    }

    enum CodingKeys: String, CodingKey {
        case name, description, path, type
        case allowedOrigins = "allowed_origins"
    }
}
