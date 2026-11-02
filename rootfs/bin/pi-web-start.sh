#!/bin/bash
# Native entrypoint for pi-web. Replaces the container's s6 run + pi-web-start.sh.
# Sourced env scopes HOME/data to the install root; no root, no s6, no nginx.
set -euo pipefail
exec 2>&1

SELF="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
: "${PI_AGENT_HOME:=$(dirname "$SELF")}"
export PI_AGENT_HOME
# shellcheck source=/dev/null
. "${PI_AGENT_HOME}/bin/pi-agent-env.sh"

DATA_DIR="${PI_AGENT_DATA_DIR}"
log() { printf '[pi-web] %s\n' "$*"; }

mkdir -p "${DATA_DIR}/sessions" "${DATA_DIR}/skills" "${HOME}" "${PI_AGENT_HOME}/logs"

# Credential file modes (defence in depth; the plaintext key problem is upstream).
for f in models.json models-store.json auth.json; do
  [ -f "${DATA_DIR}/${f}" ] && chmod 600 "${DATA_DIR}/${f}" || true
done

# Skills path bridge: pi-web reads ${PI_CODING_AGENT_DIR}/skills, the skills CLI
# writes $HOME/.pi/agent/skills. Link them (migrating a real dir if present).
AGENT_SKILLS_DIR="${HOME}/.pi/agent/skills"
mkdir -p "$(dirname "${AGENT_SKILLS_DIR}")"
if [ -d "${AGENT_SKILLS_DIR}" ] && [ ! -L "${AGENT_SKILLS_DIR}" ]; then
  log "migrating existing skills into ${DATA_DIR}/skills"
  cp -an "${AGENT_SKILLS_DIR}/." "${DATA_DIR}/skills/" 2>/dev/null || true
  rm -rf "${AGENT_SKILLS_DIR}"
fi
[ -e "${AGENT_SKILLS_DIR}" ] || ln -sfn "${DATA_DIR}/skills" "${AGENT_SKILLS_DIR}"

# Ensure the Omnigent + Paseo plugins are registered as pi extensions so their
# settings tabs are enabled (self-heal on a fresh data dir; respect an existing file).
if [ ! -f "${DATA_DIR}/settings.json" ] && [ -d "${PI_AGENT_HOME}/plugins/pi-omnigent-plugin" ]; then
  printf '{"packages":["%s","%s"]}\n' \
    "${PI_AGENT_HOME}/plugins/pi-omnigent-plugin" "${PI_AGENT_HOME}/plugins/pi-paseo-plugin" > "${DATA_DIR}/settings.json"
  log "registered Omnigent + Paseo plugins in settings.json"
fi

# Shared MCP/skills sync (what the claude/codex wrappers also run before launch).
"${PI_AGENT_HOME}/node/bin/node" "${PI_AGENT_HOME}/bin/pi-agent-share-state.mjs" >/dev/null 2>&1 \
  || log "shared MCP/skills sync skipped"

export PI_WEB_HOSTNAME="${PI_WEB_HOSTNAME:-127.0.0.1}"
export PI_WEB_NO_OPEN=1
export PORT="${PI_WEB_PORT:-30141}"
export LOG_LEVEL="${LOG_LEVEL:-info}"

