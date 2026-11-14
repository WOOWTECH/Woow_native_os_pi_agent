# Runs only on an ephemeral Windows CI runner. No eSigner secrets or WSL changes.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dir = Join-Path $env:RUNNER_TEMP ('pa-sign-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
$certs = @()
function Assert-PaTest($Condition, $Message) { if (-not $Condition) { throw $Message }; Write-Host "PASS: $Message" }
function Sign-Fixture($Path, $Certificate) {
    $s = Set-AuthenticodeSignature -FilePath $Path -Certificate $Certificate -HashAlgorithm SHA256
    Assert-PaTest ($s.Status -eq 'Valid') 'fixture has a valid Windows signature'
}
try {
    foreach ($name in 'WOOW TECH CO., LTD.', 'Other Publisher') {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject ('CN="' + $name + '"') -CertStoreLocation Cert:\CurrentUser\My
        $certs += $cert
        $file = Join-Path $dir ($cert.Thumbprint + '.cer')
        Export-Certificate -Cert $cert -FilePath $file | Out-Null
        Import-Certificate -FilePath $file -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
        Import-Certificate -FilePath $file -CertStoreLocation Cert:\CurrentUser\TrustedPublisher | Out-Null
    }
    $fixture = Join-Path $dir 'install-wsl.ps1'
    $body = 'param([string]$Message); [IO.File]::WriteAllText($env:PA_TEST_MARKER, $Message); exit 17'
    [IO.File]::WriteAllText($fixture, $body, (New-Object Text.UTF8Encoding($true)))
    $exe = Join-Path $dir 'Install-Pi-Agent.exe'
    $rejected = $false
    try { & "$root/scripts/build-windows-launcher.ps1" -Installer $fixture -Output $exe } catch { $rejected = $true }
    Assert-PaTest $rejected 'unsigned installer cannot be embedded'
    Sign-Fixture $fixture $certs[1]
    $rejected = $false
    try { & "$root/scripts/build-windows-launcher.ps1" -Installer $fixture -Output $exe } catch { $rejected = $true }
    Assert-PaTest $rejected 'trusted but wrong publisher cannot be embedded'
    [IO.File]::WriteAllText($fixture, $body, (New-Object Text.UTF8Encoding($true)))
    Sign-Fixture $fixture $certs[0]
    & "$root/scripts/build-windows-launcher.ps1" -Installer $fixture -Output $exe
    $env:PA_TEST_MARKER = Join-Path $dir 'executed.txt'
    $message = "spaces O'Neil & `$() ; test"
    & $exe -Message $message
    Assert-PaTest ($LASTEXITCODE -eq 17) 'launcher preserves installer exit code'
    Assert-PaTest (([IO.File]::ReadAllText($env:PA_TEST_MARKER)) -ceq $message) 'launcher preserves argument values without interpreting them'

    # Test the generated download command and the reboot-resume stub with real signatures.
    $env:PI_AGENT_WSL_TEST = '1'
    $installer = Join-Path $dir 'source.ps1'
    [IO.File]::WriteAllText($installer, [IO.File]::ReadAllText("$root/windows/install-wsl.ps1"), (New-Object Text.UTF8Encoding($true)))
    . $installer
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction); Copy-Item -LiteralPath $script:DownloadedFixture -Destination $OutFile }
    function Read-Host { return '' }
    $script:DownloadedFixture = $fixture
    $safeBody = '$global:PaFixtureExecuted = $true'
    foreach ($kind in 'valid', 'unsigned', 'wrong-publisher', 'tampered') {
        [IO.File]::WriteAllText($fixture, $safeBody, (New-Object Text.UTF8Encoding($true)))
        if ($kind -ne 'unsigned') { Sign-Fixture $fixture $(if ($kind -eq 'wrong-publisher') { $certs[1] } else { $certs[0] }) }
        if ($kind -eq 'tampered') { [IO.File]::AppendAllText($fixture, "`r`n# modified") }
        foreach ($mode in 'command', 'resume') {
            $global:PaFixtureExecuted = $false
            $code = if ($mode -eq 'command') { Get-PaOneLiner -Url 'https://example.invalid/installer.ps1' } else { New-PaResumeStub -Splat @{} -Kind url -Source 'https://example.invalid/installer.ps1' }
            try { & ([ScriptBlock]::Create($code)) } catch { Write-Host "Rejected $kind ($mode)" }
            Assert-PaTest ($global:PaFixtureExecuted -eq ($kind -eq 'valid')) "$mode executes only a valid company-signed script ($kind)"
        }
    }
    # The published guide must use the same guard. This test does not access the network.
    $doc = [IO.File]::ReadAllText("$root/docs/WSL2.md")
    $match = [regex]::Match($doc, '(?s)<!-- signed-install-command -->\s*```powershell\s*(.*?)\s*```')
    Assert-PaTest $match.Success 'guide has a verified installation command'
    $global:PaFixtureExecuted = $false
    try { & ([ScriptBlock]::Create($match.Groups[1].Value)) } catch { }
    Assert-PaTest (-not $global:PaFixtureExecuted) 'guide rejects the tampered script'
} finally {
    foreach ($cert in $certs) {
        foreach ($store in 'My', 'Root', 'TrustedPublisher') {
            Remove-Item -LiteralPath ("Cert:\CurrentUser\$store\" + $cert.Thumbprint) -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:PI_AGENT_WSL_TEST, Env:PI_AGENT_WSL_NOEXIT, Env:PA_TEST_MARKER -ErrorAction SilentlyContinue
}
