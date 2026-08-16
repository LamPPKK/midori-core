import Foundation

public enum NavigationTarget: Equatable, Sendable {
    case web(URL)
    case external(URL)
}

public enum AddressResolver {
    public static let defaultHomePage = URL(string: "https://duckduckgo.com/")!

    public static func resolve(_ input: String) -> NavigationTarget? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let explicit = URL(string: value), explicit.scheme != nil {
            return classify(explicit)
        }

        if looksLikeHost(value), let url = URL(string: "https://\(value)") {
            return classify(url)
        }

        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: value)]
        return components.url.map(NavigationTarget.web)
    }

    public static func isAllowedWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return url.absoluteString == "about:blank" }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    private static func classify(_ url: URL) -> NavigationTarget? {
        if isAllowedWebURL(url) { return .web(url) }

        switch url.scheme?.lowercased() {
        case "mailto", "tel", "sms", "maps":
            return .external(url)
        default:
            return nil
        }
    }

    private static func looksLikeHost(_ value: String) -> Bool {
        guard !value.contains(where: { $0.isWhitespace }) else { return false }
        let candidate = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        return candidate == "localhost" || candidate.contains(".")
    }
}
