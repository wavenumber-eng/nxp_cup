param(
    [ValidateSet("Rom", "JLink")]
    [string]$Backend = "",

    [switch]$NoReset,

    # Deprecated no-op. CMake is the default now; kept so existing commands and
    # notes do not break.
    [switch]$CMake,

    # Flash the MCUXpresso output directory instead. Only useful when comparing
    # the two build systems.
    [switch]$Mcux,

    [ValidateSet("Debug")]
    [string]$Configuration = "Debug",
    [string]$File,
    # Optional override. Otherwise resolve NXPC_JLINK_PATH, then the newest
    # SEGGER installation under Program Files. Do not use the Java SDK's
    # unrelated jlink.exe from PATH.
    [string]$JLinkPath = "",
    [string]$Device = "MCXN947_M33_0",
    [string]$Interface = "SWD",
    [int]$SpeedKHz = 4000,

    # J-Link probe serial. Leave empty to resolve automatically:
    # NXPC_JLINK_SERIAL, else auto-detect when exactly one probe is attached.
    # Not hardcoded - every kit has a different serial.
    # See tools\lib\jlink_common.ps1.
    [string]$UsbSerial = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runningOnMac = ($PSVersionTable.PSEdition -eq "Core") -and $IsMacOS
. (Join-Path $PSScriptRoot "tools\lib\nxpc_image_common.ps1")

$automaticBackend = [string]::IsNullOrWhiteSpace($Backend)

function Resolve-JLinkCommander {
    param(
        [string]$ConfiguredPath
    )

    $requestedPath = $ConfiguredPath
    if ([string]::IsNullOrWhiteSpace($requestedPath)) {
        $requestedPath = $env:NXPC_JLINK_PATH
    }

    if (-not [string]::IsNullOrWhiteSpace($requestedPath)) {
        if (-not (Test-Path -LiteralPath $requestedPath -PathType Leaf)) {
            throw "J-Link Commander not found at the configured path: $requestedPath"
        }
        return (Resolve-Path -LiteralPath $requestedPath).Path
    }

    if ($runningOnMac) {
        $seggerRoot = "/Applications/SEGGER"
        if (Test-Path -LiteralPath $seggerRoot -PathType Container) {
            $unversioned = Join-Path $seggerRoot "JLink/JLinkExe"
            if (Test-Path -LiteralPath $unversioned -PathType Leaf) {
                return (Resolve-Path -LiteralPath $unversioned).Path
            }

            $versioned = Get-ChildItem -LiteralPath $seggerRoot -Directory -Filter "JLink_V*" |
                Sort-Object -Property @{
                    Expression = {
                        if ($_.Name -match '^JLink_V(?<VersionDigits>[0-9]+)') {
                            [int64]$Matches.VersionDigits
                        } else {
                            0
                        }
                    }
                    Descending = $true
                } |
                ForEach-Object { Join-Path $_.FullName "JLinkExe" } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($versioned) {
                return (Resolve-Path -LiteralPath $versioned).Path
            }
        }

        $seggerOnPath = Get-Command JLinkExe -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($seggerOnPath) {
            return $seggerOnPath.Source
        }
    } else {
        $programFilesRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique

        foreach ($programFilesRoot in $programFilesRoots) {
            $seggerRoot = Join-Path $programFilesRoot "SEGGER"
            if (-not (Test-Path -LiteralPath $seggerRoot -PathType Container)) {
                continue
            }

            $unversioned = Join-Path $seggerRoot "JLink\JLink.exe"
            if (Test-Path -LiteralPath $unversioned -PathType Leaf) {
                return (Resolve-Path -LiteralPath $unversioned).Path
            }

            $versioned = Get-ChildItem -LiteralPath $seggerRoot -Directory -Filter "JLink_V*" |
                Sort-Object -Property @{
                    Expression = {
                        if ($_.Name -match '^JLink_V(?<VersionDigits>[0-9]+)') {
                            [int64]$Matches.VersionDigits
                        } else {
                            0
                        }
                    }
                    Descending = $true
                } |
                ForEach-Object { Join-Path $_.FullName "JLink.exe" } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1

            if ($versioned) {
                return (Resolve-Path -LiteralPath $versioned).Path
            }

            $rootCandidate = Join-Path $seggerRoot "JLink.exe"
            if (Test-Path -LiteralPath $rootCandidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $rootCandidate).Path
            }
        }

        $seggerOnPath = Get-Command JLink.exe -All -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -match '(?i)[\\/]SEGGER[\\/]' } |
            Select-Object -First 1
        if ($seggerOnPath) {
            return $seggerOnPath.Source
        }
    }

    throw @"
