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
python3 -B -m unittest discover -s tests -p test_owned_proc_lifecycle.py -v
python3 -B -m unittest discover -s tests -p test_owned_process_custody.py -v
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

Every owned safety suite (`tests/test_owned_*.py`) is wired the same way,
`python3 -B tests/<suite>`, so each one ends with
`if __name__ == '__main__': unittest.main(verbosity=2)` as its final top-level
statement. Without it the step would run zero tests and exit 0, a silent skip;
the final composer refuses such a suite (`SAFETY_SUITE_NOT_SELF_EXECUTING`) and
`SafetySuiteEntryPointTests` asserts the composer's own predicate on every
owned suite present.

## Future explicit acceptance interface

An operator must select `--mode acceptance`, `--platform ubuntu` or `wsl2`,
and an authorized supervisor. `owned-pgid` is the unchanged strict default;
`--supervisor owned-subreaper` explicitly permits proved descendants to create
their own sessions. It does not permit unrelated processes or a changed guardian.
A separately created, canonical, user-owned mode
0700 parent directory, an absolute regular local Pi Web artifact, and its
independently trusted SHA256 are required through `--parent`,
`--piweb-artifact`, and `--piweb-artifact-sha256`. The runner has no existing
install-root or credential-adoption option. Acceptance refuses UID0. Python
3.11+ with Linux procfs, pidfds and subreaper support is required.

Acceptance also requires explicit `--run-token` and
`--source-authority-sha256`, each lowercase64 hex, as is the artifact hash.
These values are validated before creating a workspace and bound to the raw
run receipt as `runToken`, `sourceAuthoritySha256` and `piwebArtifactSha256`.
The token must be freshly supplied by the external controller. The authority
digest is the caller's separately verified, non-circular source proof; receipt
transport does not grant authority or replace the driver's immutable source
lock and artifact-byte verification. Source-plan needs none of these values.

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
  archive `a5eb78fe…`. The lock was first frozen from commit
  `172522c8a4065f80e813d6d4710b26b13b6094c7` and its tree, which stay its base
  reference. Inputs changed since then (the hard-link repair in `install.sh` and
  its helper) are pinned at their current bytes. The
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
  The guardian's birth, UID, PGID and session stay fixed. `owned-pgid` continues
  refusing descendants that leave its group/session. `owned-subreaper` permits
  descendant group/session movement only while same-birth, same-UID custody
  and fresh guardian-rooted ancestry remain proved. Both refuse unknown states,
  permissions, live UID/birth substitutions and unsupported namespace views.
  Double-forked descendants remain adopted. Teardown signals the retained
  guardian through a PIDfd, then verified descendants through PIDfds. It never
  invokes `pi-agent stop`, `pkill`, `systemctl`, launchd, fixed units, login
  hooks or linger.
- For HTTP in either mode, a proved listener is only a prerequisite. The custody
  module makes one IPv4 loopback client connection, then proves its unique
  reversed ESTABLISHED tuple, nonzero server inode and actual FD in a live,
  bound owned process. It freshly rechecks the complete tuple/inode/FD
  association before granting its private connection lease. No HTTP request
  or response admission precedes that proof. A queued or fast-closing foreign
  response cannot substitute for it. The same open client FD is retained
  through response/EOF; no reconnect, redirect or alternative listener exists.
  Normal owned peer close after proof does not require its accepted FD to
  survive the response. Unrelated listeners are never signalled. HTTP checks
  do not substitute for source/package binding.
- Sharing uses the actual installed `pi_shared_runtime` bridge. The future
  pipeline verifies provider bridge command/arguments/environment, current
  sync reports without conflicts, cold/warm MCP startup, skill loading and
  an owned stdio echo through `pi_global_mcp`. It removes only run-named
  fixtures and verifies their absence through a fresh bridge. Unrelated
  synthetic skill/file sentinels retain exact bytes/modes; unrelated MCP and
  provider configuration sentinel fields retain their values. No live config
  is copied, backed up or restored.

## Bounds, receipts and supervisor limits

