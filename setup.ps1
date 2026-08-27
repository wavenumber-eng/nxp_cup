<#
.SYNOPSIS
    Provision the required firmware tools and pinned prebuilt host runtime.

.DESCRIPTION
    The ordinary student setup installs and verifies:

      1. Arm GNU Toolchain 14.2.Rel1 under out\toolchains
      2. CMake and Ninja through the native package manager when needed
      3. Host tools under out\artifacts\host: the pinned Windows release or a
         local Apple Silicon build from repository-pinned inputs

    Downloads are cached under out\downloads. A candidate toolchain or host runtime
    is fully verified before it replaces an existing installation. The local Mac
    build requires no Apple signing identity or Rust toolchain. Nothing is added to
    a persistent PATH and no environment variables are persisted.

    Maintainers who build the native host from source may explicitly add uv and
    LLVM-MinGW with -IncludeMaintainerTools.

.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -Force
    .\setup.ps1 -CoreToolsArchive D:\handoff\nxp-cup-core-tools-win-x64-1.0.1.zip
    .\setup.ps1 -IncludeMaintainerTools

    On Apple Silicon macOS, run ./setup.sh. It installs PowerShell when needed
    and delegates to this shared implementation.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipArm,
    [switch]$SkipCMake,
    [switch]$SkipNinja,
    [switch]$SkipCoreTools,
    [string]$ArmArchive,
    [string]$CoreToolsArchive,
    [switch]$IncludeMaintainerTools
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http

$RunningOnMac = ($PSVersionTable.PSEdition -eq "Core") -and $IsMacOS
$RunningOnWindows = -not $RunningOnMac -and ($env:OS -eq "Windows_NT")
if (-not $RunningOnMac -and -not $RunningOnWindows) {
    throw "NXP Cup setup supports Windows x64 and Apple Silicon macOS only."
}

$RepoRoot = $PSScriptRoot
$OutDir = Join-Path $RepoRoot "out"
$ToolsDir = Join-Path $OutDir "toolchains"
$DownloadsDir = Join-Path $OutDir "downloads"
$StagingDir = Join-Path $OutDir "staging"
$HostDir = Join-Path $OutDir "artifacts\host"
$HostBuildScript = Join-Path $RepoRoot "src/host/build.ps1"
$VersionsPath = Join-Path $RepoRoot "setup.versions.json"

if (-not (Test-Path -LiteralPath $VersionsPath -PathType Leaf)) {
    throw "Pinned setup definition is missing: $VersionsPath"
}
$Versions = Get-Content -LiteralPath $VersionsPath -Raw | ConvertFrom-Json
if ($Versions.schemaVersion -ne 1) {
    throw "Unsupported setup definition schema: $($Versions.schemaVersion)"
}
if ($RunningOnMac -and
    ($PSVersionTable.PSVersion -lt [version]$Versions.requiredCommands.powershellMinimumVersion)) {
    throw "PowerShell $($Versions.requiredCommands.powershellMinimumVersion) or newer is required on macOS. Rerun ./setup.sh to install it with Homebrew."
}

$ArmFamily = $Versions.armGnu
$CoreToolsFamily = $Versions.coreTools
$Arm = if ($RunningOnMac) { $ArmFamily.macosArm64 } else { $ArmFamily }
$CoreTools = if ($RunningOnMac) { $CoreToolsFamily.macosArm64 } else { $CoreToolsFamily }
if ($RunningOnMac -and ($null -eq $Arm)) {
    throw "The Apple Silicon Arm GNU toolchain pin is missing from setup.versions.json."
}
$CoreToolsAvailable = ($null -ne $CoreTools) -and ($CoreTools.available -ne $false)
$ArmDir = Join-Path $ToolsDir $Arm.directoryName
$ExecutableSuffix = if ($RunningOnWindows) { ".exe" } else { "" }
$ArmGcc = Join-Path (Join-Path $ArmDir "bin") "arm-none-eabi-gcc$ExecutableSuffix"
$PathComparison = if ($RunningOnWindows) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}

