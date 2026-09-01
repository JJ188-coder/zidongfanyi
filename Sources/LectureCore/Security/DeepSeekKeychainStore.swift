import Foundation
import Security

public protocol DeepSeekAPIKeyProviding: Sendable {
    func loadAPIKey() throws -> String?
}

public struct DeepSeekKeychainStore: DeepSeekAPIKeyProviding, Sendable {
    public static let defaultService = "com.jiyuanyi.Lecture.DeepSeek"
    private let service: String
    private let account: String

    public init(service: String = Self.defaultService, account: String = "api-key") {
        self.service = service
        self.account = account
    }

    public func saveAPIKey(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 8, value.count <= 8_192, !value.contains(where: \.isWhitespace) else {
            throw KeychainError.invalidKey
        }
        let data = Data(value.utf8)
        let query = baseQuery
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw KeychainError.status(insertStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.status(status)
        }
        return value
    }

    /// Checks only for a matching Keychain item reference. This avoids decrypting
    /// the secret and keeps app launch responsive while the Mac is locked.
    public func hasAPIKeyReference() -> Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

public enum KeychainError: Error, CustomStringConvertible {
    case invalidKey
    case status(OSStatus)
    public var description: String {
        switch self {
        case .invalidKey: return "API Key 格式无效"
        case .status(let status): return "macOS 钥匙串操作失败（\(status)）"
        }
    }
}
