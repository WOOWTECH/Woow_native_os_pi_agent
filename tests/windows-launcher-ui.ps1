# No signing keys or WSL needed. Uses the same source and compiler references as production.
[CmdletBinding()]
param([string]$Installer = '', [string]$Output = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('pa-ui-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp | Out-Null
try {
    $source = Join-Path $temp 'Launcher.cs'
    [IO.File]::WriteAllText($source, [IO.File]::ReadAllText("$root/windows/Launcher.cs").Replace('@@PUBLISHER@@', 'WOOW TECH CO., LTD.'))
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if (-not (Test-Path $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe' }
    $target = if ($Output) { $Output } else { Join-Path $temp 'Launcher.Tests.exe' }
    $resource = @()
    if ($Installer) { $resource = @("/resource:$Installer,install-wsl.ps1") }
    & $compiler /nologo /target:exe /platform:anycpu /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /main:LauncherTests "/out:$target" @resource $source "$root/windows/tests/Launcher.Tests.cs"
    if ($LASTEXITCODE -ne 0) { throw 'Launcher tests compilation failed' }
    & $target
    if ($LASTEXITCODE -ne 0) { throw 'Launcher UI tests failed' }
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
