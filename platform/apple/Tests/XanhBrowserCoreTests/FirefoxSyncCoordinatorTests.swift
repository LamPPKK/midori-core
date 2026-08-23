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
        "xanh-browser://accounts/oauth?code=a%00b&state=c",
    ] {
        #expect(throws: XanhSyncContractError.self) {
            try XanhFirefoxSyncCoordinator.parseOAuthCallback(
                expectedRedirect: #require(URL(string: "xanh-browser://accounts/oauth")),
                callback: #require(URL(string: value))
            )
        }
    }
    let oversized = String(repeating: "a", count: 4_097)
    #expect(throws: XanhSyncContractError.self) {
        try XanhFirefoxSyncCoordinator.parseOAuthCallback(
            expectedRedirect: #require(URL(string: "xanh-browser://accounts/oauth")),
            callback: #require(
                URL(string: "xanh-browser://accounts/oauth?code=\(oversized)&state=value")
            )
        )
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

@Test func oauthFlowIsMemoryBoundAndRequiresTheExactState() async throws {
    let runtime = FakeSyncRuntime()
    let secrets = FakeSyncSecrets()
    let coordinator = try makeCoordinator(runtime: runtime, secrets: secrets)
    _ = try await coordinator.initialize()
    try await secrets.delete(.accountState)

    let launch = try await coordinator.beginOAuth()

    #expect(launch.accountOrigin == "https://accounts.firefox.com")
    #expect(await secrets.value(.accountState) == nil)
    #expect(await coordinator.snapshot.accountState == .authenticating)
    await #expect(throws: XanhSyncContractError.self) {
        try await coordinator.beginOAuth()
    }
    await #expect(throws: XanhSyncContractError.self) {
        try await coordinator.completeOAuth(
            callback: #require(URL(string: "xanh-browser://accounts/oauth?code=code&state=wrong"))
        )
    }
    #expect(runtime.completeOAuthCalls == 0)

    let snapshot = try await coordinator.completeOAuth(
        callback: #require(
            URL(string: "xanh-browser://accounts/oauth?code=code&state=expected-state")
        )
    )
    #expect(snapshot.accountState == .connected)
    #expect(runtime.completeOAuthCalls == 1)
    #expect(await secrets.value(.accountState) == "opaque-account")
}

@Test func oauthCallbackAfterCoordinatorRestartFailsBeforeNativeCompletion() async throws {
    let runtime = FakeSyncRuntime()
    let coordinator = try makeCoordinator(runtime: runtime, secrets: FakeSyncSecrets())
    _ = try await coordinator.initialize()

    await #expect(throws: XanhSyncContractError.self) {
        try await coordinator.completeOAuth(
            callback: #require(
                URL(string: "xanh-browser://accounts/oauth?code=code&state=expected-state")
            )
        )
    }
    #expect(runtime.completeOAuthCalls == 0)
}

@Test func initializationDoesNotRestoreAnAuthenticatingSnapshotWithoutPKCEState() async throws {
    let runtime = FakeSyncRuntime()
    runtime.state = .authenticating
    let secrets = FakeSyncSecrets()
    await secrets.seed("stale-account", for: .accountState)
    await secrets.seed("stale-sync", for: .syncState)
    let coordinator = try makeCoordinator(runtime: runtime, secrets: secrets)

    let snapshot = try await coordinator.initialize()

    #expect(snapshot.accountState == .disconnected)
    #expect(snapshot.detail == "Firefox Accounts sign-in expired; start sign-in again")
    #expect(await secrets.value(.accountState) == nil)
    #expect(await secrets.value(.syncState) == nil)
    #expect(await secrets.deletes() == [.syncState, .accountState])
}

