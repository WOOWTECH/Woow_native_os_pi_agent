[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
foreach ($name in 'JSIGN_JAR', 'ESIGNER_STOREPASS', 'ESIGNER_CREDENTIAL_ID', 'ESIGNER_TOTP_SECRET') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\r\n]') {
        throw "Set $name to a nonempty single-line value"
    }
}
if (-not $env:ESIGNER_STOREPASS.Contains('|')) { throw 'ESIGNER_STOREPASS must be username|password' }
$bytes = [Convert]::FromBase64String($env:ESIGNER_TOTP_SECRET)
if ($bytes.Length -eq 0) { throw 'Empty TOTP secret' }
[Array]::Clear($bytes, 0, $bytes.Length)
for ($attempt = 0; $attempt -lt 3; $attempt++) {
    & java -jar $env:JSIGN_JAR --storetype ESIGNER --storepass env:ESIGNER_STOREPASS `
        --alias $env:ESIGNER_CREDENTIAL_ID --keypass env:ESIGNER_TOTP_SECRET `
        --alg SHA-256 --tsaurl 'http://ts.ssl.com,http://timestamp.digicert.com' --tsmode RFC3161 `
        --name 'Pi Agent' --url 'https://github.com/WOOWTECH/Woow_native_os_pi_agent' $Path
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq 2) { throw 'eSigner signing failed' }
    Start-Sleep -Seconds (30 * ($attempt + 1))
}
$signature = Get-AuthenticodeSignature -LiteralPath $Path
if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate -or
    $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne 'WOOW TECH CO., LTD.') {
    throw 'Signature, timestamp or publisher verification failed'
}
Write-Host ('Verified signed file: ' + [IO.Path]::GetFileName($Path))
