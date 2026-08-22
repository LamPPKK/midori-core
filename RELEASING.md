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
- AndroidX WebKit 1.17.0 resolved from Google Maven for the Lite System WebView
  artifact; do not substitute an alpha compatibility library in production
- `flatpak-builder`, `appstreamcli`, GPG and an offline source-release key
- Access to the Lite Play listing and its dedicated Play App Signing upload key
- Xcode 26+, Apple Developer membership, dedicated distribution certificates,
  provisioning profiles and App Store Connect records for macOS and universal
  iOS/iPadOS
- Windows 10/11 x64 and ARM64 test systems, .NET 8, Windows App SDK 2.3.1,
  Evergreen WebView2 Runtime 151.0.4129.50+ and a dedicated Windows code-signing
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
5. Run `python3 scripts/verify_webkit_latest.py` with network access and confirm
   the shared floor plus WinCairo tag/revision match the newest official stable
   WebKitGTK tag. An odd-minor development tag is never a release substitute.
6. Run `python3 scripts/verify_androidx_webkit_latest.py` with network access
   and confirm every Lite/System WebView Gradle module equals the newest stable
   AndroidX WebKit version published in Google Maven. Prereleases never satisfy
   this gate.

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

4. For a Sync-enabled candidate, start with a populated pre-Sync profile and
   verify that the private migration snapshot is mode `0600`, the stored
   checksum matches it, all source rows are processed, every safe/eligible
   record is acknowledged and rejected-row counts are audited before the
   completion marker is committed. Verify retry creates no duplicate and
   repeated imports retain at most one verified snapshot. Include
   invalid/userinfo URLs, invalid
   timestamps, oversized/control-character titles and more than 200 tabs;
   valid records and the remaining engines must still sync. Confirm
   Places-backed bookmark/history panels, local-tab publication, remote-tab
   grouping with explicit opening, and that Clear Browsing Data empties local
   Places history.
   Repeat the clear while disconnected and verify local Places is cleared
   immediately. Also force runtime initialization to fail, verify the UI reports
   a partial clear, and confirm the pending deletion runs before later
   migration/Sync. Kill the process after each native/local history-clear phase;
   on restart, confirm legacy history/session, compatibility mirrors and
   snapshots are emptied before the marker is acknowledged or Sync can run.
   Repeat the interactive Clear if the process stopped during WebKit website-
   data deletion. Verify Clear Browsing Data and Remove from This Device leave
   no migration snapshots on disk, including when multiple windows are open.
   Kill the process in turn after the write-ahead Remove marker, native
   disconnect, Secret Service cleanup, SQLite reset and snapshot prune. Confirm
   each restart preserves the original keep/delete choice and finishes all
   remaining cleanup. Also inject a SQLite reset failure and verify the local
   recovery markers survive until both the mirror and snapshots are removed.
   Verify the application marker is atomically durable and mode `0600`, and
   that a pending marker blocks scheduled, pre-sleep and manual Sync as well as
   reconnect until cleanup acknowledgement succeeds.

5. On a clean regular profile, unlock the Logins vault through the reviewed OS
   user-presence flow, activate a password field with a real pointer/keyboard
   event and choose a username in the native GTK picker. Confirm the selected
   value fills only the exact committed HTTPS top frame. Repeat with HTTP,
   userinfo, cross-origin iframe, synthetic events, navigation during the
   picker, tab switch/close, renderer termination and a stale request ID/nonce;
   every case must fail closed. Confirm private tabs have no
   `xanhCredentialBridge` handler or script, the page world cannot reach the
   isolated-world function, focus loss locks/cancels the vault/picker, and
   logs, crash output and `.xanhbackup` contain no plaintext credential.

Verification: tests must pass without warnings, WebKitGTK must be 2.52.6 or
newer, and `ldd` must contain no GTK3, WebKitGTK 4.0 or libsoup 2 library. Sync
evidence must belong to the exact candidate commit and must not contain account
state, tokens, scoped keys or the Logins key. Password Sync remains blocked
unless `XANH_LINUX_USER_PRESENCE_EVIDENCE` proves fresh OS authentication and
`XANH_LINUX_SECURITY_REVIEW_EVIDENCE` covers the isolated bridge above.

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
   Force renderer termination in foreground and background: the exact failed
   WebView must be detached and destroyed before the callback returns, recovery
   must wait for foreground, restore only a bounded HTTP(S) GET target and stop
   after one attempt rather than looping.
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

