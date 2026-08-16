import Foundation
import XCTest
@testable import XanhBrowserCore

final class AddressResolverTests: XCTestCase {
    func testAcceptsHTTPS() {
        XCTAssertEqual(
            AddressResolver.resolve("https://example.com/path"),
            .web(URL(string: "https://example.com/path")!)
        )
    }

    func testUpgradesBareHost() {
        XCTAssertEqual(
            AddressResolver.resolve("example.com/docs"),
            .web(URL(string: "https://example.com/docs")!)
        )
    }

    func testResolvesSearch() {
        guard case let .web(url)? = AddressResolver.resolve("xanh browser privacy") else {
            XCTFail("Expected a web search target")
            return
        }
        XCTAssertEqual(url.host, "duckduckgo.com")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
            "xanh browser privacy"
        )
    }

    func testAllowsExternalSchemes() {
        XCTAssertEqual(
            AddressResolver.resolve("mailto:hello@example.com"),
            .external(URL(string: "mailto:hello@example.com")!)
        )
        XCTAssertTrue(AddressResolver.isAllowedExternalURL(URL(string: "tel:+84123456789")!))
        XCTAssertFalse(AddressResolver.isAllowedExternalURL(URL(string: "javascript:alert(1)")!))
    }

    func testRejectsUnsafeInput() {
        for input in ["javascript:alert(1)", "file:///etc/passwd", "https:///missing-host"] {
            XCTAssertNil(AddressResolver.resolve(input), "Expected to reject \(input)")
        }
    }
}
