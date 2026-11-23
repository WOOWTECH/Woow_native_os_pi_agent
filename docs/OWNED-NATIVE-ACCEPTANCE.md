# Owned Ubuntu and WSL2 acceptance

The legacy `tests/smoke.sh` and `tests/smoke-linux.sh` entrypoints refuse
unconditionally. They must not overwrite an installation's MCP manifest, delete
its `qa-skill`, or restart the account's fixed `pi-web` service. There is no
override to restore that behavior.

`tests/owned_native_acceptance.py` is a new, separate runner. This source has
only local safety-fixture evidence. **Actual Ubuntu, WSL2, provider and reboot
acceptance are all false.** Review and authorization of a real target run remain
necessary; the commands below describe interfaces, not evidence of execution.

## Source inspection and local safety fixtures

From this source checkout:

```bash
python3 -B tests/owned_native_acceptance.py --mode source-plan --platform ubuntu --supervisor owned-pgid
python3 -B tests/test_owned_native_acceptance.py
```

`source-plan` hashes the locked inputs and prints a plan. It runs no installer,
SDK, service or provider and creates no acceptance workspace. The fixture suite
uses standard-library Python children, private files, and owned loopback HTTP
servers. Node 22 executes only the exact pinned native static patchers against
private copies of the real plugin package. PyYAML 6.0.3 parses the deployment
workflow for its unconditional safety-suite assertion; both are already
provisioned in the Python 3.12 / Node 22 CI job. Its JSON-RPC peer is explicitly
synthetic. The selected pipeline fixture substitutes only the installer stages,
web process and SDK bridge with explicit test-local fixtures, while exercising
the actual source copy, artifact preflight, static overlays and package binding
in pipeline order. The real installer, Pi Web, sharing helper and SDK bridge
are not executed by that suite. Fixtures cannot produce an
`OWNED_SCENARIO_COMPLETED` result.

`deployment-ci` runs `python3 -B tests/test_owned_native_acceptance.py` on every
pull request and main push, without a path filter or conditional skip. It also
retains the existing native maintenance composition suite. Local safety
results do not claim that an automatic CI run has occurred.

## Future explicit acceptance interface

An operator must select `--mode acceptance`, `--platform ubuntu` or `wsl2`,
and `--supervisor owned-pgid`. A separately created, canonical, user-owned mode
0700 parent directory, an absolute regular local Pi Web artifact, and its
independently trusted SHA256 are required through `--parent`,
`--piweb-artifact`, and `--piweb-artifact-sha256`. The runner has no existing
install-root or credential-adoption option. Acceptance refuses UID0. Python
3.11+ with Linux procfs, pidfds and subreaper support is required.

Ubuntu is checked from `/etc/os-release`. WSL2 additionally requires the
`microsoft-standard-WSL2` kernel identifier; a plain Linux kernel or WSL1 is not
WSL2 evidence. The Ubuntu mode refuses a Microsoft kernel. No SSH, cluster,
Windows host discovery or controller action is part of this runner.

Prerequisites must already be present in `/usr/bin:/bin`: Bash, curl, Git,
GPG, jq, SSH, xz, Python, flock and tmux. There is no sudo/apt/dnf action. The
fixed installer stages are `node fetch piweb clis shared paseo omnigent wire`;
`preflight` and `service` are never selected. The artifact prevents the Pi Web
source-build fallback. A future run downloads/install dependencies inside the
private roots; this implementation task did not run those operations. Existing
artifact platform/source/adapter/package-manifest checks remain authoritative.

## Ownership and preservation

- An exclusive random mode 0700 directory and mode 0600 marker bind the run.
  Descriptor-relative no-follow traversal rejects outside paths, links and
  collisions. Files read as state must be regular, singly linked, size bounded
  and stable across the read. Source/package inputs are locked by content: all
  40 installer inputs in `tests/owned-native-acceptance.lock.json` and plugin
  archive `9ac751b3…`. The lock was first frozen from commit
  `172522c8a4065f80e813d6d4710b26b13b6094c7` and its tree, which stay its base
  reference. Inputs changed since then (the hard-link repair in `install.sh` and
  its helper, and Agent Connect 0.1.21) are pinned at their current bytes. The
  lock also binds all 37 expected
  Linux plugin member bytes/modes after native overlays. Source provenance
  refers to that base; it does not claim this new driver was committed there.
  The copied inputs include `VERSION`, which the actual artifact manifest
  helper reads. After the fixed install stages, the driver applies the locked
  host-name, model-options and session-home overlays through bounded owned
  commands, then checks every expected package member before starting Pi Web.
