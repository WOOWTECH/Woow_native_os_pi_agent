[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Installer,
    [Parameter(Mandatory=$true)][string]$Output,
    [string]$Publisher = 'WOOW TECH CO., LTD.'
)
$ErrorActionPreference = 'Stop'
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$signature = Get-AuthenticodeSignature -LiteralPath $Installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.GetNameInfo(
    [Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne $Publisher) {
    throw 'Only a valid installer signed by the expected publisher can be embedded'
}
# The parameter is useful for disposable certificates in CI, never for downloaded user input.
if ($Publisher -match '["\\\r\n]') { throw 'Unsupported publisher name' }
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../windows/Launcher.cs')).Replace('@@PUBLISHER@@', $Publisher)
$temp = Join-Path ([IO.Path]::GetTempPath()) ('pa-launcher-' + [guid]::NewGuid().ToString('N') + '.cs')
try {
    [IO.File]::WriteAllText($temp, $source)
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if (-not (Test-Path $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe' }
    & $compiler /nologo /target:exe /platform:anycpu /optimize+ "/out:$Output" "/resource:$Installer,install-wsl.ps1" $temp
    if ($LASTEXITCODE -ne 0) { throw 'Compiling the Windows launcher failed' }
} finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
