# Xanh Browser for Windows

This directory contains the native Windows edition built with WinUI 3,
Windows App SDK 2.3 and the Evergreen Microsoft Edge WebView2 Runtime.

## Requirements

- Windows 10 version 2004 (build 19041) or newer
- Visual Studio 2022 with the WinUI application development workload, or the
  .NET 8 SDK and matching Windows SDK
- Evergreen WebView2 Runtime 150 or newer

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

## Security baseline

- Only valid `http`, `https` and `about:blank` navigation reaches WebView2.
- A small allowlist of external schemes is handed to Windows after validation.
- Host objects and web messaging are disabled because this edition exposes no
  native bridge to pages.
- Autofill and password saving are disabled for the 1.0 privacy baseline.
- Private tabs use WebView2 InPrivate controller options.
- The app uses an Evergreen runtime so WebView2 security fixes arrive through
  the Microsoft Edge update channel independently of the app release.
