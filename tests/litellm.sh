#!/bin/bash
# pi-agent-litellm against a gateway that answers the way the one behind the H618 boards did: what goes into
# models.json, how much output the probe asks each model for, and which model Pi starts with afterwards.
#
# Why this exists. Found on Allwinner H618 4 GB boards (v0.3.0-rc.3, pi 1.4.0), 2026-11-09/10:
#   * models.json carried only {id}, so Pi assumed a 128000-token window and asked for 16384 output tokens on every
#     turn: qwen3-4b-cluster1 (24,576 tokens) behind an MCP server's 8.2k-token tool prompt failed every turn with
#     ContextWindowExceededError;
#   * `probe --apply` asked for 96 tokens, so models passed it that answered every real Pi turn with HTTP 402
#     (OpenRouter's billing refusal: anthropic/claude-haiku-5.5 took max_tokens 16 and refused 8000);
#   * with no default set, Pi took the first model listed, anthropic/claude-fable-5.1 -- one of those.
#
#   A  set: the limits from /model/info go into models.json and models-store.json; the key stays a reference
#   B  a gateway without /model/info: entries as before, and a warning
#   C  probe: each model is asked, with a tiny prompt, for as much output as Pi will ask it for; nothing is written
#   D  probe --apply: prunes, then keeps a default that still answers or picks the first model that does
#   E  default [MODEL]: Pi's own two keys, nothing else in settings.json changes, under Pi's own lock
#   R  the real Pi (PA_TEST_PI_MODULES): accepts those limits, starts with that default, and the 24,576-token model
#      now gets a turn that fits -- the same turn that overflowed with the entry as main wrote it
#
#   tests/litellm.sh
#   PI_TEST_LITELLM=/path/to/an/older/pi-agent-litellm tests/litellm.sh     (expect failures: that is the check)
#
# Hermetic: a temp install root, a stub gateway on 127.0.0.1 (tests/litellm/gateway.mjs) and a made-up key. It reads
# no real litellm.env, talks to no real gateway and starts nothing outside its temp directory.
#
# Environment (all optional):
#   PA_TEST_NODE         node to use (default: node on PATH)
#   PA_TEST_PI_MODULES   a node_modules directory with @earendil-works/pi-coding-agent and its dependencies, for R
#                        (npm install @earendil-works/pi-coding-agent@1.4.0 in a scratch directory); skipped without it
#   PA_TEST_KEEP=1       keep the work directory
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LITELLM="${PI_TEST_LITELLM:-$HERE/rootfs/bin/pi-agent-litellm}"
NODE="${PA_TEST_NODE:-$(command -v node || true)}"
[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "no node found (set PA_TEST_NODE)" >&2; exit 2; }
pass=0; fail=0; skipped=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }
skip() { printf '  SKIP  %s\n' "$1"; skipped=$((skipped + 1)); }
# expect LABEL GOT WANT
expect() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got  $2 | wanted $3"; fi; }
# has LABEL HAYSTACK NEEDLE
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "no '$3' in: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-400)" ;; esac; }

