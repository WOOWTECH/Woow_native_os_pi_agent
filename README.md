# Woow Native OS Pi Agent

Install the full WOOWTECH **Pi Agent** stack **natively** on a developer/user
machine — macOS, Linux, or Windows — **not** inside a container. A 4th deployment
target alongside the PaaS (k8s), the Home Assistant add-on, and the k3s root image.

It assembles pinned upstream pieces (it does **not** fork pi-web): **pi-web**
(the settings UI + browser terminal), **Claude Code** + **Codex**, the
**Omnigent** and **Paseo** integrations, and the shared **skills / MCP** bridge —
then runs them under a per-OS service (systemd / launchd), as a normal user.

## Status

| OS | State |
|---|---|
| **Linux** (Ubuntu/Debian; dnf-based best-effort) | ✅ installed + running + browser-verified · 24/24 smoke |
| **macOS** (arm64, 26.4 verified) | ✅ installed + running under launchd · 24/24 smoke · see [`docs/MACOS.md`](docs/MACOS.md) |
| **Windows 11** (WSL2) | 🧪 preview: installs and runs on a GitHub-hosted Windows Server 2025 runner, connects to a real Omnigent, Claude Code and Codex chat and switch models there and in Paseo, agents drive PowerShell and apps; **not yet run on a real Windows 11 PC** (first-time WSL enablement, start at logon, sleep) and no Pi reply was seen (login and model switching work, the ChatGPT account's usage limit blocked the answer) · see [`docs/WSL2.md`](docs/WSL2.md) |

## Install

### macOS — download and double-click

[WoowPiAgent-0.2.4-macos-arm64.pkg](https://github.com/WOOWTECH/Woow_native_os_pi_agent/releases/download/v0.2.4/WoowPiAgent-0.2.4-macos-arm64.pkg)
is signed with a Developer ID and notarized, so Gatekeeper opens it without a
warning. It fetches the rest of the stack while it installs.

### Windows 11 — a dedicated WSL2 Linux (preview)

One PowerShell command creates a dedicated Ubuntu in WSL2, installs the Linux version in it,
and starts it when you log in. Pi Agent, Claude Code and Codex then run as they do on Linux,
and agents can reach Windows programs through `pi-agent-win`. Requirements, the command, what
it changes and how to remove it: [`docs/WSL2.md`](docs/WSL2.md). Not yet validated on a real
Windows machine: expect rough edges and read the status section there first.

### Linux — prebuilt pi-web (recommended)

The slow part of an install is building pi-web from source: ~15 minutes and a
full toolchain. Releases ship that tree prebuilt per platform, so no compiler is
needed and the build disappears entirely.

```bash
git clone https://github.com/WOOWTECH/Woow_native_os_pi_agent
cd Woow_native_os_pi_agent
PI_AGENT_PIWEB_ARTIFACT=https://github.com/WOOWTECH/Woow_native_os_pi_agent/releases/download/v0.2.4/piweb-0.10.0-linux-x64.tar.gz \
  ./install.sh
```

The installer verifies the asset's published `.sha256` and refuses one built for
another platform (a Mac without the pkg uses `piweb-0.10.0-macos-arm64.tar.gz`).
Unpacking takes **4s on Linux / 6s on macOS** (measured after deleting the built
tree); from a URL you also pay the download, 180 MB (Linux) / 136 MB (macOS). A
local file path works too.

- **Port 30141 already taken** — for example by an earlier pi-agent you want to
  keep running while you try this one: prefix `PI_WEB_PORT=30142`.
- **Replacing a pi-agent your Omnigent conversations already use** — they expect
  your own MCP servers, plugins, git identity and keys; see
  [`docs/SESSION-HOME.md`](docs/SESSION-HOME.md) and, for the host name that
  replacement has to take over, [a machine that already runs an Omnigent
  host](#a-machine-that-already-runs-an-omnigent-host) below.

### A machine that already runs an Omnigent host

Two hosts of one Omnigent account must not share a name: on every reconnect the
server deletes and re-creates their registrations in turn, and the conversations
bound to them change hands. Since v0.2.2 this install registers as
`<hostname> (pi-agent)`, and the plugin refuses to start a host under a name that
another host of the account holds.

| | |
|---|---|
| **A. Side by side** (the default) | A second install next to a host that keeps running — the owner's Omnigent app, an older pi-agent. Nothing to do: the name is already unique. `pi-agent-host-name check` shows it, `pi-agent-host-name set NAME` changes it. |
| **B. Replace a host** | The same name **on purpose**, so the old host's conversations follow: stop the old host, `pi-agent-host-name set "<its exact name>"`, connect with `PI_AGENT_TAKEOVER_HOST_ID=<first 8+ hex characters of its id>`, then [`pi-agent-session-home`](docs/SESSION-HOME.md). These are the manual steps on Linux with systemd. **On macOS use [`pi-agent-session-home cutover`](docs/MACOS-CUTOVER.md)** instead: it replaces the Mac's launchd-managed host by adopting its identity, keeps every conversation bound, rolls back on any failure, and checks the result on the server (`--dry-run` first). Run for real on two Macs (16 and 39 conversations); on both, every conversation was still bound afterwards, checked on the server. |

An install that already has a name is never renamed; if that name is the plain
hostname, `wire` warns (unless a cutover adopted it on purpose — then
`pi-agent-host-name check` says `adopted`). Two pi-agent installs on one machine need two names (the
second one is told so, and how, when it connects). The steps, the macOS cutover and
the reasoning:
[`docs/MACOS.md`](docs/MACOS.md#host-names-must-differ); what went wrong without
this, and how to recover: [`docs/OPERATIONS-GOTCHAS.md`](docs/OPERATIONS-GOTCHAS.md)
§13–§16.

### From source

## Quickstart (engineer track)

```bash
git clone https://github.com/WOOWTECH/Woow_native_os_pi_agent
cd Woow_native_os_pi_agent
./install.sh                 # all stages; installs under ~/.local/share/pi-agent
```

Run one or more stages instead of the whole thing:

```bash
./install.sh preflight node fetch piweb clis paseo omnigent wire service
```

Prereqs are auto-installed per OS (Homebrew / apt / dnf). Override the install
root with `PI_AGENT_HOME=/custom ./install.sh`.

## Control

```bash
pi-agent start | stop | restart | status | logs | open | url
pi-agent-host-name check | set NAME     # the name this install's Omnigent host registers under
```

pi-web serves on `http://127.0.0.1:30141` (localhost only by default; it already
satisfies pi-web's Host/Origin trust guard, so there is no nginx shim).

## Layout

Everything lands under `~/.local/share/pi-agent/` (data, scoped Node, the built
pi-web tree, the Claude/Codex CLIs, the Paseo runtime, the Omnigent venv, and the
wrapper scripts). It runs as your user; nothing is installed system-wide except
the OS build prerequisites.

## How it works / design

See [`docs/DESIGN.md`](docs/DESIGN.md) for the full architecture, the pinned
versions, the per-OS plan, and the macOS portability analysis.

## License

MIT. Vendored helper files under `vendor/` and `rootfs/bin/pi-agent-share-state.mjs`
are derived from WOOWTECH's `Woow_ha_pi_agent_add_on` / `Woow_k3s_pi_agent_package`
(MIT).

## Packaging (maintainers)

```bash
scripts/build-piweb-artifact.sh dist          # prebuilt pi-web for THIS platform (CI does this)
scripts/build-macos-tmux.sh                   # bundled tmux -> dist/tools-macos-arm64/
scripts/build-macos-pkg.sh \
    --artifact-url    https://github.com/WOOWTECH/Woow_native_os_pi_agent/releases/download/<tag>/piweb-<ver>-macos-arm64.tar.gz \
    --artifact-sha256 <that asset's .sha256> \
    [--sign-app "Developer ID Application: …"] [--sign "Developer ID Installer: …"] \
    [--notary-key AuthKey_….p8 --notary-key-id … --notary-issuer …]
```

`.github/workflows/release.yml` builds and attaches the prebuilt pi-web trees on
a `v*` tag. The `.pkg` is **not** built in CI: it is signed and notarized on the
maintainer's Mac, where the Developer ID certificates are.

The `.pkg` is under a megabyte. It carries the installer and the bundled tools,
and it **pins** the prebuilt pi-web tree by URL and sha256 rather than embedding
it. Postinstall downloads the tree, and `install.sh` verifies it. The pkg build
fails if anything other than `tools/bin/tmux` in the payload is a Mach-O binary.

**The `.pkg` install needs neither Homebrew nor the Xcode Command Line Tools.**
uv is a pinned standalone binary rather than a pip install. `flock` is a
`/usr/bin/perl` shim. On a Mac without the tools, `python3` is linked to the
uv-managed CPython, so the Omnigent tab's dependency check never runs the
`/usr/bin/python3` stub and its install dialog. And **tmux is bundled**, built
from source rather than copied from Homebrew. Homebrew's tmux is built for
macOS 26 only and links four `/opt/homebrew` dylibs. Ours targets macOS 13+,
links only `/usr/lib`, and includes utf8proc, without which tmux gets
Traditional Chinese character widths wrong. It also includes jemalloc as the
default malloc zone, without which tmux aborts in copy mode now and then on
macOS (tmux issue 5385; reproduced here in a 5-minute stress run). Details in
[`docs/MACOS.md`](docs/MACOS.md#bundled-tmux).

Signing: without `--sign-app`/`--sign` the pkg is unsigned and Gatekeeper
refuses it on other Macs. A public `.pkg` needs both Developer ID certificates
(Application for `tools/`, Installer for the pkg) plus notarization.
