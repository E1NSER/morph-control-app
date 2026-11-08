import Foundation
import Security
import MorphCore

/// Lamp credentials never include a Dyson password or a cloud session token.
struct LampCredentials: Codable, Equatable {
    var serial: String
    var accountID: String
    var longTermKey: String
    var name: String

    var isValid: Bool {
        !serial.isEmpty && MorphCrypto.normalizedAccountID(accountID) != nil
            && !longTermKey.isEmpty && Data(hex: longTermKey)?.isEmpty == false
    }
}

@MainActor
protocol CredentialStore {
    func load() throws -> LampCredentials?
    func save(_ credentials: LampCredentials) throws
    func delete() throws
}

@MainActor
final class KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account = "local-lamp"

    init(service: String? = nil) {
        // Keep the independent Developer ID distribution in its own Keychain
        // namespace while preserving existing pairings in earlier channels.
        self.service = service ?? (Bundle.main.bundleIdentifier == "at.einser.morphcontrol.direct"
            ? "at.einser.morphcontrol.direct.lamp"
            : "local.morph.app.lamp")
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> LampCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ServiceError.keychain(status) }
        guard let credentials = try? JSONDecoder().decode(LampCredentials.self, from: data), credentials.isValid else {
            throw ServiceError.invalidCredentials
        }
        return credentials
    }

    func save(_ credentials: LampCredentials) throws {
        guard credentials.isValid else { throw ServiceError.invalidCredentials }
        let data = try JSONEncoder().encode(credentials)
        let changes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ServiceError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ServiceError.keychain(status) }
    }
}

@MainActor
final class MemoryCredentialStore: CredentialStore {
    var credentials: LampCredentials?
    init(_ credentials: LampCredentials? = nil) { self.credentials = credentials }
    func load() throws -> LampCredentials? { credentials }
    func save(_ credentials: LampCredentials) throws { self.credentials = credentials }
    func delete() throws { credentials = nil }
}
