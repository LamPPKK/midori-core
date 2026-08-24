# Xanh Browser

Xanh Browser is a privacy-minded browser family built around native platform
web engines. This repository contains the Linux desktop browser, native Apple
and Windows editions, and the small single-tab Android edition, Xanh Browser
Lite.

> **Release status:** Linux and Android Lite 1.0.0 are release candidates. The
> Apple, Windows and experimental WebKit editions are 1.0.0 preview
> candidates. CI produces unsigned verification artifacts only; production
> artifacts must not be published until the signing, device, security and store gates in
> [RELEASING.md](RELEASING.md) are complete.

## Editions

| Product | Application ID | Platform | Current version |
| --- | --- | --- | --- |
| Xanh Browser | `io.github.lamppkk.xanhbrowser` | Linux desktop | 1.0.0 |
| Xanh Browser | `io.github.lamppkk.xanhbrowser` | iOS 26 / iPadOS 26 | 1.0.0 (`10000`) |
| Xanh Browser | `io.github.lamppkk.xanhbrowser.macos` | macOS 26 | 1.0.0 (`10000`) |
| Xanh Browser | `XanhBrowser.Windows` | Windows 11 + serviced Win10 Enterprise/LTSC/IoT (x64/ARM64) | 1.0.0 |
| Xanh Browser WebKit | `XanhBrowser.WebKit` | Windows x64 preview | 1.0.0 |
| Xanh Browser Lite | `io.github.lamppkk.xanhbrowser.lite` | Android 8.0+ (API 26+) | 1.0.0 (`10000`) |
| Xanh Browser Lite WebKit | `io.github.lamppkk.xanhbrowser.lite.webkit` | Android 12+ (API 31+) preview | 1.0.0 (`10000`) |

