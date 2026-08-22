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
The first sync backs up and imports legacy bookmark/history data, verifies that
all source rows were processed and every eligible record was acknowledged, then
lets the Mozilla engines merge local and remote records. Rejected unsafe-row
counts are emitted only as redacted local diagnostics. On Linux,
the import reads only from the verified immutable SQLite snapshot, marks
completion with its SHA-256 checksum and retains the legacy tables intact for
the rollback release cycle without treating them as a conflict resolver. The
coordinator retains at most the current verified snapshot; Clear Browsing Data
and “Remove from This Device” delete every migration snapshot and its checksum
metadata. The history deletion intent stays set until native Places, legacy
history/session rows, the compatibility mirror and migration snapshots are all
empty; migration and Sync remain blocked while it is pending. Snapshot deletion
is likewise write-ahead, so a process stop cannot lose a confirmed clear.
Failed cleanup is visible as a partial clear and is retried from non-secret
local markers. WebKit website-data deletion remains an interactive platform
operation; after a process stop during that phase, the user must repeat Clear
Browsing Data. “Remove from This Device” additionally atomically writes and fsyncs an
application-level mode-0600 intent (including its parent directory) before
calling the native host; the host writes its own durable keep/delete phase
marker before changing Firefox Account state. Initialization
repeats the idempotent native, Secret Service, snapshot and compatibility-
mirror cleanup, and clears the application marker only after every phase has
completed. Failure to acknowledge that marker blocks reconnect and Sync, so a
stale removal intent cannot later delete newly created account data. Concurrent
startup/Settings recovery is coalesced, and the host is reopened in a clean
disconnected state before the marker is acknowledged. Marker removal fsyncs
the parent directory; an acknowledgement error remains fail-closed in memory
and is retried before reconnect.

Sync is single-flight and runs after sign-in, on foreground when the last sync
is at least 15 minutes old, 30 seconds after local changes, on “Sync now”, and
through the platform background scheduler. A server backoff or `Retry-After`
always wins over a local request.

## Authentication and server configuration

OAuth runs in the system browser with PKCE/state handling in `fxa-client`.
Xanh never displays or collects a Mozilla password in a WebView. Each signed
edition needs its own production client ID and registered redirect URI.

The callback endpoints are deliberately distinct so one installed edition
cannot claim another edition's OAuth response:

- Linux: `xanh-browser://accounts/oauth`
- Android standard: `xanh-browser-android://accounts/oauth`
- Android Lite System WebView: `xanh-browser-lite://accounts/oauth`
- Android Lite WPE: `xanh-browser-wpe://accounts/oauth`
- macOS: `xanh-browser-macos://accounts/oauth`
- iOS/iPadOS: `xanh-browser-ios://accounts/oauth`
- Windows WebView2: `xanh-browser-windows://accounts/oauth`

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
- Linux: the native host stores account JSON, Sync metadata and the Logins key
  in Secret Service under a per-profile identifier. Missing or locked Secret
  Service fails closed without a plaintext fallback; the vault locks after five
  minutes and whenever the GTK window loses focus.

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
libraries until the user enables Sync. The System WebView bridge accepts only
main-frame messages for the exact committed HTTPS origin, requires a recent
trusted pointer or keyboard gesture, rejects synthetic DOM events, and asks the
shared runtime for a bounded exact-origin form-credential set before presenting
native UI. The published WPEView build reuses the management UI without a
password-fill script. When a checksum-verified source-fork AAR is selected, the
WPE feature reflectively requires its reviewed API and installs a persistent
main-frame document-start script in a named isolated world. Each document
generates a cryptographic nonce, then proves it using a host-generated random
challenge and monotonic navigation generation before credential requests are
accepted. Exact source origin, live HTTPS URL, tab and Activity foreground state
are checked before the picker and again before dispatch. The eventual isolated-
world fill separately rechecks origin, generation, challenge, nonce, request ID
and renderer visibility. Login usage is updated only after the document
returns a successful typed acknowledgement. Credentials never use page-world
evaluation or string interpolation. Installing the dynamic feature over an
already loaded
page runs the same idempotent bootstrap in its isolated world without reloading
or resubmitting that page. The source fork also supplies a pre-load navigation
policy callback. It keeps unsupported schemes out of WPE and permits an
allowlisted external intent only for a non-redirected user gesture; the
published Maven preview retains only the later page-start fallback and cannot
satisfy this release gate.

