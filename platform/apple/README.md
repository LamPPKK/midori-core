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
