import Foundation

public struct Bookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var url: URL

    public init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}
