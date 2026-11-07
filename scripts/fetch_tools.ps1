# Скачивает утилиты, с которыми работает AppVault, и проверяет их контрольные суммы.
#
#   powershell -ExecutionPolicy Bypass -File scripts\fetch_tools.ps1 [-Destination <папка>]
#
# По умолчанию кладёт их в %LOCALAPPDATA%\AppVault\tools — там AppVault ищет утилиты сам.
# Версии закреплены: чтобы обновить, поменяйте URL и SHA-256 ниже.
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'AppVault\tools'),
    [string]$CacheDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\tool-downloads')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$tools = @(
    @{
        Name   = 'ipatool 2.7.0'
        Url    = 'https://github.com/majd/ipatool/releases/download/v2.7.0/ipatool-2.7.0-windows-amd64.tar.gz'
        Sha256 = 'b729608716908be287c2e6972f9e8cd05f879810ae5d182fc856c9e57cca0dd5'
        # В архиве bin\ipatool-2.7.0-windows-amd64.exe — AppVault ищет ipatool.exe.
        Files  = @{ 'ipatool-*-windows-amd64.exe' = 'ipatool.exe' }
    },
    @{
        Name   = 'rcodesign 0.29.0 (apple-codesign)'
        Url    = 'https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.29.0/apple-codesign-0.29.0-x86_64-pc-windows-msvc.zip'
        Sha256 = '54bb500e2da7a8de02fcae0f331d1cac6e6d7173b4281042ff9c528ba3159aaa'
        Files  = @{ 'rcodesign.exe' = 'rcodesign.exe' }
    },
    @{
        # Сборка libimobiledevice для Windows (MinGW) со всеми утилитами, включая idevicedevmodectl.
        Name   = 'libimobiledevice (L1ghtmann, suite-exe-21d57a9)'
        Url    = 'https://github.com/L1ghtmann/libimobiledevice/releases/download/suite-exe-21d57a9/libimobile-suite-latest_x86_64-mingw64.tar.xz'
        Sha256 = '948d20c5f6460ab9d9ac6b5fdeba00ddde0c62f59882e1e1e577ed16b3ae8abe'
        Files  = @{ '*.exe' = $null; '*.dll' = $null }
    }
)

function Expand-Any([string]$archive, [string]$dir) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($archive.EndsWith('.zip')) {
        Expand-Archive -Path $archive -DestinationPath $dir -Force
        return
    }
    # tar.exe есть в Windows 10 1803+; .tar.xz умеет не всякая сборка — тогда пробуем 7-Zip.
    & tar -xf $archive -C $dir 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    $sevenZip = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sevenZip) { throw "Не удалось распаковать ${archive}: нужен tar с поддержкой xz или 7-Zip" }
    & $sevenZip e $archive "-o$dir" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip не распаковал $archive" }
    $inner = Get-ChildItem $dir -Filter *.tar | Select-Object -First 1
    if (-not $inner) { throw "В $archive не найден внутренний tar-архив" }
    & $sevenZip x $inner.FullName "-o$dir" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip не распаковал $($inner.FullName)" }
    Remove-Item $inner.FullName -Force
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ("AppVault-tools-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    foreach ($t in $tools) {
        Write-Host "→ $($t.Name)"
        $file = Join-Path $CacheDirectory ([IO.Path]::GetFileName(([uri]$t.Url).AbsolutePath))
        if ((Test-Path -LiteralPath $file) -and (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant() -ne $t.Sha256) {
            Remove-Item -LiteralPath $file -Force
        }
        if (-not (Test-Path -LiteralPath $file)) {
            $download = Join-Path $work 'download.tmp'
            Invoke-WebRequest -Uri $t.Url -OutFile $download -UseBasicParsing
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $download).Hash.ToLowerInvariant()
            if ($hash -ne $t.Sha256) { throw "Контрольная сумма не совпала для $($t.Name): $hash" }
            Move-Item -LiteralPath $download -Destination $file -Force
        }
        $unpacked = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($file) + '-x')
        Expand-Any $file $unpacked
        foreach ($pattern in $t.Files.Keys) {
            $found = Get-ChildItem -Path $unpacked -Recurse -File -Filter $pattern
            if (-not $found) { throw "В архиве $($t.Name) нет $pattern" }
            foreach ($f in $found) {
                $name = if ($t.Files[$pattern]) { $t.Files[$pattern] } else { $f.Name }
                Copy-Item $f.FullName (Join-Path $Destination $name) -Force
            }
        }
    }
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host "`nГотово: $Destination"
Get-ChildItem $Destination -Filter *.exe | Where-Object { $_.Name -match '^(ipatool|rcodesign|ideviceinstaller|idevice_id|ideviceinfo|idevicedevmodectl)\.exe$' } |
    ForEach-Object { Write-Host "  $($_.Name)" }

# Без службы Apple Mobile Device Windows не видит iPhone — ни по кабелю, ни по Wi‑Fi.
$service = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Apple Mobile Device*' -or $_.DisplayName -like 'Apple Mobile Device*' }
if (-not $service) {
    Write-Warning 'Не найдена служба Apple Mobile Device. Установите приложение «Устройства Apple» из Microsoft Store (или iTunes).'
}
