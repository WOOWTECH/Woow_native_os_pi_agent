#!/usr/bin/env bash
# Live-test helper (runs inside the PiAgent distro, as its user; see docs/WSL2-LIVE-TEST.md): give Pi a model source,
# the user's LiteLLM gateway. The key comes in the environment of the job and is stored by pi-agent-litellm in a mode
# 600 file, never in models.json.
#
# The gateway is OPTIONAL for the live test: Claude Code, Codex and Pi on its own login can all be tried without it.
# So a gateway that does not answer is a warning, never a failure -- the first live run with the secrets set died here
# on an HTTP 401 and took the whole test with it. What the warning says is limited to things that cannot give a secret
# away: the status code, the shape of the URL, the length and prefix of the key. The values never appear, and neither
# does anything the gateway sends back except a fixed keyword.
set -euo pipefail
: "${LITELLM_BASE_URL:?not set}" "${LITELLM_API_KEY:?not set}"
PA="${PI_AGENT_HOME:-$HOME/.local/share/pi-agent}"
BODY="$(mktemp "${TMPDIR:-/tmp}/pa-gw-body.XXXXXX")"
trap 'rm -f "$BODY"' EXIT

# What gets pasted into a phone's secret form is not always what was meant: a newline at the end, a space, quotes.
strip() { local s="$1"; s="${s//[$'\n\r\t ']/}"; s="${s#\"}"; s="${s%\"}"; s="${s#\'}"; s="${s%\'}"; printf '%s' "$s"; }
yn() { if "$@"; then echo yes; else echo no; fi; }

url="$(strip "$LITELLM_BASE_URL")"
key="$(strip "$LITELLM_API_KEY")"
scheme=none; case "$url" in *://*) scheme="${url%%://*}" ;; esac
facts="url: scheme=$scheme ends-with-/v1=$(yn test "${url%/v1}" != "$url") trailing-slash=$(yn test "${url%/}" != "$url") trimmed=$(yn test "$url" != "$LITELLM_BASE_URL")"
facts="$facts; key: length=${#key} starts-with-sk-=$(yn test "${key#sk-}" != "$key") trimmed=$(yn test "$key" != "$LITELLM_API_KEY")"

# $1 = what went wrong, in words. The step goes on without the gateway.
carry_on() {
  echo "::warning title=LiteLLM gateway not used (Pi will use its own login)::$1 | $facts"
  echo "LiteLLM: $1"
  echo "LiteLLM: $facts"
  echo "LiteLLM: carrying on without it -- Pi needs its own login (run pi, then /login)"
  exit 0
}

case "$url" in https://*|http://*) ;; *) carry_on "the base URL does not start with http:// or https://" ;; esac

code="$(curl -sS -m 25 -o "$BODY" -w '%{http_code}' -H "Authorization: Bearer $key" "${url%/}/models" 2>/dev/null)" || code=000
if [ "$code" != 200 ]; then
  why="the gateway answered HTTP $code to GET /models"
  if [ "$code" = 000 ]; then why="could not reach the gateway (no answer, bad host name, or timed out)"; fi
  if grep -qi 'invalid proxy server token' "$BODY" 2>/dev/null; then why="$why; it says the key is not a valid key"; fi
  if grep -qi 'no api key passed' "$BODY" 2>/dev/null; then why="$why; it says no key reached it"; fi
  if grep -qi 'cloudflare' "$BODY" 2>/dev/null; then why="$why; the reply looks like Cloudflare's, not the gateway's"; fi
  carry_on "$why"
fi

export LITELLM_API_KEY="$key"
"$PA/bin/pi-agent-litellm" set --base-url "$url" --key-env || carry_on "pi-agent-litellm set failed although the gateway answered 200"
# Most gateway models fail for billing reasons upstream and Pi's automatic choice is the first in the list, so keep
# only the ones that really answer (docs/TESTING.md, "Pi -> LiteLLM gateway").
timeout 900 "$PA/bin/pi-agent-litellm" probe --apply || echo "probe did not finish; the full model list stays"
echo "::notice title=LiteLLM gateway in use::Pi has the gateway's models ($facts)"
