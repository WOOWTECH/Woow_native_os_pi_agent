v0.3.0-rc.2 — the Windows (WSL2) preview, now also a file to double-click

A preview, not the latest release: v0.2.4 stays what releases/latest gives, and nothing changes for
macOS or Linux. This release has no macOS .pkg; on a Mac, stay on v0.2.4.

Since v0.3.0-rc.1

  - Install-Pi-Agent.cmd: download it from the release page and double-click it. It does the same as the
    command in docs/WSL2.md and stays open on the result. It is not code-signed, so Windows warns about
    it: More info, then Run anyway. It is plain text you can read first.
  - The installer no longer leaves WSL_UTF8 set in the PowerShell window it ran in.

What it adds to v0.2.4

  One command or one double-click sets up a dedicated WSL2 Ubuntu, installs the Linux version of Pi Agent
  in it and starts it when you sign in to Windows. Pi, Claude Code and Codex run as they do on Linux, and
  can reach PowerShell and Windows programs through pi-agent-win. docs/WSL2.md has the options, what it
  changes and how to remove it.

What you should know first

  - The real PC it was tested on blue-screened once (0x133 DPC_WATCHDOG_VIOLATION). The dump points at
    that PC's USB Wi-Fi driver (rtwlanu6.sys), not at a WSL component, though an indirect link cannot be
    ruled out. Save your work first. On USB Wi-Fi, update the adapter's driver or use a cable.
  - Tried on GitHub-hosted Windows Server 2025 and on one real Windows 10 22H2 PC. Not yet tried: Windows 11
    on real hardware, first-time WSL enablement with its reboot, double-clicking the file on a real PC,
    signing out and in, sleep, ARM64.
  - Inside Omnigent, Codex's automatic reviewer lets its Windows commands out of its sandbox without
    asking you. In a terminal it asks for each one.
  - Linux starts only after someone signs in to Windows.
  - Pi's ChatGPT login failed on that PC (invalid_grant, cause unknown); a LiteLLM gateway works.
