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

The patch makes the bootstrap fail closed unless dependencies are built from
source, pins Cerbero and WPE WebKit 2.52.6 with the official tarball checksum,
adds 16 KiB linker alignment, and exposes a bounded document-start bridge in a
named WebKit script world. The bridge is main-frame-only, transfers function
arguments as typed values, and removes its handler and scripts at teardown.

## Verify and build

Start from a clean checkout at the exact revision and verify the patch before
building:

```sh
git clone https://github.com/Igalia/wpe-android.git wpe-android
git -C wpe-android checkout --detach \
  "$(cat app-webkit/wpe-fork/WPE_ANDROID_REVISION)"
./scripts/verify-wpe-android-fork.sh wpe-android
git -C wpe-android apply \
  "$PWD/app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch"
```

Use Linux, JDK 17, Android SDK 36, NDK 27.0.12077973 and the upstream bootstrap
requirements. Build both supported architectures from source:

```sh
cd wpe-android
./tools/scripts/bootstrap.py --build --arch=arm64
./tools/scripts/bootstrap.py --build --arch=x86_64
./gradlew --no-daemon :wpeview:assembleRelease
```

Run `scripts/verify-android-16k.sh` against the resulting AAR before it can be
consumed by a release build. Record the exact artifact SHA-256, an SBOM, license
notices and the source archive used to reproduce it.

## Remaining production gates

The source patch alone does not make WPE production-ready. A reviewed artifact
must still pass all native-library 16 KiB checks, API 31/36 device tests, bridge
forgery and process-recovery tests, browser-flow tests, signing, source
availability and independent security review. Until those records exist,
`bundleWebKitProductionRelease` and the Firefox Sync WPE gate remain closed.