Linux now has an asynchronous GTK host for account initialization, system-
browser OAuth, exact callback routing, Secret Service persistence, manual/
startup/scheduled/pre-sleep Sync, server backoff, vault lock and keep/delete
disconnect. Its bounded data coordinator migrates legacy bookmarks/history,
publishes regular tabs, refreshes bookmark/history compatibility panels from
Places, and groups remote tabs by device behind explicit user activation. A
schema-v2 compatibility mirror retains each 12-character Places bookmark GUID
and each history visit's exact millisecond timestamp. The GTK panels require a
native confirmation before deleting a row, then call the upstream Places
delete operation and mark the mutation for Sync. Offline-only rows have no
invented identity and are removed from the pending legacy import instead.
The bookmark panel also exposes a bounded native title editor. Its update JSON
contains the exact GUID and sanitized title while URL, parent and position stay
unset, so no structural bookmark change is inferred. Rename/deletion is
rejected while the owning browser window is in a private tab.
Legacy and offline-only rename/delete commits migration-marker invalidation in
the same SQLite transaction, so a process stop cannot make a later import skip
the mutation.
Local tombstones also remove the corresponding rollback row; a remote visit is
marked explicitly so a same-second local legacy visit is never removed by
mistake.
Schema-v1 mirrors are cleared and rebuilt so an old URL or rounded timestamp is
never used as a deletion key. A
regular tab installs a document-start, top-frame-only credential script and
message handler in the named
`io.github.lamppkk.xanhbrowser.credentials` isolated WebKit world. A trusted
pointer/keyboard event opens a native GTK username picker; request ID,
navigation nonce, exact committed HTTPS URL and origin are rechecked before
the selected secret is passed as `GVariant` arguments into that same world.
Private tabs install neither the script nor the handler.
Clearing browsing data deletes local Places visits through the upstream API so
the history engine can propagate removals, including while the account is
disconnected but its local runtime remains available. If that runtime cannot be
opened, Xanh reports the partial clear, persists a non-secret pending-clear
marker and retries it before later migration or Sync. The standard build remains
fail-closed unless the native core and an approved Mozilla or HTTPS self-hosted
configuration are supplied. Windows now has a bounded WebView2 credential
picker backed by Windows Hello/PIN, exact source/origin checks and a per-
navigation nonce. Apple has the equivalent native picker backed by
LocalAuthentication, with its main-frame-only script and payload isolated in a
named `WKContentWorld`. Both remain fail-closed until pinned native artifacts
and platform bridge evidence are packaged and reviewed. WPE and WinCairo remain
integration boundaries rather than production enablement. Environment flags
are attestations backed by test evidence, not switches that make an incomplete
integration safe.

## Implementation snapshot (2026-08-22)

The shared implementation is pinned and reproducible: Rust unit tests pass,
the `mozilla` feature builds and passes Clippy with warnings denied, the C ABI
header passes a GLib-backed syntax check, and the source release gate passes.
Generated Kotlin and Swift bindings are checked in CI against the portable
UniFFI contract and the concrete `MozillaSyncRuntime` API.

The cross-platform data bridges are now present for Tabs, Places and the shared
Logins store contract.
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
Linux CI opens the production runtime and round-trips all four Sync data types
against the pinned Mozilla stores through the C ABI.

The Logins boundary now provides bounded exact-origin form credential
list/add/update/delete/touch operations through UniFFI and the stable C ABI.
It derives both stored origins from a strict HTTPS same-origin context, requires
an explicit native user action and an unlocked vault, rejects private browsing,
and filters HTTP-auth, userinfo, cross-origin and oversized upstream records.
Plaintext output is explicitly short-lived secret material. Android standard,
Android Lite, Apple, Linux and the gated Windows host now consume this boundary
through native pickers. No edition may ship filling until its picker, OS user-
presence policy and tab-ID/navigation-nonce bridge pass that platform's
security gate.

The Linux GTK host runs native C ABI/network calls and SQLite snapshot/hash
preparation away from the UI thread; size-bounded JSON assembly and panel updates
remain on GTK's main context.
OAuth is handed to `Gtk.UriLauncher`, the desktop file registers the dedicated
`xanh-browser` callback scheme, and the exact callback origin/path plus
code/state are revalidated before reaching Rust. Secure state is keyed by a
SHA-256 profile identifier in Secret Service; no account state or local Logins
key is written to the profile directory. Disabled-build policy tests and a
production-link boundary test run in CI. Its first-run migration creates a
mode-0600 SQLite snapshot inside a mode-0700 directory without a world-readable
creation window, verifies complete source traversal and eligible-record
acknowledgements before committing a checksum marker, and is safe to retry.
Places data is exposed through separate
compatibility mirrors so the rollback tables remain intact; local tabs are
published with a global, regular-only 200-record/4-MiB-safe host bound across
all open windows. Malformed
legacy rows are skipped per record without blocking later Sync, and remote tabs
are only opened after row activation. The Linux Logins UI is a bounded native
GTK picker, and its WebKitGTK bridge uses `webkit_user_script_new_for_world()`
plus `webkit_web_view_call_async_javascript_function()` rather than the default
page world or deprecated JavaScript APIs. Payload parsing rejects unknown
message shapes, stale request IDs/nonces, non-HTTPS or mismatched origins and
navigation changes. This is still not Linux production enablement until the
user-presence and independent security evidence below are complete.