@Test func staleOAuthCleanupIsRetryableWhenTheAccountDeleteFails() async throws {
    let runtime = FakeSyncRuntime()
    runtime.state = .authenticating
    let secrets = FakeSyncSecrets()
    await secrets.seed("stale-account", for: .accountState)
    await secrets.seed("stale-sync", for: .syncState)
    await secrets.failDelete(.accountState)
    let first = try makeCoordinator(runtime: runtime, secrets: secrets)

    await #expect(throws: CocoaError.self) { try await first.initialize() }
    #expect(await secrets.value(.syncState) == nil)
    #expect(await secrets.value(.accountState) == "stale-account")

    let retry = try makeCoordinator(runtime: runtime, secrets: secrets)
    let snapshot = try await retry.initialize()
    #expect(snapshot.accountState == .disconnected)
    #expect(await secrets.value(.accountState) == nil)
}

@Test func oauthAuthorizationRequiresTheConfiguredHostAndPort() async throws {
    let configuration = try XanhSyncConfiguration(
        server: .selfHosted(
            accountsURL: #require(URL(string: "https://accounts.example.test:8443")),
            tokenServerURL: #require(URL(string: "https://sync.example.test/token"))
        ),
        clientID: "approved-client",
        redirectURI: #require(URL(string: "xanh-browser://accounts/oauth")),
        deviceName: "Xanh Browser Apple"
    )
    let acceptedRuntime = FakeSyncRuntime()
    acceptedRuntime.authorizationURL = try #require(
        URL(string: "https://accounts.example.test:8443/oauth?state=expected-state")
    )
    let accepted = try makeCoordinator(
        runtime: acceptedRuntime,
        secrets: FakeSyncSecrets(),
        configuration: configuration
    )
    _ = try await accepted.initialize()
    let launch = try await accepted.beginOAuth()
    #expect(launch.accountOrigin == "https://accounts.example.test:8443")

    for value in [
        "https://evil.example.test:8443/oauth?state=expected-state",
        "https://accounts.example.test:443/oauth?state=expected-state",
    ] {
        let runtime = FakeSyncRuntime()
        runtime.authorizationURL = try #require(URL(string: value))
        let coordinator = try makeCoordinator(
            runtime: runtime,
            secrets: FakeSyncSecrets(),
            configuration: configuration
        )
        _ = try await coordinator.initialize()
        await #expect(throws: XanhSyncContractError.self) {
            try await coordinator.beginOAuth()
        }
    }
}

@Test func oauthCallbackWaitsForAnInFlightCoordinatorOperation() async throws {
    let runtime = FakeSyncRuntime()
    let secrets = FakeSyncSecrets()
    let coordinator = try makeCoordinator(runtime: runtime, secrets: secrets)
    _ = try await coordinator.initialize()
    _ = try await coordinator.beginOAuth()
    await secrets.delayWrites(milliseconds: 100)

    async let update: Void = coordinator.setEngine(.tabs, enabled: false)
    try await Task.sleep(for: .milliseconds(10))
    let snapshot = try await coordinator.completeOAuth(
        callback: #require(
            URL(string: "xanh-browser://accounts/oauth?code=code&state=expected-state")
        )
    )
    try await update

    #expect(snapshot.accountState == .connected)
    #expect(runtime.completeOAuthCalls == 1)
}

@MainActor
@Test func processServiceCoalescesInitializationAndSharesOAuthStateAcrossScenes() async throws {
    let runtime = FakeSyncRuntime()
    let factory = CountingSyncRuntimeFactory(runtime: runtime)
    let secrets = FakeSyncSecrets()
    let configuration = try syncConfiguration()
    let profile = FileManager.default.temporaryDirectory
        .appending(path: "xanh-process-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
    let service = XanhFirefoxSyncProcessService()

    async let first = service.initialize(
        configuration: configuration,
        profileDirectory: profile,
        runtimeFactory: factory,
        secrets: secrets
    )
    async let second = service.initialize(
        configuration: configuration,
        profileDirectory: profile,
        runtimeFactory: factory,
        secrets: secrets
    )
    let (firstResult, secondResult) = try await (first, second)
    #expect(firstResult.0 === secondResult.0)
    #expect(factory.openCalls == 1)

    _ = try await firstResult.0.beginOAuth()
    service.updateSnapshot(await firstResult.0.snapshot)
    let callback = try #require(
        URL(string: "xanh-browser://accounts/oauth?code=code&state=expected-state")
    )
    async let firstCallback = service.completeOAuth(callback: callback)
    async let duplicateSceneCallback = service.completeOAuth(callback: callback)
    let callbackResults = try await (firstCallback, duplicateSceneCallback)

    #expect(service.snapshot.accountState == .connected)
    #expect(callbackResults.0.accountState == .connected)
    #expect(callbackResults.1.accountState == .connected)
    #expect(runtime.completeOAuthCalls == 1)
}