W="$(mktemp -d "${TMPDIR:-/tmp}/pa-litellm.XXXXXX")" || exit 2
GW_PID=""
cleanup() {
  [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null
  if [ "${PA_TEST_KEEP:-}" = 1 ]; then echo "kept $W"; else rm -rf "$W"; fi
}
trap cleanup EXIT
mkdir -p "$W/home" "$W/cwd"

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
now_ms() { "$NODE" -e 'console.log(Date.now())'; }
# js EXPR FILE...: a JavaScript expression over the parsed JSON files f[0], f[1], ... (null when unreadable)
js() {
  "$NODE" -e '
    const fs=require("fs");
    const f=process.argv.slice(2).map(p=>{ try{ return JSON.parse(fs.readFileSync(p,"utf8")); }catch{ return null; } });
    const v=(new Function("f","return ("+process.argv[1]+")"))(f);
    console.log(typeof v==="string"?v:JSON.stringify(v));' "$@"
}

# make_tree DIR: an install root with what pi-agent-litellm needs, and nothing else
make_tree() {
  mkdir -p "$1/bin" "$1/node/bin" "$1/home" "$1/data"
  cp "$LITELLM" "$1/bin/pi-agent-litellm"
  cp "$HERE/rootfs/bin/pi-agent-env.sh" "$1/bin/pi-agent-env.sh"
  ln -s "$NODE" "$1/node/bin/node"
  chmod 755 "$1/bin/pi-agent-litellm"
}
PA="$W/pa"; make_tree "$PA"
DATA="$PA/data"; MODELS="$DATA/models.json"; STORE="$DATA/models-store.json"; SETTINGS="$DATA/settings.json"
KEY="sk-test-$$-not-a-real-key"
# lit ARGS...: pi-agent-litellm in the temp tree, with nothing inherited from this shell
lit() { env -i HOME="$W/home" PATH=/usr/bin:/bin PI_AGENT_HOME="$PA" /bin/bash "$PA/bin/pi-agent-litellm" "$@"; }

# The stub gateway. Model ids sort in this order, which is the order Pi would take them in.
CFG="$W/gateway.json"; LOG="$W/requests.log"
cat > "$CFG" <<EOF
{ "key": "$KEY", "modelInfo": true, "models": [
  { "id": "anthropic/claude-fable-5.1", "info": [{ "max_input_tokens": 200000, "max_output_tokens": 64000 }], "answer": { "billingAbove": 1000 } },
  { "id": "apporo/gpt-6-astra", "info": [{ "max_input_tokens": 272000, "max_output_tokens": 128000 }, { "max_input_tokens": 128000, "max_output_tokens": 16384 }] },
  { "id": "apporo/gpt-6-sol", "info": [{ "max_input_tokens": 400000, "max_output_tokens": 128000 }] },
  { "id": "chatgpt/gpt-5", "answer": "dead" },
  { "id": "free/model:free", "info": [{ "max_input_tokens": 32768, "max_output_tokens": 32768 }] },
  { "id": "old/gpt-small-out", "info": [{ "max_input_tokens": 16385, "max_output_tokens": 4096 }] },
  { "id": "only/out", "info": [{ "max_output_tokens": 8192 }] },
  { "id": "qwen3-4b-cluster1", "info": [{ "max_input_tokens": 24576, "max_output_tokens": null }], "contextWindow": 24576 },
  { "id": "weird/values", "info": [{ "max_input_tokens": 0, "max_output_tokens": "8192" }] }
] }
EOF
# gw EXPR: change the stub's config, e.g. gw 'c.modelInfo=false'
gw() { "$NODE" -e 'const fs=require("fs"),f=process.argv[1],c=JSON.parse(fs.readFileSync(f,"utf8")); const m=id=>c.models.find(x=>x.id===id); (new Function("c","m",process.argv[2]))(c,m); fs.writeFileSync(f,JSON.stringify(c,null,1));' "$CFG" "$1"; }
"$NODE" "$HERE/tests/litellm/gateway.mjs" "$CFG" "$W/port" "$LOG" &
GW_PID=$!
for _ in $(seq 100); do [ -s "$W/port" ] && break; sleep 0.1; done
[ -s "$W/port" ] || { echo "the stub gateway did not start" >&2; exit 2; }
BASE="http://127.0.0.1:$(cat "$W/port")/v1"

echo "== A. set: limits from /model/info"
# another provider's block must survive
printf '{\n  "providers": {\n    "local-ollama": { "baseUrl": "http://127.0.0.1:11434/v1", "api": "openai-completions", "models": [{ "id": "llama3" }] }\n  }\n}\n' > "$MODELS"
out="$(printf '%s' "$KEY" | lit set --base-url "$BASE" --key-stdin 2>&1)"; rc=$?
expect "set exits 0" "$rc" 0
has "...and says how many models have limits" "$out" "context window and output limit for 7 of 9 model(s)"
want='[{"id":"anthropic/claude-fable-5.1","contextWindow":200000,"maxTokens":16384},{"id":"apporo/gpt-6-astra","contextWindow":128000,"maxTokens":16384},{"id":"apporo/gpt-6-sol","contextWindow":400000,"maxTokens":16384},{"id":"chatgpt/gpt-5"},{"id":"free/model:free","contextWindow":32768,"maxTokens":16384},{"id":"old/gpt-small-out","contextWindow":16385,"maxTokens":4096},{"id":"only/out","maxTokens":8192},{"id":"qwen3-4b-cluster1","contextWindow":24576,"maxTokens":12288},{"id":"weird/values"}]'
expect "each entry: the window, and an output limit that is the model's, at most half the window, at most 16384" \
  "$(js 'f[0].providers.litellm.models' "$MODELS")" "$want"
expect "a 24,576-token model with no stated output limit: maxTokens 12288, not Pi's 16384" \
  "$(js 'f[0].providers.litellm.models.find(m=>m.id==="qwen3-4b-cluster1").maxTokens' "$MODELS")" 12288
expect "two deployments of one model: the smaller limits of the two" \
  "$(js 'JSON.stringify(f[0].providers.litellm.models.find(m=>m.id==="apporo/gpt-6-astra"))' "$MODELS")" '{"id":"apporo/gpt-6-astra","contextWindow":128000,"maxTokens":16384}'
expect "the key is a reference in models.json, not the key" "$(js 'f[0].providers.litellm.apiKey' "$MODELS")" '${LITELLM_API_KEY}'
leak="$(cd "$PA" && LC_ALL=C grep -rlF "$KEY" . 2>/dev/null | sort | tr '\n' ' ')"
expect "...and the key is in litellm.env only" "$leak" "./litellm.env "
expect "litellm.env and models.json are mode 600" "$(mode_of "$PA/litellm.env") $(mode_of "$MODELS")" "600 600"
expect "another provider's block is kept" "$(js 'f[0].providers["local-ollama"].models[0].id' "$MODELS")" llama3
expect "models-store.json mirrors the entries and their limits" \
  "$(js 'JSON.stringify(f[0].litellm.models.map(({name,...m})=>m))' "$STORE")" "$want"

echo "== B. a gateway without /model/info"
gw 'c.modelInfo=false'
out="$(lit refresh 2>&1)"; rc=$?
expect "refresh still works (exit 0)" "$rc" 0
has "...and warns that Pi assumes its defaults" "$out" "no model limits"
expect "...and every entry is {id}, as before" "$(js 'f[0].providers.litellm.models.every(m=>Object.keys(m).join()==="id")' "$MODELS")" true
gw 'c.modelInfo=true'
lit refresh >/dev/null 2>&1
expect "with /model/info back, refresh puts the limits back" "$(js 'f[0].providers.litellm.models' "$MODELS")" "$want"

echo "== C. probe: as much output as Pi will ask for"
printf '{\n  "packages": [\n    "/opt/pi-agent/plugins/pi-omnigent-plugin",\n    "/opt/pi-agent/plugins/pi-paseo-plugin"\n  ],\n  "theme": "dark"\n}\n' > "$SETTINGS"
chmod 640 "$SETTINGS"
m_before="$(sha "$MODELS")"; s_before="$(sha "$SETTINGS")"
: > "$LOG"
out="$(lit probe 2>&1)"; rc=$?
expect "probe exits 0" "$rc" 0
# Pi 1.4.0 asks for min(maxTokens, contextWindow - prompt - 4096); the prompt is 9 tokens by Pi's estimate
expect "max_completion_tokens, per model, is what Pi asks for (maxTokens, or 16384 without one)" \
  "$("$NODE" -e 'const r={};for(const l of require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean)){const j=JSON.parse(l);r[j.model]=j.max_completion_tokens;}console.log(JSON.stringify(r))' "$LOG")" \
  '{"anthropic/claude-fable-5.1":16384,"apporo/gpt-6-astra":16384,"apporo/gpt-6-sol":16384,"chatgpt/gpt-5":16384,"free/model:free":16384,"old/gpt-small-out":4096,"only/out":8192,"qwen3-4b-cluster1":12288,"weird/values":16384}'
expect "...in the field Pi sends to an OpenAI-compatible gateway (no max_tokens)" \
  "$("$NODE" -e 'console.log(require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).every(l=>JSON.parse(l).max_tokens===undefined))' "$LOG")" true
expect "...with a one-line prompt, so a probe stays cheap" \
  "$("$NODE" -e 'console.log([...new Set(require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(l=>{const j=JSON.parse(l);return j.messages+":"+j.prompt;}))].join())' "$LOG")" "1:Reply with the single word OK"
has "a model that refuses that much output on billing grounds is dead" "$out" "dead anthropic/claude-fable-5.1  (HTTP 402 at max_tokens 16384)"
has "a model that fails outright is dead" "$out" "dead chatgpt/gpt-5  (HTTP 500"
has "the 24,576-token model answers at its 12288" "$out" "OK   qwen3-4b-cluster1  (max_tokens 12288)"
has "summary" "$out" "probe: 7 usable, 2 unusable"
code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"anthropic/claude-fable-5.1","max_tokens":96,"messages":[{"role":"user","content":"Reply with the single word OK"}]}' "$BASE/chat/completions")"
expect "(control) the request the old probe sent, 96 tokens, gets 200 from that same model" "$code" 200
expect "probe without --apply writes nothing" "$(sha "$MODELS") $(sha "$SETTINGS")" "$m_before $s_before"

