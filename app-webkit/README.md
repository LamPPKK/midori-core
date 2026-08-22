# Xanh Browser Lite WebKit preview

This module is the separately installable Android WebKit edition. It keeps the
Lite one-tab scope and uses WPE WebKit through WPEView instead of Android System
WebView.

## Identity and baseline

- Application ID: `io.github.lamppkk.xanhbrowser.lite.webkit`
- Version: `1.0.0` (`10000`)
- Android: API 31–36
- Architectures: arm64-v8a and x86_64
- WPEView: see `WPEVIEW_VERSION`
- Embedded engine: see `WPE_RUNTIME_VERSION`

The engine versions are also visible from **WebKit engine information** in the
application menu.

## Build

Use JDK 17 and Android SDK 36 from the repository root:

```sh
./gradlew --no-daemon \
  :backup-core:testDebugUnitTest \
  :app-webkit:lintDebug \
  :app-webkit:testDebugUnitTest \
  :app-webkit:assembleDebug \
  :app-webkit:assembleAndroidTest \
  :app-webkit:bundleRelease
```

The release bundle is unsigned unless the four `XANH_WEBKIT_*` upload-key
values are provided. The guarded `bundleWebKitProductionRelease` task also
blocks publishing while the pinned WPE artifact is below the repository's
engine and 16 KiB page-alignment requirements.

The reviewed source-fork contract lives in [`wpe-fork/`](wpe-fork/README.md).
After building its AAR, use it in a verification build with an exact checksum:

```sh
./scripts/verify-android-16k.sh /absolute/path/to/wpeview-release.aar
./gradlew --no-daemon :app-webkit:assembleDebug \
  -PxanhWpeForkAar=/absolute/path/to/wpeview-release.aar \
  -PxanhWpeForkSha256=<sha256>
```

`XANH_WPE_FORK_AAR` and `XANH_WPE_FORK_SHA256` are the equivalent CI
environment variables. The checksum is mandatory whenever the local fork AAR
override is used, and the engine-information menu then reports the locked fork
runtime rather than the Maven preview runtime.

## Preview limitations

WPE Android is still an experimental embedding port. The current published
WPEView artifact bundles WPE WebKit 2.50.6 and a `libFLAC.so` that Android lint
reports as not 16 KiB page aligned. It must not be promoted to production until
an upstream artifact with WPE WebKit 2.52.6 or newer passes lint, device and
browser-flow testing. The required floor follows the
[latest WPE stable release](https://wpewebkit.org/release/); wrapper availability
is tracked separately through the
[WPE Android releases](https://github.com/Igalia/wpe-android/releases).

Because no official WPE Android 2.52.6 bootstrap package is published, the
repository carries a pinned source delta that builds that stable runtime, adds
16 KiB linker alignment and exposes a main-frame-only isolated script
world/message bridge plus a pre-load navigation policy callback. A fork-AAR verification build attaches the on-demand
credential picker only through that API. A host-generated challenge binds each
document nonce to a monotonic navigation generation. The host rechecks the live
URL and foreground state; the isolated-world reply rechecks origin, generation,
challenge, nonce, request ID and renderer visibility before acknowledging a
typed fill. Late dynamic-feature attachment bootstraps the current document
through the same named world without reloading it. API drift or a non-fork build
leaves password filling disabled. Production remains blocked until the
resulting binaries and bridge pass the release evidence listed in
[`../RELEASING.md`](../RELEASING.md).

The fork callback receives the request plus user-gesture and redirect state
before WebKit starts a navigation. HTTP(S) and `about:blank` are allowed;
unsupported schemes are blocked. `mailto`, `tel`, `geo` and `market` are handed
to a resolvable Android browsable intent only after a non-redirected user
gesture. JNI or host callback failures block the navigation.

Any distributed artifact must also carry the required WebKit/WPEView and
third-party license notices and satisfy the corresponding source-availability
obligations.

The APK contains its own native engine and is therefore much larger than the
System WebView edition. It is intentionally distributed as a separate
application so it cannot silently replace the production engine.

The published WPEView navigation client does not expose that callback. In the
Maven preview, the existing page-start guard remains defense in depth and stops
non-HTTP(S) loads after start; external schemes entered explicitly in the
address bar are still handed to a validated Android intent. This fallback is
not accepted as source-fork navigation-policy evidence.

Encrypted `.xanhbackup` import/export is compatible with Android Lite and the
Windows WebView2 edition. See [`../docs/PORTABLE_BACKUP.md`](../docs/PORTABLE_BACKUP.md).
