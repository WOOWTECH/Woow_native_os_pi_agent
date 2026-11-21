# Full native installer on macOS CI

`macos-installer.yml` runs the actual installer on macos-15 (arm64) and
macos-15-intel (x64). It builds the bundled tmux, then runs preflight, node,
fetch, piweb, clis, shared, paseo, omnigent, wire and service. All downloads
and installs use a fresh owned root, account HOME and caches. No brew, sudo,
model login, signed pkg, or deployment is used.

The fixture checks candidate archives against the manifest and installer pins,
PiWeb's source ref and real node-pty, installed Claude/Codex/Pi wrapper versions,
Paseo core CLI and runtime readiness, the hash-locked Omnigent environment,
Darwin patches/flock, PiWeb HTTP routes and actual Agent Connect lifecycle.
It checks real wrapper discovery without making provider turns. After stopping
both services, it restarts them and compares hashes of the daemon identity and
keypair. The installed Shared 0.1.6 bundle also runs its 22 SDK boundary tests,
including real cold/warm MCP bridge processes with metadata reuse, no startup
runtime errors and a successful stdio tool call in each process. The receipt
records the installed adapter test SHA alongside the shared package version.

Three explicit isolation options keep this check away from the runner's account:

- `PI_AGENT_LINK_KEYCHAIN=0`: do not discover or link the account's login Keychain.
- `PI_AGENT_LAUNCHD_LABEL`: use a unique label (letters, digits, dots, dashes and
  underscores). Pass the same value to `install.sh service` and `pi-agent`.
- `PI_AGENT_LAUNCHD_EPHEMERAL=1`: use launchctl bootstrap/bootout in the current
  user's GUI domain, without writing launchd's persistent enable database.
  Pass the same value to installer and control wrapper. Permission/domain
  failures are returned, with no manual-process substitute.

Defaults preserve the normal user installation behavior. The fixture's receipt
records the actual stage reached and final cleanup, including on failure. Only
nonsecret receipts and installer/test logs are uploaded; runtime configuration,
private keys and pairing material are never uploaded. A missing GUI launchd
domain or permission failure fails this job and must be reported as a limitation.

This is an engineer installer route on hosted Mac runners with Xcode tools.
It does not verify a signed/notarized `.pkg`, a tools-free user Mac, concurrent
installer executions, OS upgrade, or actual Claude/Codex/Pi model conversations.
The existing release artifact workflow remains independent.