function Write-Header {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Test-OnPath {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Remove-SetupPath {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return
    }
    $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $outPrefix = [System.IO.Path]::GetFullPath($OutDir).TrimEnd($separator) + $separator
    if (-not $fullPath.StartsWith($outPrefix, $PathComparison)) {
        throw "Refusing to remove a setup path outside out: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NormalizedRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $basePrefix = [System.IO.Path]::GetFullPath($BaseDirectory).TrimEnd($separator) + $separator
    $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
    if (-not $fullPath.StartsWith($basePrefix, $PathComparison)) {
        throw "Path is outside the setup root: $fullPath"
    }
    return $fullPath.Substring($basePrefix.Length).Replace($separator, '/')
}

function Save-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("nxp-cup-setup/1.0")
    $cancellation = [System.Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromMinutes(30)
    )
    try {
        $response = $client.GetAsync(
            $Url,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token
        ).GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()
        $total = $response.Content.Headers.ContentLength
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $buffer = New-Object byte[] (1024 * 1024)
            [int64]$received = 0
            $lastReported = -10
            while (($read = $inputStream.ReadAsync(
                    $buffer, 0, $buffer.Length, $cancellation.Token
                ).GetAwaiter().GetResult()) -gt 0) {
                $outputStream.Write($buffer, 0, $read)
                $received += $read
                if ($total -and ($total -gt 0)) {
                    $percent = [int][Math]::Floor(100.0 * $received / $total)
                    Write-Progress -Activity "Downloading $DisplayName" `
                        -Status "$received of $total bytes" -PercentComplete $percent
                    if ($percent -ge ($lastReported + 10)) {
                        Write-Host "    $percent% ($received/$total bytes)" -ForegroundColor DarkGray
                        $lastReported = $percent
                    }
                }
            }
        } finally {
            $outputStream.Dispose()
            $inputStream.Dispose()
            Write-Progress -Activity "Downloading $DisplayName" -Completed
        }
    } finally {
        if ($response) { $response.Dispose() }
        $cancellation.Dispose()
        $client.Dispose()
    }
}

function Get-VerifiedArchive {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ArchiveName,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [string]$SuppliedArchive
    )

    $ExpectedSha256 = $ExpectedSha256.ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($SuppliedArchive)) {
        $resolved = (Resolve-Path -LiteralPath $SuppliedArchive -ErrorAction Stop).Path
        $actual = Get-Sha256 -LiteralPath $resolved
        if ($actual -ne $ExpectedSha256) {
            throw "$DisplayName archive SHA-256 mismatch. Expected $ExpectedSha256, found $actual in $resolved"
        }
        Write-Host "  [OK] Verified supplied archive: $resolved" -ForegroundColor Green
        return $resolved
    }

    New-Item -ItemType Directory -Path $DownloadsDir -Force | Out-Null
    $cached = Join-Path $DownloadsDir $ArchiveName
    if ((Test-Path -LiteralPath $cached -PathType Leaf) -and (-not $Force)) {
        $actual = Get-Sha256 -LiteralPath $cached
        if ($actual -eq $ExpectedSha256) {
            Write-Host "  [CACHE] Verified $cached" -ForegroundColor DarkGray
            return $cached
        }
        Write-Warning "Discarding cached $DisplayName archive with SHA-256 $actual"
        Remove-Item -LiteralPath $cached -Force
    } elseif (Test-Path -LiteralPath $cached) {
        Remove-Item -LiteralPath $cached -Force
    }

    $partial = "$cached.partial"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }
    Write-Host "  Downloading $DisplayName..." -ForegroundColor White
    Write-Host "    $Url" -ForegroundColor DarkGray
    try {
        Save-RemoteFile -Url $Url -Destination $partial -DisplayName $DisplayName
        $actual = Get-Sha256 -LiteralPath $partial
        if ($actual -ne $ExpectedSha256) {
            throw "$DisplayName download SHA-256 mismatch. Expected $ExpectedSha256, found $actual"
        }
        Move-Item -LiteralPath $partial -Destination $cached
    } catch {
        if (Test-Path -LiteralPath $partial) {
            Remove-Item -LiteralPath $partial -Force
        }
        throw
    }
    Write-Host "  [OK] Downloaded and verified $ArchiveName" -ForegroundColor Green
    return $cached
}

function Expand-ZipStreaming {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $destinationPrefix = [System.IO.Path]::GetFullPath($Destination).TrimEnd($separator) + $separator
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $total = $archive.Entries.Count
        $index = 0
        $lastReported = -10
        foreach ($entry in $archive.Entries) {
            $index++
            $target = [System.IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($destinationPrefix, $PathComparison)) {
                throw "Archive entry escapes the staging directory: $($entry.FullName)"
            }
            if ($RunningOnMac) {
                $entryType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
                if ($entryType -eq 0xA000) {
                    throw "Archive contains an unsupported symbolic link: $($entry.FullName)"
                }
                continue
            }
            if ($entry.FullName.EndsWith("/")) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
            } else {
                $parent = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
            $percent = [int][Math]::Floor(100.0 * $index / $total)
            if ($percent -ge ($lastReported + 10)) {
                Write-Host "    $percent% ($index/$total files)" -ForegroundColor DarkGray
                $lastReported = $percent
            }
        }
    } finally {
        $archive.Dispose()
    }
    if ($RunningOnMac) {
        & /usr/bin/ditto -x -k $ZipPath $Destination
        if ($LASTEXITCODE -ne 0) {
            throw "ditto could not extract $ZipPath (exit $LASTEXITCODE)"
        }
    }
}

function Expand-TarXz {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $entries = @(& /usr/bin/tar -tJf $ArchivePath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "tar could not inspect $ArchivePath (exit $LASTEXITCODE)"
    }
    foreach ($entry in $entries) {
        $normalized = $entry.Replace('\', '/')
        if ($normalized.StartsWith('/') -or ($normalized -match '(^|/)\.\.(/|$)')) {
            throw "Archive entry escapes the staging directory: $entry"
        }
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & /usr/bin/tar -xJf $ArchivePath -C $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "tar could not extract $ArchivePath (exit $LASTEXITCODE)"
    }
}

function Test-ArmDirectory {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $compiler = Join-Path (Join-Path $Directory "bin") "arm-none-eabi-gcc$ExecutableSuffix"
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        return $false
    }
    $version = (& $compiler -dumpfullversion 2>&1 | Out-String).Trim()
    if (($LASTEXITCODE -ne 0) -or ($version -ne $Arm.compilerVersion)) {
        return $false
    }
    return ((Get-Sha256 -LiteralPath $compiler) -eq $Arm.compilerSha256)
}

function Switch-SetupDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string[]]$PreserveDirectories = @()
    )

    $backup = Join-Path $StagingDir ("backup-{0}-{1}" -f ([System.IO.Path]::GetFileName($Destination)), $PID)
    Remove-SetupPath -LiteralPath $backup
    $hadExisting = Test-Path -LiteralPath $Destination
    try {
        if ($hadExisting) {
            Move-Item -LiteralPath $Destination -Destination $backup
        }
        Move-Item -LiteralPath $Candidate -Destination $Destination
        foreach ($name in $PreserveDirectories) {
            $preserved = Join-Path $backup $name
            $newPath = Join-Path $Destination $name
            if ((Test-Path -LiteralPath $preserved -PathType Container) -and
                (-not (Test-Path -LiteralPath $newPath))) {
                Copy-Item -LiteralPath $preserved -Destination $newPath -Recurse
            }
        }
    } catch {
        if (Test-Path -LiteralPath $Destination) {
            Remove-SetupPath -LiteralPath $Destination
        }
        if (Test-Path -LiteralPath $backup) {
            Move-Item -LiteralPath $backup -Destination $Destination
        }
        throw
    }
    Remove-SetupPath -LiteralPath $backup
}

function Install-ArmToolchain {
    if ((-not $Force) -and (Test-ArmDirectory -Directory $ArmDir)) {
        Write-Host "  [SKIP] Verified GCC $($Arm.compilerVersion): $ArmDir" -ForegroundColor DarkGray
        return
    }

    $archive = Get-VerifiedArchive -DisplayName "Arm GNU Toolchain $($Arm.releaseVersion)" `
        -Url $Arm.url -ArchiveName $Arm.archiveName -ExpectedSha256 $Arm.sha256 `
        -SuppliedArchive $ArmArchive
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    $candidate = Join-Path $StagingDir "arm-$PID"
    Remove-SetupPath -LiteralPath $candidate
    try {
        Write-Host "  Extracting the Arm toolchain (~13k files)..." -ForegroundColor White
        if ($RunningOnMac) {
            Expand-TarXz -ArchivePath $archive -Destination $candidate
        } else {
            Expand-ZipStreaming -ZipPath $archive -Destination $candidate
        }
        if (-not (Test-ArmDirectory -Directory $candidate)) {
            $inner = Get-ChildItem -LiteralPath $candidate -Directory |
                Where-Object { Test-ArmDirectory -Directory $_.FullName } |
                Select-Object -First 1
            if ($inner) {
                Get-ChildItem -LiteralPath $inner.FullName -Force |
                    Move-Item -Destination $candidate -Force
                Remove-SetupPath -LiteralPath $inner.FullName
            }
        }
        if (-not (Test-ArmDirectory -Directory $candidate)) {
            throw "Arm archive did not contain GCC $($Arm.compilerVersion) at the expected layout."
        }
        New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
        Switch-SetupDirectory -Candidate $candidate -Destination $ArmDir
    } finally {
        Remove-SetupPath -LiteralPath $candidate
    }
    Write-Host "  [OK] Installed arm-none-eabi-gcc $($Arm.compilerVersion)" -ForegroundColor Green
}

function Update-SetupProcessPath {
    if ($RunningOnMac) {
        $brewPrefix = (& brew --prefix 2>&1 | Out-String).Trim()
        if (($LASTEXITCODE -ne 0) -or [string]::IsNullOrWhiteSpace($brewPrefix)) {
            throw "Homebrew is present but its installation prefix could not be resolved."
        }
        $env:PATH = @((Join-Path $brewPrefix "bin"), (Join-Path $brewPrefix "sbin"),
            $env:PATH) -join [System.IO.Path]::PathSeparator
        return
    }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machinePath, $userPath, $env:Path) -join ";"
}

function Install-ViaHomebrew {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Formula,
        [Parameter(Mandatory = $true)][string]$ProbeCommand,
        [switch]$Required
    )

    if (Test-OnPath -Name $ProbeCommand) {
        Write-Host "  [SKIP] Already on PATH" -ForegroundColor DarkGray
        return $true
    }
    if (-not (Test-OnPath -Name "brew")) {
        if ($Required) {
            throw "Homebrew is unavailable and required command '$ProbeCommand' was not found. Run ./setup.sh after installing Homebrew from https://brew.sh."
        }
        Write-Warning "Homebrew is unavailable; optional $DisplayName was not installed."
        return $false
    }

    Write-Host "  Installing $DisplayName with Homebrew..." -ForegroundColor White
    & brew install --formula $Formula
    if ($LASTEXITCODE -ne 0) {
        if ($Required) {
            throw "Homebrew could not install required $DisplayName (exit $LASTEXITCODE)."
        }
        Write-Warning "Homebrew could not install optional $DisplayName (exit $LASTEXITCODE)."
        return $false
    }
    Update-SetupProcessPath
    if (-not (Test-OnPath -Name $ProbeCommand)) {
        if ($Required) {
            throw "$DisplayName installation completed, but '$ProbeCommand' is still unavailable. Open a new terminal and rerun ./setup.sh."
        }
        Write-Warning "$DisplayName installed, but '$ProbeCommand' is not visible in this process."
        return $false
    }
    Write-Host "  [OK] Installed $DisplayName" -ForegroundColor Green
    return $true
}

function Install-ViaWinget {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$WingetId,
        [Parameter(Mandatory = $true)][string]$ProbeCommand,
        [switch]$Required
    )

    if (Test-OnPath -Name $ProbeCommand) {
        Write-Host "  [SKIP] Already on PATH" -ForegroundColor DarkGray
        return $true
    }
    if (-not (Test-OnPath -Name "winget")) {
        if ($Required) {
            throw "winget is unavailable and required command '$ProbeCommand' was not found. Install $DisplayName, then rerun setup.ps1."
        }
        Write-Warning "winget is unavailable; optional $DisplayName was not installed."
        return $false
    }

    Write-Host "  Installing $DisplayName via winget..." -ForegroundColor White
    & winget install --id $WingetId --exact --silent `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        if ($Required) {
            throw "winget could not install required $DisplayName (exit $LASTEXITCODE). Install it manually, then rerun setup.ps1."
        }
        Write-Warning "winget could not install optional $DisplayName (exit $LASTEXITCODE)."
        return $false
    }
    Update-SetupProcessPath
    if (-not (Test-OnPath -Name $ProbeCommand)) {
        if ($Required) {
            throw "$DisplayName installation completed, but '$ProbeCommand' is still unavailable. Open a new terminal and rerun setup.ps1."
        }
        Write-Warning "$DisplayName installed, but '$ProbeCommand' is not visible in this process."
        return $false
    }
    Write-Host "  [OK] Installed $DisplayName" -ForegroundColor Green
    return $true
}

function Assert-UsableCommand {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Command,
        [version]$MinimumVersion,
        [string[]]$Arguments = @("--version")
    )

    $commandInfo = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $commandInfo) {
        throw "Required command '$Command' is unavailable after $DisplayName setup."
    }
    $output = (& $commandInfo.Source @Arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Required command '$Command' failed its version check: $output"
    }
    $firstLine = ($output -split "`r?`n")[0].Trim()
    if ($MinimumVersion) {
        $versionMatch = [regex]::Match($firstLine, '\d+(?:\.\d+){1,3}')
        if ((-not $versionMatch.Success) -or
            ([version]$versionMatch.Value -lt $MinimumVersion)) {
            throw "$DisplayName $MinimumVersion or newer is required; found '$firstLine'."
        }
    }
    Write-Host "  [OK] $firstLine" -ForegroundColor Green
}

function Test-CoreToolsDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [string[]]$AllowedDirectories = @()
    )

    $manifestPath = Join-Path $Directory "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "manifest.json is missing"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $expectedSchema = if ($RunningOnMac) { 2 } else { 1 }
    $expectedPlatform = if ($RunningOnMac) { "macos" } else { "windows" }
    $expectedArchitecture = if ($RunningOnMac) { "arm64" } else { "x64" }
    if (($manifest.schemaVersion -ne $expectedSchema) -or
        ($manifest.releaseVersion -ne $CoreTools.releaseVersion) -or
        ($manifest.sourceCommit -ne $CoreTools.sourceCommit) -or
        ($manifest.sourceDirty -ne $false) -or
        ($manifest.platform -ne $expectedPlatform) -or
        ($manifest.architecture -ne $expectedArchitecture)) {
        throw "manifest.json does not identify the pinned clean $expectedPlatform $expectedArchitecture release"
    }
    if ($RunningOnMac -and
        (($manifest.minimumOsVersion -ne "13.0") -or
         ($manifest.bundleIdentifier -ne "com.wavenumber.nxpc.viewer") -or
         ($manifest.signing.state -ne "developer-id") -or
         (-not $manifest.signing.hardenedRuntime) -or
         (-not $manifest.signing.notarized))) {
        throw "manifest.json does not identify a signed and notarized macOS 13 app"
    }

    $expectedNames = @($CoreTools.payloadFiles | Sort-Object)
    $manifestNames = @($manifest.files | ForEach-Object { $_.name } | Sort-Object)
    if (($expectedNames -join "`n") -ne ($manifestNames -join "`n")) {
        throw "manifest.json payload does not match the pinned release contract"
    }
    foreach ($entry in $manifest.files) {
        $payload = Join-Path $Directory $entry.name
        if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) {
            throw "$($entry.name) is missing"
        }
        $file = Get-Item -LiteralPath $payload
        $hash = Get-Sha256 -LiteralPath $payload
        if (($file.Length -ne $entry.size) -or ($hash -ne $entry.sha256)) {
            throw "$($entry.name) does not match manifest.json"
        }
    }

    $actualNames = @(
        Get-ChildItem -LiteralPath $Directory -File -Recurse |
            ForEach-Object {
                Get-NormalizedRelativePath -BaseDirectory $Directory `
                    -LiteralPath $_.FullName
            } |
            Where-Object {
                ($_ -ne "manifest.json") -and
                ((($_ -split '/', 2)[0]) -notin $AllowedDirectories)
            } |
            Sort-Object
    )
    if (($actualNames -join "`n") -ne ($expectedNames -join "`n")) {
        throw "installed runtime files do not match the pinned release contract"
    }
    $expectedTopDirectories = @($expectedNames | Where-Object { $_ -like "*/*" } |
        ForEach-Object { ($_ -split '/', 2)[0] } | Sort-Object -Unique)
    $unexpectedDirectories = @(Get-ChildItem -LiteralPath $Directory -Directory |
        Where-Object { ($_.Name -notin $AllowedDirectories) -and
            ($_.Name -notin $expectedTopDirectories) })
    if ($unexpectedDirectories.Count -gt 0) {
        throw "unexpected runtime directory $($unexpectedDirectories[0].Name)"
    }

    $toolName = if ($RunningOnMac) { "nxpc_tool" } else { "nxpc_tool.exe" }
    $tool = Join-Path $Directory $toolName
    $selfTestArguments = @($CoreTools.selfTestArguments)
    if ($selfTestArguments.Count -eq 0) {
        throw "Pinned core-tools self-test arguments are missing"
    }
    & $tool @selfTestArguments
    if ($LASTEXITCODE -ne 0) {
        throw "$toolName selftest failed with exit code $LASTEXITCODE"
    }
    if ($RunningOnMac) {
        $app = Join-Path $Directory "NXP Cup Viewer.app"
        foreach ($executable in @(
            $tool,
            (Join-Path $Directory "rblhost"),
            (Join-Path $app "Contents/MacOS/NXP Cup Viewer"),
            (Join-Path $app "Contents/Resources/bin/rblhost")
        )) {
            $mode = [System.IO.File]::GetUnixFileMode($executable)
            if (($mode -band [System.IO.UnixFileMode]::UserExecute) -eq 0) {
                throw "executable mode is missing on $executable"
            }
        }
        & codesign --verify --deep --strict --verbose=2 $app
        if ($LASTEXITCODE -ne 0) {
            throw "NXP Cup Viewer.app signature validation failed with exit code $LASTEXITCODE"
        }
        & xcrun stapler validate $app
        if ($LASTEXITCODE -ne 0) {
            throw "NXP Cup Viewer.app does not have a valid stapled notarization ticket"
        }
    }
}

function Test-LocalMacCoreToolsDirectory {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $app = Join-Path $Directory "NXP Cup Viewer.app"
    $executables = @(
        (Join-Path $Directory "nxpc_tool"),
        (Join-Path $Directory "rblhost"),
        (Join-Path $app "Contents/MacOS/NXP Cup Viewer"),
        (Join-Path $app "Contents/Resources/bin/rblhost")
    )
    foreach ($executable in $executables) {
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "Locally built Mac runtime is missing $executable"
        }
        $mode = [System.IO.File]::GetUnixFileMode($executable)
        if (($mode -band [System.IO.UnixFileMode]::UserExecute) -eq 0) {
            throw "Executable mode is missing on $executable"
        }
        $architectures = (& /usr/bin/lipo -archs $executable 2>&1 | Out-String).Trim()
        if (($LASTEXITCODE -ne 0) -or ($architectures -ne "arm64")) {
            throw "Locally built Mac executable is not thin arm64: $executable ($architectures)"
        }
    }

    & /usr/bin/codesign --verify --deep --strict --verbose=2 $app
    if ($LASTEXITCODE -ne 0) {
        throw "Locally built NXP Cup Viewer.app signature validation failed with exit code $LASTEXITCODE"
    }
    $bundleIdentifier = (& /usr/bin/plutil -extract CFBundleIdentifier raw -o - `
        (Join-Path $app "Contents/Info.plist") 2>&1 | Out-String).Trim()
    if (($LASTEXITCODE -ne 0) -or ($bundleIdentifier -ne "com.wavenumber.nxpc.viewer")) {
        throw "Locally built viewer has an unexpected bundle identifier: $bundleIdentifier"
    }

    $programmerVersion = (& (Join-Path $Directory "rblhost") --version 2>&1 |
        Out-String).Trim()
    if (($LASTEXITCODE -ne 0) -or ($programmerVersion -ne "rblhost 0.2.0")) {
        throw "Locally built runtime has an unexpected programmer version: $programmerVersion"
    }
    & (Join-Path $Directory "nxpc_tool") selftest
    if ($LASTEXITCODE -ne 0) {
        throw "Locally built nxpc_tool selftest failed with exit code $LASTEXITCODE"
    }
}

