v0.2.4 — three defects that only a second real Mac could show, fixed

v0.2.3 listed what it had not verified: a reboot in the middle of a cutover, the macOS privacy
prompts, and installing the pkg over a Mac that is already cut over. Going after those on the
two Macs this project is tested on found three real defects. None needed a rare event; each
was in what a second person following the documentation would have done.

If you ran v0.2.3

  1. A Mac cut over with v0.2.3 has an Omnigent host whose umask is 077, and so does every
     session under it: files made there are 600/700 instead of 644/755 (a git worktree, a
     build, a pkg). Fix: pi-agent-session-home restart, then measure it again
     (OPERATIONS-GOTCHAS.md section 17 shows how, without reading any process's memory).
     Files made in the meantime keep their modes.
  2. There is no v0.2.3 pkg to use: it was never published, and it would not have installed
     (below). The pkg of this release is the one to install.
  3. "Install the pkg again" / ./install.sh again over an existing install stops half way
     (below). Finish with ./install.sh wire service, then pi-agent restart; v0.2.4 does not
     stop.

What was wrong, and the fix

  - The cutover left the host with the cutover's own strict umask. pi-agent-session-home-macos
    keeps umask 077 for its backups, tokens and journal; it starts the new host through the
    plugin's repair, a child of itself, and env -i clears the environment but not the umask.
    The host outlives the worker and every session inherits what it has. The replaced job ran
    with launchd's default 022. Now the repair runs under the umask the replaced job had (its
    plist's Umask key, 18 meaning 022 because launchd wants decimal, else 022), set before env -i
    so the shell that sets it cannot add variables to the plugin's environment. The dry run's plan
    says which umask the host will get. A restart was never affected: launchd starts pi-web,
    which starts the host.
  - The pkg builder took the umask of whoever ran it. tar xf - and mkdir apply it; built from a
    shell that had inherited 077 (the first item), every payload file was 600/700, root-owned
    after install, and the postinstall -- which hands the work to the console user -- failed with
    "install.sh: Permission denied", exit 126, before anything was installed. The builder now
    sets umask 022, sets modes explicitly over the whole payload root, and fails the build if
    anything in the expanded pkg is unreadable by others or install.sh is not executable by them.
  - The installer could not be run again. The omnigent stage called uv venv over a directory
    that exists after the first run; uv 0.12 refuses ("Use the --clear flag"). The node, fetch,
    piweb, clis and paseo stages before it had already replaced the plugin and pi-web trees, so
    the machine was left half updated. uv venv --clear; nothing runs from that venv.

Measured, not fixed (they are facts about macOS, written down in OPERATIONS-GOTCHAS.md section 20)

  - Privacy consent (Desktop, Documents, Downloads) belongs to the program a session runs as. For
    Claude and Pi that is this install's own node, not the replaced host's python, so earlier
    "Allow" clicks do not carry over. On the Mac where the install had been used, consent was
    already there; on the other it was not decided, and the first session that goes into one of
    those folders raises the prompt on that Mac's screen (with nobody there the session waits).
    Conversations that start in the home folder do not ask. Not tested: the native codex binary.
  - Nothing can pre-grant it from a script (the TCC database is protected by TCC); answer once at
    the Mac, or grant Full Disk Access to the install's node.

Not verified, and limits

  - A real reboot in the middle of a cutover. Both Macs have FileVault on and no automatic
    login, so a reboot stops at the disk-unlock screen until someone types a password at the
    keyboard: it cannot be done, or undone, remotely. What is covered instead: a worker killed
    half way and recovered at the next login, with real launchd jobs and a stand-in for the
    server (tests/session-home-macos.sh).
  - Windows / WSL2, Intel Macs (no hardware).
  - The privacy prompts for the native codex binary, and for services other than Desktop,
    Documents and Downloads.
  - Everything v0.2.3 listed that is not named above.

Verification

  tests/session-home-macos.sh    292 passed, 0 failed (v0.2.3: 262; the umask cases watched to fail first; plus a
                                 power cut after the repair, where the next login loads the service and the
                                 leftover worker together)
  tests/build-macos-pkg.sh       8 passed, 0 failed (watched to fail on v0.2.3's builder)
  tests/installer-rerun.sh       7 passed, 0 failed (watched to fail on v0.2.3's installer)
  tests/host-name.sh             138 passed, 0 failed
  tests/pi-wrapper-session-home.sh   12 passed, 0 failed
  On a real Mac: the v0.2.4 payload installed over a cut-over Mac that serves 16 conversations --
  all nine stages, exit 0; the host kept running; the server still showed the same host row and
  all 16 conversations bound; Claude and Pi verified afterwards.
