import Foundation
import Testing
@testable import XanhBrowserCore

private func syncConfiguration() throws -> XanhSyncConfiguration {
    try XanhSyncConfiguration(
        server: .mozilla,
        clientID: "approved-client",
        redirectURI: #require(URL(string: "xanh-browser://accounts/oauth")),
        deviceName: "Xanh Browser Apple"
    )
}

@Test func oauthCallbackRequiresExactEndpointAndSingleValues() throws {
    let values = try XanhFirefoxSyncCoordinator.parseOAuthCallback(
        expectedRedirect: #require(URL(string: "xanh-browser://accounts/oauth")),
        callback: #require(URL(string: "xanh-browser://accounts/oauth?code=a%2Bb&state=value"))
    )
    #expect(values.code == "a+b")
    #expect(values.state == "value")

    for value in [
        "xanh-browser://accounts/other?code=a&state=b",
        "xanh-browser://evil/oauth?code=a&state=b",
        "xanh-browser://accounts/oauth?code=a&code=b&state=c",
        "xanh-browser://accounts/oauth?code=a&state=b&token=secret",
        "xanh-browser://accounts/oauth?code=a&state=b#fragment",
        "xanh-browser://user@accounts/oauth?code=a&state=b",
    ] {
        #expect(throws: XanhSyncContractError.self) {
            try XanhFirefoxSyncCoordinator.parseOAuthCallback(
                expectedRedirect: #require(URL(string: "xanh-browser://accounts/oauth")),
                callback: #require(URL(string: value))
            )
        }
    }
}

@Test func coordinatorPersistsStateAndHonorsBackoff() async throws {
    let runtime = FakeSyncRuntime()
    runtime.state = .connected
    runtime.syncResult = XanhNativeSyncResult(
        status: .success,
        nextSyncAllowedEpochSeconds: 1_200
    )
    let secrets = FakeSyncSecrets()
    let coordinator = try makeCoordinator(
        runtime: runtime,
        secrets: secrets,
        now: { Date(timeIntervalSince1970: 1_000) }
    )

    _ = try await coordinator.initialize()
    var snapshot = try await coordinator.sync(reason: .manual)
    #expect(snapshot.status == .success)
    #expect(snapshot.lastSync == Date(timeIntervalSince1970: 1_000))
    #expect(snapshot.nextAllowed == Date(timeIntervalSince1970: 1_200))
    #expect(await secrets.value(.accountState) == "opaque-account")
    #expect(await secrets.value(.syncState) == "opaque-sync")
    #expect(runtime.syncCalls == 1)

    snapshot = try await coordinator.sync(reason: .manual)
    #expect(snapshot.status == .backedOff)
    #expect(runtime.syncCalls == 1)
}

@Test func coordinatorSerializesNativeOperations() async throws {
    let runtime = FakeSyncRuntime()
    runtime.state = .connected
    runtime.syncDelay = 0.05
    let coordinator = try makeCoordinator(runtime: runtime, secrets: FakeSyncSecrets())
    _ = try await coordinator.initialize()

    async let first = coordinator.sync(reason: .manual)
    try await Task.sleep(for: .milliseconds(5))
    do {
        _ = try await coordinator.sync(reason: .manual)
        Issue.record("a concurrent sync should fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .busy)
    }
    _ = try await first

    #expect(runtime.syncCalls == 1)
    #expect(runtime.maximumConcurrentCalls == 1)
}

@Test func oauthStateIsPersistedBeforeTheSystemBrowserOpens() async throws {
    let runtime = FakeSyncRuntime()
    let secrets = FakeSyncSecrets()
    let coordinator = try makeCoordinator(runtime: runtime, secrets: secrets)
    _ = try await coordinator.initialize()
    try await secrets.delete(.accountState)

    let launch = try await coordinator.beginOAuth()

    #expect(launch.accountDomain == "accounts.firefox.com")
    #expect(await secrets.value(.accountState) == "opaque-account")
    #expect(await coordinator.snapshot.accountState == .authenticating)
}

@Test func generatedVaultKeyIsNotStoredWhenNativeUnlockFails() async throws {
    let runtime = FakeSyncRuntime()
    runtime.state = .connected
    runtime.failUnlock = true
    let secrets = FakeSyncSecrets()
    let profile = FileManager.default.temporaryDirectory
        .appending(path: "xanh-apple-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try Data("unreadable".utf8).write(to: profile.appending(path: "logins.sqlite"))
    try Data("rollback".utf8).write(to: profile.appending(path: "logins.sqlite-journal"))
    defer { try? FileManager.default.removeItem(at: profile) }
    let coordinator = try makeCoordinator(
        runtime: runtime,
        secrets: secrets,
        profile: profile
    )
    _ = try await coordinator.initialize()

    do {
        try await coordinator.unlockVault()
        Issue.record("unlock should fail")
    } catch {}

    #expect(await secrets.value(.loginsKey) == nil)
    #expect(!FileManager.default.fileExists(atPath: profile.appending(path: "logins.sqlite").path))
    #expect(!FileManager.default.fileExists(
        atPath: profile.appending(path: "logins.sqlite-journal").path
    ))
    #expect(!runtime.isVaultUnlocked)
}

