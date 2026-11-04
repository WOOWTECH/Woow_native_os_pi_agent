v0.3.0-rc.1 — a preview of the Windows (WSL2) installer

A preview, not the latest release: v0.2.4 stays what releases/latest gives, and nothing changes for
macOS or Linux. This release has no macOS .pkg; on a Mac, stay on v0.2.4.

What it adds

  One PowerShell command sets up a dedicated WSL2 Ubuntu, installs the Linux version of Pi Agent in it
  and starts it when you sign in to Windows. Pi, Claude Code and Codex run as they do on Linux, and
  can reach PowerShell and Windows programs through pi-agent-win. docs/WSL2.md has the command, the
  options, what it changes and how to remove it.

What it has been tried on

  - GitHub-hosted Windows Server 2025 (WSL 3.0.3): install, self-check 24/24, keep-alive with a
    control, re-run, both uninstalls, on every push.
  - A real Omnigent server from there: conversations and model switches for Claude Code and Codex, the
    Paseo web app, agents driving PowerShell, Notepad, Edge and files.
  - One real Windows 10 22H2 PC (7.9 GB, in daily use): install, self-check 24/24, Pi on a LiteLLM
    gateway, Claude Code and Codex each chatting, switching model and driving PowerShell and Notepad
    through Omnigent, and coming back by itself after a reboot and sign-in.

What you should know first

  - That PC blue-screened once during the test (0x133 DPC_WATCHDOG_VIOLATION) with about 0.3 GB of
    memory free. The cause is not known and a link to the test cannot be ruled out. Save your work
    first, and be careful on a machine with 8 GB.
  - Not yet tried: Windows 11 on real hardware, first-time WSL enablement with its reboot, signing out
    and in, sleep, ARM64.
  - Inside Omnigent, Codex's automatic reviewer lets its Windows commands out of its sandbox without
    asking you. In a terminal it asks for each one.
  - Linux starts only after someone signs in to Windows.
  - Pi's ChatGPT login failed on that PC (invalid_grant, cause unknown); a LiteLLM gateway works.
