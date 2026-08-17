import Foundation
import Testing
@testable import XanhBrowserCore

@Test func selfHostedSyncRequiresHTTPS() throws {
    #expect(throws: XanhSyncContractError.self) {
        try XanhSyncConfiguration(
            server: .selfHosted(
                accountsURL: #require(URL(string: "http://accounts.example")),
                tokenServerURL: #require(URL(string: "https://sync.example/token"))
            ),
            clientID: "client",
            redirectURI: #require(URL(string: "xanh-browser://accounts/oauth")),
            deviceName: "Xanh Browser"
        )
    }
}

@Test func oauthRedirectRejectsAmbiguousCallbacks() throws {
    let base = try XanhSyncConfiguration(
        server: .mozilla,
        clientID: "client",
        redirectURI: #require(URL(string: "xanh-browser://accounts/oauth")),
        deviceName: "Xanh Browser"
    )
    try base.validate()
    for value in [
        "http://example.test/oauth",
        "javascript:alert(1)",
        "xanh-browser://user@accounts/oauth",
        "xanh-browser://accounts/oauth#secret",
    ] {
        #expect(throws: XanhSyncContractError.self) {
            try XanhSyncConfiguration(
                server: .mozilla,
                clientID: "client",
                redirectURI: #require(URL(string: value)),
                deviceName: "Xanh Browser"
            )
        }
    }
}

@Test func syncScheduleDebouncesAndHonorsBackoff() {
    let now = Date(timeIntervalSince1970: 1_000)
    var schedule = XanhSyncSchedule(localChange: now)
    #expect(!schedule.isDue(reason: .localChange, now: now.addingTimeInterval(29)))
    #expect(schedule.isDue(reason: .localChange, now: now.addingTimeInterval(30)))
    schedule.nextAllowed = now.addingTimeInterval(100)
    #expect(!schedule.isDue(reason: .manual, now: now.addingTimeInterval(99)))
}

@Test func credentialPolicyDeniesPrivateHTTPAndCrossOriginFrames() throws {
    let valid = XanhCredentialContext(
        documentURL: try #require(URL(string: "https://example.org/login")),
        topFrameOrigin: try #require(URL(string: "https://example.org")),
        frameOrigin: try #require(URL(string: "https://example.org")),
        isPrivate: false,
        userSelected: true
    )
    #expect(valid.isAllowed)
    let evilOrigin = try #require(URL(string: "https://evil.example"))
    #expect(!XanhCredentialContext(
        documentURL: valid.documentURL,
        topFrameOrigin: valid.topFrameOrigin,
        frameOrigin: evilOrigin,
        isPrivate: false,
        userSelected: true
    ).isAllowed)
}
