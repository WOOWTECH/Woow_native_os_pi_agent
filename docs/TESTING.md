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
