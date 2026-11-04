# Pester 5 tests for windows/install-wsl.ps1.
#
# Behaviour is tested through the script's own functions and exit codes. Only the thin wrappers
# around the system are mocked (Invoke-Wsl, Invoke-WslStream, Get-PaSystemInfo, ...), so nothing
# here touches wsl.exe, the registry, the disk or the network.
#
# This file is ASCII on purpose: Windows PowerShell 5.1 reads a file without BOM as ANSI. Chinese
# text in the tests is built from character codes. The script under test is copied to a temp file
# with a BOM before it is dot-sourced, which is what the release does too.

BeforeAll {
    $env:PI_AGENT_WSL_TEST = '1'
    $src = Join-Path (Join-Path $PSScriptRoot '..') 'install-wsl.ps1'
    $text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
    $script:Copy = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('install-wsl-test-' + [guid]::NewGuid().ToString('N') + '.ps1'))
    [System.IO.File]::WriteAllText($script:Copy, $text, (New-Object System.Text.UTF8Encoding($true)))
    . $script:Copy
    $script:RealRemoveEmptyDir = ${function:Remove-PaEmptyDir}

    $script:X64Hash = 'bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e'
    $script:Arm64Hash = '74478b5024d9047397ba79d17c27f73caf85ada4988f88cffc2892d65e6a806b'

    function Get-CallIndex {
        param([string]$Pattern)
        for ($i = 0; $i -lt $script:Calls.Count; $i++) {
            if ($script:Calls[$i] -match $Pattern) { return $i }
        }
        return -1
    }

    function Get-MutatingCalls {
        return @($script:Calls | Where-Object { $_ -match '^--(import|install|update|terminate|unregister|export)\b' })
    }

    function New-TestOpts {
        param([hashtable]$Extra = @{})
        $b = @{ Yes = $true; InstallDir = 'C:\Test\PiAgent'; BundlePath = 'C:\b\bundle.tar.gz' }
        foreach ($k in $Extra.Keys) { $b[$k] = $Extra[$k] }
        return (New-PaOptions -Bound $b)
    }

    function Get-AllMessages {
        return ((Get-PaMessages) -join "`n")
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Copy -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Env:\PI_AGENT_WSL_TEST -ErrorAction SilentlyContinue
}

