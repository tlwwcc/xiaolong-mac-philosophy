import Foundation
import Security

protocol CredentialStoring {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

enum CredentialAccount {
    static let currentAPIKey = "translation.current-api-key"

    static func preset(_ name: String) -> String {
        "translation.preset." + Data(name.utf8).base64EncodedString()
    }
}

enum CredentialStoreError: LocalizedError {
    case keychain(operation: String, status: OSStatus)
    case verificationFailed(account: String)

    var errorDescription: String? {
        switch self {
        case .keychain(let operation, let status):
            return "钥匙串\(operation)失败（状态码 \(status)），原配置未清除。"
        case .verificationFailed:
            return "钥匙串写入后校验失败，原配置未清除。"
        }
    }
}

final class KeychainCredentialStore: CredentialStoring {
    static let shared = KeychainCredentialStore()
    static var service: String {
        YoumuFeatureEnvironmentStore.shared.translationKeychainService
    }

    private(set) var lastErrorMessage: String?

    private init() {}

    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(operation: "读取", status: status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.verificationFailed(account: account)
        }
        return value
    }

    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(operation: "更新", status: updateStatus)
        }
        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(operation: "写入", status: addStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(operation: "删除", status: status)
        }
    }

    func record(_ error: Error?) {
        lastErrorMessage = error?.localizedDescription
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// 多项凭据以“写入 → 回读验证 → 成功后再清理 JSON”的顺序迁移。
/// 任一项失败会尽力回滚本次已经改动的钥匙串项，绝不删除旧明文配置。
struct CredentialVault {
    let store: CredentialStoring

    func persist(currentKey: String, presetKeys: [String: String], knownPresetNames: Set<String>) throws {
        var desired: [String: String?] = [
            CredentialAccount.currentAPIKey: currentKey.isEmpty ? nil : currentKey
        ]
        for name in knownPresetNames.union(presetKeys.keys) {
            let value = presetKeys[name]
            desired[CredentialAccount.preset(name)] = (value?.isEmpty == false) ? value : nil
        }

        var originals: [String: String?] = [:]
        var touched: [String] = []
        do {
            for account in desired.keys.sorted() {
                let original = try store.read(account: account)
                originals[account] = original
                // 先登记再变更：即使写入成功但回读校验失败，本项也必须回滚。
                touched.append(account)
                if let value = desired[account] ?? nil {
                    try store.write(value, account: account)
                    guard try store.read(account: account) == value else {
                        throw CredentialStoreError.verificationFailed(account: account)
                    }
                } else {
                    try store.delete(account: account)
                    guard try store.read(account: account) == nil else {
                        throw CredentialStoreError.verificationFailed(account: account)
                    }
                }
            }
        } catch {
            for account in touched.reversed() {
                if let original = originals[account] ?? nil {
                    try? store.write(original, account: account)
                } else {
                    try? store.delete(account: account)
                }
            }
            throw error
        }
    }

    func hydrate(currentKey: inout String, presetKeys: inout [String: String], presetNames: Set<String>) throws {
        currentKey = try store.read(account: CredentialAccount.currentAPIKey) ?? ""
        for name in presetNames {
            if let value = try store.read(account: CredentialAccount.preset(name)), !value.isEmpty {
                presetKeys[name] = value
            }
        }
    }
}
