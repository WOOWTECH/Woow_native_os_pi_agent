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
      # Deliberately NOT requiring Homebrew, nor the Command Line Tools. What this
      # installer runs on macOS either ships with the OS (curl, bsdtar -- which
      # reads .tar.xz through libarchive, so no xz binary is needed -- and
      # /usr/bin/perl for the flock shim) or is installed scoped under
      # $PI_AGENT_HOME (its own Node, the uv binary, uv's own CPython).
      #
      # Note what is NOT on that list: /usr/bin/git and /usr/bin/python3 exist on
      # every Mac, but without the Command Line Tools they are only stubs that
      # pop an installer dialog and fail. So `have python3` proves nothing, and
      # nothing here runs either of them -- except building pi-web from source,
      # which checks for the tools itself (stage_piweb).
      local missing=""
      for c in curl tar; do have "$c" || missing="$missing $c"; done
      [ -n "$missing" ] && die "missing from this macOS install:$missing"
      # tmux is needed only by Omnigent's native Pi harness, which runs the Pi
      # TUI inside its own tmux server. The pkg bundles one (tools/bin/tmux, built
      # from source) and the wire stage installs it, so Homebrew is not consulted
      # then. A git-clone install has no bundled tmux: install it when brew
      # happens to be here, and otherwise carry on -- everything else works.
      #
      # flock is NOT installed from here any more: the wire stage puts a
      # /usr/bin/perl stand-in into $PA_BIN_DIR (rootfs/bin/flock), so Omnigent
      # connect works on a Mac with neither Homebrew nor the Command Line Tools.
      if [ -x "$HERE/tools/bin/tmux" ]; then
        log "using the bundled tmux (tools/bin/tmux); Homebrew not needed"
      elif ! have tmux; then
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
# Steps that must run whatever produced the pi-web tree -- a source build or a
# prebuilt artifact. The CJK patch in particular is a data-loss fix, so an
# artifact path that skipped it would silently reintroduce the corruption.
piweb_postbuild() {
  local w="$PA_PIWEB_DIR/lib/node_modules/@agegr/pi-web"
  # CJK path patch against the installed pi-coding-agent tool layer. Idempotent:
  # the patcher marks what it edits and skips anything already marked, so
  # running it over an artifact that was patched at build time is safe.
  if [ -f "$HERE/rootfs/bin/fix-unicode-space-paths.mjs" ]; then
    # No mapfile here: macOS ships bash 3.2, which does not have it. find | xargs
    # carries the same NUL-delimited list to the patcher on both platforms.
    local found
    found="$(find "$w" -path '*@earendil-works/*/dist/*/tools/path-utils.js' -print 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${found:-0}" -ge 1 ]; then
      find "$w" -path '*@earendil-works/*/dist/*/tools/path-utils.js' -print0 2>/dev/null \
        | xargs -0 "$PA_NODE_DIR/bin/node" "$HERE/rootfs/bin/fix-unicode-space-paths.mjs" \
        && log "CJK path patch applied ($found file(s))"
    else
      warn "CJK path-utils.js not found; skipping CJK patch (upstream layout may have changed)"
    fi
  fi
  # node-pty load assertion. On the artifact path this is also the check that the
  # tree was built for THIS platform: a foreign native build fails to load here.
  PA_NODE -e 'const p=require(process.argv[1]); if(typeof p.spawn!=="function") throw Error("node-pty has no spawn()"); console.log("node-pty OK")' \
    "$w/node_modules/node-pty" || warn "node-pty check failed (browser terminal may not work)"
  log "piweb OK"
}

