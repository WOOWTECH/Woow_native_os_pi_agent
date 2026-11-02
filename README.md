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

## Install

### Fast path — prebuilt pi-web (recommended)

The slow part of an install is building pi-web from source: ~15 minutes and a
full toolchain. Releases ship that tree prebuilt per platform, so no compiler is
needed and the build disappears entirely.

Unpacking the artifact takes **6s on macOS / 4s on Linux** (measured after
deleting the built tree). From a URL you also pay the download — the asset is
136 MB (macOS) / 180 MB (Linux), so the real total is however long that takes on
your connection; a local file path skips it.

```bash
git clone https://github.com/WOOWTECH/Woow_native_os_pi_agent
cd Woow_native_os_pi_agent
PI_AGENT_PIWEB_ARTIFACT=https://github.com/WOOWTECH/Woow_native_os_pi_agent/releases/download/v0.2.0/piweb-0.10.0-macos-arm64.tar.gz \
  ./install.sh
```

Use the asset matching your platform (`macos-arm64`, `linux-x64`). The installer
verifies its published `.sha256` and refuses an artifact built for another
platform. A local file path works too.

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
`/usr/bin/perl` shim. And **tmux is bundled**, built from source rather than
copied from Homebrew. Homebrew's tmux is built for macOS 26 only and links four
`/opt/homebrew` dylibs. Ours targets macOS 13+, links only `/usr/lib`, and
includes utf8proc, without which tmux gets Traditional Chinese character widths
wrong. Details in [`docs/MACOS.md`](docs/MACOS.md#bundled-tmux).

Signing: without `--sign-app`/`--sign` the pkg is unsigned and Gatekeeper
refuses it on other Macs. A public `.pkg` needs both Developer ID certificates
(Application for `tools/`, Installer for the pkg) plus notarization.
