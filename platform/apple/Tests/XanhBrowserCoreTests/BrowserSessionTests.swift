import Foundation
import XCTest
@testable import XanhBrowserCore

final class BrowserSessionTests: XCTestCase {
    func testSessionRoundTrip() throws {
        let session = BrowserSession(
            urls: [URL(string: "https://example.com/")!, URL(string: "https://webkit.org/")!],
            selectedIndex: 1
        )

        XCTAssertEqual(BrowserSession.decode(try XCTUnwrap(session.encoded())), session)
    }

    func testSessionRejectsUnsafeURLsAndClampsSelection() {
        let session = BrowserSession(
            urls: [
                URL(fileURLWithPath: "/tmp/private"),
                URL(string: "https://user:secret@example.com/")!,
                URL(string: "https://foo_bar.example/")!,
                URL(string: "https://example.com/")!,
            ],
            selectedIndex: 9
        )

        XCTAssertEqual(session.urls, [URL(string: "https://example.com/")!])
        XCTAssertEqual(session.selectedIndex, 0)
    }

    func testEmptySessionUsesHomePage() {
        let session = BrowserSession(urls: [], selectedIndex: -1)
        XCTAssertEqual(session.urls, [AddressResolver.defaultHomePage])
        XCTAssertEqual(session.selectedIndex, 0)
    }
}