@Test func disconnectRetryCannotChangeDeleteChoice() async throws {
    let runtime = FakeSyncRuntime()
    runtime.state = .connected
    let secrets = FakeSyncSecrets()
    let coordinator = try makeCoordinator(runtime: runtime, secrets: secrets)
    _ = try await coordinator.initialize()
    await secrets.failNextDelete()

    do {
        try await coordinator.disconnect(deleteLocal: true)
        Issue.record("disconnect should fail on secure-store deletion")
    } catch {}
    do {
        try await coordinator.disconnect(deleteLocal: false)
        Issue.record("retry must not change the delete choice")
    } catch let error as XanhSyncContractError {
        #expect(error == .invalidConfiguration("A disconnect retry must keep the original local-data choice"))
    }
    try await coordinator.disconnect(deleteLocal: true)

    #expect(runtime.disconnectCalls == 1)
    #expect(runtime.lastDisconnectDeletedLocal)
    #expect(await secrets.isEmpty)
}

@Test func credentialQueryRequiresUnlockedVaultAndRejectsUnsafeNativeRecords() async throws {
    let runtime = FakeSyncRuntime()
    runtime.state = .connected
    let coordinator = try makeCoordinator(runtime: runtime, secrets: FakeSyncSecrets())
    _ = try await coordinator.initialize()
    let context = XanhCredentialContext(
        documentURL: try #require(URL(string: "https://example.org/login")),
        topFrameOrigin: try #require(URL(string: "https://example.org")),
        frameOrigin: try #require(URL(string: "https://example.org")),
        isPrivate: false,
        userSelected: true
    )

    do {
        _ = try await coordinator.credentials(for: context)
        Issue.record("a locked vault must reject credential queries")
    } catch let error as XanhSyncContractError {
        #expect(error == .vaultLocked)
    }
    try await coordinator.unlockVault()
    runtime.credentialRecords = [XanhCredentialRecord(
        id: "credential-id",
        origin: "https://example.org",
        formActionOrigin: "https://example.org",
        usernameField: "username",
        passwordField: "password",
        username: "person@example.org",
        password: "secret",
        timeCreatedEpochMillis: 1,
        timePasswordChangedEpochMillis: 1,
        timeLastUsedEpochMillis: 1,
        timesUsed: 1
    )]
    let records = try await coordinator.credentials(for: context)
    #expect(records.count == 1)
    try await coordinator.touchCredential(id: records[0].id, context: context)
    #expect(runtime.touchCredentialCalls == 1)

    runtime.credentialRecords = [XanhCredentialRecord(
        id: "credential-id",
        origin: "https://evil.example",
        formActionOrigin: "https://evil.example",
        usernameField: "username",
        passwordField: "password",
        username: "person@example.org",
        password: "secret",
        timeCreatedEpochMillis: 1,
        timePasswordChangedEpochMillis: 1,
        timeLastUsedEpochMillis: 1,
        timesUsed: 1
    )]
    do {
        _ = try await coordinator.credentials(for: context)
        Issue.record("an unsafe native credential must be rejected")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }
}

