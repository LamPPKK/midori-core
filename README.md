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
| Xanh Browser | `XanhBrowser.Windows` | Windows 10 2004+ (x64/ARM64) | 1.0.0 |
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

Use JDK 17 and Android SDK 36:

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

## Apple platforms

The shared SwiftUI app provides multi-tab and private-tab browsing on macOS,
iPhone and iPad. It requires Xcode 26 and the macOS/iOS 26 SDKs because it uses
the current WebKit-native `WebPage` and `WebView` APIs. See
[`platform/apple/README.md`](platform/apple/README.md) for build commands and
the remaining App Store signing requirements.

## Windows

The Windows edition is a native WinUI 3 application with multi-tab and
InPrivate browsing, strict URL/scheme validation, tracking prevention and
WebView2 host-bridge features disabled by default. See
[`platform/windows/README.md`](platform/windows/README.md) for .NET 8 build and
publish commands. A real WebKit/WinCairo x64 preview, built from a pinned
upstream source revision, lives in
[`platform/windows-webkit/`](platform/windows-webkit/README.md).

## Encrypted backup and sync

The full Android edition, Android Lite, Android Lite WebKit and Windows WebView2
can export and import the same portable `.xanhbackup` file. The file is
encrypted with a user password using PBKDF2-HMAC-SHA256 and AES-256-GCM. It
contains only regular tab URLs, the selected tab and the desktop-site setting;
cookies, passwords, cache and private tabs are excluded.

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

Lite keeps Sync out of its base install. A Play on-demand dynamic feature owns
the Application Services runtime; the base app loads it only after the user
chooses Firefox Sync. CI builds both base-only and `lite-with-sync` bundles,
runs `scripts/verify-lite-sync-size.sh`, and rejects a base-module increase over
1 MiB, native Sync code in `base/`, or unsupported legacy ABIs. The WPE split
shares the data UI but deliberately has no password-fill bridge and remains
blocked from production.

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
| `sync-feature-wpe/` | WPE dynamic feature; password filling remains disabled |
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
- Apple editions use only the system WebKit data stores and a nonpersistent
  store for private tabs; macOS runs in the App Sandbox.
- Windows accepts only web URLs in WebView2, disables host objects/web messages,
  and uses the Evergreen runtime for independently serviced engine updates.
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
iOS/iPadOS 26 and Windows 10 build 19041 or newer. The Android API 31+ WPE and
Windows x64 WinCairo variants remain preview-only until their engine-specific
release gates pass. Signed Apple and Windows distribution remains gated until
their platform test matrices and store/code-signing checklists pass. Android
legacy-data import and Manifest V3 remain outside the 1.0 scope.

## Historical baseline and license

The pre-modernization source is preserved by the `legacy-midori-9.0` tag.
Historical product names remain only where needed for license attribution,
historical changelog entries and the confirmed desktop importer.

See [COPYING](COPYING) for license terms and [CHANGELOG.md](CHANGELOG.md) for
release history.
