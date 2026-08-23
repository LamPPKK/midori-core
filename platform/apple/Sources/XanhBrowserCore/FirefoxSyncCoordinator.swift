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

public enum XanhRemoteDeviceKind: String, Codable, Equatable, Sendable {
    case desktop
    case mobile
    case tablet
    case tv
    case vr
    case unknown
}

public struct XanhRemoteTab: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let urlHistory: [URL]
    public let iconURL: URL?
    public let lastUsedEpochMillis: Int64
    public let isPinned: Bool

    public init(
        id: String,
        title: String,
        urlHistory: [URL],
        iconURL: URL?,
        lastUsedEpochMillis: Int64,
        isPinned: Bool
    ) {
        self.id = id
        self.title = title
        self.urlHistory = urlHistory
        self.iconURL = iconURL
        self.lastUsedEpochMillis = lastUsedEpochMillis
        self.isPinned = isPinned
    }

    public var currentURL: URL? { urlHistory.first }

    public var displayTitle: String {
        XanhRemoteTabsPolicy.sanitizedDisplayText(
            title,
            fallback: currentURL?.host ?? "Untitled tab",
            maximumUTF8Bytes: XanhRemoteTabsPolicy.maximumTitleUTF8Bytes
        )
    }

    public var isSafe: Bool {
        guard !id.isEmpty,
              id.utf8.count <= XanhRemoteTabsPolicy.maximumTabIdentifierUTF8Bytes,
              XanhRemoteTabsPolicy.isSafeIdentity(id),
              title.count <= XanhRemoteTabsPolicy.maximumTitleCharacters,
              !urlHistory.isEmpty,
              urlHistory.count <= XanhRemoteTabsPolicy.maximumURLHistoryEntries,
              XanhRemoteTabsPolicy.isValidEpochMillis(lastUsedEpochMillis) else { return false }
        guard urlHistory.allSatisfy({ AddressResolver.isAllowedWebURL($0) }) else { return false }
        return iconURL.map { AddressResolver.isAllowedWebURL($0) } ?? true
    }
}

public struct XanhRemoteTabsDevice: Codable, Equatable, Identifiable, Sendable {
    public let deviceID: String
    public let name: String
    public let kind: XanhRemoteDeviceKind
    public let lastModifiedEpochMillis: Int64
    public let tabs: [XanhRemoteTab]

    public init(
        deviceID: String,
        name: String,
        kind: XanhRemoteDeviceKind,
        lastModifiedEpochMillis: Int64,
        tabs: [XanhRemoteTab]
    ) {
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
        self.lastModifiedEpochMillis = lastModifiedEpochMillis
        self.tabs = tabs
    }

    public var id: String { deviceID }

    public var displayName: String {
        XanhRemoteTabsPolicy.sanitizedDisplayText(
            name,
            fallback: "Firefox device",
            maximumUTF8Bytes: XanhRemoteTabsPolicy.maximumDeviceNameUTF8Bytes
        )
    }

    public var isSafe: Bool {
        guard !deviceID.isEmpty,
              deviceID.utf8.count <= XanhRemoteTabsPolicy.maximumDeviceIdentifierUTF8Bytes,
              XanhRemoteTabsPolicy.isSafeIdentity(deviceID),
              name.count <= XanhRemoteTabsPolicy.maximumDeviceNameCharacters,
              tabs.count <= XanhRemoteTabsPolicy.maximumTabsPerDevice,
              XanhRemoteTabsPolicy.isValidEpochMillis(lastModifiedEpochMillis) else { return false }
        guard tabs.allSatisfy({ $0.isSafe }) else { return false }
        return Set(tabs.map { $0.id }).count == tabs.count
    }
}

