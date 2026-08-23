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
$credentialBridgePatch = (Resolve-Path (Join-Path $PSScriptRoot "../patches/xanh-credential-bridge.patch")).Path
$icon = (Resolve-Path (Join-Path $repositoryRoot "platform/windows/src/XanhBrowser.Windows/Assets/XanhBrowser.ico")).Path
$portableBackupHeader = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhPortableBackup.h")).Path
$portableBackupImplementation = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhPortableBackup.cpp")).Path
$credentialBridgePolicy = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhCredentialBridgePolicy.h")).Path
$credentialPickerTypes = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhCredentialPickerTypes.h")).Path
$credentialBridgeHeader = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhCredentialBridge.h")).Path
$credentialBridgeImplementation = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhCredentialBridge.cpp")).Path
$credentialRecordsHeader = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhCredentialRecords.h")).Path
$credentialRecordsImplementation = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhCredentialRecords.cpp")).Path
$dpapiSecretStoreHeader = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhDpapiSecretStore.h")).Path
$dpapiSecretStoreImplementation = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhDpapiSecretStore.cpp")).Path
$syncCoreABIHeader = (Resolve-Path (Join-Path $repositoryRoot "xanh-sync-core/include/xanh_sync.h")).Path
$nativeSyncLibraryHeader = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhNativeSyncLibrary.h")).Path
$nativeSyncLibraryImplementation = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhNativeSyncLibrary.cpp")).Path
$nativeSyncRuntimeHeader = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhNativeSyncRuntime.h")).Path
$nativeSyncRuntimeImplementation = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhNativeSyncRuntime.cpp")).Path
$nativeCredentialPickerHeader = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhNativeCredentialPicker.h")).Path
$nativeCredentialPickerImplementation = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhNativeCredentialPicker.cpp")).Path
$windowsHelloHeader = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhWindowsHello.h")).Path
$windowsHelloImplementation = (Resolve-Path (Join-Path $PSScriptRoot "../src/XanhWindowsHello.cpp")).Path
$mainIcon = Join-Path $sourceRoot "Tools/MiniBrowser/win/MiniBrowser.ico"
$smallIcon = Join-Path $sourceRoot "Tools/MiniBrowser/win/small.ico"
$portableBackupHeaderDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhPortableBackup.h"
$portableBackupImplementationDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhPortableBackup.cpp"
$credentialBridgePolicyDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhCredentialBridgePolicy.h"
$credentialPickerTypesDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhCredentialPickerTypes.h"
$credentialBridgeHeaderDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhCredentialBridge.h"
$credentialBridgeImplementationDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhCredentialBridge.cpp"
$credentialRecordsHeaderDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhCredentialRecords.h"
$credentialRecordsImplementationDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhCredentialRecords.cpp"
$dpapiSecretStoreHeaderDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhDpapiSecretStore.h"
$dpapiSecretStoreImplementationDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhDpapiSecretStore.cpp"
$syncCoreABIHeaderDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/xanh_sync.h"
$nativeSyncLibraryHeaderDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhNativeSyncLibrary.h"
$nativeSyncLibraryImplementationDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhNativeSyncLibrary.cpp"
$nativeSyncRuntimeHeaderDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhNativeSyncRuntime.h"
$nativeSyncRuntimeImplementationDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhNativeSyncRuntime.cpp"
$nativeCredentialPickerHeaderDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhNativeCredentialPicker.h"
$nativeCredentialPickerImplementationDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhNativeCredentialPicker.cpp"
$windowsHelloHeaderDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhWindowsHello.h"
$windowsHelloImplementationDestination = Join-Path $sourceRoot "Tools/MiniBrowser/win/XanhWindowsHello.cpp"

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
if ((Test-Path $portableBackupHeaderDestination) -or (Test-Path $portableBackupImplementationDestination)
    -or (Test-Path $credentialBridgePolicyDestination) -or (Test-Path $credentialPickerTypesDestination)
    -or (Test-Path $credentialBridgeHeaderDestination)
    -or (Test-Path $credentialBridgeImplementationDestination) -or (Test-Path $dpapiSecretStoreHeaderDestination)
    -or (Test-Path $credentialRecordsHeaderDestination) -or (Test-Path $credentialRecordsImplementationDestination)
    -or (Test-Path $dpapiSecretStoreImplementationDestination) -or (Test-Path $syncCoreABIHeaderDestination)
    -or (Test-Path $nativeSyncLibraryHeaderDestination) -or (Test-Path $nativeSyncLibraryImplementationDestination)
    -or (Test-Path $nativeSyncRuntimeHeaderDestination) -or (Test-Path $nativeSyncRuntimeImplementationDestination)
    -or (Test-Path $nativeCredentialPickerHeaderDestination) -or (Test-Path $nativeCredentialPickerImplementationDestination)
    -or (Test-Path $windowsHelloHeaderDestination)
    -or (Test-Path $windowsHelloImplementationDestination)) {
    throw "The pinned WebKit source unexpectedly contains Xanh host sources. Use a clean exact checkout."
}

