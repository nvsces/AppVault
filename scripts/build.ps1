# Build on Windows: Flutter + bundled tools + portable ZIP + EXE installer.
# powershell -ExecutionPolicy Bypass -File scripts\build.ps1
param([string]$IsccPath = '')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($env:OS -ne 'Windows_NT') { throw 'Windows is required to build AppVault.' }
if (@($env:PROCESSOR_ARCHITECTURE, $env:PROCESSOR_ARCHITEW6432) -notcontains 'AMD64') {
    throw 'Build this x64 installer on an Intel/AMD x64 Windows machine.'
}

Push-Location $root
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }

    $release = Join-Path $root 'build\windows\x64\runner\Release'
    & (Join-Path $PSScriptRoot 'fetch_tools.ps1') -Destination (Join-Path $release 'tools')
    & (Join-Path $PSScriptRoot 'package.ps1') -ReleaseDir $release -IsccPath $IsccPath
}
finally { Pop-Location }
