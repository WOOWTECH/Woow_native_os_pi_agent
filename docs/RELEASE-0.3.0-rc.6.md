v0.3.0-rc.6 — what the Allwinner H618 4 GB boards turned up

A preview, not the latest release: releases/latest keeps pointing at the newest full release. Built from
v0.3.0-rc.3 (`windows-wsl2`) plus the fixes below; nothing else changed for Windows, macOS or Linux.
pi-web is still 0.10.0; the prebuilt trees are rebuilt, the rc.3 ones keep working.

v0.3.0-rc.4 and v0.3.0-rc.5 have no assets. rc.4's release build stopped because docs/WSL2.md still
pointed at rc.3; rc.5's because GitHub no longer runs macos-14 jobs ("The configuration
'macos-14-arm64-us-default' is not supported") and the release step waits for every pi-web tree.
rc.6 is the same code: the macOS tree is built on macos-15 (so is the wsl2-linux suite's macOS leg),
and the guide and README point at rc.6.

Since v0.3.0-rc.3 (found on two H618 4 GB boards running the H4G profile, 2026-11-09/10)

  - Pi's LiteLLM models: `pi-agent-litellm set` and `refresh` now write each model's context window and
    output limit from the gateway's /model/info. Without them Pi asked a 24k-context model for 16384 output
    tokens and every turn with an MCP server's tool list overflowed. The probe now asks each model for what
    Pi will ask for, so models that only fail with a full-size request (HTTP 402 from a provider's billing
    limit) are dropped; dead models show the status. `probe --apply` keeps a default model that still
    answers, otherwise picks one and says which; `pi-agent-litellm default MODEL` sets it.
  - The claude and codex wrappers no longer sync the shared skills and MCP for --version / --help. The
    Paseo daemon asks both every 17 s; the sync cost about 6% of a 4-core H618 at idle.
  - Claude Code no longer updates itself inside long-lived sessions (DISABLE_AUTOUPDATER defaults to 1; an
    explicit value wins). It ran `npm install -g` about every 30 minutes, wrote ~330 MB each time and left
    a second, newer Claude Code next to the pinned one.
  - Downloads: `PI_AGENT_ASSET_CACHE` can point at verified copies (the sha256 check still runs), and
    curl retries 10 times, 10 s apart, within 300 s. GitHub returned 504 for a plugin tarball through all
    of rc.3's retries on a board.
  - pi-omnigent-plugin 0.3.32: probes and the lock wait 30 s instead of 5 s, so a slow board no longer
    reports an installed Omnigent as missing after every boot.
  - pi-paseo-plugin 0.1.16: the supervisor no longer asks the daemon for status every 15 s (each request
    ran every provider's --version), and Pi's model list refreshes when models.json or settings.json
    change.

Tested on Linux x86_64 with the repo's suites (host-name 132, litellm 62, fetch-verify 13, cli-wrappers 19,
pi-wrapper-session-home 12, installer-rerun 7; all pass) and on an H618 4 GB board (the scripts, both
plugins and the default/probe behaviour, drilled one at a time).
