#!/usr/bin/env bash
# Woow Native Pi Agent — installer (engineer bootstrap track).
#
# Assembles pinned upstream pieces into a native, non-container Pi Agent under
# $PI_AGENT_HOME (default ~/.local/share/pi-agent). Run as a normal user.
#
#   ./install.sh                 # run every stage
#   ./install.sh <stage>...      # run only the named stage(s), in order
#   PI_AGENT_HOME=/custom ./install.sh
#
# Stages: preflight node fetch piweb clis paseo omnigent wire service
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/pins.sh
. "$HERE/lib/pins.sh"

OS="$(pa_os)"; ARCH="$(pa_arch)"
[ "$ARCH" = unknown ] && die "unsupported CPU arch: $(uname -m)"

mkdirs() { mkdir -p "$PI_AGENT_HOME" "$PA_BIN_DIR" "$PA_DATA_DIR" "$PA_HOME_DIR" "$PA_LOG_DIR" "$PA_TMP_DIR" "$PA_PLUGINS_DIR" "$PA_CLIS_DIR"; }

# ---------------------------------------------------------------- preflight ---
stage_preflight() {
  log "stage preflight — os=$OS arch=$ARCH home=$PI_AGENT_HOME"
  case "$OS" in
    linux|wsl)
      local need=""
      for c in curl git gpg jq ssh xz make g++ python3 flock tmux; do have "$c" || need="$need $c"; done
      if [ -z "$need" ]; then
        log "build prerequisites already present; skipping package install"
      elif have apt-get; then
        local pkgs="ca-certificates curl git gnupg jq openssh-client xz-utils build-essential python3 python3-venv python3-pip util-linux tmux procps"
        log "installing apt deps (sudo; missing:$need)"
        sudo apt-get update -qq
        # shellcheck disable=SC2086
        sudo apt-get install -y --no-install-recommends $pkgs
      elif have dnf; then
        sudo dnf install -y ca-certificates curl git gnupg2 jq openssh-clients xz @development-tools python3 python3-pip util-linux tmux procps-ng
      else
        die "no apt-get or dnf; install deps manually"
      fi ;;
    macos)
      # Deliberately NOT requiring Homebrew. Everything this installer needs on
      # macOS either ships with the OS (git, curl, python3, bsdtar -- which reads
      # .tar.xz through libarchive, so no xz binary is needed) or is installed
      # scoped under $PI_AGENT_HOME (its own Node, and uv's own CPython for the
      # Omnigent venv). Asking a user to install a system-wide package manager
      # for an app-scoped install is the wrong trade, and a non-login shell does
      # not even have brew on PATH when it IS installed.
      local missing=""
      for c in git curl python3 tar; do have "$c" || missing="$missing $c"; done
      [ -n "$missing" ] && die "missing from this macOS install:$missing (install the Xcode Command Line Tools: xcode-select --install)"
      # tmux is needed only by Omnigent's native Pi harness, which runs the Pi
      # TUI inside its own tmux server. Install it when brew happens to be here,
      # and otherwise carry on: everything else works without it.
      if ! have tmux; then
        local brew; if brew="$(pa_brew)"; then
          log "installing tmux via $brew (Omnigent's native Pi harness needs it)"
          "$brew" install tmux >/dev/null 2>&1 || warn "brew install tmux failed; native Pi sessions through Omnigent will not work"
        else
          warn "tmux is absent and Homebrew is not installed; Omnigent's native Pi harness will not work (everything else does)"
        fi
      fi ;;
    *) die "unsupported OS: $OS" ;;
  esac
  mkdirs
  log "preflight OK"
}

# --------------------------------------------------------------------- node ---
stage_node() {
  log "stage node — scoped Node v$PIN_NODE_VERSION"
  if [ -x "$PA_NODE_DIR/bin/node" ] && [ "v$PIN_NODE_VERSION" = "$("$PA_NODE_DIR/bin/node" --version 2>/dev/null)" ]; then
    log "node already present"; return 0
  fi
  local nos narch ext url tarball
  case "$OS" in macos) nos=darwin ;; *) nos=linux ;; esac
  case "$ARCH" in x64) narch=x64 ;; arm64) narch=arm64 ;; esac
  ext=tar.xz; url="https://nodejs.org/dist/v${PIN_NODE_VERSION}/node-v${PIN_NODE_VERSION}-${nos}-${narch}.${ext}"
  tarball="$PA_TMP_DIR/node.${ext}"
  mkdir -p "$PA_TMP_DIR"
  log "download $url"
  curl -fSL --retry 5 "$url" -o "$tarball" || die "node download failed"
  rm -rf "$PA_NODE_DIR"; mkdir -p "$PA_NODE_DIR"
  # -xf, not -xJf: both GNU tar and macOS bsdtar detect xz themselves, and
  # macOS has no xz binary for GNU tar's -J to shell out to.
  tar -xf "$tarball" --strip-components=1 -C "$PA_NODE_DIR"
  rm -f "$tarball"
  "$PA_NODE_DIR/bin/node" --version | grep -qF "v$PIN_NODE_VERSION" || die "scoped node verify failed"
  log "node $("$PA_NODE_DIR/bin/node" --version) OK"
}

