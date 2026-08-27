param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")]
    [string]$Version,

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [switch]$SkipBuild,

    [string]$SigningIdentity = "-",

    [switch]$Notarize,

    [string]$NotaryProfile,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "../..")).Path
$buildScript = Join-Path $scriptDir "build.ps1"
$runningOnMac = ($PSVersionTable.PSEdition -eq "Core") -and $IsMacOS

if ($Notarize -and (-not $runningOnMac)) {
    throw "Apple notarization is available only for the macOS package."
}
if ($Notarize -and ($SigningIdentity -notmatch "^Developer ID Application:")) {
    throw "A Developer ID Application signing identity is required for notarization."
}
if ($Notarize -and [string]::IsNullOrWhiteSpace($NotaryProfile)) {
    throw "-NotaryProfile is required when -Notarize is used."
}
if ((-not $Notarize) -and (-not [string]::IsNullOrWhiteSpace($NotaryProfile))) {
    throw "-NotaryProfile is valid only with -Notarize."
}

function Get-CommandVersionLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$Arguments = @("--version")
    )

    $commandInfo = Get-Command $Command -ErrorAction Stop | Select-Object -First 1
    $output = (& $commandInfo.Source @Arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "$Command version check failed with exit code $LASTEXITCODE"
    }
    return ($output -split "`r?`n")[0].Trim()
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
        throw "Path is outside the package root: $fullPath"
    }
    return $fullPath.Substring($basePrefix.Length).Replace($separator, '/')
}

