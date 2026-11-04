v0.2.5 — Intel Macs install with no compiler

Until this release the installer had been verified on Apple silicon only. On the first two Intel
Macs it was installed on -- a 2017 13" MacBook Pro (macOS 13.7.8) and a 2020 MacBook Air (macOS
15.4.1) -- pi-web had to be built from source, no pkg could bundle a tmux, and the Omnigent tab
never left DEPENDENCIES_MISSING. This release closes those gaps. Apple silicon and Linux install
the same versions as before.

Downloads

  - WoowPiAgent-0.2.5-macos-x64.pkg      Intel Macs (new)
  - WoowPiAgent-0.2.5-macos-arm64.pkg    Apple silicon
  - piweb-0.10.0-macos-x64.tar.gz        the prebuilt pi-web tree for Intel Macs (new); the pkg pins it
  - tools-macos-x64.tar.gz               the x86_64 tmux the Intel pkg bundles (new), for building it

  CI builds and attaches the trees and tools-macos-x64. The pkgs are signed and notarized on the
  maintainer's Mac and attached after that.

What was wrong on an Intel Mac, and the fix

  - No prebuilt pi-web: an Intel Mac had to build it from source, ~15 minutes and the Command Line
    Tools. The release workflow now builds piweb-...-macos-x64 on a macos-15-intel runner.
  - No x86_64 tmux: scripts/build-macos-tmux.sh refused anything but arm64, so no Intel pkg could
    bundle one, and without tmux the Omnigent dependency check never passes. It now builds for the
    Mac it runs on (on x86_64: -arch x86_64, jemalloc with 4 KiB pages) and keeps every check it
    had; the Intel release job publishes the result as tools-macos-x64.tar.gz.
  - Two of omnigent's dependencies publish no x86_64 macOS wheel at their newest releases
    (cryptography 50.0.2, argon2-cffi-bindings 26.1.0), so uv built them from source: argon2
    needs the Command Line Tools, and cryptography's Rust build fails even with them (no OpenSSL
    headers). Both the omnigent stage and the plugin's own omnigent install failed this way. The
    lock now pins both a second time for Intel Macs only, at the newest releases that ship x86_64
    wheels (48.0.1 and 25.1.0), and on an Intel Mac the plugin's install resolves against that
    lock (PI_OMNIGENT_UV_CONSTRAINTS, read by the darwin patch).
  - The plugin checks a freshly installed omnigent with `--version` and a 5 s limit; its first run
    took 4.0 to 6.1 s on these Macs (0.5 s afterwards), so the check failed although the install
    had worked. On x64 the darwin patch now runs it once, with a 120 s limit, before the check.

If you installed on an Intel Mac by hand before this release

  A link from $PI_AGENT_HOME/bin/omnigent to the omnigent stage's venv worked around the last two
  defects. Remove it after upgrading: the plugin then installs and uses its own omnigent, which is
  the one pi-web-start.sh patches for Pi's model list in Omnigent (the venv is rebuilt on every
  upgrade, and that patch would go with it). Do not remove it before upgrading: on v0.2.4 the
  plugin's own install still fails there.

Not verified, and limits

  - A Mac that has never had the Command Line Tools. Both Intel Macs had them by the time the
    fixes were tested; nothing in the install compiles any more, but that was not seen on such a
    Mac.
  - Apple silicon after this change: the new code paths are covered by tests that stand in for
    the plugin's uv and fake the architecture, not by a run on an Apple silicon Mac.
  - The Intel pkg installed on an Intel Mac: it is built after this note was written. What was run
    is the same install in the pkg's layout (bundled tmux, the macos-x64 tree, source builds
    forbidden), on both Macs.
  - Everything v0.2.4 listed that is not named above.

Verification

  tests/intel-mac.sh             28 passed, 0 failed on each Intel Mac; 24 passed, 0 failed on Linux x86_64
                                 (the Intel-only part skipped). Each fix taken back to v0.2.4 makes it fail.
  tests/installer-rerun.sh       8 passed, 0 failed (one new check: the stage keeps its lock)
  tests/host-name.sh             138 passed, 0 failed
  tests/pi-wrapper-session-home.sh   12 passed, 0 failed
  tests/tmux-stress.sh           0 aborts in 300 s on each Intel Mac (590 and 449 iterations)
  CI: the release workflow on the branch, all three platforms green before this tag (run 41826891068).
  On both Intel Macs: install.sh in the pkg's layout with UV_NO_BUILD=1, exit 0; then the plugin's own
  dependency install from an empty state directory, three times on each Mac: ok, omnigent 0.16.0.
