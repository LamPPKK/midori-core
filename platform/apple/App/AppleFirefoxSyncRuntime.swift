import Foundation
#if os(iOS)
import UIKit
#endif

enum AppleFirefoxSyncRuntimeProvider {
    static var factory: (any XanhFirefoxSyncRuntimeFactory)? {
#if XANH_ENABLE_FIREFOX_SYNC
        AppleFirefoxSyncRuntimeFactory()
#else
        nil
#endif
    }
}

#if XANH_ENABLE_FIREFOX_SYNC
private struct AppleFirefoxSyncRuntimeFactory: XanhFirefoxSyncRuntimeFactory {
    func open(
        configuration: XanhSyncConfiguration,
        profileDirectory: URL,
        localLoginsKey: String?,
        accountJSON: String?,
        persistedSyncState: String?
    ) throws -> any XanhFirefoxSyncRuntime {
        let server: AccountServer = switch configuration.server {
        case .mozilla:
            .mozilla
        case let .selfHosted(accountsURL, tokenServerURL):
            .selfHosted(
                accountsUrl: accountsURL.absoluteString,
                tokenServerUrl: tokenServerURL.absoluteString
            )
        }
#if os(macOS)
        let deviceKind = DeviceKind.desktop
#elseif os(iOS)
        let deviceKind = UIDevice.current.userInterfaceIdiom == .pad
            ? DeviceKind.tablet
            : DeviceKind.mobile
#else
        let deviceKind = DeviceKind.desktop
#endif
        let runtime = try MozillaSyncRuntime(
            config: SyncConfig(
                server: server,
                clientId: configuration.clientID,
                redirectUri: configuration.redirectURI.absoluteString,
                deviceName: configuration.deviceName,
                deviceKind: deviceKind
            ),
            profileDir: profileDirectory.path,
            localLoginsKey: localLoginsKey,
            accountJson: accountJSON,
            persistedSyncState: persistedSyncState
        )
        return AppleFirefoxSyncRuntime(runtime: runtime)
    }

    func generateLocalLoginsKey() throws -> String {
        try generateNativeLocalLoginsKey()
    }
}

private final class AppleFirefoxSyncRuntime: XanhFirefoxSyncRuntime, @unchecked Sendable {
    private let runtime: MozillaSyncRuntime

    init(runtime: MozillaSyncRuntime) {
        self.runtime = runtime
    }

    func initialize() throws -> XanhAccountState { try map(runtime.initialize()) }
    func accountState() throws -> XanhAccountState { try map(runtime.accountState()) }
    func beginOAuth() throws -> URL {
        guard let url = URL(string: try runtime.beginOauth()) else {
            throw XanhSyncContractError.invalidConfiguration("Native OAuth URL is invalid")
        }
        return url
    }
    func completeOAuth(code: String, state: String) throws -> XanhAccountState {
        try map(runtime.completeOauth(code: code, state: state))
    }
    func accountJSON() throws -> String { try runtime.accountJson() }
    func persistedSyncState() throws -> String? { try runtime.persistedSyncState() }
    func sync(reason: XanhSyncReason, engines: [XanhSyncEngine]) throws -> XanhNativeSyncResult {
        let result = try runtime.sync(reason: map(reason), engines: engines.map(map))
        return XanhNativeSyncResult(
            status: map(result.status),
            nextSyncAllowedEpochSeconds: result.nextSyncAllowedEpochSeconds
        )
    }
    func remoteTabs() throws -> [XanhRemoteTabsDevice] {
        try runtime.remoteTabs().map {
            XanhRemoteTabsDevice(name: $0.deviceName, tabCount: $0.tabs.count)
        }
    }
    func vaultUnlocked() throws -> Bool { try runtime.vaultUnlocked() }
    func unlockVault(localLoginsKey: String) throws {
        try runtime.unlockVault(localLoginsKey: localLoginsKey)
    }
    func lockVault() throws { try runtime.lockVault() }
    func disconnect(deleteLocal: Bool) throws { try runtime.disconnect(deleteLocal: deleteLocal) }

    private func map(_ state: AccountState) -> XanhAccountState {
        switch state {
        case .disconnected: .disconnected
        case .authenticating: .authenticating
        case .connected: .connected
        case .authIssues: .authIssues
        }
    }

    private func map(_ reason: XanhSyncReason) -> SyncReason {
        switch reason {
        case .startup: .startup
        case .manual: .manual
        case .scheduled: .scheduled
        case .localChange: .localChange
        case .preSleep: .preSleep
        }
    }

    private func map(_ engine: XanhSyncEngine) -> SyncEngine {
        switch engine {
        case .bookmarks: .bookmarks
        case .history: .history
        case .tabs: .tabs
        case .passwords: .passwords
        }
    }

    private func map(_ status: SyncStatus) -> XanhSyncStatus {
        switch status {
        case .idle: .idle
        case .running: .running
        case .success: .success
        case .partial: .partial
        case .networkError: .networkError
        case .authError: .authError
        case .backedOff: .backedOff
        }
    }
}

private func generateNativeLocalLoginsKey() throws -> String {
    try generateLocalLoginsKey()
}
#endif
