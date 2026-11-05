v0.2.6 — Pi's models on a fresh install, and no false alarm after a pi-web restart on a Mac

Two wrong states left in v0.2.5, both seen while upgrading two Intel Macs to it. Neither is Intel-specific in the
code. No pinned version changes: pi-web, Claude Code, Codex, Omnigent and the plugins are what v0.2.5 installs.

Downloads

  - WoowPiAgent-0.2.6-macos-x64.pkg      Intel Macs
  - WoowPiAgent-0.2.6-macos-arm64.pkg    Apple silicon
  - piweb-0.10.0-<os>-<arch>.tar.gz      the prebuilt pi-web trees; each pkg pins its own

  CI builds and attaches the trees. The pkgs are signed and notarized on the maintainer's Mac and attached after that.

What was wrong, and the fix

  - A fresh install showed no Pi models in Omnigent. `pi-omnigent catalog` said pi: ready=false, 0 models next to
    claude and codex, while `pi --list-models` listed them all and `pi auth check` said ready. The model-options patch
    has to be on disk before the Omnigent host starts, because the host loads the module once and keeps it, and a
    pi-web restart does not restart the host. pi-web-start.sh applied it at every start but had to skip it while the
    plugin's omnigent did not exist, which on a fresh install is 10 to 76 s after that step. Now the plugin runs the
    patch itself, right after its own `uv tool install` and before it looks at the result, whichever process installs.
    (omnigent-plugin-model-options-hook-patch.mjs; docs/OPERATIONS-GOTCHAS.md section 21.)
  - Every pi-web restart on a Mac ended in phase `error`, HOST_PROCESS_MISSING, while the host stayed connected under
    the same pid, until `pi-omnigent repair` was run by hand. The plugin checks that by reading /proc/<pid>, and macOS
    has no /proc. The darwin patch now applies that check only where /proc exists; the server's answer decides, and a
    host that never comes back still ends in HOST_CONNECT_TIMEOUT. No process identity is emulated, and the check
    before a signal in `disconnect` is unchanged. (docs/OPERATIONS-GOTCHAS.md section 6.)

If you already installed

  1. An install whose Pi shows no models in Omnigent keeps that until its host restarts: a running host keeps the
     module it loaded, and installing this release does not restart it. Check with `pi-omnigent catalog`. To fix it,
     stop the `omnigent host` process and its `_zygote` child, then `pi-omnigent repair` (section 21). Every session on
     that host is interrupted, so pick the moment. An install whose Pi lists its models needs nothing.
  2. If you linked $PI_AGENT_HOME/bin/omnigent by hand on an Intel Mac, see docs/RELEASE-0.2.5.md.

