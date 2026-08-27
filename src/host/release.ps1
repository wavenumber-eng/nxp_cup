param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")]
    [string]$Version,

    [string]$Repository = "wavenumber-eng/nxp_cup",

    [ValidateSet("Auto", "Windows", "MacOS")]
    [string]$Platform = "Auto",

    [switch]$Publish,

    [string]$SigningIdentity = "-",

    [string]$NotaryProfile,

    [switch]$AllowDirty,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "../..")).Path
$packageScript = Join-Path $scriptDir "package.ps1"
$runningOnMac = ($PSVersionTable.PSEdition -eq "Core") -and $IsMacOS
$runningOnWindows = -not $runningOnMac -and ($env:OS -eq "Windows_NT")
$targetPlatform = if ($Platform -eq "Auto") {
    if ($runningOnMac) { "MacOS" } elseif ($runningOnWindows) { "Windows" } else { "Unsupported" }
} else {
    $Platform
}
$isMacRelease = $targetPlatform -eq "MacOS"
if (($isMacRelease -and (-not $runningOnMac)) -or
        (($targetPlatform -eq "Windows") -and (-not $runningOnWindows))) {
    throw "$targetPlatform core tools must be built and validated on that operating system."
}
if ($targetPlatform -eq "Unsupported") {
    throw "Core-tools releases are supported only on Windows x64 and macOS arm64."
}
$releaseTag = if ($isMacRelease) { "core-tools-macos-v$Version" } else { "core-tools-v$Version" }
$packageName = if ($isMacRelease) {
    "nxp-cup-core-tools-macos-arm64-$Version"
} else {
    "nxp-cup-core-tools-win-x64-$Version"
}

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

function Get-NormalizedRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $basePrefix = [System.IO.Path]::GetFullPath($BaseDirectory).TrimEnd($separator) + $separator
    $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
    $comparison = if ($runningOnMac) {
        [System.StringComparison]::Ordinal
    } else {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    if (-not $fullPath.StartsWith($basePrefix, $comparison)) {
        throw "Path is outside the validation root: $fullPath"
    }
    return $fullPath.Substring($basePrefix.Length).Replace($separator, '/')
}

