# Xanh Browser for Apple platforms

This directory contains the shared SwiftUI/WebKit application for macOS 26,
iOS 26 and iPadOS 26. The iOS target is universal (`TARGETED_DEVICE_FAMILY`
1 and 2), so the same signed binary supports iPhone and iPad while adopting the
native layout of each device.

The application uses the system WebKit engine through `WebPage` and `WebView`.
It does not bundle a browser engine. Regular tabs use the default website data
store; private tabs use a nonpersistent store. Navigation entered by the user
accepts HTTP(S), upgrades bare hosts to HTTPS, turns other text into a
DuckDuckGo search and hands a small allowlist of user-activated external
schemes to the OS. Regular tabs are restored after process termination;
private tabs are deliberately excluded from the saved session.

Generate the Xcode project and run tests with Xcode 26 or newer:

```sh
cd platform/apple
xcodegen generate
swift test
xcodebuild -project XanhBrowserApple.xcodeproj \
  -scheme XanhBrowser-macOS -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project XanhBrowserApple.xcodeproj \
  -scheme XanhBrowser-iOS -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

Store distribution still requires Apple Developer signing, the browser-app
entitlement where applicable, privacy declarations, App Store listings and
device testing. No signing material belongs in this repository.

## Firefox Sync host

The shared app contains the Apple Firefox Sync coordinator and settings UI for
macOS, iOS and iPadOS. OAuth always opens in the system browser and returns via
an edition-specific URL callback:

- macOS: `xanh-browser-macos://accounts/oauth`
- iOS/iPadOS: `xanh-browser-ios://accounts/oauth`

Opaque account/Sync state is stored in non-synchronizing, device-only Keychain
items. The local Logins key additionally requires LocalAuthentication and the
vault locks after five minutes or when the scene leaves the foreground. A
disconnect retry preserves the original keep/delete choice across restart.

Ordinary verification builds deliberately do not contain Mozilla's native
runtime. A Sync release must package the pinned
`MozillaRustComponents.xcframework`, its reviewed generated Swift binding and
checksum, then compile the adapter with
`XANH_SYNC_SWIFT_FLAGS=-DXANH_ENABLE_FIREFOX_SYNC`. Set
`XANH_FXA_CLIENT_ID` and `XANH_FXA_PRODUCTION_APPROVED=1` only for a client ID
with written Mozilla approval; otherwise ship the explicitly self-hosted path.
The release remains blocked until `../../scripts/verify-sync-release.sh apple`
and the interoperability/security matrix pass.
