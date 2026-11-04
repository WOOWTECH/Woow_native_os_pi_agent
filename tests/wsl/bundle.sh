# shellcheck shell=bash disable=SC2154  # rc and out are set by run() in lib.sh
# Seam 6: scripts/build-wsl-bundle.sh -- the release bundle and the stamped installer.

guide_points_at() {
  printf '# guide\n\n```powershell\n$u = '"'"'%s'"'"'\n& ([ScriptBlock]::Create($u))\n```\n' "$1" > "$R/docs/WSL2.md"
}
commit_world() { ( cd "$R" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null && git add -A && git -c user.name=t -c user.email=t@t commit -q -m change ); }

# bundle_world NAME -- a tiny git repository shaped like this one, so the script runs
# against something whose contents the test controls.
bundle_world() {
  sandbox "$1"
  R="$S/repo"
  mkdir -p "$R/scripts" "$R/lib" "$R/windows"
  cp "$REPO/scripts/build-wsl-bundle.sh" "$R/scripts/build-wsl-bundle.sh" 2>/dev/null
  cp "$REPO/windows/install-pi-agent.cmd.in" "$R/windows/install-pi-agent.cmd.in" 2>/dev/null
  printf '0.9.9\n' > "$R/VERSION"
  printf 'PIN_PI_WEB_VERSION=0.10.0\n' > "$R/lib/pins.sh"
  printf '#!/bin/bash\necho install\n' > "$R/install.sh"
  mkdir -p "$R/docs"
  guide_points_at "https://github.com/x/y/releases/latest/download/install-wsl.ps1"
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

# The file people double-click. cmd.exe reads it in the system code page and needs CRLF: with bare LF
# it can lose its place in the file.
CMD="$OUT/Install-Pi-Agent.cmd"
C="$(cat "$CMD" 2>/dev/null)"
[ -f "$CMD" ] && ok "bundle: writes the double-click installer" || no "bundle: writes the double-click installer" "$(ls "$OUT" 2>&1)"
has   "bundle: it fetches this release's script" "/releases/download/v0.9.9/install-wsl.ps1" "$C"
lacks "bundle: it has no placeholder left" "@@" "$C"
has   "bundle: it hands its arguments to the installer" "%*" "$C"
has   "bundle: it waits, so the window does not close on the result" "pause" "$C"
has   "bundle: it returns the installer's exit code" "exit /b %code%" "$C"
eq    "bundle: every line ends in CRLF" "$(wc -l < "$CMD" 2>/dev/null | tr -d ' ')" "$(grep -c "$(printf '\r')\$" "$CMD" 2>/dev/null)"
eq    "bundle: it is plain ASCII (cmd.exe reads it in the system code page)" "0" "$(LC_ALL=C tr -d '\r\n\t -~' < "$CMD" 2>/dev/null | wc -c | tr -d ' ')"
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
[ ! -e "$OUT/Install-Pi-Agent.cmd" ] && ok "bundle: dev writes no double-click installer" || no "bundle: dev writes no double-click installer"

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

# The guide's command is what people paste. `releases/latest` never resolves to a pre-release, so a
# preview has to name itself; and once a preview has been out, a release can inherit its fixed URL and
# send everybody to the old preview without anything failing.
bundle_world bundle-guide-names-preview
guide_points_at "https://github.com/x/y/releases/download/v0.9.8-rc.1/install-wsl.ps1"
commit_world
run bb "$OUT" 0.9.9
[ "$rc" != 0 ] && ok "bundle: refuses a release whose guide still names a preview" || no "bundle: refuses a release whose guide still names a preview"
has "bundle: and says what the guide points at" "v0.9.8-rc.1" "$out"
[ ! -e "$OUT/install-wsl.ps1" ] && ok "bundle: and that publishes nothing either" || no "bundle: and that publishes nothing either"

bundle_world bundle-preview-on-latest
printf '0.9.9-rc.1\n' > "$R/VERSION"
commit_world
run bb "$OUT" 0.9.9-rc.1
[ "$rc" != 0 ] && ok "bundle: refuses a preview whose guide points at latest, which skips it" || no "bundle: refuses a preview whose guide points at latest, which skips it"

bundle_world bundle-preview
printf '0.9.9-rc.1\n' > "$R/VERSION"
guide_points_at "https://github.com/x/y/releases/download/v0.9.9-rc.1/install-wsl.ps1"
commit_world
run bb "$OUT" 0.9.9-rc.1 --tag v0.9.9-rc.1
eq "bundle: a preview whose guide names it builds" "0" "$rc"
has "bundle: and its script stays on that preview after a reboot" "/releases/download/v0.9.9-rc.1/install-wsl.ps1" "$(cat "$OUT/install-wsl.ps1" 2>/dev/null)"

# What counts is the guide that goes out with the release, not an edit nobody committed.
bundle_world bundle-guide-uncommitted
guide_points_at "https://github.com/x/y/releases/download/v0.9.8-rc.1/install-wsl.ps1"
run bb "$OUT" 0.9.9
eq "bundle: reads the committed guide, not the working copy" "0" "$rc"

bundle_world bundle-no-command
printf '# guide without a command\n' > "$R/docs/WSL2.md"
commit_world
run bb "$OUT" 0.9.9
[ "$rc" != 0 ] && ok "bundle: refuses a release whose guide has no install command" || no "bundle: refuses a release whose guide has no install command"

bundle_world bundle-dev-any-guide
printf '# guide without a command\n' > "$R/docs/WSL2.md"
commit_world
run bb "$OUT" dev
eq "bundle: a dev build does not care what the guide says" "0" "$rc"

# A Windows git is usually set to core.autocrlf=true, and `git archive` honours it: the first run on a
# hosted Windows runner produced a bundle whose scripts had CRLF, and bash inside the VM died at
# `set -euo pipefail\r`. The bundle has to be LF whatever the machine's git is configured to do.
bundle_world bundle-crlf
run sbx GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=true "$R/scripts/build-wsl-bundle.sh" "$OUT" dev
eq "bundle: a build on a CRLF-converting git succeeds" "0" "$rc"
CRS="$(tar -xzOf "$OUT/pi-agent-installer-dev.tar.gz" woow-pi-agent-installer/install.sh 2>/dev/null | tr -cd '\r' | wc -c | tr -d ' ')"
eq "bundle: its scripts are still LF (no carriage returns)" "0" "$CRS"
