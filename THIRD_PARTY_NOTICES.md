# Third-party notices

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

## Mozilla Glean, JNA, NSS and transitive components

The official Android Application Services artifacts bring the Mozilla Glean
SDK, JNA, NSS and other transitive components. Their exact versions and
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
`app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch`. Any distributed fork
artifact must provide the corresponding complete source, license texts,
notices, relinking materials where required and an SBOM for the exact binary.
