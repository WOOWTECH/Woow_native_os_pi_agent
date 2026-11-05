v0.2.7 — A Mac without the Command Line Tools stops asking for them, and the pkg has a name

v0.2.6 said a pkg install on a Mac without the Command Line Tools never opens their install dialog. It does, and once
Omnigent is connected it keeps coming back. Both causes are fixed. No pinned version changes: pi-web, Claude Code, Codex,
Omnigent and the plugins are what v0.2.6 installs. On a Mac with the tools, the only difference is the pkg's title.

Downloads

  - WoowPiAgent-0.2.7-macos-x64.pkg      Intel Macs
  - WoowPiAgent-0.2.7-macos-arm64.pkg    Apple silicon
  - piweb-0.10.0-<os>-<arch>.tar.gz      the prebuilt pi-web trees; each pkg pins its own

  CI builds and attaches the trees. The pkgs are signed and notarized on the maintainer's Mac and attached after that.

What was wrong, and the fix

  Without the tools, /usr/bin/git and its like are stubs that open the dialog and fail at once. Nothing ever waited for the
  answer or failed because of it.

  - The install opened it once. Right after it unpacks CPython, uv renames libpython with `install_name_tool`, found through
    PATH, and that is the only stub a whole install reaches. The omnigent stage now gives that one call a stand-in. Only
    the rename is lost, from the shipped @rpath/libpython3.12.dylib to the full path. Only something linking against this
    libpython would notice, and that takes the tools; the interpreter finds it through its own rpath.
  - Claude Code opened it again and again. It runs `git` whenever it starts to work, and a connected Omnigent host starts
    `claude` by itself about every 3 minutes, so the dialog was back within 3 minutes of each Cancel. The `claude` wrapper
    now puts bin/no-dev-tools/git ahead of the stub, for itself and what it starts. A Mac with the tools, another git
    first on PATH, and Linux are left alone. (docs/MACOS.md, Host requirements.)
  - The pkg had no title: `installer` printed `Package name is ` with nothing after it. The builder now gives it one.

What this changes for an agent

  On a Mac without the tools, an agent under Claude Code has no git until they are installed. Its `git` exits 127 and says
  how to get them: `xcode-select --install`. After that it is the real git, even in a claude that was already running.
  Under Codex or Pi an agent's `git` has no stand-in: it goes to the stub, and macOS offers the tools, as before.

If you already installed

  Install this pkg; nothing else is needed. On a Mac without the tools, a claude that is already running keeps the PATH it
  started with until it restarts. New ones, including the host's own, get the stand-in at once.

Not verified, and limits

  - A wiped Mac. All of this was measured on a used Intel Mac with the tools and the install moved away for the test.
    Logging in and connecting from that empty state was not done: it would leave a permanent host row on the server.
  - Installer.app's own windows. The pkgs have been run through `sudo installer`, not by double-clicking them.
  - Apple silicon: the new paths are covered by tests with stand-ins, not by a run on an Apple silicon Mac.
  - An agent running `git` under Codex or Pi on a Mac without the tools.

Verification

  tests/claude-no-tools.sh       9 passed, 0 failed on an Intel Mac and on Linux (each piece broken in turn makes it fail)
  tests/installer-rerun.sh       13 passed, 0 failed on an Intel Mac; 12 passed, 0 failed on Linux (likewise)
  tests/build-macos-pkg.sh       10 passed, 0 failed on an Intel Mac (likewise)
  tests/session-home-macos.sh    292 passed, 0 failed on an Intel Mac (not run for v0.2.6)
  tests/smoke.sh                 24 passed, 0 failed on that Mac's install, with this tree's wire stage (not run for v0.2.6)
  tests/model-options-hook.sh    26 passed, 0 failed on an Intel Mac
  tests/resume-no-proc.sh        11 passed, 0 failed on an Intel Mac
  tests/intel-mac.sh             28 passed, 0 failed on an Intel Mac
  tests/host-name.sh             138 passed, 0 failed on an Intel Mac
  tests/pi-wrapper-session-home.sh   12 passed, 0 failed on an Intel Mac and on Linux
  With the tools moved away on an Intel Mac (macOS 15.4.1), each run ending with a control: `/usr/bin/git` opening the
  dialog. Before the fixes, one stub reached and a dialog during the install, and a dialog within 2 s of a Claude session
  starting and at each of the host's own starts of `claude`. With them: from zero, the published v0.2.6 payload with this
  install.sh, exit 0 in 162 s, no stub reached and no dialog through the first boot; a logged-in install, host connected,
  241 s with the host's own starts and a real Claude session, no dialog and nothing running /usr/bin/git. In that session
  the agent's `git` got the message and exit 127, and with the tools back, the same session got the real git. A new session
  with the tools: /usr/bin/git, the stand-in not on PATH. docs/TESTING.md has the tables.
