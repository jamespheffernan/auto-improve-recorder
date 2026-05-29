import Foundation
import Security

enum KeychainStore {
    private static let service = "com.fieldtheory.autoimproverecorder"
    private static let openAIAccount = "openai-api-key"
    private static let geminiAccount = "gemini-api-key"
    private static let anthropicAccount = "anthropic-api-key"

    static func loadOpenAIAPIKey() -> String? {
        loadAPIKey(account: openAIAccount)
    }

    static func saveOpenAIAPIKey(_ key: String) {
        saveAPIKey(key, account: openAIAccount)
    }

    static func loadGeminiAPIKey() -> String? {
        loadAPIKey(account: geminiAccount)
    }

    static func saveGeminiAPIKey(_ key: String) {
        saveAPIKey(key, account: geminiAccount)
    }

    static func loadAnthropicAPIKey() -> String? {
        loadAPIKey(account: anthropicAccount)
    }

    static func saveAnthropicAPIKey(_ key: String) {
        saveAPIKey(key, account: anthropicAccount)
    }

    private static func loadAPIKey(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func saveAPIKey(_ key: String, account: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteAPIKey(account: account)
            return
        }

        let data = Data(trimmed.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func deleteAPIKey(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
