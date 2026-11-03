# shellcheck shell=bash disable=SC2154  # rc and out are set by run() in lib.sh
# Seam 6: scripts/build-wsl-bundle.sh -- the release bundle and the stamped installer.

# bundle_world NAME -- a tiny git repository shaped like this one, so the script runs
# against something whose contents the test controls.
bundle_world() {
  sandbox "$1"
  R="$S/repo"
  mkdir -p "$R/scripts" "$R/lib" "$R/windows"
  cp "$REPO/scripts/build-wsl-bundle.sh" "$R/scripts/build-wsl-bundle.sh" 2>/dev/null
  printf '0.9.9\n' > "$R/VERSION"
  printf 'PIN_PI_WEB_VERSION=0.10.0\n' > "$R/lib/pins.sh"
  printf '#!/bin/bash\necho install\n' > "$R/install.sh"
  cat > "$R/windows/install-wsl.ps1" <<'PS'
# fixture
$script:Stamp = @{
  Version='@@VERSION@@'
  BundleUrl='@@BUNDLE_URL@@'
  BundleSha256='@@BUNDLE_SHA256@@'
  ScriptUrl='@@SCRIPT_URL@@'
  PiWebUrlX64='@@PIWEB_URL_X64@@'
  PiWebUrlArm64='@@PIWEB_URL_ARM64@@'
}
PS
  ( cd "$R" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -q -m fixture )
  printf 'not tracked\n' > "$R/junk.txt"
  OUT="$S/out"
}
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
bb() { sbx "$R/scripts/build-wsl-bundle.sh" "$@"; }

bundle_world bundle-release
run bb "$OUT" 0.9.9
eq "bundle: a release build succeeds" "0" "$rc"
TGZ="$OUT/pi-agent-installer-0.9.9.tar.gz"
[ -f "$TGZ" ] && ok "bundle: writes the tarball" || no "bundle: writes the tarball" "$(ls "$OUT" 2>&1)"
eq "bundle: the published sha256 is the tarball's" "$(sha_of "$TGZ")  pi-agent-installer-0.9.9.tar.gz" "$(cat "$TGZ.sha256" 2>/dev/null)"
LIST="$(tar -tzf "$TGZ" 2>/dev/null)"
has   "bundle: contains the installer"       "woow-pi-agent-installer/install.sh" "$LIST"
has   "bundle: contains the Windows script"  "woow-pi-agent-installer/windows/install-wsl.ps1" "$LIST"
lacks "bundle: leaves out what is not committed" "junk.txt" "$LIST"
eq    "bundle: everything sits under one directory" "0" "$(printf '%s\n' "$LIST" | grep -vc '^woow-pi-agent-installer/')"

PS1="$OUT/install-wsl.ps1"
P="$(cat "$PS1" 2>/dev/null)"
eq    "bundle: the stamped installer starts with a UTF-8 BOM (PowerShell 5.1 would read Chinese as code page 950 without it)" "efbbbf" "$(head -c3 "$PS1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
has   "bundle: stamps the version"          "Version='0.9.9'" "$P"
has   "bundle: stamps the bundle's sha256"  "BundleSha256='$(sha_of "$TGZ")'" "$P"
has   "bundle: stamps the bundle's URL"     "/releases/download/v0.9.9/pi-agent-installer-0.9.9.tar.gz" "$P"
has   "bundle: stamps the script's own URL" "/releases/download/v0.9.9/install-wsl.ps1" "$P"
has   "bundle: stamps the x64 pi-web tree"  "/releases/download/v0.9.9/piweb-0.10.0-linux-x64.tar.gz" "$P"
has   "bundle: stamps the arm64 pi-web tree" "/releases/download/v0.9.9/piweb-0.10.0-linux-arm64.tar.gz" "$P"
lacks "bundle: no placeholder is left" "@@" "$P"

# The sha256 on the release page is only worth anything if anyone can rebuild it.
run bb "$S/out2" 0.9.9
eq "bundle: building the same commit again gives the same bytes" "$(sha_of "$TGZ")" "$(sha_of "$S/out2/pi-agent-installer-0.9.9.tar.gz")"

bundle_world bundle-tag
run bb "$OUT" 0.9.9 --tag rc1
has "bundle: --tag changes the release the URLs point at" "/releases/download/rc1/pi-agent-installer-0.9.9.tar.gz" "$(cat "$OUT/install-wsl.ps1" 2>/dev/null)"

# dev: what CI builds from a branch. The Windows script is used from the checkout, not stamped.
bundle_world bundle-dev
run bb "$OUT" dev
eq "bundle: a dev build succeeds" "0" "$rc"
[ -f "$OUT/pi-agent-installer-dev.tar.gz" ] && ok "bundle: dev writes pi-agent-installer-dev.tar.gz" || no "bundle: dev writes pi-agent-installer-dev.tar.gz" "$(ls "$OUT" 2>&1)"
[ ! -e "$OUT/install-wsl.ps1" ] && ok "bundle: dev does not stamp an installer" || no "bundle: dev does not stamp an installer"

# Mistakes it must catch before something is published.
bundle_world bundle-version-mismatch
run bb "$OUT" 1.0.0
[ "$rc" != 0 ] && ok "bundle: refuses a release whose VERSION file says something else" || no "bundle: refuses a release whose VERSION file says something else"
has "bundle: and names the files that disagree" "VERSION" "$out"
[ ! -e "$OUT/install-wsl.ps1" ] && ok "bundle: and publishes nothing" || no "bundle: and publishes nothing"

bundle_world bundle-bad-version
run bb "$OUT" "latest"
[ "$rc" != 0 ] && ok "bundle: refuses a version that is not a version" || no "bundle: refuses a version that is not a version"

bundle_world bundle-unknown-placeholder
printf '$x = "@@NEW_THING@@"\n' >> "$R/windows/install-wsl.ps1"
( cd "$R" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null && git add -A && git -c user.name=t -c user.email=t@t commit -q -m more )
run bb "$OUT" 0.9.9
[ "$rc" != 0 ] && ok "bundle: refuses a script with a placeholder it does not know" || no "bundle: refuses a script with a placeholder it does not know"
has "bundle: and names it" "NEW_THING" "$out"
