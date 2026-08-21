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

    var snapshot = XanhSyncHostSnapshot(
        accountState: .disconnected,
        status: .idle,
        enabledEngines: Set(XanhSyncEngine.allCases),
        vaultUnlocked: false,
        lastSync: nil,
        nextAllowed: nil,
        detail: "Firefox Sync is not configured"
    )
    var accountsURL = ""
    var tokenServerURL = ""
    var clientID = ""
    var isShowingSettings = false
    var isConfirmingAccountDomain = false
    var isConfirmingDisconnect = false
    var accountDomain = ""
    var remoteTabsSummary = "Remote tabs have not been loaded."
    var errorMessage: String?

    private var coordinator: XanhFirefoxSyncCoordinator?
    private var pendingOAuth: XanhOAuthLaunch?

    var isConfigured: Bool { coordinator != nil }

    func initializeIfConfigured() async {
        guard coordinator == nil, let configuration = loadConfiguration() else { return }
        await initialize(configuration)
    }

    func saveSelfHostedConfiguration() async {
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
            UserDefaults.standard.set(try JSONEncoder().encode(stored), forKey: Self.configurationKey)
            await initialize(configuration)
        } catch {
            report(error)
        }
    }

    func prepareSignIn() async {
        guard let coordinator else { return }
        do {
            let launch = try await coordinator.beginOAuth()
            pendingOAuth = launch
            accountDomain = launch.accountDomain
            isConfirmingAccountDomain = true
            await refreshSnapshot()
        } catch {
            report(error)
        }
    }

    func confirmedSignInURL() -> URL? {
        defer { pendingOAuth = nil }
        return pendingOAuth?.authorizationURL
    }

    func handleOAuthCallback(_ url: URL) async {
        if coordinator == nil { await initializeIfConfigured() }
        guard let coordinator else {
            errorMessage = "Firefox Sync is not configured on this device."
            return
        }
        do {
            snapshot = try await coordinator.completeOAuth(callback: url)
        } catch {
            report(error)
        }
    }

    func syncNow() async {
        guard let coordinator else { return }
        do {
            snapshot = try await coordinator.sync(reason: .manual)
        } catch {
            report(error)
        }
    }

    func syncIfDue(_ reason: XanhSyncReason) async {
        guard let coordinator, snapshot.accountState == .connected else { return }
        do {
            snapshot = try await coordinator.sync(reason: reason)
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
            if snapshot.vaultUnlocked { try await coordinator.lockVault() }
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
            await refreshSnapshot()
        } catch {
            report(error)
        }
    }

    func lockVaultIfIdle() async {
        guard let coordinator else { return }
        do {
            if try await coordinator.lockVaultIfIdle() { await refreshSnapshot() }
        } catch {
            report(error)
        }
    }

    func loadRemoteTabs() async {
        guard let coordinator else { return }
        do {
            let devices = try await coordinator.remoteTabs()
            let tabCount = devices.reduce(0) { $0 + $1.tabCount }
            remoteTabsSummary = devices.isEmpty
                ? "No remote devices are available."
                : "\(tabCount) tab(s) from \(devices.count) device(s). Remote tabs are never opened automatically."
        } catch {
            report(error)
        }
    }

    func disconnect(deleteLocal: Bool) async {
        guard let coordinator else { return }
        do {
            try await coordinator.disconnect(deleteLocal: deleteLocal)
            await refreshSnapshot()
        } catch {
            report(error)
        }
    }

    private func initialize(_ configuration: XanhSyncConfiguration) async {
        guard let factory = AppleFirefoxSyncRuntimeProvider.factory else {
            snapshot = snapshotWithDetail(
                "This verification build does not package the pinned Firefox Sync XCFramework."
            )
            return
        }
        do {
            let profile = try Self.profileDirectory()
            let service = "\(Bundle.main.bundleIdentifier ?? "io.github.lamppkk.xanhbrowser").firefox-sync"
            let value = XanhFirefoxSyncCoordinator(
                configuration: configuration,
                profileDirectory: profile,
                runtimeFactory: factory,
                secrets: XanhKeychainFirefoxSyncSecretStore(service: service)
            )
            snapshot = try await value.initialize()
            coordinator = value
            if snapshot.accountState == .connected {
                snapshot = try await value.sync(reason: .startup)
            }
        } catch {
            report(error)
        }
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
        snapshot = await coordinator.snapshot
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        snapshot = snapshotWithDetail("Firefox Sync needs attention")
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
}
