#!/usr/bin/env bash
# Single source of truth for pinned upstream versions.
# Mirrors Woow_k3s_pi_agent_package Dockerfile ARGs + cli-runtime/versions.json.
# Bump deliberately, together, and re-run the smoke test.

PIN_NODE_VERSION=22.23.4                      # scoped Node, not system (>=22.19 for fs.globSync ESM export)

PIN_PI_WEB_VERSION=0.10.0
PIN_PI_WEB_REF=6fcd7d44981ab51a21d6cd6eb06d361d0e3d3068
PIN_PI_WEB_REPO=https://github.com/agegr/pi-web.git

PIN_OMNIGENT_PLUGIN_VERSION=0.3.31
PIN_OMNIGENT_PLUGIN_SHA256=b62059cdb6e5035c577e0e759d01a2586f1353768b40da2d190ec2db6f3bb4e7
PIN_OMNIGENT_UI_SHA256=b204fcae4f33d841810a212b71ab757d2d2956fb6e431e2ea7997980c469ef19
PIN_OMNIGENT_PLUGIN_TGZ="https://github.com/WOOWTECH/pi-omnigent-plugin/releases/download/v${PIN_OMNIGENT_PLUGIN_VERSION}/woowtech-pi-omnigent-plugin-${PIN_OMNIGENT_PLUGIN_VERSION}.tgz"

PIN_PASEO_PLUGIN_VERSION=0.1.15
PIN_PASEO_PLUGIN_SHA256=1a8fd99a503d544a6bd324b93d080ed46dd0bb94cefbff863580580d9c72d4f5
PIN_PASEO_PLUGIN_TGZ="https://github.com/WOOWTECH/pi-paseo-plugin/releases/download/v${PIN_PASEO_PLUGIN_VERSION}/woowtech-pi-paseo-${PIN_PASEO_PLUGIN_VERSION}.tgz"
PIN_GETPASEO_CLI_VERSION=0.11.2

PIN_OMNIGENT_VERSION=0.16.0
PIN_UV_VERSION=0.12.10                        # must match the omnigent plugin's own pin (src/installer.mjs)
PIN_PYTHON_VERSION=3.12.12

# uv standalone binaries, one per Rust target triple. Each value is the sha256 of
# https://github.com/astral-sh/uv/releases/download/${PIN_UV_VERSION}/uv-<triple>.tar.gz
# taken from the release's own uv-<triple>.tar.gz.sha256 and cross-checked against
# the digest GitHub computes for the asset (they agree). A standalone binary rather
# than `pip install uv` because the pip route needs a working python3, and on a Mac
# without the Command Line Tools /usr/bin/python3 is only an installer stub.
PIN_UV_SHA256_aarch64_apple_darwin=51c6170e8e3a01cef9f33b94f582b7b81ac65046f55d40afb35f9cff5a68c179
PIN_UV_SHA256_x86_64_apple_darwin=5296d5aa2b9143360405eea866f8ef4d5dc8986b164eb0dc35e8f876a9304d30
PIN_UV_SHA256_x86_64_unknown_linux_gnu=173d95a0c32d18c896c46ba6fafbf3cf9c14ab74b033f81b76c883ef492a976b
PIN_UV_SHA256_aarch64_unknown_linux_gnu=9ff6b9d4665edcdd3a88dcc73cd1eb641754deb927f14e8c62ebfde6bf4f5f5e

# tmux bundled into the macOS pkg, built from source by scripts/build-macos-tmux.sh.
# Each sha256 matches the checksum Homebrew records for the same formula
# (`brew info --json=v2 tmux libevent utf8proc`, checked 2026-11-02). libevent is
# 2.1.13-stable because that is the stable release Homebrew ships and records.
PIN_TMUX_VERSION=3.8
PIN_TMUX_URL="https://github.com/tmux/tmux/releases/download/${PIN_TMUX_VERSION}/tmux-${PIN_TMUX_VERSION}.tar.gz"
PIN_TMUX_SHA256=e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e
PIN_LIBEVENT_VERSION=2.1.13-stable
PIN_LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/release-${PIN_LIBEVENT_VERSION}/libevent-${PIN_LIBEVENT_VERSION}.tar.gz"
PIN_LIBEVENT_SHA256=f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c
PIN_UTF8PROC_VERSION=2.12.0
PIN_UTF8PROC_URL="https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v${PIN_UTF8PROC_VERSION}.tar.gz"
PIN_UTF8PROC_SHA256=f564011d38b2888d583d510b08e69ffa15aa117155db1b9b49ef1dfe1fa25111
PIN_TMUX_MACOS_MIN=13.0

PIN_CLAUDE_VERSION=2.1.296
PIN_CODEX_VERSION=0.162.1

# Default listen port (container used 30141; keep it so docs/screenshots match).
PIN_PI_WEB_PORT=30141
