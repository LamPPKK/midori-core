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

## Preview limitations

WPE Android is still an experimental embedding port. The current published
WPEView artifact bundles WPE WebKit 2.50.6 and a `libFLAC.so` that Android lint
reports as not 16 KiB page aligned. It must not be promoted to production until
an upstream artifact with WPE WebKit 2.52.5 or newer passes lint, device and
browser-flow testing.

Any distributed artifact must also carry the required WebKit/WPEView and
third-party license notices and satisfy the corresponding source-availability
obligations.

The APK contains its own native engine and is therefore much larger than the
System WebView edition. It is intentionally distributed as a separate
application so it cannot silently replace the production engine.

The published WPEView navigation client does not yet expose a policy callback
equivalent to Android WebView's URL override. Non-HTTP(S) page navigations are
therefore stopped instead of launched; an external `mailto`, `tel`, `geo` or
`market` URI entered explicitly in the address bar is still handed to a
validated Android intent.

Encrypted `.xanhbackup` import/export is compatible with Android Lite and the
Windows WebView2 edition. See [`../docs/PORTABLE_BACKUP.md`](../docs/PORTABLE_BACKUP.md).