J-Link Commander was not found.

Install the SEGGER J-Link Software and Documentation Pack, pass
-JLinkPath <path-to-J-Link-Commander>, or set NXPC_JLINK_PATH.
"@
}

$axfFile = Resolve-NxpCupImage -RepoRoot $repoRoot -File $File `
                            -Mcux:$Mcux -Configuration $Configuration

if (($Backend -eq "Rom") -or $automaticBackend) {
    $binFile = if ([IO.Path]::GetExtension($axfFile) -ieq ".bin") {
        $axfFile
    } else {
        [IO.Path]::ChangeExtension($axfFile, ".bin")
    }

    if (-not (Test-Path -LiteralPath $binFile)) {
        $message = "ROM image not found: $binFile. Run .\src\embedded\build.ps1 to create it."
        if (-not $automaticBackend) {
            throw $message
        }
        Write-Warning "$message Falling back to J-Link Commander."
    }

    $hostToolName = if ($runningOnMac) { "nxpc_tool" } else { "nxpc_tool.exe" }
    $hostTool = Join-Path $repoRoot "out\artifacts\host\$hostToolName"
    if ((Test-Path -LiteralPath $binFile) -and -not (Test-Path -LiteralPath $hostTool)) {
        $message = "NXP Cup host tool not found. Run .\src\host\build.ps1 first."
        if (-not $automaticBackend) {
            throw $message
        }
        Write-Warning "$message Falling back to J-Link Commander."
    }

    if ((Test-Path -LiteralPath $binFile) -and (Test-Path -LiteralPath $hostTool)) {
        if ($automaticBackend) {
            Write-Host "Trying the preferred ROM-HID flash path..." -ForegroundColor Cyan
        }

        $romExitCode = 1
        try {
            & $hostTool program --image $binFile
            $romExitCode = $LASTEXITCODE
        } catch {
            if (-not $automaticBackend) {
                throw
            }
            Write-Warning "ROM-HID flash could not start: $($_.Exception.Message)"
        }

        if ($romExitCode -eq 0) {
            exit 0
        }
        if (-not $automaticBackend) {
            exit $romExitCode
        }
        Write-Warning "ROM-HID flash failed with exit code $romExitCode. Falling back to J-Link Commander."
    }

    $Backend = "JLink"
}

. (Join-Path $PSScriptRoot "tools\lib\jlink_common.ps1")
$JLinkPath = Resolve-JLinkCommander -ConfiguredPath $JLinkPath
$UsbSerial = Resolve-JLinkSerial -Requested $UsbSerial

$fileInfo = Get-Item -LiteralPath $axfFile

if ($automaticBackend) {
    Write-Host "Trying the J-Link Commander fallback..." -ForegroundColor Cyan
}

Write-Host ("=" * 50)
Write-Host " NXP Cup MCXN947 - Flash"
Write-Host ("=" * 50)
Write-Host "J-Link Commander: $JLinkPath"
Write-Host "Device: $Device"
Write-Host "J-Link S/N: $UsbSerial"
Write-Host "Interface: $Interface @ $SpeedKHz kHz"
Write-Host "File: $axfFile"
Write-Host "Size: $($fileInfo.Length) bytes"
Write-Host "Modified: $($fileInfo.LastWriteTime)"
Write-Host ""

$cmdFile = Join-Path ([IO.Path]::GetTempPath()) "jlink_flash_nxpc.jlink"
$postLoadCommands = if ($NoReset) {
    @()
} else {
    @("r", "g")
}

$commands = @(
    "device $Device",
    "si $Interface",
    "speed $SpeedKHz",
    "connect",
    "h",
    "loadfile `"$axfFile`""
) + $postLoadCommands + @("exit")

$commands | Set-Content -Path $cmdFile -Encoding ASCII

$jlinkArgs = @()
if (-not [string]::IsNullOrWhiteSpace($UsbSerial)) {
    $jlinkArgs += @("-SelectEmuBySN", $UsbSerial)
}
$jlinkArgs += @("-CommandFile", $cmdFile)

try {
    & $JLinkPath @jlinkArgs
    exit $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $cmdFile -Force -ErrorAction SilentlyContinue
}
