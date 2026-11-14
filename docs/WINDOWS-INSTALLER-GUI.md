# Windows installer GUI candidate (2026-11-14)

This is an unpublished implementation candidate based on `1f61cdf` from
`origin/release/0.3.0-rc.6` (including the rc.7 signing changes). It does not
change the macOS builder or shared `install.sh`. `origin/main` was compared:
its Windows WSL2 installer/signing files are absent, and it has separate macOS
and runtime changes. No cross-platform merge is part of this branch.

Double-click the signed EXE without arguments to show a WinForms window. Click
Start to install, watch real installer stages and streamed output, and open the
local web page after successful verification. The URL comes from the installer's
final port (including an existing installation's recorded port), never a launcher
default. Failed attempts show the exit code and offer log viewing and retry.
Logs persist under `%LOCALAPPDATA%\PiAgent\launcher-logs\`, one file per attempt;
the normal installer log still exists. Closing before Start returns 2. Closing
while running is blocked so an accidental click cannot leave an orphaned install.

Explicit GUI mode accepts the existing installer arguments, including private
candidate assets, without modifying the signed PS1:

```powershell
.\Install-Pi-Agent.exe -Gui -BundlePath 'C:\QA assets\pi-agent-installer-CANDIDATE.tar.gz' -PiWebArtifact 'C:\QA assets\pi-web-linux-x64.tar.gz' -Port 43210
.\Install-Pi-Agent.exe -Gui -DryRun -BundlePath 'C:\QA assets\pi-agent-installer-CANDIDATE.tar.gz'
```

Use the bundle from the **same signing build**. A stamped installer's local
`-BundlePath` must now match its embedded SHA-256, just like a downloaded bundle;
a mismatched candidate fails before distro import. Unstamped source development
retains its explicit dev-mode behavior. `-PiWebArtifact` still uses the existing
shared installer behavior: HTTP(S) assets require the published checksum; local
prebuilt paths are trusted inputs and must be checksum/provenance-verified by the
coordinator before use. The shared installer is unchanged. No existing signature,
publisher, hash, or provenance checks are disabled.

The GUI adds `-Yes` only after the user clicks Start and runs PowerShell with
`-NonInteractive`, redirected UTF-8 stdout/stderr and closed stdin. Unexpected
prompts fail instead of hanging invisibly. WSL's existing UAC flow is unchanged.
GUI uninstall/purge options (including abbreviations) are rejected; use the CLI
for its existing destructive confirmation flow. GUI does not reboot the machine.
If exit code 20 requests a reboot, save work, reboot yourself, then invoke the
**same EXE with the same arguments** again. GUI deliberately does not register
a URL-based RunOnce continuation, because an unpublished candidate's URL may not
exist. CLI reboot continuation is unchanged. DryRun never enables Open Web.

## Signer handoff

Synchronize `windows/Launcher.cs` byte-for-byte to the smart repo's
`scripts/pi-agent-signing/Launcher.cs`. This is handled by the coordinator.

- Continue using .NET Framework 4.x `csc.exe`, `/target:exe`, `/platform:anycpu`,
  `/optimize+`. Add `/reference:System.Windows.Forms.dll` and
  `/reference:System.Drawing.dll`. No NuGet/runtime download is needed on Windows.
- Main is `[STAThread]`. Keep `/target:exe`, **not winexe**: shells and CI retain
  synchronous waiting, inherited console streams and exact native exit codes.
  GUI frees its console only when the launcher is its sole process; a caller's
  shared console is preserved. Explorer may show a brief console flash on start.
- The only embedded resource remains `/resource:<signed-ps1>,install-wsl.ps1`.
  No icons, additional resources, manifests or executable payloads are required.
- Runtime signature/publisher validation occurs before execution. The same
  extracted script stays open with `FileShare.Read` through child exit and output
  draining. Retry repeats extraction and verification. Build-time validation stays.
- PS1 now emits GUI stage and verified-endpoint records only in the child process
  with `PI_AGENT_LAUNCHER_GUI=1`. The launcher clears that variable in CLI mode.

## Validation

Local Linux validation uses isolated Mono + Xvfb to compile the actual launcher
and run `windows/tests/Launcher.Tests.cs` (UI state and URL restrictions). This
checks managed code and forms, **not** Windows Authenticode, WSL, UAC or Explorer.
`tests/windows-gui-contract.ps1` checks source behavior without Windows side effects
(11 checks: candidate hashes, stage/readiness output and manual reboot).
`bash tests/wsl.sh bundle` passed 46/46 packaging checks. Windows runs remain required:

```powershell
# Disposable Windows runner: existing suite creates/removes temporary test certs.
.\tests\windows-signing.ps1
# Included by the signing suite; can also run separately without certificates:
.\tests\windows-launcher-ui.ps1
# Existing Pester 5 suite plus GUI event/candidate checksum tests:
Invoke-Pester -Path windows/tests -Output Detailed
```

The signing suite additionally tests the GUI worker's output/error draining,
argument fidelity, exit code and fixed-byte lock, plus rejection of unsigned,
tampered and wrong-publisher embedded scripts. UI tests cover stage display,
nondefault ports, failure/retry, reboot, dry run and missing/unsafe endpoints.

For the coordinator's signed candidate acceptance, use a standard desktop user:

1. Verify final EXE/PS1 signatures and artifact provenance using the existing
   verifier. Run CLI `-DryRun` and confirm output and exit code, also from PS7.
2. Double-click without arguments: actual GUI appears, closing before Start
   changes nothing. Start shows live steps and UTF-8 output; window stays responsive.
3. Run `-Gui` with the private candidate bundle/prebuilt asset. Verify their
   spaces-containing paths survive, hash mismatch fails, and a failure's log opens.
   Correct a transient failure and Retry: a new log and signature check occur.
4. Install/reinstall with a nondefault port; Open Web must use that final port.
   DryRun and failed verification must not enable Open Web.
5. On a WSL-absent machine, exercise UAC approval/cancellation and code 20.
   No automatic reboot/URL download continuation; rerun the same candidate after
   reboot and complete installation. Confirm the normal existing autostart works.
6. Confirm GUI rejects uninstall/purge and CLI retains its previous confirmation
   and exit behavior. Do not publish a release as part of this acceptance.
