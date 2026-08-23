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

    public var accountPort: Int {
        switch server {
        case .mozilla: 443
        case let .selfHosted(accountsURL, _): accountsURL.port ?? 443
        }
    }

    public var accountOrigin: String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = accountDomain
        if accountPort != 443 { components.port = accountPort }
        return components.string ?? "https://\(accountDomain)"
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
    public static let maximumURLBytes = 8_192

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

    public static func exactTopLevel(
        documentURL: URL,
        isPrivate: Bool,
        userSelected: Bool
    ) -> Self? {
        guard documentURL.xanhIsSecureHTTPS,
              var components = URLComponents(url: documentURL, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        components.scheme = "https"
        components.host = host
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        if components.port == 443 { components.port = nil }
        guard let origin = components.url else { return nil }
        let context = Self(
            documentURL: documentURL,
            topFrameOrigin: origin,
            frameOrigin: origin,
            isPrivate: isPrivate,
            userSelected: userSelected
        )
        return context.isAllowed ? context : nil
    }

    public var isAllowed: Bool {
        guard !isPrivate, userSelected, documentURL.xanhIsSecureHTTPS,
              topFrameOrigin.xanhIsSecureOrigin,
              frameOrigin.xanhIsSecureOrigin,
              documentURL.absoluteString.utf8.count <= Self.maximumURLBytes,
              topFrameOrigin.absoluteString.utf8.count <= Self.maximumURLBytes,
              frameOrigin.absoluteString.utf8.count <= Self.maximumURLBytes else { return false }
        return documentURL.xanhOrigin == topFrameOrigin.xanhOrigin
            && topFrameOrigin.xanhOrigin == frameOrigin.xanhOrigin
    }

    public var canonicalTopFrameOrigin: String? {
        guard topFrameOrigin.xanhIsSecureOrigin else { return nil }
        return topFrameOrigin.xanhCanonicalOrigin
    }

    public var canonicalFrameOrigin: String? {
        guard frameOrigin.xanhIsSecureOrigin else { return nil }
        return frameOrigin.xanhCanonicalOrigin
    }
}

public struct XanhCredentialRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let origin: String
    public let formActionOrigin: String
    public let usernameField: String
    public let passwordField: String
    public let username: String
    public let password: String
    public let timeCreatedEpochMillis: Int64
    public let timePasswordChangedEpochMillis: Int64
    public let timeLastUsedEpochMillis: Int64
    public let timesUsed: Int64

    public init(
        id: String,
        origin: String,
        formActionOrigin: String,
        usernameField: String,
        passwordField: String,
        username: String,
        password: String,
        timeCreatedEpochMillis: Int64,
        timePasswordChangedEpochMillis: Int64,
        timeLastUsedEpochMillis: Int64,
        timesUsed: Int64
    ) {
        self.id = id
        self.origin = origin
        self.formActionOrigin = formActionOrigin
        self.usernameField = usernameField
        self.passwordField = passwordField
        self.username = username
        self.password = password
        self.timeCreatedEpochMillis = timeCreatedEpochMillis
        self.timePasswordChangedEpochMillis = timePasswordChangedEpochMillis
        self.timeLastUsedEpochMillis = timeLastUsedEpochMillis
        self.timesUsed = timesUsed
    }

    public func isAllowed(for context: XanhCredentialContext) -> Bool {
        guard context.isAllowed,
              let expectedOrigin = context.canonicalTopFrameOrigin,
              URL(string: origin)?.xanhCanonicalOrigin == expectedOrigin,
              URL(string: formActionOrigin)?.xanhCanonicalOrigin == expectedOrigin,
              XanhCredentialPolicy.isValidID(id),
              XanhCredentialPolicy.isValidUsername(username),
              XanhCredentialPolicy.isValidPassword(password),
              XanhCredentialPolicy.isValidField(usernameField),
              XanhCredentialPolicy.isValidField(passwordField),
              timeCreatedEpochMillis >= 0,
              timePasswordChangedEpochMillis >= 0,
              timeLastUsedEpochMillis >= 0,
              timesUsed >= 0 else { return false }
        return true
    }

    public var displayUsername: String {
        XanhRemoteTabsPolicy.sanitizedDisplayText(
            username,
            fallback: "(empty username)",
            maximumUTF8Bytes: XanhCredentialPolicy.maximumUsernameBytes
        )
    }
}

public struct XanhCredentialDraft: Equatable, Sendable {
    public let usernameField: String
    public let passwordField: String
    public let username: String
    public let password: String

    public init(
        usernameField: String = "",
        passwordField: String = "",
        username: String,
        password: String
    ) {
        self.usernameField = usernameField
        self.passwordField = passwordField
        self.username = username
        self.password = password
    }

    public func isAllowed(for context: XanhCredentialContext) -> Bool {
        context.isAllowed
            && XanhCredentialPolicy.isValidField(usernameField)
            && XanhCredentialPolicy.isValidField(passwordField)
            && XanhCredentialPolicy.isValidUsername(username)
            && XanhCredentialPolicy.isValidPassword(password)
    }
}

public enum XanhCredentialPolicy {
    public static let maximumResults = 100
    public static let maximumOutputBytes = 4 * 1_024 * 1_024
    public static let maximumIDBytes = 128
    public static let maximumUsernameBytes = 1_024
    public static let maximumPasswordBytes = 4_096
    public static let maximumFieldBytes = 256

    public static func isValidID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumIDBytes
            && value.unicodeScalars.allSatisfy {
                let scalar = $0.value
                return (scalar >= 48 && scalar <= 57)
                    || (scalar >= 65 && scalar <= 90)
                    || (scalar >= 97 && scalar <= 122)
                    || scalar == 45
                    || scalar == 95
            }
    }

    public static func isValidUsername(_ value: String) -> Bool {
        value.utf8.count <= maximumUsernameBytes && !value.contains("\0")
    }

    public static func isValidPassword(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumPasswordBytes
            && !value.contains("\0")
    }

    public static func isValidField(_ value: String) -> Bool {
        value.utf8.count <= maximumFieldBytes
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

extension URL {
    var xanhIsSecureHTTPS: Bool {
        scheme?.lowercased() == "https" && host != nil && user == nil && password == nil
    }

    var xanhIsSecureOrigin: Bool {
        xanhIsSecureHTTPS
            && (path.isEmpty || path == "/")
            && query == nil
            && fragment == nil
    }

    var xanhOrigin: String? {
        guard let scheme = scheme?.lowercased(), let host = host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(port ?? (scheme == "https" ? 443 : -1))"
    }

    var xanhCanonicalOrigin: String? {
        guard xanhIsSecureOrigin,
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        components.scheme = "https"
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        if components.port == 443 { components.port = nil }
        return components.string
    }
}
