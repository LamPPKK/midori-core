# Mozilla Accounts / Firefox Sync

Xanh Browser uses Mozilla Application Services rather than implementing Sync
1.5 itself. Version 1 pins Application Services 155.0 at
`c0fd8cea40c9b5dafc6604831f7bd7a8c096d313`. Nightly artifacts are prohibited
from production.

## Data and behavior

Bookmarks, history, tabs and passwords use the upstream Places, Tabs and
Logins engines and the upstream Sync Manager. Engine switches are local to a
device. Remote tabs are grouped by device and are never opened automatically.
Because Application Services 155 stores engine registrations process-wide,
Xanh permits exactly one live Mozilla Sync runtime in each process; a second
profile must run in a separate process.
The first sync backs up and imports legacy bookmark/history data, verifies
counts, then lets the Mozilla engines merge local and remote records.

Sync is single-flight and runs after sign-in, on foreground when the last sync
is at least 15 minutes old, 30 seconds after local changes, on “Sync now”, and
through the platform background scheduler. A server backoff or `Retry-After`
always wins over a local request.

## Authentication and server configuration

OAuth runs in the system browser with PKCE/state handling in `fxa-client`.
Xanh never displays or collects a Mozilla password in a WebView. Each signed
edition needs its own production client ID and registered redirect URI.

Mozilla-hosted Accounts is preferred. Self-hosted mode requires an HTTPS
Accounts URL, HTTPS Token Server URL and a client ID issued by that deployment.
The confirmation dialog displays the Accounts domain before leaving Xanh.
TLS errors cannot be bypassed. A Firefox installation and Xanh Browser must be
configured against the same custom Accounts/Sync deployment to interoperate.

Production Mozilla-hosted builds require both `XANH_FXA_CLIENT_ID` and
`XANH_FXA_PRODUCTION_APPROVED=1`. Until approval exists, release metadata must
describe the feature as self-hosted only.

## Secrets and password vault

Account JSON, OAuth tokens, scoped keys, Sync metadata and the local Logins key
are excluded from logs, crash diagnostics and `.xanhbackup`.

- Android: account state is device-bound in Android Keystore; the Logins key
  is wrapped by a user-authenticated Keystore key.
- Apple: Keychain items are non-synchronizing and `ThisDeviceOnly`; the vault
  uses LocalAuthentication.
- Windows: the native adapter is paired with local DPAPI/Windows Hello storage.
- Linux: production integration must pair the native adapter with Secret
  Service; locked or missing Secret Service disables passwords without
  exposing a fallback plaintext key. This host integration remains gated.

The vault locks after five minutes idle and immediately when the app is
backgrounded. Fill requires an HTTPS exact-origin top frame, a currently valid
navigation, an unlocked vault and an explicit choice in native UI. Private
browsing never reads, writes or syncs credentials.

## Platform status and release gates

`xanh-sync-core` provides the shared Rust contract, UniFFI scaffolding and a C
ABI. Android standard consumes the official 155.0 AARs directly. Apple release
builds must package the official pinned XCFramework and generated Swift
bindings. Linux, WebView2 and WinCairo consume the C ABI.

Android Lite uses an on-demand Play dynamic feature. `sync-feature-common`
contains the UI, JobScheduler integration and password manager;
`sync-feature` adds the AndroidX WebKit document-start/message bridge. The base
APK contains neither the Rust runtime nor native Application Services
libraries until the user enables Sync. The WPE feature reuses the management
UI but never loads a privileged password-fill script.

The current Linux, Apple, Windows, WPE and WinCairo adapters are integration
boundaries, not production enablement. Their release gates stay closed until
the platform UI, secure-state lifecycle, native packaging and required bridge
tests are present. Environment flags are attestations backed by test evidence,
not switches that make an incomplete integration safe.

## Implementation snapshot (2026-08-21)

The shared implementation is pinned and reproducible: Rust unit tests pass,
the `mozilla` feature builds and passes Clippy with warnings denied, the C ABI
header passes a GLib-backed syntax check, and the source release gate passes.
Generated Kotlin and Swift bindings are checked in CI against the portable
UniFFI contract and the concrete `MozillaSyncRuntime` API.

The first real cross-platform data bridges are now present for Tabs and Places.
Generated Kotlin and Swift bindings expose typed UniFFI methods; Vala, C# and
WinCairo use the stable C ABI with bounded JSON. The core writes only regular
local HTTP(S) tabs to the upstream Tabs store, reports how many private tabs it
skipped, and returns sanitized remote tabs grouped by device. It never opens a
remote tab.

The Places bridge creates, reads, updates and deletes bookmark-tree records,
records regular local history visits, returns bounded recent history and
deletes an exact visit. Private history is excluded before the first database
write, and bookmark mutations originating in private mode are rejected by the
shared core. History retries are idempotent by canonical URL and timestamp,
including after a partially committed upstream batch. Xanh-created
bookmark/history URLs are canonical HTTP(S); non-web
bookmarks received from Firefox remain manageable but are explicitly marked
non-openable. Bookmark trees are traversed with bounded, non-recursive child
queries instead of Application Services' unbounded deepest-tree fetch. Native
Linux CI opens the production runtime and round-trips all
three data bridges against the pinned Mozilla stores through the C ABI.

The platform boundary tests currently pass locally: 13 Apple tests cover the
contract and device-only Keychain/LocalAuthentication policy, while 21 Windows
tests cover the contract, P/Invoke surface and DPAPI/Windows Hello policy. The
Lite Android build produces both System WebView and WPE dynamic features. Its
base-module growth is 758,772 bytes, below the 1 MiB limit, and Application
Services native libraries appear only in the on-demand Sync split.

This evidence is not a production compatibility claim. The following release
evidence is still required:

- Mozilla production client IDs, registered redirects and Sync scope approval,
  or a documented HTTPS self-hosted deployment;
- disposable-account Firefox-to-Xanh interoperability for all four engines;
- signed artifacts, the complete device/OS/WebView matrix and remote CI for the
  exact release commit;
- message/FFI fuzzing, secret-redaction review and an independent security
  review;
- complete Linux, Apple and Windows runtime UI/native packaging integrations,
  including host wiring for the Tabs and Places data bridges;
- an isolated credential bridge plus 16 KiB-clean native libraries for WPE,
  and the equivalent bridge/vault/package evidence for WinCairo.

Until every applicable item is recorded, Sync remains release-gated on that
edition. A successful verification build is not permission to advertise
Mozilla-hosted Firefox compatibility.

WPE remains blocked while WPEView lacks an isolated document-start/message
bridge and while every native library has not passed 16 KiB page-size checks.
WinCairo remains blocked until its isolated bridge, vault and packaged native
core pass security tests. `scripts/verify-sync-release.sh` enforces these
conditions; setting a flag without the corresponding audit evidence is not a
valid release process.

## Required interoperability testing

Release testing uses disposable staging/self-hosted accounts and must cover
create/update/delete from both Firefox and Xanh, two-device conflicts, long
offline periods, account password changes, collection reset, remote wipe,
expired tokens and server backoff. No credentials or test tokens belong in the
repository or CI logs.
