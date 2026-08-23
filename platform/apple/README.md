# Xanh Browser for Apple platforms

This directory contains the shared SwiftUI/WebKit application for macOS 26,
iOS 26 and iPadOS 26. The iOS target is universal (`TARGETED_DEVICE_FAMILY`
1 and 2), so the same signed binary supports iPhone and iPad while adopting the
native layout of each device.

The application uses the system WebKit engine through `WebPage` and `WebView`.
It does not bundle a browser engine. Regular tabs use the default website data
store; private tabs use a nonpersistent store. Navigation entered by the user
accepts bounded HTTP(S) URLs with strict host, port and userinfo validation,
upgrades bare hosts to HTTPS, and turns other bounded text into a DuckDuckGo
search. External `mailto`, `tel`, `sms` and `maps` URLs are handed to the OS
only for a non-redirected, trusted link activation from the main frame; control
characters, encoded controls and oversized handoffs fail closed. Regular tabs
are restored after process termination; private tabs are deliberately excluded
from the saved session.

If WebKit reports that a tab's web-content process terminated, Xanh attempts at
most one automatic recovery while the scene is active. Recovery creates a new
body-free GET request for the bounded, userinfo-free current URL, validated
address or home page; it never invokes `reload()` or restores a back-forward
form item.
The attempt is stopped if the app leaves the foreground before commit, and a
second termination requires an explicit reload or address navigation.

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

The PKCE verifier and expected OAuth `state` remain in the coordinator's memory
only. A callback is accepted only for the process flow that started that exact
state; mismatched state, replay after consumption, or delivery after process
restart fails before native completion. Identical concurrent delivery to more
than one scene is coalesced into one native completion. Because Application Services does not
persist its pending PKCE flow, the user must start a fresh sign-in after a
restart or an ambiguous native completion failure. Canceling the origin prompt
does not start a flow; if the system browser refuses to open after a confirmed
start, Xanh discards the in-memory runtime and reopens only previously committed
state so the user can retry safely. The authorization URL must match the exact
configured HTTPS Accounts origin, including a non-default port. Every Apple
scene shares a process-wide Sync service and account snapshot, preventing a
second window from claiming the flow, while settings and credential picker
state remain private to their originating scene. A shared vault-lock transition
immediately dismisses and clears password rows/editors in every scene.

Opaque account/Sync state is stored in non-synchronizing, device-only Keychain
items. The local Logins key additionally requires LocalAuthentication and the
vault locks after five minutes or when the scene leaves the foreground. A
disconnect retry preserves the original keep/delete choice across restart.
Remote Tabs records are decoded into a bounded typed model (100 devices, 500
total tabs and an 8 MiB aggregate payload), grouped by device and sanitized for
native display. Unsafe URLs, duplicate identities and out-of-range timestamps
fail closed. Receiving or refreshing the list never navigates; a regular tab is
created only after the user chooses one specific safe HTTP(S) row.

The native Places library loads all four Firefox bookmark roots into a bounded
typed model (10,000 records and 16 MiB), and loads at most 500 recent history
visits within an 8 MiB boundary. Bookmark rename/delete preserves the selected
12-character Places GUID; history delete preserves the selected canonical URL
and exact millisecond timestamp. Completed regular navigations are recorded as
link visits. Private tabs are rejected before bookmark or history mutations,
and unsafe records remain inert rather than being opened through a fallback.

Regular tabs install a main-frame-only password-fill script in a named
`WKContentWorld`. The page world cannot read its tab ID, per-navigation nonce
or native credential payload. Only a trusted pointer/keyboard action on a
password field can open the native picker; the host revalidates the exact HTTPS
document and origin before querying Logins and again before filling. Private
tabs do not install the script or message handler. A selection may require
Face ID, Touch ID or the device passcode through LocalAuthentication.

The Sync settings also expose a native password library for the currently
selected regular HTTPS site. It lists at most 100 bounded Logins records and can
add, update or confirm-delete the selected exact native login ID. Username and
password drafts use the same shared 1,024/4,096-byte policy as Rust; passwords
remain masked. The host re-reads the current tab context before and after vault
unlock, query and mutation, so navigation or a tab switch clears stale rows
instead of retargeting them. Private and non-HTTPS tabs cannot open the library,
and scene/background vault locking clears its presented credential values.

Ordinary verification builds deliberately do not contain Mozilla's native
runtime. A Sync release must package the pinned
`MozillaRustComponents.xcframework`, its reviewed generated Swift binding and
checksum, then compile the adapter with
`XANH_SYNC_SWIFT_FLAGS=-DXANH_ENABLE_FIREFOX_SYNC`. Set
`XANH_FXA_CLIENT_ID` and `XANH_FXA_PRODUCTION_APPROVED=1` only for a client ID
with written Mozilla approval; otherwise ship the explicitly self-hosted path.
The release remains blocked until `../../scripts/verify-sync-release.sh apple`
and the forged-message, stale-navigation, process-recovery,
LocalAuthentication, interoperability and device security matrices pass.
