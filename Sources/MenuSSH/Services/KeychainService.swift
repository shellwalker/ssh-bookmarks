import Foundation
import Security

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case encoding
}

/// 密码与私钥口令存放在登录钥匙串（generic password）。
/// account 约定：`host.<uuid>.password`、`host.<uuid>.passphrase`。
struct KeychainService {
    var service: String = Bundle.main.bundleIdentifier ?? "com.shellwalker.MenuSSH"

    enum SecretKind: String {
        case password
        case passphrase
    }

    static func account(hostID: UUID, kind: SecretKind) -> String {
        "host.\(hostID.uuidString).\(kind.rawValue)"
    }

    func set(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.encoding }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecAttrLabel as String] = "MenuSSH"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 删除站点时调用，清理所有相关密钥。
    func deleteAll(hostID: UUID) {
        try? delete(account: Self.account(hostID: hostID, kind: .password))
        try? delete(account: Self.account(hostID: hostID, kind: .passphrase))
    }
}
