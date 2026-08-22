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
$releaseTag = (Get-Content (Join-Path $PSScriptRoot "../WEBKIT_RELEASE_TAG") -Raw).Trim()
$minimumVersion = (Get-Content (Join-Path $repositoryRoot "WEBKITGTK_MIN_VERSION") -Raw).Trim()
$patch = (Resolve-Path (Join-Path $PSScriptRoot "../patches/xanh-browser-webkit.patch")).Path
$icon = (Resolve-Path (Join-Path $repositoryRoot "platform/windows/src/XanhBrowser.Windows/Assets/XanhBrowser.ico")).Path
$portableBackupHeader = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhPortableBackup.h")).Path
$portableBackupImplementation = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhPortableBackup.cpp")).Path
$mainIcon = Join-Path $sourceRoot "Tools/MiniBrowser/win/MiniBrowser.ico"
$smallIcon = Join-Path $sourceRoot "Tools/MiniBrowser/win/small.ico"
$portableBackupHeaderDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhPortableBackup.h"
$portableBackupImplementationDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhPortableBackup.cpp"

if ($releaseTag -ne "webkitgtk-$minimumVersion") {
    throw "WinCairo release tag $releaseTag does not match the shared WebKit stable baseline $minimumVersion."
}
if ($revision -notmatch "^[0-9a-f]{40}$") {
    throw "WEBKIT_REVISION must contain exactly one lowercase 40-character Git object ID."
}