For the source-built candidate, use the exact revisions and patch in
`app-webkit/wpe-fork/`. CI must first prove that the patch still applies to the
locked WPE Android source. On the dedicated Linux runner, invoke
`scripts/build-wpe-android-fork.sh` with a clean upstream checkout and a new
output directory. The script requires the pinned upstream Android 35 library
toolchain, builds both arm64 and x86_64 from source, generates corresponding
source plus a file-level CycloneDX SBOM, and runs
`scripts/verify-android-16k.sh` before publishing its atomic evidence set. The
consuming Xanh app must then compile with SDK 36 against the exact recorded AAR
checksum and the packaged APK must pass the same 16 KiB check. The manual
`.github/workflows/wpe-android-source-build.yml` workflow encodes this lane for
a pre-provisioned JIT runner labelled `xanh-wpe-android-ephemeral` without
running `sudo`. The VM/container must accept exactly one job and be destroyed;
a persistent self-hosted runner is forbidden because upstream build code must
not influence a later release. The workflow pins every third-party action by
commit, uses unique job-local Android SDK,
Gradle, XDG and compiler-cache directories, and gives the source-build job only
read access without persisted checkout credentials or OIDC. A separate
GitHub-hosted job accepts only the fixed 16-subject checksum manifest and
creates the GitHub OIDC/Sigstore attestation for every evidence file and exact
host APK. Download the source-build artifact and its matching attestation
artifact for the same commit and `run_attempt`, then place
`github-attestation.sigstore.json` in the source-build evidence directory.
Supply the following
commit-bound files to `scripts/verify-sync-release.sh wpe`:

- `XANH_WPE_FORK_BUILD_EVIDENCE`: source revisions, commands, toolchain and AAR
  SHA-256;
- `XANH_WPE_16K_EVIDENCE`: the generated AAR report; retain alongside it the
  workflow's second report for every ELF packaged by the consuming application;
- `XANH_WPE_BRIDGE_REVIEW_EVIDENCE`: isolated-world, top-frame, host-challenge
  nonce binding, exact-origin/request-ID reply acknowledgement, background
  teardown, idempotent late-attachment bootstrap, navigation-race,
  forged-message review, and the pre-load policy callback's fail-closed JNI,
  user-gesture and redirect behavior,
  including execution of `WpeForkApiContractTest` with
  `XANH_WPE_SOURCE_FORK=true`;
- `XANH_WPE_DEVICE_TEST_EVIDENCE`: API 31/36 arm64/x86_64 browser and Sync tests,
  including HTTP(S), unsupported schemes, subframes, redirects and allowlisted
  external intents with and without a user gesture;
- `XANH_WPE_SBOM_EVIDENCE`: the generated SBOM, notices, WPE Android source plus
  Xanh patch, the exact Cerbero source plus its reviewed patch, and Cerbero
  corresponding-source bundle;
- `XANH_WPE_GITHUB_ATTESTATION_EVIDENCE`: the downloaded
  `github-attestation.sigstore.json` from the same workflow run;
- `XANH_WPE_HOST_APK_EVIDENCE`, `XANH_WPE_HOST_TEST_APK_EVIDENCE`,
  `XANH_WPE_HOST_16K_EVIDENCE` and `XANH_WPE_HOST_TOOLCHAIN_EVIDENCE`: the exact
  checksum-bound SDK 36 verification APK, instrumentation APK, packaged-ELF
  report and host toolchain hashes from that attested evidence directory.

These evidence paths supplement the existing fail-closed boolean gates; they
do not turn a source patch or unsigned verification artifact into a release.
The WPE gate rehashes the complete evidence set, reconstructs the AAR inventory
and CycloneDX document, opens and audits all source archives, binds generated
paths to one directory, reruns the ELF alignment verifier against the recorded
AAR and host APK, and verifies the GitHub attestation against the exact release
commit and `LamPPKK/midori-core` signer workflow. This verification APK remains
non-production evidence; the signed production artifact and device/security
gates are still mandatory. Attestation prevents post-build substitution and
binds provenance; it does not make a compromised self-hosted builder trusted,
so the hardened dedicated runner and independent release review remain part of
the security boundary.

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
   Reject overlong web/search input, userinfo, invalid DNS/IPv4/IPv6 hosts and
   ports, raw or percent-encoded controls, unsupported schemes, external
   redirects, subframe handoffs and synthetic link activation. Confirm a
   direct trusted main-frame link opens each allowlisted external scheme once
   on macOS, iPhone and iPad, including pointer and touch input as applicable.
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
5. On macOS, iPhone and iPad, verify the native credential picker after Face
   ID/Touch ID/passcode unlock. Cover cancel/retry, exact-origin denial,
   cross-origin frames, forged or oversized messages, stale navigation,
   renderer/process recovery and background vault lock. Confirm private tabs
   have no credential script or message handler and inspect logs/crash reports
   for plaintext credentials.

