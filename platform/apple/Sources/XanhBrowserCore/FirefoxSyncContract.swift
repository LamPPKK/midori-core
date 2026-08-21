import Foundation

public enum XanhAccountState: String, Codable, Sendable {
    case disconnected, authenticating, connected
    case authIssues = "auth-issues"
}

public enum XanhSyncEngine: String, CaseIterable, Codable, Sendable {
    case bookmarks, history, tabs, passwords
}

public enum XanhSyncReason: String, Codable, Sendable {
    case startup, manual, scheduled
    case localChange = "local-change"
    case preSleep = "pre-sleep"
}

public enum XanhSyncStatus: String, Codable, Sendable {
    case idle, running, success, partial
    case networkError = "network-error"
    case authError = "auth-error"
    case backedOff = "backed-off"
}

public enum XanhAccountServer: Codable, Equatable, Sendable {
    case mozilla
    case selfHosted(accountsURL: URL, tokenServerURL: URL)
}

public struct XanhSyncConfiguration: Codable, Equatable, Sendable {
    public let server: XanhAccountServer
    public let clientID: String
    public let redirectURI: URL
    public let deviceName: String

    public init(server: XanhAccountServer, clientID: String, redirectURI: URL, deviceName: String) throws {
        self.server = server
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.deviceName = deviceName
        try validate()
    }

    public func validate() throws {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XanhSyncContractError.invalidConfiguration("client ID is empty")
        }
        guard !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XanhSyncContractError.invalidConfiguration("device name is empty")
        }
        guard redirectURI.scheme?.lowercased() != "http",
              redirectURI.host != nil,
              redirectURI.user == nil,
              redirectURI.password == nil,
              redirectURI.query == nil,
              redirectURI.fragment == nil else {
            throw XanhSyncContractError.invalidConfiguration(
                "redirect URI must be an absolute non-cleartext callback without userinfo, query or fragment"
            )
        }
        if case let .selfHosted(accountsURL, tokenServerURL) = server {
            try Self.requireSecureOrigin(accountsURL, name: "Accounts URL")
            try Self.requireSecureOrigin(tokenServerURL, name: "Token Server URL")
        }
    }

    public var accountDomain: String {
        switch server {
        case .mozilla: "accounts.firefox.com"
        case let .selfHosted(accountsURL, _): accountsURL.host ?? ""
        }
    }

    private static func requireSecureOrigin(_ url: URL, name: String) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw XanhSyncContractError.invalidConfiguration("\(name) must be an HTTPS origin without userinfo")
        }
    }
}

public enum XanhSyncContractError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case busy
    case vaultLocked
    case bridgeRejected
    case nativeCoreUnavailable

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): message
        case .busy: "Another Firefox Sync operation is still running"
        case .vaultLocked: "The password vault is locked"
        case .bridgeRejected: "The password request was rejected"
        case .nativeCoreUnavailable: "The pinned Firefox Sync native runtime is not packaged"
        }
    }
}

public struct XanhSyncSchedule: Codable, Equatable, Sendable {
    public static let foregroundInterval: TimeInterval = 15 * 60
    public static let localChangeDebounce: TimeInterval = 30

    public var lastSync: Date?
    public var nextAllowed: Date?
    public var localChange: Date?

    public init(lastSync: Date? = nil, nextAllowed: Date? = nil, localChange: Date? = nil) {
        self.lastSync = lastSync
        self.nextAllowed = nextAllowed
        self.localChange = localChange
    }

    public func isDue(reason: XanhSyncReason, now: Date) -> Bool {
        if let nextAllowed, now < nextAllowed { return false }
        return switch reason {
        case .manual, .preSleep: true
        case .startup, .scheduled:
            lastSync.map { now.timeIntervalSince($0) >= Self.foregroundInterval } ?? true
        case .localChange:
            localChange.map { now.timeIntervalSince($0) >= Self.localChangeDebounce } ?? false
        }
    }
}

public struct XanhCredentialContext: Equatable, Sendable {
    public let documentURL: URL
    public let topFrameOrigin: URL
    public let frameOrigin: URL
    public let isPrivate: Bool
    public let userSelected: Bool

    public init(
        documentURL: URL,
        topFrameOrigin: URL,
        frameOrigin: URL,
        isPrivate: Bool,
        userSelected: Bool
    ) {
        self.documentURL = documentURL
        self.topFrameOrigin = topFrameOrigin
        self.frameOrigin = frameOrigin
        self.isPrivate = isPrivate
        self.userSelected = userSelected
    }

    public var isAllowed: Bool {
        guard !isPrivate, userSelected, documentURL.scheme?.lowercased() == "https",
              documentURL.user == nil, documentURL.password == nil else { return false }
        return documentURL.xanhOrigin == topFrameOrigin.xanhOrigin
            && topFrameOrigin.xanhOrigin == frameOrigin.xanhOrigin
    }
}

private extension URL {
    var xanhOrigin: String? {
        guard let scheme = scheme?.lowercased(), let host = host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(port ?? (scheme == "https" ? 443 : -1))"
    }
}