`tests/owned_process_custody.py` exclusively owns its PIDfd/proc descriptor
lifetimes, ancestry census and connection lease. The parent shares one budget
across all its command ledgers. Each independently running guardian has its own
controller budget for autonomous cleanup after parent death. Within each
controller, traversal, retained/provisional custody, retries and connection
proof share at most 128 currently charged process/thread identities and 128
descriptors; these are not per-parent limits. A PID identity stays charged
while its capability is pinned, including a handle whose close failed. A
successful close after retirement or ESRCH before PIDfd acquisition releases
its identity slot; an uncertain or failed close never does. A positive reap
record separately proves a completed PID and can discard its unpinned slot;
the reap record remains in its own bounded ledger. Thread IDs stay charged across all parent snapshots in the operation: a
completed snapshot alone does not prove a thread departed. This preserves the
global process/thread bound while allowing proved retired PID charges to clear. Reads
share 4 MiB per operation
(8192 bytes per proc file, 2 MiB for TCP records), at most 4096 FD entries and
128 reproof passes, all under the original absolute monotonic deadline. Nested
operations and same-connection retries do not reset these counters. These are
controller bounds, not a claim of 128 descriptors total across separate OS
processes.

Retirement removes exactly the capability object being retired (never a newer
object for the same PID) and closes its proc directory and PIDfd independently.
Each descriptor field is cleared right after its successful close, which is
when its Budget FD is released; the PID is unpinned exactly once, after both
closes succeed. A close that reports an error is never retried, because Linux
releases the number regardless: the number moves to a retained ledger and keeps
its Budget FD charge, every other independent close is still attempted, and the
first error is latched as sticky `CUSTODY_CLOSE_FAILED` with its errno. Every
later operation, including `close()`, then refuses with that same first error.
Constructor cleanup and `close()` attempt every independent handle even after
one failure.

The work cutoff stays fixed. Each tree has a separate, one-time teardown
allowance of at most three seconds, starting at the earlier of its first stop
request and work expiry. Explicit stop, parent death and known work expiry
permit only fresh ownership validation, retained-PIDfd TERM/KILL, reaping and
descriptor closure within that allowance. Repeated stop/signals never renew
it. No target launch, endpoint connection or HTTP request can use cleanup time
as work time. Closing an earlier completed tree changes only that tree's
lifetime; the shared controller budget retains its original work deadline for
later commands. Resource counters remain shared across nested operations.
An in-flight ownership operation rechecks its tree's current cutoff after a
stop transition; it cannot retain a stale work cutoff or reset counters.
Nested work-purpose operations still refuse teardown, and an explicit earlier
operation cutoff remains an earlier bound. Each cutoff check samples the clock
first and only then evaluates the effective cutoff, so a stop landing between
them can only substitute its teardown cutoff for that sample. An exceeded cutoff
raises `CustodyError` carrying `.phase` (`work`, `teardown` or `explicit`), fixed
at that sample. The guardian classifies by the error's own phase, never by the
lifetime state it observes when catching: phase `work` is known work expiry
(publish `workExpired`, then continue cleanup inside the one-shot allowance if a
stop already started) and is never sticky uncertainty. Teardown-phase expiry,
explicit cutoffs and identity/I/O errors stay sticky.

The guardian latches the first stop independently of module loading or custody
construction. Once the tree lifetime exists, that original timestamp can only
shorten its cleanup allowance. A stop before the launch gate refuses target
creation and finalizes known prelaunch resources under the same fixed bound.
Pending stop delivery is checked and the signal mask restored before fork/exec;
targets do not inherit blocked TERM/INT. The last stopped check commits launch;
a stop delivered after that point retains adoption for the registered child.
Prelaunch refusal stays HOLD, publishes no invented command-exit record, and
requires exact guardian identity plus kernel no-child proof before treeEmpty.

If custody construction itself raises `CUSTODY_DEADLINE` with phase `work`
before any launch, the constructor has already closed what it opened. The
guardian publishes `workExpired:true`, latches cleanup at the original work
cutoff, launches nothing, and performs the same no-launch finalization (exact
guardian identity, `waitpid(-1, WNOHANG | __WALL)` ECHILD) within only the
remaining one-time allowance. It then emits `treeEmpty` and exits 124 with no
command-exit record, which the driver already treats as a verified work-expired
HOLD. Any proof failure, an exhausted allowance or a constructor close failure
is a sticky HOLD; genuine initialization errors stay sticky initialization
uncertainty.

Known work expiry triggers cleanup and a bounded `workExpired:true` control
record, independently of ownership uncertainty. Verified cleanup does not
turn the expired work into success: the run stays HOLD. Genuine PIDfd, UID,
namespace, ancestry, permission and I/O uncertainty is never cleared to force
cleanup; an expired cleanup allowance also HOLDs and is not renewed.