echo "== D. probe --apply, and the default it leaves"
out="$(lit probe --apply 2>&1)"; rc=$?
expect "probe --apply exits 0" "$rc" 0
has "models.json keeps the 7 that answered" "$out" "models.json kept 7 of 9"
expect "...and drops the two that did not" "$(js 'f[0].providers.litellm.models.map(m=>m.id).filter(i=>i.startsWith("anthropic/")||i.startsWith("chatgpt/")).length' "$MODELS")" 0
has "no default before: the first model that answered becomes it, and it says so" "$out" "Pi default is now litellm/apporo/gpt-6-astra (there was none)"
expect "settings.json: Pi's two keys added, every other key kept in its place" \
  "$(js 'JSON.stringify(f[0])' "$SETTINGS")" \
  '{"packages":["/opt/pi-agent/plugins/pi-omnigent-plugin","/opt/pi-agent/plugins/pi-paseo-plugin"],"theme":"dark","defaultProvider":"litellm","defaultModel":"apporo/gpt-6-astra"}'
expect "...its mode kept (640), no lock or temp file left" "$(mode_of "$SETTINGS") $(ls -a "$DATA" | grep -c -e '\.lock$' -e '\.tmp$')" "640 0"
lit default qwen3-4b-cluster1 >/dev/null 2>&1
s_before="$(sha "$SETTINGS")"
out="$(lit probe --apply 2>&1)"
has "a default that still answers is kept, even when it is not the first" "$out" "Pi default stays litellm/qwen3-4b-cluster1 (it answered)"
expect "...and settings.json is not rewritten" "$(sha "$SETTINGS")" "$s_before"
gw 'm("qwen3-4b-cluster1").answer="dead"'
out="$(lit probe --apply 2>&1)"
has "a default that stopped answering is replaced by the first that answers" "$out" "Pi default is now litellm/apporo/gpt-6-astra (was litellm/qwen3-4b-cluster1, which did not answer)"
gw 'm("qwen3-4b-cluster1").answer="ok"'
"$NODE" -e 'const fs=require("fs"),f=process.argv[1],s=JSON.parse(fs.readFileSync(f,"utf8"));s.defaultProvider="anthropic";s.defaultModel="claude-own-login";fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n")' "$SETTINGS"
s_before="$(sha "$SETTINGS")"
out="$(lit probe --apply 2>&1)"
has "a default on another provider (the user's own Pi login) is left alone" "$out" "Pi default stays anthropic/claude-own-login (not this gateway; left as it is)"
expect "...byte for byte" "$(sha "$SETTINGS")" "$s_before"
lit default apporo/gpt-6-sol >/dev/null 2>&1
lit refresh >/dev/null 2>&1
gw 'c.models.forEach(x=>x.answer="dead")'
m_before="$(sha "$MODELS")"; s_before="$(sha "$SETTINGS")"
out="$(lit probe --apply 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "nothing answers (gateway down): --apply refuses (exit $rc)" || no "nothing answers (gateway down): --apply refuses" "exit 0: $out"
has "...and says why" "$out" "no model answered, so nothing was applied"
expect "...leaving models.json and settings.json as they were" "$(sha "$MODELS") $(sha "$SETTINGS")" "$m_before $s_before"
gw 'c.models.forEach(x=>{ x.answer = x.id==="anthropic/claude-fable-5.1" ? {billingAbove:1000} : x.id==="chatgpt/gpt-5" ? "dead" : "ok"; })'
expect "after a refresh the whole list is back, dead models first" "$(js 'f[0].providers.litellm.models[0].id' "$MODELS")" anthropic/claude-fable-5.1
expect "...and the default still names a model that answers" "$(js 'f[0].defaultProvider+"/"+f[0].defaultModel' "$SETTINGS")" litellm/apporo/gpt-6-sol

