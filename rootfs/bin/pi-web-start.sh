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

# Shared MCP/skills + plugin registration (best-effort; Settings can also do it).
"${PI_AGENT_HOME}/node/bin/node" "${PI_AGENT_HOME}/bin/pi-agent-share-state.mjs" >/dev/null 2>&1 \
  || log "shared MCP/skills sync skipped"
for seed in pi-paseo-seed.mjs pi-omnigent-seed.mjs; do
  [ -f "${PI_AGENT_HOME}/bin/${seed}" ] \
    && "${PI_AGENT_HOME}/node/bin/node" "${PI_AGENT_HOME}/bin/${seed}" >/dev/null 2>&1 \
    && log "${seed%%.mjs} seeded" || true
done

export PI_WEB_HOSTNAME="${PI_WEB_HOSTNAME:-127.0.0.1}"
export PI_WEB_NO_OPEN=1
export PORT="${PI_WEB_PORT:-30141}"
export LOG_LEVEL="${LOG_LEVEL:-info}"

cd "${HOME}"
PIWEB_JS="${PI_AGENT_HOME}/piweb/lib/node_modules/@agegr/pi-web/bin/pi-web.js"
[ -f "${PIWEB_JS}" ] || PIWEB_JS="$(find "${PI_AGENT_HOME}/piweb" -path '*@agegr/pi-web/bin/pi-web.js' -print -quit 2>/dev/null || true)"
[ -f "${PIWEB_JS}" ] || { echo "pi-web: cannot find pi-web.js under ${PI_AGENT_HOME}/piweb" >&2; exit 127; }

log "starting pi-web on ${PI_WEB_HOSTNAME}:${PORT}"
log "  data : ${PI_CODING_AGENT_DIR}"
log "  home : ${HOME}"
exec "${PI_AGENT_HOME}/node/bin/node" "${PIWEB_JS}"
