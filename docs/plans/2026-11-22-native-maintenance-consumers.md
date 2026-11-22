# Native maintenance consumer reconciliation

Status: author candidate, bound to frozen v3 source/package; final verification and root review precede a PR. Native release version remains unchanged. No publication or runtime operation is authorized by this plan.

Base: `a1149879db6644c193625472bf647af5871d6ffa`, identical tree to audited `8321720057f6addf8dc744d51af814fc5e88877b`.

1. Verify the supplied frozen plugin and npm archive. The initial synthetic metadata fixture was retired before the first test execution when the actual 37-file 0.3.35 package became available. Tests extract the actual archive and keep metadata unchanged for positive cases.
2. Add an explicit 0.3.35 path to each native patch. Darwin keeps flock discovery, the no-/proc resume rule and Intel constraints. Upstream platform/bwrap support and the longer probe supersede the historical platform edits and warm-up only on the new path. Old supported versions keep their historical implementation.
3. Preserve strict maintenance, validated Python/console spawn, identity/auth/signal checks and locks. Require the reviewed source boundaries before applying modern edits. Unknown versions and source drift retain existing warning/skip semantics; they do not gain maintenance admission.
4. Exercise both patch orders, idempotence, source compilers, drift/unknown-version negatives and old-version warm-up. Drive the actual installer and adapter with explicit owned transport fixtures. No SDK is imported. Fake proof transport does not establish SDK admission.
5. Adapt affected existing fixtures to the guard instead of adding a production bypass. Retain assertions for maintenance calls and refusal. Intel A-C has an explicit offline mode so it cannot enter package resolution or real SDK tests.
6. Update only this candidate's pin/archive/manifest. Preserve the old archive and original manifest receipt. Record freeze/handoff provenance explicitly when no source commit exists; do not attribute uncommitted bytes to a base commit.
7. Supply source inventory, diff and test receipts for independent root review. The replacement v3 package is now bound; run the affected fixture suites before the new native source freeze. Add UV copy-mode child/caller assertions and a mutation negative. deployment-ci runs the new suite with full history; there is no missing-history skip.

Current input: v3 archive `a882728cbf506cef201ef855368318e18cb879ef93baafdecdf4959b4cca0cbc`, source freeze `04c331d170a99da37bf69efc02ff0ba62da29b8c4848ca0002ca0ad847ff2378`, handoff `174feef5242af546e1ee06e2218ee3dc6695a4a9222466955fac8d3cdf8ab3ee`. Independent input verification checked all 97 source archive members and all 37 npm file bytes; 18 runtime files are unchanged from the retired package, and the only runtime delta is the installer child copy-mode setting.

Historical provisional input `439bd777…` was retired after root confirmed uv hardlinks. Poincare owns that diagnosis/fix and real owned BEFORE evidence; this lane uses the reviewed v3 package and does not duplicate SDK installs. Old raw archive and receipts remain in the evidence lane. The current native `VERSION`, old 0.3.34 archive and frozen operational sources remain unchanged.