function New-DeterministicZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    $archiveStream = [System.IO.File]::Open(
        $DestinationPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $archiveStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            $fixedTimestamp = [DateTimeOffset]::new(
                2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero
            )
            $sourceRoot = [System.IO.Path]::GetFullPath($SourceDirectory)
            foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse |
                    Sort-Object FullName) {
                $relativeName = Get-NormalizedRelativePath -BaseDirectory $sourceRoot `
                    -LiteralPath $file.FullName
                $entry = $archive.CreateEntry(
                    $relativeName,
                    [System.IO.Compression.CompressionLevel]::Optimal
                )
                $entry.LastWriteTime = $fixedTimestamp
                if ($runningOnMac) {
                    $unixMode = [int][System.IO.File]::GetUnixFileMode($file.FullName)
                    $entry.ExternalAttributes = (($unixMode -bor 0x8000) -shl 16)
                }
                $inputStream = [System.IO.File]::OpenRead($file.FullName)
                $outputStream = $entry.Open()
                try {
                    $inputStream.CopyTo($outputStream)
                } finally {
                    $outputStream.Dispose()
                    $inputStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $archiveStream.Dispose()
    }
}

if (-not $SkipBuild) {
    & $buildScript -Configuration $Configuration -Toolchain Clang -Version $Version
    if ($LASTEXITCODE -ne 0) {
        throw "Host build failed with exit code $LASTEXITCODE"
    }
}

$runtimeDir = Join-Path $repoRoot "out/build/host/runtime/$Configuration"
$required = if ($runningOnMac) {
    @("NXP Cup Viewer.app", "nxpc_tool", "rblhost", "rblhost-LICENSE.txt")
} else {
    @("nxpc_viewer.exe", "nxpc_tool.exe", "SDL2.dll", "rblhost.exe", "rblhost-LICENSE.txt")
}
foreach ($name in $required) {
    $path = Join-Path $runtimeDir $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing runtime artifact: $path"
    }
}

$rblhostName = if ($runningOnMac) { "rblhost" } else { "rblhost.exe" }
$rblhost = Join-Path $runtimeDir $rblhostName
$rblhostVersion = (& $rblhost --version 2>&1 | Out-String).Trim()
if (($LASTEXITCODE -ne 0) -or ($rblhostVersion -ne "rblhost 0.2.0")) {
    throw "Unexpected packaged programmer version: $rblhostVersion"
}
$rblhostSha256 = (Get-FileHash -LiteralPath $rblhost -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedRblhostSha256 = if ($runningOnMac) {
    "d75babe663d783ad83a5c5b760ef0581080227031f8d74256fc282d3d2c76344"
} else {
    "6cae03c432489e0bd8a658f91e5899e7d1153b6859be02c7a76798f2885cd2a8"
}
if ($rblhostSha256 -ne $expectedRblhostSha256) {
    throw "Unexpected rblhost binary SHA-256: $rblhostSha256"
}

$sourceCommit = (& git -C $repoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
if (($LASTEXITCODE -ne 0) -or ($sourceCommit -notmatch "^[0-9a-f]{40}$")) {
    throw "Could not resolve the source commit: $sourceCommit"
}
$sourceStatus = (& git -C $repoRoot status --porcelain=v1 --untracked-files=all | Out-String).Trim()
$sourceDirty = -not [string]::IsNullOrWhiteSpace($sourceStatus)

$distRoot = Join-Path $repoRoot "out/artifacts/host/packages"
$packageName = if ($runningOnMac) {
    "nxp-cup-core-tools-macos-arm64-$Version"
} else {
    "nxp-cup-core-tools-win-x64-$Version"
}
$staging = Join-Path $distRoot $packageName
$zip = Join-Path $distRoot "$packageName.zip"
$checksum = "$zip.sha256"

foreach ($existingPath in @($staging, $zip, $checksum)) {
    if (Test-Path -LiteralPath $existingPath) {
        if (-not $Force) {
            throw "Release output already exists: $existingPath. Pass -Force to replace this exact version."
        }
        Remove-Item -LiteralPath $existingPath -Recurse -Force
    }
}
New-Item -ItemType Directory -Force -Path $staging | Out-Null

foreach ($name in $required) {
    $source = Join-Path $runtimeDir $name
    $destination = Join-Path $staging $name
    if (Test-Path -LiteralPath $source -PathType Container) {
        Copy-Item -LiteralPath $source -Destination $destination -Recurse
    } else {
        Copy-Item -LiteralPath $source -Destination $destination
    }
}
$packageReadme = if ($runningOnMac) { "PACKAGE-README-macos.md" } else { "PACKAGE-README.md" }
Copy-Item -LiteralPath (Join-Path $scriptDir $packageReadme) `
    -Destination (Join-Path $staging "HOST-README.md")
Copy-Item -LiteralPath (Join-Path $scriptDir "../common/egfx/test/sdl/sdl2/COPYING.txt") `
    -Destination (Join-Path $staging "SDL2-LICENSE.txt")
Copy-Item -LiteralPath (Join-Path $scriptDir "vendor/imgui/LICENSE.txt") `
    -Destination (Join-Path $staging "Dear-ImGui-LICENSE.txt")

if ($runningOnMac) {
    if ([string]::IsNullOrWhiteSpace($SigningIdentity)) {
        throw "A macOS signing identity is required; use '-' for an explicit local ad-hoc package."
    }
    $app = Join-Path $staging "NXP Cup Viewer.app"
    $appProgrammer = Join-Path $app "Contents/Resources/bin/rblhost"
    $timestampArgument = if ($SigningIdentity -eq "-") { "--timestamp=none" } else { "--timestamp" }
    foreach ($executable in @($appProgrammer, (Join-Path $staging "nxpc_tool"),
            (Join-Path $staging "rblhost"))) {
        & codesign --force --options runtime $timestampArgument --sign $SigningIdentity $executable
        if ($LASTEXITCODE -ne 0) {
            throw "codesign failed for $executable with exit code $LASTEXITCODE"
        }
    }
    & codesign --force --options runtime $timestampArgument --sign $SigningIdentity $app
    if ($LASTEXITCODE -ne 0) {
        throw "codesign failed for $app with exit code $LASTEXITCODE"
    }
    & codesign --verify --deep --strict --verbose=2 $app
    if ($LASTEXITCODE -ne 0) {
        throw "Signed app verification failed with exit code $LASTEXITCODE"
    }

    $infoPlist = Join-Path $app "Contents/Info.plist"
    $bundleIdentifier = (& plutil -extract CFBundleIdentifier raw -o - $infoPlist 2>&1 |
        Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read CFBundleIdentifier from the packaged app."
    }
    $bundleVersion = (& plutil -extract CFBundleShortVersionString raw -o - $infoPlist 2>&1 |
        Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read CFBundleShortVersionString from the packaged app."
    }
    if (($bundleIdentifier -ne "com.wavenumber.nxpc.viewer") -or ($bundleVersion -ne $Version)) {
        throw "Unexpected app identity/version: $bundleIdentifier $bundleVersion"
    }

    $notarySubmissionId = $null
    if ($Notarize) {
        $notaryZip = Join-Path $distRoot ".$packageName-notary.zip"
        if (Test-Path -LiteralPath $notaryZip) {
            Remove-Item -LiteralPath $notaryZip -Force
        }
        try {
            New-DeterministicZip -SourceDirectory $staging -DestinationPath $notaryZip
            $notaryOutput = (& xcrun notarytool submit $notaryZip `
                    --keychain-profile $NotaryProfile --wait --timeout 30m `
                    --output-format json 2>&1 |
                Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                throw "Apple notarization submission failed: $notaryOutput"
            }
            $notaryResult = $notaryOutput | ConvertFrom-Json
            if ($notaryResult.status -ne "Accepted") {
                throw "Apple notarization was not accepted: $notaryOutput"
            }
            $notarySubmissionId = $notaryResult.id
            & xcrun stapler staple $app
            if ($LASTEXITCODE -ne 0) {
                throw "Could not staple the Apple notarization ticket to the app."
            }
            & xcrun stapler validate $app
            if ($LASTEXITCODE -ne 0) {
                throw "The stapled Apple notarization ticket did not validate."
            }
            & spctl --assess --type execute --verbose=2 $app
            if ($LASTEXITCODE -ne 0) {
                throw "Gatekeeper did not accept the notarized app."
            }
        } finally {
            if (Test-Path -LiteralPath $notaryZip) {
                Remove-Item -LiteralPath $notaryZip -Force
            }
        }
    }
}

$manifestFiles = @(
    Get-ChildItem -LiteralPath $staging -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            $relativeName = Get-NormalizedRelativePath -BaseDirectory $staging `
                -LiteralPath $_.FullName
            [ordered]@{
                name = $relativeName
                size = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
)
$manifest = [ordered]@{
    schemaVersion = if ($runningOnMac) { 2 } else { 1 }
    releaseVersion = $Version
    sourceCommit = $sourceCommit
    sourceDirty = $sourceDirty
    platform = if ($runningOnMac) { "macos" } else { "windows" }
    architecture = if ($runningOnMac) { "arm64" } else { "x64" }
    configuration = $Configuration
    tools = [ordered]@{
        cmake = Get-CommandVersionLine -Command "cmake"
        ninja = Get-CommandVersionLine -Command "ninja"
        compiler = Get-CommandVersionLine -Command "clang++"
        programmer = [ordered]@{
            name = "rblhost"
            version = "0.2.0"
            upstream = "https://github.com/nxp-mcuxpresso/rblhost"
            sourceCommit = "7a775dde2c44bd345a1ac067698afa999bd71be0"
            binarySha256 = $rblhostSha256
            rustVersion = "1.96.1"
            buildProfile = "release; upstream lockfile"
        }
        sdl = [ordered]@{
            version = "2.26.5"
            upstream = "https://www.libsdl.org/release/SDL2-2.26.5.tar.gz"
            sourceCommit = "ac13ca9ab691e13e8eebe9684740ddcb0d716203"
            sourceArchiveSha256 = "ad8fea3da1be64c83c45b1d363a6b4ba8fd60f5bde3b23ec73855709ec5eabf7"
            linkage = if ($runningOnMac) { "static" } else { "dynamic" }
        }
    }
    files = $manifestFiles
}
if ($runningOnMac) {
    $manifest["minimumOsVersion"] = "13.0"
    $manifest["bundleIdentifier"] = "com.wavenumber.nxpc.viewer"
    $manifest["signing"] = [ordered]@{
        state = if ($SigningIdentity -eq "-") { "adhoc" } else { "developer-id" }
        identity = $SigningIdentity
        hardenedRuntime = $true
        notarized = [bool]$Notarize
    }
    if ($Notarize) {
        $manifest["signing"]["notarySubmissionId"] = $notarySubmissionId
    }
}
$manifestJson = ($manifest | ConvertTo-Json -Depth 8) + "`n"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText(
    (Join-Path $staging "manifest.json"),
    $manifestJson,
    $utf8NoBom
)

New-DeterministicZip -SourceDirectory $staging -DestinationPath $zip
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $checksum,
    "$zipHash  $packageName.zip`n",
    $utf8NoBom
)

Write-Host "Portable runtime: $staging"
Write-Host "Portable zip:     $zip"
Write-Host "SHA-256:          $zipHash"

[pscustomobject]@{
    PackageName = $packageName
    StagingPath = $staging
    ZipPath = $zip
    ChecksumPath = $checksum
    Sha256 = $zipHash
}