function Install-LocalMacCoreTools {
    if (-not [string]::IsNullOrWhiteSpace($CoreToolsArchive)) {
        throw "-CoreToolsArchive cannot be used until an immutable Mac binary release is pinned. Omit it to build the host tools locally."
    }
    if ([string]::IsNullOrWhiteSpace($CoreTools.localBuildVersion)) {
        throw "The local Mac core-tools build version is missing from setup.versions.json."
    }
    if ((-not $Force) -and (Test-Path -LiteralPath $HostDir -PathType Container)) {
        try {
            Test-LocalMacCoreToolsDirectory -Directory $HostDir
            Write-Host "  [SKIP] Verified locally built core tools: $HostDir" -ForegroundColor DarkGray
            return
        } catch {
            Write-Warning "Existing local Mac host runtime is not usable: $_"
        }
    }

    Assert-UsableCommand -DisplayName "Xcode Command Line Tools" -Command "clang++"
    if (-not (Test-Path -LiteralPath $HostBuildScript -PathType Leaf)) {
        throw "Mac host build entry point is missing: $HostBuildScript"
    }
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    $candidate = Join-Path $StagingDir "core-tools-local-$PID"
    Remove-SetupPath -LiteralPath $candidate
    try {
        Write-Host "  Building the Mac viewer and CLI from pinned repository inputs..." -ForegroundColor White
        & $HostBuildScript -Configuration Release -Toolchain Clang `
            -Version $CoreTools.localBuildVersion -PublishDirectory $candidate
        if ($LASTEXITCODE -ne 0) {
            throw "Mac host build failed with exit code $LASTEXITCODE"
        }
        Test-LocalMacCoreToolsDirectory -Directory $candidate
        New-Item -ItemType Directory -Path (Split-Path -Parent $HostDir) -Force | Out-Null
        Switch-SetupDirectory -Candidate $candidate -Destination $HostDir `
            -PreserveDirectories @("packages")
    } finally {
        Remove-SetupPath -LiteralPath $candidate
    }
    Write-Host "  [OK] Built and installed local Apple Silicon core tools" -ForegroundColor Green
}

