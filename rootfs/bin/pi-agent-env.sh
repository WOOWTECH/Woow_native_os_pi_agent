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

# Claude Code's auto-updater, off. In long-lived interactive sessions (the ones
# Omnigent's claude-native harness keeps open) it ran
# `npm install -g @anthropic-ai/claude-code` about every 30 minutes, writing
# ~330 MB each time -- to eMMC on an H618 board -- and put 2.1.319, then
# 2.1.321, into the scoped Node's prefix next to the 2.1.296 pinned under
# clis/claude, the only copy the claude wrapper ever starts (measured
# 2026-11-09/10). Claude Code is updated by this installer: PIN_CLAUDE_VERSION,
# then ./install.sh clis. Every launch of it here sources this file: the claude
# wrapper does (Omnigent starts its sessions through the wrapper, with a
# filtered environment), and pi-web-start.sh does, whose environment the Paseo
# daemon inherits. An explicit value wins; Claude Code reads only 1/true/yes/on
# as "off", so DISABLE_AUTOUPDATER=0 lets it update itself where that reaches.
export DISABLE_AUTOUPDATER="${DISABLE_AUTOUPDATER:-1}"

# Scoped Node + our wrappers first on PATH.
export PATH="${PI_AGENT_HOME}/bin:${PI_AGENT_HOME}/node/bin:${PATH}"

# macOS only: Homebrew is not on PATH in a non-login shell or a launchd job, so
# anything spawned from here cannot see it -- including `tmux`, which Omnigent's
# native Pi harness runs the Pi TUI inside, and which the plugin's dependency
# discovery reports as missing without this. Appended, not prepended: the scoped
# Node and wrappers above must still win.
if [ "$(uname -s)" = "Darwin" ]; then
    for _pa_brew_bin in /opt/homebrew/bin /usr/local/bin; do
        if [ -d "$_pa_brew_bin" ]; then
            case ":${PATH}:" in
                *":${_pa_brew_bin}:"*) ;;
                *) PATH="${PATH}:${_pa_brew_bin}" ;;
            esac
        fi
    done
    unset _pa_brew_bin
    export PATH
    # Intel Macs: the Omnigent plugin installs its own omnigent with
    # `uv tool install`, resolving afresh, and that resolution picks releases of
    # cryptography and argon2-cffi-bindings that publish no x86_64 macOS wheel --
    # so uv tries source builds a Mac cannot finish. Resolve against the
    # hash-locked requirements the omnigent stage installed from instead, which
    # carry Intel-only pins for those two. Read only by the darwin patch's edit
    # to the plugin's installer, so no other uv on this PATH is affected.
    if [ "$(uname -m)" = "x86_64" ] && [ -r "${PI_AGENT_HOME}/omnigent/requirements.lock" ]; then
        export PI_OMNIGENT_UV_CONSTRAINTS="${PI_AGENT_HOME}/omnigent/requirements.lock"
    fi
fi

# Plugin + runtime roots (match the k3s image ENV so the seeds/routes resolve).
export PI_OMNIGENT_PLUGIN_ROOT="${PI_AGENT_HOME}/plugins/pi-omnigent-plugin"
export PI_OMNIGENT_SDK_ROOT="${PI_AGENT_HOME}/piweb/lib/node_modules/@agegr/pi-web"
export PI_PASEO_RUNTIME_DIR="${PI_AGENT_HOME}/paseo-runtime"
export PI_PASEO_PLUGIN_ROOT="${PI_AGENT_HOME}/plugins/pi-paseo-plugin"
export PI_PASEO_WEB_ARCHIVE="${PI_AGENT_HOME}/paseo-web/client.tar.gz"

# LiteLLM (or any OpenAI-compatible) gateway credentials, written by
# pi-agent-litellm. Kept out of models.json, which references ${LITELLM_API_KEY}.
if [ -r "${PI_AGENT_HOME}/litellm.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "${PI_AGENT_HOME}/litellm.env"
    set +a
fi
