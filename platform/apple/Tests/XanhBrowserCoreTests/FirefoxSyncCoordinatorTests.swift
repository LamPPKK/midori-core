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

    func remoteTabs() throws -> [XanhRemoteTabsDevice] { [] }
    func vaultUnlocked() throws -> Bool { isVaultUnlocked }
    func unlockVault(localLoginsKey: String) throws {
        if failUnlock { throw XanhSyncContractError.vaultLocked }
        isVaultUnlocked = true
    }
    func lockVault() throws { isVaultUnlocked = false }
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