public enum XanhRemoteTabsPolicy {
    public static let maximumDevices = 100
    public static let maximumTabsPerDevice = 500
    public static let maximumTotalTabs = 500
    public static let maximumURLHistoryEntries = 10
    public static let maximumPayloadBytes = 8 * 1_024 * 1_024
    public static let maximumDeviceIdentifierUTF8Bytes = 512
    public static let maximumTabIdentifierUTF8Bytes = 1_024
    public static let maximumDeviceNameCharacters = 512
    public static let maximumDeviceNameUTF8Bytes = 2_048
    public static let maximumTitleCharacters = 4_096
    public static let maximumTitleUTF8Bytes = 4_096
    public static let maximumEpochMillis: Int64 = 253_402_300_799_999

    public static func isValidEpochMillis(_ value: Int64) -> Bool {
        (0...maximumEpochMillis).contains(value)
    }

    public static func isSafeIdentity(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                false
            default:
                true
            }
        }
    }

    public static func sanitizedDisplayText(
        _ value: String,
        fallback: String,
        maximumUTF8Bytes: Int
    ) -> String {
        var output: [Unicode.Scalar] = []
        var outputBytes = 0
        var pendingSpace = false

        for scalar in value.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !output.isEmpty
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                continue
            default:
                break
            }
            if pendingSpace {
                guard outputBytes < maximumUTF8Bytes else { break }
                output.append(" ")
                outputBytes += 1
                pendingSpace = false
            }
            let scalarBytes = String(scalar).utf8.count
            guard outputBytes + scalarBytes <= maximumUTF8Bytes else { break }
            output.append(scalar)
            outputBytes += scalarBytes
        }

        let sanitized = String(String.UnicodeScalarView(output))
        return sanitized.isEmpty ? fallback : sanitized
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
    func bookmarkRootGUID(_ root: XanhBookmarkRoot) throws -> String
    func bookmarks(_ root: XanhBookmarkRoot) throws -> [XanhBookmarkRecord]
    func createBookmark(
        parentGUID: String,
        url: URL,
        title: String,
        dateAddedEpochMillis: Int64,
        isPrivate: Bool
    ) throws -> String
    func renameBookmark(guid: String, title: String, isPrivate: Bool) throws
    func deleteBookmark(guid: String, isPrivate: Bool) throws -> Bool
    func recordHistory(
        url: URL,
        title: String,
        visitedAtEpochMillis: Int64,
        transition: XanhHistoryTransition,
        isPrivate: Bool
    ) throws -> XanhHistoryUpdateResult
    func recentHistory(limit: UInt32) throws -> [XanhHistoryVisitRecord]
    func deleteHistoryVisit(url: URL, visitedAtEpochMillis: Int64) throws
    func clearHistory() throws
    func vaultUnlocked() throws -> Bool
    func unlockVault(localLoginsKey: String) throws
    func lockVault() throws
    func credentials(context: XanhCredentialContext) throws -> [XanhCredentialRecord]
    func touchCredential(id: String, context: XanhCredentialContext) throws
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
        let devices = try requireRuntime().remoteTabs()
        guard devices.count <= XanhRemoteTabsPolicy.maximumDevices else {
            throw XanhSyncContractError.bridgeRejected
        }
        let totalTabs = devices.reduce(into: 0) { $0 += $1.tabs.count }
        guard totalTabs <= XanhRemoteTabsPolicy.maximumTotalTabs else {
            throw XanhSyncContractError.bridgeRejected
        }
        guard Set(devices.map { $0.deviceID }).count == devices.count else {
            throw XanhSyncContractError.bridgeRejected
        }
        guard devices.allSatisfy({ $0.isSafe }) else {
            throw XanhSyncContractError.bridgeRejected
        }
        let encodedSize = try? JSONEncoder().encode(devices).count
        guard let encodedSize,
              encodedSize <= XanhRemoteTabsPolicy.maximumPayloadBytes else {
            throw XanhSyncContractError.bridgeRejected
        }
        return devices
    }

    public func bookmarks() throws -> [XanhBookmarkRecord] {
        try startOperation()
        defer { finishOperation() }
        let opened = try requireRuntime()
        var records: [XanhBookmarkRecord] = []
        for root in XanhBookmarkRoot.allCases {
            let rootRecords = try opened.bookmarks(root)
            guard rootRecords.count <= XanhPlacesPolicy.maximumBookmarkRecords,
                  records.count <= XanhPlacesPolicy.maximumBookmarkRecords - rootRecords.count else {
                throw XanhSyncContractError.bridgeRejected
            }
            records.append(contentsOf: rootRecords)
        }
        guard records.allSatisfy({ $0.isSafe }),
              Set(records.map { $0.guid }).count == records.count,
              let payloadBytes = try? JSONEncoder().encode(records).count,
              payloadBytes <= XanhPlacesPolicy.maximumBookmarkPayloadBytes else {
            throw XanhSyncContractError.bridgeRejected
        }
        return records
    }

    @discardableResult
    public func createBookmark(
        url: URL,
        title: String?,
        root: XanhBookmarkRoot = .mobile,
        isPrivate: Bool = false
    ) throws -> String {
        guard !isPrivate,
              XanhPlacesPolicy.isAllowedWebURL(url) else {
            throw XanhSyncContractError.bridgeRejected
        }
        let safeTitle = XanhPlacesPolicy.sanitizeTitle(title, fallback: url.absoluteString)
        let timestamp = try currentEpochMillis()
        try startOperation()
        defer { finishOperation() }
        let opened = try requireRuntime()
        let parentGUID = try opened.bookmarkRootGUID(root)
        guard XanhPlacesPolicy.isGUID(parentGUID) else {
            throw XanhSyncContractError.bridgeRejected
        }
        let guid = try opened.createBookmark(
            parentGUID: parentGUID,
            url: url,
            title: safeTitle,
            dateAddedEpochMillis: timestamp,
            isPrivate: false
        )
        guard XanhPlacesPolicy.isGUID(guid) else {
            throw XanhSyncContractError.bridgeRejected
        }
        schedule.localChange = now()
        return guid
    }

    public func renameBookmark(
        guid: String,
        title: String,
        isPrivate: Bool = false
    ) throws {
        guard !isPrivate,
              XanhPlacesPolicy.isGUID(guid) else {
            throw XanhSyncContractError.bridgeRejected
        }
        let safeTitle = XanhPlacesPolicy.sanitizeTitle(title, fallback: "Untitled")
        try startOperation()
        defer { finishOperation() }
        try requireRuntime().renameBookmark(guid: guid, title: safeTitle, isPrivate: false)
        schedule.localChange = now()
    }

    @discardableResult
    public func deleteBookmark(guid: String, isPrivate: Bool = false) throws -> Bool {
        guard !isPrivate,
              XanhPlacesPolicy.isGUID(guid) else {
            throw XanhSyncContractError.bridgeRejected
        }
        try startOperation()
        defer { finishOperation() }
        let deleted = try requireRuntime().deleteBookmark(guid: guid, isPrivate: false)
        if deleted { schedule.localChange = now() }
        return deleted
    }

    public func recordHistory(
        url: URL,
        title: String?,
        transition: XanhHistoryTransition = .link,
        isPrivate: Bool = false
    ) throws {
        if isPrivate { return }
        guard XanhPlacesPolicy.isAllowedWebURL(url) else {
            throw XanhSyncContractError.bridgeRejected
        }
        let safeTitle = XanhPlacesPolicy.sanitizeTitle(title, fallback: url.absoluteString)
        let timestamp = try currentEpochMillis()
        try startOperation()
        defer { finishOperation() }
        let result = try requireRuntime().recordHistory(
            url: url,
            title: safeTitle,
            visitedAtEpochMillis: timestamp,
            transition: transition,
            isPrivate: false
        )
        guard result.acceptedCount == 1,
              result.skippedPrivateCount == 0 else {
            throw XanhSyncContractError.bridgeRejected
        }
        schedule.localChange = now()
    }

    public func recentHistory(
        limit: UInt32 = UInt32(XanhPlacesPolicy.maximumHistoryResults)
    ) throws -> [XanhHistoryVisitRecord] {
        guard limit > 0,
              limit <= XanhPlacesPolicy.maximumHistoryResults else {
            throw XanhSyncContractError.bridgeRejected
        }
        try startOperation()
        defer { finishOperation() }
        let records = try requireRuntime().recentHistory(limit: limit)
        guard records.count <= Int(limit),
              records.allSatisfy({ $0.isSafe }),
              Set(records.map { $0.id }).count == records.count,
              let payloadBytes = try? JSONEncoder().encode(records).count,
              payloadBytes <= XanhPlacesPolicy.maximumHistoryPayloadBytes else {
            throw XanhSyncContractError.bridgeRejected
        }
        return records
    }

    public func deleteHistoryVisit(
        url: URL,
        visitedAtEpochMillis: Int64,
        isPrivate: Bool = false
    ) throws {
        guard !isPrivate,
              XanhPlacesPolicy.isAllowedWebURL(url),
              XanhPlacesPolicy.isSafeTimestamp(visitedAtEpochMillis, allowZero: false) else {
            throw XanhSyncContractError.bridgeRejected
        }
        try startOperation()
        defer { finishOperation() }
        try requireRuntime().deleteHistoryVisit(
            url: url,
            visitedAtEpochMillis: visitedAtEpochMillis
        )
        schedule.localChange = now()
    }

    public func clearHistory(isPrivate: Bool = false) throws {
        guard !isPrivate else { throw XanhSyncContractError.bridgeRejected }
        try startOperation()
        defer { finishOperation() }
        try requireRuntime().clearHistory()
        schedule.localChange = now()
    }

    public func credentials(
        for context: XanhCredentialContext
    ) throws -> [XanhCredentialRecord] {
        guard context.isAllowed else { throw XanhSyncContractError.bridgeRejected }
        try startOperation()
        defer { finishOperation() }
        let opened = try requireRuntime()
        try requireUsableVault(opened)
        let records = try opened.credentials(context: context)
        let encodedSize = try? JSONEncoder().encode(records).count
        guard records.count <= 100,
              records.allSatisfy({ $0.isAllowed(for: context) }),
              let encodedSize,
              encodedSize <= 4 * 1_024 * 1_024 else {
            throw XanhSyncContractError.bridgeRejected
        }
        vaultLastActivity = now()
        return records
    }

    public func touchCredential(
        id: String,
        context: XanhCredentialContext
    ) throws {
        guard context.isAllowed else { throw XanhSyncContractError.bridgeRejected }
        try startOperation()
        defer { finishOperation() }
        let opened = try requireRuntime()
        try requireUsableVault(opened)
        try opened.touchCredential(id: id, context: context)
        vaultLastActivity = now()
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

    private func currentEpochMillis() throws -> Int64 {
        let value = now().timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value > 0,
              value <= Double(XanhPlacesPolicy.maximumEpochMillis) else {
            throw XanhSyncContractError.bridgeRejected
        }
        return Int64(value.rounded(.down))
    }

    private func requireUsableVault(_ opened: any XanhFirefoxSyncRuntime) throws {
        let currentTime = now()
        guard (try? opened.vaultUnlocked()) == true,
              let vaultLastActivity,
              currentTime.timeIntervalSince(vaultLastActivity) < Self.vaultTimeout else {
            if (try? opened.vaultUnlocked()) == true { try? opened.lockVault() }
            self.vaultLastActivity = nil
            publish(
                accountState: (try? opened.accountState()) ?? snapshot.accountState,
                status: snapshot.status,
                detail: "Password vault locked"
            )
            throw XanhSyncContractError.vaultLocked
        }
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
