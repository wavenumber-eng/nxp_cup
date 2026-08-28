[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")]
    [string]$Version,

    [string]$Repository = "wavenumber-eng/nxp_cup",

    [switch]$Publish,

    [switch]$AllowDirty,

    [switch]$Offline,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "../..")).Path
$releaseTag = "android-bridge-v$Version"
$assetName = "nxp-cup-bridge-android-$Version.apk"
$releaseRoot = Join-Path $repoRoot "out/artifacts/android/releases"
$releaseApk = Join-Path $releaseRoot $assetName
$checksumPath = "$releaseApk.sha256"
$manifestPath = Join-Path $releaseRoot "nxp-cup-bridge-android-$Version.manifest.json"
$buildFile = Join-Path $scriptDir "nxp_cup_bridge/app/build.gradle"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage (exit code $LASTEXITCODE)"
    }
}

function Get-ApkIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApkPath,

        [Parameter(Mandatory = $true)]
        [string]$Aapt2Path,

        [Parameter(Mandatory = $true)]
        [string]$ApkSignerPath
    )

    $badging = (& $Aapt2Path dump badging $ApkPath 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "aapt2 could not inspect $ApkPath"
    }
    $packageMatch = [regex]::Match(
        $badging,
        "package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'"
    )
    if (-not $packageMatch.Success) {
        throw "APK package metadata is missing or malformed: $ApkPath"
    }

    $signing = (& $ApkSignerPath verify --verbose --print-certs $ApkPath 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "APK signature verification failed: $ApkPath"
    }
    $certificateMatch = [regex]::Match(
        $signing,
        "Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]{64})"
    )
    if (-not $certificateMatch.Success) {
        throw "APK signer certificate digest is missing: $ApkPath"
    }
    if ($signing -notmatch "Number of signers:\s*1") {
        throw "APK must contain exactly one signer: $ApkPath"
    }

    [pscustomobject]@{
        PackageName = $packageMatch.Groups[1].Value
        VersionCode = $packageMatch.Groups[2].Value
        VersionName = $packageMatch.Groups[3].Value
        CertificateSha256 = $certificateMatch.Groups[1].Value.ToLowerInvariant()
        DebugSigned = $signing -match "Signer #1 certificate DN:.*CN=Android Debug"
    }
}

if ($Publish -and $AllowDirty) {
    throw "-AllowDirty is available only for local dry runs; publishing requires a clean source tree."
}
foreach ($command in @("git", "npm")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required release command was not found: $command"
    }
}

