<#
.SYNOPSIS
  Builds the Flutter Windows release and packages it into Setup.exe via NSIS.

.PARAMETER SkipFlutterBuild
  Skip `flutter build windows --release` and package whatever is already in
  build\windows\x64\runner\Release\.

.EXAMPLE
  .\installer\build.ps1
.EXAMPLE
  .\installer\build.ps1 -SkipFlutterBuild
#>
param(
    [switch]$SkipFlutterBuild
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$installerDir = $PSScriptRoot

if (-not $SkipFlutterBuild) {
    Write-Host "==> flutter build windows --release" -ForegroundColor Cyan
    Push-Location $repoRoot
    try {
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

$releaseDir = Join-Path $repoRoot "build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $releaseDir "ringopus_remote_producer.exe"))) {
    throw "Release build not found at $releaseDir. Run 'flutter build windows --release' first (or drop -SkipFlutterBuild)."
}

$makensis = Get-Command makensis.exe -ErrorAction SilentlyContinue
if (-not $makensis) {
    $default = "C:\Program Files (x86)\NSIS\makensis.exe"
    if (Test-Path $default) {
        $makensis = Get-Item $default
    } else {
        throw "makensis.exe not found. Install NSIS (https://nsis.sourceforge.io/) or add it to PATH."
    }
}

$outputDir = Join-Path $installerDir "Output"
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

Write-Host "==> makensis installer.nsi" -ForegroundColor Cyan
& $makensis.Source (Join-Path $installerDir "installer.nsi")
if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }

$setupExe = Join-Path $outputDir "RingopusRemoteSetup.exe"
Write-Host "==> Built: $setupExe" -ForegroundColor Green
