import Foundation

public struct WebContentProcessRecoveryPolicy: Sendable {
    public private(set) var automaticRecoveryUsed = false
    public private(set) var pendingURL: URL?
    public private(set) var recoveryInProgress = false

    public init() {}

    @discardableResult
    public mutating func recordTermination(currentURL: URL?, address: String) -> Bool {
        guard !automaticRecoveryUsed else {
            pendingURL = nil
            recoveryInProgress = false
            return false
        }

        pendingURL = Self.safeTarget(currentURL: currentURL, address: address)
        return true
    }

    public mutating func takeRecoveryRequest(isForeground: Bool) -> URLRequest? {
        guard isForeground,
              !automaticRecoveryUsed,
              let pendingURL else { return nil }

        self.pendingURL = nil
        automaticRecoveryUsed = true
        recoveryInProgress = true

        var request = URLRequest(
            url: pendingURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        request.httpMethod = "GET"
        request.httpBody = nil
        request.httpBodyStream = nil
        return request
    }

    public mutating func resetForExplicitUserNavigation() {
        automaticRecoveryUsed = false
        pendingURL = nil
        recoveryInProgress = false
    }

    public mutating func markRecoveryCommitted() {
        recoveryInProgress = false
    }

    public mutating func markRecoveryFailed() {
        recoveryInProgress = false
    }

    public mutating func cancelInFlightRecoveryForBackground() -> Bool {
        guard recoveryInProgress else { return false }
        recoveryInProgress = false
        return true
    }

    private static func safeTarget(currentURL: URL?, address: String) -> URL {
        if let currentURL, AddressResolver.isAllowedWebURL(currentURL) {
            return currentURL
        }
        if case let .web(url)? = AddressResolver.resolve(address) {
            return url
        }
        return AddressResolver.defaultHomePage
    }
}