HTTP Basic/Digest authentication is deliberately outside the Logins engine and
credential bridge. Linux handles a matching HTTPS challenge with a separate
bounded native prompt and `NONE` WebKit persistence; HTTP, proxy, cross-origin,
retry and unsupported authentication schemes are canceled rather than queried
from or written to Firefox Sync.

The current Linux preview asks Secret Service for the Logins key. A locked
collection can show the desktop keyring prompt, but an already-unlocked
collection does not prove fresh user presence. Linux password Sync therefore
remains production-blocked until the release evidence demonstrates an audited
OS authentication/user-presence mechanism in addition to Secret Service
storage.

Apple now provides system-browser OAuth callback routing, a single-flight actor,
engine switches, server backoff, remote-tab presentation, Keychain/
LocalAuthentication vault state, restart-safe keep/delete disconnect intent and
a main-frame-only isolated `WKContentWorld` credential picker that is absent
from private tabs.
Windows provides the equivalent WinUI coordinator, single-instance protocol
activation, DPAPI/Windows Hello persistence, a gated exact-origin WebView2
credential picker and architecture-specific native DLL packaging input. Both
hosts keep Mozilla-hosted mode disabled unless the
build carries an approved client ID; HTTPS self-hosted setup remains available.

The platform boundary tests currently pass locally: 34 Apple tests cover the
contract, coordinator, navigation/recovery policy and device-only
Keychain/LocalAuthentication policy,
while 30 Windows tests cover the contract, coordinator, P/Invoke surface and
DPAPI/Windows Hello policy. The
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
- complete audited Linux OS user-presence and the Sync-enabled Flatpak
  packaging, plus Apple/Windows native packaging and reviewed platform
  credential-bridge evidence;
- an isolated credential bridge plus 16 KiB-clean native libraries for WPE,
  and the equivalent bridge/vault/package evidence for WinCairo.

Until every applicable item is recorded, Sync remains release-gated on that
edition. A successful verification build is not permission to advertise
Mozilla-hosted Firefox compatibility.

The published WPEView 0.3.3 artifact remains blocked because it lacks an
isolated document-start/message bridge and not every native library passes
16 KiB page-size checks. The pinned source delta in `app-webkit/wpe-fork/`
implements the missing bridge against WPE WebKit 2.52.6, but it remains a
candidate. Its Android host now consumes that API only when AAR checksum
verification enables the source-fork build flag, and it fails closed on any
API drift. The Linux source-build orchestrator now emits the exact dual-ABI AAR,
checksum, ELF alignment report, file-level CycloneDX SBOM, toolchain record and
validated WPE Android/Cerbero upstream archives, reviewed patches and Cerbero
corresponding-source bundle as one atomic evidence set. The manual workflow
builds that set without repository credentials or OIDC in a single-job
ephemeral self-hosted runner that is destroyed after completion.
A separate GitHub-hosted attestation job receives only the fixed checksum
manifest and cryptographically binds the set and the exact SDK 36 host APKs to
its repository, workflow and commit through GitHub OIDC/Sigstore. The AAR must
still pass
host packaging, device, interoperability and security evidence gates in
`RELEASING.md`.
The pinned WinCairo source delta now exposes bounded named-isolated-world C APIs
for user scripts, request/reply message handlers and deterministic per-world
teardown without restoring the privileged injected bundle. Its MiniBrowser host
now enforces bounded credential-free HTTP(S) navigation before load and permits
only trusted, direct user-clicked, non-redirected `mailto:`/`tel:` delegation;
it relies on WebKit's existing mouse-button field, which is populated only for
a trusted button-down event, and consumes the gesture once. It does
not register the credential bridge yet, so WinCairo remains blocked until
host origin/nonce/private-mode validation, the vault and packaged native core
pass security tests. `scripts/verify-sync-release.sh` is a fail-closed mechanical
prerequisite check, not an audit substitute. Its Linux production
mode requires evidence files for the Sync-enabled build, Secret Service,
four-engine interoperability, data migration, Flatpak and security review;
release reviewers must still validate that those files belong to the exact
release commit and satisfy this checklist.

The Linux gate accepts paths through `XANH_LINUX_SYNC_BUILD_EVIDENCE`,
`XANH_LINUX_SECRET_SERVICE_EVIDENCE`, `XANH_LINUX_INTEROP_EVIDENCE`,
`XANH_LINUX_DATA_MIGRATION_EVIDENCE`, `XANH_LINUX_FLATPAK_EVIDENCE` and
`XANH_LINUX_USER_PRESENCE_EVIDENCE` and
`XANH_LINUX_SECURITY_REVIEW_EVIDENCE`. Merely creating placeholder files is a
release-process failure even though the shell gate can only verify presence.

## Required interoperability testing

Release testing uses disposable staging/self-hosted accounts and must cover
create/update/delete from both Firefox and Xanh, two-device conflicts, long
offline periods, account password changes, collection reset, remote wipe,
expired tokens and server backoff. No credentials or test tokens belong in the
repository or CI logs.
