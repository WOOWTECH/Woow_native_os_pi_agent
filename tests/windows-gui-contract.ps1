# Platform-neutral source tests: real installer helpers, mocked WSL/system side effects.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('pa-gui-contract-' + [guid]::NewGuid().ToString('N'))
$oldTest = $env:PI_AGENT_WSL_TEST
$oldGui = $env:PI_AGENT_LAUNCHER_GUI
$script:count = 0
function Assert-Contract($condition, $message) {
    if (-not $condition) { throw $message }
    [Console]::WriteLine('PASS: ' + $message)
    $script:count++
}
try {
    New-Item -ItemType Directory $temp | Out-Null
    $env:PI_AGENT_WSL_TEST = '1'
    $env:PI_AGENT_LAUNCHER_GUI = '1'
    $source = Join-Path $temp 'installer.ps1'
    [IO.File]::WriteAllText($source, [IO.File]::ReadAllText("$root/windows/install-wsl.ps1"), (New-Object Text.UTF8Encoding($true)))
    . $source
    $script:events = New-Object 'System.Collections.Generic.List[string]'
    function Write-Host { param($Object, $ForegroundColor); $script:events.Add([string]$Object) }
    $bundle = Join-Path $temp 'candidate.tar.gz'
    [IO.File]::WriteAllText($bundle, 'candidate bytes')
    Set-PaStamp @{ Version='candidate'; BundleUrl='https://example.invalid/bundle'; BundleSha256=(Get-FileHash $bundle).Hash; ScriptUrl='https://example.invalid/script'; PiWebUrlX64='x'; PiWebUrlArm64='a' }
    Assert-Contract ((Resolve-PaBundle -Opts @{BundlePath=$bundle} -Paths @{}) -eq $bundle) 'local candidate matches signed bundle hash'
    [IO.File]::AppendAllText($bundle, 'changed')
    Assert-Contract ($null -eq (Resolve-PaBundle -Opts @{BundlePath=$bundle} -Paths @{})) 'modified local bundle rejected'
    Write-PaMsg Step 'stage 3/6'
    Assert-Contract ($script:events.Contains('[PiAgent:step]stage 3/6')) 'GUI stage event emitted'
    $env:PI_AGENT_LAUNCHER_GUI = ''
    Write-PaMsg Step 'stage 4/6'
    Assert-Contract (-not $script:events.Contains('[PiAgent:step]stage 4/6')) 'CLI emits no GUI stage event'
    $env:PI_AGENT_LAUNCHER_GUI = '1'
    function Set-PaRunOnce { throw 'GUI must not register a public URL continuation' }
    function Restart-PaComputer { throw 'GUI must not reboot' }
    Assert-Contract ((Invoke-PaStepReboot -Opts @{Yes=$true} -Paths @{}) -eq 20) 'GUI reboot returns 20 without restarting or registering RunOnce'
    function Get-PaPaths { @{} }
    function Initialize-PaLog { }
    function Test-PaPreflight { param($Opts); $Opts.Port = 43210; @{Ok=$true; Arch='x64'} }
    function Invoke-PaStepWsl { 0 }
    function Invoke-PaStepDistro { 0 }
    function Invoke-PaStepPackages { 0 }
    function Invoke-PaStepInstall { 0 }
    function Invoke-PaStepIntegration { 0 }
    function Invoke-PaStepVerify { $script:verifyCode }
    $script:verifyCode = 0
    $opts = @{DryRun=$false; Uninstall=$false; Resume=$false; Port=43211}
    $script:events.Clear()
    Assert-Contract ((Invoke-PaMainCore -Opts $opts) -eq 0) 'successful GUI install returns zero'
    Assert-Contract ($script:events.Contains('[PiAgent:ready]http://localhost:43210/')) 'endpoint uses final recorded port'
    $script:events.Clear(); $opts.DryRun=$true
    Assert-Contract ((Invoke-PaMainCore -Opts $opts) -eq 0) 'dry run succeeds'
    Assert-Contract (@($script:events | Where-Object { $_.StartsWith('[PiAgent:ready]') }).Count -eq 0) 'dry run emits no endpoint'
    $script:events.Clear(); $opts.DryRun=$false; $script:verifyCode=70
    Assert-Contract ((Invoke-PaMainCore -Opts $opts) -eq 70) 'verification failure exit code preserved'
    Assert-Contract (@($script:events | Where-Object { $_.StartsWith('[PiAgent:ready]') }).Count -eq 0) 'failed verification emits no endpoint'
    [Console]::WriteLine("$script:count GUI contract checks passed")
} finally {
    $env:PI_AGENT_WSL_TEST = $oldTest
    $env:PI_AGENT_LAUNCHER_GUI = $oldGui
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
