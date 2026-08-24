# Xanh Browser for Windows

This directory contains the native Windows edition built with .NET 10, WinUI 3,
Windows App SDK 2.4.0 and the Evergreen Microsoft Edge WebView2 Runtime. The
project pins .NET SDK 10.0.400 and stable WebView2 SDK 1.0.4129.50. Weekly
verifiers compare .NET release metadata and both Windows NuGet packages with
their official upstream indexes. At startup it
requests only the stable WebView2 release channel, sets the compatible-runtime
floor and checks the actual environment version before creating a controller
or loading any page. The WebView2 latest-stable verifier also requires that
floor's build components to match the pinned SDK, so a future SDK update cannot
silently retain an older runtime policy.

WebView2 is now an explicit migration fallback behind the
[`Xanh WebView`](https://github.com/LamPPKK/xanh-webview) contract, not the
long-term Xanh-owned Windows backend. The production replacement target is the
public [`LamPPKK/cef`](https://github.com/LamPPKK/cef) fork because CEF provides
an embeddable Chromium API for both x64 and ARM64. Cutover remains blocked on
reproducible CEF/Chromium builds, sandbox and process-recovery conformance,
signed packaging, notices/codecs review and parity with this WinUI edition.

## Requirements

- A Microsoft-supported Windows 11 release, or a serviced Windows 10
  Enterprise/LTSC/IoT edition listed in the .NET 10 supported-OS matrix.
  Build 19041 is only the technical TFM and Windows App SDK floor.
- Visual Studio 2026 with the WinUI application development workload, or the
  .NET 10.0.400 SDK and matching Windows SDK
- Evergreen WebView2 Runtime 151.0.4129.50 or newer

## Build and test

```powershell
dotnet test tests/XanhBrowser.Core.Tests/XanhBrowser.Core.Tests.csproj
dotnet build src/XanhBrowser.Windows/XanhBrowser.Windows.csproj `
  --configuration Release `
  -p:Platform=x64 `
  -p:XanhAdblockNativeDll=C:\absolute\path\to\xanh_adblock_core.dll
```

Create the self-contained verification bundle with:

```powershell
dotnet publish src/XanhBrowser.Windows/XanhBrowser.Windows.csproj `
  --configuration Release `
  --runtime win-x64 `
  --self-contained true `
  -p:Platform=x64 `
  -p:XanhAdblockNativeDll=C:\absolute\path\to\xanh_adblock_core.dll `
  --output ../../_artifact/windows-x64
```

The generated files are unsigned verification artifacts. A production build
must be signed with the dedicated Windows code-signing certificate and tested
against both x64 and ARM64 Evergreen WebView2 channels before distribution.

## Content blocking

Content blocking defaults on. Release builds fail unless they package the
architecture-matched `xanh_adblock_core.dll` produced from the pinned Rust
closure; CI also checks the required exports. Developer builds retain a small
managed Xanh baseline if the DLL is missing or rejected. WebView2 phase one
filters document-owned subresources and leaves all `Document` loads to the
existing navigation policy because the callback cannot safely distinguish a
top-level document from a subframe. Shared/service workers and WebSockets are
outside this phase's claim rather than being assigned a stale tab source. This
is intentionally narrower than uBlock Origin.

## Encrypted backup and sync

The command bar can export and import the cross-platform `.xanhbackup` format.
It includes regular tab URLs only and deliberately excludes InPrivate tabs,
cookies, passwords and cache. Use the Windows file picker to save it in an
OS-backed-up Documents folder, OneDrive, Google Drive for desktop or a Git
working tree. The same file can be imported by both Android Lite editions.

See [`../../docs/PORTABLE_BACKUP.md`](../../docs/PORTABLE_BACKUP.md) for the
wire format and safe provider workflow.

## Firefox Sync host

The WinUI command bar contains Firefox Sync setup, manual Sync, per-engine
switches, remote-tab presentation, vault controls and keep/delete disconnect.
OAuth opens in the system browser and returns through the registered
`xanh-browser-windows://accounts/oauth` protocol. AppLifecycle redirects that
callback to the one live Xanh Browser instance. The coordinator keeps the
expected OAuth `state` and PKCE-flow ownership only in memory, accepts exactly
the callback for the flow started by that process, and rejects callbacks after
restart before native completion. Application Services does not persist its
pending PKCE verifier, so an interrupted or ambiguous sign-in must be restarted
interactively. Exact-origin confirmation (including a non-default HTTPS port)
and protocol registration happen before the
flow starts; a rejected system-browser launch abandons the in-memory runtime and
reopens only previously committed state so retry remains available. Opaque
completed account/Sync state is encrypted with
user-bound DPAPI, while unlocking the local Logins key requires Windows Hello
or the device PIN and expires after five minutes/backgrounding. Window teardown
stops late UI delivery and asynchronously drains the current coordinator
operation before freeing the native runtime.

When the native Sync runtime is configured, the command bar also exposes
Bookmarks and History. Successful regular WebView2 navigation is recorded in
Places, current regular tabs are published before Sync, and the native library
shows all four Firefox bookmark roots plus the 500 most recent visits. Opening
a row always requires an explicit click. Rename/delete operations preserve the
exact bookmark GUID; history deletion uses the exact URL/timestamp visit.
InPrivate navigation is never recorded and cannot create, rename or delete a
bookmark. Remote tabs are validated as at most 100 devices/500 total tabs,
grouped by sanitized device name and never navigate until the user clicks the
specific HTTP(S) row. The ordinary verification build intentionally lacks the
native DLL, so it does not claim an independent local Places library yet.

Regular tabs install a document-start WebView2 credential bridge. A page can
only request the native chooser after a trusted pointer or keyboard event. The
host validates the top-level source URI, tab ID, per-navigation nonce, exact
HTTPS origin and bounded message before asking the native Sync core for its
already-sanitized credential set. InPrivate tabs never enable web messaging or
the bridge. WebView2's built-in autofill and password saving remain disabled.

Sync settings also expose a native password library for the currently selected
regular HTTPS site. It lists at most 100 bounded Logins records, masks password
values and can add, update or confirm-delete the selected exact native login
ID. The host requires Windows Hello/PIN-backed vault unlock, re-reads the
selected tab before and after each dialog/native operation and dismisses the
credential UI on navigation, tab switch, backgrounding or vault lock. HTTP,
InPrivate and stale contexts fail before native mutation; username, password,
field and aggregate JSON limits match the shared Rust contract.

Every Release artifact must carry the architecture-matched
`xanh_adblock_core.dll`; the ordinary verification artifact intentionally does
not carry the separately gated Firefox Sync DLL. Build the pinned blocker and
supply both DLL properties for a Sync-enabled artifact:

```powershell
cargo build --manifest-path ../../xanh-adblock-core/Cargo.toml --locked `
  --release --target x86_64-pc-windows-msvc
dotnet publish src/XanhBrowser.Windows/XanhBrowser.Windows.csproj `
  --configuration Release --runtime win-x64 --self-contained true `
  -p:Platform=x64 `
  -p:XanhAdblockNativeDll="$PWD/../../xanh-adblock-core/target/x86_64-pc-windows-msvc/release/xanh_adblock_core.dll" `
  -p:XanhSyncNativeDll=C:\artifacts\win-x64\xanh_sync_core.dll
```

For an approved Mozilla-hosted build, also pass
`-p:XanhFirefoxSyncMozillaHosted=true`,
`-p:XanhFxaProductionApproved=1` and `-p:XanhFxaClientId=<registered-id>`.
The build fails if any required value or DLL is missing. Without written
Mozilla approval, distribute only the HTTPS self-hosted configuration and run
`../../scripts/verify-sync-release.sh windows` with the required evidence.

## Security baseline

- Only bounded, canonical `http`, `https` and `about:blank` navigation reaches
  WebView2. Userinfo, invalid hosts/ports and malformed or oversized input fail
  closed.
- A small allowlist of bounded external schemes is handed to Windows only after
  raw and percent-encoded control characters have been rejected.
- Host objects remain disabled. Web messaging is enabled only in regular tabs
  for the bounded credential bridge and is checked against the exact current
  document, tab ID and navigation nonce.
- WebView2 autofill and password saving are disabled; Xanh's preview native
  picker requires Windows Hello/PIN vault unlock and explicit selection.
- Private tabs use WebView2 InPrivate controller options.
- WebView2 data lives under the user's local application-data directory, so an
  unpackaged install remains writable under protected application locations.
- Closed tabs close their controller. The first renderer or browser-process
  failure replaces the affected tab at its last validated web address through
  a fresh `Navigate` GET; it never calls `Reload` or restores a form body. A
  second failure stops automatic recovery instead of forming a crash loop.
- The app uses an Evergreen runtime so WebView2 security fixes arrive through
  the Microsoft Edge update channel independently of the app release.

The Sync-enabled Windows build remains release-gated until this bridge passes
forged-message, stale-navigation, renderer-crash and x64/ARM64 security tests
with a signed native DLL. Ordinary verification artifacts still omit that DLL.
