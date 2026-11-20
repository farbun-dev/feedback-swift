import Foundation
import Security

/// Where the SDK keeps its sign-in token: one per service and app key.
protocol TokenStore: Sendable {
    func read(_ account: String) -> String?
    func write(_ token: String, _ account: String)
    func delete(_ account: String)
}

/// The Keychain, readable only while the device is unlocked and never
/// copied to another device.
struct KeychainTokenStore: TokenStore {
    let service = "dev.farbun.feedback"

    private func query(_ account: String, legacy: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
            // The data protection keychain never asks the person for a
            // password. It needs a signed app; the legacy one is the fallback.
            if !legacy { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    /// Runs `body` against the data protection keychain, then the legacy one
    /// on a Mac where the app lacks the entitlement for the first.
    private func attempt(_ body: (_ legacy: Bool) -> OSStatus) -> OSStatus {
        let status = body(false)
        #if os(macOS)
            if status == errSecMissingEntitlement { return body(true) }
        #endif
        return status
    }

    func read(_ account: String) -> String? {
        var result: CFTypeRef?
        let status = attempt { legacy in
            var query = query(account, legacy: legacy)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ token: String, _ account: String) {
        delete(account)
        _ = attempt { legacy in
            var query = query(account, legacy: legacy)
            query[kSecValueData as String] = Data(token.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil)
        }
    }

    func delete(_ account: String) {
        _ = attempt { legacy in SecItemDelete(query(account, legacy: legacy) as CFDictionary) }
    }
}