# Install a prebuilt pi-web tree instead of building one. Returns 1 when no
# artifact was requested, so the caller falls through to the source build.
#
# Building pi-web from source takes ~15 minutes and needs a full toolchain --
# acceptable for the engineer track, not for someone running an installer they
# downloaded. CI publishes the finished tree per platform; this consumes it.
piweb_from_artifact() {
  local art="${PI_AGENT_PIWEB_ARTIFACT:-}"
  [ -n "$art" ] || return 1

  local want_os="$OS"; [ "$want_os" = wsl ] && want_os=linux
  local tarball="$PA_TMP_DIR/piweb-artifact.tar.gz"
  mkdir -p "$PA_TMP_DIR"

  case "$art" in
    http://*|https://*)
      # A tree built for another platform cannot work here: node_modules holds
      # native builds (node-pty). Catch it by name before downloading 300 MB.
      case "$art" in
        *"-${want_os}-${ARCH}.tar.gz") : ;;
        *) die "artifact $(basename "$art") is not for ${want_os}-${ARCH}" ;;
      esac
      log "downloading prebuilt pi-web: $art"
      curl -fSL --retry 5 --retry-all-errors "$art" -o "$tarball" || die "could not download $art"
      # Prefer a published checksum; accept an explicit one; refuse silence.
      local sha="${PI_AGENT_PIWEB_ARTIFACT_SHA256:-}"
      if [ -z "$sha" ]; then
        sha="$(curl -fsSL --retry 3 "${art}.sha256" 2>/dev/null | awk '{print $1}' || true)"
      fi
      [ -n "$sha" ] || die "no checksum for $art — publish <asset>.sha256 or set PI_AGENT_PIWEB_ARTIFACT_SHA256"
      local got; got="$(sha256_of "$tarball")"
      [ "$got" = "$sha" ] || die "prebuilt pi-web checksum mismatch: expected $sha got $got"
      log "checksum verified"
      ;;
    *)
      [ -f "$art" ] || die "prebuilt pi-web not found: $art"
      case "$(basename "$art")" in
        *"-${want_os}-${ARCH}.tar.gz") : ;;
        *) warn "artifact $(basename "$art") is not named for ${want_os}-${ARCH}; continuing because it is a local file" ;;
      esac
      tarball="$art"
      ;;
  esac

  log "installing prebuilt pi-web (no build, no toolchain)"
  rm -rf "$PA_PIWEB_DIR"; mkdir -p "$PA_PIWEB_DIR"
  tar xzf "$tarball" -C "$PA_PIWEB_DIR"
  [ "$tarball" = "$PA_TMP_DIR/piweb-artifact.tar.gz" ] && rm -f "$tarball"

  # The same assertion the source build makes: the settings routes must exist,
  # or the Omnigent/Paseo tabs silently will not be there.
  local w="$PA_PIWEB_DIR/lib/node_modules/@agegr/pi-web"
  for f in .next/BUILD_ID .next/server/app/omnigent/page.js .next/server/app/paseo/setup/page.js; do
    [ -e "$w/$f" ] || die "prebuilt pi-web is missing $f — rebuild the artifact"
  done
  log "prebuilt pi-web installed"
  return 0
}

stage_piweb() {
  if piweb_from_artifact; then
    piweb_postbuild
    return 0
  fi
  log "stage piweb — build pi-web $PIN_PI_WEB_VERSION @ ${PIN_PI_WEB_REF:0:12} + settings patch"
  local patch="$PA_PLUGINS_DIR/pi-omnigent-plugin/integrations/pi-web/combined.adapter.patch"
  [ -f "$patch" ] || die "run 'fetch' first (settings patch not present)"
  # The source build needs git and a compiler. On macOS both come only with the
  # Command Line Tools; without them /usr/bin/git is a stub that opens an
  # installer dialog and fails, which reads as a broken install. Say so plainly.
  if [ "$OS" = macos ] && ! xcode-select -p >/dev/null 2>&1; then
    die "building pi-web from source needs the Xcode Command Line Tools (xcode-select --install), or set PI_AGENT_PIWEB_ARTIFACT to a prebuilt tree"
  fi
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
    # Next.js leaves its build cache in .next/cache -- 611 MB of a 1.2 GB tree
    # measured on macOS, and never read at runtime (pi-web serves fine without
    # it, verified). The reference container image drops it for the same reason;
    # this installer did not, so every install carried it. Halves the install,
    # and halves the prebuilt artifact built from it.
    rm -rf .next/cache .next/trace
  )
  # install the built tree as @agegr/pi-web under piweb/lib/node_modules
  rm -rf "$PA_PIWEB_DIR"; mkdir -p "$PA_PIWEB_DIR/lib/node_modules/@agegr" "$PA_PIWEB_DIR/bin"
  mv "$src" "$PA_PIWEB_DIR/lib/node_modules/@agegr/pi-web"
  ln -sf "../lib/node_modules/@agegr/pi-web/bin/pi-web.js" "$PA_PIWEB_DIR/bin/pi-web"
  piweb_postbuild
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
# Put the pinned uv standalone binary at $PA_BIN_DIR/uv.
#
# It has two consumers. This stage uses it to build the Omnigent venv. And the
# Omnigent plugin looks for `uv` on PATH (pi-agent-env.sh puts $PA_BIN_DIR
# first); when it finds none it bootstraps one itself with
# `python3 -m pip install uv` (src/installer.mjs). Both of those used to depend
# on a working python3, and on a Mac without the Command Line Tools
# /usr/bin/python3 is only an installer stub: `have python3` succeeds, running
# it does not. The binary is the same version the plugin pins, verified against
# a per-triple sha256 in lib/pins.sh, and it fails closed on a mismatch.
ensure_uv() {
  local triple
  case "$OS-$ARCH" in
    macos-arm64)            triple=aarch64-apple-darwin ;;
    macos-x64)              triple=x86_64-apple-darwin ;;
    linux-x64|wsl-x64)      triple=x86_64-unknown-linux-gnu ;;
    linux-arm64|wsl-arm64)  triple=aarch64-unknown-linux-gnu ;;
    *) die "no pinned uv build for $OS-$ARCH" ;;
  esac
  local var="PIN_UV_SHA256_${triple//-/_}"
  local sha="${!var:-}"
  [ -n "$sha" ] || die "lib/pins.sh has no $var"

  if [ -x "$PA_BIN_DIR/uv" ] \
     && [ "$("$PA_BIN_DIR/uv" --version 2>/dev/null | awk '{print $2}')" = "$PIN_UV_VERSION" ]; then
    log "uv $PIN_UV_VERSION already present"; return 0
  fi

  local url="https://github.com/astral-sh/uv/releases/download/${PIN_UV_VERSION}/uv-${triple}.tar.gz"
  local tmp="$PA_TMP_DIR/uv-download"
  rm -rf "$tmp"; mkdir -p "$tmp" "$PA_BIN_DIR"
  fetch_verify "$url" "$sha" "$tmp/uv.tar.gz"
  tar xzf "$tmp/uv.tar.gz" -C "$tmp"
  [ -f "$tmp/uv-$triple/uv" ] || die "uv $PIN_UV_VERSION archive has no uv-$triple/uv (upstream layout changed?)"
  install -m 0755 "$tmp/uv-$triple/uv" "$PA_BIN_DIR/uv"
  rm -rf "$tmp"
  [ "$("$PA_BIN_DIR/uv" --version 2>/dev/null | awk '{print $2}')" = "$PIN_UV_VERSION" ] \
    || die "installed uv does not report version $PIN_UV_VERSION"
  log "uv $PIN_UV_VERSION installed ($triple, sha256 verified)"
}

