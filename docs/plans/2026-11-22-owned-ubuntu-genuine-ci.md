# Genuine owned Ubuntu CI route implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> Session override: this agent implements the authorized source changes now. Only static verification is authorized; no tests, SDK imports, installer/build/network/CI, commits, pushes or PRs. No execution-choice confirmation is needed.

**Goal:** Add the smallest separate automatic-PR Ubuntu 24.04 route that genuinely builds, packages and exercises the owned acceptance driver on a disposable nonroot runner when later authorized.

**Architecture:** A dedicated workflow checks out the PR head with credential persistence disabled and contents-read permission. One standard-library helper checks source/tool/platform identity, creates fresh short canonical private roots, invokes the original build and packager in an empty allowlisted environment, records the archive SHA, and passes that exact artifact/path/SHA to the unchanged real driver. Only explicit nonsecret evidence files are uploaded; failures retain their nonzero/HOLD result and private roots until runner disposal.

**Tech Stack:** GitHub Actions, system Python 3.11+, preprovisioned Ubuntu tools, original Bash installer/packager, existing owned driver. No new fixture or host infrastructure.

---

### Task 1: Establish the isolated candidate
1. Create a new detached worktree at exact 172522c8a4065f80e813d6d4710b26b13b6094c7.
2. Copy exactly the ten frozen V3 proposed files, preserving bytes/modes. Do not inspect unfinished V4.
3. Save this plan under docs/plans/2026-11-22-owned-ubuntu-genuine-ci.md before implementation.
4. Keep candidate provenance explicitly provisional pending Curie's V4 test-only refresh. Base reference is not candidate commit identity.

### Task 2: Bind inputs and implement the direct route
Create scripts/owned-ubuntu-acceptance-ci.lock.json and scripts/owned-ubuntu-acceptance-ci.py.
1. Pin the original build packager separately from the 39-input installer lock and the ten provisional frozen V3 files.
2. Future preparation must verify actual PR-head checkout identity, Ubuntu 24.04/x64/nonroot, canonical private roots, system Python/procfs/pidfd/subreaper and executable prerequisites. Fail missing tools; never apt/sudo/preflight.
3. Use fresh separate build, package and acceptance roots beneath a short private /tmp root; private HOME/TMPDIR/XDG/tool caches, env -i and umask022.
4. Execute the unchanged installer with exactly node fetch piweb (artifact variable absent), then the unchanged existing packager with the same build prefix/environment.
5. Record and compare the generated checksum and independently computed archive SHA immediately after packaging. Run the real owned CLI with that same recorded SHA, local archive and fresh acceptance parent.
6. Bound commands and workflow steps. Never continue acceptance after a failed build; never replace HOLD/nonzero with success. No mocks, fixture suite, providers, login/connect, service or release publisher.

### Task 3: Add the separate automatic PR workflow and documentation
Create .github/workflows/owned-ubuntu-acceptance.yml and docs/OWNED-UBUNTU-GENUINE-CI.md.
1. ubuntu-24.04, contents:read, persist-credentials:false, explicit PR head SHA, no supplied secrets, no protected-main dispatch workaround.
2. Bounded prepare/build+package/accept/collection steps and a 90-minute job. Preserve existing CI unchanged.
3. Always attempt upload of only explicit nonsecret identity/status, driver receipts, artifact manifest and checksum. Never upload the archive, private roots, raw process output or generated configs/identity/pairing state.
4. Distinguish genuine future hosted Ubuntu scenario evidence from synthetic fixtures, actual CI evidence, production admission and WSL2/provider/reboot claims.
5. Document same-run builder provenance and unchanged installer/driver limits; no reproducible-dependency-byte or PTY claim.

### Task 4: Static verification and provisional source freeze
1. Parse/compile new Python without importing/executing it; parse workflow YAML and Bash run bodies without executing them.
2. Check workflow permissions/triggers/head checkout/timeouts, exact command construction, evidence allowlist, copied V3 preservation, source pins, git diff whitespace and unchanged existing CI.
3. Do not run any helper phase, acceptance source-plan, tests, installer, packager, SDK or CI.
4. Write a new source inventory, static-check receipt and source archive/handoff in the exclusive evidence child. Record original base/HEAD and all uncommitted delta/new files, including copied V3.
5. Freeze as PROVISIONAL_PENDING_V4_TEST_ONLY_REFRESH_FOR_ROOT_REVIEW. No final-base, passing pipeline or operational claim; root must refresh the V4 test file/pin and independently review before any submission/execution.

## Authorized frozen V4 refresh

After this plan was written, the user supplied final frozen V4 f221a00d / handoff 0b40b939 and authorized the test-only private-copy refresh. Copied only tests/test_owned_native_acceptance.py (a40c4919ea9cde2473f418643c5dfa97ee2c7d989839d563f925890247b688f0) and updated candidate provenance. The other nine files still exactly match frozen V3/V4. The source refresh is complete; root/Bacon review and authorization of the genuine CI route remain separate. No V4 test rerun is authorized. The final handoff must say source-only, not pending an already-completed copy refresh, and must not assert root acceptance or actual CI.

## Final submission and addon-only freeze scope

Root subsequently reported V4 accepted and local commit ec0a52a20958d7ca8ad779a5b5d2391b52248892 (tree 982e0f89ace1acf2cd8753f9a6434d829ce1ee13, parent 172522c8). This supersedes the earlier provisional status. The final inventory/archive/handoff contains only the five new workflow/helper/lock/docs/plan files, with the accepted ten source inputs and 39 original inputs referenced by pins. Do not duplicate the accepted source/test archive. Integrate the reviewed addon atop ec0a52a for one later PR push by root; this lane performs no commit/push/PR/CI. Acceptance of this addon and actual pipeline results remain unclaimed.
