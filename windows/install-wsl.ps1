# install-wsl.ps1 - Pi Agent (WOOWTECH) on Windows 11, inside a dedicated WSL2 Linux.
#
# Typical use (PowerShell; administrator rights are only asked for when WSL itself is missing):
#   & ([ScriptBlock]::Create($text)) -Yes        # $text = this file, downloaded as UTF-8
#   .\install-wsl.ps1 -DryRun                    # only look, change nothing
#   .\install-wsl.ps1 -Uninstall                 # remove the Windows side, keep the Linux and its data
#
# Design: docs/WSL2-PLAN.md. Every comment marked UNVERIFIED(E<n>) is an assumption about real
# wsl.exe / Windows behaviour that experiment E<n> of that plan has to confirm on a real machine.
# Keep this file free of curly quotes and long dashes: Windows PowerShell reads them as quotes.
# The file is UTF-8 without BOM here; the release adds the BOM (Windows PowerShell 5.1 needs it
# to read the Chinese messages from a file on disk).
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$Uninstall,
    [switch]$PurgeData,
    [switch]$NoWindowsInterop,
    [switch]$NoAutostart,
    [switch]$SkipSmoke,
    [string]$DistroName = 'PiAgent',
    [string]$LinuxUser = 'piagent',
    [int]$Port = 30141,
    [string]$RootfsPath = '',
    [string]$BundlePath = '',
    [string]$PiWebArtifact = '',
    [string]$InstallDir = ''
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# The release workflow replaces these literal placeholders. An unstamped copy is a dev copy.
$script:Stamp = @{
    Version       = '@@VERSION@@'
    BundleUrl     = '@@BUNDLE_URL@@'
    BundleSha256  = '@@BUNDLE_SHA256@@'
    ScriptUrl     = '@@SCRIPT_URL@@'
    PiWebUrlX64   = '@@PIWEB_URL_X64@@'
    PiWebUrlArm64 = '@@PIWEB_URL_ARM64@@'
}

# Ubuntu 24.04.5 WSL images. The sha256 values were checked against both Microsoft's
# DistributionInfo.json and Canonical's SHA256SUMS on 2026-11-03.
$script:PaRootfs = @{
    x64   = @{
        Url      = 'https://releases.ubuntu.com/24.04.5/ubuntu-24.04.5-wsl-amd64.wsl'
        Sha256   = 'bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e'
        FileName = 'ubuntu-24.04.5-wsl-amd64.wsl'
        SizeMiB  = 371
    }
    arm64 = @{
        Url      = 'https://cdimages.ubuntu.com/releases/24.04.5/release/ubuntu-24.04.5-wsl-arm64.wsl'
        Sha256   = '74478b5024d9047397ba79d17c27f73caf85ada4988f88cffc2892d65e6a806b'
        FileName = 'ubuntu-24.04.5-wsl-arm64.wsl'
        SizeMiB  = 370
    }
}

$script:PaMinWslVersion = '2.4.4'
# 19041 (Windows 10 2004) is what WSL2 itself needs. Windows 11 22H2 is what this installer was written for; older
# builds go on with a warning (first run on a real Windows 10 22H2 PC: 2026-11-04).
$script:PaMinBuild = 19041
$script:PaRecommendedBuild = 22621
$script:PaPaseoPort = 6769
$script:PaTaskName = 'PiAgentWsl'
$script:PaRunOnceName = 'PiAgentWslResume'
$script:PaStagingDir = '/opt/pi-agent-installer'
$script:PaRootSetup = '/opt/pi-agent-installer/scripts/wsl-root-setup.sh'
# Runs elevated and nowhere else. Windows 10's built-in wsl.exe does not know --no-distribution (it prints its usage
# and fails, harmlessly), so the exit code is the one of the update. On a real Windows 10 22H2 PC plain --update went
# through the Store and ended in "catastrophic failure" after two minutes; --web-download then worked.
$script:PaElevatedWslCommand = '& { wsl.exe --install --no-distribution; wsl.exe --update; if ($LASTEXITCODE -ne 0) { wsl.exe --update --web-download }; exit $LASTEXITCODE }'
$script:PaSelfPath = ''
$script:PaMessages = New-Object System.Collections.ArrayList
$script:PaLastStream = New-Object System.Collections.ArrayList
$script:PaLogFile = ''
$script:PaDry = $false

# ---------------------------------------------------------------------------
# Messages and log
# ---------------------------------------------------------------------------

function Reset-PaMessages {
    $script:PaMessages = New-Object System.Collections.ArrayList
}

function Get-PaMessages {
    return @($script:PaMessages)
}

function Write-PaLogLine {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($script:PaLogFile)) { return }
    if ($script:PaDry) { return }
    try {
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Text
        Add-Content -LiteralPath $script:PaLogFile -Value $line -Encoding UTF8
    } catch {
        # A log that cannot be written must never stop the install.
        $null = $_
    }
}

function Write-PaMsg {
    param(
        [Parameter(Position = 0)][ValidateSet('Step', 'Info', 'Ok', 'Warn', 'Error', 'Dry')][string]$Level,
        [Parameter(Position = 1)][string]$Text
    )
    [void]$script:PaMessages.Add('[' + $Level + '] ' + $Text)
    $color = 'Gray'
    $prefix = ''
    switch ($Level) {
        'Step'  { $color = 'Cyan'; $prefix = '==> ' }
        'Ok'    { $color = 'Green'; $prefix = 'OK ' }
        'Warn'  { $color = 'Yellow'; $prefix = '! ' }
        'Error' { $color = 'Red'; $prefix = 'X ' }
        'Dry'   { $color = 'DarkYellow'; $prefix = '[dry-run] ' }
    }
    Write-Host ($prefix + $Text) -ForegroundColor $color
    Write-PaLogLine -Text ($Level + ': ' + $Text)
}

# ---------------------------------------------------------------------------
# Pure helpers (no side effects; the unit tests lean on these)
# ---------------------------------------------------------------------------