stage_omnigent() {
  log "stage omnigent — CLI $PIN_OMNIGENT_VERSION in a uv venv"
  ensure_uv
  local reqs="$HERE/vendor/omnigent-requirements.lock"
  [ -f "$reqs" ] || { warn "omnigent requirements.lock not vendored; skipping omnigent (tab still renders, live-connect unavailable)"; return 0; }
  mkdir -p "$PA_OMNIGENT_DIR"
  local uv="$PA_BIN_DIR/uv"
  # Keep uv inside $PI_AGENT_HOME. By default `uv python install` links
  # python3.12 into ~/.local/bin and every uv call caches under ~/.cache/uv --
  # both in the user's real home, and the link dangles once this install is
  # removed. --no-bin and a scoped cache prevent that.
  local uv_cache="$PA_TMP_DIR/uv-cache"
  UV_CACHE_DIR="$uv_cache" UV_PYTHON_INSTALL_DIR="$PA_OMNIGENT_DIR/python" \
    "$uv" python install --no-bin "$PIN_PYTHON_VERSION"
  UV_CACHE_DIR="$uv_cache" UV_PYTHON_INSTALL_DIR="$PA_OMNIGENT_DIR/python" \
    "$uv" venv --python "$PIN_PYTHON_VERSION" "$PA_OMNIGENT_DIR/venv"
  UV_CACHE_DIR="$uv_cache" "$uv" pip sync --python "$PA_OMNIGENT_DIR/venv/bin/python" --require-hashes "$reqs"
  "$PA_OMNIGENT_DIR/venv/bin/python" -c 'import importlib.metadata,sys; assert importlib.metadata.version("omnigent")==sys.argv[1]' "$PIN_OMNIGENT_VERSION"
  log "omnigent OK"
}

