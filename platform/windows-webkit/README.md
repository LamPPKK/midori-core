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

The patch rejects file/non-web address-bar navigation, defaults to HTTPS,
stops loading the upstream privileged injected bundle and disables Web
Inspector developer extras in the browser process. The build script also omits
that unused injected-bundle DLL from the packaged artifact.

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
Verify the revision/provenance file, remove unrelated upstream test binaries
from the package only after a dependency-closure audit, sign all shipped PE
files and test on clean Windows 10 and Windows 11 systems.

The portable `.xanhbackup` session format is currently exposed by the WinUI
edition and both Android Lite editions. It deliberately excludes cookies,
passwords, cache and private tabs. See
[`../../docs/PORTABLE_BACKUP.md`](../../docs/PORTABLE_BACKUP.md). Wiring it into
the upstream WinCairo UI is a separate release gate because that UI is rebuilt
with each pinned WebKit source baseline.
