import Foundation
import XCTest
@testable import XanhBrowserCore

final class AdblockHostTests: XCTestCase {
    func testPreferenceDefaultsOn() {
        XCTAssertTrue(AdblockHostPolicy.isEnabled(storedValue: nil))
        XCTAssertTrue(AdblockHostPolicy.isEnabled(storedValue: true))
        XCTAssertFalse(AdblockHostPolicy.isEnabled(storedValue: false))
        XCTAssertTrue(AdblockHostPolicy.isEnabled(storedValue: "false"))
    }

    func testNativeCandidatesStayWithinSuppliedBundleLocations() {
        let candidates = AdblockHostPolicy.nativeLibraryCandidates(
            resourceURL: URL(fileURLWithPath: "/Application/Resources", isDirectory: true),
            privateFrameworksURL: URL(fileURLWithPath: "/Application/Frameworks", isDirectory: true),
            executableURL: URL(fileURLWithPath: "/Application/MacOS/Xanh Browser")
        )

        XCTAssertEqual(
            candidates.map(\.path),
            [
                "/Application/Frameworks/xanh_adblock_core.framework/xanh_adblock_core",
                "/Application/Resources/libxanh_adblock_core.dylib",
                "/Application/MacOS/libxanh_adblock_core.dylib",
            ]
        )
    }

    func testCompiledRuleListValidationIsBounded() {
        XCTAssertTrue(
            AdblockHostPolicy.acceptsCompiledRuleList(
                #"[{"trigger":{"url-filter":"ads"},"action":{"type":"block"}}]"#
            )
        )
        XCTAssertFalse(AdblockHostPolicy.acceptsCompiledRuleList("[]"))
        XCTAssertFalse(AdblockHostPolicy.acceptsCompiledRuleList(""))
        XCTAssertFalse(AdblockHostPolicy.acceptsCompiledRuleList("[\u{0}]"))
        XCTAssertFalse(
            AdblockHostPolicy.acceptsCompiledRuleList(
                byteCount: AdblockHostPolicy.maximumCompiledRuleListBytes + 1,
                containsNUL: false
            )
        )
    }

    func testOnlyExpectedNativeVersionIsAccepted() {
        XCTAssertTrue(
            AdblockHostPolicy.acceptsNativeVersion(AdblockHostPolicy.expectedNativeVersion)
        )
        XCTAssertFalse(AdblockHostPolicy.acceptsNativeVersion(nil))
        XCTAssertFalse(AdblockHostPolicy.acceptsNativeVersion("1.0.0-alpha.0"))
        XCTAssertFalse(AdblockHostPolicy.acceptsNativeVersion("1.0.0"))
    }

    func testMissingNativeLibraryFailsOpen() {
        XCTAssertNil(
            NativeAdblockCompiler.compileDefaultWebKitRuleList(
                libraryPaths: ["/definitely/missing/libxanh_adblock_core.dylib"]
            )
        )
    }
}
