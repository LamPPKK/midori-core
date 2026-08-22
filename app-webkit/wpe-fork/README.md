# Xanh WPE Android source fork

This directory defines the reviewed source delta needed to move the Android WPE
preview from the published WPEView 0.3.3 artifact to the repository's current
WPE WebKit security baseline. It is a reproducible source-build contract, not a
prebuilt dependency and not approval to publish the edition.

## Locked inputs

- WPE Android: `WPE_ANDROID_REVISION` (the signed upstream `v0.3.3` release)
- WPE Android Cerbero: `CERBERO_REVISION`
- WPE WebKit: `WPE_RUNTIME_VERSION`
- Xanh delta: `patches/xanh-isolated-bridge.patch`
- Gradle 8.12 binary distribution: official SHA-256 pinned by the Xanh delta

The patch makes the bootstrap fail closed unless dependencies are built from
source, pins Cerbero and WPE WebKit 2.52.6 with the official tarball checksum,
pins the upstream Gradle wrapper download, adds 16 KiB linker alignment, and
exposes a bounded document-start bridge in a
named WebKit script world. The bridge is main-frame-only, transfers function
arguments as typed values, and removes its handler and scripts at teardown.
It also exposes a pre-load navigation policy callback containing the request,
user-gesture and redirect state. Xanh permits HTTP(S), blocks other WebKit
loads, and hands the four allowlisted external schemes to Android only for a
non-redirected user gesture and a resolvable browsable intent. Callback/JNI
exceptions fail closed.
The on-demand Sync host in `sync-feature-common/WpeCredentialBridge.kt` loads
this API reflectively only when `XANH_WPE_SOURCE_FORK` is true. It uses typed
calls both to authenticate the document nonce with a host challenge and to
require a boolean acknowledgement from the same document before updating login
usage. The published
Maven preview and any API drift keep password filling disabled.

## Verify and build

Use a dedicated Linux builder with JDK 17 and the exact upstream toolchain:
Android platform/build-tools 35, NDK 27.0.12077973 and CMake 3.31.1. The Xanh
host that consumes the resulting AAR is compiled and targeted with SDK 36;
these are separate build layers.

Start from a clean checkout at the exact revision:

```sh
git clone https://github.com/Igalia/wpe-android.git wpe-android
git -C wpe-android checkout --detach \
  "$(cat app-webkit/wpe-fork/WPE_ANDROID_REVISION)"
./scripts/verify-wpe-android-fork.sh wpe-android
```

The orchestrator creates a disposable local clone with a real `.git` directory,
applies the reviewed
patch, builds WPE WebKit and every dependency from source for both ABIs, builds
the release AAR, verifies every packaged ELF LOAD segment at 16 KiB, and then
creates an atomic evidence directory:

```sh
export ANDROID_SDK_ROOT=/opt/android-sdk
./scripts/build-wpe-android-fork.sh \
  "$PWD/wpe-android" \
  "$PWD/xanh-wpe-build-evidence"
```

The builder requires Linux, JDK 17, Python 3.10+ with `distro` and `venv`, and
the pinned Android SDK/NDK/CMake packages checked by the script.

Set `XANH_WPE_BUILD_TMPDIR` to a large local filesystem when `/tmp` cannot hold
a full dual-ABI WebKit/Cerbero build. The output is never overwritten and
contains the AAR plus checksum, `wpe-build-evidence.json`, a file-level
CycloneDX SBOM, the exact upstream WPE Android archive and Xanh patch, the exact
Cerbero revision and reviewed Cerbero patch, Cerbero's offline
corresponding-source bundle, the 16 KiB report, toolchain record and complete
build log. The generator rejects missing/extra ABIs, unclassified native
libraries, wrong runtime markers, malformed or content-drifted archives, any
tracked source delta outside the reviewed patches, and pin drift.
Recheck a downloaded evidence set before review with:

```sh
./scripts/create_wpe_build_evidence.py \
  --verify-directory /absolute/path/to/xanh-wpe-build-evidence
```

Verification rehashes every recorded file, reconstructs the AAR inventory and
SBOM, audits the bounded tar inventories and exact WPE source payload, checks
the current source pins and refuses a changed checksum sidecar. The public
generator is intentionally not a trust anchor: download and verify the
workflow's `github-attestation.sigstore.json` against the exact repository,
workflow and release commit as enforced by `verify-sync-release.sh wpe`.

The manual `WPE Android source build` workflow runs the same script on a JIT
single-job self-hosted runner labelled `xanh-wpe-android-ephemeral`, then
compiles the SDK 36 Xanh host and instrumentation APK against that exact
checksum and verifies the packaged host ELF files. The runner VM/container must
be destroyed after the job and must never be reused. This build job has only
`contents: read`, does not persist checkout credentials and cannot request an
OIDC token. A separate
GitHub-hosted job downloads only the fixed 16-subject checksum manifest and
attests those digests with GitHub OIDC/Sigstore. The source-build evidence and
attestation are separate artifacts named with the commit and run attempt; put
`github-attestation.sigstore.json` beside the 16 evidence files before running
the release gate. The immutable ephemeral runner image must be pre-provisioned
with the declared prerequisites; the workflow uses fresh per-job Android SDK, Gradle,
XDG and compiler-cache directories and does not mutate the machine through
`sudo`. The attestation binds what that runner produced, but cannot make a
compromised builder trustworthy. Regular pull requests continue to fetch and
apply-check both exact WPE Android and Cerbero revisions and run the lightweight
evidence-generator contract tests instead of rebuilding WebKit.

## Remaining production gates

The source patch and generated build evidence alone do not make WPE
production-ready. A reviewed artifact must still pass API 31/36 device tests,
bridge forgery, navigation-policy and process-recovery tests, browser-flow
tests, signing, source-availability review and independent security review.
Until those records exist,
`bundleWebKitProductionRelease` and the Firefox Sync WPE gate remain closed.