# The command the docs give for installing, for use in messages. It decodes the bytes as UTF-8 itself
# because Windows PowerShell 5.1 guesses the encoding from headers that a release asset does not have.
function Get-PaOneLiner {
    param([string]$Url, [string]$Extra = '')
    $line = '& ([ScriptBlock]::Create(([Text.Encoding]::UTF8.GetString((Invoke-WebRequest -UseBasicParsing ''' + $Url + ''').RawContentStream.ToArray())).TrimStart([char]0xFEFF)))'
    if (-not [string]::IsNullOrEmpty($Extra)) { $line = $line + ' ' + $Extra }
    return $line
}

function Get-PaStamp {
    return $script:Stamp
}

function Set-PaStamp {
    param([hashtable]$Stamp)
    $script:Stamp = $Stamp
}

# True when every stamped value was replaced by the release workflow. The marker is built from
# a character code so that this file holds the placeholder text only inside the Stamp table.
function Test-Stamped {
    $at = [string][char]64
    $marker = $at + $at
    foreach ($v in (Get-PaStamp).Values) {
        if (([string]$v).StartsWith($marker)) { return $false }
    }
    return $true
}

function Test-PaDistroName {
    param([string]$Name)
    return ($Name -match '^[A-Za-z][A-Za-z0-9._-]{0,30}$')
}

function Test-PaLinuxUser {
    param([string]$Name)
    # -match is case-insensitive in PowerShell; scripts/wsl-root-setup.sh is not, and it refuses root.
    # Better to refuse here than after the 371 MB download and the import.
    if ($Name -ceq 'root') { return $false }
    return ($Name -cmatch '^[a-z_][a-z0-9_-]{0,30}$')
}

# Windows path -> path inside WSL (/mnt/<drive>/...). UNC paths are not supported.
function ConvertTo-WslPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $p = $Path.Trim()
    if ($p.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('UNC paths are not supported: ' + $Path)
    }
    if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    if ($p.StartsWith('\\') -or $p.StartsWith('//')) {
        throw ('UNC paths are not supported: ' + $Path)
    }
    if ($p -notmatch '^[A-Za-z]:[\\/]') {
        throw ('Need an absolute path that starts with a drive letter: ' + $Path)
    }
    $drive = $p.Substring(0, 1).ToLowerInvariant()
    $rest = $p.Substring(2).Replace('\', '/')
    $rest = [regex]::Replace($rest, '/{2,}', '/')
    if ($rest.Length -gt 1) { $rest = $rest.TrimEnd('/') }
    if ($rest -eq '/') { $rest = '' }
    return ('/mnt/' + $drive + $rest)
}

# -InstallDir says where the PiAgent folder goes. The uninstaller deletes folders under it (distro,
# cache, bin), so it only ever works inside a folder named PiAgent that is its own: D:\ becomes
# D:\PiAgent, D:\Data becomes D:\Data\PiAgent, and D:\Apps\PiAgent is used as it is. Otherwise
# -InstallDir D:\ would make the uninstaller delete the user's own D:\bin and D:\cache.
function Get-PaInstallDirUnder {
    param([string]$Path)
    $full = Resolve-PaFullPath -Path $Path
    $trimmed = $full.TrimEnd('\')
    if ([System.IO.Path]::GetFileName($trimmed) -ieq 'PiAgent') { return $trimmed }
    return [System.IO.Path]::Combine($full, 'PiAgent')
}

function Resolve-PaFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        $p = Join-Path (Get-Location).ProviderPath $p
    }
    return [System.IO.Path]::GetFullPath($p)
}

# First x.y.z(.w) token of "wsl --version" output. The labels are localized, the digits are not.
function Get-WslVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    foreach ($line in ($Text -split "`n")) {
        $m = [regex]::Match($line, '\d+\.\d+\.\d+(\.\d+)?')
        if ($m.Success) { return $m.Value }
    }
    return $null
}

# -1, 0 or 1. Missing parts count as 0, so 2.4.4 equals 2.4.4.0 (System.Version would not).
function Compare-PaVersion {
    param([string]$Left, [string]$Right)
    $a = @(($Left -split '\.') | ForEach-Object { [int]$_ })
    $b = @(($Right -split '\.') | ForEach-Object { [int]$_ })
    for ($i = 0; $i -lt 4; $i++) {
        $x = 0
        $y = 0
        if ($i -lt $a.Count) { $x = $a[$i] }
        if ($i -lt $b.Count) { $y = $b[$i] }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

# wsl.exe output may be UTF-16 (NUL bytes), carry a BOM and CRLF, and stderr arrives as ErrorRecords.
function ConvertTo-PaCleanText {
    param($Lines)
    $out = New-Object System.Collections.ArrayList
    foreach ($l in @($Lines)) {
        if ($null -eq $l) { continue }
        $s = ''
        if ($l -is [System.Management.Automation.ErrorRecord]) {
            $s = [string]$l.Exception.Message
        } else {
            $s = [string]$l
        }
        $s = [regex]::Replace($s, '[\u0000\uFEFF\r]', '')
        [void]$out.Add($s)
    }
    return (($out.ToArray()) -join "`n").Trim()
}

function Get-PaLastLine {
    param([string]$Text)
    $last = ''
    if ([string]::IsNullOrEmpty($Text)) { return $last }
    foreach ($line in ($Text -split "`n")) {
        if ($line.Trim().Length -gt 0) { $last = $line.Trim() }
    }
    return $last
}

# "configured uid=1001" / "linger uid=1001" -> 1001, anything else -> $null
function Get-PaUidFromOutput {
    param([string]$Text, [string]$Prefix)
    $last = Get-PaLastLine -Text $Text
    $m = [regex]::Match($last, '^' + [regex]::Escape($Prefix) + ' uid=(\d+)$')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

function Add-PaPathEntry {
    param([string]$Current, [Parameter(Mandatory = $true)][string]$Entry)
    $parts = @()
    if (-not [string]::IsNullOrEmpty($Current)) {
        $parts = @($Current.Split(';') | Where-Object { $_ -ne '' })
    }
    $want = $Entry.TrimEnd('\')
    foreach ($p in $parts) {
        if ($p.TrimEnd('\') -ieq $want) { return $Current }
    }
    $parts += $Entry
    return ($parts -join ';')
}

function Remove-PaPathEntry {
    param([string]$Current, [Parameter(Mandatory = $true)][string]$Entry)
    if ([string]::IsNullOrEmpty($Current)) { return $Current }
    $want = $Entry.TrimEnd('\')
    $keep = New-Object System.Collections.ArrayList
    $removed = $false
    foreach ($p in $Current.Split(';')) {
        if ($p -ne '' -and $p.TrimEnd('\') -ieq $want) {
            $removed = $true
        } elseif ($p -ne '') {
            [void]$keep.Add($p)
        }
    }
    if (-not $removed) { return $Current }
    return (($keep.ToArray()) -join ';')
}

# UNVERIFIED(E12): the arm64 image and the linux-arm64 pi-web build have not run on a real Windows ARM64 PC.
function Get-PaRootfsSpec {
    param([string]$Arch)
    if ($Arch -eq 'arm64') { return $script:PaRootfs['arm64'] }
    return $script:PaRootfs['x64']
}

function ConvertTo-PaPsLiteral {
    param($Value)
    if ($Value -is [bool]) {
        if ($Value) { return '$true' }
        return '$false'
    }
    if ($Value -is [int]) { return [string]$Value }
    return ("'" + ([string]$Value).Replace("'", "''") + "'")
}

function Get-PaPaths {
    param([hashtable]$Opts)
    $root = $Opts.InstallDir
    return @{
        InstallDir = $root
        DistroDir  = [System.IO.Path]::Combine($root, 'distro')
        CacheDir   = [System.IO.Path]::Combine($root, 'cache')
        BinDir     = [System.IO.Path]::Combine($root, 'bin')
        Shim       = [System.IO.Path]::Combine($root, 'bin', 'pi-agent.cmd')
        Keepalive  = [System.IO.Path]::Combine($root, 'keepalive.ps1')
        ResumeStub = [System.IO.Path]::Combine($root, 'resume.ps1')
        Log        = [System.IO.Path]::Combine($root, 'install.log')
    }
}

function New-PaOptions {
    param([hashtable]$Bound)
    $o = @{
        Yes = $false; DryRun = $false; Resume = $false; Uninstall = $false; PurgeData = $false
        NoWindowsInterop = $false; NoAutostart = $false; SkipSmoke = $false
        DistroName = 'PiAgent'; LinuxUser = 'piagent'; Port = 30141
        RootfsPath = ''; BundlePath = ''; PiWebArtifact = ''; InstallDir = ''
    }
    if ($null -ne $Bound) {
        foreach ($k in @($Bound.Keys)) {
            if ($o.ContainsKey($k) -and $null -ne $Bound[$k]) { $o[$k] = $Bound[$k] }
        }
    }
    foreach ($k in 'Yes', 'DryRun', 'Resume', 'Uninstall', 'PurgeData', 'NoWindowsInterop', 'NoAutostart', 'SkipSmoke') {
        $o[$k] = [bool]$o[$k]
    }
    $o['Port'] = [int]$o['Port']
    $o['PortGiven'] = ($null -ne $Bound -and $Bound.ContainsKey('Port'))
    if ([string]::IsNullOrEmpty([string]$o['InstallDir'])) {
        $o['InstallDir'] = [System.IO.Path]::Combine((Get-PaLocalAppData), 'PiAgent')
    } else {
        $o['InstallDir'] = Get-PaInstallDirUnder -Path ([string]$o['InstallDir'])
    }
    # A resume after a reboot runs from another working directory: keep only absolute paths.
    foreach ($k in 'RootfsPath', 'BundlePath') {
        if (-not [string]::IsNullOrEmpty([string]$o[$k])) { $o[$k] = Resolve-PaFullPath -Path ([string]$o[$k]) }
    }
    $art = [string]$o['PiWebArtifact']
    if ($art.Length -gt 0 -and $art -notmatch '^https?://') {
        $o['PiWebArtifact'] = Resolve-PaFullPath -Path $art
    }
    return $o
}

# The pi-web build to hand to install.sh: a URL from the stamp, or the override, or '' (build from source).
function Get-PaPiWebArtifact {
    param([hashtable]$Opts, [string]$Arch)
    $art = [string]$Opts.PiWebArtifact
    if ($art.Length -gt 0) {
        if ($art -match '^https?://') { return $art }
        return (ConvertTo-WslPath -Path $art)
    }
    if (Test-Stamped) {
        $st = Get-PaStamp
        if ($Arch -eq 'arm64') { return [string]$st.PiWebUrlArm64 }
        return [string]$st.PiWebUrlX64
    }
    return ''
}

function Get-PaInstallEnv {
    param([int]$Uid, [int]$Port, [string]$Artifact)
    $e = @(
        ('XDG_RUNTIME_DIR=/run/user/' + $Uid),
        ('DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/' + $Uid + '/bus'),
        ('PI_WEB_PORT=' + $Port)
    )
    if (-not [string]::IsNullOrEmpty($Artifact)) { $e += ('PI_AGENT_PIWEB_ARTIFACT=' + $Artifact) }
    return $e
}

# wsl.exe arguments that run a command as the Linux user inside the user's copy of the installer.
# UNVERIFIED(E2): that --cd accepts an absolute Linux path and that the session needs no login for systemctl --user
# once XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are given.
function Get-PaUserExecArgs {
    param([string]$Distro, [string]$User, [int]$Uid, [int]$Port, [string]$Artifact, [string[]]$Command)
    $envArgs = Get-PaInstallEnv -Uid $Uid -Port $Port -Artifact $Artifact
    $head = @('-d', $Distro, '-u', $User, '--cd', ('/home/' + $User + '/pi-agent-installer'), '--exec', '/usr/bin/env')
    return ($head + $envArgs + $Command)
}

function Get-PaSmokeResult {
    param([string[]]$Lines)
    foreach ($l in @($Lines)) {
        $m = [regex]::Match([string]$l, 'RESULT:\s*(\d+)\s+passed,\s*(\d+)\s+failed')
        if ($m.Success) {
            return [pscustomobject]@{ Passed = [int]$m.Groups[1].Value; Failed = [int]$m.Groups[2].Value }
        }
    }
    return $null
}

function ConvertTo-PaFriendlyWslError {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    # UNVERIFIED(E14): the exact error text of a machine without usable virtualization.
    if ($Text -match 'HCS_E_HYPERV_NOT_INSTALLED|0x80370102|Virtual Machine Platform|not supported with your current machine configuration') {
        return '這台電腦目前不能啟動 WSL2。請依序檢查:(1) Windows 的「虛擬機器平台」沒開:用系統管理員身分開 PowerShell,執行 wsl --install --no-distribution,重新開機後再重跑安裝;(2) BIOS/UEFI 沒開虛擬化(Intel VT-x 或 AMD-V);(3) 這是虛擬機:虛擬機軟體要支援巢狀虛擬化(Parallels 在 Apple 晶片上不支援)。(virtualization is off or not available)'
    }
    if ($Text -match 'optional component is not enabled|WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED|0x8007019e') {
        return 'Windows 的 WSL 功能還沒啟用。請重新開機後再重跑安裝。(WSL optional component is not enabled)'
    }
    return $null
}

# ---------------------------------------------------------------------------
# Generated files
# ---------------------------------------------------------------------------

# Written to <InstallDir>\resume.ps1 and run once by HKCU RunOnce after the reboot.
# Kind 'url' re-fetches this script, 'file' (dev) reads the local copy.
function New-PaResumeStub {
    param([System.Collections.IDictionary]$Splat, [string]$Kind, [string]$Source)
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add('# Generated by install-wsl.ps1: continues the Pi Agent (WSL2) install after a reboot.')
    [void]$L.Add('$ErrorActionPreference = ''Stop''')
    [void]$L.Add('try {')
    [void]$L.Add('    $splat = @{}')
    foreach ($k in $Splat.Keys) {
        [void]$L.Add('    $splat[' + (ConvertTo-PaPsLiteral -Value $k) + '] = ' + (ConvertTo-PaPsLiteral -Value $Splat[$k]))
    }
    if ($Kind -eq 'url') {
        # UNVERIFIED(E1): GitHub serves release assets without a charset, so the bytes are decoded by hand.
        [void]$L.Add('    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12')
        # Windows removes a RunOnce entry BEFORE it runs, and at logon the network is often not up yet:
        # try for two minutes, and say what to type if it still fails.
        [void]$L.Add('    $text = $null')
        [void]$L.Add('    $lastError = ''''')
        [void]$L.Add('    for ($try = 1; $try -le 24; $try++) {')
        [void]$L.Add('        try {')
        [void]$L.Add('            $resp = Invoke-WebRequest -UseBasicParsing -Uri ' + (ConvertTo-PaPsLiteral -Value $Source))
        [void]$L.Add('            $text = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())')
        [void]$L.Add('            break')
        [void]$L.Add('        } catch {')
        [void]$L.Add('            $lastError = $_.Exception.Message')
        [void]$L.Add('            Start-Sleep -Seconds 5')
        [void]$L.Add('        }')
        [void]$L.Add('    }')
        [void]$L.Add('    if ($null -eq $text) {')
        [void]$L.Add('        throw (''could not download the installer for two minutes (check the network): '' + $lastError + '' ... run this by hand: '' + ' + (ConvertTo-PaPsLiteral -Value (Get-PaOneLiner -Url $Source)) + ')')
        [void]$L.Add('    }')
    } else {
        [void]$L.Add('    $text = [System.IO.File]::ReadAllText(' + (ConvertTo-PaPsLiteral -Value $Source) + ', [System.Text.Encoding]::UTF8)')
    }
    [void]$L.Add('    $text = $text.TrimStart([char]0xFEFF)')
    [void]$L.Add('    $sb = [ScriptBlock]::Create($text)')
    # The installer exits when it thinks it runs as a file, which would end this stub before it can show anything.
    [void]$L.Add('    $env:PI_AGENT_WSL_NOEXIT = ''1''')
    [void]$L.Add('    & $sb @splat')
    [void]$L.Add('} catch {')
    [void]$L.Add('    Write-Host (''Pi Agent install could not continue: '' + $_.Exception.Message) -ForegroundColor Red')
    [void]$L.Add('}')
    [void]$L.Add('Write-Host ''''')
    [void]$L.Add('[void](Read-Host ''Press Enter to close this window'')')
    return (($L.ToArray()) -join "`r`n")
}

# Keeps the distro running while the user is signed in: systemd services do not count as activity,
# so without this WSL stops the distro about 15 seconds after the last terminal closes.
# UNVERIFIED(E3): that one foreground wsl.exe running "sleep infinity" is enough to keep it up.
function New-PaKeepaliveScript {
    param([string]$Distro)
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add('# Generated by install-wsl.ps1. Keeps the WSL distro running while you are signed in.')
    [void]$L.Add('$distro = ''' + $Distro + '''')
    [void]$L.Add('$created = $false')
    [void]$L.Add('$mutex = New-Object System.Threading.Mutex($true, (''Local\PiAgentWslKeepalive-'' + $distro), [ref]$created)')
    [void]$L.Add('if (-not $created) { exit 0 }')
    [void]$L.Add('$delay = 5')
    [void]$L.Add('while ($true) {')
    [void]$L.Add('    $t0 = Get-Date')
    [void]$L.Add('    & wsl.exe -d $distro --exec /usr/bin/sleep infinity | Out-Null')
    [void]$L.Add('    $ran = ((Get-Date) - $t0).TotalSeconds')
    [void]$L.Add('    if ($ran -lt 10) { $delay = [Math]::Min(60, $delay * 2) } else { $delay = 5 }')
    [void]$L.Add('    Start-Sleep -Seconds $delay')
    [void]$L.Add('}')
    return (($L.ToArray()) -join "`r`n")
}

function New-PaShimText {
    param([string]$Distro, [string]$User)
    return ('@wsl.exe -d ' + $Distro + ' -u ' + $User + ' --exec /home/' + $User + '/.local/share/pi-agent/bin/pi-agent %*' + "`r`n")
}

function New-PaUrlShortcutText {
    param([int]$Port)
    return ('[InternetShortcut]' + "`r`n" + 'URL=http://localhost:' + $Port + '/' + "`r`n")
}

# ---------------------------------------------------------------------------
# Thin wrappers around the system. The unit tests mock these and nothing else.
# ---------------------------------------------------------------------------

function Get-PaLocalAppData { return [string]$env:LOCALAPPDATA }
function Get-PaWindowsDir { return [string]$env:SystemRoot }
function Get-PaUserProfileDir { return [string]$env:USERPROFILE }
function Get-PaStartMenuDir { return [System.IO.Path]::Combine([string]$env:APPDATA, 'Microsoft', 'Windows', 'Start Menu') }
function Get-PaNow { return (Get-Date) }

function Get-PaShortcutPath {
    return [System.IO.Path]::Combine((Get-PaStartMenuDir), 'Programs', 'Pi Agent.url')
}

function Start-PaSleep {
    param([int]$Seconds)
    Start-Sleep -Seconds $Seconds
}

function Read-PaLine {
    param([string]$Prompt)
    return [string](Read-Host -Prompt $Prompt)
}

# -Yes answers with $ValueWhenYes (rebooting: never; purging data: yes), otherwise ask.
function Read-PaConfirm {
    param([string]$Prompt, [bool]$ValueWhenYes, [bool]$Auto)
    if ($Auto) { return $ValueWhenYes }
    $answer = Read-PaLine -Prompt ($Prompt + ' [y/N]')
    return ($answer -match '^(y|yes)$')
}

function Test-PaPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return (Test-Path -LiteralPath $Path)
}

function New-PaDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Remove-PaPath {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Deletes a directory only when nothing is left in it. -InstallDir can point anywhere the user
# likes, so the install directory is never deleted recursively: the installer removes what it put
# there, and the folder itself only if that leaves it empty.
function Remove-PaEmptyDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $left = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Move-PaItem {
    param([string]$From, [string]$To)
    Move-Item -LiteralPath $From -Destination $To -Force
}

# Files for the VM must be LF without BOM ($Lf); generated .ps1 files get a BOM so that
# Windows PowerShell 5.1 reads them as UTF-8.
function Write-PaFile {
    param([string]$Path, [string]$Text, [bool]$Bom = $false, [bool]$Lf = $false)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $body = $Text
    if ($Lf) { $body = $body.Replace("`r`n", "`n") }
    [System.IO.File]::WriteAllText($Path, $body, (New-Object System.Text.UTF8Encoding($Bom)))
}

function Get-PaFileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Save-PaFile {
    param([string]$Url, [string]$Path)
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path
    } finally {
        $ProgressPreference = $old
    }
}

# UNVERIFIED(E5): that Windows reaches the service through localhost (WSL localhost forwarding).
function Test-PaHttp {
    param([string]$Url, [int]$TimeoutSec = 5)
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
        return ([int]$r.StatusCode -eq 200)
    } catch {
        return $false
    } finally {
        $ProgressPreference = $old
    }
}

function Get-PaSystemInfo {
    param([string]$InstallDir = '')
    $info = [ordered]@{
        IsWindows         = $true
        Caption           = ''
        Build             = $null
        Arch              = 'unknown'
        RamGB             = $null
        FreeDiskGB        = $null
        HypervisorPresent = $null
        VirtFirmware      = $null
        IsAdmin           = $false
        Is64BitProcess    = $true
    }
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { $info['IsWindows'] = $false }
    } catch {
        $null = $_
    }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $info['Build'] = [int]$os.BuildNumber
        $info['Caption'] = [string]$os.Caption
    } catch {
        $null = $_
    }
    try {
        $a = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        if ($a -eq 'X64') { $info['Arch'] = 'x64' }
        elseif ($a -eq 'Arm64') { $info['Arch'] = 'arm64' }
        else { $info['Arch'] = $a.ToLowerInvariant() }
    } catch {
        $e = $env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrEmpty($e)) { $e = $env:PROCESSOR_ARCHITECTURE }
        if ($e -eq 'AMD64') { $info['Arch'] = 'x64' }
        elseif ($e -eq 'ARM64') { $info['Arch'] = 'arm64' }
    }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $info['RamGB'] = [math]::Round(([double]$cs.TotalPhysicalMemory) / 1073741824, 1)
        $info['HypervisorPresent'] = [bool]$cs.HypervisorPresent
    } catch {
        $null = $_
    }
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $info['VirtFirmware'] = [bool]$cpu.VirtualizationFirmwareEnabled
    } catch {
        $null = $_
    }
    try {
        if (-not [string]::IsNullOrEmpty($InstallDir)) {
            $root = [System.IO.Path]::GetPathRoot($InstallDir)
            $drive = New-Object System.IO.DriveInfo($root)
            $info['FreeDiskGB'] = [math]::Round(([double]$drive.AvailableFreeSpace) / 1073741824, 1)
        }
    } catch {
        $null = $_
    }
    try {
        $info['Is64BitProcess'] = [Environment]::Is64BitProcess
    } catch {
        $null = $_
    }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        $info['IsAdmin'] = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $null = $_
    }
    return [pscustomobject]$info
}

# UNVERIFIED(E5): that a forwarded WSL port shows up as a Windows listener (wslrelay) in NAT mode.
function Test-PortInUse {
    param([int]$Port)
    try {
        $c = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        if ($c.Count -gt 0) {
            $name = ''
            try { $name = (Get-Process -Id $c[0].OwningProcess -ErrorAction Stop).ProcessName } catch { $null = $_ }
            return [pscustomobject]@{ InUse = $true; Process = $name }
        }
    } catch {
        $null = $_
    }
    return [pscustomobject]@{ InUse = $false; Process = '' }
}

# UNVERIFIED(E13): that these two keys are what Windows sets after "wsl --install" needs a reboot.
function Test-RebootPending {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) {
        try {
            if (Test-Path -LiteralPath $k) { return $true }
        } catch {
            $null = $_
        }
    }
    return $false
}

function Restart-PaComputer {
    # No -Force: it closes the other programs without letting them ask to save their work.
    try {
        Restart-Computer
    } catch {
        Write-PaMsg 'Warn' ('沒辦法自動重新開機({0})。請存好其他工作後,自己重新開機。(restart failed)' -f $_.Exception.Message)
    }
}

# Runs one PowerShell command line elevated and returns its exit code. Only used for "wsl --install":
# the user may elevate with another administrator account, so nothing else may run in that process.
# UNVERIFIED(E13): the quoting of -Command through Start-Process in Windows PowerShell 5.1.
function Start-PaElevated {
    param([string]$Command)
    $argString = '-NoProfile -ExecutionPolicy Bypass -Command "' + $Command + '"'
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -Verb RunAs -Wait -PassThru
    return [int]$p.ExitCode
}

function Set-PaRunOnce {
    param([string]$Name, [string]$Command)
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -LiteralPath $path -Name $Name -Value $Command -Type String
}

function Remove-PaRunOnce {
    param([string]$Name)
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    Remove-ItemProperty -LiteralPath $path -Name $Name -ErrorAction SilentlyContinue
}

# Returns 'task' or 'runkey'.
# UNVERIFIED(E4): that a standard user may register a logon task for itself; the Run key is the fallback.
# UNVERIFIED(E4): the hidden powershell.exe may flash a window at sign-in; accepted for now.
function Register-PaAutostart {
    param([string]$ScriptPath, [string]$TaskName)
    $psArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
        $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
        return 'task'
    } catch {
        Write-PaLogLine -Text ('scheduled task failed: ' + $_.Exception.Message)
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $runKey -Name $TaskName -Value ('powershell.exe ' + $psArgs) -Type String
        return 'runkey'
    }
}

function Unregister-PaAutostart {
    param([string]$TaskName)
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { $null = $_ }
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $TaskName -ErrorAction SilentlyContinue
}

function Start-PaKeepalive {
    param([string]$ScriptPath)
    $argString = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '"'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -WindowStyle Hidden | Out-Null
}

function Stop-PaKeepalive {
    param([string]$InstallDir)
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'")
        foreach ($p in $procs) {
            $cl = [string]$p.CommandLine
            if ($cl.Contains('keepalive.ps1') -and $cl.IndexOf($InstallDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        $null = $_
    }
}

# Tells running programs (Explorer, new terminals) that the user environment changed.
# UNVERIFIED(E9): standard WM_SETTINGCHANGE broadcast; failure only means "sign out and in again".
function Send-PaEnvironmentChange {
    try {
        if (-not ('PaWin32.Native' -as [type])) {
            Add-Type -Namespace PaWin32 -Name Native -MemberDefinition '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
        }
        $res = [UIntPtr]::Zero
        [void][PaWin32.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$res)
    } catch {
        $null = $_
    }
}

# Edits the USER Path through the registry so that %VARS% stay unexpanded. Returns $true if it changed.
function Set-PaUserPath {
    param([Parameter(Mandatory = $true)][string]$Entry, [switch]$Remove)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($null -eq $key) { $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment') }
    try {
        $cur = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($Remove) {
            $new = Remove-PaPathEntry -Current $cur -Entry $Entry
        } else {
            $new = Add-PaPathEntry -Current $cur -Entry $Entry
        }
        if ($new -ne $cur) {
            $key.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Send-PaEnvironmentChange
            return $true
        }
        return $false
    } finally {
        $key.Close()
    }
}

# ---------------------------------------------------------------------------
# wsl.exe: every call goes through these two functions
# ---------------------------------------------------------------------------

# UNVERIFIED(E1): that WSL_UTF8=1 is honoured by the target WSL version (otherwise the NUL
# stripping in ConvertTo-PaCleanText still handles the UTF-16 output).
function Invoke-Wsl {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $env:WSL_UTF8 = '1'
    Write-PaLogLine -Text ('wsl ' + ($Arguments -join ' '))
    $oldEnc = $null
    $raw = $null
    $code = -1
    try {
        try {
            $oldEnc = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        } catch {
            $null = $_
        }
        $raw = & wsl.exe @Arguments 2>&1
        $code = $LASTEXITCODE
    } catch {
        $raw = @($_.Exception.Message)
        $code = -1
    } finally {
        if ($null -ne $oldEnc) {
            try { [Console]::OutputEncoding = $oldEnc } catch { $null = $_ }
        }
    }
    $text = ConvertTo-PaCleanText -Lines $raw
    Write-PaLogLine -Text ('  exit=' + $code)
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

# Streams the output to the console as it arrives and returns the exit code. The lines are kept
# for Get-PaLastStreamLines.
function Invoke-WslStream {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $env:WSL_UTF8 = '1'
    Write-PaLogLine -Text ('wsl ' + ($Arguments -join ' '))
    $script:PaLastStream = New-Object System.Collections.ArrayList
    $oldEnc = $null
    $code = -1
    try {
        try {
            $oldEnc = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        } catch {
            $null = $_
        }
        & wsl.exe @Arguments 2>&1 | ForEach-Object {
            $line = ConvertTo-PaCleanText -Lines @($_)
            [void]$script:PaLastStream.Add($line)
            Write-Host ('    ' + $line)
            Write-PaLogLine -Text ('  | ' + $line)
        }
        $code = $LASTEXITCODE
    } catch {
        Write-PaLogLine -Text ('  stream error: ' + $_.Exception.Message)
        $code = -1
    } finally {
        if ($null -ne $oldEnc) {
            try { [Console]::OutputEncoding = $oldEnc } catch { $null = $_ }
        }
    }
    Write-PaLogLine -Text ('  exit=' + $code)
    return $code
}

function Get-PaLastStreamLines {
    return @($script:PaLastStream)
}

# ---------------------------------------------------------------------------
# WSL helpers built on the wrappers
# ---------------------------------------------------------------------------

function Invoke-PaVm {
    param([string]$Distro, [string]$User, [string[]]$Exec)
    return (Invoke-Wsl -Arguments (@('-d', $Distro, '-u', $User, '--exec') + $Exec))
}

function Get-WslInfo {
    $r = Invoke-Wsl -Arguments @('--version')
    $ver = $null
    if ($r.ExitCode -eq 0) { $ver = Get-WslVersionText -Text ([string]$r.Output) }
    $ready = $false
    if ($null -ne $ver) { $ready = ((Compare-PaVersion -Left $ver -Right $script:PaMinWslVersion) -ge 0) }
    return [pscustomobject]@{ Ready = $ready; Version = $ver; Raw = [string]$r.Output }
}

function Get-PaDistroNames {
    $r = Invoke-Wsl -Arguments @('-l', '-q')
    $names = New-Object System.Collections.ArrayList
    if ($r.ExitCode -ne 0) { return @() }
    foreach ($line in ([string]$r.Output -split "`n")) {
        $t = $line.Trim()
        if ($t.Length -gt 0) { [void]$names.Add($t) }
    }
    return @($names.ToArray())
}

function Get-PaDistroState {
    param([string]$Name)
    $exists = $false
    foreach ($n in @(Get-PaDistroNames)) {
        if ($n -ieq $Name) { $exists = $true }
    }
    $marker = $false
    if ($exists) {
        $r = Invoke-PaVm -Distro $Name -User 'root' -Exec @('/usr/bin/test', '-f', '/etc/pi-agent-distro')
        $marker = ($r.ExitCode -eq 0)
    }
    return [pscustomobject]@{ Exists = $exists; HasMarker = $marker }
}

# The port an earlier install of this Linux recorded (install.sh writes it), or 0 when there is none.
function Get-PaRecordedPort {
    param([string]$Distro, [string]$User)
    $r = Invoke-PaVm -Distro $Distro -User $User -Exec @('/bin/sh', '-c', 'cat $HOME/.local/share/pi-agent/pi-web-port')
    if ($r.ExitCode -ne 0) { return 0 }
    $line = Get-PaLastLine -Text ([string]$r.Output)
    if ($line -notmatch '^\d{4,5}$') { return 0 }
    $p = [int]$line
    if ($p -lt 1024 -or $p -gt 65535) { return 0 }
    return $p
}

# UNVERIFIED(E2): "systemctl is-system-running --wait" answers running or degraded once boot is done.
function Wait-PaSystemd {
    param([string]$Distro, [int]$Tries = 3)
    for ($i = 1; $i -le $Tries; $i++) {
        $r = Invoke-PaVm -Distro $Distro -User 'root' -Exec @('/usr/bin/timeout', '60', '/usr/bin/systemctl', 'is-system-running', '--wait')
        $state = Get-PaLastLine -Text ([string]$r.Output)
        if ($state -eq 'running' -or $state -eq 'degraded') { return $true }
        Write-PaLogLine -Text ('systemd state: ' + $state)
        Start-PaSleep -Seconds 5
    }
    return $false
}

function Restart-PaDistro {
    param([string]$Distro)
    [void](Invoke-Wsl -Arguments @('--terminate', $Distro))
    Start-PaSleep -Seconds 2
    $r = Invoke-PaVm -Distro $Distro -User 'root' -Exec @('/bin/true')
    return ($r.ExitCode -eq 0)
}

# Download (3 tries) and verify, or reuse a cached file whose hash matches. Returns $true/$false.
function Get-PaVerifiedFile {
    param([string]$Url, [string]$Path, [string]$Sha256, [string]$Label)
    $want = $Sha256.ToLowerInvariant()
    if (Test-PaPath -Path $Path) {
        $h = Get-PaFileSha256 -Path $Path
        if ($h -eq $want) {
            Write-PaMsg 'Info' ('使用已下載的檔案:' + $Label)
            return $true
        }
        Remove-PaPath -Path $Path
    }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Save-PaFile -Url $Url -Path ($Path + '.part')
            Move-PaItem -From ($Path + '.part') -To $Path
        } catch {
            Write-PaMsg 'Warn' ('下載失敗(第 {0} 次):{1}' -f $i, $_.Exception.Message)
            Remove-PaPath -Path ($Path + '.part')
            Start-PaSleep -Seconds (3 * $i)
            continue
        }
        $h = Get-PaFileSha256 -Path $Path
        if ($h -eq $want) { return $true }
        Write-PaMsg 'Warn' ('下載的檔案校驗碼不符,已丟棄(第 {0} 次)。(sha256 mismatch)' -f $i)
        Remove-PaPath -Path $Path
        Start-PaSleep -Seconds (3 * $i)
    }
    return $false
}

# ---------------------------------------------------------------------------
# Step 0: preflight (read-only)
# ---------------------------------------------------------------------------

function Test-PaPreflight {
    param([hashtable]$Opts)
    Write-PaMsg 'Step' '步驟 0/6:檢查這台電腦'
    $bad = $false
    $info = Get-PaSystemInfo -InstallDir $Opts.InstallDir
    $arch = 'x64'

    if (-not (Test-PaDistroName -Name $Opts.DistroName)) {
        Write-PaMsg 'Error' '-DistroName 只能用英文字母、數字、點、底線、減號。(invalid distro name)'
        $bad = $true
    }
    if (-not (Test-PaLinuxUser -Name $Opts.LinuxUser)) {
        Write-PaMsg 'Error' '-LinuxUser 只能用小寫英文字母、數字、底線、減號。(invalid Linux user name)'
        $bad = $true
    }
    if ($Opts.Port -lt 1024 -or $Opts.Port -gt 65535) {
        Write-PaMsg 'Error' '-Port 要在 1024 到 65535 之間。(invalid port)'
        $bad = $true
    }
    if (-not $info.IsWindows) {
        Write-PaMsg 'Error' '這個安裝程式只能在 Windows 上執行。(Windows only)'
        $bad = $true
    }
    # A 32-bit PowerShell (the x86 console or ISE) is redirected away from wsl.exe and would report WSL as missing.
    if ($info.PSObject.Properties['Is64BitProcess'] -and -not $info.Is64BitProcess) {
        Write-PaMsg 'Error' '這是 32 位元的 PowerShell,看不到 WSL。請改開 64 位元的「Windows PowerShell」(開始功能表裡名稱後面沒有 (x86) 的那個),再重跑。(32-bit PowerShell cannot see wsl.exe)'
        $bad = $true
    }
    if ($null -ne $info.Build -and $info.Build -lt $script:PaMinBuild) {
        Write-PaMsg 'Error' ('這台電腦的 Windows 版本太舊(build {0})。需要 Windows 10 2004(build {1})或更新,請先更新 Windows 再重試。(unsupported Windows build)' -f $info.Build, $script:PaMinBuild)
        $bad = $true
    } elseif ($null -ne $info.Build -and $info.Build -lt $script:PaRecommendedBuild) {
        Write-PaMsg 'Warn' ('這台是 Windows 10(build {0})。可以安裝,但主要支援的是 Windows 11 22H2 以上。(Windows 10 is not the main target)' -f $info.Build)
    }
    if ($info.Arch -eq 'x64' -or $info.Arch -eq 'arm64') {
        $arch = $info.Arch
    } else {
        Write-PaMsg 'Error' ('不支援這種處理器({0})。需要 x64 或 ARM64 的電腦。(unsupported architecture)' -f $info.Arch)
        $bad = $true
    }
    if ($null -ne $info.RamGB) {
        if ($info.RamGB -lt 4) {
            Write-PaMsg 'Error' ('記憶體只有 {0} GB,至少需要 4 GB(建議 8 GB 以上)。(not enough RAM)' -f $info.RamGB)
            $bad = $true
        } elseif ($info.RamGB -lt 8) {
            Write-PaMsg 'Warn' ('記憶體只有 {0} GB,可以安裝,但建議 8 GB 以上才順暢。' -f $info.RamGB)
        }
    }
    if ($null -ne $info.FreeDiskGB -and $info.FreeDiskGB -lt 10) {
        Write-PaMsg 'Error' ('{0} 剩下 {1} GB,至少需要 10 GB。請清出空間後再重試。(not enough disk space)' -f [System.IO.Path]::GetPathRoot($Opts.InstallDir), $info.FreeDiskGB)
        $bad = $true
    }
    # UNVERIFIED(E14): the authoritative test is starting the distro; this only warns early.
    if ($info.HypervisorPresent -eq $false -and $info.VirtFirmware -eq $false) {
        Write-PaMsg 'Warn' '沒有偵測到虛擬化功能。如果之後啟動 Linux 失敗,請到 BIOS/UEFI 開啟虛擬化;如果這是虛擬機,需要支援巢狀虛擬化。(virtualization not detected)'
    }

    $stamped = Test-Stamped
    if (-not $stamped -and [string]::IsNullOrEmpty($Opts.BundlePath)) {
        Write-PaMsg 'Error' '這是尚未蓋章的開發版,需要用 -BundlePath 指定安裝包。(unstamped build needs -BundlePath)'
        $bad = $true
    }
    if (-not [string]::IsNullOrEmpty($Opts.BundlePath) -and -not (Test-PaPath -Path $Opts.BundlePath)) {
        Write-PaMsg 'Error' ('找不到安裝包:{0}(bundle not found)' -f $Opts.BundlePath)
        $bad = $true
    }
    if (-not [string]::IsNullOrEmpty($Opts.RootfsPath) -and -not (Test-PaPath -Path $Opts.RootfsPath)) {
        Write-PaMsg 'Error' ('找不到映像檔:{0}(rootfs not found)' -f $Opts.RootfsPath)
        $bad = $true
    }
    if (-not $stamped -and [string]::IsNullOrEmpty($Opts.PiWebArtifact)) {
        Write-PaMsg 'Warn' '沒有指定 -PiWebArtifact,安裝時會從原始碼編譯 pi-web,約需 15 分鐘。(pi-web will be built from source)'
    }

    $state = Get-PaDistroState -Name $Opts.DistroName
    if ($state.Exists -and -not $state.HasMarker) {
        Write-PaMsg 'Error' ('已經有一個叫 {0} 的 WSL 發行版,而且不是這個安裝程式建立的。請用 -DistroName 換一個名字;如果它是上次安裝中途被中斷留下的,先執行 wsl --unregister {0} 再重跑。(distro name taken)' -f $Opts.DistroName)
        $bad = $true
    }
    if ($state.Exists -and $state.HasMarker -and -not $Opts.PortGiven) {
        # A re-run must not move the service. The default port may well belong to something else by now.
        $kept = Get-PaRecordedPort -Distro $Opts.DistroName -User $Opts.LinuxUser
        if ($kept -gt 0 -and $kept -ne $Opts.Port) {
            Write-PaMsg 'Info' ('這台已經裝好,沿用原本的連接埠 {0}。要換埠請加 -Port。(keeping port {0})' -f $kept)
            $Opts.Port = $kept
        }
    }
    if (-not ($state.Exists -and $state.HasMarker)) {
        # Our own distro already forwards its ports to Windows, so a listener there is expected.
        foreach ($p in @($Opts.Port, $script:PaPaseoPort)) {
            $u = Test-PortInUse -Port $p
            if ($u.InUse) {
                Write-PaMsg 'Error' ('連接埠 {0} 已經被「{1}」使用。請先關掉它,或用 -Port 指定別的埠。(port in use)' -f $p, $u.Process)
                $bad = $true
            }
        }
    }

    if (-not $bad) { Write-PaMsg 'Ok' '電腦檢查通過。' }
    return @{ Ok = (-not $bad); Arch = $arch; Info = $info; DistroState = $state }
}

# ---------------------------------------------------------------------------
# Step 1: WSL itself
# ---------------------------------------------------------------------------

function Get-PaResumeSplat {
    param([hashtable]$Opts)
    $s = [ordered]@{}
    $s['Resume'] = $true
    foreach ($k in 'Yes', 'NoWindowsInterop', 'NoAutostart', 'SkipSmoke') {
        if ($Opts[$k]) { $s[$k] = $true }
    }
    foreach ($k in 'DistroName', 'LinuxUser', 'RootfsPath', 'BundlePath', 'PiWebArtifact', 'InstallDir') {
        if (-not [string]::IsNullOrEmpty([string]$Opts[$k])) { $s[$k] = [string]$Opts[$k] }
    }
    $s['Port'] = [int]$Opts.Port
    return $s
}

function Invoke-PaStepReboot {
    param([hashtable]$Opts, [hashtable]$Paths)
    $st = Get-PaStamp
    $kind = ''
    $source = ''
    if ((Test-Stamped) -and -not [string]::IsNullOrEmpty([string]$st.ScriptUrl)) {
        $kind = 'url'
        $source = [string]$st.ScriptUrl
    } elseif (-not [string]::IsNullOrEmpty($script:PaSelfPath)) {
        $kind = 'file'
        $source = $script:PaSelfPath
    }
    Write-PaMsg 'Warn' '需要重新開機,才能完成 WSL 的安裝。'
    if ($kind -ne '') {
        $stub = New-PaResumeStub -Splat (Get-PaResumeSplat -Opts $Opts) -Kind $kind -Source $source
        Write-PaFile -Path $Paths.ResumeStub -Text $stub -Bom $true
        $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $Paths.ResumeStub + '"'
        if ($cmd.Length -gt 250) {
            Write-PaMsg 'Warn' '安裝路徑太長,重新開機後可能無法自動繼續;到時請手動再執行一次安裝指令。(RunOnce command is long)'
        }
        Set-PaRunOnce -Name $script:PaRunOnceName -Command $cmd
        Write-PaMsg 'Info' '重新開機並登入 Windows 後,安裝會自動繼續。'
    } else {
        Write-PaMsg 'Info' '重新開機後,請再執行一次同樣的安裝指令。'
    }
    if (Read-PaConfirm -Prompt '現在重新開機嗎?請先把其他程式裡的工作存好。' -ValueWhenYes $false -Auto $Opts.Yes) {
        Restart-PaComputer
    } else {
        Write-PaMsg 'Info' '請你自己找時間重新開機(安裝程式不會自動重開機)。'
    }
    return 20
}

function Invoke-PaStepWsl {
    param([hashtable]$Opts, [hashtable]$Paths)
    Write-PaMsg 'Step' '步驟 1/6:檢查 WSL(Windows 內建的 Linux 功能)'
    $info = Get-WslInfo
    if ($info.Ready) {
        Write-PaMsg 'Ok' ('WSL 已就緒(版本 {0})。' -f $info.Version)
        return 0
    }
    if ($Opts.DryRun) {
        Write-PaMsg 'Dry' ('would install or update WSL (needs administrator rights, may need a reboot); minimum version {0}' -f $script:PaMinWslVersion)
        return 0
    }
    Write-PaMsg 'Warn' 'WSL 還沒裝好或版本太舊,現在安裝。接下來會跳出「是否允許變更」的確認視窗,請按「是」。'
    $rc = -1
    try {
        $rc = Start-PaElevated -Command $script:PaElevatedWslCommand
    } catch {
        Write-PaMsg 'Error' ('沒有取得系統管理員權限,無法安裝 WSL。請重跑安裝,並在確認視窗按「是」。(administrator rights needed: {0})' -f $_.Exception.Message)
        return 30
    }
    $info = Get-WslInfo
    $pending = Test-RebootPending
    # After the reboot a leftover "pending" flag from something else must not send us round again.
    $needReboot = (-not $info.Ready) -or ($pending -and -not $Opts.Resume)
    if ($needReboot) {
        if ($Opts.Resume -and -not $info.Ready) {
            Write-PaMsg 'Error' '重新開機之後 WSL 還是不能用。請手動執行 wsl --install,看一下訊息再重跑。(WSL still not ready after reboot)'
            return 30
        }
        if (-not $pending -and $rc -ne 0) {
            Write-PaMsg 'Error' ('WSL 安裝失敗(代碼 {0})。請確認網路正常,再重跑一次。如果你是用 SSH 連進來裝,請改在這台電腦的桌面開 PowerShell 跑:Store 版 WSL 在 SSH 連線裡可能啟動不了。(wsl --install failed)' -f $rc)
            return 30
        }
        return (Invoke-PaStepReboot -Opts $Opts -Paths $Paths)
    }
    Write-PaMsg 'Ok' ('WSL 安裝完成(版本 {0})。' -f $info.Version)
    return 0
}

# ---------------------------------------------------------------------------
# Step 2: the dedicated distro
# ---------------------------------------------------------------------------

function Resolve-PaBundle {
    param([hashtable]$Opts, [hashtable]$Paths)
    if (-not [string]::IsNullOrEmpty($Opts.BundlePath)) {
        if (-not (Test-PaPath -Path $Opts.BundlePath)) {
            Write-PaMsg 'Error' ('找不到安裝包:{0}(bundle not found)' -f $Opts.BundlePath)
            return $null
        }
        Write-PaMsg 'Warn' '開發模式:使用你指定的安裝包,不驗證它的校驗碼。(dev mode: bundle hash is not verified)'
        return $Opts.BundlePath
    }
    $st = Get-PaStamp
    New-PaDirectory -Path $Paths.CacheDir
    $dest = [System.IO.Path]::Combine($Paths.CacheDir, ('pi-agent-installer-' + $st.Version + '.tar.gz'))
    Write-PaMsg 'Info' '下載安裝包...'
    if (Get-PaVerifiedFile -Url ([string]$st.BundleUrl) -Path $dest -Sha256 ([string]$st.BundleSha256) -Label '安裝包') { return $dest }
    Write-PaMsg 'Error' '安裝包下載或校驗失敗。請檢查網路後重試。(bundle download or sha256 check failed)'
    return $null
}

function Resolve-PaRootfs {
    param([hashtable]$Opts, [hashtable]$Paths, [string]$Arch)
    $spec = Get-PaRootfsSpec -Arch $Arch
    if (-not [string]::IsNullOrEmpty($Opts.RootfsPath)) {
        $h = ''
        if (Test-PaPath -Path $Opts.RootfsPath) { $h = Get-PaFileSha256 -Path $Opts.RootfsPath }
        if ($h -ne $spec.Sha256) {
            Write-PaMsg 'Error' '指定的映像檔校驗碼不符,不會匯入。(sha256 mismatch)'
            return $null
        }
        return $Opts.RootfsPath
    }
    New-PaDirectory -Path $Paths.CacheDir
    $dest = [System.IO.Path]::Combine($Paths.CacheDir, $spec.FileName)
    Write-PaMsg 'Info' ('下載 Ubuntu 24.04 映像(約 {0} MiB,要一點時間)...' -f $spec.SizeMiB)
    if (Get-PaVerifiedFile -Url $spec.Url -Path $dest -Sha256 $spec.Sha256 -Label 'Ubuntu 映像') { return $dest }
    Write-PaMsg 'Error' '映像下載或校驗失敗(sha256 mismatch 或網路問題),不會匯入。請檢查網路後重試。(download or sha256 check failed)'
    return $null
}

function Copy-PaBundleToVm {
    param([string]$Distro, [string]$BundleFile)
    $wslPath = ConvertTo-WslPath -Path $BundleFile
    $stage = $script:PaStagingDir
    $cmds = @(
        @('/bin/rm', '-rf', $stage),
        @('/bin/mkdir', '-p', $stage),
        @('/bin/tar', '-xzf', $wslPath, '-C', $stage, '--strip-components=1')
    )
    foreach ($c in $cmds) {
        $r = Invoke-PaVm -Distro $Distro -User 'root' -Exec $c
        if ($r.ExitCode -ne 0) {
            Write-PaMsg 'Error' ('把安裝包放進 Linux 失敗:{0}(copy bundle failed)' -f $r.Output)
            return $false
        }
    }
    return $true
}

# Removes a distro THIS run imported and could not finish, so the next run is not blocked by "name taken".
function Remove-PaNewDistro {
    param([string]$Distro)
    Write-PaMsg 'Warn' ('清掉這次剛建立、還沒設定完的 Linux「{0}」,下次可以重來。' -f $Distro)
    [void](Invoke-Wsl -Arguments @('--unregister', $Distro))
}

function Invoke-PaStepDistro {
    param([hashtable]$Opts, [hashtable]$Paths, [hashtable]$Ctx)
    $name = $Opts.DistroName
    $user = $Opts.LinuxUser
    Write-PaMsg 'Step' ('步驟 2/6:準備專用的 Linux「{0}」' -f $name)
    $state = Get-PaDistroState -Name $name
    if ($Opts.DryRun) {
        if ($state.Exists) {
            Write-PaMsg 'Dry' ('would reuse the distro {0} and refresh the installer inside it' -f $name)
        } else {
            $spec = Get-PaRootfsSpec -Arch $Ctx.Arch
            Write-PaMsg 'Dry' ('would download the Ubuntu 24.04 image (about {0} MiB), verify its sha256, import it as {1}, create the user {2} and turn on systemd' -f $spec.SizeMiB, $name, $user)
        }
        return 0
    }
    $created = $false
    try {
        $bundle = Resolve-PaBundle -Opts $Opts -Paths $Paths
        if (-not $bundle) { return 40 }

        if (-not $state.Exists) {
            $rootfs = Resolve-PaRootfs -Opts $Opts -Paths $Paths -Arch $Ctx.Arch
            if (-not $rootfs) { return 40 }
            Write-PaMsg 'Info' '匯入 Linux 映像(約 1 分鐘)...'
            New-PaDirectory -Path $Paths.DistroDir
            # UNVERIFIED(E1): that wsl --import accepts the .wsl file and starts without any prompt.
            $r = Invoke-Wsl -Arguments @('--import', $name, $Paths.DistroDir, $rootfs, '--version', '2')
            if ($r.ExitCode -ne 0) {
                $friendly = ConvertTo-PaFriendlyWslError -Text ([string]$r.Output)
                if ($friendly) { Write-PaMsg 'Error' $friendly } else { Write-PaMsg 'Error' ('匯入 Linux 映像失敗:{0}(wsl --import failed)' -f $r.Output) }
                return 40
            }
            $created = $true
            $r = Invoke-PaVm -Distro $name -User 'root' -Exec @('/bin/true')
            if ($r.ExitCode -ne 0) {
                $friendly = ConvertTo-PaFriendlyWslError -Text ([string]$r.Output)
                if ($friendly) { Write-PaMsg 'Error' $friendly } else { Write-PaMsg 'Error' ('Linux 啟動失敗:{0}(distro did not start)' -f $r.Output) }
                Remove-PaNewDistro -Distro $name
                return 40
            }
        } else {
            Write-PaMsg 'Info' ('沿用已經存在的 Linux「{0}」。' -f $name)
        }

        if (-not (Copy-PaBundleToVm -Distro $name -BundleFile $bundle)) {
            if ($created) { Remove-PaNewDistro -Distro $name }
            return 40
        }

        $before = ''
        if (-not $created) {
            $before = [string](Invoke-PaVm -Distro $name -User 'root' -Exec @('/bin/cat', '/etc/wsl.conf')).Output
        }
        $interop = 'on'
        if ($Opts.NoWindowsInterop) { $interop = 'off' }
        $cfg = @('/bin/bash', $script:PaRootSetup, 'configure', '--user', $user, '--interop', $interop)
        if ($interop -eq 'on') {
            # UNVERIFIED(E6): that System32 (and the PowerShell folder below it) is what agents need on PATH.
            $sys32 = ''
            try { $sys32 = ConvertTo-WslPath -Path ([System.IO.Path]::Combine((Get-PaWindowsDir), 'System32')) } catch { Write-PaMsg 'Warn' 'Windows 資料夾不在磁碟機代號底下,Windows 互通的路徑設定略過。(Windows directory is not on a drive letter)' }
            if ($sys32) { $cfg += @('--win-system32', $sys32) }
        }
        $cfg += @('--installer-src', $script:PaStagingDir)
        $r = Invoke-PaVm -Distro $name -User 'root' -Exec $cfg
        $uid = Get-PaUidFromOutput -Text ([string]$r.Output) -Prefix 'configured'
        if ($r.ExitCode -ne 0 -or $null -eq $uid) {
            Write-PaMsg 'Error' ('設定 Linux 失敗:{0}(configure failed)' -f $r.Output)
            if ($created) { Remove-PaNewDistro -Distro $name }
            return 40
        }
        $Ctx.Uid = $uid

        $needRestart = $created
        if (-not $created) {
            $after = [string](Invoke-PaVm -Distro $name -User 'root' -Exec @('/bin/cat', '/etc/wsl.conf')).Output
            if ($after -ne $before) { $needRestart = $true }
        }
        if ($needRestart) {
            Write-PaMsg 'Info' '重新啟動 Linux,讓設定生效...'
            if (-not (Restart-PaDistro -Distro $name)) {
                Write-PaMsg 'Error' 'Linux 重新啟動失敗。(distro restart failed)'
                return 40
            }
        }
        if (-not (Wait-PaSystemd -Distro $name)) {
            Write-PaMsg 'Error' 'Linux 裡的 systemd 沒有啟動,Pi Agent 需要它。請重跑安裝;還是不行的話,把 install.log 給我們看。(systemd did not start)'
            return 40
        }
    } catch {
        Write-PaMsg 'Error' ('準備 Linux 時發生錯誤:{0}(distro step failed)' -f $_.Exception.Message)
        if ($created) { Remove-PaNewDistro -Distro $name }
        return 40
    }
    Write-PaMsg 'Ok' ('專用的 Linux「{0}」準備好了。' -f $name)
    return 0
}

# ---------------------------------------------------------------------------
# Steps 3 and 4: packages, then Pi Agent itself
# ---------------------------------------------------------------------------

function Invoke-PaStepPackages {
    param([hashtable]$Opts, [hashtable]$Ctx)
    $name = $Opts.DistroName
    $user = $Opts.LinuxUser
    Write-PaMsg 'Step' '步驟 3/6:安裝 Linux 需要的套件(約幾分鐘)'
    if ($Opts.DryRun) {
        Write-PaMsg 'Dry' 'would install the apt packages and turn on lingering for the Linux user'
        return 0
    }
    $code = Invoke-WslStream -Arguments @('-d', $name, '-u', 'root', '--exec', '/bin/bash', $script:PaRootSetup, 'packages', '--user', $user)
    if ($code -ne 0) {
        Write-PaMsg 'Error' ('安裝 Linux 套件失敗(代碼 {0})。請確認網路正常後重跑。(packages failed)' -f $code)
        return 40
    }
    # UNVERIFIED(E2): that linger gives the user a systemd manager and /run/user/<uid>/bus without a login.
    $r = Invoke-PaVm -Distro $name -User 'root' -Exec @('/bin/bash', $script:PaRootSetup, 'linger', '--user', $user)
    $uid = Get-PaUidFromOutput -Text ([string]$r.Output) -Prefix 'linger'
    if ($r.ExitCode -ne 0 -or $null -eq $uid) {
        Write-PaMsg 'Error' ('啟用使用者服務失敗:{0}(linger failed)' -f $r.Output)
        return 40
    }
    $Ctx.Uid = $uid
    Write-PaMsg 'Ok' '套件安裝完成。'
    return 0
}

function Invoke-PaStepInstall {
    param([hashtable]$Opts, [hashtable]$Ctx)
    $name = $Opts.DistroName
    $user = $Opts.LinuxUser
    Write-PaMsg 'Step' '步驟 4/6:安裝 Pi Agent(要下載約 180 MB,請耐心等候)'
    if ($Opts.DryRun) {
        Write-PaMsg 'Dry' 'would run install.sh as the Linux user (pi-web, Claude Code, Codex, Omnigent host, systemd service)'
        return 0
    }
    try {
        $artifact = Get-PaPiWebArtifact -Opts $Opts -Arch $Ctx.Arch
    } catch {
        Write-PaMsg 'Error' ('-PiWebArtifact 的路徑不能用:{0}(bad artifact path)' -f $_.Exception.Message)
        return 50
    }
    if ([string]::IsNullOrEmpty($artifact)) {
        Write-PaMsg 'Warn' '沒有預先編譯好的 pi-web,會從原始碼編譯,約需 15 分鐘。(building pi-web from source)'
    }
    $args4 = Get-PaUserExecArgs -Distro $name -User $user -Uid $Ctx.Uid -Port $Opts.Port -Artifact $artifact -Command @('/bin/bash', './install.sh')
    $code = Invoke-WslStream -Arguments $args4
    if ($code -ne 0) {
        Write-PaMsg 'Error' ('Pi Agent 安裝失敗(代碼 {0})。完整紀錄在 {1}。(install.sh failed)' -f $code, $script:PaLogFile)
        return 50
    }
    Write-PaMsg 'Ok' 'Pi Agent 安裝完成。'
    return 0
}

# ---------------------------------------------------------------------------
# Step 5: the Windows side
# ---------------------------------------------------------------------------

# UNVERIFIED(E9): the whole Windows side (shim on the user PATH, Start Menu .url file) on a real machine.
function Invoke-PaStepIntegration {
    param([hashtable]$Opts, [hashtable]$Paths)
    $name = $Opts.DistroName
    $user = $Opts.LinuxUser
    Write-PaMsg 'Step' '步驟 5/6:設定 Windows 端(自動啟動、pi-agent 指令、開始功能表捷徑)'
    if ($Opts.DryRun) {
        Write-PaMsg 'Dry' ('would write {0} and start it hidden (keeps the Linux running while you are signed in)' -f $Paths.Keepalive)
        if (-not $Opts.NoAutostart) {
            Write-PaMsg 'Dry' ('would register the scheduled task {0} (at sign-in), falling back to the HKCU Run key' -f $script:PaTaskName)
        }
        Write-PaMsg 'Dry' ('would write {0} and add {1} to your user PATH' -f $Paths.Shim, $Paths.BinDir)
        Write-PaMsg 'Dry' 'would create the Start Menu shortcut Pi Agent.url'
        return 0
    }
    try {
        New-PaDirectory -Path $Paths.BinDir
        Write-PaFile -Path $Paths.Keepalive -Text (New-PaKeepaliveScript -Distro $name) -Bom $true
        Start-PaKeepalive -ScriptPath $Paths.Keepalive
        Write-PaMsg 'Ok' '已啟動保持 Linux 運作的背景程式。'
        if ($Opts.NoAutostart) {
            Write-PaMsg 'Info' '略過自動啟動的設定(-NoAutostart)。'
        } else {
            $mode = Register-PaAutostart -ScriptPath $Paths.Keepalive -TaskName $script:PaTaskName
            if ($mode -eq 'task') {
                Write-PaMsg 'Ok' '已設定:登入 Windows 時自動啟動。'
            } else {
                Write-PaMsg 'Warn' '排程工作建立失敗,改用「登入時執行」的登錄項目。(scheduled task failed, used the Run key)'
            }
        }
        Write-PaFile -Path $Paths.Shim -Text (New-PaShimText -Distro $name -User $user) -Bom $false
        $changed = Set-PaUserPath -Entry $Paths.BinDir
        if ($changed) {
            Write-PaMsg 'Ok' '已加入 pi-agent 指令。新開的 PowerShell 視窗才找得到它。'
        } else {
            Write-PaMsg 'Info' 'pi-agent 指令之前就設定好了。'
        }
        Write-PaFile -Path (Get-PaShortcutPath) -Text (New-PaUrlShortcutText -Port $Opts.Port) -Bom $false
        Write-PaMsg 'Ok' '已建立開始功能表捷徑「Pi Agent」。'
    } catch {
        Write-PaMsg 'Error' ('設定 Windows 端時發生錯誤:{0}(integration failed)' -f $_.Exception.Message)
        return 60
    }
    return 0
}

# ---------------------------------------------------------------------------
# Step 6: verify and tell the user what to do next
# ---------------------------------------------------------------------------

function Show-PaNextSteps {
    param([hashtable]$Opts)
    $uninstallCmd = '.\install-wsl.ps1 -Uninstall'
    if (-not [string]::IsNullOrEmpty($script:PaSelfPath)) {
        $uninstallCmd = '& "' + $script:PaSelfPath + '" -Uninstall'
    } elseif (Test-Stamped) {
        # Installed with the one-line command: there is no file to run, so give the one-liner again.
        $uninstallCmd = Get-PaOneLiner -Url ([string](Get-PaStamp).ScriptUrl) -Extra '-Uninstall'
    }
    Write-PaMsg 'Ok' '完成!Pi Agent 已經可以使用。'
    Write-PaMsg 'Info' '接下來:'
    Write-PaMsg 'Info' ('  1. 用瀏覽器開 http://localhost:{0}/(開始功能表裡也有「Pi Agent」)。' -f $Opts.Port)
    Write-PaMsg 'Info' '  2. 在頁面的 Omnigent 分頁,連線到你的 Omnigent 伺服器。'
    Write-PaMsg 'Info' ('  3. Claude Code 和 Codex 要在 Linux 裡各登入一次。在 PowerShell 輸入 wsl -d {0},再依序輸入:' -f $Opts.DistroName)
    Write-PaMsg 'Info' '       ~/.local/share/pi-agent/bin/claude auth login'
    Write-PaMsg 'Info' '       ~/.local/share/pi-agent/bin/codex login'
    Write-PaMsg 'Info' '  4. 平常用 pi-agent status、pi-agent restart 管理(新開的 PowerShell 視窗才找得到這個指令)。'
    Write-PaMsg 'Info' ('  5. 要解除安裝:{0}(預設會保留你的資料)。' -f $uninstallCmd)
    if (-not $Opts.NoWindowsInterop) {
        Write-PaMsg 'Warn' '提醒:Windows 互通已開啟,代理可以用你的 Windows 權限執行程式。不想要的話,重跑安裝並加上 -NoWindowsInterop。'
    }
}

function Invoke-PaStepVerify {
    param([hashtable]$Opts, [hashtable]$Ctx)
    $name = $Opts.DistroName
    $user = $Opts.LinuxUser
    Write-PaMsg 'Step' '步驟 6/6:確認可以使用'
    if ($Opts.DryRun) {
        Write-PaMsg 'Dry' ('would wait for http://localhost:{0}/api/home and run tests/smoke.sh inside the Linux' -f $Opts.Port)
        return 0
    }
    $url = 'http://localhost:' + $Opts.Port + '/api/home'
    $up = $false
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-PaHttp -Url $url) { $up = $true; break }
        Start-PaSleep -Seconds 3
    }
    if (-not $up) {
        Write-PaMsg 'Error' ('等了 3 分鐘,{0} 還是沒有回應。請看 install.log,或在 PowerShell 輸入 pi-agent logs。(no answer from pi-web)' -f $url)
        return 70
    }
    Write-PaMsg 'Ok' ('Pi Agent 已經在 http://localhost:{0}/ 回應。' -f $Opts.Port)
    if (-not $Opts.SkipSmoke) {
        Write-PaMsg 'Info' '執行自我檢查(smoke test)...'
        $smoke = Get-PaUserExecArgs -Distro $name -User $user -Uid $Ctx.Uid -Port $Opts.Port -Artifact '' -Command @('/bin/bash', './tests/smoke.sh')
        $code = Invoke-WslStream -Arguments $smoke
        $res = Get-PaSmokeResult -Lines (Get-PaLastStreamLines)
        if ($null -ne $res) {
            Write-PaMsg 'Info' ('自我檢查:{0} 項通過,{1} 項失敗。' -f $res.Passed, $res.Failed)
        }
        if ($code -ne 0) {
            Write-PaMsg 'Error' '自我檢查有項目沒通過。上面的紀錄會顯示是哪一項。(smoke test failed)'
            return 70
        }
    }
    Show-PaNextSteps -Opts $Opts
    return 0
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

# What the installer put in InstallDir besides the distro's disk.
function Remove-PaInstallFiles {
    param([hashtable]$Paths)
    foreach ($p in @($Paths.CacheDir, $Paths.BinDir, $Paths.Keepalive, $Paths.ResumeStub, $Paths.Log)) {
        Remove-PaPath -Path $p
    }
}

# Only after a successful --unregister: until then DistroDir may hold the ext4.vhdx of a distro that is
# still registered (under another name, or because `wsl -l` failed), and deleting that is deleting data.
function Remove-PaInstallDir {
    param([hashtable]$Paths)
    Remove-PaInstallFiles -Paths $Paths
    Remove-PaPath -Path $Paths.DistroDir
    Remove-PaEmptyDir -Path $Paths.InstallDir
}

# Stops Pi Agent in the Linux and turns its service off, so that a later start of the distro -- even a
# plain "wsl -d PiAgent" -- does not bring pi-web, the Omnigent host and the Windows interop back. A
# reinstall turns the service on again (install.sh does `systemctl --user enable --now`).
function Stop-PaPiAgentInVm {
    param([string]$Distro, [string]$User)
    $r = Invoke-PaVm -Distro $Distro -User 'root' -Exec @('/usr/bin/id', '-u', $User)
    $uid = ([string]$r.Output).Trim()
    if ($r.ExitCode -eq 0 -and $uid -match '^\d+$') {
        $envArgs = @('/usr/bin/env', ('XDG_RUNTIME_DIR=/run/user/' + $uid), ('DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/' + $uid + '/bus'))
        [void](Invoke-Wsl -Arguments (@('-d', $Distro, '-u', $User, '--exec') + $envArgs + @('/usr/bin/systemctl', '--user', 'disable', '--now', 'pi-web.service')))
    }
    [void](Invoke-Wsl -Arguments @('-d', $Distro, '-u', $User, '--exec', ('/home/' + $User + '/.local/share/pi-agent/bin/pi-agent'), 'stop'))
}

function Invoke-PaUninstall {
    param([hashtable]$Opts, [hashtable]$Paths)
    $name = $Opts.DistroName
    $user = $Opts.LinuxUser
    Write-PaMsg 'Step' '解除安裝 Pi Agent(Windows 版)'
    $state = Get-PaDistroState -Name $name
    if ($Opts.DryRun) {
        Write-PaMsg 'Dry' 'would stop the keep-alive process, remove the scheduled task, the Run and RunOnce entries, the pi-agent command and the Start Menu shortcut'
        if ($state.Exists) { Write-PaMsg 'Dry' ('would stop Pi Agent inside {0} and stop the distro; the distro and its data stay' -f $name) }
        if ($Opts.PurgeData) { Write-PaMsg 'Dry' ('would export {0} to a backup file first, then unregister it (deleting all its data)' -f $name) }
        return 0
    }
    Stop-PaKeepalive -InstallDir $Paths.InstallDir
    Unregister-PaAutostart -TaskName $script:PaTaskName
    Remove-PaRunOnce -Name $script:PaRunOnceName
    [void](Set-PaUserPath -Entry $Paths.BinDir -Remove)
    Remove-PaPath -Path (Get-PaShortcutPath)
    Remove-PaPath -Path $Paths.BinDir
    Remove-PaPath -Path $Paths.Keepalive
    Remove-PaPath -Path $Paths.ResumeStub
    Write-PaMsg 'Ok' 'Windows 端的設定已移除。'
    if ($state.Exists -and $state.HasMarker) {
        Stop-PaPiAgentInVm -Distro $name -User $user
        [void](Invoke-Wsl -Arguments @('--terminate', $name))
        Write-PaMsg 'Ok' ('已停止 Linux「{0}」裡的 Pi Agent。' -f $name)
    } elseif ($state.Exists) {
        Write-PaMsg 'Warn' ('Linux「{0}」不是這個安裝程式建立的,沒有動它。(not created by this installer, left alone)' -f $name)
    }
    if (-not $Opts.PurgeData) {
        Write-PaMsg 'Info' ('Linux「{0}」和裡面的資料都保留著。要連資料一起刪掉,請加上 -Uninstall -PurgeData。' -f $name)
        return 0
    }
    if (-not $state.Exists) {
        Write-PaMsg 'Info' ('找不到 Linux「{0}」,沒有資料要刪。' -f $name)
        Remove-PaInstallFiles -Paths $Paths
        if (Test-PaPath -Path $Paths.DistroDir) {
            Write-PaMsg 'Warn' ('資料夾 {0} 沒有動。如果 wsl -l -v 還看得到 Linux,請自己用 wsl --unregister <名稱> 刪;確定沒有了再手動刪這個資料夾。(distro folder left alone)' -f $Paths.DistroDir)
        }
        Remove-PaEmptyDir -Path $Paths.InstallDir
        return 0
    }
    if (-not $state.HasMarker) {
        Write-PaMsg 'Error' ('Linux「{0}」不是這個安裝程式建立的(找不到 /etc/pi-agent-distro),所以不會刪除它。要刪請自己執行 wsl --unregister {0}。(not created by this installer, nothing was deleted)' -f $name)
        return 3
    }
    # UNVERIFIED(E11): wsl --export of a distro with a few GB of data can take minutes.
    $stamp = (Get-PaNow).ToString('yyyyMMdd-HHmm')
    $backup = [System.IO.Path]::Combine((Get-PaUserProfileDir), ('PiAgent-backup-' + $stamp + '.tar'))
    Write-PaMsg 'Info' ('先把 Linux 的資料備份到 {0}(可能要幾分鐘)...' -f $backup)
    $r = Invoke-Wsl -Arguments @('--export', $name, $backup)
    if ($r.ExitCode -ne 0 -or -not (Test-PaPath -Path $backup)) {
        Write-PaMsg 'Error' ('備份失敗,所以不會刪除任何資料:{0}(backup failed, nothing was deleted)' -f $r.Output)
        return 40
    }
    Write-PaMsg 'Ok' ('已備份:{0}' -f $backup)
    if (-not $Opts.Yes) {
        Write-PaMsg 'Warn' ('接下來會永久刪除 Linux「{0}」和裡面所有資料(備份檔會留著)。' -f $name)
        $typed = Read-PaLine -Prompt ('要繼續請輸入發行版名稱 ' + $name)
        if ($typed -ne $name) {
            Write-PaMsg 'Info' '已取消,沒有刪除任何資料。'
            return 2
        }
    }
    $r = Invoke-Wsl -Arguments @('--unregister', $name)
    if ($r.ExitCode -ne 0) {
        Write-PaMsg 'Error' ('刪除 Linux 失敗:{0}(unregister failed)' -f $r.Output)
        return 40
    }
    Remove-PaInstallDir -Paths $Paths
    Write-PaMsg 'Ok' ('已刪除 Linux「{0}」。備份檔:{1}' -f $name, $backup)
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Initialize-PaLog {
    param([hashtable]$Paths)
    New-PaDirectory -Path $Paths.InstallDir
    $script:PaLogFile = $Paths.Log
    Write-PaLogLine -Text '--- install-wsl.ps1 start ---'
}

function Invoke-PaMainCore {
    param([hashtable]$Opts)
    $paths = Get-PaPaths -Opts $Opts
    if (-not $Opts.DryRun) { Initialize-PaLog -Paths $paths }
    $shownVersion = 'dev'
    if (Test-Stamped) { $shownVersion = [string](Get-PaStamp).Version }
    Write-PaMsg 'Step' ('Pi Agent Windows 版(WSL2)安裝程式  版本 {0}' -f $shownVersion)
    if ($Opts.DryRun) { Write-PaMsg 'Info' '試跑模式:只檢查,不會改變任何東西。' }

    if ($Opts.Uninstall) { return (Invoke-PaUninstall -Opts $Opts -Paths $paths) }

    if ($Opts.Resume) {
        if (-not $Opts.DryRun) { Remove-PaRunOnce -Name $script:PaRunOnceName }
        Write-PaMsg 'Info' '重新開機後繼續安裝...'
    }

    $ctx = @{ Arch = 'x64'; Uid = 0 }
    $pre = Test-PaPreflight -Opts $Opts
    if (-not $pre.Ok) { return 10 }
    $ctx.Arch = $pre.Arch

    $rc = Invoke-PaStepWsl -Opts $Opts -Paths $paths
    if ($rc -ne 0) { return $rc }
    $rc = Invoke-PaStepDistro -Opts $Opts -Paths $paths -Ctx $ctx
    if ($rc -ne 0) { return $rc }
    $rc = Invoke-PaStepPackages -Opts $Opts -Ctx $ctx
    if ($rc -ne 0) { return $rc }
    $rc = Invoke-PaStepInstall -Opts $Opts -Ctx $ctx
    if ($rc -ne 0) { return $rc }
    $rc = Invoke-PaStepIntegration -Opts $Opts -Paths $paths
    if ($rc -ne 0) { return $rc }
    $rc = Invoke-PaStepVerify -Opts $Opts -Ctx $ctx
    if ($rc -ne 0) { return $rc }
    return 0
}

# Returns the exit code: 0 ok; 1 unexpected error; 2 cancelled by the user; 3 refused (the Linux is not
# this installer's); 10 preflight; 20 reboot needed; 30 WSL; 40 distro; 50 install; 60 Windows
# integration; 70 verify.
function Invoke-PaMain {
    param([hashtable]$Options)
    $script:PaDry = [bool]$Options.DryRun
    $script:PaLogFile = ''
    Reset-PaMessages
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        $rc = @(Invoke-PaMainCore -Opts $Options)
        return [int]$rc[$rc.Count - 1]
    } catch {
        Write-PaMsg 'Error' ('未預期的錯誤:{0}(unexpected error)' -f $_.Exception.Message)
        return 1
    } finally {
        $ErrorActionPreference = $oldEap
        $script:PaDry = $false
    }
}

# Pester dot-sources this file with PI_AGENT_WSL_TEST=1 and calls the functions itself.
if ($env:PI_AGENT_WSL_TEST -ne '1') {
    if ($PSCommandPath) { $script:PaSelfPath = $PSCommandPath }
    $paBound = @{
        Yes = [bool]$Yes; DryRun = [bool]$DryRun; Resume = [bool]$Resume; Uninstall = [bool]$Uninstall
        PurgeData = [bool]$PurgeData; NoWindowsInterop = [bool]$NoWindowsInterop
        NoAutostart = [bool]$NoAutostart; SkipSmoke = [bool]$SkipSmoke
        DistroName = $DistroName; LinuxUser = $LinuxUser
        RootfsPath = $RootfsPath; BundlePath = $BundlePath; PiWebArtifact = $PiWebArtifact
        InstallDir = $InstallDir
    }
    if ($PSBoundParameters.ContainsKey('Port')) { $paBound['Port'] = $Port }
    $paCode = 1
    try {
        $paCode = Invoke-PaMain -Options (New-PaOptions -Bound $paBound)
    } catch {
        Write-Host ('Pi Agent: ' + $_.Exception.Message) -ForegroundColor Red
    }
    # File mode: leave with the code. Script block / iex mode: never close the user's console.
    if ($PSCommandPath -and $env:PI_AGENT_WSL_NOEXIT -ne '1') { exit $paCode }
    $global:LASTEXITCODE = $paCode
}