$sourceCommit = (& git -C $repoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
if (($LASTEXITCODE -ne 0) -or ($sourceCommit -notmatch "^[0-9a-f]{40}$")) {
    throw "Could not resolve the source commit: $sourceCommit"
}
$sourceStatus = (& git -C $repoRoot status --porcelain=v1 --untracked-files=all | Out-String).Trim()
if ((-not [string]::IsNullOrWhiteSpace($sourceStatus)) -and (-not $AllowDirty)) {
    throw "The release source tree is not clean. Commit or remove local changes before releasing."
}
if (-not [string]::IsNullOrWhiteSpace($sourceStatus)) {
    Write-Warning "Local dry run is using a dirty source tree because -AllowDirty was explicit."
}

$buildText = Get-Content -LiteralPath $buildFile -Raw
$configuredVersion = [regex]::Match($buildText, 'versionName\s+"([^"]+)"').Groups[1].Value
$configuredVersionCode = [regex]::Match($buildText, 'versionCode\s+(\d+)').Groups[1].Value
if ([string]::IsNullOrWhiteSpace($configuredVersion) -or [string]::IsNullOrWhiteSpace($configuredVersionCode)) {
    throw "Could not read Android versionName/versionCode from $buildFile"
}
if ($configuredVersion -ne $Version) {
    throw "Requested release $Version does not match Android versionName $configuredVersion"
}

Write-Host "Checking generated dashboard pages..." -ForegroundColor Cyan
& (Join-Path $repoRoot "src/web/build.ps1") -Check
if ($LASTEXITCODE -ne 0) {
    throw "Shared dashboard generated-page check failed with exit code $LASTEXITCODE"
}
Invoke-NativeChecked -Command "npm" -Arguments @("test", "--prefix", (Join-Path $repoRoot "src/host")) `
    -FailureMessage "Dashboard browser tests failed"

Write-Host "Building and testing Android bridge from $sourceCommit..." -ForegroundColor Cyan
& (Join-Path $scriptDir "build.ps1") -Clean -Offline:$Offline
if ($LASTEXITCODE -ne 0) {
    throw "Android build failed with exit code $LASTEXITCODE"
}

. (Join-Path $scriptDir "tools/android_env.ps1")
$buildTools = $script:NxpCupAndroidVersions.AndroidBuildTools
$aapt2 = Join-Path $env:ANDROID_HOME "build-tools/$buildTools/aapt2.exe"
$apkSigner = Join-Path $env:ANDROID_HOME "build-tools/$buildTools/apksigner.bat"
foreach ($path in @($aapt2, $apkSigner)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Android release verifier is missing: $path"
    }
}

$builtApk = Join-Path $repoRoot "out/artifacts/android/nxp_cup_bridge.apk"
if (-not (Test-Path -LiteralPath $builtApk -PathType Leaf)) {
    throw "Android build did not publish the expected APK: $builtApk"
}
$builtIdentity = Get-ApkIdentity -ApkPath $builtApk -Aapt2Path $aapt2 -ApkSignerPath $apkSigner
if (($builtIdentity.PackageName -ne "com.wavenumber.nxpc.bridge") -or
    ($builtIdentity.VersionName -ne $Version) -or
    ($builtIdentity.VersionCode -ne $configuredVersionCode)) {
    throw "Built APK identity does not match the release contract."
}
if (-not $builtIdentity.DebugSigned) {
    throw "Version $Version is documented as a debug-signed maintainer build, but the APK signer changed."
}

New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
foreach ($path in @($releaseApk, $checksumPath, $manifestPath)) {
    if (Test-Path -LiteralPath $path) {
        if (-not $Force) {
            throw "Release output already exists: $path. Pass -Force to replace this exact version."
        }
        Remove-Item -LiteralPath $path -Force
    }
}
Copy-Item -LiteralPath $builtApk -Destination $releaseApk
$apkFile = Get-Item -LiteralPath $releaseApk
$apkHash = (Get-FileHash -LiteralPath $releaseApk -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText($checksumPath, "$apkHash  $assetName`n", $utf8NoBom)

$manifest = [ordered]@{
    schemaVersion = 1
    releaseVersion = $Version
    versionCode = [int]$configuredVersionCode
    sourceCommit = $sourceCommit
    sourceDirty = -not [string]::IsNullOrWhiteSpace($sourceStatus)
    applicationId = $builtIdentity.PackageName
    buildVariant = "debug"
    signing = [ordered]@{
        kind = "android-debug"
        certificateSha256 = $builtIdentity.CertificateSha256
    }
    apk = [ordered]@{
        name = $assetName
        size = $apkFile.Length
        sha256 = $apkHash
    }
}
[System.IO.File]::WriteAllText(
    $manifestPath,
    (($manifest | ConvertTo-Json -Depth 6) + "`n"),
    $utf8NoBom
)

$copiedIdentity = Get-ApkIdentity -ApkPath $releaseApk -Aapt2Path $aapt2 -ApkSignerPath $apkSigner
if (($copiedIdentity.PackageName -ne $builtIdentity.PackageName) -or
    ($copiedIdentity.VersionName -ne $builtIdentity.VersionName) -or
    ($copiedIdentity.CertificateSha256 -ne $builtIdentity.CertificateSha256)) {
    throw "Versioned APK identity changed while packaging."
}

if ($Publish) {
    $postBuildStatus = (& git -C $repoRoot status --porcelain=v1 --untracked-files=all | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($postBuildStatus)) {
        throw "Build or test execution left the source tree dirty; refusing to publish."
    }
}

if (-not $Publish) {
    Write-Host ""
    Write-Host "Dry run complete; nothing was uploaded." -ForegroundColor Green
    Write-Host "Release tag: $releaseTag"
    Write-Host "APK:         $releaseApk"
    Write-Host "SHA-256:     $apkHash"
    Write-Host "Signer:      $($builtIdentity.CertificateSha256) (Android debug)"
    Write-Host "Run again from a clean GitHub-present commit with -Publish to create the release."
    exit 0
}

if (-not (Get-Command "gh" -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required only when -Publish is used."
}
Invoke-NativeChecked -Command "gh" -Arguments @("auth", "status") `
    -FailureMessage "GitHub CLI authentication is not ready"

$repoJson = (& gh repo view $Repository --json visibility,defaultBranchRef,viewerPermission 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect GitHub repository $Repository`: $repoJson"
}
$repo = $repoJson | ConvertFrom-Json
if ($repo.visibility -ne "PUBLIC") {
    throw "Release repository must be public so the APK is anonymously downloadable."
}
if (($null -eq $repo.defaultBranchRef) -or [string]::IsNullOrWhiteSpace($repo.defaultBranchRef.name)) {
    throw "GitHub repository $Repository has no default branch."
}

$immutabilityJson = (& gh api "repos/$Repository/immutable-releases" 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect immutable-release settings for $Repository`: $immutabilityJson"
}
$immutability = $immutabilityJson | ConvertFrom-Json
if (-not $immutability.enabled) {
    throw "GitHub immutable releases are disabled for $Repository."
}
& gh api "repos/$Repository/git/commits/$sourceCommit" --silent 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Source commit $sourceCommit is not present on GitHub. Push the merged commit before publishing."
}

$savedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    & gh release view $releaseTag --repo $Repository *> $null
    $releaseExists = ($LASTEXITCODE -eq 0)
} finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
if ($releaseExists) {
    throw "GitHub release $releaseTag already exists; release versions are immutable."
}
$matchingTagsJson = (& gh api "repos/$Repository/git/matching-refs/tags/$releaseTag" 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect existing GitHub tags: $matchingTagsJson"
}
$matchingTags = @($matchingTagsJson | ConvertFrom-Json)
if (@($matchingTags | Where-Object { $_.ref -eq "refs/tags/$releaseTag" }).Count -gt 0) {
    throw "GitHub tag $releaseTag already exists without a release."
}

$releaseNotes = @"
Maintainer Android USB-host and Wi-Fi telemetry relay for the NXP Cup platform.

This `$Version` APK is the proven Moto G Power 5G (2023) development build. It is
debug-signed, distributed outside an app store, and is not required for the student
firmware workflow. Install with `adb install -r $assetName` when updating an app signed
with the same certificate; otherwise uninstalling first also clears app data and USB
association.
"@
Invoke-NativeChecked -Command "gh" -Arguments @(
    "release", "create", $releaseTag,
    $releaseApk, $checksumPath, $manifestPath,
    "--repo", $Repository,
    "--target", $sourceCommit,
    "--title", "NXP Cup Android bridge $Version",
    "--notes", $releaseNotes,
    "--draft"
) -FailureMessage "Could not create the draft GitHub release"

$downloadRoot = Join-Path $repoRoot "out/validation/android-release/$releaseTag"
if (Test-Path -LiteralPath $downloadRoot) {
    Remove-Item -LiteralPath $downloadRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
Invoke-NativeChecked -Command "gh" -Arguments @(
    "release", "download", $releaseTag,
    "--repo", $Repository,
    "--pattern", $assetName,
    "--dir", $downloadRoot
) -FailureMessage "Could not download the draft APK for verification"
$downloadedApk = Join-Path $downloadRoot $assetName
$downloadHash = (Get-FileHash -LiteralPath $downloadedApk -Algorithm SHA256).Hash.ToLowerInvariant()
if ($downloadHash -ne $apkHash) {
    throw "Downloaded GitHub APK hash does not match; the draft was not published."
}
$downloadedIdentity = Get-ApkIdentity -ApkPath $downloadedApk -Aapt2Path $aapt2 -ApkSignerPath $apkSigner
if (($downloadedIdentity.VersionName -ne $Version) -or
    ($downloadedIdentity.CertificateSha256 -ne $builtIdentity.CertificateSha256)) {
    throw "Downloaded GitHub APK identity does not match; the draft was not published."
}

Invoke-NativeChecked -Command "gh" -Arguments @(
    "release", "edit", $releaseTag,
    "--repo", $Repository,
    "--draft=false"
) -FailureMessage "The verified draft could not be published"

$publicUrl = "https://github.com/$Repository/releases/download/$releaseTag/$assetName"
$publicDownload = Join-Path $downloadRoot "public-$assetName"
$publicVerified = $false
$lastPublicError = ""
for ($attempt = 1; $attempt -le 6; $attempt++) {
    try {
        if (Test-Path -LiteralPath $publicDownload) {
            Remove-Item -LiteralPath $publicDownload -Force
        }
        Invoke-WebRequest -UseBasicParsing -Uri $publicUrl -OutFile $publicDownload
        $publicHash = (Get-FileHash -LiteralPath $publicDownload -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($publicHash -eq $apkHash) {
            $publicVerified = $true
            break
        }
        $lastPublicError = "downloaded SHA-256 was $publicHash"
    } catch {
        $lastPublicError = $_.Exception.Message
    }
    if ($attempt -lt 6) {
        Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 10))
    }
}
if (-not $publicVerified) {
    throw "Release $releaseTag was published, but anonymous verification failed: $lastPublicError"
}
Write-Host "Published and verified: $publicUrl" -ForegroundColor Green