$upstreamTagOutput = @(& git ls-remote https://github.com/WebKit/WebKit.git "refs/tags/$releaseTag^{}")
$upstreamTagExitCode = $LASTEXITCODE
if ($upstreamTagExitCode -ne 0 -or $upstreamTagOutput.Count -ne 1) {
    throw "Could not resolve the official upstream WebKit tag $releaseTag."
}
$upstreamTagFields = ([string]$upstreamTagOutput[0]).Trim() -split "\s+"
if ($upstreamTagFields.Count -ne 2 -or $upstreamTagFields[1] -ne "refs/tags/$releaseTag^{}") {
    throw "Official WebKit tag $releaseTag returned an invalid reference."
}
$resolvedReleaseRevision = $upstreamTagFields[0]
if ($resolvedReleaseRevision -ne $revision) {
    throw "Official WebKit tag $releaseTag resolves to $resolvedReleaseRevision, expected $revision."
}

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
$initialUntracked = @(& git -C $sourceRoot ls-files --others --exclude-standard)
$initialUntrackedExitCode = $LASTEXITCODE
if ($initialUntrackedExitCode -ne 0 -or $initialUntracked.Count -ne 0) {
    throw "The WebKit source has untracked non-ignored files. Use a clean checkout."
}

& git -C $sourceRoot apply --check --ignore-space-change $patch
if ($LASTEXITCODE -ne 0) {
    throw "The Xanh Browser WebKit patch does not apply to the pinned revision."
}
if ((Test-Path $portableBackupHeaderDestination) -or (Test-Path $portableBackupImplementationDestination)) {
    throw "The pinned WebKit source unexpectedly contains Xanh portable-backup sources. Use a clean exact checkout."
}

$mainIconBackup = [IO.Path]::GetTempFileName()
$smallIconBackup = [IO.Path]::GetTempFileName()
Copy-Item $mainIcon $mainIconBackup -Force
Copy-Item $smallIcon $smallIconBackup -Force
$copiedPortableBackupFiles = @()
$buildFailure = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$output = $null
$outputCreatedByThisRun = $false
$patchApplied = $false
$portableBackupHeaderHash = $null
$portableBackupImplementationHash = $null

try {
    & git -C $sourceRoot apply --ignore-space-change $patch
    if ($LASTEXITCODE -ne 0) {
        throw "Could not apply the Xanh Browser WebKit patch."
    }
    $patchApplied = $true
    $copiedPortableBackupFiles += $portableBackupHeaderDestination
    Copy-Item $portableBackupHeader $portableBackupHeaderDestination
    $copiedPortableBackupFiles += $portableBackupImplementationDestination
    Copy-Item $portableBackupImplementation $portableBackupImplementationDestination
    $portableBackupHeaderHash = (Get-FileHash $portableBackupHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $portableBackupImplementationHash = (Get-FileHash $portableBackupImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant()
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
    if ((Get-FileHash $portableBackupHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $portableBackupHeaderHash
        -or (Get-FileHash $portableBackupImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $portableBackupImplementationHash
        -or (Get-FileHash $portableBackupHeader -Algorithm SHA256).Hash.ToLowerInvariant() -ne $portableBackupHeaderHash
        -or (Get-FileHash $portableBackupImplementation -Algorithm SHA256).Hash.ToLowerInvariant() -ne $portableBackupImplementationHash) {
        throw "Portable-backup sources changed during the WebKit build. Discard this build and retry from a stable checkout."
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
    $outputCreatedByThisRun = $true
    Copy-Item (Join-Path $binaryDirectory "*") $output -Recurse -Force
    $unusedInjectedBundle = Join-Path $output "MiniBrowserInjectedBundle.dll"
    if (Test-Path $unusedInjectedBundle) {
        Remove-Item $unusedInjectedBundle -Force
    }
    @(
        "Product: Xanh Browser WebKit 1.0.0 preview"
        "Engine: WebKit WinCairo"
        "Upstream release: $releaseTag"
        "WebKit revision: $revision"
        "Portable backup header SHA-256: $portableBackupHeaderHash"
        "Portable backup implementation SHA-256: $portableBackupImplementationHash"
        "Architecture: x64"
        "Built: $([DateTimeOffset]::UtcNow.ToString('O'))"
    ) | Set-Content (Join-Path $output "ENGINE.txt") -Encoding UTF8
    $executableName = "XanhBrowser.WebKit.exe"
    $executableHash = (Get-FileHash (Join-Path $output $executableName) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$executableHash  $executableName" |
        Set-Content (Join-Path $output "$executableName.sha256") -Encoding ascii
}
catch {
    $buildFailure = $_
}
finally {
    try {
        foreach ($copiedFile in $copiedPortableBackupFiles) {
            if (Test-Path $copiedFile) {
                try {
                    Remove-Item $copiedFile -Force
                }
                catch {
                    $cleanupFailures.Add("Could not remove temporary portable-backup source $copiedFile: $($_.Exception.Message)")
                }
            }
        }
    }
    finally {
        if ($patchApplied) {
            & git -C $sourceRoot apply --reverse --check --ignore-space-change $patch 2>$null
            if ($LASTEXITCODE -eq 0) {
                & git -C $sourceRoot apply --reverse --ignore-space-change $patch
                if ($LASTEXITCODE -ne 0) {
                    $cleanupFailures.Add("Could not remove the reviewed Xanh WebKit patch.")
                }
            }
            else {
                $cleanupFailures.Add("The reviewed Xanh WebKit patch could not be removed cleanly.")
            }
        }
        try {
            Copy-Item $mainIconBackup $mainIcon -Force
            Copy-Item $smallIconBackup $smallIcon -Force
            Remove-Item $mainIconBackup, $smallIconBackup -Force
        }
        catch {
            $cleanupFailures.Add("Could not restore the upstream icons or remove their temporary copies: $($_.Exception.Message)")
        }

        & git -C $sourceRoot diff --quiet
        if ($LASTEXITCODE -ne 0) {
            $cleanupFailures.Add("The WebKit checkout has tracked changes after cleanup.")
        }
        & git -C $sourceRoot diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            $cleanupFailures.Add("The WebKit checkout has staged changes after cleanup.")
        }
        $remainingUntracked = @(& git -C $sourceRoot ls-files --others --exclude-standard)
        $remainingUntrackedExitCode = $LASTEXITCODE
        if ($remainingUntrackedExitCode -ne 0 -or $remainingUntracked.Count -ne 0) {
            $cleanupFailures.Add("The WebKit checkout has untracked non-ignored files after cleanup.")
        }
    }
}

if ($buildFailure -or $cleanupFailures.Count) {
    if ($outputCreatedByThisRun -and $output -and (Test-Path $output)) {
        try {
            Remove-Item $output -Recurse -Force
        }
        catch {
            $cleanupFailures.Add("Could not remove the invalid output directory $output: $($_.Exception.Message)")
        }
    }
    if ($buildFailure -and $cleanupFailures.Count) {
        throw "$($buildFailure.Exception.Message) Cleanup also failed: $($cleanupFailures -join '; ')"
    }
    if ($buildFailure) {
        throw $buildFailure
    }
    throw "WebKit build cleanup failed: $($cleanupFailures -join '; ')"
}