@Test func remoteTabsAreTypedSanitizedBoundedAndNeverOpenFallbackURLs() async throws {
    let runtime = FakeSyncRuntime()
    runtime.state = .connected
    runtime.remoteDevices = [XanhRemoteTabsDevice(
        deviceID: "phone-one",
        name: "\u{202E}Phone\nOne",
        kind: .mobile,
        lastModifiedEpochMillis: 2,
        tabs: [XanhRemoteTab(
            id: "phone-one:0",
            title: "Secure\u{202E}\nLogin",
            urlHistory: [try #require(URL(string: "https://example.org/login"))],
            iconURL: URL(string: "https://example.org/icon.png"),
            lastUsedEpochMillis: 1,
            isPinned: true
        )]
    )]
    let coordinator = try makeCoordinator(runtime: runtime, secrets: FakeSyncSecrets())
    _ = try await coordinator.initialize()

    let devices = try await coordinator.remoteTabs()
    #expect(devices.count == 1)
    #expect(devices[0].displayName == "Phone One")
    #expect(devices[0].tabs[0].displayTitle == "Secure Login")
    #expect(devices[0].tabs[0].currentURL?.absoluteString == "https://example.org/login")

    runtime.remoteDevices = [XanhRemoteTabsDevice(
        deviceID: "unsafe",
        name: "Unsafe",
        kind: .desktop,
        lastModifiedEpochMillis: 2,
        tabs: [XanhRemoteTab(
            id: "unsafe:0",
            title: "Unsafe",
            urlHistory: [try #require(URL(string: "https://user:secret@example.org/"))],
            iconURL: nil,
            lastUsedEpochMillis: 1,
            isPinned: false
        )]
    )]
    do {
        _ = try await coordinator.remoteTabs()
        Issue.record("an unsafe remote URL must not open a fallback tab")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }

    runtime.remoteDevices = (0...XanhRemoteTabsPolicy.maximumDevices).map { index in
        XanhRemoteTabsDevice(
            deviceID: "device-\(index)",
            name: "Device \(index)",
            kind: .unknown,
            lastModifiedEpochMillis: 0,
            tabs: []
        )
    }
    do {
        _ = try await coordinator.remoteTabs()
        Issue.record("more than 100 remote devices must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }

    runtime.remoteDevices = [XanhRemoteTabsDevice(
        deviceID: "future",
        name: "Future device",
        kind: .desktop,
        lastModifiedEpochMillis: .max,
        tabs: []
    )]
    do {
        _ = try await coordinator.remoteTabs()
        Issue.record("an out-of-range remote timestamp must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }
}

private func makeCoordinator(
    runtime: FakeSyncRuntime,
    secrets: FakeSyncSecrets,
    now: @escaping @Sendable () -> Date = Date.init,
    profile: URL? = nil
) throws -> XanhFirefoxSyncCoordinator {
    XanhFirefoxSyncCoordinator(
        configuration: try syncConfiguration(),
        profileDirectory: profile ?? FileManager.default.temporaryDirectory
            .appending(path: "xanh-apple-sync-\(UUID().uuidString)", directoryHint: .isDirectory),
        runtimeFactory: FakeSyncRuntimeFactory(runtime: runtime),
        secrets: secrets,
        now: now
    )
}

private struct FakeSyncRuntimeFactory: XanhFirefoxSyncRuntimeFactory {
    let runtime: FakeSyncRuntime

    func open(
        configuration: XanhSyncConfiguration,
        profileDirectory: URL,
        localLoginsKey: String?,
        accountJSON: String?,
        persistedSyncState: String?
    ) throws -> any XanhFirefoxSyncRuntime {
        runtime
    }

    func generateLocalLoginsKey() throws -> String { "generated-device-key" }
}

private final class FakeSyncRuntime: XanhFirefoxSyncRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var activeCalls = 0
    private(set) var maximumConcurrentCalls = 0
    var state = XanhAccountState.disconnected
    var syncResult = XanhNativeSyncResult(status: .success, nextSyncAllowedEpochSeconds: nil)
    var syncDelay: TimeInterval = 0
    var failUnlock = false
    private(set) var syncCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var lastDisconnectDeletedLocal = false
    private(set) var isVaultUnlocked = false
    private(set) var touchCredentialCalls = 0
    var credentialRecords: [XanhCredentialRecord] = []
    var remoteDevices: [XanhRemoteTabsDevice] = []

    func initialize() throws -> XanhAccountState { state }
    func accountState() throws -> XanhAccountState { state }
    func beginOAuth() throws -> URL { URL(string: "https://accounts.firefox.com/oauth")! }
    func completeOAuth(code: String, state: String) throws -> XanhAccountState {
        self.state = .connected
        return .connected
    }
    func accountJSON() throws -> String { "opaque-account" }
    func persistedSyncState() throws -> String? { "opaque-sync" }

    func sync(reason: XanhSyncReason, engines: [XanhSyncEngine]) throws -> XanhNativeSyncResult {
        lock.lock()
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        lock.unlock()
        defer {
            lock.lock()
            activeCalls -= 1
            lock.unlock()
        }
        syncCalls += 1
        if syncDelay > 0 { Thread.sleep(forTimeInterval: syncDelay) }
        return syncResult
    }

    func remoteTabs() throws -> [XanhRemoteTabsDevice] { remoteDevices }
    func vaultUnlocked() throws -> Bool { isVaultUnlocked }
    func unlockVault(localLoginsKey: String) throws {
        if failUnlock { throw XanhSyncContractError.vaultLocked }
        isVaultUnlocked = true
    }
    func lockVault() throws { isVaultUnlocked = false }
    func credentials(context: XanhCredentialContext) throws -> [XanhCredentialRecord] {
        credentialRecords
    }
    func touchCredential(id: String, context: XanhCredentialContext) throws {
        touchCredentialCalls += 1
    }
    func disconnect(deleteLocal: Bool) throws {
        disconnectCalls += 1
        lastDisconnectDeletedLocal = deleteLocal
        isVaultUnlocked = false
        state = .disconnected
    }
}

private actor FakeSyncSecrets: XanhFirefoxSyncSecretStore {
    private var values: [XanhSyncSecret: String] = [:]
    private var deleteFailuresRemaining = 0

    var isEmpty: Bool { values.isEmpty }
    func value(_ secret: XanhSyncSecret) -> String? { values[secret] }
    func failNextDelete() { deleteFailuresRemaining += 1 }
    func read(_ secret: XanhSyncSecret) async throws -> String? { values[secret] }
    func write(_ value: String, for secret: XanhSyncSecret) async throws { values[secret] = value }
    func delete(_ secret: XanhSyncSecret) async throws {
        if deleteFailuresRemaining > 0 {
            deleteFailuresRemaining -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        values.removeValue(forKey: secret)
    }
    func readLoginsKeyWithUserPresence(reason: String) async throws -> String? { values[.loginsKey] }
}
