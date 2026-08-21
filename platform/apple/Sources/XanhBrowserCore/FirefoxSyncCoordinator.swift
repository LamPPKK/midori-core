import Foundation

public enum XanhSyncSecret: String, CaseIterable, Sendable {
    case accountState = "account-state"
    case syncState = "sync-state"
    case loginsKey = "logins-key"
    case schedule
    case engineSelection = "engine-selection"
    case disconnectIntent = "disconnect-intent"
}

public struct XanhNativeSyncResult: Equatable, Sendable {
    public let status: XanhSyncStatus
    public let nextSyncAllowedEpochSeconds: UInt64?

    public init(status: XanhSyncStatus, nextSyncAllowedEpochSeconds: UInt64?) {
        self.status = status
        self.nextSyncAllowedEpochSeconds = nextSyncAllowedEpochSeconds
    }
}

public struct XanhRemoteTabsDevice: Equatable, Sendable {
    public let name: String
    public let tabCount: Int

    public init(name: String, tabCount: Int) {
        self.name = name
        self.tabCount = tabCount
    }
}

public protocol XanhFirefoxSyncRuntime: AnyObject, Sendable {
    func initialize() throws -> XanhAccountState
    func accountState() throws -> XanhAccountState
    func beginOAuth() throws -> URL
    func completeOAuth(code: String, state: String) throws -> XanhAccountState
    func accountJSON() throws -> String
    func persistedSyncState() throws -> String?
    func sync(reason: XanhSyncReason, engines: [XanhSyncEngine]) throws -> XanhNativeSyncResult
    func remoteTabs() throws -> [XanhRemoteTabsDevice]
    func vaultUnlocked() throws -> Bool
    func unlockVault(localLoginsKey: String) throws
    func lockVault() throws
    func disconnect(deleteLocal: Bool) throws
}

public protocol XanhFirefoxSyncRuntimeFactory: Sendable {
    func open(
        configuration: XanhSyncConfiguration,
        profileDirectory: URL,
        localLoginsKey: String?,
        accountJSON: String?,
        persistedSyncState: String?
    ) throws -> any XanhFirefoxSyncRuntime

    func generateLocalLoginsKey() throws -> String
}

public protocol XanhFirefoxSyncSecretStore: Sendable {
    func read(_ secret: XanhSyncSecret) async throws -> String?
    func write(_ value: String, for secret: XanhSyncSecret) async throws
    func delete(_ secret: XanhSyncSecret) async throws
    func readLoginsKeyWithUserPresence(reason: String) async throws -> String?
}

public struct XanhOAuthLaunch: Equatable, Sendable {
    public let authorizationURL: URL
    public let accountDomain: String
}

public struct XanhSyncHostSnapshot: Equatable, Sendable {
    public let accountState: XanhAccountState
    public let status: XanhSyncStatus
    public let enabledEngines: Set<XanhSyncEngine>
    public let vaultUnlocked: Bool
    public let lastSync: Date?
    public let nextAllowed: Date?
    public let detail: String
}