The full multi-tab Android edition is maintained in the
[Xanh Browser Android repository](https://github.com/LamPPKK/midori-android).

The Apple apps use the operating system WebKit through SwiftUI `WebPage` and
`WebView`. The production Windows app uses the Evergreen Edge WebView2 Runtime;
its separate x64 preview builds the upstream WebKit WinCairo port from a pinned
source revision. Android Lite similarly keeps the production System WebView
edition and adds a separate WPE WebKit preview.

## Linux desktop

### Current capabilities

- Multi-tab browsing, bookmarks, history and downloads
- Private tabs that are excluded from history and session persistence
- Safe session recovery without automatically importing a legacy session
- Confirmed, one-time, idempotent import of legacy bookmarks, history and
  settings
- Six native libpeas plugins: ad blocking, bookmarks, session support,
  colorful tabs, status clock and status features
- A permission-checked Manifest V2 WebExtension subset with isolated script
  worlds, host permissions, CSP enforcement and validated messages

Manifest V3 and complete Chrome/Firefox extension API compatibility are not
part of the 1.0 scope.

### Build requirements

- Linux
- CMake 3.24+
- Ninja
- Vala 0.56+
- GLib 2.74+
- GTK 4.10+
- WebKitGTK 6.0 and JavaScriptCoreGTK 6.0, version 2.52.6+
- libsoup 3, SQLite, libpeas 2, GCR 4 and JSON-GLib

Package names vary by distribution. The authoritative dependency constraints
are in [CMakeLists.txt](CMakeLists.txt); the shared patch-level floor is pinned
in [WEBKITGTK_MIN_VERSION](WEBKITGTK_MIN_VERSION). Version 2.52.6 is the latest
stable WebKitGTK/WPE WebKit release and fixes the vulnerabilities listed in
[WSA-2026-0005](https://webkitgtk.org/security/WSA-2026-0005.html).
The scheduled WebKit baseline workflow resolves official upstream release tags
weekly and fails when this floor, the WinCairo tag or its peeled revision no
longer matches the newest even-minor stable series; development tags are never
accepted as a production baseline. It also downloads the two exact pinned
upstream source files used by the Linux popup policy and fails if the GLib
navigation-action mapping or trusted button-down mouse invariant changes.

Linux address and recovery targets are limited to validated HTTP(S) URLs no
larger than 8 KiB. They reject userinfo, raw or decoded control characters,
raw whitespace, malformed IDN/DNS/IP hosts and invalid ports. If a WebProcess
terminates, only the selected tab in an active window may make one automatic
fresh URI load from its last validated committed URL. A background tab waits;
leaving the foreground cancels an in-flight attempt, and a second termination
stops with an explicit Reload action instead of looping or restoring
back-forward/form state.

Linux also makes every WebKit navigation decision explicit: only exact
`about:blank` and validated HTTP(S) URLs are allowed in the web view. External
`mailto`, `tel`, `sms`, `geo`, `maps` and `market` links are intercepted by a
document-start script in a named isolated world and handed to the operating
system only for an unmodified trusted activation in the active top frame. The
host revalidates the 2 KiB URI and exact 8 KiB document URL, tab, foreground
state and clearing state; synthetic clicks, redirects, iframe requests, stale
messages, decoded controls, whitespace and backslashes fail closed. Entering a
valid allowlisted URI in the address bar is also an explicit handoff. Private
tabs use the same policy, so an approved handoff intentionally discloses that
URI to the selected external application.

Powerful-feature permissions on Linux are deny-by-default. Camera, microphone,
display capture, geolocation, device enumeration, pointer lock and a validated
third-party Storage Access request may show a native **Allow on This Page**
prompt only for the exact current HTTPS document in the selected tab of the
active window.
The request is revalidated after the prompt and is denied on navigation, tab
switch/close, focus loss, renderer termination, data clearing, replacement by a
new prompt or a 30-second timeout. Notifications, DRM key systems, clipboard,
XR and unknown request types remain denied until they have dedicated UI and
origin/lifecycle handling. Private tabs use the same one-request policy without
persisting a Xanh decision across navigation.

TLS certificate failures on Linux are also fail-closed. Xanh shows only the
validated HTTPS origin plus bounded, control-free certificate details and does
not create a certificate or host exception. The native warning is tied to the
exact active tab and failing URL, expires after 30 seconds, and is canceled by
navigation, tab/window lifecycle changes, renderer termination or data
clearing. Paths, queries and fragments are never copied into the warning.

Linux HTTP authentication no longer falls through to WebKit's default
credential dialog or persistent credential store. Basic and Digest challenges
may show a native **Sign In Once** prompt only when the challenge host, port and
security origin match the exact selected HTTPS document in the active window.
Cross-origin, HTTP, proxy, retry, NTLM/Negotiate, certificate and unknown
challenges are canceled. Credentials are bounded, sent with `NONE` persistence,
never proposed from WebKit storage and never routed through Firefox Sync; the
prompt is canceled on the same tab/document/window, renderer, clear-data,
replacement and 30-second timeout boundaries. Private tabs use the same manual,
non-persistent path.

Linux downloads use WebKitGTK 6.0's absolute local-path API only after the
native save dialog has confirmed the exact destination. Server-provided names
are stripped of path separators, controls, directional formatting and excessive
length before they reach the dialog. Overwrite is enabled only after that native
confirmation; closing the window or clearing data cancels an unresolved choice.
A failed download produces one `failed` database entry, never a second false
`finished` entry. Private downloads require the same explicit save choice but
are not written to Xanh's download database.

Linux new-window requests are fail-closed instead of creating an unrelated tab
for every `window.open`. Xanh accepts one bounded HTTP(S) or exact `about:blank`
target per second only from a trusted direct left/middle-button link in the
selected foreground HTTP(S) tab. Synthetic/keyboard activation, script-only
opens, redirects, malformed targets, stale documents and the 101st tab are
blocked. An accepted view is constructed with WebKit's `related-view`, inherits
the opener's regular or ephemeral network session, receives Xanh's isolated
bridges and current content filter before navigation, and remains outside the UI
until `ready-to-show`. Tab changes, navigation, focus loss, renderer failure,
data clearing, closure or a 15-second timeout cancel an unresolved popup.

Linux file inputs use an application-owned modal GTK4 chooser only for the
selected foreground HTTPS document. The request retains the exact document and
tab identity, applies WebKit's MIME filter, and returns at most 32 unique local
absolute paths without percent-escape ambiguity, bounded to 4 KiB each and
64 KiB together. A navigation, tab
switch/close, renderer termination, browsing-data clear, replacement request or
five-minute timeout cancels the chooser and tells WebKit that no file was
selected. Xanh does not write selected upload paths to its database, session,
Sync data or portable backups; the operating-system chooser/portal remains
subject to its own folder-history policy.

Page-controlled titles are normalized once through the shared desktop data
policy before they reach tab/window labels, history, bookmarks, session state,
the Places compatibility mirror or Firefox Sync. Xanh collapses whitespace,
removes control, zero-width and bidi-formatting characters, preserves valid
UTF-8 boundaries and limits the result to 4,096 bytes; an empty result falls
back to the bounded page URL or `Untitled`. The same core policy now validates
HTTP(S) URLs for navigation, legacy storage and Sync, so userinfo, malformed
hosts/ports, whitespace and raw or percent-decoded controls cannot be accepted
by one data path after another path rejects them; backslashes are rejected to
avoid GLib/WHATWG parser differentials. UI-facing history, bookmark and Places
queries quarantine unsafe legacy URL rows, including legacy private-history
rows, while the bounded migration scanner still counts every source row and
audits each rejection. Session persistence accepts only those HTTP(S) URLs or
exact `about:blank`, skips unsafe legacy rows and remaps the selected tab to the
remaining safe list instead of reopening rejected content as a search.

### Build and test

```sh
cmake -S . -B _build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build _build
ctest --test-dir _build --output-on-failure
cmake --build _build --target validate-metadata
```

The uninstalled executable is `_build/xanh-browser`. Install into a temporary
staging directory before inspecting the package layout:

```sh
DESTDIR="$PWD/_artifact" cmake --install _build
```

## Android Lite

Xanh Browser Lite intentionally has one tab and no history manager, tab
manager or bookmark database. It includes navigation, address/search
resolution, reload, sharing, desktop mode, file upload, geolocation consent,
scoped downloads and asynchronous privacy clearing.
Its serviced System WebView integration uses the stable AndroidX WebKit 1.17.0
compatibility layer; the separately packaged WPE edition remains governed by
the engine-specific baseline below. The scheduled stable-baseline workflow
reads Google Maven metadata weekly and fails if any shipping Gradle module or,
when present, its strict dependency checksums lag the newest stable AndroidX
WebKit release; alpha, beta and RC versions never satisfy this production gate.
If the serviced renderer is terminated,
Lite destroys the dead WebView and recreates the Activity from only its last
validated HTTP(S) URL instead of restoring a form body. Recovery waits until
the Activity is foreground, runs at most once and closes a repeatedly crashing
page instead of looping.

Use JDK 17, Android SDK Platform 37.1 and Build Tools 36.1.0. The apps retain
target API 36 for the 1.0 release:

The Android builds pin Android Gradle Plugin 9.3.2 and the checksum-verified
Gradle 9.7.1 wrapper. A separate weekly baseline reads the official Google
Maven and Gradle release endpoints and fails when either stable build-tool pin
or the checked-in wrapper JAR/distribution checksum becomes stale.

AndroidX Core is pinned to stable 1.19.0. Its published AAR requires compile
API 37, so every Android module builds against stable Android SDK Platform
37.1 while the shipping applications continue to target API 36.

```sh
./gradlew --no-daemon \
  :backup-core:testDebugUnitTest \
  :app:lintDebug \
  :app:testDebugUnitTest \
  :app:assembleDebug \
  :app:assembleAndroidTest \
  :app:bundleRelease
```

Generated files are placed under `app/build/outputs/`. `bundleRelease` creates
an **unsigned verification AAB**. A production bundle requires the dedicated
Lite upload key and the guarded `bundleProductionRelease` task documented in
[RELEASING.md](RELEASING.md).

### Android WPE WebKit preview

The `app-webkit` module is a separately installable, single-tab WPE WebKit
edition for arm64 and x86_64 devices running API 31 or newer:

```sh
./gradlew --no-daemon \
  :backup-core:testDebugUnitTest \
  :app-webkit:lintDebug \
  :app-webkit:testDebugUnitTest \
  :app-webkit:assembleDebug \
  :app-webkit:assembleAndroidTest \
  :app-webkit:bundleRelease
```

It currently uses the newest published Maven artifact, WPEView 0.3.3, whose
embedded runtime identifies itself as WPE WebKit 2.50.6. This is intentionally
preview-only: the upstream artifact is below this project's WPE WebKit 2.52.6
security baseline and one bundled native library is not 16 KiB page aligned.
The guarded production task fails until both conditions are resolved. Exact
engine versions are pinned in `app-webkit/WPEVIEW_VERSION` and
`app-webkit/WPE_RUNTIME_VERSION` and are also shown in the application menu.
Track reviewed wrapper releases on the
[official WPE Android release page](https://github.com/Igalia/wpe-android/releases).

The repository also carries a reproducible source-fork contract at
[`app-webkit/wpe-fork/`](app-webkit/wpe-fork/README.md). It locks WPE Android
and Cerbero revisions, upgrades the source-built engine to WPE WebKit 2.52.6,
adds 16 KiB ELF alignment flags and supplies a bounded, main-frame-only bridge
in a named isolated script world. The same fork adds a pre-load navigation
policy callback; Xanh allows web URLs, blocks unsupported schemes, and opens an
allowlisted external scheme only for a non-redirected user gesture. A
Linux-only build orchestrator now creates a dual-ABI AAR, exact checksum,
16 KiB report, file-level CycloneDX SBOM, toolchain/build provenance and the
validated corresponding source archives without modifying the input checkout.
The manual source-build workflow then compiles the SDK 37.1 host against that
exact AAR in an unprivileged, single-job ephemeral runner labelled
`xanh-wpe-android-ephemeral`. A separate GitHub-hosted job downloads only the
fixed checksum manifest and emits a commit-bound GitHub
OIDC/Sigstore attestation for the evidence and host APKs; source-build code
never receives the repository credential or OIDC permission. It does not
replace the Maven preview by default and does not open the production
gate until the bridge, devices, signing and security evidence have all been
reviewed.

## Apple platforms

The shared SwiftUI app provides multi-tab and private-tab browsing on macOS,
iPhone and iPad. It requires Xcode 26 and the macOS/iOS 26 SDKs because it uses
the current WebKit-native `WebPage` and `WebView` APIs. Regular tabs use a
main-frame-only isolated `WKContentWorld` for the gated Firefox Sync credential
picker; private tabs never install that bridge. Address and restored-session
URLs are bounded and reject userinfo or malformed hosts/ports. Allowlisted
external schemes require a trusted, non-redirected main-frame link activation
before the system is asked to open them. A terminated WebContent process gets
at most one foreground-only GET recovery at a validated URL; automatic reload,
form resubmission and repeat recovery are blocked. See
[`platform/apple/README.md`](platform/apple/README.md) for build commands and
the remaining App Store signing requirements.

## Windows

The Windows edition is a native WinUI 3 application with multi-tab and
InPrivate browsing, strict URL/scheme validation, tracking prevention and
WebView2 host-bridge features disabled by default. See
[`platform/windows/README.md`](platform/windows/README.md) for .NET 10 build and
publish commands. A real WebKit/WinCairo x64 preview is built from a pinned
upstream stable release commit matching the shared WebKit 2.52.6 security
baseline and lives in
[`platform/windows-webkit/`](platform/windows-webkit/README.md).
Its pinned source delta includes isolated-world C API primitives, while the
MiniBrowser host additionally blocks non-web navigation before load and only
delegates trusted, direct user-clicked, non-redirected `mailto:`/`tel:` links,
with one external launch per consumed gesture. Unexpected WebProcess
termination receives at most one bounded back-forward restore when the current
committed item has no stored HTTP body; form submissions are never restored and
a repeatedly crashing page cannot form an automatic recovery loop. The
MiniBrowser now registers a fail-closed, main-frame isolated credential bridge
and connects it to one process-wide native picker. The picker uses an
owner-window Windows Hello/PIN check, current-user DPAPI state, strict bounded
exact-origin record parsing, a native username chooser and a five-minute or
background vault lock. It returns `unavailable` unless self-hosted public
configuration, readable protected vault state and a signed native core are present.
Its DLL loader accepts only
an exact-name, same-directory native core with a trusted Authenticode signature,
the expected version and the full C ABI, and rejects builds without Mozilla
support. A typed adapter now owns the validated DLL/runtime together, takes its
signatures from the packaged C header, bounds all credential-facing inputs and
wipes generated keys and returned credential JSON through exception-safe native
owners and non-SSO host buffers. Native open/key-generation failures retain the
originating thread-local error before the DLL can unload, and runtime failures
remain associated with their calling thread. No native DLL or account setup is
packaged by default, so the signed package and end-to-end Sync path remain
release-gated.

## Encrypted backup and sync

The full Android edition, Android Lite, Android Lite WebKit, Windows WebView2
and the WinCairo preview can export and import the same portable `.xanhbackup`
file. The file is encrypted with a user password using PBKDF2-HMAC-SHA256 and
AES-256-GCM. It contains only regular tab/window URLs, the selected item and
the desktop-site setting; cookies, passwords, cache and private state are
excluded. Full URL query/fragment data remains part of the encrypted snapshot
and can itself be sensitive.

The application uses the operating-system file picker. On Android this can
write directly to Google Drive or another installed Documents provider. On
Windows it can write to OneDrive, Google Drive for desktop, an OS-backed-up
Documents folder or a Git working tree. The application stores no cloud token,
and syncing/merge conflicts remain under the selected provider's control. See
[`docs/PORTABLE_BACKUP.md`](docs/PORTABLE_BACKUP.md) for the format, threat
model and provider workflow.

## Mozilla Accounts / Firefox Sync

`xanh-sync-core` is the shared Rust boundary for Mozilla Accounts and Firefox
Sync. It pins stable Mozilla Application Services 155.0 and exposes UniFFI plus
a versioned C ABI for Kotlin, Swift, Vala and C#. Bookmarks/history use Places,
remote tabs use Tabs and passwords use a local authenticated Logins vault.
An official-tag verifier checks the lock, Cargo closure, Rust constants and
license notice on relevant changes and weekly; a newer stable Mozilla release
fails CI until its compatibility and security matrix is rerun explicitly.
Mozilla-hosted builds require registered per-edition client IDs and production
approval; an HTTPS self-hosted deployment remains available when configured
against the same server as Firefox.

The feature is release-gated independently on each platform. WPE and WinCairo
remain preview-only until their isolated message bridges, vaults and packaging
security checks pass. See [`docs/FIREFOX_SYNC.md`](docs/FIREFOX_SYNC.md) for the
architecture, implementation snapshot, threat boundary and required
interoperability matrix. Passing local builds does not open a production gate;
Mozilla approval or a documented self-hosted deployment, signed artifacts and
the interoperability/security matrix remain mandatory. Sync tokens, scoped
keys and passwords are never included in `.xanhbackup`.

The shared Rust boundary also ships scheduled cargo-fuzz campaigns for isolated
bridge envelopes, credential context validation and the stable credential C
ABI. These campaigns reject oversized or ambiguous origin claims before they
reach a platform vault; production still requires the longer independent
security review recorded in the release checklist.

The standard Android host applies the shared Logins contract to its Xanh-only
password library: exact canonical HTTPS origins, ASCII identifiers and bounded
UTF-8 username/password/field data are enforced before every mutation. A
successful add/update/delete/touch schedules local-change Sync; backgrounding,
vault replacement or disconnect clears decrypted rows and dialogs so stale
async work cannot repopulate or retarget the screen. The hierarchy opts out of
Android Autofill/content capture and requests no IME personalized learning;
provider/IME compliance remains platform-controlled.

On Linux, the optional native build now exposes account controls in the GTK
menu, opens OAuth in the system browser, validates the registered callback and
stores account/Sync/vault state in Secret Service. The ordinary desktop build
fails closed when the native core or approved/self-hosted configuration is not
present. A connected build imports legacy bookmarks/history from a verified
private SQLite snapshot, mirrors Places into the existing GTK panels, publishes
regular local tabs and presents remote tabs by device for explicit opening.
The GTK bookmark/history panels preserve the native bookmark GUID and exact
visit timestamp in a schema-v2 compatibility mirror. Confirmed row deletion
therefore calls the upstream Places API and creates the precise tombstone for
the next Firefox Sync; rows created offline remain removable without guessing
a native identity. The same panel can rename a bookmark by GUID while leaving
its URL, folder and position unchanged. Rename/delete mutations are rejected
from private tabs. Existing schema-v1 mirrors are discarded and safely rebuilt.
Clearing browsing data quiesces every open window, clears upstream Places
history locally for the next Sync and removes migration snapshots. Linux
regular tabs now use a native GTK username picker and a document-start,
top-frame-only credential bridge in a named isolated WebKitGTK world. Request
ID, navigation nonce and the exact committed HTTPS origin are revalidated, and
private tabs install no credential bridge. Linux production remains gated until
Sync-enabled Flatpak packaging, audited fresh OS user-presence for password
unlock, and the interoperability/security evidence are complete.

Apple and Windows include native settings/coordinator hosts for system-browser
OAuth, engine selection, backoff-aware Sync, remote tabs, device-bound secure
state and five-minute password-vault locking. Both now have gated native
credential pickers with trusted-gesture, exact-origin, tab and navigation-nonce
checks; private/InPrivate tabs never install them. Apple additionally keeps its
bridge and credential payload in an isolated `WKContentWorld`. Apple decodes
remote tabs into bounded typed records, groups them by device and opens a
regular tab only after the user selects one specific safe HTTP(S) row. Its
native Places library also presents bounded bookmark/history records, preserves
the exact bookmark GUID or URL/millisecond visit identity for mutations, records
only completed regular navigation and excludes private tabs before every Places
write. Its native password library also lists, adds, updates and deletes Logins
only for the current exact HTTPS origin after LocalAuthentication. Every result
and exact login ID is revalidated across page/tab changes; private and non-HTTPS
contexts never reach the native mutation API, and vault/background locking
clears the displayed credential records. These hosts' ordinary verification artifacts intentionally omit the native
Mozilla runtime, and production remains blocked until the pinned XCFramework/DLL
and platform interoperability/security evidence are packaged and reviewed. Each
platform uses its own registered callback scheme.

The Sync-enabled Windows host now publishes bounded regular tabs before Sync,
records only successful regular navigation in Places and exposes a native
bookmark/history library. Bookmark rename/delete uses the selected 12-character
Places GUID, history deletion uses the selected canonical URL plus millisecond
visit timestamp, and remote history is display-only until explicitly opened.
Remote tabs are parsed through the same bounded native contract, grouped by
device and remain inert until the user clicks one specific HTTP(S) row.
Its native site-password library uses Windows Hello/PIN to unlock the vault,
then lists, adds, updates and confirm-deletes Logins only for the selected
regular tab's exact HTTPS origin. It retains and revalidates the native login ID
across every dialog/native boundary; navigation, tab changes, backgrounding or
vault lock dismiss stale credential rows. InPrivate tabs are rejected before
any Places or Logins mutation. The ordinary artifact
still has no local Places runtime, so these library controls remain unavailable
until an approved or self-hosted Sync configuration and native DLL are present.

Lite keeps Sync out of its base install. A Play on-demand dynamic feature owns
the Application Services runtime; the base app loads it only after the user
chooses Firefox Sync. CI builds both base-only and `lite-with-sync` bundles,
runs `scripts/verify-lite-sync-size.sh`, and rejects a base-module increase over
1 MiB, native Sync code in `base/`, or unsupported legacy ABIs. Its System
WebView credential picker requires a recent trusted user gesture and consumes
only the bounded exact-origin form records returned by the shared Android
runtime. The WPE split shares the data UI but deliberately has no password-fill
bridge when built with the published Maven preview. A checksum-verified source
fork build now attaches a separate top-frame isolated bridge with per-document
nonce authenticated by a host challenge, exact-origin/foreground/navigation and
request-ID validation, native selection, and typed replies acknowledged by the
same document. Late feature attachment runs the idempotent bootstrap in the
current isolated world without reloading the page. It remains blocked from
production until the fork artifact, its fail-closed pre-load navigation policy,
and device/security evidence pass the WPE release gate.

## Repository map

| Path | Purpose |
| --- | --- |
| `desktop/` | GTK4 application, persistence, importer and WebExtension bridge |
| `plugins2/` | Native plugin ABI 2 modules and manifests |
| `tests-modern/` | Desktop unit, integration and smoke tests |
| `data-xanh/` | Desktop entry, AppStream metadata, schema, icon and D-Bus service |
| `ui/` | GTK4 Builder resources |
| `flatpak/` | Flatpak manifest for the desktop application |
| `app/` | Xanh Browser Lite Android module |
| `app-webkit/` | Separately installable WPE WebKit Android preview |
| `backup-core/` | Android implementation of the portable encrypted backup format |
| `sync-feature-common/` | Shared Lite on-demand Sync UI, vault and scheduler |
| `sync-feature/` | System WebView dynamic feature with the isolated credential bridge |
| `sync-feature-wpe/` | WPE dynamic feature; source-fork credential bridge is fail-closed |
| `xanh-sync-core/` | Rust Application Services core, UniFFI and stable C ABI |
| `platform/apple/` | Shared macOS, iOS and iPadOS application |
| `platform/windows/` | Windows application powered by WebView2 |
| `platform/windows-webkit/` | Pinned source build of the WebKit WinCairo x64 preview |
| `fastlane/` | Play listing metadata for Lite |
| `.github/workflows/` | Linux, Android, Apple, Windows, Flatpak, CodeQL and source-release CI |

## Security and privacy defaults

- The desktop build links only against GTK4, WebKitGTK 6.0 and libsoup 3.
- Linux CI enforces WebKitGTK/JavaScriptCoreGTK 2.52.6 or newer at configure
  time and again against the linked runtime.
- Linux WebProcess recovery is limited to one selected, foreground, body-free
  URI load from an 8 KiB validated committed HTTP(S) URL. It never invokes
  automatic reload or back-forward restoration. Background recovery is
  deferred; focus loss cancels an in-flight attempt, and repeat failure stops
  for explicit user action.
- Linux WebKit navigation is allowlisted before load. Only validated HTTP(S)
  and exact `about:blank` stay in WebKit; an allowlisted external scheme needs
  either explicit address-bar activation or a trusted active-top-frame event
  from the named isolated bridge, followed by host-side URI/document checks.
- Linux powerful-feature permissions are HTTPS-only, native-confirmed and
  scoped to one still-current request. Unsupported request classes are denied,
  while navigation, tab/window lifecycle, renderer loss, privacy clearing and
  timeout all cancel a pending prompt.
- Apple editions use only the system WebKit data stores, keep their gated
  credential bridge in an isolated content world and use a nonpersistent store
  without that bridge for private tabs; macOS runs in the App Sandbox. Web and
  external URLs are bounded before navigation, reject userinfo, malformed
  hosts/ports and decoded controls, and external handoff additionally requires
  a trusted non-redirected main-frame link activation. WebContent-process
  recovery is bounded to one foreground GET without request bodies or
  back-forward state and stops if the scene leaves the foreground.
- Windows accepts only web URLs in WebView2, disables host objects, restricts
  web messaging to the gated regular-tab credential bridge and uses the
  Evergreen runtime for independently serviced engine updates. Scheduled
  official verifiers reject stale, dynamic or prerelease .NET, Windows App SDK
  and WebView2 pins; the current stable baselines are .NET 10.0.11 / SDK
  10.0.400, Windows App SDK 2.4.0 and WebView2 SDK 1.0.4129.50. Startup additionally
  rejects non-stable channels or a Runtime older than 151.0.4129.50 before any
  page is loaded. WebView2 navigation and external handoff are bounded and
  reject userinfo, invalid hosts/ports and control-bearing input. Renderer or
  browser-process failure receives at most one fresh GET recovery at a
  validated URL; Xanh never automatically reloads form state.
- The Flatpak manifest grants only the permissions required by current browser
  functionality.
- Android production blocks cleartext and mixed content, enables Safe Browsing
  and uses scoped storage without legacy external-storage permissions.
- Portable backups are authenticated and encrypted, reject non-HTTP(S) URLs
  and are bounded to 1 MiB and 50 tabs before parsing.
- External Android schemes are handed off only after URI and intent checks.
- File and geolocation access require user consent when requested.
- Signing keys and passwords must never be committed to this repository.

## Supported release scope

The production 1.0 codebase targets Linux desktop, Android API 26–36, macOS 26,
iOS/iPadOS 26, Microsoft-supported Windows 11 releases and the serviced Windows
10 Enterprise/LTSC/IoT editions listed for .NET 10. Windows build 19041 remains
the technical TFM and Windows App SDK floor; it is not a promise of support for
consumer Windows 10 releases outside Microsoft's .NET 10 support matrix. The
Android API 31+ WPE and Windows x64 WinCairo variants remain preview-only until
their engine-specific release gates pass. Signed Apple and Windows distribution
remains gated until their platform test matrices and store/code-signing
checklists pass. Android legacy-data import and Manifest V3 remain outside the
1.0 scope.

## Historical baseline and license

The pre-modernization source is preserved by the `legacy-midori-9.0` tag.
Historical product names remain only where needed for license attribution,
historical changelog entries and the confirmed desktop importer.

See [COPYING](COPYING) for license terms and [CHANGELOG.md](CHANGELOG.md) for
release history.
