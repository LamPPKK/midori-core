import Foundation

public struct BrowserSession: Codable, Equatable, Sendable {
    public static let maximumTabCount = 20

    public var urls: [URL]
    public var selectedIndex: Int

    public init(urls: [URL], selectedIndex: Int) {
        let safeURLs = Array(
            urls.lazy
                .filter(AddressResolver.isAllowedWebURL)
                .prefix(Self.maximumTabCount)
        )
        self.urls = safeURLs.isEmpty ? [AddressResolver.defaultHomePage] : safeURLs
        self.selectedIndex = min(max(selectedIndex, 0), self.urls.count - 1)
    }

    public static func decode(_ data: Data?) -> BrowserSession? {
        guard let data, let decoded = try? JSONDecoder().decode(BrowserSession.self, from: data) else {
            return nil
        }
        return BrowserSession(urls: decoded.urls, selectedIndex: decoded.selectedIndex)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
