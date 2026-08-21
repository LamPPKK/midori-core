# Xanh Browser 1.0 release runbook

This runbook covers Xanh Browser for Linux, Apple and Windows, Xanh Browser
Lite for Android, and the two experimental WebKit variants.
The full Android edition has a separate checklist in the
[Android repository](https://github.com/LamPPKK/midori-android/blob/codex/xanh-browser-modernization/RELEASING.md).

Do not publish a production artifact while any required gate below is missing.

## Release identity

| Product | Application ID | Version |
| --- | --- | --- |
| Linux desktop | `io.github.lamppkk.xanhbrowser` | `1.0.0` |
| iOS / iPadOS | `io.github.lamppkk.xanhbrowser` | `1.0.0` / `10000` |
| macOS | `io.github.lamppkk.xanhbrowser.macos` | `1.0.0` / `10000` |
| Windows | `XanhBrowser.Windows` | `1.0.0` |
| Windows WebKit preview | `XanhBrowser.WebKit` | `1.0.0` |
| Android Lite | `io.github.lamppkk.xanhbrowser.lite` | `1.0.0` / `10000` |
| Android Lite WebKit preview | `io.github.lamppkk.xanhbrowser.lite.webkit` | `1.0.0` / `10000` |

The archival desktop baseline is `legacy-midori-9.0`. The production release
tag is `v1.0.0` and must reference the reviewed release commit.

## Prerequisites

- Push access to this repository and access to its GitHub Actions results
- Linux with the dependencies listed in [README.md](README.md)
- JDK 17, Android SDK 36 and an emulator/device matrix for API 26, 30, 33 and 36
- `flatpak-builder`, `appstreamcli`, GPG and an offline source-release key
- Access to the Lite Play listing and its dedicated Play App Signing upload key
- Xcode 26+, Apple Developer membership, dedicated distribution certificates,
  provisioning profiles and App Store Connect records for macOS and universal
  iOS/iPadOS
- Windows 10/11 x64 and ARM64 test systems, .NET 8, Windows App SDK 2.3.1,
  Evergreen WebView2 Runtime 150+ and a dedicated Windows code-signing
  certificate
- The four Lite signing values below, supplied through the environment or the
  matching private Gradle properties

| Environment variable | Purpose |
| --- | --- |
| `XANH_LITE_KEYSTORE` | Upload-key keystore path |
| `XANH_LITE_STORE_PASSWORD` | Keystore password |
| `XANH_LITE_KEY_ALIAS` | Upload-key alias |
| `XANH_LITE_KEY_PASSWORD` | Upload-key password |

The Android WebKit preview uses a distinct upload key and the equivalent
`XANH_WEBKIT_KEYSTORE`, `XANH_WEBKIT_STORE_PASSWORD`,
`XANH_WEBKIT_KEY_ALIAS` and `XANH_WEBKIT_KEY_PASSWORD` values. A WebKit build
must never reuse the regular Lite key.

GitHub source-release automation additionally requires
`XANH_RELEASE_GPG_PRIVATE_KEY` as a base64-encoded private key and
`XANH_RELEASE_GPG_KEY` as its key ID. Never store any key or password in Git.

## 1. Prepare the candidate

1. Confirm the worktree is clean and the candidate commit is on the intended
   release branch.
2. Confirm the application IDs and versions in CMake, Gradle, desktop metadata,
   the Flatpak manifest and Play metadata.
3. Search shipping sources for obsolete product IDs and dependencies. Only
   licenses, historical changelog entries and the desktop importer may retain
   the historical product name.
4. Require green GitHub Actions results for Linux, Android Lite, WebKit
   editions, instrumentation, Apple, Windows, CodeQL and dependency review.

Verification:

```sh
git status --short
git grep -n -E 'webkit2gtk-4\.0|gtk\+-3\.0|libsoup-2\.4|org\.midori'
```

The first command must print nothing. The second may only match explicitly
allowed historical material, never a shipping dependency or application ID.

## 2. Validate Linux desktop

1. Build and run the full test suite on Linux:

   ```sh
   cmake -S . -B _build -G Ninja \
     -DCMAKE_BUILD_TYPE=Release \
     -DCMAKE_INSTALL_PREFIX=/usr
   cmake --build _build
   ctest --test-dir _build --output-on-failure
   cmake --build _build --target validate-metadata
   ```

2. Validate all GTK4 UI files and runtime linkage:

   ```sh
   pkg-config --atleast-version="$(cat WEBKITGTK_MIN_VERSION)" webkitgtk-6.0
   pkg-config --modversion webkitgtk-6.0
   for file in ui/*.ui; do gtk4-builder-tool validate "$file"; done
   ldd _build/xanh-browser
   ```

3. Run application and WebExtension checks under Wayland and X11. Exercise TLS
   errors, media permissions, downloads, private mode, session recovery,
   profile import and every native plugin.

Verification: tests must pass without warnings, WebKitGTK must be 2.52.6 or
newer, and `ldd` must contain no GTK3, WebKitGTK 4.0 or libsoup 2 library.

## 3. Build and inspect Flatpak

```sh
flatpak-builder --force-clean --sandbox _flatpak-build \
  flatpak/io.github.lamppkk.xanhbrowser.yml
flatpak info --show-permissions io.github.lamppkk.xanhbrowser
```

Install the candidate on a clean Linux profile and repeat the core browsing,
download, private-mode, TLS and permission checks. Publish it to the beta remote
before production.

Verification: the installed application must report the expected ID/version,
start under Wayland and X11, and expose no permission beyond the reviewed
Flatpak manifest.

## 4. Validate and sign Android Lite

1. Run the local verification pipeline:

   ```sh
   ./gradlew --no-daemon \
     :backup-core:testDebugUnitTest \
     :app:lintDebug \
     :app:testDebugUnitTest \
     :app:assembleDebug \
     :app:assembleAndroidTest \
     :app:bundleRelease
   ```

2. Run `connectedDebugAndroidTest` on API 26, 30, 33 and 36, including phone,
   tablet and foldable profiles and multiple stable System WebView versions.
3. Exercise navigation, predictive back, rotation/process death, downloads,
   sharing, external schemes, file upload, geolocation, privacy clearing and
   encrypted backup import/export through an Android Documents provider.
4. Export the four `XANH_LITE_*` values and build the signed candidate:

   ```sh
   ./gradlew --no-daemon bundleProductionRelease
   ```

Verification: `verifyReleaseSigning` must pass, the AAB must be signed by the
Lite upload key, and a Play-generated APK must install as
`io.github.lamppkk.xanhbrowser.lite` version `1.0.0` (`10000`) on a clean
device. A plain `bundleRelease` artifact is unsigned and must never be uploaded.

### Android WPE WebKit preview

Build the separately installable preview with:

```sh
./gradlew --no-daemon \
  :backup-core:testDebugUnitTest \
  :app-webkit:lintDebug \
  :app-webkit:testDebugUnitTest \
  :app-webkit:assembleDebug \
  :app-webkit:assembleAndroidTest \
  :app-webkit:bundleRelease
```

Run connected tests on physical/emulated API 31 and 36 arm64/x86_64 targets.
Exercise TLS rejection, navigation, media, rotation/process death, large-page
devices and encrypted backup round-trips with Lite and Windows.

The initial preview pins WPEView 0.3.3, which embeds WPE WebKit 2.50.6, and
Android lint reports its arm64 `libFLAC.so` as not 16 KiB page aligned. Both
are production blockers. Do not suppress that lint warning or publish this
edition until a reviewed WPEView artifact embeds WPE WebKit 2.52.6 or newer,
all native libraries pass the 16 KiB check and the guarded
`bundleWebKitProductionRelease` task succeeds with the distinct WebKit key.
Bundle the reviewed WebKit/WPEView third-party notices and fulfill all source
availability obligations before distribution.

## 5. Validate Apple and Windows

Before producing source artifacts, validate the new native editions.

### Firefox Sync release gate (all editions)

Before enabling Sync in any signed artifact, build `xanh-sync-core` with the
`mozilla` feature against the exact revision in
`xanh-sync-core/APPLICATION_SERVICES.lock`, generate an SBOM and include
`THIRD_PARTY_NOTICES.md`. Run `./scripts/verify-sync-release.sh <edition>` for
the target and retain evidence for every environment flag it checks.

Mozilla-hosted releases require a separately registered client ID/redirect URI
and written production approval for each application identity. Otherwise the
release must be explicitly self-hosted-only and Firefox must be configured to
the same HTTPS Accounts/Sync deployment. Never put OAuth tokens, scoped keys,
account JSON, local Logins keys or test credentials in Git, CI logs, crash
reports or `.xanhbackup`.

The candidate is blocked until disposable-account testing covers two-way
bookmark/history/tab/password create/update/delete, conflict, long offline,
password change, collection reset, remote wipe, expiry and backoff. Inspect
databases, logs and crash output for plaintext secrets and complete independent
FFI/bridge fuzzing and security review. WPE and WinCairo Sync remain blocked by
their isolated-bridge/vault guards even if another edition passes.

For Lite, first publish the reviewed Android AAR to a private/local Maven
repository, then build the on-demand splits explicitly:

```sh
./gradlew -p ../midori-android \
  :sync-core:publishReleasePublicationToBuildRepository
./gradlew \
  -PxanhEnableSyncFeature=true \
  -PxanhSyncSelfHostedOnly=true \
  -PxanhSyncRepository=../midori-android/sync-core/build/maven \
  :sync-feature-common:lintDebug \
  :app:bundleRelease :app-webkit:bundleRelease
./scripts/verify-lite-sync-size.sh \
  /path/to/base-only.aab app/build/outputs/bundle/release/app-release.aab
```

Replace `xanhSyncSelfHostedOnly` with the registered client-ID/approval
properties only after written Mozilla approval. Retain the base-only bundle
used by the size comparison. The AAB is the `lite-with-sync` GitHub artifact;
use Play delivery or a reviewed `bundletool` split set for installation rather
than repackaging it as a monolithic APK.

### Apple

1. Run `swift test --package-path platform/apple` with Xcode 26 or newer.
2. Build `XanhBrowser-macOS` and the universal `XanhBrowser-iOS` scheme in
   Release configuration. Exercise phone and tablet layouts, rotation, process
   restoration, regular/private tabs, navigation, downloads, file input,
   camera/microphone/location prompts and external schemes on physical devices.
3. Archive with the dedicated distribution profiles. Validate the macOS App
   Sandbox and hardened runtime, notarize the direct macOS build if one is
   distributed, and submit the signed archives to App Store Connect.
4. For Sync builds, package the pinned official Application Services
   XCFramework/checksum, verify non-synchronizing `ThisDeviceOnly` Keychain
   entries and LocalAuthentication lock/background behavior, build with
   `XANH_SYNC_SWIFT_FLAGS=-DXANH_ENABLE_FIREFOX_SYNC`, and confirm the callback
   is `xanh-browser-macos://accounts/oauth` or
   `xanh-browser-ios://accounts/oauth` for the target. Then run
   `./scripts/verify-sync-release.sh apple`.

Verification: both archives must report the intended bundle ID/version, contain
no private signing material, pass App Store validation and install from TestFlight
or the notarized distribution channel on clean devices.

### Windows

1. Run the core tests and publish both architectures:

   ```powershell
   dotnet test platform/windows/tests/XanhBrowser.Core.Tests/XanhBrowser.Core.Tests.csproj -c Release
   dotnet publish platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj -c Release -r win-x64 --self-contained true -p:Platform=x64
   dotnet publish platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj -c Release -r win-arm64 --self-contained true -p:Platform=ARM64
   ```

2. Test multi-tab, InPrivate, clear-data, download, permissions, external
   schemes, encrypted backup import/export and recovery from a WebView2 process
   failure on current Windows 10 and Windows 11 with current Evergreen Stable
   Runtime. Decode the shared Android golden backup vector and round-trip a
   provider-hosted file in both directions.
3. Sign every executable and package with the dedicated certificate, verify the
   timestamp and signature on a separate clean system, then run Microsoft
   Defender and SmartScreen submission checks.
4. For Sync builds, pass the architecture-matched C ABI DLL using
   `-p:XanhSyncNativeDll=<path>`. An approved Mozilla-hosted build must also use
   `-p:XanhFirefoxSyncMozillaHosted=true`,
   `-p:XanhFxaProductionApproved=1` and
   `-p:XanhFxaClientId=<registered-id>`; otherwise keep the build self-hosted.
   Confirm the registered callback is
   `xanh-browser-windows://accounts/oauth`, protect account state with DPAPI
   and vault access with Windows Hello, then run
   `./scripts/verify-sync-release.sh windows`.

Verification: x64 and ARM64 packages must install cleanly, retain a valid
signature after download, and use the serviced Evergreen Runtime rather than a
stale bundled browser engine.

### Windows WebKit/WinCairo preview

The WebKit variant is a separate x64 source build; it is not an engine switch
inside the WinUI application. Follow `platform/windows-webkit/README.md` and
build the exact revision in `platform/windows-webkit/WEBKIT_REVISION` with:

```powershell
.\platform\windows-webkit\scripts\Build-XanhBrowserWebKit.ps1 `
  -WebKitSource C:\src\WebKit
```

Verify the branding patch on every revision update, run upstream WebKit tests,
audit the copied runtime dependency closure, sign every shipped PE file and
test navigation, TLS, download, media and process recovery on clean Windows 10
and Windows 11 x64 systems. The generated `ENGINE.txt` and executable SHA-256
must match the reviewed build.

This preview is not production-ready until its upstream MiniBrowser-based UI
has the same encrypted backup import/export surface as the WinUI and Android
editions. Windows ARM64 support also remains unavailable in upstream WinCairo.

## 6. Produce signed source artifacts

With `XANH_RELEASE_GPG_KEY` set to the offline release key ID:

```sh
./scripts/release-source.sh
sha256sum --check xanh-browser-1.0.0.tar.xz.sha256
gpg --verify xanh-browser-1.0.0.tar.xz.asc xanh-browser-1.0.0.tar.xz
```

Verification: checksum and detached-signature verification must both succeed
from a separate clean directory. The `v1.0.0` tag also runs the signed-source
and Flatpak workflows.

## 7. Promote in order

1. Android full and Lite internal testing
2. Android full and Lite closed testing
3. Linux Flatpak beta
4. Apple TestFlight and signed Windows preview ring
5. Android full and Lite production
6. Apple/Windows production after store and platform gates
7. Linux Flatpak production and signed source archive

Do not skip a stage. Resolve every blocker/high finding from lint, dependency
review, CodeQL and the Play pre-launch report before promotion.

## Final verification

- All signed products install cleanly with the intended name, ID and version.
- Core browsing, privacy and recovery checklists pass on every supported target.
- `.xanhbackup` golden-vector and provider round-trips pass between Android
  Lite and Windows; no private state appears in the decoded payload.
- CI is green for the exact release commit and tag.
- No release surface advertises Android legacy-data import, Manifest V3 or
  complete browser-extension compatibility.
- Release notes link the checksum and detached signature for the source archive.

## Rollback and escalation

- Before production, reject the candidate, fix it on the release branch and
  restart this runbook from step 1.
- During a staged Play rollout, halt the rollout. Publish a higher version code
  for any replacement; never reuse `10000` after it has reached production.
- For Flatpak, stop promotion of the affected commit and republish only a tested,
  signed replacement. Do not move or recreate the existing release tag.
- If an upload or source-signing key may be exposed, stop immediately, revoke or
  rotate the affected key through Play/GPG procedures, remove the secret from CI
  and audit repository history before continuing.
