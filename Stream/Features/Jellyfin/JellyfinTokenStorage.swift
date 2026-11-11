import Foundation
import Security

nonisolated protocol JellyfinTokenStorage: Sendable {
    func token(for account: String) -> String?
    func setToken(_ token: String?, for account: String)
}

/// Keeps Jellyfin access tokens in the login Keychain.
nonisolated struct KeychainTokenStorage: JellyfinTokenStorage {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "Stream") + ".jellyfin") {
        self.service = service
    }

    func token(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String?, for account: String) {
        let query = baseQuery(for: account)
        SecItemDelete(query as CFDictionary)

        guard let token else { return }

        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// In-memory storage for tests and previews.
nonisolated final class EphemeralTokenStorage: JellyfinTokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func token(for account: String) -> String? {
        lock.withLock { tokens[account] }
    }

    func setToken(_ token: String?, for account: String) {
        lock.withLock { tokens[account] = token }
    }
}
