---
name: windows-from-wsl
description: Run PowerShell, start Windows programs and reach Windows files from this WSL2 Linux. Use when the user asks for anything on Windows or on this PC, such as PowerShell, Notepad or another Windows app, a C:\ path, or the Windows desktop.
---

# Windows from this WSL2 Linux

This Linux runs inside a Windows PC. Windows programs can be started from here, and they
run with the rights of the Windows user who is signed in.

| To | Run |
|---|---|
| Run PowerShell, output in UTF-8 | `pi-agent-win ps '<script>'` (single quotes, so Linux leaves `$` alone) |
| Start a program and get its process ID | `pi-agent-win ps 'Start-Process notepad.exe -PassThru \| Select-Object -ExpandProperty Id'` |
| Open a URL or a file with the default program | `pi-agent-win open <url-or-path>` |
| Run a Windows program and wait for it | `pi-agent-win run <program.exe> [args]` |
| Find out why Windows cannot be reached | `pi-agent-win doctor` |

Windows drives are under `/mnt`, so `C:\Users` is `/mnt/c/Users`. Windows can have a redirected
Desktop: ask for it with `[Environment]::GetFolderPath('Desktop')`.

## When a sandbox is in the way

Codex runs its commands in a sandbox that blocks the connection to Windows. It shows up as
`UtilBindVsockAnyPort: socket failed 1`, or as `pi-agent-win` saying a sandbox blocks it or that no
interop channel works. **That does not mean Windows cannot be reached.** Ask to run the same command
outside the sandbox, with a one-line reason, so the person can approve it. If the session does not
allow asking, tell the person that a Codex sandbox setting is what stopped it.

## This is someone's computer

- Stop only processes you started, by the process ID you got when you started them. Never stop a
  process by name: the person may have the same program open.
- Do not change settings, and do not delete or overwrite files you did not create, unless asked to.
- Prefer a read-only command when it answers the question.