# -------------------------------------------------------------------- fetch ---
# Download + verify both plugin tarballs (the omnigent one carries the pi-web
# settings patch) and extract them to the plugins dir.
stage_fetch() {
  log "stage fetch — plugins"
  mkdir -p "$PA_PLUGINS_DIR" "$PA_TMP_DIR"
  local ot="$PA_TMP_DIR/omnigent-plugin.tgz" pt="$PA_TMP_DIR/paseo-plugin.tgz"
  fetch_verify "$PIN_OMNIGENT_PLUGIN_TGZ" "$PIN_OMNIGENT_PLUGIN_SHA256" "$ot"
  rm -rf "$PA_PLUGINS_DIR/pi-omnigent-plugin"; mkdir -p "$PA_PLUGINS_DIR/pi-omnigent-plugin"
  tar xzf "$ot" --strip-components=1 -C "$PA_PLUGINS_DIR/pi-omnigent-plugin"
  PA_NODE -e 'const p=require(process.argv[1]); if(p.name!=="@woowtech/pi-omnigent-plugin"||p.version!==process.argv[2]) throw Error("unexpected omnigent plugin "+p.name+"@"+p.version)' \
    "$PA_PLUGINS_DIR/pi-omnigent-plugin/package.json" "$PIN_OMNIGENT_PLUGIN_VERSION"
  fetch_verify "$PIN_PASEO_PLUGIN_TGZ" "$PIN_PASEO_PLUGIN_SHA256" "$pt"
  rm -rf "$PA_PLUGINS_DIR/pi-paseo-plugin"; mkdir -p "$PA_PLUGINS_DIR/pi-paseo-plugin"
  tar xzf "$pt" --strip-components=1 -C "$PA_PLUGINS_DIR/pi-paseo-plugin"
  PA_NODE -e 'const p=require(process.argv[1]); if(p.name!=="@woowtech/pi-paseo"||p.version!==process.argv[2]) throw Error("unexpected paseo plugin "+p.name+"@"+p.version)' \
    "$PA_PLUGINS_DIR/pi-paseo-plugin/package.json" "$PIN_PASEO_PLUGIN_VERSION"
  # verify the pi-web settings patch checksum (the thing that adds the tabs)
  local patch="$PA_PLUGINS_DIR/pi-omnigent-plugin/integrations/pi-web/combined.adapter.patch"
  [ -f "$patch" ] || die "combined.adapter.patch missing in omnigent plugin"
  local got; got="$(sha256_of "$patch")"
  [ "$got" = "$PIN_OMNIGENT_UI_SHA256" ] || die "combined.adapter.patch sha256 mismatch: $got"
  rm -f "$ot" "$pt"
  # macOS: the plugin refuses every non-Linux platform before it discovers
  # anything, so the Omnigent tab can never leave DEPENDENCIES_MISSING. Applied
  # here, right after extraction, because re-running this stage replaces the
  # source. Version-gated and never fatal -- see the script's header, and
  # docs/MACOS.md for what was measured on-device.
  if [ "$OS" = macos ] && [ -f "$HERE/rootfs/bin/omnigent-plugin-darwin-patch.mjs" ]; then
    PA_NODE "$HERE/rootfs/bin/omnigent-plugin-darwin-patch.mjs" "$PA_PLUGINS_DIR/pi-omnigent-plugin" \
      2>&1 | while IFS= read -r line; do log "$line"; done || true
  fi
  log "fetch OK (plugins verified, settings patch verified)"
}

