import CoreFoundation
import Foundation
import Security
import SSHBookmarksCore

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case encoding
}

/// 登录密码存放在登录钥匙串（generic password）。没有私钥口令保险库。
/// account 约定：`host.<uuid>.password`。`passphrase` 这个账户不再使用。
struct KeychainService {
    /// 新条目用 bundle id。旧条目在 `com.shellwalker.MenuSSH`，读到后写回新 service。
    var service: String = Bundle.main.bundleIdentifier ?? ProductIdentity.keychainService

    enum SecretKind: String {
        case password
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
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse
            add[kSecAttrLabel as String] = ProductIdentity.keychainLabel
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func get(account: String) throws -> String? {
        let current = try read(service: service, account: account)
        let legacy: String?
        if current == nil, service != ProductIdentity.legacyKeychainService {
            legacy = try read(service: ProductIdentity.legacyKeychainService, account: account)
        } else {
            legacy = nil
        }
        switch KeychainMigration.read(foundInCurrent: current != nil, foundInLegacy: legacy != nil) {
        case .current:
            return current
        case .missing:
            return nil
        case .copyFromLegacy:
            guard let legacy else { return nil }
            // 写回失败就仍返回密码，下次读取再试。不把密码写进日志。
            if (try? set(legacy, account: account)) != nil {
                try? delete(account: account, service: ProductIdentity.legacyKeychainService)
            }
            return legacy
        }
    }

    func delete(account: String) throws {
        try delete(account: account, service: service)
        if service != ProductIdentity.legacyKeychainService {
            try delete(account: account, service: ProductIdentity.legacyKeychainService)
        }
    }

    private func read(service: String, account: String) throws -> String? {
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

    private func delete(account: String, service: String) throws {
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
    }
}
