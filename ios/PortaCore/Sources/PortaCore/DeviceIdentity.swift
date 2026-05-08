import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Device identity — an Ed25519 keypair. Public key is registered with the
/// backend; private key stays in the Keychain. Authentication is: server
/// issues a nonce, device signs it, server verifies with stored public key.
///
/// On non-Apple platforms (for `swift test` on Linux) we fall back to an
/// in-memory keypair so core tests stay portable.
public final class DeviceIdentity {
    public let publicKey: Data
    public let signer: (Data) -> Data

    public init(publicKey: Data, signer: @escaping (Data) -> Data) {
        self.publicKey = publicKey
        self.signer = signer
    }

    #if canImport(CryptoKit)
    /// Loads (or creates) the keypair from the Keychain under the given tag.
    /// The private key bytes are stored as a generic password item so this
    /// works on macOS too (the `SecKey` path is iOS-secure-enclave-only for
    /// EC P-256, not Ed25519).
    public static func loadOrCreate(keychainTag: String = "app.porta.ios.identity") -> DeviceIdentity {
        if let existing = loadFromKeychain(tag: keychainTag) {
            return existing
        }
        let key = Curve25519.Signing.PrivateKey()
        saveToKeychain(privateKey: key.rawRepresentation, tag: keychainTag)
        return make(from: key)
    }

    private static func make(from key: Curve25519.Signing.PrivateKey) -> DeviceIdentity {
        let pub = key.publicKey.rawRepresentation
        return DeviceIdentity(publicKey: pub) { data in
            (try? key.signature(for: data)) ?? Data()
        }
    }

    private static func loadFromKeychain(tag: String) -> DeviceIdentity? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrAccount as String:  tag,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        return make(from: key)
    }

    private static func saveToKeychain(privateKey: Data, tag: String) {
        let attrs: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrAccount as String:  tag,
            kSecValueData as String:    privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(attrs as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }
    #else
    public static func loadOrCreate(keychainTag: String = "porta") -> DeviceIdentity {
        // Non-Apple fallback: ephemeral keypair for tests only.
        var seed = Data(count: 32)
        _ = seed.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return DeviceIdentity(publicKey: seed) { _ in Data() }
    }
    #endif
}