# One wrapper: Pester refuses BeforeEach directly in the root of a file ("Each test setup is not supported in root").
Describe 'install-wsl.ps1' {
BeforeEach {
    $script:Calls = New-Object System.Collections.ArrayList
    $script:Streams = New-Object System.Collections.ArrayList
    $script:Scn = @{
        Info             = [pscustomobject]@{ IsWindows = $true; Caption = 'Windows 11'; Build = 26100; Arch = 'x64'; RamGB = 16; FreeDiskGB = 100; HypervisorPresent = $true; VirtFirmware = $true; IsAdmin = $false; Is64BitProcess = $true }
        WslReady         = $true
        WslVersion       = '2.5.7.0'
        DistroExists     = $false
        HasMarker        = $true
        StartFail        = $false
        SystemdState     = 'running'
        Uid              = 1001
        WslConf          = 'conf-v1'
        ExportExit       = 0
        ElevatedExit     = 0
        ElevatedThrows   = $false
        ReadyAfterElevated = $true
        RebootPending    = $false
        PackagesExit     = 0
        InstallExit      = 0
        SmokeExit        = 0
        HttpUp           = $true
        BusyPorts        = @()
        RecordedPort     = ''
        HashOverride     = ''
        Answer           = ''
        Existing         = @('C:\b\bundle.tar.gz')
    }
    Set-PaStamp -Stamp @{
        Version       = '1.2.3'
        BundleUrl     = 'https://example.invalid/bundle.tar.gz'
        BundleSha256  = ('b' * 64)
        ScriptUrl     = 'https://example.invalid/install-wsl.ps1'
        PiWebUrlX64   = 'https://example.invalid/piweb-x64.tar.gz'
        PiWebUrlArm64 = 'https://example.invalid/piweb-arm64.tar.gz'
    }
    Reset-PaMessages

    Mock Write-Host { }
    Mock Write-PaLogLine { }
    Mock Get-PaLocalAppData { 'C:\Users\tester\AppData\Local' }
    Mock Get-PaWindowsDir { 'C:\Windows' }
    Mock Get-PaUserProfileDir { 'C:\Users\tester' }
    Mock Get-PaStartMenuDir { 'C:\Users\tester\AppData\Roaming\Microsoft\Windows\Start Menu' }
    Mock Get-PaNow { [datetime]'2026-11-03T12:00:00' }
    Mock Get-PaSystemInfo { $script:Scn.Info }
    Mock Test-PortInUse { [pscustomobject]@{ InUse = ($script:Scn.BusyPorts -contains $Port); Process = 'node' } }
    Mock Test-RebootPending { $script:Scn.RebootPending }
    Mock Start-PaElevated {
        if ($script:Scn.ElevatedThrows) { throw 'The operation was canceled by the user' }
        if ($script:Scn.ReadyAfterElevated) { $script:Scn.WslReady = $true }
        return $script:Scn.ElevatedExit
    }
    Mock Start-PaSleep { }
    Mock Read-PaLine { $script:Scn.Answer }
    Mock Restart-PaComputer { }
    Mock Test-PaPath { $script:Scn.Existing -contains $Path }
    Mock New-PaDirectory { }
    Mock Remove-PaPath { }
    Mock Remove-PaEmptyDir { }
    Mock Move-PaItem { }
    Mock Write-PaFile { }
    Mock Save-PaFile { }
    Mock Get-PaFileSha256 {
        if ($script:Scn.HashOverride) { return $script:Scn.HashOverride }
        if ($Path -match 'amd64') { return $script:X64Hash }
        if ($Path -match 'arm64') { return $script:Arm64Hash }
        return ('b' * 64)
    }
    Mock Set-PaRunOnce { }
    Mock Remove-PaRunOnce { }
    Mock Register-PaAutostart { 'task' }
    Mock Unregister-PaAutostart { }
    Mock Set-PaUserPath { $true }
    Mock Start-PaKeepalive { }
    Mock Stop-PaKeepalive { }
    Mock Test-PaHttp { $script:Scn.HttpUp }
    Mock Invoke-WslStream {
        $line = $Arguments -join ' '
        [void]$script:Streams.Add($line)
        if ($line -match ' packages ') { return $script:Scn.PackagesExit }
        if ($line -match 'install\.sh$') { return $script:Scn.InstallExit }
        if ($line -match 'smoke\.sh$') { return $script:Scn.SmokeExit }
        return 0
    }
    Mock Invoke-Wsl {
        $line = $Arguments -join ' '
        [void]$script:Calls.Add($line)
        if ($line -eq '--version') {
            if ($script:Scn.WslReady) {
                return [pscustomobject]@{ ExitCode = 0; Output = ('WSL version: ' + $script:Scn.WslVersion + "`nKernel version: 6.6.87.2-1") }
            }
            return [pscustomobject]@{ ExitCode = 1; Output = 'Usage: wsl.exe [Argument] [Options...]' }
        }
        if ($line -eq '-l -q') {
            if ($script:Scn.DistroExists) { return [pscustomobject]@{ ExitCode = 0; Output = "Ubuntu`nPiAgent" } }
            return [pscustomobject]@{ ExitCode = 1; Output = 'no installed distributions' }
        }
        if ($line -match '/usr/bin/test -f /etc/pi-agent-distro') {
            if ($script:Scn.HasMarker) { return [pscustomobject]@{ ExitCode = 0; Output = '' } }
            return [pscustomobject]@{ ExitCode = 1; Output = '' }
        }
        if ($line -match 'pi-agent/pi-web-port') {
            if ($script:Scn.RecordedPort) { return [pscustomobject]@{ ExitCode = 0; Output = $script:Scn.RecordedPort } }
            return [pscustomobject]@{ ExitCode = 1; Output = 'cat: No such file or directory' }
        }
        if ($line -match 'is-system-running') { return [pscustomobject]@{ ExitCode = 0; Output = $script:Scn.SystemdState } }
        if ($line -match 'wsl-root-setup\.sh configure') { return [pscustomobject]@{ ExitCode = 0; Output = ('some log' + "`n" + 'configured uid=' + $script:Scn.Uid) } }
        if ($line -match 'wsl-root-setup\.sh linger') { return [pscustomobject]@{ ExitCode = 0; Output = ('linger uid=' + $script:Scn.Uid) } }
        if ($line -match '/usr/bin/id -u ') { return [pscustomobject]@{ ExitCode = 0; Output = [string]$script:Scn.Uid } }
        if ($line -match '/bin/cat /etc/wsl\.conf') { return [pscustomobject]@{ ExitCode = 0; Output = $script:Scn.WslConf } }
        if ($line -match '--exec /bin/true$' -and $script:Scn.StartFail) {
            return [pscustomobject]@{ ExitCode = 1; Output = 'Wsl/Service/CreateInstance/CreateVm/HCS/HCS_E_HYPERV_NOT_INSTALLED' }
        }
        if ($line -match '^--export ') { return [pscustomobject]@{ ExitCode = $script:Scn.ExportExit; Output = '' } }
        return [pscustomobject]@{ ExitCode = 0; Output = '' }
    }
}

Describe 'ConvertTo-WslPath' {
    It 'maps a drive path: <Path>' -ForEach @(
        @{ Path = 'C:\Users\tester\bundle.tar.gz'; Want = '/mnt/c/Users/tester/bundle.tar.gz' }
        @{ Path = 'd:\x'; Want = '/mnt/d/x' }
        @{ Path = 'C:/a/b'; Want = '/mnt/c/a/b' }
        @{ Path = 'C:\Users\John Doe\a b.tar'; Want = '/mnt/c/Users/John Doe/a b.tar' }
        @{ Path = 'C:\a\\b\'; Want = '/mnt/c/a/b' }
        @{ Path = 'C:\'; Want = '/mnt/c' }
        @{ Path = '\\?\C:\long\path'; Want = '/mnt/c/long/path' }
    ) {
        ConvertTo-WslPath -Path $Path | Should -Be $Want
    }

    It 'keeps CJK characters' {
        $cjk = -join ([char]0x8CC7, [char]0x6599)
        ConvertTo-WslPath -Path ('D:\' + $cjk + '\x.tar') | Should -Be ('/mnt/d/' + $cjk + '/x.tar')
    }

    It 'rejects UNC and relative paths: <Path>' -ForEach @(
        @{ Path = '\\server\share\x' }
        @{ Path = '\\?\UNC\server\share\x' }
        @{ Path = '\\wsl$\PiAgent\home' }
        @{ Path = 'relative\path' }
    ) {
        { ConvertTo-WslPath -Path $Path } | Should -Throw
    }
}

Describe 'WSL version helpers' {
    It 'reads the version from the English output' {
        Get-WslVersionText -Text "WSL version: 2.5.7.0`nKernel version: 6.6.87.2-1`nWSLg version: 1.0.66" | Should -Be '2.5.7.0'
    }
    It 'reads the version from a localized label' {
        $label = 'WSL ' + (-join ([char]0x7248, [char]0x672C)) + ': 2.5.7.0'
        Get-WslVersionText -Text $label | Should -Be '2.5.7.0'
    }
    It 'accepts three parts' {
        Get-WslVersionText -Text 'WSL version: 2.1.5' | Should -Be '2.1.5'
    }
    It 'returns null when there is no version: <Text>' -ForEach @(
        @{ Text = '' }
        @{ Text = 'Usage: wsl.exe [Argument] [Options...]' }
    ) {
        Get-WslVersionText -Text $Text | Should -BeNullOrEmpty
    }
    It 'compares versions: <Left> vs <Right>' -ForEach @(
        @{ Left = '2.5.7.0'; Right = '2.4.4'; Want = 1 }
        @{ Left = '2.4.4'; Right = '2.4.4.0'; Want = 0 }
        @{ Left = '2.4.3.9'; Right = '2.4.4'; Want = -1 }
        @{ Left = '10.0.0'; Right = '9.9.9.9'; Want = 1 }
    ) {
        Compare-PaVersion -Left $Left -Right $Right | Should -Be $Want
    }
}

Describe 'user PATH string helpers' {
    It 'appends an entry and keeps %VARS% unexpanded' {
        $cur = '%USERPROFILE%\bin;C:\Tools;%LOCALAPPDATA%\Microsoft\WindowsApps'
        Add-PaPathEntry -Current $cur -Entry 'C:\Pi\bin' | Should -Be ($cur + ';C:\Pi\bin')
    }
    It 'is idempotent, case-insensitive and ignores a trailing backslash' {
        $once = Add-PaPathEntry -Current 'C:\Tools' -Entry 'C:\Pi\bin'
        Add-PaPathEntry -Current $once -Entry 'C:\Pi\bin' | Should -Be $once
        Add-PaPathEntry -Current 'c:\pi\BIN\;C:\Tools' -Entry 'C:\Pi\bin' | Should -Be 'c:\pi\BIN\;C:\Tools'
    }
    It 'starts a path from nothing' {
        Add-PaPathEntry -Current '' -Entry 'C:\Pi\bin' | Should -Be 'C:\Pi\bin'
    }
    It 'removes only that entry' {
        Remove-PaPathEntry -Current '%USERPROFILE%\bin;C:\Pi\bin\;C:\Tools' -Entry 'C:\Pi\bin' | Should -Be '%USERPROFILE%\bin;C:\Tools'
    }
    It 'leaves the path alone when the entry is absent' {
        Remove-PaPathEntry -Current 'C:\Tools' -Entry 'C:\Pi\bin' | Should -Be 'C:\Tools'
    }
}

Describe 'small pure helpers' {
    It 'Test-Stamped is true for a stamped table and false for placeholders' {
        Test-Stamped | Should -BeTrue
        $at = [string][char]64
        $ph = $at + $at + 'BUNDLE_URL' + $at + $at
        Set-PaStamp -Stamp @{ Version = '1'; BundleUrl = $ph; BundleSha256 = 'x'; ScriptUrl = 'x'; PiWebUrlX64 = 'x'; PiWebUrlArm64 = 'x' }
        Test-Stamped | Should -BeFalse
    }
    It 'validates distro and user names' {
        Test-PaDistroName -Name 'PiAgent' | Should -BeTrue
        Test-PaDistroName -Name 'bad name' | Should -BeFalse
        Test-PaDistroName -Name '1abc' | Should -BeFalse
        Test-PaLinuxUser -Name 'piagent' | Should -BeTrue
        Test-PaLinuxUser -Name 'Pi' | Should -BeFalse
        Test-PaLinuxUser -Name 'Bad' | Should -BeFalse
        Test-PaLinuxUser -Name 'root' | Should -BeFalse
    }
    It 'picks the rootfs by architecture' {
        (Get-PaRootfsSpec -Arch 'x64').Sha256 | Should -Be $script:X64Hash
        (Get-PaRootfsSpec -Arch 'x64').Url | Should -Match 'amd64\.wsl$'
        (Get-PaRootfsSpec -Arch 'arm64').Sha256 | Should -Be $script:Arm64Hash
        (Get-PaRootfsSpec -Arch 'arm64').Url | Should -Match 'arm64\.wsl$'
    }
    It 'builds the environment for install.sh' {
        $e = Get-PaInstallEnv -Uid 1001 -Port 30141 -Artifact 'https://example.invalid/p.tar.gz'
        $e | Should -Contain 'XDG_RUNTIME_DIR=/run/user/1001'
        $e | Should -Contain 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus'
        $e | Should -Contain 'PI_WEB_PORT=30141'
        $e | Should -Contain 'PI_AGENT_PIWEB_ARTIFACT=https://example.invalid/p.tar.gz'
        (Get-PaInstallEnv -Uid 1001 -Port 30141 -Artifact '') -join ' ' | Should -Not -Match 'PIWEB_ARTIFACT'
    }
    It 'builds the wsl.exe arguments that run a command as the Linux user' {
        $a = Get-PaUserExecArgs -Distro 'PiAgent' -User 'piagent' -Uid 1001 -Port 30141 -Artifact '' -Command @('/bin/bash', './install.sh')
        ($a -join ' ') | Should -Match '^-d PiAgent -u piagent --cd /home/piagent/pi-agent-installer --exec /usr/bin/env '
        ($a -join ' ') | Should -Match '/bin/bash \./install\.sh$'
    }
    It 'parses the uid lines of the Linux side script' {
        Get-PaUidFromOutput -Text "log`nconfigured uid=1001" -Prefix 'configured' | Should -Be 1001
        Get-PaUidFromOutput -Text "linger uid=7`n" -Prefix 'linger' | Should -Be 7
        Get-PaUidFromOutput -Text 'configured uid=abc' -Prefix 'configured' | Should -BeNullOrEmpty
        Get-PaUidFromOutput -Text '' -Prefix 'configured' | Should -BeNullOrEmpty
    }
    It 'parses the smoke test result' {
        $r = Get-PaSmokeResult -Lines @('x', '# RESULT: 24 passed, 1 failed')
        $r.Passed | Should -Be 24
        $r.Failed | Should -Be 1
        Get-PaSmokeResult -Lines @('nothing') | Should -BeNullOrEmpty
    }
    It 'turns wsl.exe output into clean text' {
        $nul = [string][char]0
        $bom = [string][char]0xFEFF
        $err = New-Object System.Management.Automation.ErrorRecord((New-Object System.Exception('boom')), 'id', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $t = ConvertTo-PaCleanText -Lines @(($bom + 'W' + $nul + 'S' + $nul + 'L' + $nul + "`r"), $err)
        $t | Should -Be "WSL`nboom"
    }
    It 'explains a missing virtualization platform' {
        ConvertTo-PaFriendlyWslError -Text 'HCS_E_HYPERV_NOT_INSTALLED' | Should -Match 'virtualization'
        ConvertTo-PaFriendlyWslError -Text 'Error: 0x80370102' | Should -Match 'virtualization'
        ConvertTo-PaFriendlyWslError -Text 'something else' | Should -BeNullOrEmpty
    }
    It 'generates the keep-alive script' {
        $s = New-PaKeepaliveScript -Distro 'PiAgent'
        $s | Should -Match "\`$distro = 'PiAgent'"
        $s | Should -Match 'wsl\.exe -d \$distro --exec /usr/bin/sleep infinity'
        $s | Should -Match 'System\.Threading\.Mutex'
    }
    It 'generates the pi-agent shim' {
        New-PaShimText -Distro 'PiAgent' -User 'piagent' | Should -Be ('@wsl.exe -d PiAgent -u piagent --exec /home/piagent/.local/share/pi-agent/bin/pi-agent %*' + "`r`n")
    }
    It 'generates the Start Menu shortcut' {
        New-PaUrlShortcutText -Port 30142 | Should -Be ('[InternetShortcut]' + "`r`n" + 'URL=http://localhost:30142/' + "`r`n")
    }
    It 'generates a resume stub that re-fetches the script and escapes quotes' {
        $splat = [ordered]@{ Resume = $true; Yes = $true; DistroName = "O'Neil"; Port = 30141 }
        $s = New-PaResumeStub -Splat $splat -Kind 'url' -Source 'https://example.invalid/install-wsl.ps1'
        $s | Should -Match "\`$splat\['Resume'\] = \`$true"
        $s | Should -Match "\`$splat\['DistroName'\] = 'O''Neil'"
        $s | Should -Match "\`$splat\['Port'\] = 30141"
        $s | Should -Match 'RawContentStream'
        $s | Should -Match 'TrimStart\(\[char\]0xFEFF\)'
        $s | Should -Match "Uri 'https://example\.invalid/install-wsl\.ps1'"
        $s | Should -Match 'for \(\$try = 1; \$try -le 24; \$try\+\+\)'
        $s | Should -Match 'run this by hand'
        $s | Should -Match 'PI_AGENT_WSL_NOEXIT'
        $f = New-PaResumeStub -Splat $splat -Kind 'file' -Source 'C:\dev\install-wsl.ps1'
        $f | Should -Match 'ReadAllText\(''C:\\dev\\install-wsl\.ps1'''
        $f | Should -Not -Match 'Invoke-WebRequest'
    }
    It 'fills option defaults and resolves the install directory' {
        $o = New-PaOptions -Bound @{ Yes = $true }
        $o.Yes | Should -BeTrue
        $o.DistroName | Should -Be 'PiAgent'
        $o.LinuxUser | Should -Be 'piagent'
        $o.Port | Should -Be 30141
        $o.PortGiven | Should -BeFalse
        (New-PaOptions -Bound @{ Port = 30142 }).PortGiven | Should -BeTrue
        $o.InstallDir | Should -Be 'C:\Users\tester\AppData\Local\PiAgent'
        (Get-PaPaths -Opts $o).Shim | Should -Be 'C:\Users\tester\AppData\Local\PiAgent\bin\pi-agent.cmd'
    }
}

Describe 'preflight' {
    It 'exits 10 and says why: <Name>' -ForEach @(
        @{ Name = 'Windows build is too old'; Keyword = 'unsupported Windows build'; Apply = { $script:Scn.Info.Build = 18363 } }
        @{ Name = 'the architecture is unsupported'; Keyword = 'unsupported architecture'; Apply = { $script:Scn.Info.Arch = 'x86' } }
        @{ Name = 'this is a 32-bit PowerShell'; Keyword = '32-bit PowerShell'; Apply = { $script:Scn.Info.Is64BitProcess = $false } }
        @{ Name = 'there is too little RAM'; Keyword = 'not enough RAM'; Apply = { $script:Scn.Info.RamGB = 3 } }
        @{ Name = 'there is too little disk space'; Keyword = 'not enough disk space'; Apply = { $script:Scn.Info.FreeDiskGB = 5 } }
        @{ Name = 'the web port is busy'; Keyword = 'port in use'; Apply = { $script:Scn.BusyPorts = @(30141) } }
        @{ Name = 'the paseo port is busy'; Keyword = 'port in use'; Apply = { $script:Scn.BusyPorts = @(6769) } }
        @{ Name = 'the distro name belongs to someone else'; Keyword = 'distro name taken'; Apply = { $script:Scn.DistroExists = $true; $script:Scn.HasMarker = $false } }
        @{ Name = 'the build is unstamped and has no bundle'; Keyword = 'unstamped build needs -BundlePath'; Apply = {
                $at = [string][char]64
                $ph = $at + $at + 'X' + $at + $at
                Set-PaStamp -Stamp @{ Version = $ph; BundleUrl = $ph; BundleSha256 = $ph; ScriptUrl = $ph; PiWebUrlX64 = $ph; PiWebUrlArm64 = $ph }
            }
        }
    ) {
        & $Apply
        $extra = @{}
        if ($Keyword -match 'unstamped') { $extra['BundlePath'] = '' }
        $o = New-TestOpts -Extra $extra
        $rc = Invoke-PaMain -Options $o
        $rc | Should -Be 10
        Get-AllMessages | Should -Match ([regex]::Escape($Keyword))
        (Get-MutatingCalls).Count | Should -Be 0
        Should -Invoke Start-PaElevated -Times 0 -Exactly
        Should -Invoke Write-PaFile -Times 0 -Exactly
    }

    It 'does not complain about the ports when our own distro already has them' {
        $script:Scn.DistroExists = $true
        $script:Scn.HasMarker = $true
        $script:Scn.BusyPorts = @(30141, 6769)
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
    }

    It 'a re-run without -Port keeps the port the install recorded' {
        $script:Scn.DistroExists = $true
        $script:Scn.RecordedPort = '30142'
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        ($script:Streams -join "`n") | Should -Match 'PI_WEB_PORT=30142'
        ($script:Streams -join "`n") | Should -Not -Match 'PI_WEB_PORT=30141'
        Get-AllMessages | Should -Match 'keeping port 30142'
    }

    It 'an explicit -Port wins over the recorded one' {
        $script:Scn.DistroExists = $true
        $script:Scn.RecordedPort = '30142'
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Port = 30150 }) | Should -Be 0
        ($script:Streams -join "`n") | Should -Match 'PI_WEB_PORT=30150'
        Get-AllMessages | Should -Not -Match 'keeping port'
    }

    It 'falls back to the default when the record is not a port: <Bad>' -ForEach @(
        @{ Bad = 'not-a-number' }
        @{ Bad = '80' }
        @{ Bad = '99999' }
        @{ Bad = '99999999999' }
    ) {
        $script:Scn.DistroExists = $true
        $script:Scn.RecordedPort = $Bad
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        ($script:Streams -join "`n") | Should -Match 'PI_WEB_PORT=30141'
    }

    It 'a first install does not ask the Linux for a port' {
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        ($script:Calls -join "`n") | Should -Not -Match 'pi-web-port'
    }

    It 'warns, but goes on, on Windows 10 22H2' {
        $script:Scn.Info.Build = 19045
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        Get-AllMessages | Should -Match 'Windows 10 is not the main target'
    }

    It 'warns, but goes on, with little RAM' {
        $script:Scn.Info.RamGB = 6
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        Get-AllMessages | Should -Match '\[Warn\]'
    }

    It 'rejects a bad distro name and a bad port' {
        Invoke-PaMain -Options (New-TestOpts -Extra @{ DistroName = 'bad name' }) | Should -Be 10
        Get-AllMessages | Should -Match 'invalid distro name'
        Reset-PaMessages
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Port = 80 }) | Should -Be 10
        Get-AllMessages | Should -Match 'invalid port'
        Reset-PaMessages
        Invoke-PaMain -Options (New-TestOpts -Extra @{ LinuxUser = 'root' }) | Should -Be 10
        Get-AllMessages | Should -Match 'invalid Linux user name'
    }

    It 'rejects a bundle or rootfs path that does not exist' {
        $script:Scn.Existing = @()
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 10
        Get-AllMessages | Should -Match 'bundle not found'
    }
}

Describe 'a fresh install' {
    It 'imports the pinned image, then installs, then sets up Windows, and returns 0' {
        $o = New-TestOpts -Extra @{ BundlePath = '' }
        Invoke-PaMain -Options $o | Should -Be 0

        $imp = Get-CallIndex -Pattern '^--import PiAgent C:\\Test\\PiAgent\\distro C:\\Test\\PiAgent\\cache\\ubuntu-24\.04\.5-wsl-amd64\.wsl --version 2$'
        $imp | Should -BeGreaterThan -1
        $term = Get-CallIndex -Pattern '^--terminate PiAgent$'
        $term | Should -BeGreaterThan $imp
        (Get-CallIndex -Pattern 'wsl-root-setup\.sh configure --user piagent --interop on --win-system32 /mnt/c/Windows/System32 --installer-src /opt/pi-agent-installer$') | Should -BeGreaterThan $imp
        (Get-CallIndex -Pattern '/bin/tar -xzf /mnt/c/Test/PiAgent/cache/pi-agent-installer-1\.2\.3\.tar\.gz -C /opt/pi-agent-installer --strip-components=1$') | Should -BeGreaterThan $imp
        (Get-CallIndex -Pattern 'is-system-running --wait$') | Should -BeGreaterThan $term

        Should -Invoke Save-PaFile -Times 1 -Exactly -ParameterFilter { $Url -match 'ubuntu-24\.04\.5-wsl-amd64\.wsl$' }
        Should -Invoke Save-PaFile -Times 1 -Exactly -ParameterFilter { $Url -eq 'https://example.invalid/bundle.tar.gz' }

        $script:Streams.Count | Should -Be 3
        $script:Streams[0] | Should -Match 'wsl-root-setup\.sh packages --user piagent$'
        $inst = $script:Streams[1]
        $inst | Should -Match '^-d PiAgent -u piagent --cd /home/piagent/pi-agent-installer --exec /usr/bin/env '
        $inst | Should -Match 'XDG_RUNTIME_DIR=/run/user/1001'
        $inst | Should -Match 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus'
        $inst | Should -Match 'PI_WEB_PORT=30141'
        $inst | Should -Match 'PI_AGENT_PIWEB_ARTIFACT=https://example\.invalid/piweb-x64\.tar\.gz'
        $inst | Should -Match '/bin/bash \./install\.sh$'
        $script:Streams[2] | Should -Match 'smoke\.sh$'

        Should -Invoke Write-PaFile -ParameterFilter { $Path -match 'keepalive\.ps1$' } -Times 1 -Exactly
        Should -Invoke Write-PaFile -ParameterFilter { $Path -match 'pi-agent\.cmd$' } -Times 1 -Exactly
        Should -Invoke Write-PaFile -ParameterFilter { $Path -match 'Pi Agent\.url$' } -Times 1 -Exactly
        Should -Invoke Start-PaKeepalive -Times 1 -Exactly
        Should -Invoke Register-PaAutostart -Times 1 -Exactly
        Should -Invoke Set-PaUserPath -Times 1 -Exactly -ParameterFilter { $Entry -eq 'C:\Test\PiAgent\bin' }
    }

    It 'uses the arm64 image and the arm64 pi-web build on an ARM64 PC' {
        $script:Scn.Info.Arch = 'arm64'
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        Should -Invoke Save-PaFile -Times 1 -Exactly -ParameterFilter { $Url -match 'ubuntu-24\.04\.5-wsl-arm64\.wsl$' }
        (Get-CallIndex -Pattern '^--import PiAgent .*ubuntu-24\.04\.5-wsl-arm64\.wsl --version 2$') | Should -BeGreaterThan -1
        $script:Streams[1] | Should -Match 'PI_AGENT_PIWEB_ARTIFACT=https://example\.invalid/piweb-arm64\.tar\.gz'
    }

    It 'turns a local pi-web file into a /mnt path' {
        $o = New-TestOpts -Extra @{ PiWebArtifact = 'C:\dl\piweb-0.10.0-linux-x64.tar.gz' }
        Invoke-PaMain -Options $o | Should -Be 0
        $script:Streams[1] | Should -Match 'PI_AGENT_PIWEB_ARTIFACT=/mnt/c/dl/piweb-0\.10\.0-linux-x64\.tar\.gz'
    }

    It 'in dev mode with no pi-web file it warns that pi-web is built from source' {
        $at = [string][char]64
        $ph = $at + $at + 'X' + $at + $at
        Set-PaStamp -Stamp @{ Version = $ph; BundleUrl = $ph; BundleSha256 = $ph; ScriptUrl = $ph; PiWebUrlX64 = $ph; PiWebUrlArm64 = $ph }
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        Get-AllMessages | Should -Match 'dev mode'
        Get-AllMessages | Should -Match 'built from source'
        $script:Streams[1] | Should -Not -Match 'PIWEB_ARTIFACT'
    }

    It 'skips the autostart registration with -NoAutostart but still starts the keep-alive' {
        Invoke-PaMain -Options (New-TestOpts -Extra @{ NoAutostart = $true }) | Should -Be 0
        Should -Invoke Register-PaAutostart -Times 0 -Exactly
        Should -Invoke Start-PaKeepalive -Times 1 -Exactly
    }

    It 'skips the smoke test with -SkipSmoke' {
        Invoke-PaMain -Options (New-TestOpts -Extra @{ SkipSmoke = $true }) | Should -Be 0
        $script:Streams.Count | Should -Be 2
    }

    It 'sends the interop switch to the Linux side' {
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        (Get-CallIndex -Pattern 'configure --user piagent --interop on --win-system32 /mnt/c/Windows/System32 ') | Should -BeGreaterThan -1
    }

    It 'sends --interop off and no --win-system32 with -NoWindowsInterop' {
        Invoke-PaMain -Options (New-TestOpts -Extra @{ NoWindowsInterop = $true }) | Should -Be 0
        $cfg = @($script:Calls | Where-Object { $_ -match 'wsl-root-setup\.sh configure' })
        $cfg.Count | Should -Be 1
        $cfg[0] | Should -Match '--interop off'
        $cfg[0] | Should -Not -Match '--win-system32'
        Get-AllMessages | Should -Not -Match 'NoWindowsInterop'
    }
}

Describe 'running it again' {
    It 'reuses the distro that has the marker: no --import, still refreshes and installs' {
        $script:Scn.DistroExists = $true
        $script:Scn.HasMarker = $true
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        (Get-CallIndex -Pattern '^--import ') | Should -Be -1
        (Get-CallIndex -Pattern 'wsl-root-setup\.sh configure') | Should -BeGreaterThan -1
        (Get-CallIndex -Pattern '^--terminate ') | Should -Be -1
        Should -Invoke Save-PaFile -Times 0 -Exactly
        $script:Streams.Count | Should -Be 3
    }

    It 'restarts the distro only when /etc/wsl.conf changed' {
        $script:Scn.DistroExists = $true
        Mock Invoke-Wsl {
            $line = $Arguments -join ' '
            [void]$script:Calls.Add($line)
            if ($line -eq '--version') { return [pscustomobject]@{ ExitCode = 0; Output = 'WSL version: 2.5.7.0' } }
            if ($line -eq '-l -q') { return [pscustomobject]@{ ExitCode = 0; Output = 'PiAgent' } }
            if ($line -match '/bin/cat /etc/wsl\.conf') {
                $script:CatCount = 1 + [int]$script:CatCount
                return [pscustomobject]@{ ExitCode = 0; Output = ('conf-v' + $script:CatCount) }
            }
            if ($line -match 'wsl-root-setup\.sh configure') { return [pscustomobject]@{ ExitCode = 0; Output = 'configured uid=1001' } }
            if ($line -match 'wsl-root-setup\.sh linger') { return [pscustomobject]@{ ExitCode = 0; Output = 'linger uid=1001' } }
            if ($line -match 'is-system-running') { return [pscustomobject]@{ ExitCode = 0; Output = 'running' } }
            return [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        $script:CatCount = 0
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        (Get-CallIndex -Pattern '^--terminate PiAgent$') | Should -BeGreaterThan -1
    }
}

Describe 'failures on the way' {
    It 'refuses a rootfs whose hash does not match and never imports it' {
        $script:Scn.HashOverride = 'deadbeef'
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 40
        (Get-CallIndex -Pattern '^--import ') | Should -Be -1
        Get-AllMessages | Should -Match 'sha256 mismatch'
        Should -Invoke Save-PaFile -Times 3 -Exactly
    }

    It 'refuses a -RootfsPath whose hash does not match and never imports it' {
        $script:Scn.HashOverride = 'deadbeef'
        $script:Scn.Existing = @('C:\b\bundle.tar.gz', 'C:\dl\ubuntu-amd64.wsl')
        Invoke-PaMain -Options (New-TestOpts -Extra @{ RootfsPath = 'C:\dl\ubuntu-amd64.wsl' }) | Should -Be 40
        (Get-CallIndex -Pattern '^--import ') | Should -Be -1
        Should -Invoke Save-PaFile -Times 0 -Exactly
    }

    It 'accepts a -RootfsPath with the right hash and does not download' {
        $script:Scn.Existing = @('C:\b\bundle.tar.gz', 'C:\dl\ubuntu-amd64.wsl')
        Invoke-PaMain -Options (New-TestOpts -Extra @{ RootfsPath = 'C:\dl\ubuntu-amd64.wsl' }) | Should -Be 0
        (Get-CallIndex -Pattern '^--import PiAgent C:\\Test\\PiAgent\\distro C:\\dl\\ubuntu-amd64\.wsl --version 2$') | Should -BeGreaterThan -1
        Should -Invoke Save-PaFile -Times 0 -Exactly
    }

    It 'explains a distro that cannot start and removes the half-made one' {
        $script:Scn.StartFail = $true
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 40
        Get-AllMessages | Should -Match 'virtualization'
        @($script:Calls | Where-Object { $_ -match '^--unregister PiAgent$' }).Count | Should -Be 1
    }

    It 'stops when systemd does not come up' {
        $script:Scn.SystemdState = 'offline'
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 40
        Get-AllMessages | Should -Match 'systemd did not start'
        $script:Streams.Count | Should -Be 0
    }

    It 'returns 40 when the Linux packages fail' {
        $script:Scn.PackagesExit = 100
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 40
        Get-AllMessages | Should -Match 'packages failed'
    }

    It 'returns 50 when install.sh fails' {
        $script:Scn.InstallExit = 1
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 50
        Get-AllMessages | Should -Match 'install\.sh failed'
        Should -Invoke Write-PaFile -Times 0 -Exactly -ParameterFilter { $Path -match 'keepalive' }
    }

    It 'returns 60 when the Windows side cannot be set up' {
        Mock Set-PaUserPath { throw 'registry is read-only' }
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 60
        Get-AllMessages | Should -Match 'integration failed'
    }

    It 'returns 70 when pi-web never answers' {
        $script:Scn.HttpUp = $false
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 70
        Get-AllMessages | Should -Match 'no answer from pi-web'
        $script:Streams.Count | Should -Be 2
    }

    It 'returns 70 when the smoke test fails' {
        $script:Scn.SmokeExit = 1
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 70
        Get-AllMessages | Should -Match 'smoke test failed'
    }
}

Describe 'WSL itself' {
    It 'asks for administrator rights only when WSL is not ready' {
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 0
        Should -Invoke Start-PaElevated -Times 0 -Exactly
    }

    It 'treats an old WSL as not ready' {
        $script:Scn.WslVersion = '2.1.5.0'
        $script:Scn.ReadyAfterElevated = $true
        $script:Scn.WslReady = $true
        $info = Get-WslInfo
        $info.Ready | Should -BeFalse
        $info.Version | Should -Be '2.1.5.0'
    }

    It 'registers a resume job and returns 20 when a reboot is pending' {
        $script:Scn.WslReady = $false
        $script:Scn.ReadyAfterElevated = $true
        $script:Scn.RebootPending = $true
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 20
        Should -Invoke Start-PaElevated -Times 1 -Exactly
        Should -Invoke Write-PaFile -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Test\PiAgent\resume.ps1' -and $Bom }
        Should -Invoke Set-PaRunOnce -Times 1 -Exactly -ParameterFilter { $Name -eq 'PiAgentWslResume' -and $Command -match 'resume\.ps1"$' -and $Command.Length -lt 260 }
        Should -Invoke Restart-PaComputer -Times 0 -Exactly
        (Get-CallIndex -Pattern '^--import ') | Should -Be -1
    }

    It 'points the resume stub at the stamped script URL' {
        $script:Scn.WslReady = $false
        $script:Scn.RebootPending = $true
        Invoke-PaMain -Options (New-TestOpts -Extra @{ NoWindowsInterop = $true }) | Should -Be 20
        Should -Invoke Write-PaFile -Times 1 -Exactly -ParameterFilter {
            $Path -match 'resume\.ps1$' -and $Text -match 'https://example\.invalid/install-wsl\.ps1' -and $Text -match "NoWindowsInterop'\] = \`$true" -and $Text -match "\`$splat\['Resume'\] = \`$true"
        }
    }

    It 'also asks for a reboot when WSL installed fine but is still not ready' {
        $script:Scn.WslReady = $false
        $script:Scn.ReadyAfterElevated = $false
        $script:Scn.RebootPending = $false
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 20
    }

    It 'restarts only when the user says yes' {
        $script:Scn.WslReady = $false
        $script:Scn.RebootPending = $true
        $script:Scn.Answer = 'y'
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Yes = $false }) | Should -Be 20
        Should -Invoke Restart-PaComputer -Times 1 -Exactly
    }

    It 'never restarts by itself with -Yes' {
        $script:Scn.WslReady = $false
        $script:Scn.RebootPending = $true
        $script:Scn.Answer = 'y'
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Yes = $true }) | Should -Be 20
        Should -Invoke Restart-PaComputer -Times 0 -Exactly
    }

    It 'returns 30 when the install fails without a pending reboot' {
        $script:Scn.WslReady = $false
        $script:Scn.ReadyAfterElevated = $false
        $script:Scn.ElevatedExit = 5
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 30
        Get-AllMessages | Should -Match 'wsl --install failed'
    }

    It 'returns 30 when the administrator prompt is declined' {
        $script:Scn.WslReady = $false
        $script:Scn.ElevatedThrows = $true
        Invoke-PaMain -Options (New-TestOpts) | Should -Be 30
        Get-AllMessages | Should -Match 'administrator rights needed'
    }

    It 'returns 30 when WSL is still not ready after the resumed install' {
        $script:Scn.WslReady = $false
        $script:Scn.ReadyAfterElevated = $false
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Resume = $true }) | Should -Be 30
        Get-AllMessages | Should -Match 'still not ready after reboot'
        Should -Invoke Remove-PaRunOnce -Times 1 -Exactly -ParameterFilter { $Name -eq 'PiAgentWslResume' }
    }

    It 'continues normally after a reboot when WSL is ready' {
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Resume = $true }) | Should -Be 0
        Should -Invoke Remove-PaRunOnce -Times 1 -Exactly
    }
}

