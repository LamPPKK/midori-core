import Foundation

public enum XanhBookmarkRoot: String, CaseIterable, Codable, Hashable, Sendable {
    case menu
    case toolbar
    case unfiled
    case mobile
}

public enum XanhBookmarkKind: String, Codable, Hashable, Sendable {
    case bookmark
    case folder
    case separator
}

public enum XanhHistoryTransition: String, Codable, Hashable, Sendable {
    case link
    case typed
    case bookmark
    case redirectPermanent
    case redirectTemporary
    case download
    case reload
}

public struct XanhBookmarkRecord: Codable, Hashable, Identifiable, Sendable {
    public let guid: String
    public let parentGUID: String?
    public let position: UInt32
    public let kind: XanhBookmarkKind
    public let title: String?
    public let rawURL: String?
    public let isOpenable: Bool
    public let dateAddedEpochMillis: Int64
    public let lastModifiedEpochMillis: Int64

    public init(
        guid: String,
        parentGUID: String?,
        position: UInt32,
        kind: XanhBookmarkKind,
        title: String?,
        rawURL: String?,
        isOpenable: Bool,
        dateAddedEpochMillis: Int64,
        lastModifiedEpochMillis: Int64
    ) {
        self.guid = guid
        self.parentGUID = parentGUID
        self.position = position
        self.kind = kind
        self.title = title
        self.rawURL = rawURL
        self.isOpenable = isOpenable
        self.dateAddedEpochMillis = dateAddedEpochMillis
        self.lastModifiedEpochMillis = lastModifiedEpochMillis
    }

    public var id: String { guid }

    public var openableURL: URL? {
        guard isOpenable,
              let rawURL,
              let url = URL(string: rawURL),
              XanhPlacesPolicy.isAllowedWebURL(url) else { return nil }
        return url
    }

    public var displayTitle: String {
        XanhPlacesPolicy.sanitizedDisplayText(
            title,
            fallback: openableURL?.host ?? "Untitled bookmark"
        )
    }

    public var isSafe: Bool {
        guard XanhPlacesPolicy.isGUID(guid),
              parentGUID.map(XanhPlacesPolicy.isGUID) ?? true,
              XanhPlacesPolicy.isSafeTitle(title),
              XanhPlacesPolicy.isSafeTimestamp(dateAddedEpochMillis, allowZero: true),
              XanhPlacesPolicy.isSafeTimestamp(lastModifiedEpochMillis, allowZero: true) else {
            return false
        }
        return XanhPlacesPolicy.isSafeBookmarkURL(
            kind: kind,
            rawURL: rawURL,
            isOpenable: isOpenable
        )
    }
}

public struct XanhHistoryVisitRecord: Codable, Hashable, Identifiable, Sendable {
    public let url: URL
    public let title: String?
    public let visitedAtEpochMillis: Int64
    public let transition: XanhHistoryTransition
    public let isRemote: Bool

    public init(
        url: URL,
        title: String?,
        visitedAtEpochMillis: Int64,
        transition: XanhHistoryTransition,
        isRemote: Bool
    ) {
        self.url = url
        self.title = title
        self.visitedAtEpochMillis = visitedAtEpochMillis
        self.transition = transition
        self.isRemote = isRemote
    }

    public var id: String { "\(visitedAtEpochMillis)|\(url.absoluteString)" }

    public var displayTitle: String {
        XanhPlacesPolicy.sanitizedDisplayText(title, fallback: url.host ?? url.absoluteString)
    }

    public var isSafe: Bool {
        XanhPlacesPolicy.isAllowedWebURL(url)
            && XanhPlacesPolicy.isSafeTitle(title)
            && XanhPlacesPolicy.isSafeTimestamp(visitedAtEpochMillis, allowZero: false)
    }
}

public struct XanhHistoryUpdateResult: Equatable, Sendable {
    public let acceptedCount: UInt32
    public let skippedPrivateCount: UInt32

    public init(acceptedCount: UInt32, skippedPrivateCount: UInt32) {
        self.acceptedCount = acceptedCount
        self.skippedPrivateCount = skippedPrivateCount
    }
}

public enum XanhPlacesPolicy {
    public static let maximumBookmarkRecords = 10_000
    public static let maximumHistoryResults = 500
    public static let maximumBookmarkPayloadBytes = 16 * 1_024 * 1_024
    public static let maximumHistoryPayloadBytes = 8 * 1_024 * 1_024
    public static let maximumTitleUTF8Bytes = 4_096
    public static let maximumURLUTF8Bytes = 8_192
    public static let maximumEpochMillis: Int64 = 253_402_300_799_999

    public static func isGUID(_ value: String) -> Bool {
        value.utf8.count == 12 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
                || byte == 0x5F
        }
    }

    public static func isAllowedWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return AddressResolver.isAllowedWebURL(url)
            && url.absoluteString.utf8.count <= maximumURLUTF8Bytes
    }

    public static func isSafeTitle(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= maximumTitleUTF8Bytes
            && !value.unicodeScalars.contains {
                $0.properties.generalCategory == .control
            }
    }

    public static func isSafeTimestamp(_ value: Int64, allowZero: Bool) -> Bool {
        value <= maximumEpochMillis && (allowZero ? value >= 0 : value > 0)
    }

    public static func sanitizeTitle(_ value: String?, fallback: String) -> String {
        let candidate = value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let source = candidate.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        var output: [Unicode.Scalar] = []
        var outputBytes = 0
        var pendingSpace = false

        for scalar in source.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !output.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .control { continue }
            let scalarBytes = String(scalar).utf8.count
            let separatorBytes = pendingSpace ? 1 : 0
            guard outputBytes + separatorBytes + scalarBytes <= maximumTitleUTF8Bytes else { break }
            if pendingSpace {
                output.append(" ")
                outputBytes += 1
                pendingSpace = false
            }
            output.append(scalar)
            outputBytes += scalarBytes
        }

        let sanitized = String(String.UnicodeScalarView(output))
        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    public static func sanitizedDisplayText(_ value: String?, fallback: String) -> String {
        let bounded = sanitizeTitle(value, fallback: fallback)
        let scalars = bounded.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .format, .lineSeparator, .paragraphSeparator:
                false
            default:
                true
            }
        }
        let sanitized = String(String.UnicodeScalarView(scalars))
        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    static func isSafeBookmarkURL(
        kind: XanhBookmarkKind,
        rawURL: String?,
        isOpenable: Bool
    ) -> Bool {
        guard kind == .bookmark else { return rawURL == nil && !isOpenable }
        guard let rawURL,
              rawURL.utf8.count <= maximumURLUTF8Bytes,
              !rawURL.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control
              }),
              URL(string: rawURL) != nil else { return false }
        guard isOpenable else { return true }
        guard let url = URL(string: rawURL) else { return false }
        return isAllowedWebURL(url)
    }
}