echo "== E. default [MODEL]"
expect "default with no argument shows it" "$(lit default 2>&1)" "Pi default: litellm/apporo/gpt-6-sol"
out="$(lit default litellm/apporo/gpt-6-astra 2>&1)"; rc=$?
expect "the name Pi prints (litellm/<id>) is accepted" "$rc $(js 'f[0].defaultModel' "$SETTINGS")" "0 apporo/gpt-6-astra"
lit default qwen3-4b-cluster1 >/dev/null 2>&1
expect "...and so is the bare id" "$(js 'f[0].defaultProvider+"/"+f[0].defaultModel' "$SETTINGS")" litellm/qwen3-4b-cluster1
expect "only those two keys changed" "$(js 'Object.keys(f[0]).join()+"|"+f[0].theme+"|"+f[0].packages.length' "$SETTINGS")" "packages,theme,defaultProvider,defaultModel|dark|2"
s_before="$(sha "$SETTINGS")"
out="$(lit default nope/not-a-model 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "a model the gateway does not list is refused (exit $rc)" || no "a model the gateway does not list is refused" "exit 0"
has "...naming it" "$out" "nope/not-a-model is not one of the"
expect "...and settings.json is untouched" "$(sha "$SETTINGS")" "$s_before"
printf '[1, 2]\n' > "$W/array.json"; cp "$W/array.json" "$SETTINGS"
out="$(lit default apporo/gpt-6-sol 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(sha "$SETTINGS")" = "$(sha "$W/array.json")" ] && ok "a settings.json that is not a JSON object is refused and left as it is" || no "a settings.json that is not a JSON object is refused and left as it is" "exit $rc: $out"
rm -f "$SETTINGS"
lit default apporo/gpt-6-sol >/dev/null 2>&1
expect "no settings.json: one is made with just the two keys" "$(js 'JSON.stringify(f[0])' "$SETTINGS")" '{"defaultProvider":"litellm","defaultModel":"apporo/gpt-6-sol"}'
printf '\357\273\277{"theme": "dark"}\n' > "$SETTINGS"
lit default apporo/gpt-6-sol >/dev/null 2>&1
expect "a settings.json that starts with a byte-order mark (Pi strips one too) is read, and written back without it" \
  "$(head -c 1 "$SETTINGS") $("$NODE" -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(s.theme+"/"+s.defaultModel)' "$SETTINGS")" "{ dark/apporo/gpt-6-sol"
