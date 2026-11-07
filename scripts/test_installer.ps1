# Windows smoke test: clean install, launch, upgrade, uninstall, data preservation.
param([string]$Installer = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\AppVault-Setup.exe'))
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this test on Windows.' }
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{14AC75B1-A8C5-47B6-BB6D-62B6656402E4}_is1'
if (Test-Path $uninstallKey) { throw 'AppVault is already installed. Use a clean test account.' }

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$work = Join-Path $tempRoot ('AppVault install test-' + [guid]::NewGuid())
$installDir = Join-Path $work 'AppVault'
$dataDir = Join-Path $work 'User data'
$previousHome = $env:APPVAULT_HOME
$app = $null
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$sentinel = Join-Path $dataDir 'library-preserved.txt'
Set-Content -LiteralPath $sentinel -Value 'preserve me'

function Install-App([string]$logName) {
    $log = Join-Path $work $logName
    $result = Start-Process -FilePath $Installer -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
        "/DIR=`"$installDir`"", "/LOG=`"$log`""
    ) -Wait -PassThru
    if ($result.ExitCode -ne 0) { throw "Installer failed ($($result.ExitCode)). See $log" }
}

try {
    $env:APPVAULT_HOME = $dataDir
    Install-App 'install.log'
    foreach ($file in @('AppVault.exe', 'flutter_windows.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'data\app.so', 'tools\ipatool.exe', 'tools\rcodesign.exe', 'tools\vcruntime140.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installDir $file))) { throw "Not installed: $file" }
    }
    if (-not (Test-Path $uninstallKey)) { throw 'Missing Windows uninstall entry' }
    $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'AppVault.lnk'
    if (-not (Test-Path -LiteralPath $shortcut)) { throw 'Missing Start menu shortcut' }
    & (Join-Path $PSScriptRoot 'verify_tools.ps1') -ToolsDir (Join-Path $installDir 'tools')

    # Start outside the install directory, as Windows shortcuts and Explorer do.
    $app = Start-Process -FilePath (Join-Path $installDir 'AppVault.exe') -WorkingDirectory $work -PassThru
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $app.Refresh()
        if ($app.HasExited) { throw "AppVault exited during startup ($($app.ExitCode))" }
        if ($app.MainWindowHandle -ne 0) { break }
    }
    if ($app.MainWindowHandle -eq 0) { throw 'AppVault did not show a window' }
    $null = $app.CloseMainWindow()
    if (-not $app.WaitForExit(10000)) { Stop-Process -Id $app.Id -Force }
    $app = $null
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'Secrets\ipatool-keychain.dpapi'))) {
        throw 'Dart startup did not initialize DPAPI storage'
    }

    # A second installation must replace application files and remove stale assets.
    $stale = Join-Path $installDir 'data\flutter_assets\obsolete-test.txt'
    Set-Content -LiteralPath $stale -Value 'old asset'
    Install-App 'upgrade.log'
    if (Test-Path -LiteralPath $stale) { throw 'Upgrade left stale Flutter assets' }
    if (-not (Test-Path -LiteralPath $sentinel)) { throw 'Upgrade removed user data' }

    $uninstaller = Join-Path $installDir 'unins000.exe'
    $result = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$(Join-Path $work 'uninstall.log')`"") -Wait -PassThru
    if ($result.ExitCode -ne 0) { throw 'Uninstaller failed' }
    if (Test-Path -LiteralPath (Join-Path $installDir 'AppVault.exe')) { throw 'Uninstaller left AppVault.exe' }
    if (Test-Path $uninstallKey) { throw 'Uninstaller left its registry entry' }
    if (Test-Path -LiteralPath $shortcut) { throw 'Uninstaller left the Start menu shortcut' }
    if (-not (Test-Path -LiteralPath $sentinel)) { throw 'Uninstaller removed user data' }
    Write-Host 'OK: install, bundled tools, startup, upgrade, uninstall, user data preserved'
}
finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force }
    $env:APPVAULT_HOME = $previousHome
    # Keep logs on failure for diagnosis. The CI runner removes its temp directory.
    Write-Host "Installer test logs: $work"
}
