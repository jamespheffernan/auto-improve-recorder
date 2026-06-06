import Foundation

protocol SecretsStore: AnyObject {
    func loadCredentials() -> ProviderCredentials
    func saveCredentials(_ credentials: ProviderCredentials)
    func saveCredentialsDebounced(_ credentials: ProviderCredentials)
}

final class KeychainSecretsStore: SecretsStore {
    private let queue = DispatchQueue(label: "com.fieldtheory.air.secrets-store", qos: .utility)
    private let lock = NSLock()
    private var pendingSave: DispatchWorkItem?
    private var pendingSaveID: UUID?

    func loadCredentials() -> ProviderCredentials {
        ProviderCredentials(
            openAIAPIKey: KeychainStore.loadOpenAIAPIKey() ?? "",
            geminiAPIKey: KeychainStore.loadGeminiAPIKey() ?? "",
            anthropicAPIKey: KeychainStore.loadAnthropicAPIKey() ?? ""
        )
    }

    func saveCredentials(_ credentials: ProviderCredentials) {
        lock.lock()
        pendingSave?.cancel()
        pendingSave = nil
        pendingSaveID = nil
        write(credentials)
        lock.unlock()
    }

    func saveCredentialsDebounced(_ credentials: ProviderCredentials) {
        let saveID = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            self?.writePendingCredentials(credentials, id: saveID)
        }

        lock.lock()
        pendingSave?.cancel()
        pendingSave = workItem
        pendingSaveID = saveID
        lock.unlock()

        queue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func writePendingCredentials(_ credentials: ProviderCredentials, id: UUID) {
        lock.lock()
        guard pendingSaveID == id else {
            lock.unlock()
            return
        }
        pendingSave = nil
        pendingSaveID = nil
        write(credentials)
        lock.unlock()
    }

    private func write(_ credentials: ProviderCredentials) {
        KeychainStore.saveOpenAIAPIKey(credentials.openAIAPIKey)
        KeychainStore.saveGeminiAPIKey(credentials.geminiAPIKey)
        KeychainStore.saveAnthropicAPIKey(credentials.anthropicAPIKey)
    }
}
