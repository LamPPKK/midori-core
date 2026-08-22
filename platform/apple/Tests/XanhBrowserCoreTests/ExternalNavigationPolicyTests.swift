import Foundation
import XCTest
@testable import XanhBrowserCore

final class ExternalNavigationPolicyTests: XCTestCase {
    private let safeURL = URL(string: "mailto:hello@example.com")!

    func testAllowsDirectTrustedMainFrameExternalLink() {
        XCTAssertTrue(allows())
    }

    func testRejectsEveryMissingTrustOrFrameSignal() {
        XCTAssertFalse(allows(isLinkActivated: false))
        XCTAssertFalse(allows(sourceIsMainFrame: false))
        XCTAssertFalse(allows(targetIsMainFrameOrNewWindow: false))
        XCTAssertFalse(allows(hasTrustedButtonActivation: false))
        XCTAssertFalse(allows(isContentRuleListRedirect: true))
    }

    func testRejectsUnsafeExternalURLBeforeHandoff() {
        XCTAssertFalse(allows(url: URL(string: "mailto:hello@example.com?subject=x%0d%0aBcc:x@y.test")!))
        XCTAssertFalse(allows(url: URL(string: "javascript:alert(1)")!))
    }

    private func allows(
        url: URL? = nil,
        isLinkActivated: Bool = true,
        sourceIsMainFrame: Bool = true,
        targetIsMainFrameOrNewWindow: Bool = true,
        hasTrustedButtonActivation: Bool = true,
        isContentRuleListRedirect: Bool = false
    ) -> Bool {
        ExternalNavigationPolicy.allows(
            url: url ?? safeURL,
            isLinkActivated: isLinkActivated,
            sourceIsMainFrame: sourceIsMainFrame,
            targetIsMainFrameOrNewWindow: targetIsMainFrameOrNewWindow,
            hasTrustedButtonActivation: hasTrustedButtonActivation,
            isContentRuleListRedirect: isContentRuleListRedirect
        )
    }
}
