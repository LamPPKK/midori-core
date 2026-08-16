import Foundation
import XCTest
@testable import XanhBrowserCore

final class BookmarkTests: XCTestCase {
    func testBookmarkRoundTrip() throws {
        let bookmark = Bookmark(
            id: UUID(uuidString: "A1904B02-6EA9-4CBA-A801-CED5D915F767")!,
            title: "Xanh Browser",
            url: URL(string: "https://example.com/")!
        )
        let data = try JSONEncoder().encode(bookmark)
        XCTAssertEqual(try JSONDecoder().decode(Bookmark.self, from: data), bookmark)
    }
}