$mainIconBackup = [IO.Path]::GetTempFileName()
$smallIconBackup = [IO.Path]::GetTempFileName()
Copy-Item $mainIcon $mainIconBackup -Force
Copy-Item $smallIcon $smallIconBackup -Force
$copiedSourceFiles = @()
$buildFailure = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$output = $null
$outputCreatedByThisRun = $false
$patchApplied = $false
$credentialBridgePatchApplied = $false
$portableBackupHeaderHash = $null
$portableBackupImplementationHash = $null
$credentialBridgePolicyHash = $null
$credentialPickerTypesHash = $null
$credentialBridgeHeaderHash = $null
$credentialBridgeImplementationHash = $null
$credentialRecordsHeaderHash = $null
$credentialRecordsImplementationHash = $null
$dpapiSecretStoreHeaderHash = $null
$dpapiSecretStoreImplementationHash = $null
$syncCoreABIHeaderHash = $null
$nativeSyncLibraryHeaderHash = $null
$nativeSyncLibraryImplementationHash = $null
$nativeSyncRuntimeHeaderHash = $null
$nativeSyncRuntimeImplementationHash = $null
$nativeCredentialPickerHeaderHash = $null
$nativeCredentialPickerImplementationHash = $null
$windowsHelloHeaderHash = $null
$windowsHelloImplementationHash = $null

