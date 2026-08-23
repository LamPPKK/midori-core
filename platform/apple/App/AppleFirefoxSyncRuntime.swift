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
        try runtime.remoteTabs().map { device in
            let tabs = try device.tabs.enumerated().map { index, tab in
                let history = try tab.urlHistory.map { value in
                    guard let url = URL(string: value) else {
                        throw XanhSyncContractError.bridgeRejected
                    }
                    return url
                }
                let iconURL = try tab.iconUrl.map { value in
                    guard let url = URL(string: value) else {
                        throw XanhSyncContractError.bridgeRejected
                    }
                    return url
                }
                return XanhRemoteTab(
                    id: "\(device.deviceId):\(index)",
                    title: tab.title,
                    urlHistory: history,
                    iconURL: iconURL,
                    lastUsedEpochMillis: tab.lastUsedEpochMillis,
                    isPinned: tab.isPinned
                )
            }
            return XanhRemoteTabsDevice(
                deviceID: device.deviceId,
                name: device.deviceName,
                kind: map(device.deviceKind),
                lastModifiedEpochMillis: device.lastModifiedEpochMillis,
                tabs: tabs
            )
        }
    }
    func bookmarkRootGUID(_ root: XanhBookmarkRoot) throws -> String {
        bookmarkRootGuid(root: map(root))
    }
    func bookmarks(_ root: XanhBookmarkRoot) throws -> [XanhBookmarkRecord] {
        try runtime.bookmarkTree(root: map(root)).map { record in
            XanhBookmarkRecord(
                guid: record.guid,
                parentGUID: record.parentGuid,
                position: record.position,
                kind: map(record.kind),
                title: record.title,
                rawURL: record.url,
                isOpenable: record.isOpenable,
                dateAddedEpochMillis: record.dateAddedEpochMillis,
                lastModifiedEpochMillis: record.lastModifiedEpochMillis
            )
        }
    }
    func createBookmark(
        parentGUID: String,
        url: URL,
        title: String,
        dateAddedEpochMillis: Int64,
        isPrivate: Bool
    ) throws -> String {
        try runtime.createBookmark(item: NewBookmark(
            parentGuid: parentGUID,
            position: nil,
            kind: .bookmark,
            title: title,
            url: url.absoluteString,
            dateAddedEpochMillis: dateAddedEpochMillis,
            lastModifiedEpochMillis: nil,
            isPrivate: isPrivate
        ))
    }
    func renameBookmark(guid: String, title: String, isPrivate: Bool) throws {
        try runtime.updateBookmark(update: BookmarkUpdate(
            guid: guid,
            title: title,
            url: nil,
            parentGuid: nil,
            position: nil,
            isPrivate: isPrivate
        ))
    }
    func deleteBookmark(guid: String, isPrivate: Bool) throws -> Bool {
        try runtime.deleteBookmark(guid: guid, isPrivate: isPrivate)
    }
    func recordHistory(
        url: URL,
        title: String,
        visitedAtEpochMillis: Int64,
        transition: XanhHistoryTransition,
        isPrivate: Bool
    ) throws -> XanhHistoryUpdateResult {
        let result = try runtime.recordHistory(visits: [LocalHistoryVisit(
            url: url.absoluteString,
            title: title,
            visitedAtEpochMillis: visitedAtEpochMillis,
            transition: map(transition),
            isPrivate: isPrivate
        )])
        return XanhHistoryUpdateResult(
            acceptedCount: result.acceptedCount,
            skippedPrivateCount: result.skippedPrivateCount
        )
    }
    func recentHistory(limit: UInt32) throws -> [XanhHistoryVisitRecord] {
        try runtime.recentHistory(limit: limit).map { record in
            guard let url = URL(string: record.url) else {
                throw XanhSyncContractError.bridgeRejected
            }
            return XanhHistoryVisitRecord(
                url: url,
                title: record.title,
                visitedAtEpochMillis: record.visitedAtEpochMillis,
                transition: map(record.transition),
                isRemote: record.isRemote
            )
        }
    }
    func deleteHistoryVisit(url: URL, visitedAtEpochMillis: Int64) throws {
        try runtime.deleteHistoryVisit(
            url: url.absoluteString,
            visitedAtEpochMillis: visitedAtEpochMillis
        )
    }
    func clearHistory() throws { try runtime.clearHistory() }
    func vaultUnlocked() throws -> Bool { try runtime.vaultUnlocked() }
    func unlockVault(localLoginsKey: String) throws {
        try runtime.unlockVault(localLoginsKey: localLoginsKey)
    }
    func lockVault() throws { try runtime.lockVault() }
    func credentials(context: XanhCredentialContext) throws -> [XanhCredentialRecord] {
        try runtime.credentials(context: map(context)).map(map)
    }
    func addCredential(
        context: XanhCredentialContext,
        draft: XanhCredentialDraft
    ) throws -> XanhCredentialRecord {
        try map(runtime.addCredential(credential: NewCredential(
            context: map(context),
            usernameField: draft.usernameField,
            passwordField: draft.passwordField,
            username: draft.username,
            password: draft.password
        )))
    }
    func updateCredential(
        id: String,
        context: XanhCredentialContext,
        draft: XanhCredentialDraft
    ) throws -> XanhCredentialRecord {
        try map(runtime.updateCredential(credential: CredentialUpdate(
            id: id,
            context: map(context),
            usernameField: draft.usernameField,
            passwordField: draft.passwordField,
            username: draft.username,
            password: draft.password
        )))
    }
    func deleteCredential(id: String, context: XanhCredentialContext) throws -> Bool {
        try runtime.deleteCredential(id: id, context: map(context))
    }
    func touchCredential(id: String, context: XanhCredentialContext) throws {
        try runtime.touchCredential(id: id, context: map(context))
    }
    func disconnect(deleteLocal: Bool) throws { try runtime.disconnect(deleteLocal: deleteLocal) }

    private func map(_ context: XanhCredentialContext) throws -> CredentialContext {
        guard context.isAllowed,
              let topFrameOrigin = context.canonicalTopFrameOrigin,
              let frameOrigin = context.canonicalFrameOrigin else {
            throw XanhSyncContractError.bridgeRejected
        }
        return CredentialContext(
            documentUrl: context.documentURL.absoluteString,
            topFrameOrigin: topFrameOrigin,
            frameOrigin: frameOrigin,
            isPrivate: context.isPrivate,
            userSelected: context.userSelected
        )
    }

    private func map(_ record: CredentialRecord) -> XanhCredentialRecord {
        XanhCredentialRecord(
            id: record.id,
            origin: record.origin,
            formActionOrigin: record.formActionOrigin,
            usernameField: record.usernameField,
            passwordField: record.passwordField,
            username: record.username,
            password: record.password,
            timeCreatedEpochMillis: record.timeCreatedEpochMillis,
            timePasswordChangedEpochMillis: record.timePasswordChangedEpochMillis,
            timeLastUsedEpochMillis: record.timeLastUsedEpochMillis,
            timesUsed: record.timesUsed
        )
    }

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

    private func map(_ kind: RemoteDeviceKind) -> XanhRemoteDeviceKind {
        switch kind {
        case .desktop: .desktop
        case .mobile: .mobile
        case .tablet: .tablet
        case .tv: .tv
        case .vr: .vr
        case .unknown: .unknown
        }
    }

    private func map(_ root: XanhBookmarkRoot) -> BookmarkRoot {
        switch root {
        case .menu: .menu
        case .toolbar: .toolbar
        case .unfiled: .unfiled
        case .mobile: .mobile
        }
    }

    private func map(_ kind: BookmarkKind) -> XanhBookmarkKind {
        switch kind {
        case .bookmark: .bookmark
        case .folder: .folder
        case .separator: .separator
        }
    }

    private func map(_ transition: XanhHistoryTransition) -> HistoryTransition {
        switch transition {
        case .link: .link
        case .typed: .typed
        case .bookmark: .bookmark
        case .redirectPermanent: .redirectPermanent
        case .redirectTemporary: .redirectTemporary
        case .download: .download
        case .reload: .reload
        }
    }

    private func map(_ transition: HistoryTransition) -> XanhHistoryTransition {
        switch transition {
        case .link: .link
        case .typed: .typed
        case .bookmark: .bookmark
        case .redirectPermanent: .redirectPermanent
        case .redirectTemporary: .redirectTemporary
        case .download: .download
        case .reload: .reload
        }
    }
}

private func generateNativeLocalLoginsKey() throws -> String {
    try generateLocalLoginsKey()
}
#endif
