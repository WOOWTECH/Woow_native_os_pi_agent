# Testing / QA

## Linux — validated 2026-11-01 (on an internal Ubuntu 24.04 host)

A full QA pass on a clean machine. All green.

### Clean one-command install
`./install.sh` from a wiped `$PI_AGENT_HOME`, all 9 stages end to end:

```
preflight (skips apt when deps present) → node 22.23.4 → fetch (plugins +
settings-patch sha256 verified) → piweb (built from source, Omnigent/Paseo
routes compiled, CJK patch applied) → clis (claude 2.1.296 + codex 0.162.1) →
paseo (@getpaseo/cli 0.11.2) → omnigent (0.16.0 uv venv) → wire (settings.json
auto-registers both plugins) → service (systemd --user, enabled + started)
done: preflight node fetch piweb clis paseo omnigent wire service
```

### Smoke test (`tests/smoke-linux.sh`) — 24 passed, 0 failed
- **versions**: pi 1.4.0, claude 2.1.296, codex 0.162.1
- **service**: active + enabled (survives boot)
- **http**: `/`, `/api/home`, `/omnigent` all 200
- **plugin state**: `settings.json` registers both plugins; `/api/omnigent`
  reports `active:true`, 3 engines, version 0.3.31
- **skill sharing**: a skill under `data/skills/` is visible through
  `~/.claude/skills`, `~/.pi/agent/skills`, and `~/.agents/skills`
- **MCP sharing**: an http + a stdio server from `data/mcp.json` land in both
  `~/.claude.json` and `~/.codex/config.toml`; `claude mcp list` lists them;
  removing one prunes it from both (managed-marker tracking)
- **restart**: pi-web serves again after `systemctl --user restart`

Run it yourself:
```bash
bash tests/smoke-linux.sh    # exits non-zero on any failure
```

### Browser verification (real Chromium, over an SSH tunnel to localhost:30141)
- Settings dialog renders all 8 tabs: 一般 · 模型 · 技能 · 子代理 · 外掛 · MCP ·
  **Omnigent** · **Paseo**. UI is Traditional Chinese.
- The **Omnigent** tab is fully populated: connection form + the three detected
  engines (Claude Code 2.1.296, Codex 0.162.1, Pi Agent 1.4.0) + the
  conversation-verification panel. (Before the `settings.json` fix it showed
  "插件已停用".)

### Known-remaining (need external input, not installer bugs)
- **Live Omnigent connect** needs an Omnigent **server URL + account/password**.
- **Model availability** ("0 個模型") needs model auth: `claude auth login` /
  `codex login` (the user's own accounts) or an Omnigent server connection.
- **macOS** is gated on the plugin portability item — see `DESIGN.md` §6.
- **Windows (WSL2)** reuses this exact Linux path; pending a test target.

## Pi → LiteLLM gateway — validated 2026-11-01

Wired with `pi-agent-litellm set --base-url <gw>/v1 --key-stdin` against the
WOOWTECH PaaS LiteLLM release (a per-workspace `paas-ws-*` Helm release reached
over its public hostname). The key lands in `$PI_AGENT_HOME/litellm.env`
(mode 600) and `models.json` references it as `${LITELLM_API_KEY}`, so no
credential is stored in `models.json`.

Verified on the Linux host:
- `pi auth check --provider litellm --json` → `{"status":"ready","authType":"api_key"}`
- `pi --list-models` lists all **81** gateway models
- **Conversation + model switching**: four different models each returned their
  own distinct expected string —
  `apporo/gpt-6-astra`, `apporo/gpt-6-sol`, `chatgpt-pool/gpt-6-sol`,
  `qwen3-4b-cluster1` (a local GPU endpoint behind the gateway).
- Select with the provider prefix: `pi --model litellm/apporo/gpt-6-astra`.
  Ids keep their slashes because that is what goes on the wire.

### Findings worth knowing
1. **Most gateway models fail for upstream billing/quota reasons, not wiring.**
   Probing all 81: **24 answer**. The rest fail upstream —
   `woowtech/claude-*` and `anthropic/*`: Anthropic credit exhausted;
   `chatgpt/*`: `usage_limit_reached`; anything routed through OpenRouter
   (`deepseek/*`, `z-ai/*`, `openai/*` per `/model/info`): HTTP 402
   "upstream provider declined for a billing reason".
   Reliable groups observed: `apporo/gpt-*`, `chatgpt-pool/gpt-*`,
   `qwen3-4b-*` (local GPU), several `:free` models.
2. **`settings.json` `defaultModel` is ignored by `pi -p`** (pi 1.4.0). Print
   mode falls back to automatic selection, which takes the alphabetically first
   catalog entry — `anthropic/claude-fable-5.1` here, one of the no-credit ones.
   Pass `--model` explicitly, or keep no-credit models out of the gateway.
3. **Using Pi *through Omnigent* needs two files that `models.json` does not
   touch.** Omnigent enumerates a self-hosted Pi's models in
   `omnigent/harnesses/pi_native/credentials.py::pi_own_login_model_options`
   as the **intersection** of
   - `<agent-dir>/auth.json` — provider ids Pi has logged in to, and
   - `<agent-dir>/models-store.json` — Pi's catalog cache, which is
     **undocumented** (Pi's own configuration.md does not list it).

   It never reads `models.json`, which is the documented way to add a
   compatible endpoint. So a gateway wired the documented way is invisible to
   Omnigent: `pi auth check` says `ready`, `pi --list-models` shows every model
   and conversations work, while Omnigent reports `MODELS_UNAVAILABLE` and the
   mobile UI shows "Models unavailable".

   Note this is **not** a bug in `pi-omnigent-plugin`: its own
   `nativePiLoginFingerprint()` gate (also `auth.json`-based) is consistent
   with what the host requires. The gap is in the `omnigent` package itself
   (0.16.0, Databricks, Inc.) — a third-party dependency, not ours.

   **Resolution used here**, both reproducible through `pi-agent-litellm`:
   - `pi` → `/login` → *Sign in with an API key* → `litellm` → paste the key.
     This writes `auth.json`. Pi has no non-interactive login, so this step is
     manual. **It stores the key in cleartext** — accepted here for testing;
     rotate it afterwards.
   - `pi-agent-litellm` seeds `models-store.json` from `models.json` on every
     `set` / `refresh` / `probe --apply`. Pi only writes that file for
     providers it refreshes over the network, and a statically declared
     compatible endpoint is never refreshed — confirmed by removing the
     `models` array, which left Pi with 0 models rather than discovering them.

   After both, all three engines verify:
   `claude ready+verified (4)`, `codex ready+verified (8)`,
   `pi ready+verified (24)`, and the connection phase finally reaches
   **`ready`** instead of `needs-verification`.

4. **Prune dead models, or every unqualified Pi run fails.** Pi's automatic
   selection takes the **first** entry in the provider's model list, and the
   gateway's alphabetically first model (`anthropic/claude-fable-5.1`) is one
   of the no-credit ones — so `pi -p`, and Omnigent's own verification, both
   died with `PROVIDER_PAYMENT_REQUIRED` while 23 working models sat further
   down the list. `pi-agent-litellm probe --apply` tests every model and keeps
   only the ones that answer (81 → 24 here), which makes the automatic default
   a working model and the Omnigent picker honest.
