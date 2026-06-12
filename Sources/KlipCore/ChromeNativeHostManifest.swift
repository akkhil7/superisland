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
        let id = extensionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ChromeNativeHostManifestError.missingExtensionID }
        guard !path.isEmpty else { throw ChromeNativeHostManifestError.missingHostPath }

        self.name = "com.useklip.chrome_bridge"
        self.description = "Klip Chrome native messaging bridge"
        self.path = path
        self.type = "stdio"
        self.allowedOrigins = ["chrome-extension://\(id)/"]
    }

    enum CodingKeys: String, CodingKey {
        case name, description, path, type
        case allowedOrigins = "allowed_origins"
    }
}
