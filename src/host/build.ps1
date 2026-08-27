param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$ImGuiDir = "",

    [ValidateSet("Clang", "MSVC")]
    [string]$Toolchain = "Clang",

    [ValidatePattern("^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")]
    [string]$Version = "0.0.0",

    [switch]$ToolOnly
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "../..")
$runtimeRoot = Join-Path $repoRoot "out/build/host/runtime"
$runningOnMac = ($PSVersionTable.PSEdition -eq "Core") -and $IsMacOS

$clang = Get-Command "clang++" -ErrorAction SilentlyContinue | Select-Object -First 1
$ninja = Get-Command "ninja" -ErrorAction SilentlyContinue | Select-Object -First 1
$msvcAvailable = $false
if (-not $runningOnMac) {
    $programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio/Installer/vswhere.exe"
        if (Test-Path -LiteralPath $vswhere) {
            $msvcPath = & $vswhere -latest -products * `
                -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                -property installationPath
            $msvcAvailable = -not [string]::IsNullOrWhiteSpace($msvcPath)
        }
    }
}

if ($Toolchain -eq "Clang") {
    if (-not $clang) {
        throw "clang++ was not found. Run .\setup.ps1 to install LLVM-MinGW."
    }
    if (-not $ninja) {
        throw "Ninja was not found. Run .\setup.ps1."
    }
    $buildName = if ($runningOnMac) { "cmake-clang-macos-arm64" } else { "cmake-clang" }
    $buildDir = Join-Path $repoRoot "out/build/host/$buildName"
    $configureArgs = @(
        "-S", $scriptDir,
        "-B", $buildDir,
        "-G", "Ninja Multi-Config",
        "-DCMAKE_CXX_COMPILER=$($clang.Source)",
        "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=$runtimeRoot"
    )
} else {
    if ($runningOnMac) {
        throw "MSVC is not available on macOS. Use the default Clang toolchain."
    }
    if (-not $msvcAvailable) {
        throw "Visual Studio C++ tools were not found. Use -Toolchain Clang after running .\setup.ps1, or install the C++ desktop workload."
    }
    $buildDir = Join-Path $repoRoot "out/build/host/cmake-msvc"
    $configureArgs = @(
        "-S", $scriptDir,
        "-B", $buildDir,
        "-G", "Visual Studio 17 2022",
        "-A", "x64",
        "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=$runtimeRoot"
    )
}
if ([string]::IsNullOrWhiteSpace($ImGuiDir)) {
    $ImGuiDir = Join-Path $scriptDir "vendor/imgui"
}
$resolvedImGui = Resolve-Path -LiteralPath $ImGuiDir
$configureArgs += "-DNXPC_HOST_IMGUI_DIR=$resolvedImGui"
$configureArgs += if ($ToolOnly) { "-DNXPC_HOST_BUILD_VIEWER=OFF" } else { "-DNXPC_HOST_BUILD_VIEWER=ON" }
$configureArgs += "-DNXPC_HOST_VERSION=$Version"

Write-Host "Configuring NXP Cup native host ($Toolchain)..."
& cmake @configureArgs
if ($LASTEXITCODE -ne 0) {
    throw "CMake configure failed with exit code $LASTEXITCODE"
}

$targets = @(if ($ToolOnly) { "nxpc_tool" } else { "nxpc_viewer"; "nxpc_tool" })
Write-Host "Building NXP Cup native host ($Configuration, $Toolchain)..."
& cmake --build $buildDir --config $Configuration --target @targets
if ($LASTEXITCODE -ne 0) {
    throw "CMake build failed with exit code $LASTEXITCODE"
}

$outputDir = Join-Path $runtimeRoot $Configuration
$executableSuffix = if ($runningOnMac) { "" } else { ".exe" }
$viewerName = if ($runningOnMac) { "NXP Cup Viewer.app" } else { "nxpc_viewer.exe" }
if (-not $ToolOnly) {
    Write-Host "Viewer: $(Join-Path $outputDir $viewerName)"
}
Write-Host "CLI:    $(Join-Path $outputDir "nxpc_tool$executableSuffix")"

$publishDir = Join-Path $repoRoot "out/artifacts/host"
$programmerName = if ($runningOnMac) { "rblhost" } else { "rblhost.exe" }
$runtimeFiles = if ($ToolOnly) {
    @("nxpc_tool$executableSuffix", $programmerName, "rblhost-LICENSE.txt")
} else {
    $files = @($viewerName, "nxpc_tool$executableSuffix", $programmerName,
        "rblhost-LICENSE.txt")
    if (-not $runningOnMac) {
        $files += "SDL2.dll"
    }
    $files
}
New-Item -ItemType Directory -Force -Path $publishDir | Out-Null
foreach ($name in $runtimeFiles) {
    $source = Join-Path $outputDir $name
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Native host build completed but a runtime file is missing: $source"
    }
    $destination = Join-Path $publishDir $name
    if (Test-Path -LiteralPath $source -PathType Container) {
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Recurse -Force
        }
        Copy-Item -LiteralPath $source -Destination $destination -Recurse
    } else {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}
Write-Host "Artifacts: $publishDir" -ForegroundColor Green