try {
    & git -C $sourceRoot apply --ignore-space-change $patch
    if ($LASTEXITCODE -ne 0) {
        throw "Could not apply the Xanh Browser WebKit patch."
    }
    $patchApplied = $true
    & git -C $sourceRoot apply --check --ignore-space-change $credentialBridgePatch
    if ($LASTEXITCODE -ne 0) {
        throw "The Xanh credential bridge patch does not apply after the reviewed WebKit patch."
    }
    & git -C $sourceRoot apply --ignore-space-change $credentialBridgePatch
    if ($LASTEXITCODE -ne 0) {
        throw "Could not apply the Xanh credential bridge patch."
    }
    $credentialBridgePatchApplied = $true
    $copiedSourceFiles += $portableBackupHeaderDestination
    Copy-Item $portableBackupHeader $portableBackupHeaderDestination
    $copiedSourceFiles += $portableBackupImplementationDestination
    Copy-Item $portableBackupImplementation $portableBackupImplementationDestination
    $copiedSourceFiles += $credentialBridgePolicyDestination
    Copy-Item $credentialBridgePolicy $credentialBridgePolicyDestination
    $copiedSourceFiles += $credentialPickerTypesDestination
    Copy-Item $credentialPickerTypes $credentialPickerTypesDestination
    $copiedSourceFiles += $credentialBridgeHeaderDestination
    Copy-Item $credentialBridgeHeader $credentialBridgeHeaderDestination
    $copiedSourceFiles += $credentialBridgeImplementationDestination
    Copy-Item $credentialBridgeImplementation $credentialBridgeImplementationDestination
    $copiedSourceFiles += $credentialRecordsHeaderDestination
    Copy-Item $credentialRecordsHeader $credentialRecordsHeaderDestination
    $copiedSourceFiles += $credentialRecordsImplementationDestination
    Copy-Item $credentialRecordsImplementation $credentialRecordsImplementationDestination
    $copiedSourceFiles += $dpapiSecretStoreHeaderDestination
    Copy-Item $dpapiSecretStoreHeader $dpapiSecretStoreHeaderDestination
    $copiedSourceFiles += $dpapiSecretStoreImplementationDestination
    Copy-Item $dpapiSecretStoreImplementation $dpapiSecretStoreImplementationDestination
    $copiedSourceFiles += $syncCoreABIHeaderDestination
    Copy-Item $syncCoreABIHeader $syncCoreABIHeaderDestination
    $copiedSourceFiles += $nativeSyncLibraryHeaderDestination
    Copy-Item $nativeSyncLibraryHeader $nativeSyncLibraryHeaderDestination
    $copiedSourceFiles += $nativeSyncLibraryImplementationDestination
    Copy-Item $nativeSyncLibraryImplementation $nativeSyncLibraryImplementationDestination
    $copiedSourceFiles += $nativeSyncRuntimeHeaderDestination
    Copy-Item $nativeSyncRuntimeHeader $nativeSyncRuntimeHeaderDestination
    $copiedSourceFiles += $nativeSyncRuntimeImplementationDestination
    Copy-Item $nativeSyncRuntimeImplementation $nativeSyncRuntimeImplementationDestination
    $copiedSourceFiles += $nativeCredentialPickerHeaderDestination
    Copy-Item $nativeCredentialPickerHeader $nativeCredentialPickerHeaderDestination
    $copiedSourceFiles += $nativeCredentialPickerImplementationDestination
    Copy-Item $nativeCredentialPickerImplementation $nativeCredentialPickerImplementationDestination
    $copiedSourceFiles += $windowsHelloHeaderDestination
    Copy-Item $windowsHelloHeader $windowsHelloHeaderDestination
    $copiedSourceFiles += $windowsHelloImplementationDestination
    Copy-Item $windowsHelloImplementation $windowsHelloImplementationDestination
    $portableBackupHeaderHash = (Get-FileHash $portableBackupHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $portableBackupImplementationHash = (Get-FileHash $portableBackupImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $credentialBridgePolicyHash = (Get-FileHash $credentialBridgePolicyDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $credentialPickerTypesHash = (Get-FileHash $credentialPickerTypesDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $credentialBridgeHeaderHash = (Get-FileHash $credentialBridgeHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $credentialBridgeImplementationHash = (Get-FileHash $credentialBridgeImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $credentialRecordsHeaderHash = (Get-FileHash $credentialRecordsHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $credentialRecordsImplementationHash = (Get-FileHash $credentialRecordsImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $dpapiSecretStoreHeaderHash = (Get-FileHash $dpapiSecretStoreHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $dpapiSecretStoreImplementationHash = (Get-FileHash $dpapiSecretStoreImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $syncCoreABIHeaderHash = (Get-FileHash $syncCoreABIHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $nativeSyncLibraryHeaderHash = (Get-FileHash $nativeSyncLibraryHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $nativeSyncLibraryImplementationHash = (Get-FileHash $nativeSyncLibraryImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $nativeSyncRuntimeHeaderHash = (Get-FileHash $nativeSyncRuntimeHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $nativeSyncRuntimeImplementationHash = (Get-FileHash $nativeSyncRuntimeImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $nativeCredentialPickerHeaderHash = (Get-FileHash $nativeCredentialPickerHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $nativeCredentialPickerImplementationHash = (Get-FileHash $nativeCredentialPickerImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $windowsHelloHeaderHash = (Get-FileHash $windowsHelloHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $windowsHelloImplementationHash = (Get-FileHash $windowsHelloImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant()
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
        -or (Get-FileHash $portableBackupImplementation -Algorithm SHA256).Hash.ToLowerInvariant() -ne $portableBackupImplementationHash
        -or (Get-FileHash $credentialBridgePolicyDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialBridgePolicyHash
        -or (Get-FileHash $credentialPickerTypesDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialPickerTypesHash
        -or (Get-FileHash $credentialBridgeHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialBridgeHeaderHash
        -or (Get-FileHash $credentialBridgeImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialBridgeImplementationHash
        -or (Get-FileHash $credentialBridgePolicy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialBridgePolicyHash
        -or (Get-FileHash $credentialPickerTypes -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialPickerTypesHash
        -or (Get-FileHash $credentialBridgeHeader -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialBridgeHeaderHash
        -or (Get-FileHash $credentialBridgeImplementation -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialBridgeImplementationHash
        -or (Get-FileHash $credentialRecordsHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialRecordsHeaderHash
        -or (Get-FileHash $credentialRecordsImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialRecordsImplementationHash
        -or (Get-FileHash $credentialRecordsHeader -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialRecordsHeaderHash
        -or (Get-FileHash $credentialRecordsImplementation -Algorithm SHA256).Hash.ToLowerInvariant() -ne $credentialRecordsImplementationHash
        -or (Get-FileHash $dpapiSecretStoreHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dpapiSecretStoreHeaderHash
        -or (Get-FileHash $dpapiSecretStoreImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dpapiSecretStoreImplementationHash
        -or (Get-FileHash $dpapiSecretStoreHeader -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dpapiSecretStoreHeaderHash
        -or (Get-FileHash $dpapiSecretStoreImplementation -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dpapiSecretStoreImplementationHash
        -or (Get-FileHash $syncCoreABIHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $syncCoreABIHeaderHash
        -or (Get-FileHash $syncCoreABIHeader -Algorithm SHA256).Hash.ToLowerInvariant() -ne $syncCoreABIHeaderHash
        -or (Get-FileHash $nativeSyncLibraryHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeSyncLibraryHeaderHash
        -or (Get-FileHash $nativeSyncLibraryImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeSyncLibraryImplementationHash
        -or (Get-FileHash $nativeSyncLibraryHeader -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeSyncLibraryHeaderHash
        -or (Get-FileHash $nativeSyncLibraryImplementation -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeSyncLibraryImplementationHash
        -or (Get-FileHash $nativeSyncRuntimeHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeSyncRuntimeHeaderHash
        -or (Get-FileHash $nativeSyncRuntimeImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeSyncRuntimeImplementationHash
        -or (Get-FileHash $nativeSyncRuntimeHeader -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeSyncRuntimeHeaderHash
        -or (Get-FileHash $nativeSyncRuntimeImplementation -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeSyncRuntimeImplementationHash
        -or (Get-FileHash $nativeCredentialPickerHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeCredentialPickerHeaderHash
        -or (Get-FileHash $nativeCredentialPickerImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeCredentialPickerImplementationHash
        -or (Get-FileHash $nativeCredentialPickerHeader -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeCredentialPickerHeaderHash
        -or (Get-FileHash $nativeCredentialPickerImplementation -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeCredentialPickerImplementationHash
        -or (Get-FileHash $windowsHelloHeaderDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $windowsHelloHeaderHash
        -or (Get-FileHash $windowsHelloImplementationDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $windowsHelloImplementationHash
        -or (Get-FileHash $windowsHelloHeader -Algorithm SHA256).Hash.ToLowerInvariant() -ne $windowsHelloHeaderHash
        -or (Get-FileHash $windowsHelloImplementation -Algorithm SHA256).Hash.ToLowerInvariant() -ne $windowsHelloImplementationHash) {
        throw "Xanh host sources changed during the WebKit build. Discard this build and retry from a stable checkout."
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
        "Credential bridge policy SHA-256: $credentialBridgePolicyHash"
        "Credential picker types SHA-256: $credentialPickerTypesHash"
        "Credential bridge header SHA-256: $credentialBridgeHeaderHash"
        "Credential bridge implementation SHA-256: $credentialBridgeImplementationHash"
        "Credential records header SHA-256: $credentialRecordsHeaderHash"
        "Credential records implementation SHA-256: $credentialRecordsImplementationHash"
        "DPAPI secret-store header SHA-256: $dpapiSecretStoreHeaderHash"
        "DPAPI secret-store implementation SHA-256: $dpapiSecretStoreImplementationHash"
        "Native Sync C ABI header SHA-256: $syncCoreABIHeaderHash"
        "Native Sync loader header SHA-256: $nativeSyncLibraryHeaderHash"
        "Native Sync loader implementation SHA-256: $nativeSyncLibraryImplementationHash"
        "Native Sync runtime header SHA-256: $nativeSyncRuntimeHeaderHash"
        "Native Sync runtime implementation SHA-256: $nativeSyncRuntimeImplementationHash"
        "Native credential picker header SHA-256: $nativeCredentialPickerHeaderHash"
        "Native credential picker implementation SHA-256: $nativeCredentialPickerImplementationHash"
        "Windows Hello header SHA-256: $windowsHelloHeaderHash"
        "Windows Hello implementation SHA-256: $windowsHelloImplementationHash"
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
        foreach ($copiedFile in $copiedSourceFiles) {
            if (Test-Path $copiedFile) {
                try {
                    Remove-Item $copiedFile -Force
                }
                catch {
                    $cleanupFailures.Add("Could not remove temporary Xanh host source $copiedFile: $($_.Exception.Message)")
                }
            }
        }
    }
    finally {
        if ($credentialBridgePatchApplied) {
            & git -C $sourceRoot apply --reverse --check --ignore-space-change $credentialBridgePatch 2>$null
            if ($LASTEXITCODE -eq 0) {
                & git -C $sourceRoot apply --reverse --ignore-space-change $credentialBridgePatch
                if ($LASTEXITCODE -ne 0) {
                    $cleanupFailures.Add("Could not remove the reviewed Xanh credential bridge patch.")
                }
            }
            else {
                $cleanupFailures.Add("The reviewed Xanh credential bridge patch could not be removed cleanly.")
            }
        }
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