Describe 'dry run' {
    It 'checks for real and changes nothing on a fresh machine' {
        $script:Scn.WslReady = $false
        $script:Scn.DistroExists = $false
        Invoke-PaMain -Options (New-TestOpts -Extra @{ DryRun = $true }) | Should -Be 0

        @($script:Calls | Where-Object { $_ -notmatch '^(--version|-l -q)$' }).Count | Should -Be 0
        (Get-MutatingCalls).Count | Should -Be 0
        Get-AllMessages | Should -Match '\[Dry\] would'
        foreach ($name in 'Start-PaElevated', 'Invoke-WslStream', 'Write-PaFile', 'New-PaDirectory', 'Save-PaFile', 'Set-PaRunOnce', 'Remove-PaRunOnce', 'Register-PaAutostart', 'Set-PaUserPath', 'Start-PaKeepalive', 'Stop-PaKeepalive', 'Remove-PaPath', 'Move-PaItem', 'Restart-PaComputer') {
            Should -Invoke -CommandName $name -Times 0 -Exactly
        }
    }

    It 'changes nothing with an existing distro either' {
        $script:Scn.DistroExists = $true
        $script:Scn.HasMarker = $true
        Invoke-PaMain -Options (New-TestOpts -Extra @{ DryRun = $true }) | Should -Be 0
        (Get-CallIndex -Pattern 'wsl-root-setup') | Should -Be -1
        (Get-MutatingCalls).Count | Should -Be 0
        Should -Invoke Invoke-WslStream -Times 0 -Exactly
        Should -Invoke Write-PaFile -Times 0 -Exactly
    }

    It 'still stops at a failed check' {
        $script:Scn.Info.Build = 18363
        Invoke-PaMain -Options (New-TestOpts -Extra @{ DryRun = $true }) | Should -Be 10
    }

    It 'does not uninstall anything either' {
        $script:Scn.DistroExists = $true
        Invoke-PaMain -Options (New-TestOpts -Extra @{ DryRun = $true; Uninstall = $true; PurgeData = $true }) | Should -Be 0
        (Get-MutatingCalls).Count | Should -Be 0
        Should -Invoke Stop-PaKeepalive -Times 0 -Exactly
        Should -Invoke Remove-PaPath -Times 0 -Exactly
        Should -Invoke Unregister-PaAutostart -Times 0 -Exactly
    }
}