# Teach Omnigent's Pi model picker about gateways configured in models.json.
# Upstream 0.16.0 answers an own-login Pi from auth.json INTERSECT
# models-store.json; Pi writes that store only for providers it refreshes over
# the network, so a compatible endpoint (LiteLLM, Ollama, vLLM) declared in
# models.json is in neither file and the picker comes up empty. The patch
# routes that case to `pi --list-models`. It must run BEFORE the host manager
# boots, because the manager holds the module in memory for its whole life.
# Idempotent, version-gated, and it never fails the start.
#
# It runs under the omnigent tool's OWN interpreter -- the one that imports the
# patched module -- not `python3`. On a Mac without the Command Line Tools,
# /usr/bin/python3 is an installer stub that pops a dialog and fails, and this
# runs on every service start. Until the plugin has installed omnigent there is
# nothing to patch, so no tool interpreter simply means skip.
if [ -f "${PI_AGENT_HOME}/bin/omnigent-model-options-patch.py" ]; then
  PY="${PI_AGENT_HOME}/data/omnigent-plugin/uv/tools/omnigent/bin/python"
  if [ -x "$PY" ]; then
    "$PY" "${PI_AGENT_HOME}/bin/omnigent-model-options-patch.py" \
      --tool-dir "${PI_AGENT_HOME}/data/omnigent-plugin/uv/tools/omnigent" 2>&1 \
      | while IFS= read -r line; do log "$line"; done || true
  fi
fi

# Session home (docs/SESSION-HOME.md): teach the plugin to start the Omnigent
# host with PI_AGENT_SESSION_HOME as its HOME. Inert while that variable is
# unset, so -- like the patch above -- it is applied on every start, which also
# survives a plugin re-extract.
if [ -f "${PI_AGENT_HOME}/bin/omnigent-plugin-session-home-patch.mjs" ]; then
  "${PI_AGENT_HOME}/node/bin/node" "${PI_AGENT_HOME}/bin/omnigent-plugin-session-home-patch.mjs" \
    "${PI_AGENT_HOME}/plugins/pi-omnigent-plugin" 2>&1 \
    | while IFS= read -r line; do log "$line"; done || true
fi
if [ -n "${PI_AGENT_SESSION_HOME:-}" ]; then
  log "session home: Omnigent sessions run with HOME=${PI_AGENT_SESSION_HOME}"
fi

# Ensure the Omnigent host launcher shim is installed (self-heal). It lets the
# Omnigent host manager boot together with pi-web, which is what makes the
# connected engines get models + pass verification. Needs a real pi-web on PATH
# (installed by the wire stage at ${PI_AGENT_HOME}/bin/pi-web).
if [ ! -x "${HOME}/.local/bin/pi-web" ] \
   && [ -x "${PI_AGENT_HOME}/bin/pi-web" ] \
   && [ -f "${PI_AGENT_HOME}/plugins/pi-omnigent-plugin/bin/cli.mjs" ]; then
  "${PI_AGENT_HOME}/node/bin/node" "${PI_AGENT_HOME}/plugins/pi-omnigent-plugin/bin/cli.mjs" install-host >/dev/null 2>&1 \
    && log "installed Omnigent host launcher shim" || true
fi

cd "${HOME}"
# Prefer launching pi-web THROUGH the Omnigent launcher shim (boots the host
# manager); fall back to launching pi-web directly if the shim isn't present.
export PATH="${HOME}/.local/bin:${PATH}"
if [ -x "${HOME}/.local/bin/pi-web" ]; then
  log "starting pi-web via Omnigent launcher on ${PI_WEB_HOSTNAME}:${PORT} (data ${PI_CODING_AGENT_DIR})"
  exec "${HOME}/.local/bin/pi-web"
fi
PIWEB_JS="${PI_AGENT_HOME}/piweb/lib/node_modules/@agegr/pi-web/bin/pi-web.js"
[ -f "${PIWEB_JS}" ] || PIWEB_JS="$(find "${PI_AGENT_HOME}/piweb" -path '*@agegr/pi-web/bin/pi-web.js' -print -quit 2>/dev/null || true)"
[ -f "${PIWEB_JS}" ] || { echo "pi-web: cannot find pi-web.js under ${PI_AGENT_HOME}/piweb" >&2; exit 127; }
log "starting pi-web directly on ${PI_WEB_HOSTNAME}:${PORT} (data ${PI_CODING_AGENT_DIR})"
exec "${PI_AGENT_HOME}/node/bin/node" "${PIWEB_JS}"
