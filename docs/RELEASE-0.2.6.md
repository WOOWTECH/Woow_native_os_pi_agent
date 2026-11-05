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

Not verified, and limits

  - A session running through a pi-web restart. The restart was measured with a connected host and no session bound to
    it (below); the host keeps its pid, but a session under it was not there to watch.
  - tests/session-home-macos.sh and tests/smoke.sh over this tree: they use real launchd jobs or restart the service,
    and the Mac available was in use.
  - Apple silicon: the new paths are covered by tests with stand-ins, not by a run on an Apple silicon Mac.
  - Double-clicking a pkg on an Intel Mac. What was run on them is the payload's install.sh, the way the postinstall
    runs it. The pkg's root layer (the payload in /usr/local/lib, launchctl asuser) has not run there.
  - A Mac that has never had the Command Line Tools. Everything v0.2.5 listed that is not named above.

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