mkdir "$SETTINGS.lock"
( sleep 0.6; rmdir "$SETTINGS.lock" ) & holder=$!
t0="$(now_ms)"; out="$(lit default free/model:free 2>&1)"; rc=$?; t1="$(now_ms)"
wait "$holder"
if [ "$rc" = 0 ] && [ $((t1 - t0)) -ge 500 ] && [ "$(js 'f[0].defaultModel' "$SETTINGS")" = "free/model:free" ]; then
  ok "Pi's lock (settings.json.lock) held by someone else: it waits for it, then writes ($((t1 - t0)) ms)"
else no "Pi's lock (settings.json.lock) held by someone else: it waits for it, then writes" "exit $rc after $((t1 - t0)) ms: $out"; fi
mkdir "$SETTINGS.lock"; "$NODE" -e 'const t=(Date.now()-60000)/1000; require("fs").utimesSync(process.argv[1],t,t)' "$SETTINGS.lock"
t0="$(now_ms)"; out="$(lit default apporo/gpt-6-sol 2>&1)"; rc=$?; t1="$(now_ms)"
if [ "$rc" = 0 ] && [ ! -e "$SETTINGS.lock" ] && [ "$(js 'f[0].defaultModel' "$SETTINGS")" = "apporo/gpt-6-sol" ]; then
  ok "a stale lock (a minute old, as proper-lockfile judges) is taken over at once ($((t1 - t0)) ms)"