# --------------------------------------------------------------------- wire ---
stage_wire() {
  log "stage wire — install scripts + symlinks"
  mkdirs
  for f in pi-agent-env.sh pi claude codex pi-omnigent pi-paseo pi-web-start.sh pi-agent pi-agent-adopt-logins pi-agent-session-home pi-agent-session-home-macos pi-agent-litellm pi-agent-share-state.mjs fix-unicode-space-paths.mjs omnigent-model-options-patch.py omnigent-plugin-darwin-patch.mjs omnigent-plugin-session-home-patch.mjs; do
    [ -f "$HERE/rootfs/bin/$f" ] && install -m 0755 "$HERE/rootfs/bin/$f" "$PA_BIN_DIR/$f"
  done
  # macOS only: a flock(1) for the Omnigent plugin's locked(). macOS ships none,
  # and the darwin patch makes the plugin look on PATH, where pi-agent-env.sh puts
  # $PA_BIN_DIR first -- so this shim is what it finds, with or without Homebrew.
  # Never on Linux: util-linux's flock is the real thing there, and a shim first
  # on PATH would shadow it for every agent shell too.
  if [ "$OS" = macos ]; then
    install -m 0755 "$HERE/rootfs/bin/flock" "$PA_BIN_DIR/flock"
    # The tmux the pkg bundles (scripts/build-macos-tmux.sh): Omnigent's native
    # Pi harness runs the Pi TUI inside it, and Omnigent finds it with
    # shutil.which("tmux") -- PATH order, where $PA_BIN_DIR comes first. A git
    # clone has no tools/ and keeps the Homebrew fallback in preflight.
    if [ -x "$HERE/tools/bin/tmux" ]; then
      install -m 0755 "$HERE/tools/bin/tmux" "$PA_BIN_DIR/tmux"
      if [ -d "$HERE/tools/licenses" ]; then
        mkdir -p "$PI_AGENT_HOME/share/licenses"
        cp -p "$HERE/tools/licenses/"* "$PI_AGENT_HOME/share/licenses/"
      fi
      log "installed bundled tmux ($("$PA_BIN_DIR/tmux" -V 2>/dev/null || echo '?'))"
    fi
    # python3 for the Omnigent plugin's dependency discovery, only on a Mac
    # whose /usr/bin/python3 is the Command Line Tools stub. Discovery resolves
    # `python3` by walking PATH and runs `python3 --version` on every refresh,
    # and a failed probe is not cached -- so on such a Mac every refresh hits
    # the stub and opens the "install developer tools?" dialog. $PA_BIN_DIR is
    # first on pi-web's PATH (after the plugin's own state dirs, which hold no
    # python3), so a link here is what discovery finds. It points at the
    # uv-managed CPython the omnigent stage installed -- the base interpreter,
    # not the omnigent venv. A Mac with a real python3 keeps it: a python3 here
    # would shadow it for every agent shell too, so an earlier link is removed.
    local py_link="$PA_BIN_DIR/python3" py_base="" py_cand
    if pa_macos_python3_is_stub; then
      for py_cand in "$PA_OMNIGENT_DIR/python/cpython-$PIN_PYTHON_VERSION-"*/bin/"python${PIN_PYTHON_VERSION%.*}"; do
        [ -x "$py_cand" ] && { py_base="$py_cand"; break; }
      done
      if [ -e "$py_link" ] && [ ! -L "$py_link" ]; then
        warn "$py_link exists and is not a link -- leaving it; it is what Omnigent's discovery will run"
      elif [ -n "$py_base" ] && [ "$("$py_base" --version 2>&1)" = "Python $PIN_PYTHON_VERSION" ]; then
        ln -sfn "$py_base" "$py_link"
        log "linked python3 to the uv-managed CPython $PIN_PYTHON_VERSION (/usr/bin/python3 is only the Command Line Tools stub)"
      else
        warn "/usr/bin/python3 is the Command Line Tools stub and the uv-managed CPython is missing (run the omnigent stage); Omnigent's dependency check may open the developer-tools dialog"
      fi
    elif [ -L "$py_link" ]; then
      case "$(readlink "$py_link")" in
        "$PA_OMNIGENT_DIR"/python/*) rm -f "$py_link"; log "removed the python3 link: this Mac has a real python3 now" ;;
      esac
    fi
  fi
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
  # macOS: the Security framework resolves the login Keychain from
  # $HOME/Library/Keychains, and pi-agent-env.sh scopes HOME -- so every keychain
  # call made by this install returns errSecNoDefaultKeychain (-25307). Claude
  # Code keeps its credentials there, so the scoped install reports
  # "Not logged in" even when the user IS logged in, and `claude auth login`
  # then fails with "Couldn't save your login. If your Mac's keychain is
  # locked, unlock it and log in again." That message is misleading: the
  # keychain is not locked, it cannot be found. Link the real one in.
  #
  # Only this one directory is shared, and it is the user's own keychain on
  # their own machine -- the rest of the scoping (data, sessions, .omnigent
  # host identity, shared skills/MCP) is untouched.
  if [ "$OS" = macos ]; then
    local real_home; real_home="$(eval echo "~$(id -un)")"
    if [ -n "$real_home" ] && [ -d "$real_home/Library/Keychains" ] && [ "$real_home" != "$PI_AGENT_HOME" ]; then
      mkdir -p "$PA_HOME_DIR/Library"
      if [ -e "$PA_HOME_DIR/Library/Keychains" ] && [ ! -L "$PA_HOME_DIR/Library/Keychains" ]; then
        warn "$PA_HOME_DIR/Library/Keychains exists and is not a symlink — leaving it; Claude Code will report 'Not logged in'"
      else
        ln -sfn "$real_home/Library/Keychains" "$PA_HOME_DIR/Library/Keychains"
        log "linked the login Keychain into the scoped home (Claude Code reads its credentials from there)"
      fi
    fi
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