# -------------------------------------------------------------------- piweb ---
# Build pi-web from the pinned source commit with the Omnigent/Paseo settings
# patch applied, then apply the CJK path-corruption patch. This is the heaviest
# step and the one that must be proven native.
stage_piweb() {
  log "stage piweb — build pi-web $PIN_PI_WEB_VERSION @ ${PIN_PI_WEB_REF:0:12} + settings patch"
  local patch="$PA_PLUGINS_DIR/pi-omnigent-plugin/integrations/pi-web/combined.adapter.patch"
  [ -f "$patch" ] || die "run 'fetch' first (settings patch not present)"
  local src="$PA_TMP_DIR/piweb-src"
  rm -rf "$src"; mkdir -p "$src"
  ( cd "$src"
    export PATH="$PA_NODE_DIR/bin:$PATH"   # every `env node` (shebangs, next workers) must be the scoped node
    git init -q
    git fetch --depth=1 "$PIN_PI_WEB_REPO" "$PIN_PI_WEB_REF"
    git checkout --detach -q FETCH_HEAD
    [ "$(git rev-parse HEAD)" = "$PIN_PI_WEB_REF" ] || die "pi-web ref mismatch"
    git apply --check "$patch" || die "settings patch does not apply to this pi-web ref"
    git apply "$patch"
    log "patch applied; npm ci (dev) — this pulls the toolchain, a few minutes"
    NODE_ENV=development PA_NPM ci --include=dev --no-audit --no-fund
    # CIRCLE_NODE_TOTAL is what Next.js sizes its static-generation worker pool
    # from, and the heap cap keeps one worker from ballooning. Both are derived
    # from the host's RAM: the default behaviour is tuned for CI machines and
    # will swap an 8 GB laptop into the ground.
    local workers heap; workers="$(pa_build_workers)"; heap="$(pa_build_heap_mib)"
    log "npm run build (Next.js) — $workers worker(s), ${heap}MiB heap cap (host has $(pa_ram_mib)MiB RAM)"
    NEXT_TELEMETRY_DISABLED=1 CIRCLE_NODE_TOTAL="$workers" \
      NODE_OPTIONS="--max-old-space-size=$heap" PA_NPM run build
    for f in .next/BUILD_ID .next/server/app/omnigent/page.js .next/server/app/paseo/setup/page.js .next/server/app/api/omnigent/route.js; do
      [ -e "$f" ] || die "expected built artifact missing: $f (settings routes did not compile)"
    done
    log "settings routes compiled (omnigent + paseo pages present)"
    PA_NPM prune --omit=dev --ignore-scripts
  )
  # install the built tree as @agegr/pi-web under piweb/lib/node_modules
  rm -rf "$PA_PIWEB_DIR"; mkdir -p "$PA_PIWEB_DIR/lib/node_modules/@agegr" "$PA_PIWEB_DIR/bin"
  mv "$src" "$PA_PIWEB_DIR/lib/node_modules/@agegr/pi-web"
  ln -sf "../lib/node_modules/@agegr/pi-web/bin/pi-web.js" "$PA_PIWEB_DIR/bin/pi-web"
  # CJK path patch against the installed pi-coding-agent tool layer
  if [ -f "$HERE/rootfs/bin/fix-unicode-space-paths.mjs" ]; then
    # No mapfile here: macOS ships bash 3.2, which does not have it. find | xargs
    # carries the same NUL-delimited list to the patcher on both platforms.
    local found
    found="$(find "$PA_PIWEB_DIR/lib/node_modules/@agegr/pi-web" -path '*@earendil-works/*/dist/*/tools/path-utils.js' -print 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${found:-0}" -ge 1 ]; then
      find "$PA_PIWEB_DIR/lib/node_modules/@agegr/pi-web" -path '*@earendil-works/*/dist/*/tools/path-utils.js' -print0 2>/dev/null \
        | xargs -0 "$PA_NODE_DIR/bin/node" "$HERE/rootfs/bin/fix-unicode-space-paths.mjs" \
        && log "CJK path patch applied ($found file(s))"
    else
      warn "CJK path-utils.js not found; skipping CJK patch (upstream layout may have changed)"
    fi
  fi
  # node-pty load assertion
  PA_NODE -e 'const p=require(process.argv[1]); if(typeof p.spawn!=="function") throw Error("node-pty has no spawn()"); console.log("node-pty OK")' \
    "$PA_PIWEB_DIR/lib/node_modules/@agegr/pi-web/node_modules/node-pty" || warn "node-pty check failed (browser terminal may not work)"
  log "piweb OK"
}

