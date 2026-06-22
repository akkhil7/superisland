import Foundation
import CryptoKit

/// Chrome derives an extension's ID from the `"key"` field in its manifest:
/// SHA-256 of the DER public key, first 16 bytes, hex digits transposed into
/// the a–p alphabet. Pinning a key in `manifest.json` therefore pins the ID —
/// even for unpacked extensions — which lets SuperIsland install the native messaging
/// host without asking the user to copy the ID out of chrome://extensions.
public enum ChromeExtensionIdentity {
    /// The base64 public key embedded in `Extensions/Chrome/manifest.json`.
    public static let manifestKey = """
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnWzct1ORf26F7rMWXHE2LG3xnUCg3i4wTkpOhzC0Jj2Z9dQ6HI34HWWxkFayZJ68WfToO8Sal5ZezqYRXEF8YT+wd1Bqgx+2k+K6Vb7PbPIa31VxY4Uc4139i0MUXb0o62izjw46+QTmJaOUuCov0+8HDabHqTipR8TZ1Upu5jqLkesuAdCRGp/gAHn1nxUwbA+lapqe3dvDqxsdDs9WktXo+gZBw0s8T08lwx4a5UabxNl1NdBYl56jTXK1SMLX1bR+beMyUHlwGp4qflwDzuaH7+ZLzMd4Bq0bpkJGTAMIK4IciL421ay4aj9F4lXRE7PhFC0Dn1d7SR51prlPSQIDAQAB
    """

    /// The extension ID Chrome assigns for `manifestKey`.
    public static let extensionID = "nojmmgbfjaohlfclonopaeaenadfjeji"

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
