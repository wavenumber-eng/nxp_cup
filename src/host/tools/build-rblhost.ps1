param(
    [string]$SourceDir = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
$versionsPath = Join-Path $PSScriptRoot "../vendor/rblhost/build.versions.json"
$versions = Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json

if ($versions.schemaVersion -ne 1) {
    throw "Unsupported rblhost build definition schema: $($versions.schemaVersion)"
}
if (-not $IsMacOS -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne "Arm64") {
    throw "The pinned Mac rblhost build currently supports Apple Silicon arm64 only."
}

foreach ($command in @("git", "cargo", "rustc")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required rblhost build command was not found: $command"
    }
}

$rustVersion = (& rustc --version 2>&1 | Out-String).Trim()
if (($LASTEXITCODE -ne 0) -or ($rustVersion -notmatch "^rustc $([regex]::Escape($versions.rustVersion)) ")) {
    throw "Expected rustc $($versions.rustVersion), found: $rustVersion"
}
$cargoVersion = (& cargo --version 2>&1 | Out-String).Trim()
if (($LASTEXITCODE -ne 0) -or ($cargoVersion -notmatch "^cargo $([regex]::Escape($versions.rustVersion)) ")) {
    throw "Expected cargo $($versions.rustVersion), found: $cargoVersion"
}
$rustDetails = (& rustc -vV 2>&1 | Out-String)
if (($LASTEXITCODE -ne 0) -or ($rustDetails -notmatch "(?m)^host: aarch64-apple-darwin$")) {
    throw "Rust is not targeting the required aarch64-apple-darwin host."
}

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $sourceRoot = Join-Path $repoRoot "out/vendor/rblhost-$($versions.sourceCommit)"
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceRoot) | Out-Null
        Write-Host "Cloning pinned rblhost source..." -ForegroundColor Cyan
        & git clone --filter=blob:none --no-checkout $versions.upstream $sourceRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Could not clone pinned rblhost source (exit $LASTEXITCODE)."
        }
        & git -C $sourceRoot checkout --detach $versions.sourceCommit
        if ($LASTEXITCODE -ne 0) {
            throw "Could not check out pinned rblhost commit (exit $LASTEXITCODE)."
        }
    }
} else {
    $sourceRoot = (Resolve-Path -LiteralPath $SourceDir -ErrorAction Stop).Path
}

$sourceCommit = (& git -C $sourceRoot rev-parse HEAD 2>&1 | Out-String).Trim()
if (($LASTEXITCODE -ne 0) -or ($sourceCommit -ne $versions.sourceCommit)) {
    throw "rblhost source must be commit $($versions.sourceCommit); found $sourceCommit"
}
$sourceStatus = (& git -C $sourceRoot status --porcelain=v1 --untracked-files=all 2>&1 | Out-String).Trim()
if (($LASTEXITCODE -ne 0) -or (-not [string]::IsNullOrWhiteSpace($sourceStatus))) {
    throw "rblhost source checkout is dirty; refusing an unrecorded build."
}

Write-Host "Building pinned rblhost $($versions.version) for macOS arm64..." -ForegroundColor Cyan
Push-Location $sourceRoot
try {
    & cargo build --locked --release
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$built = Join-Path $sourceRoot "target/release/rblhost"
if (-not (Test-Path -LiteralPath $built -PathType Leaf)) {
    throw "rblhost build completed without the expected executable: $built"
}
$reportedVersion = (& $built --version 2>&1 | Out-String).Trim()
if (($LASTEXITCODE -ne 0) -or ($reportedVersion -ne "rblhost $($versions.version)")) {
    throw "Unexpected built rblhost version: $reportedVersion"
}
$actualHash = (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedHash = $versions.binaries.macosArm64.sha256
if ($actualHash -ne $expectedHash) {
    throw "rblhost SHA-256 mismatch. Expected $expectedHash, found $actualHash"
}

$publishDir = Join-Path $repoRoot "out/build/host/vendor/macos-arm64"
$published = Join-Path $publishDir "rblhost"
New-Item -ItemType Directory -Force -Path $publishDir | Out-Null
Copy-Item -LiteralPath $built -Destination $published -Force

Write-Host "Verified rblhost $($versions.version): $actualHash" -ForegroundColor Green
Write-Host "Built: $published" -ForegroundColor Green

[pscustomobject]@{
    Path = $published
    Version = $versions.version
    SourceCommit = $sourceCommit
    RustVersion = $versions.rustVersion
    Sha256 = $actualHash
}