@MainActor
@Test func processServicePublishesFailedOAuthCompletionToEveryScene() async throws {
    let runtime = FakeSyncRuntime()
    runtime.completeOAuthError = CocoaError(.fileReadUnknown)
    let service = XanhFirefoxSyncProcessService()
    let result = try await service.initialize(
        configuration: syncConfiguration(),
        profileDirectory: FileManager.default.temporaryDirectory.appending(
            path: "xanh-process-sync-\(UUID().uuidString)",
            directoryHint: .isDirectory
        ),
        runtimeFactory: FakeSyncRuntimeFactory(runtime: runtime),
        secrets: FakeSyncSecrets()
    )
    _ = try await result.0.beginOAuth()
    service.updateSnapshot(await result.0.snapshot)
    let callback = try #require(
        URL(string: "xanh-browser://accounts/oauth?code=code&state=expected-state")
    )

    await #expect(throws: CocoaError.self) {
        try await service.completeOAuth(callback: callback)
    }
    #expect(service.snapshot.accountState == .disconnected)
    #expect(service.snapshot.status == .authError)
    await #expect(throws: XanhSyncContractError.self) {
        try await service.completeOAuth(callback: callback)
    }
    #expect(runtime.completeOAuthCalls == 1)
}

@MainActor
@Test func wrongQueuedSceneCallbackCannotBlockTheExactCallback() async throws {
    let runtime = FakeSyncRuntime()
    let secrets = FakeSyncSecrets()
    let service = XanhFirefoxSyncProcessService()
    let result = try await service.initialize(
        configuration: syncConfiguration(),
        profileDirectory: FileManager.default.temporaryDirectory.appending(
            path: "xanh-process-sync-\(UUID().uuidString)",
            directoryHint: .isDirectory
        ),
        runtimeFactory: FakeSyncRuntimeFactory(runtime: runtime),
        secrets: secrets
    )
    _ = try await result.0.beginOAuth()
    service.updateSnapshot(await result.0.snapshot)
    await secrets.delayWrites(milliseconds: 100)
    async let update: Void = result.0.setEngine(.tabs, enabled: false)
    try await Task.sleep(for: .milliseconds(10))

    let wrong = Task {
        try await service.completeOAuth(
            callback: #require(
                URL(string: "xanh-browser://accounts/oauth?code=code&state=wrong")
            )
        )
    }
    try await Task.sleep(for: .milliseconds(10))
    let exact = Task {
        try await service.completeOAuth(
            callback: #require(
                URL(string: "xanh-browser://accounts/oauth?code=code&state=expected-state")
            )
        )
    }
    try await update

    await #expect(throws: XanhSyncContractError.self) { try await wrong.value }
    #expect(try await exact.value.accountState == .connected)
    #expect(runtime.completeOAuthCalls == 1)
}

@Test func ambiguousNativeBeginFailureQuarantinesOAuthUntilRestart() async throws {
    let runtime = FakeSyncRuntime()
    runtime.failBeginOAuth = true
    let coordinator = try makeCoordinator(runtime: runtime, secrets: FakeSyncSecrets())
    _ = try await coordinator.initialize()

    await #expect(throws: CocoaError.self) { try await coordinator.beginOAuth() }
    runtime.failBeginOAuth = false
    await #expect(throws: XanhSyncContractError.self) { try await coordinator.beginOAuth() }
    #expect(runtime.beginOAuthCalls == 1)

    let ambiguousRuntime = FakeSyncRuntime()
    ambiguousRuntime.authorizationURL = URL(
        string: "https://accounts.firefox.com/oauth?state&state=expected-state"
    )!
    let ambiguousCoordinator = try makeCoordinator(
        runtime: ambiguousRuntime,
        secrets: FakeSyncSecrets()
    )
    _ = try await ambiguousCoordinator.initialize()
    await #expect(throws: XanhSyncContractError.self) {
        try await ambiguousCoordinator.beginOAuth()
    }
    #expect(ambiguousRuntime.beginOAuthCalls == 1)
}

