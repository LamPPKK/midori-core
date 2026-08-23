import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

@available(iOS 26.0, macOS 26.0, *)
@MainActor
@Observable
final class FirefoxSyncViewModel {
    private static let configurationKey = "XanhFirefoxSyncPublicConfigurationV1"
#if os(macOS)
    private static let redirectURI = URL(string: "xanh-browser-macos://accounts/oauth")!
#else
    private static let redirectURI = URL(string: "xanh-browser-ios://accounts/oauth")!
#endif

    var snapshot: XanhSyncHostSnapshot { process.snapshot }
    var accountsURL = ""
    var tokenServerURL = ""
    var clientID = ""
    var isShowingSettings = false
    var isConfirmingAccountDomain = false
    var isConfirmingDisconnect = false
    var accountOrigin = ""
    var remoteTabs: [XanhRemoteTabsDevice] = []
    var remoteTabsStatus = "Remote tabs have not been loaded."
    var bookmarks: [XanhBookmarkRecord] = []
    var bookmarksStatus = "Bookmarks have not been loaded."
    var recentHistory: [XanhHistoryVisitRecord] = []
    var historyStatus = "History has not been loaded."
    var isConfirmingClearHistory = false
    var siteCredentials: [XanhCredentialRecord] = []
    var passwordsStatus = "Passwords have not been loaded."
    var errorMessage: String?
    var credentialSelection: FirefoxCredentialSelection?

    private var coordinator: XanhFirefoxSyncCoordinator?
    private let process: XanhFirefoxSyncProcessService
    private var isInitializing = false
    private var pendingHistory: [PendingHistoryVisit] = []
    private var isWritingHistory = false
    @ObservationIgnored
    private var credentialContinuation: CheckedContinuation<XanhCredentialRecord?, Never>?

    init(process: XanhFirefoxSyncProcessService) {
        self.process = process
    }

    var isConfigured: Bool { coordinator != nil }

    func initializeIfConfigured() async {
        guard coordinator == nil, !isInitializing, let configuration = loadConfiguration() else {
            return
        }
        isInitializing = true
        defer { isInitializing = false }
        do {
            try await initialize(configuration)
        } catch {
            report(error)
        }
    }