Seen, not fixed

  - At a load average near 50 on 4 cores, one first boot's prepare() threw, boot.json said `"phase": "error"`, and
    omnigent was not installed 6 minutes later; nothing retries. At load 7 the same install worked. boot() swallows the
    exception, so the cause is suspected (locked()'s 5 s limit for its helper), not proven. Connecting from Settings ->
    Omnigent, or `pi-omnigent connect`, installs omnigent anyway, and the fix above runs there too.

Found after the release

  - On a Mac without the Command Line Tools the "install the command line developer tools?" dialog does appear, although
    the README said it does not. Nothing waits for the answer and nothing fails. There are two causes:
      - Once, during the install: uv renames libpython with `install_name_tool`, and without the tools that is a stub.
        Fixed after this release: the omnigent stage gives that one call a stand-in.
      - Whenever Claude Code starts to work, from then on: it runs `git` three times, and a connected Omnigent host
        starts `claude` by itself every 3 minutes. So on a connected Mac the dialog comes back within 3 minutes of each
        Cancel, until the tools are installed. Clicking Install ends it for good. Not fixed.
    (docs/MACOS.md, Host requirements.)
  - The pkg has no title. `installer` prints `Package name is ` with nothing after it, and `installer -pkginfo` prints
    nothing. Fixed after this release, in the builder.

Measured after the release (2026-11-05), with the published x64 pkg

  - `sudo installer` over an install, a download with quarantine set: Gatekeeper accepted it as Notarized Developer ID, and
    it exited 0 in 165 s on the MacBook Pro (macOS 13.7.8) and 223 s on the MacBook Air (15.4.1). Receipt 0.2.6, the payload
    root-owned in /usr/local/lib/woow-pi-agent, the postinstall's install.sh exit=0, the installed files owned by the
    user, catalog unchanged (claude 4, codex 3, pi 85).
  - A reply running through the upgrade, on the MacBook Air. Claude's Bash tool wrote a heartbeat every second for 420 s
    while `sudo installer` ran for 283 s: the longest gap was 2 s, the reply arrived, and the host, its tmux server and
    claude kept their pids. Phase needs-verification, no issue. On the MacBook Pro a session's tmux server and claude kept
    their pids through the same upgrade.
  - From zero, without the Command Line Tools, on the MacBook Air: the install, its plist, the npm cache, the payload, the
    receipt and the tools moved away, `/usr/bin/git` answering "No developer tools were found, requesting install".
    `sudo installer` exited 0 in 227 s and compiled nothing. The plugin's own omnigent came with cryptography 48.0.1 and
    argon2-cffi-bindings 25.1.0. Phase needs-login, dependencies ok, no issue. The dialog came up once, as above. In two
    repeat runs of the same payload, the Pi patch was on that omnigent when the first boot finished (4 list-models matches).
  - With the tools away and a logged-in install, real sessions with Claude, Codex and Pi each ran a command through
    their own tool and replied, in 14 to 28 s.
  - Every time the install was put back after those runs the host really was gone, and the plugin started a new one:
    connected within 30 s, no issue, catalog unchanged. So the no-/proc edit does not stop a dead host from coming back.

Not verified, and limits

  - tests/session-home-macos.sh and tests/smoke.sh over this tree: they use real launchd jobs or restart the service,
    and the Mac available was in use.
  - Apple silicon: the new paths are covered by tests with stand-ins, not by a run on an Apple silicon Mac.
  - Installer.app's own windows. The pkg's root layer has run on both Intel Macs through `sudo installer`; nobody has
    double-clicked it and walked through them.
  - A wiped Mac. "From zero" above is a used Mac with things moved away for the test. Logging in and connecting from that
    empty state was not done: it would leave a permanent host row on the server. Everything v0.2.5 listed that is not
    named above.

Verification

  tests/model-options-hook.sh    26 passed, 0 failed on an Intel Mac and on Linux (each piece broken in turn makes it fail)
  tests/resume-no-proc.sh        11 passed, 0 failed on an Intel Mac; 12 passed, 0 failed on Linux (likewise)
  tests/intel-mac.sh             28 passed, 0 failed on an Intel Mac; 24 passed, 0 failed on Linux
  tests/host-name.sh             138 passed, 0 failed on both
  tests/installer-rerun.sh       8 passed, 0 failed on both
  tests/pi-wrapper-session-home.sh   12 passed, 0 failed on both
  tests/build-macos-pkg.sh       8 passed, 0 failed on an Intel Mac
  On one Intel Mac (macOS 13.7.8), list-models matches in the omnigent the plugin had just installed, v0.2.5 then this
  release, 0 unpatched and 4 patched: install-dependencies with nothing else started, 0 and 4; a real first service
  start, 0 and 4. On the other Intel Mac (macOS 15.4.1), a real first service start: 4. On Linux x86_64,
  install-dependencies with this release: 4.
  A real pi-web restart with a connected host, on that other Mac, control then fix: v0.2.5's plugin stayed in phase error,
  HOST_PROCESS_MISSING, for the 2 minutes watched; with the edit, phase needs-verification and no issue for those 2
  minutes. Same host pid and connected throughout, catalog unchanged (claude 4, codex 3, pi 85).