function Install-CoreTools {
    if (-not $CoreToolsAvailable) {
        if ($RunningOnMac) {
            Install-LocalMacCoreTools
            return
        }
        $reason = if (($null -ne $CoreTools) -and $CoreTools.reason) {
            $CoreTools.reason
        } else {
            "No immutable release is pinned for this platform."
        }
        throw "$reason Use -SkipCoreTools until the release pin is finalized."
    }
    if ((-not $Force) -and (Test-Path -LiteralPath $HostDir -PathType Container)) {
        try {
            Test-CoreToolsDirectory -Directory $HostDir -AllowedDirectories @("packages")
            Write-Host "  [SKIP] Verified core tools $($CoreTools.releaseVersion): $HostDir" -ForegroundColor DarkGray
            return
        } catch {
            Write-Warning "Existing host runtime is not the pinned release: $_"
        }
    }

    $archive = Get-VerifiedArchive -DisplayName "NXP Cup core tools $($CoreTools.releaseVersion)" `
        -Url $CoreTools.url -ArchiveName $CoreTools.assetName `
        -ExpectedSha256 $CoreTools.sha256 -SuppliedArchive $CoreToolsArchive
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    $candidate = Join-Path $StagingDir "core-tools-$PID"
    Remove-SetupPath -LiteralPath $candidate
    try {
        Write-Host "  Extracting and validating the host runtime..." -ForegroundColor White
        Expand-ZipStreaming -ZipPath $archive -Destination $candidate
        Test-CoreToolsDirectory -Directory $candidate
        New-Item -ItemType Directory -Path (Split-Path -Parent $HostDir) -Force | Out-Null
        Switch-SetupDirectory -Candidate $candidate -Destination $HostDir `
            -PreserveDirectories @("packages")
    } finally {
        Remove-SetupPath -LiteralPath $candidate
    }
    Write-Host "  [OK] Installed core tools $($CoreTools.releaseVersion)" -ForegroundColor Green
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "The pinned NXP Cup tools require a 64-bit operating system."
}
if ($RunningOnMac) {
    $machineArchitecture = (& /usr/bin/uname -m 2>&1 | Out-String).Trim()
    if (($LASTEXITCODE -ne 0) -or ($machineArchitecture -ne "arm64")) {
        throw "The first NXP Cup Mac setup supports Apple Silicon arm64 only."
    }
}

$platformDisplayName = if ($RunningOnMac) { "Apple Silicon macOS" } else { "Windows x64" }
Write-Header -Text "NXP Cup $platformDisplayName Setup"
Write-Host "  Repository: $RepoRoot" -ForegroundColor DarkGray
Write-Host "  Pins:       $VersionsPath" -ForegroundColor DarkGray
Write-Host "  Cache:      $DownloadsDir" -ForegroundColor DarkGray

Write-Host ""
Write-Host "[1/4] Arm GNU Toolchain $($Arm.releaseVersion)" -ForegroundColor Yellow
if ($SkipArm) {
    Write-Host "  [SKIP] -SkipArm" -ForegroundColor DarkGray
} else {
    Install-ArmToolchain
}

Write-Host ""
Write-Host "[2/4] CMake" -ForegroundColor Yellow
if ($SkipCMake) {
    Write-Host "  [SKIP] -SkipCMake" -ForegroundColor DarkGray
} else {
    if ($RunningOnMac) {
        [void](Install-ViaHomebrew -DisplayName "CMake" -Formula "cmake" `
            -ProbeCommand "cmake" -Required)
    } else {
        [void](Install-ViaWinget -DisplayName "CMake" -WingetId "Kitware.CMake" `
            -ProbeCommand "cmake" -Required)
    }
    Assert-UsableCommand -DisplayName "CMake" -Command "cmake" `
        -MinimumVersion $Versions.requiredCommands.cmakeMinimumVersion
}

Write-Host ""
Write-Host "[3/4] Ninja" -ForegroundColor Yellow
if ($SkipNinja) {
    Write-Host "  [SKIP] -SkipNinja" -ForegroundColor DarkGray
} else {
    if ($RunningOnMac) {
        [void](Install-ViaHomebrew -DisplayName "Ninja" -Formula "ninja" `
            -ProbeCommand "ninja" -Required)
    } else {
        [void](Install-ViaWinget -DisplayName "Ninja" -WingetId "Ninja-build.Ninja" `
            -ProbeCommand "ninja" -Required)
    }
    Assert-UsableCommand -DisplayName "Ninja" -Command "ninja" `
        -MinimumVersion $Versions.requiredCommands.ninjaMinimumVersion
}

Write-Host ""
$coreToolsLabel = if ($CoreToolsAvailable) {
    "Pinned $platformDisplayName core tools $($CoreTools.releaseVersion)"
} elseif ($RunningOnMac) {
    "$platformDisplayName core tools (local source build)"
} else {
    "$platformDisplayName core tools (release pin pending)"
}
Write-Host "[4/4] $coreToolsLabel" -ForegroundColor Yellow
if ($SkipCoreTools) {
    Write-Host "  [SKIP] -SkipCoreTools" -ForegroundColor DarkGray
} else {
    Install-CoreTools
}

if ($IncludeMaintainerTools) {
    Write-Host ""
    if ($RunningOnMac) {
        Write-Host "[Maintainer] uv and AppleClang" -ForegroundColor Yellow
        [void](Install-ViaHomebrew -DisplayName "uv" -Formula "uv" -ProbeCommand "uv")
        Assert-UsableCommand -DisplayName "Xcode Command Line Tools" -Command "clang++"
    } else {
        Write-Host "[Maintainer] uv and LLVM-MinGW" -ForegroundColor Yellow
        [void](Install-ViaWinget -DisplayName "uv" -WingetId "astral-sh.uv" -ProbeCommand "uv")
        [void](Install-ViaWinget -DisplayName "LLVM-MinGW" `
            -WingetId "MartinStorsjo.LLVM-MinGW.UCRT" -ProbeCommand "clang++")
    }
}

Write-Header -Text "Setup Complete"
if (-not $SkipArm) {
    Write-Host "  Arm toolchain: $ArmDir" -ForegroundColor Green
}
if (-not $SkipCoreTools) {
    Write-Host "  Host runtime:  $HostDir" -ForegroundColor Green
}
Write-Host "  No persistent environment variables were changed." -ForegroundColor White
Write-Host ""
Write-Host "  Next:" -ForegroundColor White
if ($RunningOnMac) {
    Write-Host "    pwsh -File src/embedded/build.ps1" -ForegroundColor Green
    Write-Host "    pwsh -File src/embedded/flash.ps1" -ForegroundColor Green
    Write-Host "    open 'out/artifacts/host/NXP Cup Viewer.app'" -ForegroundColor Green
} else {
    Write-Host "    .\src\embedded\build.ps1" -ForegroundColor Green
    Write-Host "    .\src\embedded\flash.ps1" -ForegroundColor Green
    Write-Host "    .\out\artifacts\host\nxpc_viewer.exe" -ForegroundColor Green
}
Write-Host ""
