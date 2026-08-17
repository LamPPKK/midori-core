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
    public static let timeout: TimeInterval = 5 * 60
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
