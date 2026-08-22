import Foundation
import XCTest
@testable import XanhBrowserCore

final class WebContentProcessRecoveryPolicyTests: XCTestCase {
    func testRecoveryUsesCurrentValidatedURLAsFreshGET() {
        var policy = WebContentProcessRecoveryPolicy()
        let current = URL(string: "https://example.com/current?value=1")!

        XCTAssertTrue(policy.recordTermination(currentURL: current, address: "https://fallback.test/"))
        let request = policy.takeRecoveryRequest(isForeground: true)

        XCTAssertEqual(request?.url, current)
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertNil(request?.httpBody)
        XCTAssertNil(request?.httpBodyStream)
        XCTAssertEqual(request?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertTrue(policy.automaticRecoveryUsed)
        XCTAssertTrue(policy.recoveryInProgress)
        XCTAssertNil(policy.pendingURL)

        policy.markRecoveryCommitted()
        XCTAssertFalse(policy.recoveryInProgress)
    }

    func testRecoveryWaitsForForegroundWithoutConsumingBudget() {
        var policy = WebContentProcessRecoveryPolicy()
        let current = URL(string: "https://example.com/")!

        XCTAssertTrue(policy.recordTermination(currentURL: current, address: ""))
        XCTAssertNil(policy.takeRecoveryRequest(isForeground: false))
        XCTAssertFalse(policy.automaticRecoveryUsed)
        XCTAssertEqual(policy.pendingURL, current)
        XCTAssertEqual(policy.takeRecoveryRequest(isForeground: true)?.url, current)
    }

    func testBackgroundingCancelsAnInFlightAttemptWithoutGrantingAnother() {
        var policy = WebContentProcessRecoveryPolicy()
        let current = URL(string: "https://example.com/")!

        XCTAssertTrue(policy.recordTermination(currentURL: current, address: ""))
        XCTAssertNotNil(policy.takeRecoveryRequest(isForeground: true))
        XCTAssertTrue(policy.cancelInFlightRecoveryForBackground())
        XCTAssertFalse(policy.recoveryInProgress)
        XCTAssertTrue(policy.automaticRecoveryUsed)
        XCTAssertNil(policy.takeRecoveryRequest(isForeground: true))
    }

    func testSecondTerminationStopsUntilExplicitUserNavigation() {
        var policy = WebContentProcessRecoveryPolicy()
        let current = URL(string: "https://example.com/")!

        XCTAssertTrue(policy.recordTermination(currentURL: current, address: ""))
        XCTAssertNotNil(policy.takeRecoveryRequest(isForeground: true))
        XCTAssertFalse(policy.recordTermination(currentURL: current, address: ""))
        XCTAssertNil(policy.takeRecoveryRequest(isForeground: true))

        policy.resetForExplicitUserNavigation()
        XCTAssertFalse(policy.recoveryInProgress)
        XCTAssertTrue(policy.recordTermination(currentURL: current, address: ""))
        XCTAssertNotNil(policy.takeRecoveryRequest(isForeground: true))
    }

    func testUnsafeCurrentURLFallsBackToValidatedAddress() {
        var policy = WebContentProcessRecoveryPolicy()

        XCTAssertTrue(
            policy.recordTermination(
                currentURL: URL(string: "https://user:secret@example.com/")!,
                address: "example.org/path"
            )
        )

        XCTAssertEqual(
            policy.takeRecoveryRequest(isForeground: true)?.url,
            URL(string: "https://example.org/path")!
        )
    }

    func testUnsafeCurrentURLAndAddressFallBackToHome() {
        var policy = WebContentProcessRecoveryPolicy()

        XCTAssertTrue(
            policy.recordTermination(
                currentURL: URL(fileURLWithPath: "/tmp/form-state"),
                address: "https://foo_bar.example/"
            )
        )

        XCTAssertEqual(
            policy.takeRecoveryRequest(isForeground: true)?.url,
            AddressResolver.defaultHomePage
        )
    }
}
