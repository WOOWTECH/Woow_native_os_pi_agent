v0.2.3 — replace a Mac's own Omnigent host without losing a conversation

A Mac that has used Omnigent for a while runs its host as a launchd job
(ai.omnigent.host), and every conversation is bound to that host on the server.
Until now the only way to put this install in its place was to start a second host
next to it -- and two hosts of one account with one name take each other's
registration and conversations (v0.2.2 stops that from happening by accident).
v0.2.3 adds the way to do it on purpose, and safely.

What is new

  - pi-agent-session-home runs on macOS (launchd): enable | disable | status | restart,
    as on Linux. rootfs/bin/pi-agent-session-home-macos is the implementation; the
    existing command hands over to it on a Mac. Details: docs/MACOS-CUTOVER.md.

  - pi-agent-session-home cutover [--dry-run | --apply] and uncutover. The cutover
    replaces the Mac's launchd-managed host by ADOPTING ITS IDENTITY: this install's
    host takes the old host's host_id and name, so the server sees the same host
    reconnect -- no row is rotated and no conversation moves. In order: a read-only
    preflight that stops on any doubt (the old host online on the server, no busy
    conversation unless you allow it, no unknown foreign host, the plugin's login
    confirmed, disk space); backups; the old launchd jobs are booted out, disabled and
    MOVED aside (never deleted); ~/.omnigent is parked and linked to this install;
    the old host's identity and any providers/runner settings this install lacks go
    into its config; the plugin's own `pi-omnigent repair` refreshes its connection
    receipt (without it the plugin refuses to resume a host whose id differs from the
    receipt); the service starts; and the result is checked ON THE SERVER: same host id
    online, same name, every conversation that was bound still bound. Any failure rolls
    everything back, and `uncutover` does the same on demand. The work runs in a
    one-shot LaunchAgent that removes itself, because replacing the host ends every
    session it serves, the one that typed the command included.

Found on real machines, and fixed (a sandbox could not show these)

  - Pi had no models after a cutover (Omnigent: MODELS_UNAVAILABLE). Claude and Codex
    keep their login under HOME; Pi keeps its models in one directory that the install
    pointed at its own, empty one. While session home is on, the `pi` wrapper now uses
    the user's own ~/.pi/agent -- but only if it holds a models.json or an auth.json,
    so a user with no Pi of their own is unchanged. The newer Pi writes there (measured:
    one version marker in settings.json and a clean-up time-stamp); the cutover backs
    the directory up first. A gateway that lives only in the install's own Pi data is
    not offered until it is added to the user's models.json (docs/SESSION-HOME.md).
  - An owner's own launchd job can rest on the old host: an hourly health check asked
    launchd whether ai.omnigent.host runs and would have raised a false "login lost"
    alarm, and a job logging under ~/.omnigent would have stopped starting. The preflight
    now names such jobs, and the cutover recreates the log directories they write to.
  - After a cutover the install's host name is the replaced host's own, usually the
    machine's plain hostname. `install.sh wire` (run on every update) warned about it
    and printed a command to rename it -- which, on an adopted identity, would rename
    the owner's host on the server. pi-agent-host-name now reports it as `adopted`.
  - tests/session-home-macos.sh was not isolated from the environment of an Omnigent
    conversation (OMNIGENT_CONFIG_HOME and friends), which is where it is run from on a
    cut-over Mac; it now scrubs them.

Verified

  Sandbox (macOS 26.4 arm64; real launchd jobs, a stub of the server API, fake hosts)
    tests/session-home-macos.sh        262 passed, 0 failed (run from inside an Omnigent conversation)
    tests/host-name.sh                 138 passed, 0 failed
    tests/pi-wrapper-session-home.sh   12 passed, 0 failed (4 fail against v0.2.2's wrapper)
  On the maintainer's two Macs, each time with the server as the evidence
    woowtech MacBook   16 conversations: same host row (created_at unchanged), same name,
                       online; all 16 still bound.
    elmomac            39 conversations: same, all 39 still bound; the conversation that
                       typed the command came back after reopening.
    Claude verified on both through `pi-omnigent verify`; Pi verified through the user's
    LiteLLM gateway on the MacBook. Codex, and Pi on the ChatGPT-subscription route, were
    answered by the provider's weekly usage limit that day -- the request reached the
    provider; not a defect of this release.
  The signed and notarized v0.2.2 .pkg was installed on the MacBook: the first end-to-end
  install of the pkg on another machine (about 4 minutes, memory and the running demos
  there unaffected).

Not verified, and limits

  - A reboot in the middle of a cutover (tested with a killed worker, not a real reboot).
  - The macOS privacy prompts (Desktop, Documents) the new host program may raise.
  - Windows / WSL2. Intel Macs. Re-running the full .pkg over a Mac that is already cut
    over (the update path that was used: `./install.sh wire`, then a service restart).
  - One Omnigent account, two Macs. The server offers no way to delete an ordinary host
    row, so the temporary "<hostname> (pi-agent)" row of a cutover stays offline.
  - `uncutover` puts back what the cutover parked; conversations created since, and files
    the host replaced, live only in this install's directory (docs/MACOS-CUTOVER.md,
    "Going back later").

Updating a Mac that already runs v0.2.2

  ./install.sh wire, restart the service once (pi-agent restart), then
  pi-agent-session-home cutover --dry-run. A Mac with an older install is told to update
  first. Quit Omnigent.app for the few minutes of the cutover.