Describe 'uninstall' {
    BeforeEach {
        $script:Scn.DistroExists = $true
        $script:Scn.HasMarker = $true
    }

    It 'removes the Windows side, keeps the distro and its data, and never exports or unregisters' {
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Uninstall = $true }) | Should -Be 0
        (Get-CallIndex -Pattern '^--unregister ') | Should -Be -1
        (Get-CallIndex -Pattern '^--export ') | Should -Be -1
        (Get-CallIndex -Pattern 'pi-agent/bin/pi-agent stop$') | Should -BeGreaterThan -1
        (Get-CallIndex -Pattern '^--terminate PiAgent$') | Should -BeGreaterThan -1
        Should -Invoke Stop-PaKeepalive -Times 1 -Exactly
        Should -Invoke Unregister-PaAutostart -Times 1 -Exactly
        Should -Invoke Remove-PaRunOnce -Times 1 -Exactly
        Should -Invoke Set-PaUserPath -Times 1 -Exactly -ParameterFilter { $Entry -eq 'C:\Test\PiAgent\bin' -and $Remove }
        Should -Invoke Remove-PaPath -Times 1 -Exactly -ParameterFilter { $Path -match 'Pi Agent\.url$' }
        Should -Invoke Remove-PaPath -Times 0 -Exactly -ParameterFilter { $Path -eq 'C:\Test\PiAgent' }
        Should -Invoke Remove-PaPath -Times 0 -Exactly -ParameterFilter { $Path -match 'distro' }
    }

    It 'turns the Pi Agent service off in the Linux, so starting the distro later does not bring it back' {
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Uninstall = $true }) | Should -Be 0
        (Get-CallIndex -Pattern 'XDG_RUNTIME_DIR=/run/user/1001 .*systemctl --user disable --now pi-web\.service$') | Should -BeGreaterThan -1
    }

    It 'with -PurgeData but no such Linux, never touches the distro folder (it may still hold a registered disk)' {
        $script:Scn.DistroExists = $false
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Uninstall = $true; PurgeData = $true }) | Should -Be 0
        (Get-CallIndex -Pattern '^--unregister ') | Should -Be -1
        Should -Invoke Remove-PaPath -Times 0 -Exactly -ParameterFilter { $Path -match 'distro$' }
    }

    It 'with -PurgeData exports first, then unregisters, then removes what it put in the install directory, never the directory itself recursively' {
        $script:Scn.Existing = @('C:\Users\tester\PiAgent-backup-20261103-1200.tar')
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Uninstall = $true; PurgeData = $true }) | Should -Be 0
        $exp = Get-CallIndex -Pattern '^--export PiAgent C:\\Users\\tester\\PiAgent-backup-20261103-1200\.tar$'
        $unreg = Get-CallIndex -Pattern '^--unregister PiAgent$'
        $exp | Should -BeGreaterThan -1
        $unreg | Should -BeGreaterThan $exp
        Should -Invoke Remove-PaPath -Times 0 -Exactly -ParameterFilter { $Path -eq 'C:\Test\PiAgent' }
        Should -Invoke Remove-PaPath -Times 1 -ParameterFilter { $Path -match 'distro$' }
        Should -Invoke Remove-PaEmptyDir -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Test\PiAgent' }
    }

    It 'refuses -PurgeData for a Linux this installer did not create, and touches nothing' {
        $script:Scn.HasMarker = $false
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Uninstall = $true; PurgeData = $true }) | Should -Be 3
        (Get-CallIndex -Pattern '^--export ') | Should -Be -1
        (Get-CallIndex -Pattern '^--unregister ') | Should -Be -1
        (Get-CallIndex -Pattern '^--terminate ') | Should -Be -1
        Get-AllMessages | Should -Match 'not created by this installer'
    }

    It 'does not delete anything when the backup fails' {
        $script:Scn.ExportExit = 1
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Uninstall = $true; PurgeData = $true }) | Should -Be 40
        (Get-CallIndex -Pattern '^--unregister ') | Should -Be -1
        Get-AllMessages | Should -Match 'backup failed'
    }

    It 'does not delete anything when the backup file is missing' {
        $script:Scn.Existing = @()
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Uninstall = $true; PurgeData = $true }) | Should -Be 40
        (Get-CallIndex -Pattern '^--unregister ') | Should -Be -1
    }

    It 'asks the user to type the distro name and cancels on anything else' {
        $script:Scn.Existing = @('C:\Users\tester\PiAgent-backup-20261103-1200.tar')
        $script:Scn.Answer = 'nope'
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Uninstall = $true; PurgeData = $true; Yes = $false }) | Should -Be 2
        (Get-CallIndex -Pattern '^--export ') | Should -BeGreaterThan -1
        (Get-CallIndex -Pattern '^--unregister ') | Should -Be -1
    }

    It 'goes on when the typed name is right' {
        $script:Scn.Existing = @('C:\Users\tester\PiAgent-backup-20261103-1200.tar')
        $script:Scn.Answer = 'PiAgent'
        Invoke-PaMain -Options (New-TestOpts -Extra @{ Uninstall = $true; PurgeData = $true; Yes = $false }) | Should -Be 0
        (Get-CallIndex -Pattern '^--unregister PiAgent$') | Should -BeGreaterThan -1
    }
}

