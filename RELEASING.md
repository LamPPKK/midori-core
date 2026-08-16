# Xanh Browser 1.0 release runbook

This runbook covers Xanh Browser for Linux and Xanh Browser Lite for Android.
The full Android edition has a separate checklist in the
[Android repository](https://github.com/LamPPKK/midori-android/blob/codex/xanh-browser-modernization/RELEASING.md).

Do not publish a production artifact while any required gate below is missing.

## Release identity

| Product | Application ID | Version |
| --- | --- | --- |
| Linux desktop | `io.github.lamppkk.xanhbrowser` | `1.0.0` |
| Android Lite | `io.github.lamppkk.xanhbrowser.lite` | `1.0.0` / `10000` |

The archival desktop baseline is `legacy-midori-9.0`. The production release
tag is `v1.0.0` and must reference the reviewed release commit.

## Prerequisites

- Push access to this repository and access to its GitHub Actions results
- Linux with the dependencies listed in [README.md](README.md)
- JDK 17, Android SDK 36 and an emulator/device matrix for API 26, 30, 33 and 36
- `flatpak-builder`, `appstreamcli`, GPG and an offline source-release key
- Access to the Lite Play listing and its dedicated Play App Signing upload key
- The four Lite signing values below, supplied through the environment or the
  matching private Gradle properties

| Environment variable | Purpose |
| --- | --- |
| `XANH_LITE_KEYSTORE` | Upload-key keystore path |
| `XANH_LITE_STORE_PASSWORD` | Keystore password |
| `XANH_LITE_KEY_ALIAS` | Upload-key alias |
| `XANH_LITE_KEY_PASSWORD` | Upload-key password |

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
4. Require green GitHub Actions results for Linux, Android Lite, instrumentation,
   CodeQL and dependency review.

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
   for file in ui/*.ui; do gtk4-builder-tool validate "$file"; done
   ldd _build/xanh-browser
   ```

3. Run application and WebExtension checks under Wayland and X11. Exercise TLS
   errors, media permissions, downloads, private mode, session recovery,
   profile import and every native plugin.

Verification: tests must pass without warnings, and `ldd` must contain no GTK3,
WebKitGTK 4.0 or libsoup 2 library.

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
     lintDebug \
     testDebugUnitTest \
     assembleDebug \
     assembleAndroidTest \
     bundleRelease
   ```

2. Run `connectedDebugAndroidTest` on API 26, 30, 33 and 36, including phone,
   tablet and foldable profiles and multiple stable System WebView versions.
3. Exercise navigation, predictive back, rotation/process death, downloads,
   sharing, external schemes, file upload, geolocation and privacy clearing.
4. Export the four `XANH_LITE_*` values and build the signed candidate:

   ```sh
   ./gradlew --no-daemon bundleProductionRelease
   ```

Verification: `verifyReleaseSigning` must pass, the AAB must be signed by the
Lite upload key, and a Play-generated APK must install as
`io.github.lamppkk.xanhbrowser.lite` version `1.0.0` (`10000`) on a clean
device. A plain `bundleRelease` artifact is unsigned and must never be uploaded.

## 5. Produce signed source artifacts

With `XANH_RELEASE_GPG_KEY` set to the offline release key ID:

```sh
./scripts/release-source.sh
sha256sum --check xanh-browser-1.0.0.tar.xz.sha256
gpg --verify xanh-browser-1.0.0.tar.xz.asc xanh-browser-1.0.0.tar.xz
```

Verification: checksum and detached-signature verification must both succeed
from a separate clean directory. The `v1.0.0` tag also runs the signed-source
and Flatpak workflows.

## 6. Promote in order

1. Android full and Lite internal testing
2. Android full and Lite closed testing
3. Linux Flatpak beta
4. Android full and Lite production
5. Linux Flatpak production and signed source archive

Do not skip a stage. Resolve every blocker/high finding from lint, dependency
review, CodeQL and the Play pre-launch report before promotion.

## Final verification

- All three signed products install cleanly with the intended name, ID and version.
- Core browsing, privacy and recovery checklists pass on every supported target.
- CI is green for the exact release commit and tag.
- No release surface advertises Windows, macOS, Android legacy-data import,
  Manifest V3 or complete browser-extension compatibility.
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
