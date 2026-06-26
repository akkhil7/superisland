import Foundation
import CryptoKit

/// Chrome derives an extension's ID from the `"key"` field in its manifest:
/// SHA-256 of the DER public key, first 16 bytes, hex digits transposed into
/// the a–p alphabet. Pinning a key in `manifest.json` therefore pins the ID —
/// even for unpacked extensions — which lets SuperIsland install the native messaging
/// host without asking the user to copy the ID out of chrome://extensions.
public enum ChromeExtensionIdentity {
    /// The base64 public key pinned in `Extensions/Chrome/manifest.json`. This is
    /// the **dev/unpacked** key, so a locally loaded unpacked build always
    /// resolves to `devExtensionID`. The Chrome Web Store rejects a manifest
    /// containing `key`, so the packaging script strips it; the published item
    /// gets `storeExtensionID` (a different ID assigned by Google).
    public static let manifestKey = """
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnWzct1ORf26F7rMWXHE2LG3xnUCg3i4wTkpOhzC0Jj2Z9dQ6HI34HWWxkFayZJ68WfToO8Sal5ZezqYRXEF8YT+wd1Bqgx+2k+K6Vb7PbPIa31VxY4Uc4139i0MUXb0o62izjw46+QTmJaOUuCov0+8HDabHqTipR8TZ1Upu5jqLkesuAdCRGp/gAHn1nxUwbA+lapqe3dvDqxsdDs9WktXo+gZBw0s8T08lwx4a5UabxNl1NdBYl56jTXK1SMLX1bR+beMyUHlwGp4qflwDzuaH7+ZLzMd4Bq0bpkJGTAMIK4IciL421ay4aj9F4lXRE7PhFC0Dn1d7SR51prlPSQIDAQAB
        """

    /// Local unpacked (developer) extension ID — Chrome derives this from
    /// `manifestKey`.
    public static let devExtensionID = "nojmmgbfjaohlfclonopaeaenadfjeji"

    /// Published Chrome Web Store extension ID (assigned by Google).
    public static let storeExtensionID = "jdapljiiabpkggmdjbjjpihnjlaomhdo"

    /// Every ID the native-messaging host authorizes: the published store
    /// extension AND a locally-loaded unpacked dev build can each connect.
    public static let allowedExtensionIDs = [storeExtensionID, devExtensionID]

    /// Canonical ID (the published one) for single-ID call sites.
    public static let extensionID = storeExtensionID

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
