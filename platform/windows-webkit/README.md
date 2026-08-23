# Xanh Browser WebKit for Windows

This is the real WebKit/WinCairo x64 edition of Xanh Browser. It is separate
from the production WinUI/WebView2 edition in `platform/windows` and builds
against a full, pinned upstream WebKit checkout.

## Status and supported architecture

- Product: **Xanh Browser WebKit 1.0.0 preview**
- Engine: upstream WebKit Windows port (Cairo graphics and libcurl networking)
- Baseline: `webkitgtk-2.52.6`, resolved to the exact commit in
  `WEBKIT_REVISION`
- Architecture: Windows x64 only
- Distribution: unsigned developer artifact; not a production release

WebKit does not publish a supported Windows embedding SDK or redistributable
runtime. The official Windows port must be built from source, and upstream only
supports 64-bit Windows. For that reason this edition is not an engine toggle
inside the ARM64-capable WinUI application.

## Build

Install the current WebKit Windows prerequisites, then prepare a dedicated
checkout at the pinned revision:

```powershell
git clone https://github.com/WebKit/WebKit.git C:\src\WebKit
git -C C:\src\WebKit checkout (Get-Content .\platform\windows-webkit\WEBKIT_REVISION)
```

From a WebKit command prompt at this repository root:

```powershell
.\platform\windows-webkit\scripts\Build-XanhBrowserWebKit.ps1 `
  -WebKitSource C:\src\WebKit