public actor XanhFirefoxSyncCoordinator {
    private static let vaultTimeout: TimeInterval = 5 * 60
    private let configuration: XanhSyncConfiguration
    private let profileDirectory: URL
    private let runtimeFactory: any XanhFirefoxSyncRuntimeFactory
    private let secrets: any XanhFirefoxSyncSecretStore
    private let now: @Sendable () -> Date
    private var runtime: (any XanhFirefoxSyncRuntime)?
    private var schedule = XanhSyncSchedule()
    private var enabledEngines = Set(XanhSyncEngine.allCases)
    private var pendingDisconnectDeleteLocal: Bool?
    private var nativeDisconnectCompleted = false
    private var vaultLastActivity: Date?
    private var operationRunning = false
    private var vaultLockPending = false

    public private(set) var snapshot = XanhSyncHostSnapshot(
        accountState: .disconnected,
        status: .idle,
        enabledEngines: Set(XanhSyncEngine.allCases),
        vaultUnlocked: false,
        lastSync: nil,
        nextAllowed: nil,
        detail: "Firefox Sync is not initialized"
    )

    public init(
        configuration: XanhSyncConfiguration,
        profileDirectory: URL,
        runtimeFactory: any XanhFirefoxSyncRuntimeFactory,
        secrets: any XanhFirefoxSyncSecretStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.profileDirectory = profileDirectory.standardizedFileURL
        self.runtimeFactory = runtimeFactory
        self.secrets = secrets
        self.now = now
    }

    @discardableResult
    public func initialize() async throws -> XanhSyncHostSnapshot {
        if runtime != nil { return snapshot }
        try startOperation()
        defer { finishOperation() }
        try configuration.validate()
        try FileManager.default.createDirectory(
            at: profileDirectory,
            withIntermediateDirectories: true
        )
        let account = try await secrets.read(.accountState)
        let syncState = try await secrets.read(.syncState)
        restoreSchedule(try await secrets.read(.schedule))
        restoreEngineSelection(try await secrets.read(.engineSelection))
        pendingDisconnectDeleteLocal = try Self.parseDisconnectIntent(
            try await secrets.read(.disconnectIntent)
        )
        let opened = try runtimeFactory.open(
            configuration: configuration,
            profileDirectory: profileDirectory,
            localLoginsKey: nil,
            accountJSON: account,
            persistedSyncState: syncState
        )
        runtime = opened
        do {
            let state = try opened.initialize()
            try await persistRuntimeState()
            publish(accountState: state, status: .idle, detail: "Firefox Sync is ready")
            if let deleteLocal = pendingDisconnectDeleteLocal {
                try await disconnectLocked(deleteLocal: deleteLocal)
            }
            return snapshot
        } catch {
            runtime = nil
            throw error
        }
    }

    public func beginOAuth() async throws -> XanhOAuthLaunch {
        try startOperation()
        defer { finishOperation() }
        let authorizationURL = try requireRuntime().beginOAuth()
        guard authorizationURL.scheme?.lowercased() == "https",
              authorizationURL.host != nil,
              authorizationURL.user == nil,
              authorizationURL.password == nil else {
            throw XanhSyncContractError.invalidConfiguration(
                "Firefox Accounts returned an unsafe authorization URL"
            )
        }
        try await persistRuntimeState()
        publish(
            accountState: .authenticating,
            status: .idle,
            detail: "Waiting for the system browser to complete sign-in"
        )
        return XanhOAuthLaunch(
            authorizationURL: authorizationURL,
            accountDomain: configuration.accountDomain
        )
    }

    @discardableResult
    public func completeOAuth(callback: URL) async throws -> XanhSyncHostSnapshot {
        try startOperation()
        defer { finishOperation() }
        let values = try Self.parseOAuthCallback(
            expectedRedirect: configuration.redirectURI,
            callback: callback
        )
        let state = try requireRuntime().completeOAuth(code: values.code, state: values.state)
        try await persistRuntimeState()
        publish(accountState: state, status: .idle, detail: "Firefox Accounts sign-in completed")
        if state == .connected {
            _ = try await syncLocked(reason: .startup, ignoreInterval: true)
        }
        return snapshot
    }

    @discardableResult
    public func sync(reason: XanhSyncReason) async throws -> XanhSyncHostSnapshot {
        try startOperation()
        defer { finishOperation() }
        return try await syncLocked(reason: reason, ignoreInterval: false)
    }

    public func setEngine(_ engine: XanhSyncEngine, enabled: Bool) async throws {
        try startOperation()
        defer { finishOperation() }
        if enabled { enabledEngines.insert(engine) } else { enabledEngines.remove(engine) }
        let data = try JSONEncoder().encode(enabledEngines.map(\.rawValue).sorted())
        try await secrets.write(String(decoding: data, as: UTF8.self), for: .engineSelection)
        publish(accountState: snapshot.accountState, status: snapshot.status, detail: snapshot.detail)
    }

    public func notifyLocalChange() {
        schedule.localChange = now()
    }

    public func unlockVault() async throws {
        try startOperation()
        defer { finishOperation() }
        let opened = try requireRuntime()
        var key = try await secrets.readLoginsKeyWithUserPresence(
            reason: "Unlock passwords saved in Xanh Browser"
        )
        let generated = key == nil
        if generated {
            try deleteUnreadableLoginsDatabase()
            key = try runtimeFactory.generateLocalLoginsKey()
        }
        guard let key else { throw XanhSyncContractError.vaultLocked }
        do {
            try opened.unlockVault(localLoginsKey: key)
            if generated { try await secrets.write(key, for: .loginsKey) }
        } catch {
            if (try? opened.vaultUnlocked()) == true { try? opened.lockVault() }
            throw error
        }
        vaultLastActivity = now()
        publish(
            accountState: try opened.accountState(),
            status: snapshot.status,
            detail: "Password vault unlocked for five minutes"
        )
        if vaultLockPending { throw XanhSyncContractError.vaultLocked }
    }

    public func lockVault() throws {
        if operationRunning {
            vaultLockPending = true
            vaultLastActivity = nil
            publish(
                accountState: snapshot.accountState,
                status: snapshot.status,
                detail: "Password vault locked"
            )
            return
        }
        let opened = try requireRuntime()
        try opened.lockVault()
        vaultLastActivity = nil
        publish(
            accountState: try opened.accountState(),
            status: snapshot.status,
            detail: "Password vault locked"
        )
    }

    @discardableResult
    public func lockVaultIfIdle() throws -> Bool {
        guard let vaultLastActivity,
              now().timeIntervalSince(vaultLastActivity) >= Self.vaultTimeout else {
            return false
        }
        try lockVault()
        return true
    }

    public func remoteTabs() throws -> [XanhRemoteTabsDevice] {
        try startOperation()
        defer { finishOperation() }
        return try requireRuntime().remoteTabs()
    }

    public func disconnect(deleteLocal: Bool) async throws {
        try startOperation()
        defer { finishOperation() }
        try await disconnectLocked(deleteLocal: deleteLocal)
    }

    public nonisolated static func parseOAuthCallback(
        expectedRedirect: URL,
        callback: URL
    ) throws -> (code: String, state: String) {
        guard expectedRedirect.scheme?.caseInsensitiveCompare(callback.scheme ?? "") == .orderedSame,
              expectedRedirect.host?.caseInsensitiveCompare(callback.host ?? "") == .orderedSame,
              expectedRedirect.port == callback.port,
              expectedRedirect.path == callback.path,
              expectedRedirect.query == nil,
              callback.user == nil,
              callback.password == nil,
              callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.count == 2 else {
            throw XanhSyncContractError.invalidConfiguration(
                "OAuth callback does not match the registered redirect URI"
            )
        }
        var values: [String: String] = [:]
        for item in items {
            guard ["code", "state"].contains(item.name),
                  let value = item.value,
                  !value.isEmpty,
                  values.updateValue(value, forKey: item.name) == nil else {
                throw XanhSyncContractError.invalidConfiguration("OAuth callback query is ambiguous")
            }
        }
        guard values.count == 2, let code = values["code"], let state = values["state"] else {
            throw XanhSyncContractError.invalidConfiguration("OAuth callback is missing code or state")
        }
        return (code, state)
    }

    private func syncLocked(
        reason: XanhSyncReason,
        ignoreInterval: Bool
    ) async throws -> XanhSyncHostSnapshot {
        let opened = try requireRuntime()
        let currentTime = now()
        guard snapshot.accountState == .connected else {
            throw XanhSyncContractError.invalidConfiguration("Firefox Accounts sign-in is required")
        }
        if let nextAllowed = schedule.nextAllowed, currentTime < nextAllowed {
            publish(
                accountState: snapshot.accountState,
                status: .backedOff,
                detail: "Server backoff is active"
            )
            return snapshot
        }
        if !ignoreInterval, !schedule.isDue(reason: reason, now: currentTime) { return snapshot }

        publish(accountState: snapshot.accountState, status: .running, detail: "Firefox Sync is running")
        let result = try opened.sync(
            reason: reason,
            engines: enabledEngines.sorted { $0.rawValue < $1.rawValue }
        )
        schedule.nextAllowed = result.nextSyncAllowedEpochSeconds.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        if result.status == .success || result.status == .partial { schedule.lastSync = currentTime }
        if reason == .localChange { schedule.localChange = nil }
        try await persistRuntimeState()
        let scheduleData = try JSONEncoder().encode(schedule)
        try await secrets.write(String(decoding: scheduleData, as: UTF8.self), for: .schedule)
        publish(
            accountState: try opened.accountState(),
            status: result.status,
            detail: Self.statusDetail(result.status)
        )
        return snapshot
    }

    private func disconnectLocked(deleteLocal: Bool) async throws {
        let opened = try requireRuntime()
        if let pendingDisconnectDeleteLocal, pendingDisconnectDeleteLocal != deleteLocal {
            throw XanhSyncContractError.invalidConfiguration(
                "A disconnect retry must keep the original local-data choice"
            )
        }
        if pendingDisconnectDeleteLocal == nil {
            try await secrets.write(
                deleteLocal ? "delete-local" : "keep-local",
                for: .disconnectIntent
            )
            pendingDisconnectDeleteLocal = deleteLocal
        }
        if !nativeDisconnectCompleted {
            try opened.disconnect(deleteLocal: deleteLocal)
            nativeDisconnectCompleted = true
        }
        let values: [XanhSyncSecret] = deleteLocal
            ? [.accountState, .syncState, .loginsKey, .schedule, .engineSelection]
            : [.accountState, .syncState, .schedule]
        for secret in values { try await secrets.delete(secret) }
        try await secrets.delete(.disconnectIntent)
        schedule = XanhSyncSchedule()
        vaultLastActivity = nil
        pendingDisconnectDeleteLocal = nil
        nativeDisconnectCompleted = false
        publish(
            accountState: .disconnected,
            status: .idle,
            detail: deleteLocal
                ? "Firefox Sync data was removed from this device"
                : "Firefox Sync disconnected; local data was kept"
        )
    }

    private func persistRuntimeState() async throws {
        let opened = try requireRuntime()
        try await secrets.write(try opened.accountJSON(), for: .accountState)
        if let state = try opened.persistedSyncState() {
            try await secrets.write(state, for: .syncState)
        } else {
            try await secrets.delete(.syncState)
        }
    }

    private func publish(accountState: XanhAccountState, status: XanhSyncStatus, detail: String) {
        snapshot = XanhSyncHostSnapshot(
            accountState: accountState,
            status: status,
            enabledEngines: enabledEngines,
            vaultUnlocked: !vaultLockPending && ((try? runtime?.vaultUnlocked()) ?? false),
            lastSync: schedule.lastSync,
            nextAllowed: schedule.nextAllowed,
            detail: detail
        )
    }

    private func requireRuntime() throws -> any XanhFirefoxSyncRuntime {
        guard let runtime else { throw XanhSyncContractError.nativeCoreUnavailable }
        return runtime
    }

    private func startOperation() throws {
        guard !operationRunning else { throw XanhSyncContractError.busy }
        operationRunning = true
    }

    private func finishOperation() {
        operationRunning = false
        guard vaultLockPending, let runtime else { return }
        do {
            try runtime.lockVault()
            vaultLockPending = false
            vaultLastActivity = nil
            publish(
                accountState: (try? runtime.accountState()) ?? snapshot.accountState,
                status: snapshot.status,
                detail: "Password vault locked"
            )
        } catch {
            publish(
                accountState: snapshot.accountState,
                status: snapshot.status,
                detail: "Password vault lock must be retried"
            )
        }
    }

    private func deleteUnreadableLoginsDatabase() throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let url = profileDirectory.appending(path: "logins.sqlite\(suffix)")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func restoreSchedule(_ value: String?) {
        guard let value,
              let data = value.data(using: .utf8),
              let restored = try? JSONDecoder().decode(XanhSyncSchedule.self, from: data) else { return }
        schedule = restored
    }

    private func restoreEngineSelection(_ value: String?) {
        guard let value,
              let data = value.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return }
        let restored = Set(names.compactMap(XanhSyncEngine.init(rawValue:)))
        if restored.count == names.count { enabledEngines = restored }
    }

    private nonisolated static func parseDisconnectIntent(_ value: String?) throws -> Bool? {
        switch value {
        case nil: nil
        case "delete-local": true
        case "keep-local": false
        default:
            throw XanhSyncContractError.invalidConfiguration("Stored disconnect intent is invalid")
        }
    }

    private nonisolated static func statusDetail(_ status: XanhSyncStatus) -> String {
        switch status {
        case .success: "Firefox Sync completed"
        case .partial: "Firefox Sync completed with partial engine failures"
        case .networkError: "Firefox Sync could not reach the server"
        case .authError: "Firefox Accounts needs attention"
        case .backedOff: "Firefox Sync is waiting for server backoff"
        default: "Firefox Sync is idle"
        }
    }
}