Describe 'the install directory' {
    It 'is the folder that holds PiAgent, so a delete never reaches the user other folders: <Given>' -ForEach @(
        @{ Given = 'D:\'; Want = 'D:\PiAgent' }
        @{ Given = 'D:\Data'; Want = 'D:\Data\PiAgent' }
        @{ Given = 'D:\Apps\PiAgent'; Want = 'D:\Apps\PiAgent' }
        @{ Given = 'D:\Apps\piagent\'; Want = 'D:\Apps\piagent' }
    ) {
        (New-PaOptions -Bound @{ InstallDir = $Given }).InstallDir | Should -Be $Want
    }
}

Describe 'Remove-PaEmptyDir' {
    It 'removes an empty directory and leaves one that holds files' {
        $empty = Join-Path $TestDrive 'empty'
        $full = Join-Path $TestDrive 'full'
        New-Item -ItemType Directory -Path $empty | Out-Null
        New-Item -ItemType Directory -Path $full | Out-Null
        Set-Content -LiteralPath (Join-Path $full 'keep.txt') -Value 'x'
        & $script:RealRemoveEmptyDir -Path $empty
        & $script:RealRemoveEmptyDir -Path $full
        Test-Path -LiteralPath $empty | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $full 'keep.txt') | Should -BeTrue
    }
}

Describe 'the final message' {
    It 'gives the one-line command for removal when no install-wsl.ps1 is on the machine' {
        Set-PaStamp -Stamp @{ Version = '1.2.3'; BundleUrl = 'https://example.invalid/b.tar.gz'; BundleSha256 = ('b' * 64); ScriptUrl = 'https://example.invalid/install-wsl.ps1'; PiWebUrlX64 = 'x'; PiWebUrlArm64 = 'x' }
        Show-PaNextSteps -Opts (New-TestOpts)
        $m = Get-AllMessages
        $m | Should -Match 'Invoke-WebRequest'
        $m | Should -Match 'example\.invalid/install-wsl\.ps1'
        $m | Should -Match '-Uninstall'
    }
}
}
