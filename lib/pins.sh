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
PIN_UV_VERSION=0.12.10
PIN_PYTHON_VERSION=3.12.12

PIN_CLAUDE_VERSION=2.1.296
PIN_CODEX_VERSION=0.162.1

# Default listen port (container used 30141; keep it so docs/screenshots match).
PIN_PI_WEB_PORT=30141
