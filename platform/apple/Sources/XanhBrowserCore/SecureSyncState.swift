import Foundation
import LocalAuthentication
import Security

public final class XanhSecureSyncState: @unchecked Sendable {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func store(_ data: Data, account: String, userPresence: Bool) throws {
        try delete(account: account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: false,
        ]
        if userPresence {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.userPresence],
                &error
            ) else {
                if let error { throw error.takeRetainedValue() }
                throw XanhSyncContractError.vaultLocked
            }
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let result = SecItemAdd(query as CFDictionary, nil)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }

    public func load(account: String, prompt: String? = nil) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let prompt {
            let context = LAContext()
            context.localizedReason = prompt
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
        return data
    }

    public func delete(account: String) throws {
        let result = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }
}

@MainActor
public final class XanhVaultSession {
    public nonisolated static let timeout: TimeInterval = 5 * 60
    public private(set) var unlockedAt: Date?

    public init() {}

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? XanhSyncContractError.vaultLocked
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
            throw XanhSyncContractError.vaultLocked
        }
        unlockedAt = Date()
    }

    public func touch(now: Date = Date()) -> Bool {
        guard let unlockedAt, now.timeIntervalSince(unlockedAt) < Self.timeout else {
            lock()
            return false
        }
        self.unlockedAt = now
        return true
    }

    public func lock() { unlockedAt = nil }
}

public actor XanhKeychainFirefoxSyncSecretStore: XanhFirefoxSyncSecretStore {
    private let storage: XanhSecureSyncState

    public init(service: String) {
        storage = XanhSecureSyncState(service: service)
    }

    public func read(_ secret: XanhSyncSecret) async throws -> String? {
        guard let data = try storage.load(account: secret.rawValue) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw XanhSyncContractError.invalidConfiguration("Keychain Sync state is not UTF-8")
        }
        return value
    }

    public func write(_ value: String, for secret: XanhSyncSecret) async throws {
        try storage.store(
            Data(value.utf8),
            account: secret.rawValue,
            userPresence: secret == .loginsKey
        )
    }

    public func delete(_ secret: XanhSyncSecret) async throws {
        try storage.delete(account: secret.rawValue)
    }

    public func readLoginsKeyWithUserPresence(reason: String) async throws -> String? {
        if let data = try storage.load(account: XanhSyncSecret.loginsKey.rawValue, prompt: reason) {
            guard let value = String(data: data, encoding: .utf8) else {
                throw XanhSyncContractError.invalidConfiguration("Keychain Logins key is not UTF-8")
            }
            return value
        }

        // A missing item has nothing for Keychain to authenticate. Require
        // device-owner authentication before allowing the first key to be
        // generated and protected with a user-presence access control list.
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            throw evaluationError ?? XanhSyncContractError.vaultLocked
        }
        guard try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        ) else {
            throw XanhSyncContractError.vaultLocked
        }
        return nil
    }
}