# --------------------------------------------------------------------- clis ---
stage_clis() {
  log "stage clis — claude $PIN_CLAUDE_VERSION + codex $PIN_CODEX_VERSION"
  mkdir -p "$PA_CLIS_DIR/claude" "$PA_CLIS_DIR/codex"
  PA_NPM install --prefix "$PA_CLIS_DIR/claude" --no-audit --no-fund "@anthropic-ai/claude-code@$PIN_CLAUDE_VERSION"
  PA_NPM install --prefix "$PA_CLIS_DIR/codex"  --no-audit --no-fund "@openai/codex@$PIN_CODEX_VERSION"
  # drop musl SDK copies on glibc linux (keep glibc), best-effort
  if [ "$OS" != macos ]; then
    find "$PA_CLIS_DIR" -maxdepth 6 -type d -name '*-linux-*-musl' -prune -exec rm -rf {} + 2>/dev/null || true
  fi
  [ -x "$PA_CLIS_DIR/claude/node_modules/.bin/claude" ] || die "claude bin not installed"
  [ -x "$PA_CLIS_DIR/codex/node_modules/.bin/codex" ]   || die "codex bin not installed"
  log "clis OK"
}

# -------------------------------------------------------------------- paseo ---
stage_paseo() {
  log "stage paseo — managed @getpaseo/cli $PIN_GETPASEO_CLI_VERSION runtime"
  local pl="$PA_PLUGINS_DIR/pi-paseo-plugin"
  [ -d "$pl" ] || die "run 'fetch' first"
  local rt; rt="$(PA_NODE --input-type=module -e "import {prepareRuntimeManifest} from '$pl/src/runtime-layout.mjs'; console.log(prepareRuntimeManifest({runtimeDir:'$PA_PASEO_RUNTIME_DIR'}))")"
  PA_NPM ci --prefix "$rt" --omit=dev --no-audit --no-fund
  if [ "$OS" != macos ]; then
    find "$rt/node_modules/@anthropic-ai" -maxdepth 1 -type d -name '*-musl' -exec rm -rf {} + 2>/dev/null || true
  fi
  PA_NODE --input-type=module -e "import {markRuntimeReady} from '$pl/src/runtime-layout.mjs'; markRuntimeReady({runtimeDir:'$PA_PASEO_RUNTIME_DIR'})"
  log "paseo runtime OK"
}

# ----------------------------------------------------------------- omnigent ---
stage_omnigent() {
  log "stage omnigent — CLI $PIN_OMNIGENT_VERSION in a uv venv"
  local reqs="$HERE/vendor/omnigent-requirements.lock"
  [ -f "$reqs" ] || { warn "omnigent requirements.lock not vendored; skipping omnigent (tab still renders, live-connect unavailable)"; return 0; }
  mkdir -p "$PA_OMNIGENT_DIR"
  python3 -m venv "$PA_TMP_DIR/uv" && "$PA_TMP_DIR/uv/bin/pip" install -q "uv==$PIN_UV_VERSION"
  local uv="$PA_TMP_DIR/uv/bin/uv"
  UV_PYTHON_INSTALL_DIR="$PA_OMNIGENT_DIR/python" "$uv" python install "$PIN_PYTHON_VERSION"
  UV_PYTHON_INSTALL_DIR="$PA_OMNIGENT_DIR/python" "$uv" venv --python "$PIN_PYTHON_VERSION" "$PA_OMNIGENT_DIR/venv"
  "$uv" pip sync --python "$PA_OMNIGENT_DIR/venv/bin/python" --require-hashes "$reqs"
  "$PA_OMNIGENT_DIR/venv/bin/python" -c 'import importlib.metadata,sys; assert importlib.metadata.version("omnigent")==sys.argv[1]' "$PIN_OMNIGENT_VERSION"
  log "omnigent OK"
}