The module opens a process PIDfd before admission, requires matching kernel
`Pid`/single-view `NSpid` fdinfo and retains the proc directory. It checks those
bindings, stable birth/UID and namespaces around fresh top-down all-thread
children edges while both ends are held. A retained capability omitted from
a racing census is not discharged. Adoption requires bounded edge reproof.
A discovered candidate that departs invalidates the entire census. Complete
child sets of every retained parent, including an anchor with no saved edges,
are freshly checked before accepting that census. Missing required live-anchor
children data HOLDs; a disappearing non-anchor thread requires bounded complete
re-census, never an empty-list substitution. An empty task listing of a held
non-anchor capability whose same held PIDfd is ready (the task was released
after `proc_task_readdir`'s dead check and before its first thread) is that same
children-site departure: its children were already reparented to the subreaper,
so the pass is discarded and a fresh census sees them. For the anchor, or a
nonready capability, an empty task listing stays `CUSTODY_TASKS_UNKNOWN`.
A newly discovered non-anchor child whose own PIDfd is already ready at
discovery while its parent edge is still listed is a zombie that its live owned
parent has not reaped. It is recorded only as an inert terminal leaf of that
parent for the current pass: its PIDfd is held and charged like any discovered
identity, but it is never a live or provisional capability, never signalled,
never adopted or traversed (a zombie's children were already reparented), and
never a live proof. The parent edge is re-read with both held, and the leaf
stays in that parent's expected child set for the closure re-reads only while
the same PIDfd is still ready and its fdinfo still binds that PID (a released
zombie reports `Pid: -1` for good, so the listed number cannot have been reaped
and reused). Any change restarts the whole census; each pass closes its leaves.
A leaf neither empties nor fills a tree: a live parent keeps the tree nonempty,
and `treeEmpty` still needs the unchanged final `__WALL` ECHILD result. The guardian reaps during reproof
and requires the kernel's final no-child result after the empty observation
before publishing `treeEmpty`. Retries share the original counters/deadline.
Departure at the final held-PIDfd readiness poll also retires that capability
and restarts the whole bounded census. It cannot return an empty live set while
retaining a departed child that would later fail the unchanged live-close guard.

Only whole-process PIDfd exit/reap readiness (POLLIN or POLLHUP) retires custody;
POLLERR/NVAL and contradictory Pid/NSpid remain refusals. HUP-only handling is an
API-contract qualification, not a claim that a tested kernel emitted it.
A terminal leader
with another thread alive remains live/unknown: its namespace links are already
gone, so the bounded exit-window wait below expires as sticky
`CUSTODY_EXIT_UNCONFIRMED` while that thread lives (or, when the operation
cutoff comes first, as that cutoff's own phase-tagged expiry). Terminal-to-live
contradictions, live reuse, changed anchor and unknown errors remain refusals.
At a signal-boundary ESRCH, only readiness of that same held PIDfd permits
departure handling, followed by fresh bounded ancestry reproof for descendants.
A departed guardian still requires its exact Popen reaping and final control
proof; departure alone cannot certify an empty tree. Non-ready ESRCH,
permission and unknown signal errors HOLD. Numeric replacement signalling is
never a fallback.

One narrow namespace-readlink departure rule applies to non-anchor candidates.
If the exact `os.readlink('ns/pid')` or `os.readlink('ns/net')` site raises EACCES,
the module immediately checks that same already-held whole-process PIDfd using
the unchanged strict fdinfo identity/namespace binding and POLLIN-or-POLLHUP
readiness checks, rejecting ERR/NVAL. Only positive exit readiness is a
departure. The original counters and deadline remain binding; final ECHILD
still precedes treeEmpty. No ownership, signal or HTTP permission comes from
that candidate. For EACCES there is no wait for readiness: nonready, unknown,
substituted or erroneous PIDfds and later exit cannot clear an already reported
sticky permission uncertainty. This rule chooses a safe action after proved
whole-process departure; it does not identify the exact EACCES cause.

Namespace-exit window (ENOENT). On Linux, `do_exit()` sets PF_EXITING, clears the
task's nsproxy in `exit_task_namespaces()` and only later, in `exit_notify()`,
makes the PIDfd readable; deferred final-`fput` work in `exit_task_work()` runs in
between. While an owned process exits, `readlink('ns/net')` therefore returns
ENOENT while the SAME held PIDfd is still not readable, and `/proc/<pid>/stat`
shows that birth with PF_EXITING (0x4) in field 9. The root probe on 6.8.0-106
measured the window from sub-millisecond (trivial processes) to ~3 ms (16 MB
memfd), ~14 ms (64 MB), ~55 ms (256 MB) and ~200 ms (1 GB); see
`live-acceptance/maintenance-resume-20261122T053735Z/root-v5-errno2-kernel-window-probe/`
(`probe_exit_window.py`, `RESULT-1.json`, `probe_window_duration.py`,
`RESULT-2-duration.json`). That window explains the V5 fixed-campaign
`CUSTODY_IO_ERROR` errno 2. For an already-held non-anchor capability, ENOENT at
that exact site is handled as follows: (a) if the same held PIDfd is ready, it is
a departure; (b) otherwise stat is re-read through the held procfd; if stat is
unavailable only immediate readiness counts. If the same held PIDfd is ready by
then (a released task's procfd reports root ownership), that readiness is the
departure; otherwise the re-read must show the same birth, the anchor UID and
PF_EXITING, and without PF_EXITING the original ENOENT stays a HOLD; (c) with PF_EXITING the module waits with `poll` on the SAME held PIDfd for
at most 2 s from the start of the wait and never past the current operation
cutoff. Readiness within that wait is a departure. A wait ended by the operation
cutoff before the 2 s bound raises that cutoff's own phase-tagged expiry, exactly
as any other check of that cutoff would: phase `work` is a known work expiry
(the guardian publishes `workExpired` and runs its one-shot cleanup; the parent
sees a non-sticky `CUSTODY_DEADLINE`), while teardown-phase and explicit-cutoff
expiries keep their existing classification. Only when the full 2 s elapse
without readiness is sticky `CUSTODY_EXIT_UNCONFIRMED` raised, never success.
The wait renews or extends no deadline, charges no identity and behaves
identically inside and outside a census. ESRCH at that site is only an
immediate-readiness departure. An anchor never departs and never waits: at the
namespace and FD-directory sites an anchor whose same held PIDfd is immediately
ready, or (at that site's exiting errno) whose stat re-read shows the anchor
birth, the anchor UID and PF_EXITING, refuses at once as `CUSTODY_ANCHOR_GONE`,
as at the stat site; a live anchor's error stays `CUSTODY_IO_ERROR`. The driver
treats a parent-ledger `CUSTODY_ANCHOR_GONE` as an expected guardian exit only
after waiting for that exact guardian Popen for at most min(2 s, the tree's
current cutoff); a guardian that has not exited by then stays sticky
uncertainty, and an exited one still needs its final `treeEmpty` record. No
other errno or site gains tolerance.

Borrowed validation is nonmutating. Validation (`_validate`, the namespace
links, the FD-directory scan and the exact socket-FD recheck) never closes a
capability and never runs a census underneath its caller; it only returns a
departure outcome. Only the census retires capabilities. Outer transactions
(`verify_listener`, `connect_owned`, `signal_owned`, `empty`) that observe a
departure restart from a fresh bounded census with fresh objects, under the same
shared Budget, deadline and cumulative pass bound; `connect_owned` re-checks
`self._caps.get(pid) is cap` after every census before using a capability. There
is still exactly one connection and no HTTP byte before peer proof.

One site-aware helper decides departure for the stat, proc-directory, task/
children, empty task listing, FD-directory and namespace sites, so the decision
shapes cannot drift. Every FD-derived site of a held capability goes through it:
`open('fd')`, the directory read (`next()` of the listing, where a post-release
ENOENT surfaces), a per-entry `readlink` failure other than a closed descriptor's
ENOENT, and the exact `fd/<n>` recheck. On Linux `exit_mm()` clears the task's
mm long before `exit_notify()`; from then until release `/proc/<pid>/fd` is
root-owned 0500 for a non-root observer, so that site's real exiting errno is
EACCES, also for a ready zombie, while `ns/net` may still resolve and the PIDfd
stays nonready for up to tens of milliseconds as touched memory is torn down.
For a non-anchor held capability, ENOENT, ESRCH or EACCES with the same held
PIDfd immediately ready is a departure for the outer transaction. EACCES with a
nonready PIDfd takes the namespace exit-window rule above: same birth, anchor
UID and PF_EXITING through the held procfd, then the bounded same-PIDfd wait
with the same cutoff rule; readiness is a departure, the full bound is sticky
`CUSTODY_EXIT_UNCONFIRMED`. EACCES without PF_EXITING (a live non-dumpable
owner), nonready ENOENT/ESRCH, anchors and other errnos stay fatal. A fruitless
scan of a capability is rechecked before moving on: same-PIDfd readiness, or
PF_EXITING then the bounded wait, is a departure (its files may already be
gone, so its listing is empty), so a departing owner never becomes an empty
owner set; a live, non-exiting owner simply has no match. Other PIDfds, other
readlink/read/open sites, namespace mismatches and all other permission
failures remain HOLD, and a terminal leader state alone never qualifies.

| Site | Non-anchor, same PIDfd ready | Non-anchor, nonready | Anchor |
| --- | --- | --- | --- |
| stat, proc dir, task/children | ENOENT/ESRCH: departure | HOLD | ready ENOENT/ESRCH: refuses as gone |
| empty task listing | departure (census change) | `CUSTODY_TASKS_UNKNOWN` | `CUSTODY_TASKS_UNKNOWN` |
| namespace link | ENOENT/ESRCH/EACCES: departure | ENOENT + PF_EXITING: bounded wait; else HOLD | ready, or ENOENT + PF_EXITING: `CUSTODY_ANCHOR_GONE`; else HOLD |
| FD directory (open, read, entry, recheck) | ENOENT/ESRCH/EACCES: departure | EACCES + PF_EXITING: bounded wait; else HOLD | ready, or EACCES + PF_EXITING: `CUSTODY_ANCHOR_GONE`; else HOLD |
| fruitless FD scan | departure | PF_EXITING: bounded wait; else no match | ready or PF_EXITING: `CUSTODY_ANCHOR_GONE`; else no match |

The bounded wait ends in readiness (departure), the operation cutoff (its own
phase-tagged expiry) or the full 2 s (sticky `CUSTODY_EXIT_UNCONFIRMED`). Other
errnos at every site stay HOLD.

A separate incomplete-census rule applies only to a newly discovered, unbound,
non-anchor candidate whose PID is an actual positive integer. At the exact
`os.pidfd_open(pid, 0)` site, EINVAL with no returned descriptor invalidates the
entire pass. It is neither an exit proof nor an ownership grant. Previously
held live capabilities remain held; failed acquisition releases only its unused
descriptor reservation. Unresolved identities, reads, descriptors, reap
records and the cumulative 128-pass limit remain charged within the same
operation and fixed deadline; only identities whose retirement is proved can
release a slot.
Constructors, anchors, already-held capabilities, other errno values, nonzero
flags and earlier sticky errors have no exception or fallback.

A fresh complete guardian-rooted closure must reacquire any still-present
candidate. A persistent unacquirable candidate or missing known live capability
HOLDs within the existing bounds. An old edge absent from that entire fresh
closure is withdrawn; this makes no historical PID-death claim. An independently
proved nonempty closed set may resume monitoring and normal proved-peer HTTP.
Every parent/adoption/readiness change still restarts complete proof; departing
tasks are never silently filtered into an empty set.

Guardian reaping uses `waitpid(-1, WNOHANG | __WALL)` for all direct children,
including non-SIGCHLD clones. Each positive result has its PID and exit/signal
status accounted in a bounded shared-operation ledger before any later budget
failure. A reap record is retained under its separate 128-record limit and
does not consume a live identity slot; a still-pinned capability for that PID
continues to consume one. Reap records and census passes do not reset on
retries. A zero wait result means children remain. Only current ECHILD following
complete closure can permit treeEmpty. Any positive final reap changes the empty
epoch and requires another full census before a new final ECHILD check. No work
or one-shot cleanup deadline is renewed. These Linux reaping/census constraints
are process-custody evidence, not platform acceptance.

The guardian loads the exact sibling module by file under `python -I -S -B`;
it does not depend on ambient module search paths. The driver is the lifecycle
caller; the supervisor owns adoption/reaping and parent-death handling; the
custody module hides capabilities and connected-peer proof. The selected
supervisor is recorded in platform and run receipts. A complete bounded
control uncertainty fails promptly without probing a normally exiting
guardian's PID as a new control check. Only the first fixed reason and bounded
errno are retained; child output, arguments, environment and config are absent
from that diagnostic record.

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
that changes UID (or session in strict mode), or a target that needs systemd services can prevent
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

## Source-only integration boundary

This detached-custody candidate is uncommitted source based on commit
`69963675d7c763ae5ef6e64090baae6aa4fcbd60` with the separately reviewed proc V2
overlay. Its new bytes are not committed699 bytes. Workflow, CI-controller,
authority-lock and genuine-Ubuntu documentation changes belong to a separate
reviewed composition. The existing CI authority does not admit these changed
runtime files or the new module/fixtures. A future helper must bind the entire
source closure and explicitly select `--supervisor owned-subreaper` before a
new genuine run; this source freeze authorizes no push or CI run.

The existing exclusive private-root name/marker and receipt path remain the
run identity; the receipt's selected supervisor, owned guardian PID/birth/UID/
PGID/session, bounded first uncertainty, command/check order and cleanup state
remain evidence rather than authority. The existing11-file nonsecret artifact
allowlist need not be expanded. Local fixtures do not relabel failed Ubuntu699,
or establish WSL2/provider/reboot, production or tenant acceptance.