function Test-CoreToolsArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Windows", "MacOS")]
        [string]$ExpectedPlatform,

        [switch]$RequirePublishReady,

        [Parameter(Mandatory = $true)]
        [string]$ValidationRoot
    )

    $extractPath = Join-Path $ValidationRoot "archive"
    if (Test-Path -LiteralPath $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
    if ($ExpectedPlatform -eq "MacOS") {
        Invoke-NativeChecked -Command "ditto" -Arguments @("-x", "-k", $ZipPath, $extractPath) `
            -FailureMessage "Could not extract the macOS package"
    } else {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractPath
    }

    $manifestPath = Join-Path $extractPath "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Package validation failed: manifest.json is missing"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.releaseVersion -ne $ExpectedVersion) {
        throw "Package validation failed: expected version $ExpectedVersion, found $($manifest.releaseVersion)"
    }
    $expectedPlatformName = if ($ExpectedPlatform -eq "MacOS") { "macos" } else { "windows" }
    $expectedArchitecture = if ($ExpectedPlatform -eq "MacOS") { "arm64" } else { "x64" }
    if (($manifest.platform -ne $expectedPlatformName) -or
            ($manifest.architecture -ne $expectedArchitecture)) {
        throw "Package validation failed: expected $expectedPlatformName $expectedArchitecture metadata"
    }

    $expectedNames = if ($ExpectedPlatform -eq "MacOS") {
        @(
            "Dear-ImGui-LICENSE.txt",
            "HOST-README.md",
            "NXP Cup Viewer.app/Contents/_CodeSignature/CodeResources",
            "NXP Cup Viewer.app/Contents/Info.plist",
            "NXP Cup Viewer.app/Contents/MacOS/NXP Cup Viewer",
            "NXP Cup Viewer.app/Contents/Resources/bin/rblhost",
            "NXP Cup Viewer.app/Contents/Resources/licenses/rblhost-LICENSE.txt",
            "nxpc_tool",
            "rblhost",
            "rblhost-LICENSE.txt",
            "SDL2-LICENSE.txt"
        )
    } else {
        @(
            "Dear-ImGui-LICENSE.txt",
            "nxpc_tool.exe",
            "nxpc_viewer.exe",
            "rblhost.exe",
            "rblhost-LICENSE.txt",
            "HOST-README.md",
            "SDL2.dll",
            "SDL2-LICENSE.txt"
        )
    }
    $manifestNames = @($manifest.files | ForEach-Object { $_.name } | Sort-Object)
    if (($manifestNames -join "`n") -ne (($expectedNames | Sort-Object) -join "`n")) {
        throw "Package validation failed: manifest payload does not match the release contract"
    }

    foreach ($entry in $manifest.files) {
        $payloadPath = Join-Path $extractPath $entry.name
        if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
            throw "Package validation failed: $($entry.name) is missing"
        }
        $file = Get-Item -LiteralPath $payloadPath
        $hash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (($file.Length -ne $entry.size) -or ($hash -ne $entry.sha256)) {
            throw "Package validation failed: $($entry.name) does not match manifest.json"
        }
    }

    $actualNames = @(
        Get-ChildItem -LiteralPath $extractPath -File -Recurse |
            Where-Object { $_.FullName -ne $manifestPath } |
            ForEach-Object {
                Get-NormalizedRelativePath -BaseDirectory $extractPath `
                    -LiteralPath $_.FullName
            } |
            Sort-Object
    )
    if (($actualNames -join "`n") -ne (($expectedNames | Sort-Object) -join "`n")) {
        throw "Package validation failed: archive payload does not match the release contract"
    }

    $toolName = if ($ExpectedPlatform -eq "MacOS") { "nxpc_tool" } else { "nxpc_tool.exe" }
    $tool = Join-Path $extractPath $toolName
    Invoke-NativeChecked -Command $tool -Arguments @("selftest") `
        -FailureMessage "Packaged nxpc_tool self-test failed"

    if ($ExpectedPlatform -eq "MacOS") {
        if (($manifest.schemaVersion -ne 2) -or ($manifest.minimumOsVersion -ne "13.0") -or
                ($manifest.bundleIdentifier -ne "com.wavenumber.nxpc.viewer")) {
            throw "Package validation failed: macOS schema, minimum OS, or bundle identifier is invalid"
        }
        if ($RequirePublishReady) {
            if (($manifest.signing.state -ne "developer-id") -or
                    (-not $manifest.signing.hardenedRuntime) -or
                    (-not $manifest.signing.notarized) -or
                    [string]::IsNullOrWhiteSpace($manifest.signing.notarySubmissionId)) {
                throw "Package validation failed: macOS publication requires Developer ID signing and accepted notarization"
            }
        } elseif ($manifest.signing.notarized) {
            throw "Package validation failed: a local dry run must not claim Apple notarization"
        }

        $app = Join-Path $extractPath "NXP Cup Viewer.app"
        $appExecutable = Join-Path $app "Contents/MacOS/NXP Cup Viewer"
        $appProgrammer = Join-Path $app "Contents/Resources/bin/rblhost"
        $programmer = Join-Path $extractPath "rblhost"
        foreach ($executable in @($tool, $programmer, $appExecutable, $appProgrammer)) {
            $mode = [System.IO.File]::GetUnixFileMode($executable)
            if (($mode -band [System.IO.UnixFileMode]::UserExecute) -eq 0) {
                throw "Package validation failed: executable mode is missing on $executable"
            }
            $architectures = (& lipo -archs $executable 2>&1 | Out-String).Trim()
            if (($LASTEXITCODE -ne 0) -or ($architectures -ne "arm64")) {
                throw "Package validation failed: expected a thin arm64 executable at $executable"
            }
            $dependencies = @(& otool -L $executable 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "Package validation failed: could not inspect dynamic dependencies for $executable"
            }
            foreach ($dependencyLine in $dependencies | Select-Object -Skip 1) {
                $dependency = ($dependencyLine.Trim() -split '\s+')[0]
                if (($dependency -notlike "/System/Library/*") -and
                        ($dependency -notlike "/usr/lib/*")) {
                    throw "Package validation failed: non-system dependency $dependency in $executable"
                }
            }
            Invoke-NativeChecked -Command "codesign" `
                -Arguments @("--verify", "--strict", "--verbose=2", $executable) `
                -FailureMessage "Code-signature verification failed for $executable"
        }
        Invoke-NativeChecked -Command "codesign" `
            -Arguments @("--verify", "--deep", "--strict", "--verbose=2", $app) `
            -FailureMessage "Deep app-signature verification failed"

        foreach ($versionedExecutable in @($tool, $appExecutable)) {
            $loadCommands = (& otool -l $versionedExecutable 2>&1 | Out-String)
            if (($LASTEXITCODE -ne 0) -or
                    ($loadCommands -notmatch "(?ms)cmd LC_BUILD_VERSION.*?minos 13\.0")) {
                throw "Package validation failed: expected minimum macOS 13.0 in $versionedExecutable"
            }
        }
        $infoPlist = Join-Path $app "Contents/Info.plist"
        $bundleIdentifier = (& plutil -extract CFBundleIdentifier raw -o - $infoPlist 2>&1 |
            Out-String).Trim()
        $bundleVersion = (& plutil -extract CFBundleShortVersionString raw -o - $infoPlist 2>&1 |
            Out-String).Trim()
        if (($bundleIdentifier -ne "com.wavenumber.nxpc.viewer") -or
                ($bundleVersion -ne $ExpectedVersion)) {
            throw "Package validation failed: app bundle identity or version is incorrect"
        }
        if ($RequirePublishReady) {
            Invoke-NativeChecked -Command "xcrun" -Arguments @("stapler", "validate", $app) `
                -FailureMessage "The packaged app does not have a valid stapled notarization ticket"
            Invoke-NativeChecked -Command "spctl" `
                -Arguments @("--assess", "--type", "execute", "--verbose=2", $app) `
                -FailureMessage "Gatekeeper rejected the packaged app"
        }
    } elseif ($manifest.schemaVersion -ne 1) {
        throw "Package validation failed: Windows manifest schema 1 changed"
    }
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "Core-tools releases must be built on a 64-bit operating system."
}
if ($isMacRelease) {
    $machineArchitecture = (& uname -m 2>&1 | Out-String).Trim()
    if (($LASTEXITCODE -ne 0) -or ($machineArchitecture -ne "arm64")) {
        throw "Mac core-tools releases must be built on Apple Silicon arm64."
    }
    if ($Publish -and ($SigningIdentity -notmatch "^Developer ID Application:")) {
        throw "Mac publication requires -SigningIdentity with a Developer ID Application identity."
    }
    if ($Publish -and [string]::IsNullOrWhiteSpace($NotaryProfile)) {
        throw "Mac publication requires an external -NotaryProfile for Apple notarytool."
    }
    if ((-not $Publish) -and (-not [string]::IsNullOrWhiteSpace($NotaryProfile))) {
        throw "-NotaryProfile is used only by a Mac -Publish run."
    }
} elseif (($SigningIdentity -ne "-") -or (-not [string]::IsNullOrWhiteSpace($NotaryProfile))) {
    throw "Apple signing and notarization options are valid only for a Mac release."
}
if ($Publish -and $AllowDirty) {
    throw "-AllowDirty is available only for local dry runs; publishing requires a clean source tree."
}