# --------------------------------------------------------------------- wire ---
stage_wire() {
  log "stage wire — install scripts + symlinks"
  mkdirs
  for f in pi-agent-env.sh pi claude codex pi-omnigent pi-paseo pi-web-start.sh pi-agent pi-agent-litellm pi-agent-share-state.mjs fix-unicode-space-paths.mjs omnigent-model-options-patch.py omnigent-plugin-darwin-patch.mjs; do
    [ -f "$HERE/rootfs/bin/$f" ] && install -m 0755 "$HERE/rootfs/bin/$f" "$PA_BIN_DIR/$f"
  done
  # register the Omnigent + Paseo plugins as pi extensions so their settings
  # tabs are enabled out of the box (seed once; never clobber a user's choice)
  if [ -d "$PA_PLUGINS_DIR/pi-omnigent-plugin" ] && [ ! -f "$PA_DATA_DIR/settings.json" ]; then
    mkdir -p "$PA_DATA_DIR"
    printf '{\n  "packages": [\n    "%s",\n    "%s"\n  ]\n}\n' \
      "$PA_PLUGINS_DIR/pi-omnigent-plugin" "$PA_PLUGINS_DIR/pi-paseo-plugin" > "$PA_DATA_DIR/settings.json"
    log "registered Omnigent + Paseo plugins in settings.json"
  fi
  # plugins require pi-web's node_modules (match the image symlink)
  local pw="$PA_PIWEB_DIR/lib/node_modules/@agegr/pi-web/node_modules"
  if [ -d "$pw" ]; then
    for p in pi-omnigent-plugin pi-paseo-plugin; do
      [ -d "$PA_PLUGINS_DIR/$p" ] && ln -sfn "$pw" "$PA_PLUGINS_DIR/$p/node_modules"
    done
    # Wrappers, not symlinks: a symlink to cli.mjs runs with the caller's HOME,
    # and the plugin resolves its Omnigent config from $HOME/.omnigent -- so
    # `pi-omnigent connect` typed in an ordinary shell would write the machine
    # owner's live Omnigent host rather than this install's. The wrappers source
    # pi-agent-env.sh first. Installed from rootfs/ by the loop above; drop any
    # symlink an older install left behind.
    for legacy in pi-omnigent pi-paseo; do
      [ -L "$PA_BIN_DIR/$legacy" ] && rm -f "$PA_BIN_DIR/$legacy"
    done
  fi
  # A real pi-web on PATH so the Omnigent host launcher (install-host, run from
  # pi-web-start.sh) can find it as realWeb — this is what lets a connected
  # engine actually get models + pass verification. Mirrors the container's
  # /usr/local/bin/pi-web.
  if [ -d "$PA_PIWEB_DIR" ]; then
    cat > "$PA_BIN_DIR/pi-web" <<'WRAP'
#!/bin/bash
SELF="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
: "${PI_AGENT_HOME:=$(dirname "$SELF")}"
exec "$PI_AGENT_HOME/node/bin/node" "$PI_AGENT_HOME/piweb/lib/node_modules/@agegr/pi-web/bin/pi-web.js" "$@"
WRAP
    chmod +x "$PA_BIN_DIR/pi-web"
  fi
  log "wire OK — bin at $PA_BIN_DIR"
}

# ------------------------------------------------------------------ service ---
stage_service() {
  log "stage service"
  case "$OS" in
    linux|wsl)
      if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
        local unitdir="$HOME/.config/systemd/user"; mkdir -p "$unitdir"
        cat > "$unitdir/pi-web.service" <<EOF
[Unit]
Description=Woow Pi Agent (pi-web)
After=network-online.target

[Service]
Type=simple
Environment=PI_AGENT_HOME=$PI_AGENT_HOME
Environment=PI_WEB_PORT=$PIN_PI_WEB_PORT
ExecStart=$PA_BIN_DIR/pi-web-start.sh
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now pi-web.service
        command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$USER" >/dev/null 2>&1 || true
        log "systemd --user service enabled + started"
      else
        warn "no systemd --user; start manually with: PI_AGENT_HOME=$PI_AGENT_HOME $PA_BIN_DIR/pi-agent start"
      fi ;;
    macos)
      local plist="$HOME/Library/LaunchAgents/io.woowtech.pi-agent.plist"; mkdir -p "$(dirname "$plist")"
      cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.woowtech.pi-agent</string>
  <key>ProgramArguments</key><array><string>$PA_BIN_DIR/pi-web-start.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>PI_AGENT_HOME</key><string>$PI_AGENT_HOME</string><key>PI_WEB_PORT</key><string>$PIN_PI_WEB_PORT</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$PA_LOG_DIR/pi-web.log</string>
  <key>StandardErrorPath</key><string>$PA_LOG_DIR/pi-web.log</string>
</dict></plist>
EOF
      launchctl unload "$plist" 2>/dev/null || true
      launchctl load -w "$plist"
      log "launchd agent loaded" ;;
  esac
  log "pi-web will serve http://127.0.0.1:$PIN_PI_WEB_PORT"
}

ALL_STAGES=(preflight node fetch piweb clis paseo omnigent wire service)
run_stage() { "stage_$1"; }

main() {
  local stages=("$@")
  [ "${#stages[@]}" -eq 0 ] && stages=("${ALL_STAGES[@]}")
  for s in "${stages[@]}"; do
    case " ${ALL_STAGES[*]} " in *" $s "*) run_stage "$s" ;; *) die "unknown stage: $s" ;; esac
  done
  log "done: ${stages[*]}"
}
main "$@"
