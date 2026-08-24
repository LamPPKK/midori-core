# Third-party notices

## Brave adblock-rust 0.13.3

Xanh Browser can embed Brave's `adblock-rust` 0.13.3 at revision
`886d45dcf5283ce8eddc6d961e7dd27966ab23f2` as its shared native network-rule
engine. The crate and upstream source are licensed under the Mozilla Public
License 2.0 (MPL-2.0). The reviewed crates.io archive has SHA-256
`f44b96a666a23c12acad7c688bfe8638a7094e7eabe765b09a6864ab991c676d`.

- Source: <https://github.com/brave/adblock-rust>
- Release: <https://github.com/brave/adblock-rust/releases/tag/v0.13.3>
- License: <https://www.mozilla.org/MPL/2.0/>

Xanh currently uses the upstream crate without modifying its MPL-covered
source. Binary releases that enable the native engine must include this notice,
the applicable MPL license text, corresponding source location and an SBOM for
the exact Cargo closure. Filter-list content has its own license and provenance;
no third-party subscription is bundled unless its notice and snapshot identity
are recorded separately.

## Mozilla Application Services 155.0

Xanh Browser can link Mozilla Application Services 155.0 at revision
`c0fd8cea40c9b5dafc6604831f7bd7a8c096d313` for Mozilla Accounts and Firefox
Sync interoperability. Application Services and its component source files are
licensed under the Mozilla Public License 2.0 (MPL-2.0).

- Source: <https://github.com/mozilla/application-services>
- Release: <https://github.com/mozilla/application-services/releases/tag/v155.0>
- License: <https://www.mozilla.org/MPL/2.0/>

Any Xanh Browser modifications to MPL-covered files must remain available in
source form under MPL-2.0. Xanh Browser does not currently modify upstream
Application Services source; it pins and links the official release. Binary
release bundles must include this notice, an SBOM and the corresponding source
location.

## Java Native Access 5.18.1

The Android System WebView edition uses Java Native Access (JNA) 5.18.1 as the
direct, name-bound bridge to `xanh-adblock-core`'s reviewed C ABI. JNA is
dual-licensed under LGPL-2.1-or-later or Apache-2.0; Xanh elects Apache-2.0 for
this use.

- Source: <https://github.com/java-native-access/jna>
- Release notes: <https://github.com/java-native-access/jna/blob/5.18.1/CHANGES.md>
- License: <https://github.com/java-native-access/jna/blob/5.18.1/LICENSE>

Android binary releases must retain the applicable JNA license/notice material
and record the exact AAR in their locked Gradle dependency graph and SBOM.

## Mozilla Glean, NSS and transitive components

The official Android Application Services artifacts bring the Mozilla Glean
SDK, NSS and other transitive components. Their exact versions and
licenses are recorded by the release SBOM generated from the locked Gradle and
Cargo dependency graphs. No user telemetry is submitted by Xanh Browser Sync
v1; Mozilla library telemetry payloads are not uploaded by the application.

## WPE Android, WPEView and WPE WebKit

The Android WPE preview can use the WPEView 0.3.3 sources at revision
`1a8e367ff6a20b65eeb33e9a547f3ccf3017fc4d`, a pinned WPE Android Cerbero
checkout at `5e73f46751c7f7a4c7200ca0c86d950982db5ea6`, and WPE WebKit 2.52.6.
WPE Android/WPEView is distributed under LGPL-2.1-or-later; WebKit and the
native dependency bundle contain LGPL and permissively licensed components.

- WPE Android source: <https://github.com/Igalia/wpe-android>
- WPE WebKit 2.52.6: <https://wpewebkit.org/release/wpewebkit-2.52.6.html>
- WPE Android license: <https://github.com/Igalia/wpe-android/blob/v0.3.3/LICENSE.md>

Xanh's source changes are recorded in
`app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch` and
`app-webkit/wpe-fork/patches/cerbero-wpewebkit-2.52.6.patch`. Any distributed fork
artifact must provide the corresponding complete source, license texts,
notices, relinking materials where required and an SBOM for the exact binary.

## WebKit WinCairo source preview

The Windows WebKit preview builds the upstream WebKit WinCairo port from the
peeled `webkitgtk-2.52.6` tag at revision
`4fb33923db2f945803df49546f75867980365c08`. WebKit contains LGPL-2.1-or-later
and permissively licensed components; individual upstream file notices remain
authoritative.

- WebKit source: <https://github.com/WebKit/WebKit>
- Stable release: <https://webkitgtk.org/2026/08/19/webkitgtk2.52.6-released.html>
- Xanh source deltas: `platform/windows-webkit/patches/xanh-browser-webkit.patch`
  and `platform/windows-webkit/patches/xanh-credential-bridge.patch`

Any distributed WinCairo artifact must retain the applicable license texts and
notices and provide the corresponding complete source, both Xanh patches, relinking
materials where required and an SBOM for the exact shipped runtime and native
dependency closure.
