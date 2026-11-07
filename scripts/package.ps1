# Package a complete Windows release directory. Inno Setup 6.3+ is required.
param(
    [string]$ReleaseDir = '',
    [string]$IsccPath = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($env:OS -ne 'Windows_NT') { throw 'Windows is required to package AppVault.' }
if (-not $ReleaseDir) { $ReleaseDir = Join-Path $root 'build\windows\x64\runner\Release' }
$ReleaseDir = (Resolve-Path -LiteralPath $ReleaseDir).Path

# The installer version follows pubspec.yaml, including the Flutter build number.
$pubspec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$') {
    throw 'Expected version: major.minor.patch+build in pubspec.yaml'
}
$version = $Matches[1]
$buildNumber = if ($Matches[2]) { $Matches[2] } else { '0' }
$fileVersion = "$version.$buildNumber"

if (-not $IsccPath) {
    $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($compiler) { $IsccPath = $compiler.Source }
    else {
        $IsccPath = @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
}
if (-not $IsccPath -or -not (Test-Path -LiteralPath $IsccPath)) {
    throw 'Install Inno Setup 6.3+ (winget install JRSoftware.InnoSetup), or pass -IsccPath.'
}

# App-local VC++ runtime: also works for a per-user install without elevation.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Installer / vswhere.exe not found.' }
$installations = @(& $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if ($LASTEXITCODE -ne 0) { throw 'vswhere failed' }
$crt = $null
foreach ($installation in $installations) {
    $redist = Join-Path $installation 'VC\Redist\MSVC'
    if (-not (Test-Path -LiteralPath $redist)) { continue }
    $versions = Get-ChildItem -LiteralPath $redist -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending
    foreach ($v in $versions) {
        $crt = Get-ChildItem -Path (Join-Path $v.FullName 'x64\Microsoft.VC*.CRT') -Directory |
            Select-Object -First 1
        if ($crt) { break }
    }
    if ($crt) { break }
}
if (-not $crt) { throw 'Visual C++ x64 redistributable DLLs not found. Install the VS C++ desktop workload.' }
Copy-Item -Path (Join-Path $crt.FullName '*.dll') -Destination $ReleaseDir -Force
# rcodesign.exe is a separate process and imports VCRUNTIME140.dll. Its loader
# searches tools/, so DLLs beside AppVault.exe alone are not sufficient.
$toolsDir = Join-Path $ReleaseDir 'tools'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
Copy-Item -Path (Join-Path $crt.FullName '*.dll') -Destination $toolsDir -Force

$required = @(
    'AppVault.exe', 'flutter_windows.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
    'data\app.so', 'data\icudtl.dat', 'data\flutter_assets',
    'tools\ipatool.exe', 'tools\rcodesign.exe', 'tools\ideviceinstaller.exe',
    'tools\idevice_id.exe', 'tools\ideviceinfo.exe', 'tools\idevicedevmodectl.exe'
)
foreach ($file in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir $file))) { throw "Missing release file: $file" }
}
& (Join-Path $PSScriptRoot 'verify_tools.ps1') -ToolsDir $toolsDir
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $ReleaseDir -Force

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$installer = Join-Path $dist 'AppVault-Setup.exe'
# Remove old output so a failed compile can never publish a previous installer.
if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
& $IsccPath "/DAppVersion=$version" "/DAppFileVersion=$fileVersion" "/DSourceDir=$ReleaseDir" "/DOutputDir=$dist" (Join-Path $root 'windows\installer\AppVault.iss')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $installer)) { throw 'Inno Setup compilation failed' }

$zip = Join-Path $dist 'AppVault-windows.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $ReleaseDir '*') -DestinationPath $zip
$checksums = foreach ($file in @($installer, $zip)) {
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($file))"
}
$checksums | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ASCII
Write-Host "Ready: $installer"
Write-Host "Portable: $zip"