- HOME, install/data, XDG roots, temporary files and caches are private. An
  explicit child environment drops ambient keys, proxy settings, login state,
  adopted HOME, SSH agents, Python/Node hooks and controller configuration.
  UV uses copy mode. A fixed child umask makes installed source modes
  reproducible; the enclosing root remains 0700 and private files use 0600.
- Each command has a separate session/PGID and standard-library subreaper.
  Birth ticks, UID, PGID and session must match. Descendant enumeration is
  bounded and restricted to that owned tree, including children of all its
  threads. Double-forked children remain adopted. Teardown signals the retained
  guardian through a pidfd, then verified descendants through pidfds. It never
  invokes `pi-agent stop`, `pkill`, `systemctl`, launchd, fixed units, login
  hooks or linger.
- Before and after HTTP, the selected IPv4 loopback listener inode and UID must
  match the owned tree's socket descriptors. Only the selected port record is
  used; no user process sweep occurs. An occupied port or unrelated listener
  is a refusal, not a request to stop it. The reservation-to-start bind race
  remains possible and fails on ownership mismatch. HTTP checks are not a
  substitute for source/package binding.
- Sharing uses the actual installed `pi_shared_runtime` bridge. The future
  pipeline verifies provider bridge command/arguments/environment, current
  sync reports without conflicts, cold/warm MCP startup, skill loading and
  an owned stdio echo through `pi_global_mcp`. It removes only run-named
  fixtures and verifies their absence through a fresh bridge. Unrelated
  synthetic skill/file sentinels retain exact bytes/modes; unrelated MCP and
  provider configuration sentinel fields retain their values. No live config
  is copied, backed up or restored.

## Bounds, receipts and supervisor limits

The default run deadline is 1800 seconds (allowed 60–3600); an install command
gets at most 600 seconds, sync 90, bridge 30, HTTP 3 per request, teardown 3 per
command tree. Commands have 2 MiB combined output and at most 32 command trees.
State reads are at most 4 MiB; input enumeration is at most 128 files/16 MiB.
Artifact compressed bytes are at most 512 MiB. Before extraction, tar headers
are checked for at most 250000 members/4 GiB expanded data, 30 seconds, safe
relative names, no duplicates/special modes, internal symlinks, no symlink
parents, no hardlinks/devices/FIFOs, and at most 1 MiB per metadata read. The
complete symlink graph is resolved component by component, expanding each
link before processing the remaining `..` components. Escapes, cycles and
file-as-directory traversal are refused before installation. All link
resolutions share the archive deadline, one million component steps and 16384
link expansions, with at most 64 nested links per resolution. Internal Node
`.bin` chains remain supported within these bounds.
Cleanup pre-scans at most 250000
entries/64 levels and removes only descriptor-bound owned items within 30
seconds. Exceeding a bound produces HOLD.

The receipt is exclusively created beside the private run directory, mode
0600. Raw command output stays bounded in memory and is not written to the
receipt. A failure or interrupt produces HOLD and retains the private root for
review. A missing “tree empty” guardian record, changed PID/marker/path,
unknown/escaped descendant, or failed cleanup also produces HOLD. An uncertain
process tree remains supervised/retained; the runner does not kill an unknown
process or delete a possibly active root. The receipt includes the owned PID
birth proofs needed for subsequent explicitly authorized investigation.

This is cooperative process containment, not a hostile-code sandbox. A same-UID
adversary, kernel compromise, uninterruptible I/O, SIGKILL/power loss, a process
that changes session/UID, or a target that needs systemd services can prevent
verified teardown. The guardian attempts cleanup if its parent disappears;
it retains adoption when ownership becomes uncertain. Root/path/socket checks
reduce accidental substitutions but cannot eliminate all same-UID races.

`OWNED_SCENARIO_COMPLETED` covers only the selected fresh, credential-free
process lifecycle and synthetic sharing data. It does not approve a tenant
upgrade. The broad real-Ubuntu/WSL2/provider/reboot acceptance fields remain
false; a future external review may assess the observed target/platform and
checks separately. Persistent service enablement, user systemd boot behavior,
WSL shutdown/reboot, Windows browser integration, real accounts, provider turns,
existing-state migration and lost-history recovery are not tested. A future
dedicated disposable account/VM/WSL distribution is required for those distinct
operations. Existing production holds remain unchanged.
