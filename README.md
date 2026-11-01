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
| **Windows (WSL2)** | ⏳ reuses the Linux path |

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
