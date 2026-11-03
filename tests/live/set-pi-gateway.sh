#!/usr/bin/env bash
# Live-test helper (runs inside the PiAgent distro, as its user; see docs/WSL2-LIVE-TEST.md): give Pi a model source,
# the user's LiteLLM gateway. The key comes in the environment of the job and is stored by pi-agent-litellm in a mode
# 600 file, never in models.json.
set -euo pipefail
: "${LITELLM_BASE_URL:?not set}" "${LITELLM_API_KEY:?not set}"
PA="${PI_AGENT_HOME:-$HOME/.local/share/pi-agent}"

"$PA/bin/pi-agent-litellm" set --base-url "$LITELLM_BASE_URL" --key-env
# Most gateway models fail for billing reasons upstream and Pi's automatic choice is the first in the list, so keep
# only the ones that really answer (docs/TESTING.md, "Pi -> LiteLLM gateway").
timeout 900 "$PA/bin/pi-agent-litellm" probe --apply || echo "probe did not finish; the full model list stays"
