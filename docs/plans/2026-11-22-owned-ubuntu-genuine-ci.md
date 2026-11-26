# Genuine Ubuntu acceptance composition

The current composition updates PR17 to native v0.2.13 and the reviewed custody runtime. Earlier source-only handoffs remain historical evidence. This plan does not itself authorize user-host or production changes.

1. Preserve the released v0.2.13 installer lock and package bytes. Pin its exact hash, size and 40 input rows plus the current packager in the CI controller.
2. Compose the reviewed custody runtime, supervisor, driver, controller and safety suites. Preserve exact-object retirement, failed-close HOLD, bounded descriptors/identities/reads/passes/reaps, and fixed deadlines.
3. Freeze non-lock source leaves first. Generate the source-row inventory and reproducible source archive, then the handoff binding their hashes, roles and supported invocation/receipt contract. Generate the consumer lock last to avoid circular hashes.
4. Verify actual source/metadata/archive bytes and the synthetic authority refusal tests. Never turn synthetic fixture metadata into operational authority.
5. Run custody, lifecycle, departure and controller suites only on isolated CI. The genuine job checks the actual PR head, builds Pi Web, records the artifact hash, and invokes the owned Ubuntu scenario.
6. Inspect its raw receipt, teardown verification and retained-root flag before accepting a run. Collection preserves eleven allowlisted evidence files and cannot turn a failed scenario into success.
7. Merge only after required CI passes. These checks do not authorize provider calls, WSL2/reboot acceptance, other hosts or production rollout.
