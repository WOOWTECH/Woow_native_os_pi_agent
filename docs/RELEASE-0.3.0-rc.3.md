v0.3.0-rc.3 — the Windows (WSL2) preview, with what a Windows 11 virtual machine turned up

A preview, not the latest release: v0.2.4 stays what releases/latest gives, and nothing changes for
macOS or Linux. This release has no macOS .pkg; on a Mac, stay on v0.2.4.

Since v0.3.0-rc.2 (all of it found by running the installer on Windows 11 for the first time)

  - At every sign-in on Windows 11 a Windows Terminal window titled powershell.exe stayed open on the
    desktop. It was the keep-alive, and closing it stopped the Linux. The keep-alive now starts through
    conhost.exe --headless and leaves no window; the installer checks that it came up and falls back to
    the old command line if this PC does not accept the new one. If you installed rc.1 or rc.2, run the
    same install again.
  - On a PC without WSL the screen sat still for 2 minutes at the start: Windows 11's built-in wsl.exe was
    waiting for a key press nobody could see. Fixed.
  - Text from the Linux install no longer walks across the window in Windows Terminal.
  - If WSL times out starting its virtual machine (a busy PC, just after a restart), the installer waits a
    minute and tries once more, then says what to do.
  - If WSL could not start the Linux "PiAgent" (for example virtualization is off), the installer called it
    "not created by this installer" and suggested wsl --unregister, which deletes that Linux and its data.
    It now says why it cannot start and tells you not to delete it.
  - The warnings the double-click file triggers are described as they really appear (Edge: Keep; Windows:
    Run), with what to do when Smart App Control blocks the file.

What you should know first

  - The real PC it was tested on blue-screened once (0x133 DPC_WATCHDOG_VIOLATION). The dump points at that
    PC's USB Wi-Fi driver (rtwlanu6.sys), not at a WSL component, though an indirect link cannot be ruled
    out. Save your work first. On USB Wi-Fi, update the adapter's driver or use a cable.
  - Tried on GitHub-hosted Windows Server 2025, on one real Windows 10 22H2 PC, and in a Windows 11 virtual
    machine (double-click, the first WSL enable with its reboot, signing out and in, restarting). Not yet
    tried: Windows 11 on real hardware, the whole install on Windows 11, sleep and wake, WSL2 on ARM64.
  - Inside Omnigent, Codex's automatic reviewer lets its Windows commands out of its sandbox without
    asking you. In a terminal it asks for each one.
  - Linux starts only after someone signs in to Windows.
  - Pi's ChatGPT login failed on the real PC (invalid_grant, cause unknown); a LiteLLM gateway works.
