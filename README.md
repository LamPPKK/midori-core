# Xanh Browser

Xanh Browser is a privacy-minded browser family built around native platform
web engines. This repository contains the Linux desktop browser, native Apple
and Windows editions, and the small single-tab Android edition, Xanh Browser
Lite.

> **Release status:** Linux and Android Lite 1.0.0 are release candidates. The
> Apple and Windows ports are 1.0.0 preview candidates. CI produces unsigned
> verification artifacts only; production artifacts must not be published
> until the signing, device, security and store gates in
> [RELEASING.md](RELEASING.md) are complete.

## Editions

| Product | Application ID | Platform | Current version |
| --- | --- | --- | --- |
| Xanh Browser | `io.github.lamppkk.xanhbrowser` | Linux desktop | 1.0.0 |
| Xanh Browser | `io.github.lamppkk.xanhbrowser` | iOS 26 / iPadOS 26 | 1.0.0 (`10000`) |
| Xanh Browser | `io.github.lamppkk.xanhbrowser.macos` | macOS 26 | 1.0.0 (`10000`) |
| Xanh Browser | `XanhBrowser.Windows` | Windows 10 2004+ (x64/ARM64) | 1.0.0 (`10000`) |
| Xanh Browser Lite | `io.github.lamppkk.xanhbrowser.lite` | Android 8.0+ (API 26+) | 1.0.0 (`10000`) |

The full multi-tab Android edition is maintained in the
[Xanh Browser Android repository](https://github.com/LamPPKK/midori-android).

The Apple apps use the operating system WebKit through SwiftUI `WebPage` and
`WebView`; the Windows app uses the Evergreen Edge WebView2 Runtime. Windows
cannot share Apple's WebKit engine because Apple does not ship a supported
production WebKit embedding framework for that platform.

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
- WebKitGTK 6.0 and JavaScriptCoreGTK 6.0, version 2.52.5+
- libsoup 3, SQLite, libpeas 2, GCR 4 and JSON-GLib

Package names vary by distribution. The authoritative dependency constraints
are in [CMakeLists.txt](CMakeLists.txt).

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
  lintDebug \
  testDebugUnitTest \
  assembleDebug \
  assembleAndroidTest \
  bundleRelease
```

Generated files are placed under `app/build/outputs/`. `bundleRelease` creates
an **unsigned verification AAB**. A production bundle requires the dedicated
Lite upload key and the guarded `bundleProductionRelease` task documented in
[RELEASING.md](RELEASING.md).

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
publish commands.

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
| `platform/apple/` | Shared macOS, iOS and iPadOS application |
| `platform/windows/` | Windows application powered by WebView2 |
| `fastlane/` | Play listing metadata for Lite |
| `.github/workflows/` | Linux, Android, Apple, Windows, Flatpak, CodeQL and source-release CI |

## Security and privacy defaults

- The desktop build links only against GTK4, WebKitGTK 6.0 and libsoup 3.
- Linux CI enforces WebKitGTK/JavaScriptCoreGTK 2.52.5 or newer at configure
  time and again against the linked runtime.
- Apple editions use only the system WebKit data stores and a nonpersistent
  store for private tabs; macOS runs in the App Sandbox.
- Windows accepts only web URLs in WebView2, disables host objects/web messages,
  and uses the Evergreen runtime for independently serviced engine updates.
- The Flatpak manifest grants only the permissions required by current browser
  functionality.
- Android production blocks cleartext and mixed content, enables Safe Browsing
  and uses scoped storage without legacy external-storage permissions.
- External Android schemes are handed off only after URI and intent checks.
- File and geolocation access require user consent when requested.
- Signing keys and passwords must never be committed to this repository.

## Supported release scope

The 1.0 codebase targets Linux desktop, Android API 26–36, macOS 26,
iOS/iPadOS 26 and Windows 10 build 19041 or newer. Signed Apple and Windows
distribution remains gated until their platform test matrices and store/code
signing checklists pass. Android legacy-data import and Manifest V3 remain
outside the 1.0 scope.

## Historical baseline and license

The pre-modernization source is preserved by the `legacy-midori-9.0` tag.
Historical product names remain only where needed for license attribution,
historical changelog entries and the confirmed desktop importer.

See [COPYING](COPYING) for license terms and [CHANGELOG.md](CHANGELOG.md) for
release history.