@Test func persistedSyncStateIsCommittedBeforeAccountState() async throws {
    let secrets = FakeSyncSecrets()
    let coordinator = try makeCoordinator(runtime: FakeSyncRuntime(), secrets: secrets)

    _ = try await coordinator.initialize()

    #expect(await secrets.writes() == [.syncState, .accountState])
}

@Test func firstSyncFailureDoesNotUndoCompletedOAuth() async throws {
    let runtime = FakeSyncRuntime()
    runtime.syncError = CocoaError(.fileReadUnknown)
    let coordinator = try makeCoordinator(runtime: runtime, secrets: FakeSyncSecrets())
    _ = try await coordinator.initialize()
    _ = try await coordinator.beginOAuth()

    let snapshot = try await coordinator.completeOAuth(
        callback: #require(
            URL(string: "xanh-browser://accounts/oauth?code=code&state=expected-state")
        )
    )

    #expect(snapshot.accountState == .connected)
    #expect(snapshot.status == .networkError)
    #expect(snapshot.detail == "Sign-in completed; the first Sync did not finish")
}

@Test func abandonedOAuthReopensPersistedStateAndRejectsTheOldCallback() async throws {
    let runtime = FakeSyncRuntime()
    runtime.authorizationURL = URL(string: "https://accounts.firefox.com/oauth?state=first")!
    let coordinator = try makeCoordinator(runtime: runtime, secrets: FakeSyncSecrets())
    _ = try await coordinator.initialize()
    _ = try await coordinator.beginOAuth()

    var snapshot = try await coordinator.abandonOAuth()
    #expect(snapshot.accountState == .disconnected)

    runtime.authorizationURL = URL(string: "https://accounts.firefox.com/oauth?state=second")!
    _ = try await coordinator.beginOAuth()
    await #expect(throws: XanhSyncContractError.self) {
        try await coordinator.completeOAuth(
            callback: #require(URL(string: "xanh-browser://accounts/oauth?code=code&state=first"))
        )
    }
    snapshot = try await coordinator.completeOAuth(
        callback: #require(URL(string: "xanh-browser://accounts/oauth?code=code&state=second"))
    )
    #expect(snapshot.accountState == .connected)
}