foreach ($command in @("git", "cmake", "ninja", "clang++", "npm")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required release command was not found: $command"
    }
}

$sourceCommit = (& git -C $repoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
if (($LASTEXITCODE -ne 0) -or ($sourceCommit -notmatch "^[0-9a-f]{40}$")) {
    throw "Could not resolve the source commit: $sourceCommit"
}
$status = (& git -C $repoRoot status --porcelain=v1 --untracked-files=all | Out-String).Trim()
if ((-not [string]::IsNullOrWhiteSpace($status)) -and (-not $AllowDirty)) {
    throw "The release source tree is not clean. Commit or remove local changes before releasing."
}
if (-not [string]::IsNullOrWhiteSpace($status)) {
    Write-Warning "Local dry run is using a dirty source tree because -AllowDirty was explicit."
}

Write-Host "Building and testing $targetPlatform core tools from $sourceCommit..." -ForegroundColor Cyan
& (Join-Path $scriptDir "build.ps1") -Configuration Release -Toolchain Clang -Version $Version
if ($LASTEXITCODE -ne 0) {
    throw "Host build failed with exit code $LASTEXITCODE"
}

$builtToolName = if ($isMacRelease) { "nxpc_tool" } else { "nxpc_tool.exe" }
$builtTool = Join-Path $repoRoot "out/build/host/runtime/Release/$builtToolName"
Invoke-NativeChecked -Command $builtTool -Arguments @("selftest") `
    -FailureMessage "Built nxpc_tool self-test failed"
Invoke-NativeChecked -Command "npm" -Arguments @("ci", "--prefix", $scriptDir) `
    -FailureMessage "Could not install the pinned host browser test dependencies"
Invoke-NativeChecked -Command "npm" -Arguments @("test", "--prefix", $scriptDir) `
    -FailureMessage "Host browser tests failed"
Invoke-NativeChecked -Command "git" `
    -Arguments @("-C", $repoRoot, "diff", "--exit-code", "--", "src/host/nxpc_usb_debug_viewer.html") `
    -FailureMessage "Browser build changed the checked-in standalone viewer"

if ($Publish) {
    $postTestStatus = (& git -C $repoRoot status --porcelain=v1 --untracked-files=all | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($postTestStatus)) {
        throw "Build or test execution left the source tree dirty; refusing to publish."
    }
}

$packageArguments = @{
    Version = $Version
    Configuration = "Release"
    SkipBuild = $true
    Force = $Force
}
if ($isMacRelease) {
    $packageArguments.SigningIdentity = $SigningIdentity
    if ($Publish) {
        $packageArguments.Notarize = $true
        $packageArguments.NotaryProfile = $NotaryProfile
    }
}
$package = & $packageScript @packageArguments
$zipHash = (Get-FileHash -LiteralPath $package.ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumLine = (Get-Content -LiteralPath $package.ChecksumPath -Raw).Trim()
if ($checksumLine -ne "$zipHash  $packageName.zip") {
    throw "Outer SHA-256 file does not match the package archive."
}

$validationRoot = Join-Path $repoRoot "out/validation/host-release/$packageName"
if (Test-Path -LiteralPath $validationRoot) {
    Remove-Item -LiteralPath $validationRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $validationRoot | Out-Null
Test-CoreToolsArchive -ZipPath $package.ZipPath -ExpectedVersion $Version `
    -ExpectedPlatform $targetPlatform -RequirePublishReady:$Publish -ValidationRoot $validationRoot

$packageManifest = Get-Content -LiteralPath (Join-Path $package.StagingPath "manifest.json") -Raw |
    ConvertFrom-Json
if ($Publish -and ($packageManifest.sourceDirty -or ($packageManifest.sourceCommit -ne $sourceCommit))) {
    throw "Package provenance is not the clean release commit; refusing to publish."
}

if (-not $Publish) {
    Write-Host ""
    Write-Host "Dry run complete; nothing was uploaded." -ForegroundColor Green
    Write-Host "Release tag: $releaseTag"
    Write-Host "Archive:     $($package.ZipPath)"
    Write-Host "Checksum:    $($package.ChecksumPath)"
    Write-Host "Run again from a clean release commit with -Publish to create the GitHub release."
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
    throw "Release repository must be public so student setup can download without authentication."
}
if (($null -eq $repo.defaultBranchRef) -or [string]::IsNullOrWhiteSpace($repo.defaultBranchRef.name)) {
    throw "GitHub repository $Repository has no default branch. Push main before publishing."
}

$immutabilityJson = (& gh api "repos/$Repository/immutable-releases" 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect immutable-release settings for $Repository`: $immutabilityJson"
}
$immutability = $immutabilityJson | ConvertFrom-Json
if (-not $immutability.enabled) {
    throw "GitHub immutable releases are disabled for $Repository. Enable them before publishing."
}

& gh api "repos/$Repository/git/commits/$sourceCommit" --silent 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Source commit $sourceCommit is not present on GitHub. Push the release commit before publishing."
}
$savedErrorActionPreference = $ErrorActionPreference
try {
    # Windows PowerShell promotes native stderr to an ErrorRecord when the
    # preference is Stop. A missing release is the expected result here, so
    # capture the exit code without terminating before it can be inspected.
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
$exactTag = @($matchingTags | Where-Object { $_.ref -eq "refs/tags/$releaseTag" })
if ($exactTag.Count -gt 0) {
    throw "GitHub tag $releaseTag already exists without a release; refusing to attach assets to an unknown commit."
}

$releaseNotes = if ($isMacRelease) {
@"
Prebuilt NXP Cup student core tools for Apple Silicon macOS 13 or newer.

Includes the signed and notarized native viewer app, command-line tool, statically
linked SDL2, and pinned NXP ROM-HID programmer. J-Link is not included or required
for the normal flow.
"@
} else {
@"
Prebuilt NXP Cup student core tools for Windows x64.

Includes the native viewer, command-line tool, SDL2 runtime, and pinned NXP
ROM-HID programmer. J-Link is not included or required for the normal flow.
"@
}
$releaseTitle = if ($isMacRelease) {
    "NXP Cup macOS core tools $Version"
} else {
    "NXP Cup core tools $Version"
}
Invoke-NativeChecked -Command "gh" -Arguments @(
    "release", "create", $releaseTag,
    $package.ZipPath, $package.ChecksumPath,
    "--repo", $Repository,
    "--target", $sourceCommit,
    "--title", $releaseTitle,
    "--notes", $releaseNotes,
    "--draft"
) -FailureMessage "Could not create the draft GitHub release"

$downloadRoot = Join-Path $validationRoot "github-download"
New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
Invoke-NativeChecked -Command "gh" -Arguments @(
    "release", "download", $releaseTag,
    "--repo", $Repository,
    "--pattern", "$packageName.zip",
    "--dir", $downloadRoot
) -FailureMessage "Could not download the draft release asset for verification"
$downloadedZip = Join-Path $downloadRoot "$packageName.zip"
$downloadHash = (Get-FileHash -LiteralPath $downloadedZip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($downloadHash -ne $zipHash) {
    throw "Downloaded GitHub asset hash does not match the local release archive; the draft was not published."
}
Test-CoreToolsArchive -ZipPath $downloadedZip -ExpectedVersion $Version `
    -ExpectedPlatform $targetPlatform -RequirePublishReady:$Publish `
    -ValidationRoot (Join-Path $validationRoot "github-package")

Invoke-NativeChecked -Command "gh" -Arguments @(
    "release", "edit", $releaseTag,
    "--repo", $Repository,
    "--draft=false"
) -FailureMessage "The verified draft could not be published"

$publicUrl = "https://github.com/$Repository/releases/download/$releaseTag/$packageName.zip"
$publicDownload = Join-Path $downloadRoot "public-$packageName.zip"
$publicVerified = $false
$lastPublicError = ""
for ($attempt = 1; $attempt -le 6; $attempt++) {
    try {
        if (Test-Path -LiteralPath $publicDownload) {
            Remove-Item -LiteralPath $publicDownload -Force
        }
        Write-Host "Anonymous asset verification attempt $attempt of 6..."
        Invoke-WebRequest -UseBasicParsing -Uri $publicUrl -OutFile $publicDownload
        $publicHash = (Get-FileHash -LiteralPath $publicDownload -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($publicHash -eq $zipHash) {
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
    throw "Release $releaseTag was published and is immutable, but anonymous verification did not complete after 6 attempts: $lastPublicError"
}
$publicHash = (Get-FileHash -LiteralPath $publicDownload -Algorithm SHA256).Hash.ToLowerInvariant()
if ($publicHash -ne $zipHash) {
    throw "The anonymous public download does not match the verified release archive."
}
Write-Host "Published and verified: $publicUrl" -ForegroundColor Green