    func saveSelfHostedConfiguration() async {
        guard !isInitializing else { return }
        isInitializing = true
        defer { isInitializing = false }
        do {
            guard let accounts = URL(string: accountsURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let token = URL(string: tokenServerURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw XanhSyncContractError.invalidConfiguration("Enter valid HTTPS server URLs")
            }
            let configuration = try XanhSyncConfiguration(
                server: .selfHosted(accountsURL: accounts, tokenServerURL: token),
                clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                redirectURI: Self.redirectURI,
                deviceName: Self.deviceName
            )
            let stored = StoredConfiguration(
                accountsURL: accounts.absoluteString,
                tokenServerURL: token.absoluteString,
                clientID: configuration.clientID
            )
            try await initialize(configuration)
            UserDefaults.standard.set(
                try JSONEncoder().encode(stored),
                forKey: Self.configurationKey
            )
        } catch {
            report(error)
        }
    }

    func prepareSignIn() async {
        guard let coordinator else { return }
        accountOrigin = await coordinator.accountOrigin
        isConfirmingAccountDomain = true
    }

    func beginConfirmedSignIn() async -> URL? {
        guard let coordinator else { return nil }
        do {
            let launch = try await coordinator.beginOAuth()
            process.updateSnapshot(await coordinator.snapshot)
            return launch.authorizationURL
        } catch {
            report(error)
            return nil
        }
    }

    func finishOAuthLaunch(accepted: Bool) async {
        guard !accepted, let coordinator else { return }
        do {
            process.updateSnapshot(try await coordinator.abandonOAuth())
            errorMessage = "The system browser did not open. Firefox Accounts sign-in was canceled."
        } catch {
            report(error)
        }
    }

    func handleOAuthCallback(_ url: URL) async {
        if coordinator == nil { await initializeIfConfigured() }
        guard coordinator != nil else {
            errorMessage = "Firefox Sync is not configured on this device."
            return
        }
        do {
            _ = try await process.completeOAuth(callback: url)
        } catch {
            report(error)
        }
    }

    func syncNow() async {
        guard let coordinator else { return }
        do {
            process.updateSnapshot(try await coordinator.sync(reason: .manual))
        } catch {
            report(error)
        }
    }

    func syncIfDue(_ reason: XanhSyncReason) async {
        guard let coordinator, snapshot.accountState == .connected else { return }
        do {
            process.updateSnapshot(try await coordinator.sync(reason: reason))
        } catch XanhSyncContractError.busy {
            // A user-initiated operation already owns the single-flight slot.
        } catch {
            report(error)
        }
    }

    func setEngine(_ engine: XanhSyncEngine, enabled: Bool) async {
        guard let coordinator else { return }
        do {
            try await coordinator.setEngine(engine, enabled: enabled)
            await refreshSnapshot()
        } catch {
            report(error)
        }
    }

    func toggleVault() async {
        guard let coordinator else { return }
        do {
            if snapshot.vaultUnlocked {
                try await coordinator.lockVault()
                clearCredentialLibrary()
            }
            else { try await coordinator.unlockVault() }
            await refreshSnapshot()
        } catch {
            report(error)
        }
    }

    func lockVault() async {
        guard let coordinator else { return }
        do {
            try await coordinator.lockVault()
            clearCredentialLibrary()
            await refreshSnapshot()
        } catch {
            report(error)
        }
    }

    func lockVaultIfIdle() async {
        guard let coordinator else { return }
        do {
            if try await coordinator.lockVaultIfIdle() {
                clearCredentialLibrary()
                await refreshSnapshot()
            }
        } catch {
            report(error)
        }
    }

    func loadRemoteTabs() async {
        guard let coordinator else { return }
        do {
            remoteTabs = try await coordinator.remoteTabs()
            let tabCount = remoteTabs.reduce(0) { $0 + $1.tabs.count }
            remoteTabsStatus = remoteTabs.isEmpty
                ? "No remote devices are available."
                : "\(tabCount) tab(s) from \(remoteTabs.count) device(s). Choose one tab to open it."
        } catch {
            remoteTabs = []
            remoteTabsStatus = "Remote tabs could not be loaded."
            report(error)
        }
    }

    func saveBookmark(url: URL?, title: String?, isPrivate: Bool) async {
        guard let coordinator else { return }
        guard !isPrivate else {
            bookmarksStatus = "Private tabs cannot create bookmarks."
            return
        }
        guard let url, XanhPlacesPolicy.isAllowedWebURL(url) else {
            bookmarksStatus = "The current page cannot be bookmarked safely."
            return
        }
        do {
            _ = try await coordinator.createBookmark(url: url, title: title)
            await loadBookmarks(detail: "Bookmark saved to Mobile Bookmarks.")
        } catch {
            report(error)
        }
    }

    func loadBookmarks(detail: String? = nil) async {
        guard let coordinator else { return }
        do {
            bookmarks = try await coordinator.bookmarks().filter { $0.kind == .bookmark }
            bookmarksStatus = detail ?? (bookmarks.isEmpty
                ? "No Firefox Sync bookmarks are available."
                : "\(bookmarks.count) bookmark(s). Unsafe Firefox URLs remain manageable but cannot be opened.")
        } catch {
            bookmarks = []
            bookmarksStatus = "Bookmarks could not be loaded."
            report(error)
        }
    }

    func renameBookmark(
        _ bookmark: XanhBookmarkRecord,
        title: String,
        isPrivate: Bool
    ) async {
        guard let coordinator else { return }
        do {
            try await coordinator.renameBookmark(
                guid: bookmark.guid,
                title: title,
                isPrivate: isPrivate
            )
            await loadBookmarks(detail: "Bookmark renamed by exact GUID.")
        } catch {
            report(error)
        }
    }

    func deleteBookmark(_ bookmark: XanhBookmarkRecord, isPrivate: Bool) async {
        guard let coordinator else { return }
        do {
            let deleted = try await coordinator.deleteBookmark(
                guid: bookmark.guid,
                isPrivate: isPrivate
            )
            await loadBookmarks(detail: deleted
                ? "Bookmark deleted by exact GUID."
                : "Bookmark no longer exists.")
        } catch {
            report(error)
        }
    }

    func recordHistory(url: URL, title: String?, isPrivate: Bool) async {
        guard !isPrivate,
              coordinator != nil,
              XanhPlacesPolicy.isAllowedWebURL(url) else { return }
        let candidate = PendingHistoryVisit(url: url, title: title)
        guard pendingHistory.last != candidate else { return }
        if pendingHistory.count == 100 { pendingHistory.removeFirst() }
        pendingHistory.append(candidate)
        await drainHistoryQueue()
    }

    func loadRecentHistory(detail: String? = nil) async {
        guard let coordinator else { return }
        do {
            recentHistory = try await coordinator.recentHistory()
            historyStatus = detail ?? (recentHistory.isEmpty
                ? "No Firefox Sync history is available."
                : "\(recentHistory.count) recent visit(s). Remote visits are never opened automatically.")
        } catch {
            recentHistory = []
            historyStatus = "History could not be loaded."
            report(error)
        }
    }

    func deleteHistoryVisit(_ visit: XanhHistoryVisitRecord, isPrivate: Bool) async {
        guard let coordinator else { return }
        do {
            try await coordinator.deleteHistoryVisit(
                url: visit.url,
                visitedAtEpochMillis: visit.visitedAtEpochMillis,
                isPrivate: isPrivate
            )
            await loadRecentHistory(detail: "The selected URL/timestamp visit was deleted.")
        } catch {
            report(error)
        }
    }

    func clearHistory(isPrivate: Bool) async {
        guard let coordinator else { return }
        do {
            try await coordinator.clearHistory(isPrivate: isPrivate)
            recentHistory = []
            historyStatus = "All local Places history was cleared. The next Sync publishes the deletion."
        } catch {
            report(error)
        }
    }

    @discardableResult
    func loadSiteCredentials(
        contextProvider: @MainActor @Sendable () -> XanhCredentialContext?
    ) async -> Bool {
        guard let context = contextProvider(), context.isAllowed else {
            clearCredentialLibrary(
                detail: "Passwords are unavailable in private or non-HTTPS pages."
            )
            return false
        }
        guard let coordinator else {
            clearCredentialLibrary()
            return false
        }
        do {
            let currentSnapshot = await coordinator.snapshot
            if !currentSnapshot.vaultUnlocked { try await coordinator.unlockVault() }
            guard contextProvider() == context else {
                clearCredentialLibrary(detail: "The page changed before passwords were loaded.")
                return false
            }
            let records = try await coordinator.credentials(for: context)
            guard contextProvider() == context else {
                clearCredentialLibrary(detail: "The page changed before passwords were loaded.")
                return false
            }
            siteCredentials = records
            passwordsStatus = siteCredentials.isEmpty
                ? "No saved passwords for this exact HTTPS origin."
                : "\(siteCredentials.count) saved login(s) for this exact HTTPS origin."
            await refreshSnapshot()
            return true
        } catch {
            clearCredentialLibrary(detail: "Passwords could not be loaded.")
            report(error)
            return false
        }
    }

    func addCredential(
        draft: XanhCredentialDraft,
        contextProvider: @MainActor @Sendable () -> XanhCredentialContext?
    ) async {
        guard let coordinator,
              let context = contextProvider(),
              draft.isAllowed(for: context) else {
            report(XanhSyncContractError.bridgeRejected)
            return
        }
        do {
            _ = try await coordinator.addCredential(context: context, draft: draft)
            guard contextProvider() == context else {
                clearCredentialLibrary(detail: "The page changed after the password was saved.")
                return
            }
            if await loadSiteCredentials(contextProvider: contextProvider) {
                passwordsStatus = "Password saved for the exact HTTPS origin."
            }
        } catch {
            report(error)
        }
    }

    func updateCredential(
        _ record: XanhCredentialRecord,
        draft: XanhCredentialDraft,
        contextProvider: @MainActor @Sendable () -> XanhCredentialContext?
    ) async {
        guard let coordinator,
              let context = contextProvider(),
              record.isAllowed(for: context),
              draft.isAllowed(for: context) else {
            report(XanhSyncContractError.bridgeRejected)
            return
        }
        do {
            _ = try await coordinator.updateCredential(
                id: record.id,
                context: context,
                draft: draft
            )
            guard contextProvider() == context else {
                clearCredentialLibrary(detail: "The page changed after the password was updated.")
                return
            }
            if await loadSiteCredentials(contextProvider: contextProvider) {
                passwordsStatus = "Password updated by exact login ID."
            }
        } catch {
            report(error)
        }
    }

    func deleteCredential(
        _ record: XanhCredentialRecord,
        contextProvider: @MainActor @Sendable () -> XanhCredentialContext?
    ) async {
        guard let coordinator,
              let context = contextProvider(),
              record.isAllowed(for: context) else {
            report(XanhSyncContractError.bridgeRejected)
            return
        }
        do {
            let deleted = try await coordinator.deleteCredential(id: record.id, context: context)
            guard contextProvider() == context else {
                clearCredentialLibrary(detail: "The page changed after the password was deleted.")
                return
            }
            if await loadSiteCredentials(contextProvider: contextProvider) {
                passwordsStatus = deleted
                    ? "Password deleted by exact login ID."
                    : "The selected password no longer exists."
            }
        } catch {
            report(error)
        }
    }

    func clearCredentialLibrary(detail: String = "Passwords have not been loaded.") {
        siteCredentials = []
        passwordsStatus = detail
    }

    func requestCredential(
        for context: XanhCredentialContext
    ) async -> XanhCredentialRecord? {
        guard context.isAllowed,
              credentialSelection == nil,
              credentialContinuation == nil else { return nil }
        if coordinator == nil { await initializeIfConfigured() }
        guard let coordinator else { return nil }
        do {
            let currentSnapshot = await coordinator.snapshot
            if !currentSnapshot.vaultUnlocked {
                try await coordinator.unlockVault()
            }
            let records = try await coordinator.credentials(for: context)
            await refreshSnapshot()
            guard !records.isEmpty else { return nil }
            return await withCheckedContinuation { continuation in
                credentialContinuation = continuation
                credentialSelection = FirefoxCredentialSelection(
                    context: context,
                    credentials: records
                )
            }
        } catch {
            report(error)
            return nil
        }
    }

    func selectCredential(_ record: XanhCredentialRecord) async {
        guard let selection = credentialSelection,
              selection.credentials.contains(where: { $0.id == record.id }),
              let continuation = credentialContinuation else { return }
        credentialSelection = nil
        credentialContinuation = nil
        do {
            try await coordinator?.touchCredential(id: record.id, context: selection.context)
            await refreshSnapshot()
            continuation.resume(returning: record)
        } catch {
            report(error)
            continuation.resume(returning: nil)
        }
    }

    func cancelCredentialSelection() {
        credentialSelection = nil
        let continuation = credentialContinuation
        credentialContinuation = nil
        continuation?.resume(returning: nil)
    }

    func disconnect(deleteLocal: Bool) async {
        guard let coordinator else { return }
        do {
            try await coordinator.disconnect(deleteLocal: deleteLocal)
            remoteTabs = []
            remoteTabsStatus = "Remote tabs have not been loaded."
            bookmarks = []
            bookmarksStatus = "Bookmarks have not been loaded."
            recentHistory = []
            historyStatus = "History has not been loaded."
            pendingHistory = []
            clearCredentialLibrary()
            await refreshSnapshot()
        } catch {
            report(error)
        }
    }

    private func initialize(_ configuration: XanhSyncConfiguration) async throws {
        guard let factory = AppleFirefoxSyncRuntimeProvider.factory else {
            process.updateSnapshot(snapshotWithDetail(
                "This verification build does not package the pinned Firefox Sync XCFramework."
            ))
            throw XanhSyncContractError.nativeCoreUnavailable
        }
        let profile = try Self.profileDirectory()
        let service = "\(Bundle.main.bundleIdentifier ?? "io.github.lamppkk.xanhbrowser").firefox-sync"
        let result = try await process.initialize(
            configuration: configuration,
            profileDirectory: profile,
            runtimeFactory: factory,
            secrets: XanhKeychainFirefoxSyncSecretStore(service: service)
        )
        coordinator = result.0
        process.updateSnapshot(result.1)
    }

    private func loadConfiguration() -> XanhSyncConfiguration? {
        let approved = (Bundle.main.object(
            forInfoDictionaryKey: "XanhFirefoxSyncProductionApproved"
        ) as? String) == "1"
        let productionClientID = Bundle.main.object(
            forInfoDictionaryKey: "XanhFirefoxSyncClientID"
        ) as? String
        if approved, let productionClientID, !productionClientID.isEmpty {
            return try? XanhSyncConfiguration(
                server: .mozilla,
                clientID: productionClientID,
                redirectURI: Self.redirectURI,
                deviceName: Self.deviceName
            )
        }
        guard let data = UserDefaults.standard.data(forKey: Self.configurationKey),
              let stored = try? JSONDecoder().decode(StoredConfiguration.self, from: data),
              let accounts = URL(string: stored.accountsURL),
              let token = URL(string: stored.tokenServerURL) else { return nil }
        accountsURL = stored.accountsURL
        tokenServerURL = stored.tokenServerURL
        clientID = stored.clientID
        return try? XanhSyncConfiguration(
            server: .selfHosted(accountsURL: accounts, tokenServerURL: token),
            clientID: stored.clientID,
            redirectURI: Self.redirectURI,
            deviceName: Self.deviceName
        )
    }

    private func refreshSnapshot() async {
        guard let coordinator else { return }
        process.updateSnapshot(await coordinator.snapshot)
    }

    private func drainHistoryQueue() async {
        guard !isWritingHistory else { return }
        isWritingHistory = true
        defer { isWritingHistory = false }

        while !pendingHistory.isEmpty, !Task.isCancelled {
            guard let coordinator else {
                pendingHistory = []
                return
            }
            let visit = pendingHistory.removeFirst()
            do {
                try await coordinator.recordHistory(url: visit.url, title: visit.title)
            } catch XanhSyncContractError.busy {
                pendingHistory.insert(visit, at: 0)
                try? await Task.sleep(for: .milliseconds(250))
            } catch {
                historyStatus = "A page visit could not be saved to Places."
            }
        }
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func snapshotWithDetail(_ detail: String) -> XanhSyncHostSnapshot {
        XanhSyncHostSnapshot(
            accountState: snapshot.accountState,
            status: snapshot.status,
            enabledEngines: snapshot.enabledEngines,
            vaultUnlocked: snapshot.vaultUnlocked,
            lastSync: snapshot.lastSync,
            nextAllowed: snapshot.nextAllowed,
            detail: detail
        )
    }

    private static var deviceName: String {
#if os(macOS)
        Host.current().localizedName ?? "Xanh Browser macOS"
#else
        UIDevice.current.name
#endif
    }

    private static func profileDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "XanhBrowser/FirefoxSync", directoryHint: .isDirectory)
    }

    private struct StoredConfiguration: Codable {
        let accountsURL: String
        let tokenServerURL: String
        let clientID: String
    }

    private struct PendingHistoryVisit: Equatable {
        let url: URL
        let title: String?
    }
}

struct FirefoxCredentialSelection: Identifiable {
    let id = UUID()
    let context: XanhCredentialContext
    let credentials: [XanhCredentialRecord]
}