@Test func abandoningAnAuthenticatingRuntimeDeletesSyncStateBeforeAccountState() async throws {
    let runtime = FakeSyncRuntime()
    let secrets = FakeSyncSecrets()
    let coordinator = try makeCoordinator(runtime: runtime, secrets: secrets)
    _ = try await coordinator.initialize()
    _ = try await coordinator.beginOAuth()
    runtime.state = .authenticating

    _ = try await coordinator.abandonOAuth()

    #expect(await secrets.deletes().suffix(2) == [.syncState, .accountState])
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

    let draft = XanhCredentialDraft(
        usernameField: "username",
        passwordField: "password",
        username: "new@example.org",
        password: "new-secret"
    )
    let added = try await coordinator.addCredential(context: context, draft: draft)
    #expect(added.id == "added-credential")
    #expect(runtime.addCredentialCalls == 1)
    #expect(runtime.lastCredentialDraft == draft)

    let updatedDraft = XanhCredentialDraft(
        usernameField: "username",
        passwordField: "password",
        username: "updated@example.org",
        password: "updated-secret"
    )
    let updated = try await coordinator.updateCredential(
        id: added.id,
        context: context,
        draft: updatedDraft
    )
    #expect(updated.id == added.id)
    #expect(updated.username == "updated@example.org")
    #expect(runtime.updateCredentialCalls == 1)
    #expect(try await coordinator.deleteCredential(id: added.id, context: context))
    #expect(runtime.deleteCredentialCalls == 1)

    let privateContext = XanhCredentialContext(
        documentURL: context.documentURL,
        topFrameOrigin: context.topFrameOrigin,
        frameOrigin: context.frameOrigin,
        isPrivate: true,
        userSelected: true
    )
    do {
        _ = try await coordinator.addCredential(context: privateContext, draft: draft)
        Issue.record("private credential mutations must fail before native storage")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }
    #expect(runtime.addCredentialCalls == 1)

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

@Test func placesLibraryPreservesExactIdentitiesAndRejectsPrivateOrUnsafeData() async throws {
    let runtime = FakeSyncRuntime()
    runtime.state = .connected
    let bookmarkURL = try #require(URL(string: "https://example.org/bookmark"))
    let historyURL = try #require(URL(string: "https://example.org/history"))
    let bookmark = XanhBookmarkRecord(
        guid: "bookmark1234",
        parentGUID: "mobile______",
        position: 0,
        kind: .bookmark,
        title: "Saved\u{202E} Page",
        rawURL: bookmarkURL.absoluteString,
        isOpenable: true,
        dateAddedEpochMillis: 1,
        lastModifiedEpochMillis: 2
    )
    let visit = XanhHistoryVisitRecord(
        url: historyURL,
        title: "Visited page",
        visitedAtEpochMillis: 3,
        transition: .typed,
        isRemote: true
    )
    runtime.bookmarksByRoot[.mobile] = [bookmark]
    runtime.historyRecords = [visit]
    let coordinator = try makeCoordinator(
        runtime: runtime,
        secrets: FakeSyncSecrets(),
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    _ = try await coordinator.initialize()

    let bookmarks = try await coordinator.bookmarks()
    #expect(bookmarks == [bookmark])
    #expect(bookmarks[0].displayTitle == "Saved Page")
    #expect(bookmarks[0].openableURL == bookmarkURL)

    let created = try await coordinator.createBookmark(
        url: bookmarkURL,
        title: "  New\nbookmark  "
    )
    #expect(created == "created_____")
    #expect(runtime.lastCreatedBookmarkParentGUID == "mobile______")
    #expect(runtime.lastCreatedBookmarkTitle == "New bookmark")
    #expect(runtime.lastCreatedBookmarkTimestamp == 1_700_000_000_000)

    do {
        try await coordinator.renameBookmark(
            guid: bookmark.guid,
            title: "Private rename",
            isPrivate: true
        )
        Issue.record("private bookmark rename must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }
    #expect(runtime.lastRenamedBookmarkGUID == nil)
    do {
        _ = try await coordinator.deleteBookmark(guid: bookmark.guid, isPrivate: true)
        Issue.record("private bookmark delete must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }
    #expect(runtime.lastDeletedBookmarkGUID == nil)

    try await coordinator.renameBookmark(guid: bookmark.guid, title: " Renamed\nbookmark ")
    #expect(runtime.lastRenamedBookmarkGUID == bookmark.guid)
    #expect(runtime.lastRenamedBookmarkTitle == "Renamed bookmark")
    #expect(try await coordinator.deleteBookmark(guid: bookmark.guid))
    #expect(runtime.lastDeletedBookmarkGUID == bookmark.guid)

    try await coordinator.recordHistory(
        url: historyURL,
        title: "Private",
        isPrivate: true
    )
    #expect(runtime.recordHistoryCalls == 0)
    do {
        try await coordinator.deleteHistoryVisit(
            url: historyURL,
            visitedAtEpochMillis: visit.visitedAtEpochMillis,
            isPrivate: true
        )
        Issue.record("private history delete must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }
    #expect(runtime.lastDeletedHistoryURL == nil)
    do {
        try await coordinator.clearHistory(isPrivate: true)
        Issue.record("private history clear must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }
    #expect(runtime.clearHistoryCalls == 0)
    try await coordinator.recordHistory(url: historyURL, title: " Normal\nvisit ")
    #expect(runtime.recordHistoryCalls == 1)
    #expect(runtime.lastHistoryTitle == "Normal visit")
    #expect(runtime.lastHistoryTimestamp == 1_700_000_000_000)

    #expect(try await coordinator.recentHistory() == [visit])
    try await coordinator.deleteHistoryVisit(
        url: historyURL,
        visitedAtEpochMillis: visit.visitedAtEpochMillis
    )
    #expect(runtime.lastDeletedHistoryURL == historyURL)
    #expect(runtime.lastDeletedHistoryTimestamp == visit.visitedAtEpochMillis)
    try await coordinator.clearHistory()
    #expect(runtime.clearHistoryCalls == 1)

    runtime.bookmarksByRoot[.toolbar] = [bookmark]
    do {
        _ = try await coordinator.bookmarks()
        Issue.record("duplicate Places GUIDs across roots must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }

    runtime.bookmarksByRoot = [
        .mobile: (0...XanhPlacesPolicy.maximumBookmarkRecords).map { index in
            XanhBookmarkRecord(
                guid: String(format: "%012d", index),
                parentGUID: "mobile______",
                position: UInt32(index),
                kind: .bookmark,
                title: "Bookmark",
                rawURL: bookmarkURL.absoluteString,
                isOpenable: true,
                dateAddedEpochMillis: 1,
                lastModifiedEpochMillis: 2
            )
        }
    ]
    do {
        _ = try await coordinator.bookmarks()
        Issue.record("more than 10,000 bookmark records must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }

    let maximumTitle = String(repeating: "x", count: XanhPlacesPolicy.maximumTitleUTF8Bytes)
    runtime.bookmarksByRoot = [
        .mobile: (0..<4_096).map { index in
            XanhBookmarkRecord(
                guid: String(format: "%012d", index),
                parentGUID: "mobile______",
                position: UInt32(index),
                kind: .bookmark,
                title: maximumTitle,
                rawURL: bookmarkURL.absoluteString,
                isOpenable: true,
                dateAddedEpochMillis: 1,
                lastModifiedEpochMillis: 2
            )
        }
    ]
    do {
        _ = try await coordinator.bookmarks()
        Issue.record("bookmark payloads above 16 MiB must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }

    runtime.historyRecords = Array(
        repeating: visit,
        count: XanhPlacesPolicy.maximumHistoryResults + 1
    )
    do {
        _ = try await coordinator.recentHistory()
        Issue.record("more than 500 history visits must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }

    do {
        _ = try await coordinator.createBookmark(
            url: try #require(URL(string: "https://user:secret@example.org/")),
            title: "Unsafe"
        )
        Issue.record("bookmark URLs containing userinfo must fail closed")
    } catch let error as XanhSyncContractError {
        #expect(error == .bridgeRejected)
    }
}

private func makeCoordinator(
    runtime: FakeSyncRuntime,
    secrets: FakeSyncSecrets,
    now: @escaping @Sendable () -> Date = Date.init,
    profile: URL? = nil,
    configuration: XanhSyncConfiguration? = nil
) throws -> XanhFirefoxSyncCoordinator {
    XanhFirefoxSyncCoordinator(
        configuration: try configuration ?? syncConfiguration(),
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

private final class CountingSyncRuntimeFactory: XanhFirefoxSyncRuntimeFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let runtime: FakeSyncRuntime
    private var storedOpenCalls = 0

    init(runtime: FakeSyncRuntime) { self.runtime = runtime }

    var openCalls: Int {
        lock.withLock { storedOpenCalls }
    }

    func open(
        configuration: XanhSyncConfiguration,
        profileDirectory: URL,
        localLoginsKey: String?,
        accountJSON: String?,
        persistedSyncState: String?
    ) throws -> any XanhFirefoxSyncRuntime {
        lock.withLock { storedOpenCalls += 1 }
        return runtime
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
    var syncError: Error?
    var completeOAuthError: Error?
    var failUnlock = false
    var failBeginOAuth = false
    var authorizationURL = URL(string: "https://accounts.firefox.com/oauth?state=expected-state")!
    private(set) var syncCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var lastDisconnectDeletedLocal = false
    private(set) var isVaultUnlocked = false
    private(set) var touchCredentialCalls = 0
    private(set) var addCredentialCalls = 0
    private(set) var updateCredentialCalls = 0
    private(set) var deleteCredentialCalls = 0
    private(set) var lastCredentialDraft: XanhCredentialDraft?
    var credentialRecords: [XanhCredentialRecord] = []
    var remoteDevices: [XanhRemoteTabsDevice] = []
    var bookmarksByRoot: [XanhBookmarkRoot: [XanhBookmarkRecord]] = [:]
    var historyRecords: [XanhHistoryVisitRecord] = []
    var recordHistoryResult = XanhHistoryUpdateResult(acceptedCount: 1, skippedPrivateCount: 0)
    private(set) var lastCreatedBookmarkParentGUID: String?
    private(set) var lastCreatedBookmarkTitle: String?
    private(set) var lastCreatedBookmarkTimestamp: Int64?
    private(set) var lastRenamedBookmarkGUID: String?
    private(set) var lastRenamedBookmarkTitle: String?
    private(set) var lastDeletedBookmarkGUID: String?
    private(set) var recordHistoryCalls = 0
    private(set) var lastHistoryTitle: String?
    private(set) var lastHistoryTimestamp: Int64?
    private(set) var lastDeletedHistoryURL: URL?
    private(set) var lastDeletedHistoryTimestamp: Int64?
    private(set) var clearHistoryCalls = 0
    private(set) var beginOAuthCalls = 0
    private(set) var completeOAuthCalls = 0

    func initialize() throws -> XanhAccountState { state }
    func accountState() throws -> XanhAccountState { state }
    func beginOAuth() throws -> URL {
        beginOAuthCalls += 1
        if failBeginOAuth { throw CocoaError(.fileReadUnknown) }
        return authorizationURL
    }
    func completeOAuth(code: String, state: String) throws -> XanhAccountState {
        completeOAuthCalls += 1
        if let completeOAuthError { throw completeOAuthError }
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
        if let syncError { throw syncError }
        return syncResult
    }

    func remoteTabs() throws -> [XanhRemoteTabsDevice] { remoteDevices }
    func bookmarkRootGUID(_ root: XanhBookmarkRoot) throws -> String {
        switch root {
        case .menu: "menu________"
        case .toolbar: "toolbar_____"
        case .unfiled: "unfiled_____"
        case .mobile: "mobile______"
        }
    }
    func bookmarks(_ root: XanhBookmarkRoot) throws -> [XanhBookmarkRecord] {
        bookmarksByRoot[root] ?? []
    }
    func createBookmark(
        parentGUID: String,
        url: URL,
        title: String,
        dateAddedEpochMillis: Int64,
        isPrivate: Bool
    ) throws -> String {
        lastCreatedBookmarkParentGUID = parentGUID
        lastCreatedBookmarkTitle = title
        lastCreatedBookmarkTimestamp = dateAddedEpochMillis
        return "created_____"
    }
    func renameBookmark(guid: String, title: String, isPrivate: Bool) throws {
        lastRenamedBookmarkGUID = guid
        lastRenamedBookmarkTitle = title
    }
    func deleteBookmark(guid: String, isPrivate: Bool) throws -> Bool {
        lastDeletedBookmarkGUID = guid
        return true
    }
    func recordHistory(
        url: URL,
        title: String,
        visitedAtEpochMillis: Int64,
        transition: XanhHistoryTransition,
        isPrivate: Bool
    ) throws -> XanhHistoryUpdateResult {
        recordHistoryCalls += 1
        lastHistoryTitle = title
        lastHistoryTimestamp = visitedAtEpochMillis
        return recordHistoryResult
    }
    func recentHistory(limit: UInt32) throws -> [XanhHistoryVisitRecord] { historyRecords }
    func deleteHistoryVisit(url: URL, visitedAtEpochMillis: Int64) throws {
        lastDeletedHistoryURL = url
        lastDeletedHistoryTimestamp = visitedAtEpochMillis
    }
    func clearHistory() throws { clearHistoryCalls += 1 }
    func vaultUnlocked() throws -> Bool { isVaultUnlocked }
    func unlockVault(localLoginsKey: String) throws {
        if failUnlock { throw XanhSyncContractError.vaultLocked }
        isVaultUnlocked = true
    }
    func lockVault() throws { isVaultUnlocked = false }
    func credentials(context: XanhCredentialContext) throws -> [XanhCredentialRecord] {
        credentialRecords
    }
    func addCredential(
        context: XanhCredentialContext,
        draft: XanhCredentialDraft
    ) throws -> XanhCredentialRecord {
        addCredentialCalls += 1
        lastCredentialDraft = draft
        let record = credentialRecord(id: "added-credential", context: context, draft: draft)
        credentialRecords.append(record)
        return record
    }
    func updateCredential(
        id: String,
        context: XanhCredentialContext,
        draft: XanhCredentialDraft
    ) throws -> XanhCredentialRecord {
        updateCredentialCalls += 1
        lastCredentialDraft = draft
        let record = credentialRecord(id: id, context: context, draft: draft)
        credentialRecords.removeAll { $0.id == id }
        credentialRecords.append(record)
        return record
    }
    func deleteCredential(id: String, context: XanhCredentialContext) throws -> Bool {
        deleteCredentialCalls += 1
        let count = credentialRecords.count
        credentialRecords.removeAll { $0.id == id }
        return credentialRecords.count != count
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

    private func credentialRecord(
        id: String,
        context: XanhCredentialContext,
        draft: XanhCredentialDraft
    ) -> XanhCredentialRecord {
        let origin = context.canonicalTopFrameOrigin ?? ""
        return XanhCredentialRecord(
            id: id,
            origin: origin,
            formActionOrigin: origin,
            usernameField: draft.usernameField,
            passwordField: draft.passwordField,
            username: draft.username,
            password: draft.password,
            timeCreatedEpochMillis: 1,
            timePasswordChangedEpochMillis: 1,
            timeLastUsedEpochMillis: 1,
            timesUsed: 0
        )
    }
}

private actor FakeSyncSecrets: XanhFirefoxSyncSecretStore {
    private var values: [XanhSyncSecret: String] = [:]
    private var writeOrder: [XanhSyncSecret] = []
    private var deleteOrder: [XanhSyncSecret] = []
    private var deleteFailuresRemaining = 0
    private var targetedDeleteFailures: Set<XanhSyncSecret> = []
    private var writeDelayMilliseconds = 0

    var isEmpty: Bool { values.isEmpty }
    func value(_ secret: XanhSyncSecret) -> String? { values[secret] }
    func writes() -> [XanhSyncSecret] { writeOrder }
    func deletes() -> [XanhSyncSecret] { deleteOrder }
    func seed(_ value: String, for secret: XanhSyncSecret) { values[secret] = value }
    func failNextDelete() { deleteFailuresRemaining += 1 }
    func failDelete(_ secret: XanhSyncSecret) { targetedDeleteFailures.insert(secret) }
    func delayWrites(milliseconds: Int) { writeDelayMilliseconds = milliseconds }
    func read(_ secret: XanhSyncSecret) async throws -> String? { values[secret] }
    func write(_ value: String, for secret: XanhSyncSecret) async throws {
        if writeDelayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(writeDelayMilliseconds))
        }
        writeOrder.append(secret)
        values[secret] = value
    }
    func delete(_ secret: XanhSyncSecret) async throws {
        deleteOrder.append(secret)
        if targetedDeleteFailures.remove(secret) != nil {
            throw CocoaError(.fileWriteUnknown)
        }
        if deleteFailuresRemaining > 0 {
            deleteFailuresRemaining -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        values.removeValue(forKey: secret)
    }
    func readLoginsKeyWithUserPresence(reason: String) async throws -> String? { values[.loginsKey] }
}
