# Native shared environment for the Woow Pi Agent.
#
# Sourced (not executed) by pi-web-start.sh and the pi/claude/codex wrappers.
# It applies ONLY within processes that source it, so — unlike the container
# original — it never rewrites the interactive user's real HOME.
#
# The caller must export PI_AGENT_HOME before sourcing (the wrappers derive it
# from their own location).

: "${PI_AGENT_HOME:?PI_AGENT_HOME must be set before sourcing pi-agent-env.sh}"
: "${PI_AGENT_DATA_DIR:=${PI_AGENT_HOME}/data}"
export PI_AGENT_HOME PI_AGENT_DATA_DIR

# The pi coding agent stores skills, sessions, models.json and auth.json here.
export PI_CODING_AGENT_DIR="${PI_AGENT_DATA_DIR}"
# Scoped HOME so the agent's per-session worktrees and the shared claude/codex
# state land under the install root, not the user's real home.
export HOME="${PI_AGENT_HOME}/home"

export PI_TELEMETRY="${PI_TELEMETRY:-0}"
export PI_SKIP_VERSION_CHECK="${PI_SKIP_VERSION_CHECK:-1}"

# Scoped Node + our wrappers first on PATH.
export PATH="${PI_AGENT_HOME}/bin:${PI_AGENT_HOME}/node/bin:${PATH}"

# Plugin + runtime roots (match the k3s image ENV so the seeds/routes resolve).
export PI_OMNIGENT_PLUGIN_ROOT="${PI_AGENT_HOME}/plugins/pi-omnigent-plugin"
export PI_OMNIGENT_SDK_ROOT="${PI_AGENT_HOME}/piweb/lib/node_modules/@agegr/pi-web"
export PI_PASEO_RUNTIME_DIR="${PI_AGENT_HOME}/paseo-runtime"
export PI_PASEO_PLUGIN_ROOT="${PI_AGENT_HOME}/plugins/pi-paseo-plugin"
export PI_PASEO_WEB_ARCHIVE="${PI_AGENT_HOME}/paseo-web/client.tar.gz"
