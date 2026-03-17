import CryptoKit
import Foundation
import Security

/// Generates and persists an Ed25519 SSH key pair in the Keychain.
class KeyManager {
    static let shared = KeyManager()
    private let keychainAccount = "com.mediabackup.ssh.privatekey"

    /// Returns the existing private key, or generates a new one on first call.
    var privateKey: Curve25519.Signing.PrivateKey {
        if let key = loadFromKeychain() { return key }
        let key = Curve25519.Signing.PrivateKey()
        saveToKeychain(key)
        return key
    }

    /// Public key in OpenSSH format, ready to paste into authorized_keys.
    var publicKeyString: String {
        let pubKeyBytes = privateKey.publicKey.rawRepresentation

        // Wire format: length-prefixed "ssh-ed25519" + length-prefixed key bytes
        var wire = Data()
        wire.appendSSHString("ssh-ed25519".data(using: .utf8)!)
        wire.appendSSHString(pubKeyBytes)

        return "ssh-ed25519 \(wire.base64EncodedString()) media-backup-ios"
    }

    // MARK: - Keychain

    private func loadFromKeychain() -> Curve25519.Signing.PrivateKey? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: keychainAccount,
            kSecReturnData:  true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private func saveToKeychain(_ key: Curve25519.Signing.PrivateKey) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: keychainAccount,
            kSecValueData:   key.rawRepresentation,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}

private extension Data {
    mutating func appendSSHString(_ data: Data) {
        var length = UInt32(data.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { self.append(contentsOf: $0) }
        self.append(data)
    }
}
