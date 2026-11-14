[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SignedDir,
    [Parameter(Mandatory=$true)][string]$UnsignedDir,
    [Parameter(Mandatory=$true)][string]$SourceSha,
    [Parameter(Mandatory=$true)][string]$RunId
)
$ErrorActionPreference = 'Stop'
$manifest = Get-Content (Join-Path $SignedDir 'signing-manifest.json') -Raw | ConvertFrom-Json
$config = Get-Content (Join-Path $PSScriptRoot 'windows-signer.json') -Raw | ConvertFrom-Json
$version = (Get-Content (Join-Path $PSScriptRoot '../VERSION') -Raw).Trim()
if ($manifest.repository -cne 'WOOWTECH/Woow_native_os_pi_agent' -or $manifest.source_sha -cne $SourceSha -or
    $manifest.version -cne $version -or $manifest.run_id -cne $RunId -or $manifest.signer_sha -cne $config.sha) {
    throw 'Signed artifact does not belong to this source commit, version and signer run'
}
$expected = @('install-wsl.ps1', 'Install-Pi-Agent.exe', 'Install-Pi-Agent.cmd', "pi-agent-installer-$version.tar.gz", "pi-agent-installer-$version.tar.gz.sha256")
$actual = @(Get-ChildItem $SignedDir -Force | Where-Object Name -ne 'signing-manifest.json' | ForEach-Object Name)
if (Compare-Object $expected $actual) { throw 'Unexpected signed artifact file list' }
if (Compare-Object $expected @($manifest.files.PSObject.Properties.Name)) { throw 'Unexpected signing manifest file list' }
foreach ($name in $expected) {
    $file = Join-Path $SignedDir $name
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $manifest.files.$name) { throw "Signed artifact hash mismatch: $name" }
    if ($name -notin @('install-wsl.ps1', 'Install-Pi-Agent.exe')) {
        if ($hash -ne (Get-FileHash -LiteralPath (Join-Path $UnsignedDir $name) -Algorithm SHA256).Hash) { throw "Bundle differs from this checkout: $name" }
    }
}
foreach ($name in 'install-wsl.ps1', 'Install-Pi-Agent.exe') {
    $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $SignedDir $name)
    if ($sig.Status -ne 'Valid' -or -not $sig.TimeStamperCertificate -or
        $sig.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne 'WOOW TECH CO., LTD.') {
        throw "Invalid signature, timestamp or publisher: $name"
    }
    Write-Host "Verified $name : $($sig.SignerCertificate.Subject)"
}
# Authenticode may only append its comment block to the independently rebuilt script.
$original = [IO.File]::ReadAllText((Join-Path $UnsignedDir 'install-wsl.ps1'))
$signed = [IO.File]::ReadAllText((Join-Path $SignedDir 'install-wsl.ps1'))
if (-not $signed.StartsWith($original, [StringComparison]::Ordinal)) { throw 'Signed script body differs from this checkout' }
$suffix = $signed.Substring($original.Length)
if ($suffix -notmatch '\A\s*# SIG # Begin signature block\r?\n(?:# [A-Za-z0-9+/=]+\r?\n)+# SIG # End signature block\s*\z') {
    throw 'Unexpected content appended to signed script'
}
Write-Host 'Verified source commit, version, signer run and all artifact bytes'
