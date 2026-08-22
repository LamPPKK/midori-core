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
        for input in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "https:///missing-host",
            "https://user:secret@example.com/",
            "https://foo_bar.example/",
            "https://example.com:70000/",
            "https://-invalid.example/",
            "https://127.1/",
            "https://999.1.1.1/",
            "https://[not:ipv6]/",
            "https://[1:2:3:4:5:6:7:8:]/",
            "https://example.com/%0d%0aHeader:value",
        ] {
            XCTAssertNil(AddressResolver.resolve(input), "Expected to reject \(input)")
        }
    }

    func testAcceptsCanonicalIDNAndIPHosts() {
        XCTAssertNotNil(AddressResolver.resolve("https://bücher.example/"))
        XCTAssertNotNil(AddressResolver.resolve("https://127.0.0.1/"))
        XCTAssertNotNil(AddressResolver.resolve("https://[::1]/"))
        XCTAssertNotNil(AddressResolver.resolve("http://localhost:8080/"))
        XCTAssertNotNil(AddressResolver.resolve("https://example.com/a%20b"))
    }

    func testRejectsOversizedWebInputAndSearchOutput() {
        XCTAssertNil(AddressResolver.resolve("https://example.com/" + String(repeating: "a", count: 8_193)))
        XCTAssertNil(AddressResolver.resolve(String(repeating: "語", count: 3_000)))
    }

    func testRejectsUnsafeExternalURLs() {
        for value in [
            "mailto:hello@example.com?subject=x%0d%0aBcc:test@example.com",
            "tel:%00+84123456789",
            "mailto:hello%7F@example.com",
            "mailto:hello example@example.com",
            "mailto:",
        ] {
            let url = URL(string: value)!
            XCTAssertFalse(AddressResolver.isAllowedExternalURL(url), "Expected to reject \(value)")
        }
    }

    func testRejectsOversizedExternalURL() {
        let value = "mailto:user@example.com?subject=" + String(repeating: "a", count: 2_049)
        XCTAssertFalse(AddressResolver.isAllowedExternalURL(URL(string: value)!))
    }
}
