v0.2.2 — two Omnigent hosts with one name no longer take each other's conversations

Two hosts of one Omnigent account that share a name are not "two hosts with the
same label". The server finds a connecting host by host_id and, failing that, by
(account, name). A daemon that arrives under a taken name makes it delete that
host's registration, create a new one and repoint the conversations bound to it,
and two live daemons with one name do that to each other on every reconnect. A
scoped install and the owner's own Omnigent, both defaulting to the machine's
hostname, did exactly this on the Mac used for testing. docs/MACOS.md had called
it cosmetic ("nothing functional depends on it"); it was not, and that text is
corrected.

What changes

  - wire (so ./install.sh, ./install.sh wire and the pkg) gives an install that
    has no host name one that cannot collide by default: "<hostname> (pi-agent)",
    written into its own home/.omnigent/config.yaml, mode 600. omnigent keeps a
    name it finds there and generates only the host_id. An existing name is never
    replaced; one equal to the plain hostname gets a warning, not a rename.

  - pi-agent-host-name check | set NAME | seed. `set` takes any name, including an
    old host's exact name when replacing that host on purpose. `check` also prints
    the plugin's last refusal to start a host (exit 1 while one is pending).

  - pi-omnigent-plugin 0.3.31 is patched, by fetch, again by wire and again at
    every service start (pi-web-start.sh, so a plugin tree re-extracted outside
    the installer is covered at once), to ask
    GET /v1/hosts just before it starts a host. If any other host of the account
    has the same name -- online or offline -- nothing is started:
    HOST_NAME_COLLISION, naming the other host and printing the exact command to
    proceed. If the server cannot be asked, nothing is started either
    (HOST_NAME_UNVERIFIABLE): failing open would let an unreachable server
    trigger the one thing that cannot be undone, and connect/resume need the
    server just before this point anyway. The three codes also get localized
    hints in the plugin's own table (src/issues.mjs), because Settings shows the
    hint for a code, not the message, and `pi-omnigent connect` prints only the
    code: they all point at `pi-agent-host-name check`, which prints the last
    refusal in full. Version-gated, counted anchors, idempotent, keeps
    omnigent.py.orig and issues.mjs.orig, never fails the install; a plugin
    version it was not validated against is skipped with a warning.

  - Replacing a host on purpose is still possible, and only on purpose:
    PI_AGENT_TAKEOVER_HOST_ID=<first 8 or more hex characters of the old host's id>.
    Every colliding host's id must start with it, "1" / "true" / a typo do not
    work, and the old host must already be offline. The refusal prints the exact
    line to run with the colliding id filled in.

  - Docs: MACOS.md corrected (new section "Host names must differ"),
    OPERATIONS-GOTCHAS.md sections 13-16 (name collision and registration
    rotation; the restart deadlock after a registration is deleted, and its
    recovery; a conversation follows its host binding; read a script's RESULT
    line, not whether it finished), README.

Two ways to run a second host

  A. Side by side (the default). The new install gets its own name; nothing to do.
  B. Replacing a host (same name on purpose). Stop the old host, set its exact
     name, connect with PI_AGENT_TAKEOVER_HOST_ID, then pi-agent-session-home.
     Linux with systemd only. NOT available on macOS in this release:
     pi-agent-session-home exits at once on Darwin, and without it the replaced
     conversations would run under the scoped HOME (no MCP servers, plugins, git
     identity or keys of the user's own). Use A on a Mac.

Upgrading an existing install

  Re-run ./install.sh wire (or install the pkg again). A name equal to the plain
  hostname is reported, not changed. To change it:
  pi-agent-host-name set "<hostname> (pi-agent)", then pi-agent restart (a running
  host keeps the name it started with).

Limits

  - The guard covers hosts the plugin starts. It does not stop `omnigent host` run
    by hand, or an Omnigent app, under a taken name.
  - Nothing moves conversations back after a collision; check which host each one
    is bound to.
  - A restart that already deadlocked (HTTP_404 from resume, because the
    registration row is gone) is recovered with `pi-omnigent repair`, under
    `env -i` -- docs/OPERATIONS-GOTCHAS.md section 14.
  - Tested against a stub server shaped from the plugin's own use of /v1/me and
    /v1/hosts (host_id, name, status; owner when present), not against a live
    Omnigent server.

Also in this release (already on main when this was prepared)

  a1fa583 feat: session home -- Omnigent sessions with the user's own HOME
          pi-agent-session-home enable | restart | status | disable, and the
          plugin patch behind it (docs/SESSION-HOME.md). Linux, systemd --user.
  004081f fix(session-home): keep the caller's HOME in the wrappers
  672851b fix: let a second install pick its port (PI_WEB_PORT), and adopt
          Claude's Linux credential
  4c6c160 fix(adopt-logins): link pi's login where pi reads it
  8c27cf6 docs(readme): per-platform install with the v0.2.1 links

Verification

  tests/host-name.sh (hermetic: temp dirs and a stub server; docs/TESTING.md)
    macOS 26.4 arm64   134 passed, 0 failed, 0 skipped
    Ubuntu 24.04       128 passed, 0 failed, 1 skipped (needs the omnigent
                       package, which the isolated tree does not have)
  26 deliberate regressions were each caught by the suite.
