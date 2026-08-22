# Xanh Browser for Windows

This directory contains the native Windows edition built with WinUI 3,
Windows App SDK 2.3 and the Evergreen Microsoft Edge WebView2 Runtime. The
project pins the stable WebView2 SDK 1.0.4129.50 and verifies it weekly against
the official NuGet flat-container index.

## Requirements

- Windows 10 version 2004 (build 19041) or newer
- Visual Studio 2022 with the WinUI application development workload, or the
  .NET 8 SDK and matching Windows SDK
- Evergreen WebView2 Runtime 151.0.4129.50 or newer

## Build and test

```powershell
dotnet test tests/XanhBrowser.Core.Tests/XanhBrowser.Core.Tests.csproj
dotnet build src/XanhBrowser.Windows/XanhBrowser.Windows.csproj `
  --configuration Release `
  -p:Platform=x64
```

Create the self-contained verification bundle with:

```powershell
dotnet publish src/XanhBrowser.Windows/XanhBrowser.Windows.csproj `
  --configuration Release `
  --runtime win-x64 `
  --self-contained true `
  -p:Platform=x64 `
  --output ../../_artifact/windows-x64
```

The generated files are unsigned verification artifacts. A production build
must be signed with the dedicated Windows code-signing certificate and tested
against both x64 and ARM64 Evergreen WebView2 channels before distribution.

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
callback to the one live Xanh Browser instance. Opaque state is encrypted with
user-bound DPAPI, while unlocking the local Logins key requires Windows Hello
or the device PIN and expires after five minutes/backgrounding.

Regular tabs install a document-start WebView2 credential bridge. A page can
only request the native chooser after a trusted pointer or keyboard event. The
host validates the top-level source URI, tab ID, per-navigation nonce, exact
HTTPS origin and bounded message before asking the native Sync core for its
already-sanitized credential set. InPrivate tabs never enable web messaging or
the bridge. WebView2's built-in autofill and password saving remain disabled.

The normal unsigned verification artifact does not carry the Rust native DLL
and therefore fails closed. Supply an architecture-matched DLL explicitly:

```powershell
dotnet publish src/XanhBrowser.Windows/XanhBrowser.Windows.csproj `
  --configuration Release --runtime win-x64 --self-contained true `
  -p:Platform=x64 `
  -p:XanhSyncNativeDll=C:\artifacts\win-x64\xanh_sync_core.dll
```

For an approved Mozilla-hosted build, also pass
`-p:XanhFirefoxSyncMozillaHosted=true`,
`-p:XanhFxaProductionApproved=1` and `-p:XanhFxaClientId=<registered-id>`.
The build fails if any required value or DLL is missing. Without written
Mozilla approval, distribute only the HTTPS self-hosted configuration and run
`../../scripts/verify-sync-release.sh windows` with the required evidence.

## Security baseline

- Only valid `http`, `https` and `about:blank` navigation reaches WebView2.
- A small allowlist of external schemes is handed to Windows after validation.
- Host objects remain disabled. Web messaging is enabled only in regular tabs
  for the bounded credential bridge and is checked against the exact current
  document, tab ID and navigation nonce.
- WebView2 autofill and password saving are disabled; Xanh's preview native
  picker requires Windows Hello/PIN vault unlock and explicit selection.
- Private tabs use WebView2 InPrivate controller options.
- WebView2 data lives under the user's local application-data directory, so an
  unpackaged install remains writable under protected application locations.
- Closed tabs close their controller; renderer crashes reload and browser
  process crashes recreate the affected tab at its last safe web address.
- The app uses an Evergreen runtime so WebView2 security fixes arrive through
  the Microsoft Edge update channel independently of the app release.

The Sync-enabled Windows build remains release-gated until this bridge passes
forged-message, stale-navigation, renderer-crash and x64/ARM64 security tests
with a signed native DLL. Ordinary verification artifacts still omit that DLL.
