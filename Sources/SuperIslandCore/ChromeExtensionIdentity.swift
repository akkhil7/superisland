import Foundation
import CryptoKit

/// Chrome derives an extension's ID from the `"key"` field in its manifest:
/// SHA-256 of the DER public key, first 16 bytes, hex digits transposed into
/// the a–p alphabet. Pinning a key in `manifest.json` therefore pins the ID —
/// even for unpacked extensions — which lets SuperIsland install the native messaging
/// host without asking the user to copy the ID out of chrome://extensions.
public enum ChromeExtensionIdentity {
    /// The base64 public key embedded in `Extensions/Chrome/manifest.json`.
    /// This is the Chrome Web Store item's public key, so the unpacked dev build
    /// and the published extension resolve to the same ID (native messaging works
    /// for both). The Web Store rejects a manifest containing `key`, so the
    /// packaging script strips it from the uploaded zip.
    public static let manifestKey = """
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzN5Wk3I666wgoJeZ0bMMzDkAGr3wLOHAsiOP0/m+eTDH6627ezMLLkaMbq9yisqGjUUT361/nLZZpH8APGtPf8hggaAPPWMwiqh8k1psJhEGAUgG36CWESVqrWuATeMqJLeDzjMApyYp3tG322584KcMuhpdtub/f06+zSMesRzU09kLHNDBVUcvogHr3YLEWlmPtH5W7cOkmWIqE7wuUtFKG0xbBc0H9AnXA2G3v5kvRMQVvlXsnFPkZ5R0xN80DsgKDPBfu07zxyQdrHrqVDkGNzCz0h698IXyKQe75DSJZc1br1XP+nRJDisvy7z7LLO6dLWRFZax68+/kiDnZwIDAQAB
        """

    /// The extension ID Chrome assigns for `manifestKey` (the Web Store item ID).
    public static let extensionID = "jdapljiiabpkggmdjbjjpihnjlaomhdo"

    /// Compute the extension ID for a base64-encoded DER public key.
    public static func extensionID(forBase64Key key: String) -> String? {
        guard let der = Data(base64Encoded: key) else { return nil }
        let digest = SHA256.hash(data: der)
        return digest.prefix(16)
            .flatMap { byte in [byte >> 4, byte & 0xF] }
            .map { String(UnicodeScalar(UInt8(ascii: "a") + $0)) }
            .joined()
    }
}
