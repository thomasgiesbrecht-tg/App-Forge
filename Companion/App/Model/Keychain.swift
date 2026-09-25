import Foundation
import Security

/// Die Kopplung (Schlüssel zum Mac) liegt im Schlüsselbund.
enum Keychain {
    private static let service = "com.captureworks.AppForge.Companion"
    private static let account = "pairing"

    static func savePairing(_ info: PairingInfo) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        deletePairing()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Auch für Benachrichtigungs-Aktionen bei gesperrtem Gerät lesbar (nach dem ersten Entsperren).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadPairing() -> PairingInfo? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PairingInfo.self, from: data)
    }

    static func deletePairing() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