```

The script verifies a clean exact revision, resolves `WEBKIT_RELEASE_TAG`
against the official upstream WebKit remote and checks that it matches both the
pinned commit and the repository-wide stable WebKit baseline before it applies
the reviewed branding and URL-hardening patch, replaces the icon for the build,
updates official
WebKitRequirements, builds Release with the upstream script, copies the x64
runtime directory to a new `_artifact/xanh-browser-windows-webkit-x64`
directory, writes engine provenance and a standard SHA-256 file, then restores
the checkout. It refuses an output directory that already exists so stale
runtime files cannot leak into a new artifact.

The reviewed source deltas also expose **Export encrypted backup** and **Import
encrypted backup** in the File menu and connect the validating credential
bridge to MiniBrowser. The build script temporarily copies the standalone CNG
codec plus seven credential-bridge/DPAPI/Windows-Hello sources into the pinned tree,
records every source hash in `ENGINE.txt`, and removes the files while restoring the checkout.
Export places the selected window first and includes up to 49 other
regular HTTP(S) windows. Import authenticates and validates the complete file
before opening any new regular windows; cookie/credential/form stores, cache
and private state are never read into the format. Full URLs are included, so
query or fragment data may still be sensitive and is protected by the backup
password. Unicode domain names are canonicalized with Windows IDN support and
then checked by the same ASCII pre-load policy used for navigation.

`scripts/verify_webkit_latest.py` independently enumerates official WebKit Git
tags, ignores odd-minor development series, selects the greatest stable semantic
version and requires this edition's tag and peeled commit to match it. CI runs
the verifier on relevant changes and every Monday so a newly published stable
security baseline cannot remain unnoticed.

The patch rejects file/non-web address-bar navigation, defaults to HTTPS,
stops loading the upstream privileged injected bundle and disables Web
Inspector developer extras in the browser process. The build script also omits
that unused injected-bundle DLL from the packaged artifact.

The source delta also adds bounded Xanh-specific C APIs for main-frame user
scripts and request/reply message handlers in the same named isolated
`API::ContentWorld`. Invalid or overlong world/handler names fail closed, the
handler preserves the actual source world in `WKScriptMessageRef`, and explicit
per-world removal APIs provide deterministic teardown. MiniBrowser now
registers a main-frame-only credential request handler in that world. A random
native tab ID and document challenge are bound to the exact committed,
userinfo-free HTTPS URL; provisional navigation, same-document URL changes and
renderer termination invalidate pending requests. The host rejects unknown or
oversized fields, forged origins, subframes and stale request IDs. Its picker
boundary is asynchronous, single-flight and lifetime-weak; it rechecks the
foreground window, committed URL and generation after completion, while
navigation, renderer termination and teardown complete stale requests as
`unavailable`. The committed preview deliberately has no credential picker
callback, so every validated request receives `unavailable` and no secret is
filled. Sync remains blocked until the compiled DPAPI/Windows Hello primitives,
packaged native core and reviewed picker are connected; the validating bridge must not
be treated as a substitute.

The build also compiles a cancellable C++/WinRT Windows Hello helper using the
desktop `IUserConsentVerifierInterop::RequestVerificationForWindowAsync` owner-
HWND API. It generation-checks completion and catches every activation/device
error as denial. The helper is not wired to the bridge yet, and because that
interop requires Windows build 22000, password access must fail closed on older
Windows releases.

The compiled `XanhDpapiSecretStore` provides fixed slots for account state,
Sync state, the Logins key, scheduling, engine selection and a disconnect
intent below the current user's `FOLDERID_LocalAppData`. Each value is capped
at 4 MiB, protected without machine scope or interactive DPAPI UI, bound to its
slot with optional entropy, and wrapped in an application-level SHA-256
envelope. Reads reject reparse points, malformed lengths and altered data.
Writes use a random same-directory `CREATE_NEW` temporary file, flush its
contents and publish it with a replace-existing, write-through same-volume rename;
the API also provides idempotent fixed-slot removal. DPAPI binds confidentiality
to the Windows user profile, not to the Xanh process; another process already
running as that user can invoke DPAPI, deny access or delete ciphertext. Callers
must therefore treat every error as a locked/unavailable vault. The preview compiles this store but does not yet wire
it to the credential picker or native Sync runtime.

The preview host also applies a navigation-action policy before WebKit loads a
request. Bounded, credential-free HTTP(S) URLs and the narrow `about:blank` /
`about:srcdoc` set remain inside WebKit. `mailto:` and `tel:` are delegated to
Windows only for a direct, unconsumed user gesture when WebKit explicitly
allows external schemes. Xanh requires WebKit's existing trusted, button-down
link-click signal; WebKit exposes no mouse button for an untrusted event, so
`HTMLElement.click()` and dispatched synthetic events fail closed without a new
IPC field. The accepted gesture token is consumed before launch,
so one click can delegate at most one external URI; redirects and every other
scheme fail closed. The
policy is unit-tested independently from the Windows build, and the custom
navigation-action API preserves WebKit's internal redirect signal so a page
cannot disguise an external redirect as a click.
Every source-revision update must revalidate the upstream trusted-button
invariant in `WebMouseEvent.cpp`; CI fetches and checks that exact file from the
pinned commit.

Web-process termination is recovered at most once per user-requested
navigation, and only when the current committed back-forward item has no stored
HTTP body. WebKit restores that item after a terminated process; this is
deliberately not described as a cache-bypassing origin reload. Form submissions
and every other body-bearing item are never restored automatically. Inspecting
the committed item at termination also prevents a provisional navigation from
making an older form entry appear safe. A completed recovery leaves the budget
exhausted, so another termination stops instead of forming a crash loop.
Address-bar loads, Back/Forward, explicit Reload and a trusted main-frame web
link grant a new single attempt, still subject to the committed-item check.
Client-requested termination is never undone, and the live automation state
suppresses modal failure dialogs.

The pinned commit is the peeled upstream `webkitgtk-2.52.6` tag rather than an
arbitrary `main` snapshot. The GTK release tag is used because WinCairo and GTK
are built from the same WebKit source tree, and this gives the Windows preview
an auditable stable source baseline that includes the fixes required by
WSA-2026-0005. The artifact contains the whole upstream `bin64` runtime because
WebKit does not provide a separately serviced Windows runtime. Security
releases therefore require updating `WEBKIT_RELEASE_TAG` and
`WEBKIT_REVISION` together, refreshing the patch, rebuilding and redistributing
the complete edition.

## Release gates

Before publishing, build on a clean Windows x64 host and run upstream WebKit
tests plus browser navigation, TLS, download, media and process-crash tests.
Navigation tests must include malformed and overlong URLs, userinfo, invalid
ports, redirect-to-external, script-created external navigation and direct
user-clicked `mailto:`/`tel:` links.
Process tests must cover crash, memory/CPU termination, termination during the
automatic restore, a successful recovery followed by another crash, explicit
user retry, refusal to restore a body-bearing item, provisional-navigation races
and client-requested termination.
Verify the revision/provenance file, remove unrelated upstream test binaries
from the package only after a dependency-closure audit, sign all shipped PE
files and test on clean Windows 10 and Windows 11 systems. Compile and exercise
the isolated-world C API with forged page-world messages, duplicate handler
names, invalid world names, navigation/process swaps and repeated teardown;
page JavaScript must never reach the isolated handler. Also run the committed
credential-policy suite, then attach an asynchronous test picker and prove
forged origin/tab/challenge/request IDs, concurrent or replayed completions,
subframes, provisional loads, same-document navigation, renderer termination
and host teardown cannot display or fill a credential. The default preview
must continue returning `unavailable` until the native vault gate is complete.

The portable `.xanhbackup` session format is exposed by this preview, the WinUI
edition and both Android Lite editions. It deliberately excludes cookies,
passwords, cache and private tabs. Before release, run the CNG golden-vector
suite and provider round-trips against Android and WinUI artifacts. See
[`../../docs/PORTABLE_BACKUP.md`](../../docs/PORTABLE_BACKUP.md).
