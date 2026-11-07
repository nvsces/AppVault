# Read-only checks against the actual binaries included in the installer.
param([Parameter(Mandatory = $true)][string]$ToolsDir)
$ErrorActionPreference = 'Stop'
$ToolsDir = (Resolve-Path -LiteralPath $ToolsDir).Path
$checks = @(
    @{ Exe = 'ipatool.exe'; Args = @('--help'); Contains = @('list-purchases', 'list-versions', 'get-version-metadata', '--keychain-passphrase') },
    @{ Exe = 'rcodesign.exe'; Args = @('sign', '--help'); Contains = @('--p12-file', '--p12-password-file', '--entitlements-xml-file') },
    @{ Exe = 'rcodesign.exe'; Args = @('analyze-certificate', '--help'); Contains = @('--p12-file', '--p12-password-file') },
    @{ Exe = 'ideviceinstaller.exe'; Args = @('--help'); Contains = @('--xml', '--user', '--attribute', '--sinf', '--metadata', 'uninstall') },
    @{ Exe = 'idevice_id.exe'; Args = @('--help'); Contains = @('--network', '--list') },
    @{ Exe = 'ideviceinfo.exe'; Args = @('--help'); Contains = @('--xml', '--network') },
    @{ Exe = 'idevicedevmodectl.exe'; Args = @('--help'); Contains = @('list', 'reveal', '--network') }
)
foreach ($check in $checks) {
    $exe = Join-Path $ToolsDir $check.Exe
    $arguments = $check.Args
    $output = (& $exe @arguments 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "$($check.Exe) failed to start ($LASTEXITCODE): $output" }
    foreach ($option in $check.Contains) {
        if (-not $output.Contains($option)) { throw "$($check.Exe) does not support $option" }
    }
    Write-Host "OK: $($check.Exe) $arguments"
}