Verification: both archives must report the intended bundle ID/version, contain
no private signing material, pass App Store validation and install from TestFlight
or the notarized distribution channel on clean devices.

### Windows

Before building Windows artifacts, run
`python3 scripts/verify_webview2_latest.py` with network access. The candidate
must pin the newest stable Microsoft.Web.WebView2 SDK from the official NuGet
index; prerelease or dynamic versions never satisfy this gate. On an isolated
Windows test machine, confirm Runtime 150 and non-stable Beta/Dev/Canary
channels are rejected before a controller or page is created, while Runtime
151.0.4129.50 and newer stable Evergreen installations start normally.

1. Run the core tests and publish both architectures:

   ```powershell
   dotnet test platform/windows/tests/XanhBrowser.Core.Tests/XanhBrowser.Core.Tests.csproj -c Release
   dotnet publish platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj -c Release -r win-x64 --self-contained true -p:Platform=x64
   dotnet publish platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj -c Release -r win-arm64 --self-contained true -p:Platform=ARM64
   ```

2. Test multi-tab, InPrivate, clear-data, download, permissions, external
   schemes, encrypted backup import/export and recovery from a WebView2 process
   failure on current Windows 10 and Windows 11 with current Evergreen Stable
   Runtime. Force both renderer and browser-process exits from a committed GET,
   then from a form POST: the first failure may replace the tab only at a
   bounded validated URL through a fresh GET, must never resubmit the body, and
   a second failure must stop rather than loop. Exercise oversized URLs,
   userinfo, invalid hosts/ports and percent-encoded control characters in
   external handoffs; each must fail closed. Decode the shared Android golden
   backup vector and round-trip a provider-hosted file in both directions. For
   a Sync-enabled candidate, also verify Windows Hello/PIN unlock, exact-origin
   credential selection, cancel and retry, stale navigation/process failure,
   forged or oversized messages, background vault lock and the absence of any
   bridge in InPrivate tabs.
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
must match the reviewed build. CI must also resolve `WEBKIT_RELEASE_TAG` to the
exact commit in `WEBKIT_REVISION`; do not ship a moving `main` snapshot or a
commit older than the shared `WEBKITGTK_MIN_VERSION` security baseline.
The source-fork isolated-world C API must compile in the Windows build and pass
message-world, request/reply, duplicate-handler and teardown tests. Its presence
alone is not a credential bridge: keep Sync disabled until the WinCairo host,
vault, packaged native core and security evidence are complete.
The pre-load navigation-action policy must also reject overlong/malformed URLs,
userinfo, invalid ports, script-created external navigation and every external
redirect. Verify that only a direct user gesture can delegate bounded `mailto:`
or `tel:` URLs and that regular credential-free HTTP(S) plus the narrow internal
blank/srcdoc set still load. A single click token must never launch more than
one external handler, including pages that loop or synthesize link clicks.
Verify WebKit only exposes a button for trusted, button-down link events and that
`HTMLElement.click()` plus manually dispatched click events remain blocked even
inside a real user-event handler. Keyboard-only activation is intentionally
blocked in this preview until it has an equivalent trusted-event signal.
Terminate the WinCairo WebProcess for crash, memory and CPU reasons. The first
unexpected termination may restore the current committed back-forward item
exactly once only when it has no stored HTTP body; form submissions and other
body-bearing items must never be restored automatically. Start a provisional
bodyless navigation over a committed form item and terminate before commit to
confirm the old item remains blocked. A second termination before or after
recovery must stop without a loop. Confirm explicit Reload restores one attempt
subject to the same committed-item check, requested-by-client termination is
not undone, and live automation attach/detach never blocks on a modal dialog.

Run the WinCairo CNG portable-backup suite against both fixed golden vectors,
then export/import through OneDrive, Google Drive for desktop and a local Git
working tree. Confirm tampering, wrong passwords, oversized input, unsafe URLs
and partial writes all fail without replacing the destination or opening any
window. Windows ARM64 support remains unavailable in upstream WinCairo.

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
  Lite, Windows WebView2 and WinCairo; no private state appears in the decoded
  payload.
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
