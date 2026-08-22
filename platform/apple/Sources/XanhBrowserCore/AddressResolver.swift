import Darwin
import Foundation

public enum NavigationTarget: Equatable, Sendable {
    case web(URL)
    case external(URL)
}

public enum AddressResolver {
    public static let defaultHomePage = URL(string: "https://duckduckgo.com/")!
    public static let maximumWebURLBytes = 8_192
    public static let maximumExternalURLBytes = 2_048

    private static let externalSchemes = Set(["mailto", "tel", "sms", "maps"])

    public static func resolve(_ input: String) -> NavigationTarget? {
        guard isWithinUTF8Limit(input, maximumWebURLBytes),
              !containsControlCharacters(input) else { return nil }
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
        guard let searchURL = components.url,
              isAllowedWebURL(searchURL) else { return nil }
        return .web(searchURL)
    }

    public static func isAllowedWebURL(_ url: URL) -> Bool {
        let value = url.absoluteString
        guard isWithinUTF8Limit(value, maximumWebURLBytes),
              !containsControlCharacters(value),
              !containsPercentEncodedControl(value),
              let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return value.lowercased() == "about:blank" }
        guard scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port.map({ (1...65_535).contains($0) }) ?? true else { return false }
        return hasValidHost(url)
    }

    public static func isAllowedExternalURL(_ url: URL) -> Bool {
        let value = url.absoluteString
        guard let scheme = url.scheme?.lowercased(),
              externalSchemes.contains(scheme),
              isWithinUTF8Limit(value, maximumExternalURLBytes),
              !containsControlCharacters(value),
              !containsWhitespace(value),
              !containsPercentEncodedControl(value, includingSpace: true),
              let separator = value.firstIndex(of: ":"),
              value.index(after: separator) < value.endIndex else { return false }
        return true
    }

    private static func classify(_ url: URL) -> NavigationTarget? {
        if isAllowedWebURL(url) { return .web(url) }

        if isAllowedExternalURL(url) {
            return .external(url)
        }
        return nil
    }

    private static func looksLikeHost(_ value: String) -> Bool {
        guard !value.contains(where: { $0.isWhitespace }) else { return false }
        let candidate = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        return candidate == "localhost" || candidate.contains(".")
    }

    private static func hasValidHost(_ url: URL) -> Bool {
        guard var host = url.host(percentEncoded: true), !host.isEmpty else { return false }

        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if host.contains(":") {
            guard !host.contains("%") else { return false }
            var address = in6_addr()
            return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        }

        if host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty,
              host.utf8.count <= 253,
              host.utf8.allSatisfy({ $0 < 0x80 }) else { return false }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty,
              labels.allSatisfy(isValidDNSLabel) else { return false }

        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            guard labels.count == 4 else { return false }
            return labels.allSatisfy { label in
                guard label.count == 1 || label.first != "0",
                      UInt8(label) != nil else { return false }
                return true
            }
        }
        return true
    }

    private static func isValidDNSLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty,
              label.utf8.count <= 63,
              label.first != "-",
              label.last != "-" else { return false }
        return label.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
        }
    }

    private static func containsPercentEncodedControl(
        _ value: String,
        includingSpace: Bool = false
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 3 else { return false }
        for index in 0..<(bytes.count - 2) where bytes[index] == 0x25 {
            guard let high = hexNibble(bytes[index + 1]),
                  let low = hexNibble(bytes[index + 2]) else { continue }
            let decoded = high << 4 | low
            if decoded < 0x20 || decoded == 0x7F || (includingSpace && decoded == 0x20) {
                return true
            }
        }
        return false
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func containsWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isWithinUTF8Limit(_ value: String, _ limit: Int) -> Bool {
        value.utf8.count <= limit
    }
}