else no "a stale lock (a minute old, as proper-lockfile judges) is taken over at once" "exit $rc after $((t1 - t0)) ms: $out"; fi
has "status shows the default" "$(lit status 2>&1)" "Pi default        : litellm/apporo/gpt-6-sol"

echo "== R. the real Pi"
PI_CLI="${PA_TEST_PI_MODULES:-}/@earendil-works/pi-coding-agent/dist/cli.js"
if [ -z "${PA_TEST_PI_MODULES:-}" ] || [ ! -f "$PI_CLI" ]; then
  skip "R* -- needs PA_TEST_PI_MODULES, a node_modules with @earendil-works/pi-coding-agent and its dependencies"
else
  PR="$W/pa-r"; make_tree "$PR"
  cp "$HERE/rootfs/bin/pi" "$PR/bin/pi"; chmod 755 "$PR/bin/pi"
  mkdir -p "$PR/piweb"; ln -s "$PA_TEST_PI_MODULES" "$PR/piweb/node_modules"   # where the pi wrapper looks
  env -i HOME="$W/home" PATH=/usr/bin:/bin PI_AGENT_HOME="$PR" /bin/bash "$PR/bin/pi-agent-litellm" set --base-url "$BASE" --key-stdin <<<"$KEY" >/dev/null 2>&1
  env -i HOME="$W/home" PATH=/usr/bin:/bin PI_AGENT_HOME="$PR" /bin/bash "$PR/bin/pi-agent-litellm" default apporo/gpt-6-sol >/dev/null 2>&1
  # pir ARGS...: the real pi, through the install's own pi wrapper (for at most 90 s where there is a `timeout`); its
  # stderr goes to a log. Pi's print mode exits 0 even when the request failed, so what it printed is what is checked.
  limit=""; command -v timeout >/dev/null 2>&1 && limit="timeout 90"
  pir() {
    ( cd "$W/cwd" && exec $limit env -i HOME="$W/home" PATH=/usr/bin:/bin PI_AGENT_HOME="$PR" /bin/bash "$PR/bin/pi" \
        --offline --no-session --no-extensions --no-skills --no-context-files "$@" </dev/null 2>>"$W/pi-stderr.log" )
  }
  last_request() { "$NODE" -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).at(-1)||{};console.log((new Function("l","return "+process.argv[2]))(l))' "$LOG" "$1"; }
  ver="$(pir --version | tail -1)"
  listing="$(pir --list-models)"
  row() { printf '%s\n' "$listing" | awk -v id="$1" '$1=="litellm" && $2==id {print $3" "$4}'; }
  expect "Pi ($ver) reads the 24,576-token model's limits from models.json" "$(row qwen3-4b-cluster1)" "24.6K 12.3K"
  expect "...a model with no stated limits keeps Pi's defaults" "$(row weird/values)" "128K 16.4K"
  expect "...and an output limit alone" "$(row only/out)" "128K 8.2K"
  : > "$LOG"
  out="$(pir -p "Reply with the single word OK")"
  expect "pi -p naming no model answers" "$out" OK
  expect "...with the default from settings.json, not the first model listed" "$(last_request 'l.model')" apporo/gpt-6-sol
  expect "...asking it for maxTokens, as the probe did" "$(last_request 'l.max_completion_tokens')" 16384
  # The field failure: the 24,576-token model behind an MCP server whose tools make ~8.2k tokens of prompt
  "$NODE" -e 'const line=JSON.stringify({name:"odoo_search_read",description:"Search records of an Odoo model and read the given fields",parameters:{model:"string",domain:"array",fields:"array"}})+"\n"; process.stdout.write(line.repeat(Math.ceil(32800/line.length)))' > "$W/tool-prompt.txt"
  : > "$LOG"
  out="$(pir -p --model litellm/qwen3-4b-cluster1 "Reply with the single word OK")"
  expect "the 24,576-token model, a short prompt: Pi asks for its maxTokens, 12288 -- what the probe asked for" "$out $(last_request 'l.max_completion_tokens')" "OK 12288"
  : > "$LOG"
  out="$(pir -p --model litellm/qwen3-4b-cluster1 --append-system-prompt "$W/tool-prompt.txt" "Reply with the single word OK")"
  asked="$(last_request 'l.max_completion_tokens')"; total="$(last_request 'l.promptTokens+l.max_completion_tokens')"
  if [ "$out" = OK ] && [ "$asked" -lt 12288 ] && [ "$total" -le 24576 ]; then
    ok "...with an ~8.2k-token tool prompt it still answers: Pi asked for $asked, $total tokens in all"
  else no "...with an ~8.2k-token tool prompt it still answers" "output '$out', asked $asked, $total in all"; fi
  cp "$PR/data/models.json" "$W/models.with-limits.json"
  "$NODE" -e 'const fs=require("fs"),f=process.argv[1],c=JSON.parse(fs.readFileSync(f,"utf8"));c.providers.litellm.models=c.providers.litellm.models.map(m=>({id:m.id}));fs.writeFileSync(f,JSON.stringify(c,null,2))' "$PR/data/models.json"
  : > "$LOG"
  out="$(pir -p --model litellm/qwen3-4b-cluster1 --append-system-prompt "$W/tool-prompt.txt" "Reply with the single word OK")"
  asked="$(last_request 'l.max_completion_tokens')"; total="$(last_request 'l.promptTokens+l.max_completion_tokens')"
  if [ "$out" != OK ] && [ "$asked" = 16384 ] && [ "$total" -gt 24576 ]; then
    ok "(control) with the entry as main wrote it, {id}, the same turn overflows: Pi asked for 16384, $total tokens in all"
  else no "(control) with the entry as main wrote it, {id}, the same turn overflows" "output '$out', asked $asked, $total in all"; fi
  cp "$W/models.with-limits.json" "$PR/data/models.json"
fi

echo
printf 'pi-agent-litellm: %s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" = 0 ]
