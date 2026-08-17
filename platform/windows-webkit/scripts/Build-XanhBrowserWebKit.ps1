[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WebKitSource,

    [string]$OutputDirectory = "_artifact/xanh-browser-windows-webkit-x64",

    [switch]$SkipLibraryUpdate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
$sourceRoot = (Resolve-Path $WebKitSource).Path
$revision = (Get-Content (Join-Path $PSScriptRoot "../WEBKIT_REVISION") -Raw).Trim()
$patch = (Resolve-Path (Join-Path $PSScriptRoot "../patches/xanh-browser-webkit.patch")).Path
$icon = (Resolve-Path (Join-Path $repositoryRoot "platform/windows/src/XanhBrowser.Windows/Assets/XanhBrowser.ico")).Path
$mainIcon = Join-Path $sourceRoot "Tools/MiniBrowser/win/MiniBrowser.ico"
$smallIcon = Join-Path $sourceRoot "Tools/MiniBrowser/win/small.ico"

if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
    throw "The upstream WebKit Windows port supports x64 Windows only."
}

$actualRevision = (& git -C $sourceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualRevision -ne $revision) {
    throw "Expected WebKit revision $revision, found $actualRevision."
}

& git -C $sourceRoot diff --quiet
if ($LASTEXITCODE -ne 0) {
    throw "The WebKit source has tracked local changes. Use a clean checkout."
}
& git -C $sourceRoot diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    throw "The WebKit source has staged local changes. Use a clean checkout."
}

& git -C $sourceRoot apply --check --ignore-space-change $patch
if ($LASTEXITCODE -ne 0) {
    throw "The Xanh Browser WebKit patch does not apply to the pinned revision."
}

$mainIconBackup = [IO.Path]::GetTempFileName()
$smallIconBackup = [IO.Path]::GetTempFileName()
Copy-Item $mainIcon $mainIconBackup -Force
Copy-Item $smallIcon $smallIconBackup -Force

try {
    & git -C $sourceRoot apply --ignore-space-change $patch
    if ($LASTEXITCODE -ne 0) {
        throw "Could not apply the Xanh Browser WebKit patch."
    }
    Copy-Item $icon $mainIcon -Force
    Copy-Item $icon $smallIcon -Force

    Push-Location $sourceRoot
    try {
        if (-not $SkipLibraryUpdate) {
            & python Tools/Scripts/update-webkit-win-libs.py
            if ($LASTEXITCODE -ne 0) {
                throw "WebKitRequirements update failed."
            }
        }
        & perl Tools/Scripts/build-webkit --release --skip-library-update
        if ($LASTEXITCODE -ne 0) {
            throw "WebKit WinCairo build failed."
        }
    }
    finally {
        Pop-Location
    }

    $binaryDirectory = Join-Path $sourceRoot "WebKitBuild/Release/bin64"
    $browserExecutable = Join-Path $binaryDirectory "XanhBrowser.WebKit.exe"
    if (-not (Test-Path $browserExecutable)) {
        throw "Missing branded browser executable: $browserExecutable"
    }

    $output = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $OutputDirectory))
    $repositoryPrefix = $repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $output.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Output directory must be inside the Xanh Browser repository."
    }
    if (Test-Path $output) {
        throw "Output directory already exists; move it aside before building: $output"
    }
    New-Item -ItemType Directory -Path $output | Out-Null
    Copy-Item (Join-Path $binaryDirectory "*") $output -Recurse -Force
    $unusedInjectedBundle = Join-Path $output "MiniBrowserInjectedBundle.dll"
    if (Test-Path $unusedInjectedBundle) {
        Remove-Item $unusedInjectedBundle -Force
    }
    @(
        "Product: Xanh Browser WebKit 1.0.0 preview"
        "Engine: WebKit WinCairo"
        "WebKit revision: $revision"
        "Architecture: x64"
        "Built: $([DateTimeOffset]::UtcNow.ToString('O'))"
    ) | Set-Content (Join-Path $output "ENGINE.txt") -Encoding UTF8
    $executableName = "XanhBrowser.WebKit.exe"
    $executableHash = (Get-FileHash (Join-Path $output $executableName) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$executableHash  $executableName" |
        Set-Content (Join-Path $output "$executableName.sha256") -Encoding ascii
}
finally {
    & git -C $sourceRoot apply --reverse --check --ignore-space-change $patch 2>$null
    if ($LASTEXITCODE -eq 0) {
        & git -C $sourceRoot apply --reverse --ignore-space-change $patch
    }
    Copy-Item $mainIconBackup $mainIcon -Force
    Copy-Item $smallIconBackup $smallIcon -Force
    Remove-Item $mainIconBackup, $smallIconBackup -Force
}
