param(
    [switch]$Check
)

$ErrorActionPreference = "Stop"
$componentRoot = $PSScriptRoot
$repositoryRoot = (Resolve-Path (Join-Path $componentRoot "..\..")).Path
$templatePath = Join-Path $componentRoot "dashboard\dashboard.html"
$cssPath = Join-Path $componentRoot "dashboard\dashboard.css"
$presentationPath = Join-Path $componentRoot "dashboard\dashboard.js"
$newline = [Environment]::NewLine

$targets = @(
    @{
        Name = "WebSerial"
        Transport = "webserial"
        Adapter = Join-Path $repositoryRoot "src\host\web\webserial_adapter.js"
        Output = Join-Path $repositoryRoot "src\host\nxpc_usb_debug_viewer.html"
    },
    @{
        Name = "Android relay"
        Transport = "relay"
        Adapter = Join-Path $repositoryRoot "src\android\web\relay_adapter.js"
        Output = Join-Path $repositoryRoot "src\android\nxp_cup_bridge\app\src\main\res\raw\relay_viewer.html"
    }
)

$template = Get-Content -LiteralPath $templatePath -Raw
$css = Get-Content -LiteralPath $cssPath -Raw
$presentation = Get-Content -LiteralPath $presentationPath -Raw
$encoding = [System.Text.UTF8Encoding]::new($false)
$failed = $false

foreach ($target in $targets) {
    $adapter = Get-Content -LiteralPath $target.Adapter -Raw
    $html = $template.Replace("{{TRANSPORT}}", $target.Transport)
    $html = $html.Replace("<!-- NXPC_DASHBOARD_STYLE -->", "<style>$newline$css$newline</style>")
    $html = $html.Replace("<!-- NXPC_DASHBOARD_SCRIPT -->", "<script>$newline$presentation$newline</script>")
    $html = $html.Replace("<!-- NXPC_ADAPTER_SCRIPT -->", "<script>$newline$adapter$newline</script>")

    if ($html -match '(?i)<(?:script|link|img|source)[^>]+(?:src|href)\s*=\s*["''](?:https?:)?//' -or
        $html -match '(?i)@import\s+(?:url\()?\s*["'']?(?:https?:)?//' -or
        $html -match '(?i)url\(\s*["'']?(?:https?:)?//' -or
        $html -match 'NXPC_(?:DASHBOARD|ADAPTER)' -or $html -match '\{\{TRANSPORT\}\}') {
        throw "$($target.Name) generation failed: an external runtime asset or build token remains."
    }

    $bytes = $encoding.GetBytes($html)
    if ($Check) {
        $equal = $false
        if (Test-Path -LiteralPath $target.Output) {
            $existing = [System.IO.File]::ReadAllBytes($target.Output)
            if ($existing.Length -eq $bytes.Length) {
                $equal = $true
                for ($index = 0; $index -lt $bytes.Length; $index++) {
                    if ($existing[$index] -ne $bytes[$index]) { $equal = $false; break }
                }
            }
        }
        if (-not $equal) {
            Write-Error "$($target.Name) generated page is stale: $($target.Output)" -ErrorAction Continue
            $failed = $true
        } else {
            Write-Host "$($target.Name) generated page is current: $($target.Output)"
        }
    } else {
        [System.IO.File]::WriteAllBytes($target.Output, $bytes)
        Write-Host "Built $($target.Name) page: $($target.Output)"
    }
}

if ($failed) { exit 1 }
