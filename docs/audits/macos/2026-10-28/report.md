<!-- docs/audits/macos/2026-10-28/report.md -->

# macOS audit report and bounded handoff

Code checkpoint updated **28 October 2026 at 21:46 Paris**. All reported times use Europe/Paris (UTC+01:00). The user asked to finish the already-engaged work and already-found defects, save the outcome, and stop new research before deleting the container.

## Current published code and final CI

The published code checkpoint is **`b56677ea345e115828e2bf5b5dbfcf5cf5e46c7e`**, tree **`1a36008ddbe51aea487668c69c25e09a5109edef`**, on **`fix/macos`**. The final development merge imports `18d69a24c06586186a221c1afb5ce703732ac4a1`. All **35 delivery atoms** and **12 normal development merges** are preserved; no rebase, force-push, pull request, or push to dev/main was performed. Delivery atoms include test infrastructure and one style change; they are not a claim of 35 distinct runtime bugs.

The final code push completed with actual exit0. Workflow dispatch completed with HTTP204 and actual exit0 at **21:41:08.929658 Paris**, requesting `os_lanes=macos`. New run [**40765470617**](https://github.com/adrienm7/ergopti/actions/runs/40765470617), attempt1, names exact source `b56677ea345e115828e2bf5b5dbfcf5cf5e46c7e` and was created at **21:41:08 Paris**. Run **40765470617**, attempt1, finished **FAILURE** at **2026-10-28T22:40:15+01:00 Paris**, on exact source `b56677ea345e115828e2bf5b5dbfcf5cf5e46c7e`. Its complete census is **47 jobs: 39 success, 5 skipped, 3 failure**. The observer completed with actual child exit0. The immutable final receipt has SHA256 `92d9f6903302da8252503c2deb9905d4e4645ed3275fee7be5b40ab3c780bd42`. Every skipped or unexecuted stage remains classified as such; a green neighboring job is never substituted.

Local full Common qualification executes **529/529 checks successfully**, plus **18 other gates with actual exit0** and durable child wait0. It completed **21:33:34.061 Paris**, followed by the sequential final observer and qualifier at **21:34:53 Paris**. Source and index fingerprints are unchanged and no relevant live process remains. The immutable qualification has SHA256 `923686606c37f2ab92d607567ff88ed3eb7ca5dde02a44095a8c2f06e060a761` and explicitly records staged precommit contents. The ordinary oracle commit and subsequent merge have exactly that qualified whole tree; old receipts were not rewritten to later commits.

The full driver receipts retain their actual parent source `ae73ed2f4d7b915e66b1628c057d346c456d91aa`: macOS **25,385 passed / 2,040 modules +185/185 E2E** (one historical explicit host-specific NA), Linux **19,810 passed /804 modules +302/302 E2E result records**. All product code, driver tests and harness projections are byte-identical in the final code checkpoint. The real change planner selects only format and JS for the final test-only change. Linux's 302 printed records have 274 distinct human labels; no unique-scenario-identity claim is made. The corrected diagnostic and its original failures remain archived, including the single bounded menu-row measurement change 2258 to 2257.

## Final atomic test repair:35

`d02675fa2df11b8d5d0adbfa1e673164b7a41ea1` — **test: verify executable recommended info owners**.

**Bug and original proof:** Common check 487 failed because its Windows source oracle still required raw `gesture_recommended_info`, whereas dev correctly used `MenuCommand.GESTURE_RECOMMENDED_INFO` with the same handler. The exact old gate exits1 on the current product source. The initial proposed guard also accepts eleven reproduced nonexecuting-string decoys: registration, native helper and required reason only in unused strings on each OS, plus two separate handler definitions only in strings on Windows/macOS. Linux's inline handler is covered by its registration case.

**Cause and correction:** source spelling and substring searches could certify comments or string content as executable ownership. The one changed CJS test now reuses the existing comment/string lexical owner, locates actual handler definitions and finite native-call argument spans, and requires the canonical registration and reason literals in the actual dialog call. It preserves all original three-OS default, gesture, debounce, MLX, dialog and absence assertions. No driver, generated artifact, default or user-facing text changes.

**Regression and review:** the corrected gate passes with **22 actually executed negative controls**. All eleven prior lexical-decoy probes now observe the expected specific assertion failure. Five deliberately weakened oracle variants fail: old predicate, missing registration guard, missing comment boundary, missing string boundary and missing native-call argument boundary. The exact old original remains a positive-gate failure. Independent peer acceptance has SHA256 `61cca1939044943817ad64c7090e413e43fd3c5926454c2c7a4d58e7e98b1d0f`; the author revision2 receipt has SHA256 `bf71be21cba49cfde64847d8809c72bee0a25b12ec6a33c73bca6a207b4f8ec1`. Diagnostic-only selection/import-order mistakes remain recorded; they were not product-test skips or weakened assertions. Normal commit hooks exit0 and the committed tree equals the fully qualified content.

**Three-OS scope:** this is the shared source-contract test that blocks Common qualification of every selected lane, including macOS. The original failure concerns the Windows command spelling; all three executable dialog owners and all eleven known lexical decoys are checked. Product behavior on all three OS remains unchanged.

## Twelfth normal development merge

`b56677ea345e115828e2bf5b5dbfcf5cf5e46c7e` — **chore(macos): merge the upstream command guard repair**. Parents are the oracle commit above and `18d69a24c06586186a221c1afb5ce703732ac4a1`. The incoming development commit independently fixes the simple canonical command guard. The one CJS conflict is resolved by preserving dev's canonical command and same handler together with the independently verified stricter 22-control oracle. The **entire resulting tree remains `1a36008ddbe51aea487668c69c25e09a5109edef`**, identical to the fully qualified oracle commit. All 13 quick gates and normal merge hooks pass; a full rerun is unnecessary for identical bytes. The initial merge conflict exit1 is archived as a merge event, not a failing test.

The private candidate `f699073f0d9fe66a23cfb2f2e45a71a28c4ec785` remains **superseded recovery data only**. It was not integrated or counted among these 35 atoms. Its ref is preserved in the evidence bundle with an explicit DO_NOT_CHERRY_PICK warning.

## Complete delivered commit index

Per-commit bug, cause and regression details for atoms 1–34 remain in the source-specific historical ledger below; atom 35 is detailed above. The eight earlier historical commits and twelve merge commits are documented separately and are not extra new bug fixes.

| #   | SHA                                        | Exact subject                                                     |
| --- | ------------------------------------------ | ----------------------------------------------------------------- |
| 1   | `b1ee6bf4740e8b9b5b47cc8ff3922006311b3911` | test(macos): await actual pac worker ownership transitions        |
| 2   | `cad35740f2cfd1edfb43779bf81954fee384cc53` | fix(macos): retain worker completion after file-limit signals     |
| 3   | `43b421fc9cd24d6229bdaef2216be557f6cdd5a4` | fix(macos): stage release swaps on the destination filesystem     |
| 4   | `e18b28e6a5558878abf47fd07c7cc0876b31c989` | fix(macos): publish release swaps with exclusive renames          |
| 5   | `278a367cc383ec2a080c56faeeb323914d33625c` | fix(macos): retire only owned app cloner reservations             |
| 6   | `5b02d9932d741f3c8106c2b2141bae24bf9d1f54` | fix(macos): preserve mkdir errno during bundle reservation        |
| 7   | `20c2e8ffcb81a4e2d4bc380b59726f2cb5058b64` | test(macos): preserve posix path bytes in cloner probes           |
| 8   | `a2b3dd323902b0d849e33472a723bdea4d519442` | fix(macos): route accepted scheme uris through native open        |
| 9   | `ed4fa805eddef224b6cb8eb3d9239ad1543786dd` | fix(macos): finish cloner cleanup after diagnostic failures       |
| 10  | `75137defe3ae2fe22c45df578a89204f39bb2f68` | test(macos): discover native runner paths without shell records   |
| 11  | `186c216dcb7ee295880709a2ac01af27779b1e2c` | test(macos): resolve temporary roots with native path rules       |
| 12  | `d8383cadd6c91f971f6d060e6cf90d9afe2bb86c` | fix(macos): give each app cloner bundle an independent identity   |
| 13  | `c564982271baf69a24bfb70cb02206f471323f00` | test(macos): enumerate production sources with native paths       |
| 14  | `2e60bb085e30ed120417eddacf0d9d7156d51272` | test(macos): preserve complete runtime source inventories         |
| 15  | `8283da9025a16d5d7944499d967e19425bb0289d` | test(macos): preserve native e2e bootstrap paths                  |
| 16  | `9e1740002c44743681fedfff34b621202964e14b` | test(macos): follow pending layout activation ownership           |
| 17  | `490b1705c87a73b34126eaa021996a96989fd566` | test(macos): find the enabled-list editor by its declaration      |
| 18  | `2c001889c2901703eba39deafa14b739fa6f1da3` | test(macos): match the two-child input-source editor              |
| 19  | `4c6c8a8f03fe284a0dbe5a869366630eed18c03b` | test(linux): reload the configuration guard for its logger        |
| 20  | `b33bfcb700f7731d8c38dd7f89cba718f455ca12` | fix(macos): bootstrap standalone e2e without native lua modules   |
| 21  | `56bdf43a94856a00db83aa6e71424530d0a2e352` | test(macos): align native uri cases with neutral fixture paths    |
| 22  | `b7c66b31e8033420669abbbd975d42b45296d8c6` | fix(macos): report failed app cloner receipt writes               |
| 23  | `62f2c76b8e034f1e6fbd6596029c299e8b870d6a` | test(macos): arm log-write limits after resource admission        |
| 24  | `329bdda8a1b54790a63cdda2c1776f1dcb061dbc` | fix(macos): create writable blank release fixture images          |
| 25  | `cd9465a7f9c99666d51f59eab9896f01527f93af` | fix(macos): qualify native release scripts without undeclared lua |
| 26  | `c1d281680533fdfd7df2148b7eaaed03348136e7` | test(macos): follow fresh-process layout confirmation callbacks   |
| 27  | `5e11e36cea21ae791ee89c1d7a0c3f5c765c7b8a` | fix(macos): fence ledger replay until publication commits         |
| 28  | `87f277a98f13b3839074cf5e5b80e61da20649a6` | fix(macos): configure fresh input-source settle delays            |
| 29  | `439fabefb500d29e142e7773bf13922780c02fee` | style(macos): describe layout behavior without plan labels        |
| 30  | `a34bc3f01be4072053db8fd03d4788504fe6f214` | fix(macos): check native bundle receipt delivery                  |
| 31  | `9811f27f344e9ce6b8fb93b7f0aee1484a3754ad` | fix(macos): report deferred layout action failures                |
| 32  | `c71552b77386ae5eaf4cb0d0461f1b47e4da5d43` | fix(macos): retire interrupted MLX bootstrap workspaces           |
| 33  | `bdd4ff26c5a182c4a53de8f5966795a4bdb2cd5f` | test(macos): recognize direct deferred layout ownership           |
| 34  | `5d14ff8156196892edb2c3d7d39551a4a42c07ed` | fix(macos): refuse field runs during terminal transitions         |
| 35  | `d02675fa2df11b8d5d0adbfa1e673164b7a41ea1` | test: verify executable recommended info owners                   |

## Completed workspace cleanup

At the completed checkpoint, three no-longer-needed validator/author worktrees were archived and normally removed. The final receipt records **1,586,548,736 allocated bytes reclaimed** (about 1.48GiB), with compact proof files retained outside those worktrees and 16,384,078 bytes of verified cache/source archives retained separately. Every branch ref, the Root/original HEAD and index, and both dependency targets remain unchanged. Only the original and delivery worktrees remain registered. Cleanup receipt SHA256: `d9ace73821cb93ca5895d4fc68e58c16b15a5f9c73b4b86d9ed3bc7c8d3071ec`. The compact backup carries its metadata, not the redundant ignored-cache archives.

## Remaining work and evidence

[TODO.md](TODO.md) records the one confirmed protected owned-Ollama bootstrap workspace leak. The two Swift source-flow hypotheses and physical/TCC/field questions are explicitly unconfirmed. The old locale, Windows-literal and duplicate-unit issues were repaired upstream; check 487 and the eleven known oracle decoys are now repaired by atom 35. The user stopped new audits; no additional research is authorized by this handoff.

[README.md](README.md), [manifest.json](manifest.json) and `evidence.tar.gz` preserve the recorded receipts, original negative probes, source freezes, reproducible protected-helper proof and recoverable Git refs. Historical `/workspace/scratch/...` paths identify their recorded archive locations; they are not promises that the deleted container still exists.

## Final hosted CI and documentation source binding

Run **40765470617**, attempt1, finished **FAILURE** at **2026-10-28T22:40:15+01:00 Paris**, on exact source `b56677ea345e115828e2bf5b5dbfcf5cf5e46c7e`. Its complete census is **47 jobs: 39 success, 5 skipped, 3 failure**. The observer completed with actual child exit0. The immutable final receipt has SHA256 `92d9f6903302da8252503c2deb9905d4e4645ed3275fee7be5b40ab3c780bd42`. Every skipped or unexecuted stage remains classified as such; a green neighboring job is never substituted.

Current-source reviewed evidence is preserved under `recorded/oct28-merge11-final-ci/reviewed-evidence/`:

- `common-data-source.json` — SHA256 `3275ebc031ad08665e262faed3610bc145c3cd271870a1db4c39aaee8ab8ad24`.
- `common-input-actions.json` — SHA256 `ff381f39ad7552d990741f6548438bd5256c2029ddc0d2468238699731277b44`.
- `common-verdict.json` — SHA256 `fd0a7a990722757d720b1d0bbc0261455669ba128ab9f6d08a297c019cdf8bcb`.
- `macos-e2e.json` — SHA256 `a437b0e7d3098d2edf3910d3467737e209f4055b317899fae8ef194b876d8779`.
- `macos-lua-unit-integration.json` — SHA256 `d4e81fd2c7c434c13fc51c1ceec5f27a6a2b65dddb8405799c222d1b3dc72e14`.
- `managed-intel-receiving.json` — SHA256 `cb4cf0d74a7df6548a0911209e9cfdcdd8f57d1a20f0a4a46f5e9b424804d61a`.
- `native-intel.json` — SHA256 `a09fae92e77ea5f82ba75222c8b0164e6648bc632dcf4ee8912233042958f184`.
- `native26-incomplete.json` — SHA256 `88a3bcfab76b9b9b0a27e10f6fb53992b6798bd0b73bc0ca080183f5c6f8aaf7`.
- `tooltip-additional-native.json` — SHA256 `8d329552aaf7d8749e7ff63e9afdda9e9b7ca9b014bef4b9b011791e07e10ae6`.
- `tooltip-native.json` — SHA256 `faa2c1159e1949b0b7a9d9fcf9a2894d1a98c484a954a0e083c202f293e341c8`.

The macOS26 Swift step hit its fixed ten-minute action deadline at **22:37:22.851755 Paris**. Its actual transcript records **387 case starts, 386 distinct passed cases, no printed XCTest assertion failure, and no full successful suite summary**. The final started-but-unfinished case is `ManagedPACSourceTests.testRealPACSourceTrustAnchorsPreserveHostnameAndDowngradeRefusal`. The earlier `HomebrewArchiveAcceptanceTests.testRealBrewZIPInstallXZUpgradeAndRefusalsPreserveInstalledState` completed successfully in **288.971 seconds**; that duration does not establish why it was slow or rule out a later test hang. The native job therefore fails and the macOS Build/Install stages remain unexecuted; the two final verdict failures are downstream of this stage refusal. The workflow timeout is in a protected area and was not changed. Investigation and full current-source native/build/install qualification remain TODO; no automatic retry or test bypass was used. An earlier progress inference incorrectly called the Swift step successful when later always-run diagnostics started; the retained `native-stage-correction.json` corrects that inference against the actual step verdict and transcript.

The final handoff is a documentation-only commit adding exactly the five files in `docs/audits/macos/2026-10-28/`. The required final verification checks that every code, product, test, package and CI/harness file outside those paths remains byte-identical to the CI source above. CI qualifies that explicit code source; it does not execute the subsequent documentation commit. The final documentation commit SHA and normal push receipt are reported in the final response and ordinary branch history. No new audit, retry, test quarantine or driver change belongs to this handoff.

**Qualification remains incomplete.** Preserve the actual failing/cancelled/unexecuted stages below and in TODO; do not describe this run as green.

- `123097469754` — macOS / E2E tests (Launcher XCTest and native probes (macOS 26)): **failure**, runner `1000066318`.
  - Actual step: Run Swift launcher tests on macOS 26 — failure.

- `123117406702` — macOS / Verdict (All mandatory results): **failure**, runner `1000066371`.
  - Actual step: Require the complete source-bound stage chain — failure.

- `123117605624` — Release / Verify all lanes and original plan: **failure**, runner `1000066373`.
  - Actual step: Assert every required lane and the original plan — failure.

## Historical source-specific ledger through 20:46 Paris

The following ledger is retained from the earlier report snapshot. Its checkpoint words such as “current”, “pending”, “not pushed” and “candidate” describe the explicit earlier times and source hashes there, not the current published checkpoint above. Its original bytes and SHA are also preserved in the archive. Current code35, merge12 and CI status are owned by the sections above.

### Earlier audit ledger

Updated 28 October 2026 at 20:46 Paris; all times are Europe/Paris (UTC+01:00).

Current local delivery integration is clean at **`ae73ed2f4d7b915e66b1628c057d346c456d91aa`**, tree **`fc5b9f2251109a97e5adf736f084d44f8ad134b1`**, after the eleventh normal development merge. Parents are `37ad319e514c3ade085dee292c35fca4e05d6cef` and latest fetched dev `42acb5cdcf2c027925a672b94b30bcbc79bccc34`. Field-admission fix 34 and the newer development merges remain local, **not yet pushed**. All nine incoming paths exactly match dev after generation, and both owned field-fix files are unchanged. No rebase, force-push or push to dev/main occurred.

Current full local results on this committed source: macOS **25,385/2,040 modules +185 E2E** and Linux **19,810/804 modules +302 E2E** pass. Common executes all 529 checks, with **528 pass / 1 fail**: the only remaining failure is check 487, a stale source oracle that requires the old raw gesture command identifier despite dev's canonical `MenuCommand.GESTURE_RECOMMENDED_INFO` route. All three previous Common failures 250/474/483 now pass. Root is preparing a separate strict **test-only** oracle correction with negative controls, preserving all three OS assertions and all product/default behavior. It is not committed or pushed; the next delivery atom 35, if qualified, is distinct from the superseded private `f699` candidate. Publication remains blocked on actual complete Common success.

Published fix/macos remains `80e8092f2051ad4927dcc880f9585a0e69f6613a`. Its run [**40739753554**](https://github.com/adrienm7/ergopti/actions/runs/40739753554), started **18:52:02 Paris**, finishes **FAILURE at 20:17:49 Paris**: **48 jobs = 36 success + 4 failure + 7 skipped + 1 infrastructure cancellation**. No actual macOS product-test method fails. Mac26 Swift674/674, selected Intel172/172, Lua25,377/2,039 modules, E2E185/185, Tooltip12 captures, application packaging and four Install cells succeed. The last clean/Karabiner/upgraded-state Install cell does not execute: GitHub annotations report hosted-runner capacity refusal. No test is skipped or cancelled by Root. The two protected Common failures and dependent verdicts keep this old head red. Final receipt: `/workspace/scratch/oct28-ci-final33/final-receipt.json`, SHA256 `b11d40544cf11ad73b7cd810387a40b4f5751f12f46429abfd82df5f5e542810`; final appendix SHA256 `9f07327c313a624f4ef37d3c41fece08fa793b988647a93ef4dcfc041b7a596a`.

**Resolved upstream on latest dev:** `42acb5cdcf2c027925a672b94b30bcbc79bccc34` repairs all three Common defects found in the earlier snapshots: five gesture translations, the Windows MenuCommand identifier contract, and the carrier's duplicated timing conversion through canonical `health.now_ms`. These are upstream repairs, not new Root-authored fixes. The two protected Common areas are no longer listed as unfixed on latest dev. Existing red receipts remain valid for their original sources; fresh verification must establish the incoming source's result.

**Candidate35 is superseded, outside delivery.** Its owner completed local commit `f699073f0d9fe66a23cfb2f2e45a71a28c4ec785`, tree `6c9db77db58334bb6435f73cec2094e72934653e`, before withdrawal reached the owner. That commit exists only on the private owner branch: it was neither fast-forwarded into Root integration nor pushed. Root instead preserves dev's canonical implementation through the normal merge. Delivery accounting remains 34 atomic commits; the private candidate is not fix35 of that delivery. All precommit proofs are retained without rebinding. Supersession receipt `owner/superseded.json`, SHA256 `857abf827065c0cbc7c6dd5d7f894d6ff795043ffbdc751f1e62d6f2e67957ce`.

New complete qualification is now running on committed head `ae73ed2f4d`/tree `fc5b9f2251`: Common started at 20:24:14 Paris and macOS started at 20:24:15 Paris. Linux preparation has GO for that same source because upstream changes five shared locales; its producer launch is still pending. Earlier candidate35 results do not qualify this upstream implementation. All full results were pending at launch; their completed outcomes are recorded in the latest verification section below.

Historical completed run [40727519951](https://github.com/adrienm7/ergopti/actions/runs/40727519951), attempt 1, head `c80cf8dddb3e04df4849ac501cec1ca92b9e1c71`, ran **17:35:49–18:42:49 Paris**, **FAILURE** (terminal state observed 18:43:15). Its 44 jobs comprise 28 success, 5 failure, 9 skipped and 2 cancelled; annotations establish unavailable ARM runners for both unexecuted cells. Mac26 complete Swift674/674, Intel172/172 and Tooltip12 captures passed for that exact historical head. No result is rebound to later source.

Final source-bound CI receipt: `/workspace/scratch/oct28-ci-final30/final-receipt.json`, SHA256 `43d0e16e3898f44e69a619554fc372906501de19eebc29ec43c47b92ed693d04`; complete appendix `/workspace/scratch/oct28-ci-final30/ci-recovery-appendix.md`.

Historical c80 and80 runs have a direct Common data/source failure from the two incoming upstream gesture commits: da/it/nl/no/sv `menu.gestures.recommended_info` duplicates English without an allowlist entry; Windows `menu_gestures.ahk` contains eight configuration literals against baseline seven. Exact source pins prove the seven relevant files on c80 match dev f4e. Both failures were in explicitly excluded gesture/Windows areas and were retained unchanged in those snapshots. Latest dev42ac repairs both upstream; their original red receipts are not rewritten. No baseline has been increased and no test disabled. Evidence: `/workspace/scratch/oct28-ci-final30/common-data-source-failure-evidence.json` and `protected-upstream-source-pins.json`.

The complete local batch on c715 passes **25,377 macOS tests / 2,039 unique modules**, plus **185/185 E2E** and one pre-existing explicit host/driver-specific NA. All eight canonical groups have actual subprocess exit 0. Independent qualification and final residual observation both exit 0. Receipt: `/workspace/scratch/oct28-final32-hs/qualification.json`, `residual-observer.json`. The later oracle-only commit and incoming Linux-only merge preserve the macOS, shared-data, Windows and Linux-plus product subtree IDs exactly; this provenance is recorded in `/workspace/scratch/oct28-merge9-verification/source.json`. The source-bound c715 receipt is not rewritten to a later tree.

An environment reconnection interrupted two incomplete Common producers; neither is reported complete or green. Their unchanged logs and interruption observations remain under final32-common and final33-common. The replacement full final34 run completed on exact final80/tree22: **529 unique executed checks = 527 pass + 2 fail** (excluded locale check 250 and Windows literal check 474), actual JS exit 1 and durable outer child wait1 at **18:48:57 Paris**. **All 18 other gates exit 0**. Final physical source/index remain unchanged; no live owned process or unreadable live same-UID process remains. Previously introduced oracle failures 67/72 are fixed and pass. The registered MLX receiver 328 passes and asserts all 15 real component scenarios. One pre-existing AHK host-specific case is explicitly NOTEXECUTED; no desktop Windows qualification is claimed. Receipt: `/workspace/scratch/oct28-final34-common/qualification.json`, SHA256 `4efee0962ebb7de366173c572d3536ff32bdfa48629c626c774fbdc73ea1ed34`. These are genuine red Common results retained without a raised baseline, skipped test or replaced exit status.

Earlier full qualification of a34/treea5 remains valid for that exact earlier snapshot: JS **529/529**, macOS **25,373 / 2,038 modules +185 E2E**, Linux **19,809 / 804 modules +302 E2E**; all three producer exits 0. It is not rebound to the final tree. Receipt: `/workspace/scratch/oct28-bsd-writer-assembly/qualification.json`.

Normal publication of head `80e8092f2051ad4927dcc880f9585a0e69f6613a` succeeded: `git push -u origin fix/macos` exited 0, followed by a standard REST workflow dispatch with HTTP 204 and actual exit 0. Although `gh` sends expired authorization and returns 401, inherited-proxy REST access works without adding or changing authentication headers. No secret values were printed or authentication guards removed. Neither dev nor main was pushed. Publication receipt: `/workspace/scratch/oct28-final-publication/publication.json`. The newer local head `37ad319e51` has not been published.

Completed native results from run `40739753554` qualify published head `80e8092f20`: **674/674** full Mac26 Swift cases, **172/172** selected Intel cases, **185/185** standalone E2E scenarios, and **25,377 macOS tests across 2,039 unique modules** all pass. Tooltip executes all 12 painted captures and retires its owner process group. The application Build job succeeds and uploads both archive formats; four installation/launch cells pass and the final cell is unexecuted because of hosted-runner capacity. Common retains the two protected failures on this old source. These are completed job results; the whole run fails and does not qualify local37ad or newer dev. Receipts: `/workspace/scratch/oct28-ci-final33/{native26-evidence.json,native-intel-evidence.json,lua-executed-counts.json,tooltip-native-evidence.json,macos-build-evidence.json}`.

## Confirmed finding left outside the authorized edit scope

The unchanged macOS owned-Ollama helper `modules/llm/native_python_bootstrap.sh` (`native_bootstrap_python`), called by `ensure-ollama-native-deps.sh`, leaves its workspace and partial file when its process group receives SIGTERM during either uv or Python download. Both real signal probes return -15 and leave no live group members; the normal download-refusal control returns 1 and removes its workspace. The caller's real EXIT trap only reports the stage, and the native PTY guardian only owns its source snapshots, so neither retires these download folders. The absence of an operation-local resource owner is the cause.

This is a **confirmed unfixed bug in an explicitly protected owned-Ollama installation path**, distinct from the two protected Common-gate regressions. No repository file was changed. Proof uses the unchanged helper and caller trap, actual Linux Bash/filesystem/process signals, and only a strict local download port; it does not claim native Darwin/PTy execution. The macOS-specific helper is not used by the Windows or Linux product installers. Evidence/reproducer: `/workspace/scratch/oct28-protected-bootstrap-report/ready.json`, SHA256 `81b6b9302ccaa3c7f246d2db8b93e549693e5952c735b57b2a406fc6f6ceacb7`; `proof.json`, `probe-uv-python.py`. Maintainer question: should a later authorized change extend the proven per-operation cleanup ownership to this protected helper?

The two Swift worker source-flow hypotheses remain **unconfirmed**, not additional counted bugs: `/workspace/scratch/oct28-native-receipts/ready.json`. Their proposed native reproduction must run before any fix.

### Thirty-first atomic fix (published)

`9811f27f344e9ce6b8fb93b7f0aee1484a3754ad` — **fix(macos): report deferred layout action failures**.

**Bug/proof:** exceptions from native layout dispatch and deferred menu refresh disappeared. The exact two final regression cases fail against c80 (0 pass / 2 fail) and pass against the corrected source (2 pass / 0 fail). **Cause/fix:** each callback used an unchecked inner `pcall`, hiding the error before the canonical TimerScheduler exception guard. Pass both callbacks directly to DeferredWork, so the existing guard logs the original failure once and retires each timer. No added scheduling, constants or logging abstraction.

**Regression scope:** actual menu-provider action closures, real DeferredWork and TimerScheduler, modeled native timers; the fixture substitutes manifest.build with the actual active-layout provider, so this is not a complete manifest-rendering or native CoreServices test. Both dispatch and refresh failures must produce exactly one original-marker diagnostic and leave zero active timers. Nine related modules and strict/format/generation/encoding/source guards pass. Evidence: `/workspace/scratch/oct28-lifecycle-tail/gates.json`, `before-final-test.log`, `after-final-test.log`, `source-freeze.json`. Windows/Linux never execute these macOS CoreServices deferrals.

### Thirty-second atomic fix (published)

`c71552b77386ae5eaf4cb0d0461f1b47e4da5d43` — **fix(macos): retire interrupted MLX bootstrap workspaces**. Author commit `f21f1a01f83c506a9b96ccaa261f6abebca67ab6` was normally cherry-picked; no merge or squash of the two independent fixes.

**Bug/proof:** actual process-group SIGTERM during uv and managed Python downloads leaves each private workspace and partial download behind. Both unchanged final group-interruption cases fail against the exact c80 source. **Cause/fix:** allocations happened before the later venv EXIT cleanup was installed, and explicit rm paths could not run on interruption. Each bootstrap operation now owns a local subshell with EXIT/INT/TERM/HUP cleanup and retains its allocated directory identity; cleanup refuses a replaced/unverified directory and preserves the primary error. Python discovery/export remains in the caller. The later venv trap and protected Ollama helper are untouched.

**Regression:** 5 methods / 15 business scenarios pass, including both live-download group interruptions, direct owner signals, failure/success status, parent export and foreign directory preservation; independent review replays all 15. Old foreign deletion and SIGINT timeout observations are retained but not counted as separate delivered fixes. Related macOS modules pass 84/84, the fingerprint gate passes 33/33, and normal hooks/style/encoding pass. Linux-host component proof uses actual Bash/filesystem/signals with only the BSD-stat boundary ported. The later native run is recorded separately in the current CI status; these component receipts are not native execution claims. Windows/Linux cannot run this Apple-silicon MLX installer. Evidence: `/workspace/scratch/oct28-other-shell-receipts/ready.json` and `peer-review.json`.

**Historical final32 checkpoint:** the c715 Common and macOS batch ran on exact tree `2aa61ec29cebd49834e27ee751ad5121d95b7dd0`. The macOS producer completed successfully as recorded above; an environment reconnection interrupted the Common producer before completion. Its partial output is not reported green.

That checkpoint exposed two owned source-oracle failures (handler bijection and category coverage): the native-layout predicate still required the swallowed `pcall(fn)` spelling removed by 981. Commit 33 below repairs that oracle, retaining existing controls and adding negative controls. These owned failures are distinct from the two protected upstream failures.

**Historical authentication checkpoint:** `gh` returned 401 and connected tools exposed no dispatch operation. Standard inherited-proxy REST access was subsequently verified, and actual push/dispatch succeeded for head `80e8092f20` as recorded above. No credentials were printed or guards overridden. The two Swift source-flow hypotheses remain unconfirmed.

### Thirty-third atomic fix (published)

`bdd4ff26c5a182c4a53de8f5966795a4bdb2cd5f` — **test(macos): recognize direct deferred layout ownership**.

**Bug/proof:** the canonical handler and category source predicates still required the swallowed pcall removed in 981. Both actual gates fail at the positive layout owner check on c715. **Cause/fix:** the finite source oracle certified the old harmful spelling. Require the canonical direct callback handoff while retaining all previous branch, identity and final-publication checks; do not accept the old wrapper as a compatibility path.

**Regression:** both gates pass with the strict corrected predicate. Five mutations for each of six behavioral rows in each suite add **60 negative controls**: swallowing, discarding or omitting work and a foreign owner label. Restoring the old predicate makes both positive checks fail; removing the new guard makes both suites fail the new negative controls. Strict/format/gen/false-green/encoding and normal hooks pass. Only the macOS CoreServices predicate changes; other OS ownership rules remain unchanged. Evidence: `/workspace/scratch/oct28-layout-owner-oracle/ready.json` and `negative-proofs.json`.

### Ninth ordinary dev synchronization

`80e8092f2051ad4927dcc880f9585a0e69f6613a` — **chore(macos): merge current Linux validation fixes from dev**, incoming parent `463352a2d49d0fbe3fc9d7db3c8a425547b8a012`. Imports three upstream Linux validation/Python-floor commits, with all 10 incoming paths exactly dev after canonical generation. These are not Root-authored bug fixes. Minimum generation, format, strict conventions, AHK-local, sealed updater, encodings, Lua-global checks and five incoming Python-floor tests pass; ordinary commit hook succeeds. No product-plus subtree changes relative to c715. Receipt: `/workspace/scratch/oct28-merge9-verification/source.json`, `receipts.json`, `commit.log`.

Five additional unused owned worktrees were normally removed at **18:16:49 Paris**, retaining branch refs, one verified source bundle and recoverable ignored-content archives. **2.33 GiB** allocated checkout bytes reclaimed; Root/original/dependencies and active validators unchanged. Receipt: `/workspace/scratch/oct28-final-unused-cleanup/receipt.json`.

A bounded sibling review of run_install_and_chain found no further proved bug: the actual install_user/system owner already contains/logs exceptions and releases its lock. Controlled real-helper failures and subsequent healthy retries pass in both scopes. No source/test change was made. Evidence: `/workspace/scratch/oct28-layout-install-audit/ready.json`.

The detailed historical sections below retain their original snapshot scopes; their pending/running statements describe those earlier checkpoints and do not supersede this current status.

Historical nineteen-commit integration base: `d895f9471b2de3d948c186707888c1ed7edd310d`, a normal merge of `origin/dev` at `85e34b905a5016846dc98cf1126dd1ca9572940d`. No rebases, force pushes, or release-branch pushes.

Historical nineteen-commit candidate tree: `46b6ad843959f1acd2c20e8413245cc901575f3a`; full binary patch SHA-256 `59673432b097422d29987b56eb3543cac1e70227265e5eb95bb5e17d1d85193d`. Nineteen atomic commits, 57 owned paths. Final3 global validation passed on this exact tree, normal commits preserved it, and only fix/macos was pushed.

## Changes and regression evidence

Commit counts describe delivery history, not independent runtime-bug counts. Of the 34 atomic commits, 15 have `test` subjects, one has a `style` subject, and 18 have `fix` subjects. The `fix` group includes three test-infrastructure repairs (20, 24 and 25). Product corrections can also be successive repairs of one contract, such as the native receipt publisher in 22 and 30. Thus this report does **not** claim 34 distinct runtime bugs. The eleven normal development merges and historical eight-commit appendix are outside that count; the reverted `efa02` portability hypothesis is not an active fix.

### 1. test(macos): await actual pac worker ownership transitions

Commit: `b1ee6bf4740e8b9b5b47cc8ff3922006311b3911`.

A request thread can enter its real start operation before the
acknowledgement is published. Closing its listener or dropping ownership
then leaks or races the worker. Preserve the actual start outcome and
retire the socket only after ownership is known.

The same two regression methods fail against the exact previous PAC
fixture. Normal and optimized Python suites pass 16 cases each; the
portable receiving contract passes 68 controls.

Only the macOS PAC test peer and its receiving tests use this lifecycle;
no Windows or Linux product driver changes.

Evidence receipt: `/workspace/scratch/oct28-pac/ready.json`.

### 2. fix(macos): retain worker completion after file-limit signals

Commit: `cad35740f2cfd1edfb43779bf81954fee384cc53`.

The supervisor ignores SIGXFSZ, so its child inherits SIG_IGN across
exec and can survive a file-size refusal. Install a caught no-op handler
in the supervisor instead: exec restores the child default while the
parent still survives diagnostic write failures and publishes
completion.

The same registered suite passes 8/10 before and 10/10 after. Real Bash
and zsh signal matrices cover caught, ignored, and uncaught outcomes;
duplicate-case mutations fail.

The supervised shell worker belongs to macOS App Cloner. Linux and
Windows product drivers do not run it.

Evidence receipt: `/workspace/scratch/oct28-worker/ready.json`.

### 3. fix(macos): stage release swaps on the destination filesystem

Commit: `43b421fc9cd24d6229bdaef2216be557f6cdd5a4`.

A staging directory on another filesystem makes mv copy an app
partially. Rollback can then nest the only original app inside that
partial candidate and falsely reopen it. Place staging beside the
destination and validate the admitted filesystem before arming.

Current-dev physical fixtures reproduce partial-copy publication and
rollback loss. Ten physical cases and the installer, receipt, and arming
regressions pass with the fix.

This selected-release updater is macOS-only. Other operating systems use
separate installers.

Evidence receipt: `/workspace/scratch/oct28-updater/ready.json`.

### 4. fix(macos): publish release swaps with exclusive renames

Commit: `e18b28e6a5558878abf47fd07c7cc0876b31c989`.

A destination race can nest the candidate or backup during mv.
Concurrent armed workers can also retire the sole backup. Use native
exclusive rename operations and retain an inherited lock lease before
publishing ARMED.

Physical destination collisions and two-worker schedules reproduce the
old failures. The receiving installer and receipt cases cover exclusive
refusal, rollback, and lease lifetime; native Swift qualification
is recorded in the later source-bound CI results.

The native rename worker and selected-release launcher are macOS-only.
No other OS installer is changed.

Evidence receipt: `/workspace/scratch/oct28-updater/ready.json`.

### 5. fix(macos): retire only owned app cloner reservations

Commit: `278a367cc383ec2a080c56faeeb323914d33625c`.

Shortcut generation can leave a partial reserved app after allocation or
writing fails. Share the existing clone lifecycle with both generators
and verify native device/inode ownership before rollback, while
preserving completed and foreign bundles.

Real allocation, write, identity, replacement, symlink, and final-
receipt failures exercise cleanup. The registered stage passes 33/33,
including the full shortcut generator.

App Cloner is a macOS standalone product. The portable test stat adapter
does not change Linux or Windows products.

Evidence receipt: `/workspace/scratch/oct28-cloner/ready.json`.

### 6. fix(macos): preserve mkdir errno during bundle reservation

Commit: `5b02d9932d741f3c8106c2b2141bae24bf9d1f54`.

Checking whether a path still exists after failed mkdir loses the actual
EEXIST result when its owner retires concurrently. Branch on the kernel
errno from that mkdir, preserving umask and exact path bytes.

A controlled real mkdir barrier reproduces owner retirement after
EEXIST. Missing-parent and permission refusals stay fatal; the
registered stage passes 36/36.

Only the macOS App Cloner reservation helper changes. Portable POSIX
tests exercise the same kernel boundary without changing other products.

Evidence receipt: `/workspace/scratch/oct28-cloner/ready.json`.

### 7. test(macos): preserve posix path bytes in cloner probes

Commit: `20c2e8ffcb81a4e2d4bc380b59726f2cb5058b64`.

The test transport converts literal POSIX backslashes into directory
separators before invoking Bash. A valid physical fixture is redirected
to a different path and the generated-launcher checks cannot exercise
that checkout.

The real Bash byte roundtrip regression fails before the helper fix. The
registered stage advances from 36/37 to 37/37 while preserving Windows
Git-Bash drive mapping.

This is the macOS App Cloner test transport. Windows path conversion
remains platform-specific; POSIX names retain their bytes. No Linux
product driver is changed; Linux serves only as the portable test host.

Evidence receipt: `/workspace/scratch/oct28-cloner/ready.json`.

### 8. fix(macos): route accepted scheme uris through native open

Commit: `a2b3dd323902b0d849e33472a723bdea4d519442`.

The launcher only recognizes double-slash URLs, so accepted single-slash
Teams links and opaque RFC scheme URIs are incorrectly forwarded as
positional file arguments. Recognize the scheme grammar used by the UI
and preserve file inputs.

Actual launcher bodies run every URI/file vector across native,
Electron, and VS Code families. Single-slash Teams and opaque scheme
cases reproduce the old mismatch; the stage passes 40/40.

Only generated macOS App Cloner launchers use native open. Other OS
product launchers are unaffected.

Use neutral /fixture path data in both URI producer and oracle so the
developer-path guard stays meaningful. All 36 routing cases pass under
actual Bash and zsh, and the unchanged developer-path guard passes.

Evidence receipt: `/workspace/scratch/oct28-cloner/ready.json`.

### 9. fix(macos): finish cloner cleanup after diagnostic failures

Commit: `ed4fa805eddef224b6cb8eb3d9239ad1543786dd`.

A finite log limit or closed diagnostic reader can interrupt EXIT
cleanup and leave the reserved bundle or workspace behind. Isolate log
signal handling, preserve the primary status, and finish all owned
cleanup; print result paths without echo escape interpretation.

Real file-size limits, closed pipes, foreign replacements, cleanup
refusals, and literal backslash result paths exercise the shipped CLI
scopes. The same registered suite passes 43/45 before and 45/45 after.

These shell generators belong only to macOS App Cloner. Portable Bash
and zsh probes qualify kernel behavior, not a Linux product change.

Evidence receipt: `/workspace/scratch/oct28-cloner/ready.json`.

### 10. test(macos): discover native runner paths without shell records

Commit: `75137defe3ae2fe22c45df578a89204f39bb2f68`.

The macOS unit runner normalizes POSIX filename bytes and shell line
reads truncate newline paths. Shell source enumeration can also hide a
forbidden hotpath emission. Resolve the actual native entrypoint and
share complete fail-closed native discovery.

Actual old macOS backslash startup fails. Twelve unique
driver/provider/prefix cases now run; the newline emission negative
control fails closed, five discovery faults remain covered, and a
duplicate-mode mutant is rejected.

macOS uses the shared test walker; shared fallback behavior is covered.
Linux retains its existing native directory injection and production
sources are unchanged. Windows formatting stays conditional.

Migrate the bounded CLI fixture to the canonical Discovery.collect
interface and load actual luv for native bootstrap. The same unchanged
17 CLI cases go from 0/17 to 17/17: ten invalid inputs retain status 2
before discovery and seven valid inputs retain real summaries and
process exits.

Evidence receipt: `/workspace/scratch/oct28-runner/ready.json`.

### 11. test(macos): resolve temporary roots with native path rules

Commit: `186c216dcb7ee295880709a2ac01af27779b1e2c`.

Treating every backslash as a separator corrupts valid POSIX TMPDIR
values, while unconditional drive syntax admits a relative C:/ path.
Reuse the native path owner and apply Windows display conversion only on
Windows.

The exact final unit cases pass 2/4 before and 4/4 after. Real child
TMPDIR environments cover quote, backslash, and newline roots, allocate
within the exact root, and independently verify owned retirement before
fallback cleanup.

The changed helper is macOS test infrastructure. Canonical shared path
semantics are reused unchanged; Windows drive and UNC behavior is
retained.

Update the two historical temporary-root fixture expectations to native
platform rules. Old POSIX fixtures pass 4/6 and corrected fixtures pass
6/6 under both interpreters; the Windows path model remains 6/6. Real
four-unit and three-child allocation regressions remain intact.

Evidence receipt: `/workspace/scratch/oct28-runner/temp-followup/ready.json`.

### 12. fix(macos): give each app cloner bundle an independent identity

Commit: `d8383cadd6c91f971f6d060e6cf90d9afe2bb86c`.

Same-second creations publish identical bundle identifiers despite
separate reservations and clone profiles. Allocate one native UUID and
reuse it for metadata and launcher consumers. Validate its exact receipt
and status before allocating any app or workspace.

The exact registered suite fails at 45/48 with previous runtime bytes
and passes 48/48 after. Real shortcut metadata exposes duplicate
identifiers; producer refusal and malformed receipt controls verify
allocation never starts.

App Cloner is a macOS-only standalone product. Its portable UUID
boundary retains Windows Git-Bash handling without changing other OS
products.

Evidence receipt: `/workspace/scratch/oct28-cloner/uuid-atom/round3/ready.json`.

### 13. test(macos): enumerate production sources with native paths

Commit: `c564982271baf69a24bfb70cb02206f471323f00`.

Shell quoting, newline records, and absolute tests-directory exclusions
can execute path text or omit production sources. Reuse complete native
discovery and apply exclusions to relative paths while retaining source
expansion and positive caching.

The same 11 physical cases pass 5/11 before and 11/11 after; the related
cohort passes 33/33. Old controlled command substitution creates its
owned marker; the native path does not. A no-cache mutant fails the real
enumeration counter.

Only macOS source-reader tests and fixtures change. The canonical shared
walker is reused; legitimate native symlink semantics are explicit and
no product driver behavior changes.

Load native discovery only when the source inventory is requested.
Unchanged Python diagnostic suites can again load basic helpers without
the native provider; all four suites are red before and green after.
Real source cohorts and native discovery regressions remain green.

Evidence receipt: `/workspace/scratch/oct28-source-census-proof/ready.json`.

### 14. test(macos): preserve complete runtime source inventories

Commit: `2e60bb085e30ed120417eddacf0d9d7156d51272`.

Shell records and full-path exclusions hide forbidden runtime source
bodies beneath valid native paths. Use the canonical walker, exclude
owned test links before following targets, and classify unknown
directory entries with actual nonfollowing metadata.

The same physical regression passes 4/11 before and 11/11 after. Keeping
the previous walker with the new client still fails three controls; the
complete related cohort passes 70/70 with all read faults and retries
retained.

Only macOS runtime inventory tests and the shared test walker guard
change. Shared behavior retains regular files named tests and is covered
by the driver path matrix; no product payload changes.

Evidence receipt: `/workspace/scratch/oct28-runtime-source-followup/ready.json`.

### 15. test(macos): preserve native e2e bootstrap paths

Commit: `8283da9025a16d5d7944499d967e19425bb0289d`.

The E2E entrypoint converts literal POSIX backslashes to separators and
reads cwd through a line-oriented shell command. Valid physical checkout
names then prevent real helpers and the shared corpus from loading.
Resolve the actual native source filename directly.

The exact final bootstrap probe succeeds for the old ordinary root and
fails for old backslash and newline roots. Six unique real-
prefix/provider cases now load the real helpers, synthetic stack, JSON
decoder, and nonempty corpus. All scenario bodies remain byte-identical.

Only the macOS E2E bootstrap and its registered portable regression
change. Linux already uses its native runner-root owner. The six probes
cover bootstrap only; the complete 185-scenario suite runs once for the
final batch.

Evidence receipt: `/workspace/scratch/oct28-runner/e2e-followup/ready.json`.

### 16. test(macos): follow pending layout activation ownership

Commit: `9e1740002c44743681fedfff34b621202964e14b`.

The static layout ownership oracle still requires the obsolete callback
shape from before pending activation. Recognize the current finite
native owner without weakening action-handler or category coverage.

Both unchanged current upstream ownership gates fail before and pass
after. Each retains its existing negative controls and adds five focused
negative controls. No native TIS execution is claimed.

Only static macOS layout menu ownership checks change. Windows and Linux
runtime owners are untouched.

Evidence receipt: `/workspace/scratch/oct28-menu-layout-oracle/ready.json`.

### 17. test(macos): find the enabled-list editor by its declaration

Commit: `490b1705c87a73b34126eaa021996a96989fd566`.

The upstream enabled-list regression opens a hardcoded driver filename,
so moving the implementation breaks a source-path check before it can
inspect the editor. Select exactly one production unit by its
declaration and retain every script assertion.

The exact unchanged ratchet reports 28 files and 76 reads on both dev
and the assembled tree. The correction restores 27 files and 75 reads
without raising either baseline; the real focused module passes 22/22.

Only a macOS source-inspection test changes. Windows and Linux product
drivers do not use that editor-source oracle. No input-source product
behavior, OS defaults, or shared gate semantics change.

Evidence receipt: `/workspace/scratch/oct28-runner/pinned-ratchet-proof/ready.json`.

### 18. test(macos): match the two-child input-source editor

Commit: `2c001889c2901703eba39deafa14b739fa6f1da3`.

The enabled-list writer now performs defaults export and import without
restarting an agent. Its supervisor test still expects a third child and
therefore rejects the correct two-child program. Assert the actual two
new sessions and decreasing deadlines.

The same ten registrations pass 8/10 before and 10/10 after. Timeout
process-group kill, exact-child waiting, publication-window SIGTERM, and
all five production mutants remain covered.

Only the oracle for the embedded macOS Python supervisor changes. No
Windows or Linux equivalent process or production source changes.

Evidence receipt: `/workspace/scratch/oct28-input-source-supervisor-oracle/ready.json`.

### 19. test(linux): reload the configuration guard for its logger

Commit: `4c6c8a8f03fe284a0dbe5a869366630eed18c03b`.

The fixture observes the current logger while a retained configuration
guard can still hold the previous logger captured during require. Load
the binding through the existing module-isolation helper before
observing its diagnostic.

Both real tests pass in a clean process. A deterministic stale-logger
schedule fails before and passes after; removing only the Linux refusal
diagnostic still fails the existing assertion.

Root explicitly authorized this one-line Linux fixture repair during
shared qualification. No Linux product behavior changes. macOS and
Windows tests do not have this swapped Lua logger observation.

Evidence receipt: `/workspace/scratch/oct28-linux-guard-proof/ready.json`.

## Ten follow-up commits after the failed nineteen-commit CI

These are the exact first-parent, non-merge Root commits from `4c6c8a8f03fe284a0dbe5a869366630eed18c03b` through `439fabefb500d29e142e7773bf13922780c02fee`, in integration order. The worktree-local author SHAs in component receipts can differ after normal cherry-picks; the SHAs listed here are the actual integration commits.

### 20. b33bfcb700f7731d8c38dd7f89cba718f455ca12 — fix(macos): bootstrap standalone e2e without native lua modules

**Bug/proof:** actual CI job `122804469951` installed Lua 5.4 and LuaFileSystem, then aborted on `require("luv")` at `run_e2e.lua:37` before all scenarios. The same final registered regression is red with the actual old bootstrap. **Cause/fix:** the standalone entrypoint had acquired an undeclared native dependency. Use the existing pure-Lua quoting owner, resolve its physical directory through an owned read-only POSIX pipe, read all raw bytes, close exactly once before raising read errors, require actual command success, and strip only the single protocol LF. The scenario tail is unchanged.

**Regression:** 18 actual bootstrap invocations (6 retained plus 12 SDK-free), 12 retained native unit-runner path cases, and six process-I/O refusal controls. Full 185/185 replay succeeds with actual Lua 5.4, real lfs and unavailable luv; one pre-existing driver/host NA remains reported. Raw backslash, newline, quoting/substitution text, trailing LF, stale PWD, hostile CDPATH and directory symlinks are covered. Out-of-tree entry-file symlinks are outside the declared invocation contract. Windows resolver code is unchanged; this entrypoint belongs only to the macOS driver. Linux is the actual portable execution host, not a claim of native Darwin execution.

Evidence: `/workspace/scratch/oct28-e2e-sdk-fix/ready.json`; independent peer `/workspace/scratch/oct28-l66-peer/bootstrap-review.json`, SHA256 `12f0547e432891c9c11d8559875e3f4bf8effca6800ff7e473a4f2b3a0975835`.

### 21. 56bdf43a94856a00db83aa6e71424530d0a2e352 — test(macos): align native uri cases with neutral fixture paths

**Bug/proof:** actual Mac26 Swift receiver expected `/Users/fixture/project` and `/Users/fixture/report:2026.txt`, while the real routing producer emitted the current neutral `/fixture/...` inputs. Six actual zsh mismatches across three app families reproduced the CI failure. **Cause/fix:** receiver expectations drifted from producer fixtures; correct only the two expected paths.

**Regression:** all 36 routing vectors and exact argument/UI admission traces remain, 36 actual zsh inputs match and the registered portable suite passes 48/48. This is the macOS App Cloner native receiver; Windows/Linux do not host its Swift/zsh app dispatch. No product routing change. The later source-bound Mac26 CI records native confirmation; this component receipt alone does not establish Darwin behavior.

Evidence: `/workspace/scratch/oct28-native-cloner-repair/uri/ready.json`.

### 22. b7c66b31e8033420669abbbd975d42b45296d8c6 — fix(macos): report failed app cloner receipt writes

**Bug/proof:** actual zsh builtin printf returned false status zero on a closed descriptor; a reader-closed pipe instead killed the parent with SIGPIPE and left its completed bundle's workspace behind. The old 22-case physical probe has four real zsh failures; restoring only the builtin writer reproduces all four. **Cause/fix:** the parent shell cannot reliably observe its own builtin writer failure. Use `/usr/bin/printf` for the two final receipts, so child failure is returned to the shell and owned EXIT cleanup can execute while preserving the completed bundle. Existing AppleScript independently rejects an empty result; the proved bug is the CLI status/cleanup, not a falsely accepted UI result.

**Regression:** both success tails face real closed descriptors and reader-closed pipes, all 22 physical cases pass under Bash and zsh, and the registered suite passes 49/49. Scope is the two macOS App Cloner scripts; other OS drivers have neither these resource owners nor the AppleScript caller. Later Darwin CI shows the reader-closed pipe cases passing but disproves the closed-descriptor assumption; commit 30 below completes that publication fix.

Evidence: `/workspace/scratch/oct28-native-cloner-repair/receipt/ready.json`; `receipt-old22-r2.json`, `receipt-new-zsh.json`, `receipt-builtin-mutant-zsh.json` in the parent evidence directory. The deliberately reproduced old leak was separately retired; no unknown leak is inferred from the original CI log-limit failure.

### 23. 62f2c76b8e034f1e6fbd6596029c299e8b870d6a — test(macos): arm log-write limits after resource admission

**Bug/proof:** Darwin CI admitted 609 log bytes under a nominal 422-byte aggregate quota and returned status 1 rather than the test's expected 153. Its append file-size admission checks a fresh descriptor's offset before O_APPEND positioning, so the old injection did not guarantee a refusal. **Cause/fix:** the test confused an aggregate EOF budget with the actual failing write boundary. Arm a real zero file-size limit at the existing post-reservation log boundary. Keep the earlier tee free to publish diagnostics and compare exact actual bytes with the captured prefix through independent Node and Swift reads.

**Regression:** 22 physical cases pass under real zsh, six limited clone cases actually return 153, and the registered Bash suite passes 49/49. Omitting only the fault admission fails all six targeted cases. A forged producer receipt and missing quota metadata are independently rejected. All status, ownership, foreign bundle, symlink and closed-reader assertions remain. Three test-only files change; only macOS uses this native fixture. The later source-bound native CI records actual execution. Public XNU source explains the trace but is not asserted to identify the exact hosted kernel binary.

Evidence: `/workspace/scratch/oct28-native-cloner-repair/quota/ready.json`; peer `quota/peer-review.json`.

### 24. 329bdda8a1b54790a63cdda2c1776f1dcb061dbc — fix(macos): create writable blank release fixture images

**Bug/proof:** actual CI failed at `NativeReleaseSwapFilesystemTests.swift:212`: `hdiutil: create: -format requires -srcfolder or -srcdevice`. The fixture never mounted the owned volume and therefore never reached its publication assertions. **Cause/fix:** a source-backed creation option was passed for a blank image. Remove `-format UDRW` and retain blank-image writable UDIF creation, 64 MiB HFS+, all mount identity/read-only/publication/retirement checks and both existing test registrations.

**Regression:** the existing native receiver is retained unchanged after the creation correction. Later Mac26 CI passes both filesystem methods; local Linux component checks alone cannot qualify hdiutil/HFS. This is macOS-only native packaging/install infrastructure; neither other OS creates this image. No extra test is substituted for the existing failing receiver.

Evidence: `/workspace/scratch/oct28-ci-final19/native26-evidence.json`; `/workspace/scratch/oct28-native-fixture-repair/ready.json`; peer `/workspace/scratch/oct28-native-peer/review.json`.

### 25. cd9465a7f9c99666d51f59eab9896f01527f93af — fix(macos): qualify native release scripts without undeclared lua

**Bug/proof:** the other native release receiver aborted before all four races: `release_arming_fixture.py:58`, `RuntimeError: Lua 5.4 is required for the native arming control`. The Swift job had no admitted interpreter at that point. **Cause/fix:** native script testing implicitly depended on Lua installation from a later stage. Add an explicitly selected fail-closed source-parser mode to that receiver. Preserve actual Lua as the mandatory default and label the native mode honestly `script-only/source-parser`. Bind source, SWAP/DETACH programs and both complete raw and ported argv vectors in Swift.

**Regression:** common updater tests compare three complete raw argv vectors and both scripts with actual Lua arm_swap emission, reject ten malformed detach authorities, execute all four physical races with missing Lua in explicit mode, and require default mode to fail under the same missing-Lua environment. Four business mutants (three unsafe mv phases and removed lease) fail. Independent peer reran the three-vector/ten-refusal control with actual Lua 5.4.8 and raw LF scratch paths, exit 0. This changes macOS native fixtures and their portable receiving tests only; Windows has no Darwin worker. The strict-source native test does not claim to execute arm_swap Lua, and local script ports do not establish native HFS/MachO behavior.

Evidence: `/workspace/scratch/oct28-native-fixture-repair/{ready.json,semantic-controls.json,emission-controls.json}`; peer `/workspace/scratch/oct28-native-peer/review.json`, SHA256 `42f224003f018db7acd0c7673b5786cb6b7d4d2217cfbf4c950557ab0894ae1f`.

### 26. c1d281680533fdfd7df2148b7eaaed03348136e7 — test(macos): follow fresh-process layout confirmation callbacks

**Bug/proof:** both complete menu gates rejected the correct dev callback after fresh-process TIS confirmation replaced the old synchronous getter. **Cause/fix:** the finite ownership oracle still recognized a retired callback body. Follow fresh confirmation, unread responses, consent, enabled/pending and failure branches without changing production or raising coverage baselines. The later dev merge preserves its bounded waiting confirmation and negative controls.

**Regression:** both old gates exit 1 and both repaired full gates exit 0; 246 menus, no missing declared IDs, and no unresolved owned actions. Eight independent actual callback mutations are rejected. This common CJS oracle inspects a macOS-only menu callback; other OS runtime behavior is unchanged. Structural callback checks are not native TIS execution.

Evidence: `/workspace/scratch/oct28-fresh-tis-menu-oracle/ready.json`, with source, full-gate and eight-control bindings. The earlier `/workspace/scratch/oct28-menu-layout-oracle/ready.json` belongs to the original batch and is not this newer fresh-TIS repair.

### 27. 5e11e36cea21ae791ee89c1d7a0c3f5c765c7b8a — fix(macos): fence ledger replay until publication commits

**Bug/proof:** real public init/ingest/stop and actual SQLite on the imported bounded-replay implementation reproduced premature ingestion after read, SQL or scheduler refusal; durable state still advertised pending replay, and durability restoration or metadata publication could fail without keeping the fence. **Cause/fix:** in-memory replay ownership was released before successful FULL restoration and atomic publication of cursor, event ID, date/context and pending-row removal. Retain the durable pending row, exact timer/database cleanup debt, and stale callback fencing until all required acknowledgements complete; restart retries the same authoritative state.

**Regression:** the final seven physical methods against the exact old manager yield three passing healthy methods and ten failing fault subcases; the repaired manager passes. Seven registered cases and seven real SQLite methods cover ten refusal boundaries, plus five semantic production mutants (all exit 1), existing rollover 24/24 and quit-meta 3/3. Component HS 25306 across 2032 modules and E2E185/185 are historical component results, not final combined totals. The rollover busy oracle now requires the actual durable journal so the new startup transaction cannot consume the wrong injected fault. macOS alone owns this SQLite cache replay; Windows uses a ledger without this replay owner and Linux has its separate persistence owner. Analogous unrelated Linux fault coverage is not claimed.

Evidence: `/workspace/scratch/oct28-keystats-startup-implementation/safety-ready-final.json`, `safety-final-old-source/ready.json`, `safety-final-peer-review.json`. Two unchanged component JS failures were explicitly retained then repaired by commits 28 and 29 below; this receipt was never a claim of combined green.

### 28. 87f277a98f13b3839074cf5e5b80e61da20649a6 — fix(macos): configure fresh input-source settle delays

**Bug/proof:** two literal 300 ms sleeps in the fresh CoreServices child ignored the shared timing registry. The same final Lua test against the old module receives nil instead of configured argv value 0.137; the old Python consumer fails all nine new delay controls. **Cause/fix:** duplicate embedded defaults were not connected to the single timing authority. Add one named 300 ms registry value, pass it explicitly to the child, and reject missing/invalid values; retain the independent ten-second watchdog. Preserve dev's current refresh/enable flags and retry behavior.

**Regression:** six focused modules pass 45 cases; Python consumer passes 19/19 (old 10/19); old final Lua case fails exactly its new argument check; unchanged timer-inventory gate red before and green after without a baseline change. Actual preamble and both sleep AST expressions execute in the controls; Carbon native execution is not claimed. The helper is CoreServices/macOS-only; Windows/Linux never execute it. The shared timing declaration supports that one owner and changes no other OS behavior.

Evidence: `/workspace/scratch/oct28-input-source-contracts/ready.json`, `input-unit-results.json`, `dev184-overlay-pins.json` and peer records.

### 29. 439fabefb500d29e142e7773bf13922780c02fee — style(macos): describe layout behavior without plan labels

**Bug/proof:** unchanged repository source gate rejected stale planning/probe identifiers in three layout comments; old source gate exits 1 with three findings. **Cause/fix:** source comments coupled behavior to transient planning labels. Replace those labels with behavioral descriptions, including dev's current retry comment. This is a gate/convention repair, not a newly claimed runtime bug.

**Regression:** the same unchanged gate exits 0; no baseline increase. Independent token proof confirms identical executable Lua tokens, including strings, across all three files. Only macOS source comments/test comments change; other OS execution is unaffected.

Evidence: `/workspace/scratch/oct28-input-source-contracts/ready.json`, `comment-token-proof.json` (executable token identity), and old/new plan-reference logs.

## Thirtieth atomic follow-up — native checked receipt publisher

### 30. a34bc3f01be4072053db8fd03d4788504fe6f214 — fix(macos): check native bundle receipt delivery

**Bug/proof:** the actual Darwin run `40714812019` disproves the previous portability assumption: both `clone:result-closed-fd` and `shortcut:result-closed-fd` still return zero despite failed result delivery. Completed destinations survive and workspaces retire; those traces prove false success, not a new leak. The earlier successful GNU-host `/usr/bin/printf` checks did not establish BSD behavior. Independent public Apple BSD printf source shows unchecked stdio writes can leave a zero formatting return value; native cat checks descriptor/write failures and final stdout closure. Public-main source snapshots explain the observations without claiming binary identity with the hosted runner.

**Cause/fix:** changing a zsh builtin to native printf still relied on an unchecked native publication contract. Put one checked `/bin/cat` heredoc publisher in the existing `reserve_bundle.sh` owner, preserving the raw path and exactly one newline. Both real callers and the synthetic Swift ownership subject explicitly propagate helper failure with `|| exit $?`, required because real zsh function errexit can otherwise bypass the caller's global EXIT cleanup. No optional writer/fallback, copied second helper, workflow edits or weakened receiver assertions are introduced.

**Regression:** the same **22** actual zsh business cases now pass, including the original two closed-fd cases; the real current Swift ownership shell subject returns nonzero and retires its workspace. The registered Bash suite passes **51/51**. Seven independent raw-byte cases cover path publication. Masking actual cat failures in a private copy makes the registered suite fail **4/51**; removing explicit caller propagation fails **four** unchanged real zsh cases. Eight targeted gates and ordinary commit hooks exit 0. The helper belongs solely to macOS App Cloner; Windows/Linux products do not ship this publisher. Linux-host portable command results remain distinct from native Darwin qualification, which subsequently passes in runs `40727519951` and `40739753554` for their respective exact source heads.

Evidence: `/workspace/scratch/oct28-receipt-writer/ready.json`, SHA256 `448799c70a4745856f310ffda6567e9d9545d2ae9de38eade44b284f05c63325`; independent peer `/workspace/scratch/oct28-receipt-writer/peer-review.json`, SHA256 `a9d05747bd0fa641a5248e93e0106bc394f0df657940067d2cf8ccf733ef1e02`; BSD source evidence `/workspace/scratch/oct28-bsd-result-writer-peer/bsd-evidence.json`, SHA256 `16a72a7c34cd04777114d6ab31954a27cb4813f17e4585afa87adf7cc83d5512`. Exact patch SHA256 `a6b7d709d0f87832f92b70b4e8f236e791f192b10acb99ec8ea28288a6160567`.

**Historical component checkpoint:** the full three-producer batch on tree `a5f0f58a19666301cbeec55f0d11fae3b561f836` subsequently completed successfully; its exact totals and receipt are listed in the opening status. Its portable results did not erase the earlier merge7 failure or qualify a different source tree. GitHub annotations later attributed the unexecuted merge7 Tooltip cancellation to hosted-runner capacity, as documented below. The reverted legacy `efa02` claim and native/field limits remain explicit.

## Two normal development merges in this follow-up

- `22894401427cecdf9669ab7cf9e8a92ebc29ef96` — `chore(macos): merge current layout and replay fixes from dev`; first parent `4c6c8a8f03fe284a0dbe5a869366630eed18c03b`, dev parent `88e350f9343ec34c180196fe2c56598ff15b524f`.
- `47fb581644719ce4904d38661f625815a39c773c` — `chore(macos): merge the latest afternoon release fixes from dev`; first parent `5e11e36cea21ae791ee89c1d7a0c3f5c765c7b8a`, dev parent `184d7b5f9a7fb458d666ed69de3ca61dd40d14dd`.

Both preserve published history through ordinary merges, with dev behavior retained in conflicts. Imported upstream changes include fresh-process layout enable/refresh/retry, shortcut rebind/refusal isolation, bounded/reboot-stable metrics replay/cache, model browser work and dependency fixes. These are upstream work, not ten additional Root fixes. Protected areas appearing in the full patch against 4c originate from these dev merges; the owned-vs-dev manifest lists **zero owned protected paths**. Current integration binding: `/workspace/scratch/oct28-followup-assembly/assembly.json`, full patch SHA256 `4b0215e8ef088cfdd906df08b7b82b362e2ce1a36f10a9687c1fe3401918ac67`.

## Historical seventh development merge and qualification restart

After the ten follow-up commits, the full combined local batch on the earlier `439fabefb500` snapshot produced actual results:

- macOS: **25367 passed, 0 failed across 2038 modules**, then **E2E185/185**, actual producer exit 0.
- Linux: **19807 passed, 0 failed across 804 modules**, then **E2E302/302**, actual producer exit 0.
- Common: **528/529 JS passed**, actual producer exit **1**. The sole failure was entry **477**, the inline sorted-key duplicate authority already present in dev184. This failed full batch is preserved as a genuine red; it is not replaced with a claimed green or attributed to an unexecuted gate.

The pre-push fetch found newer dev `5ee230e8aa062f0a9f61827b126808029be17f8e`. It already fixes that duplicate authority in upstream `d6a08b1` and adopts the timing, comment and menu-oracle work in upstream `9e36`, `fe346` and `37ce` respectively. It also carries SvelteKit 3 and discovery/catalogue work. Root imports these through a seventh overall ordinary development merge, `ffa0231b7675a307c070b39c30c014f6b389af10`, preserving dev behavior in four conflicts; normal merge hooks exit 0. Imported upstream changes are not counted as additional authored fixes and protected upstream areas are not edited by owned patches.

The bounded timing reconciliation keeps dev's canonical **`ui.input_source_reselect_settle_ms` = 300 ms**, **`SETTLE_SEC`**, enable/refresh flags and retry behavior. It removes the now-dead earlier owned timing key. It retains explicit argument-count and finite positive delay validation before native framework loading; no fallback or module-time captured constant is restored. The regression follows dev's **dynamic call-time lookup**: two invocations receive distinct 0.137/0.291 values, one read per child. An assertion that the timing is read only once for all future children would be wrong for the current implementation and is not claimed. Six focused modules now pass **47** cases; the Python consumer passes **19/19**, whereas its pre-reconciliation check fails on the missing explicit argv guard. Timer inventory, timing liveness and generation checks exit 0. These are component checks, not the final combined verdict.

Exact reconciliation receipt: `/workspace/scratch/oct28-merge7-timing-reconcile/ready.json`; patch SHA256 `66bfeb6046452deceb5bf413a9dc1887a09a42cb8fc53a798319bb721deb5aa3`. The current full source patch against original `4c6c8a8f03fe284a0dbe5a869366630eed18c03b` has SHA256 `d76c0595ea32d10332a7c03e2ae344dc3d608dc4514e13725d875ad7bb8dca98` and current tree `95a2c89537910042009ec2a4ce5e84b7b042dd93`.

The fresh complete Common/macOS/Linux batch **finished successfully**, source-bound by `/workspace/scratch/oct28-merge7-assembly/qualification.json` at **16:19:31 Paris**: Common JS **529/529**, macOS **25373 passed/0 failed across 2038 modules** and **E2E185/185**, Linux **19809 passed/0 failed across 804 modules** and **E2E302/302**. All three actual producer exits are 0. The residual observer reports qualified=true, exact source bindings=true, zero matched live processes and no unreadable same-UID process; its stated provenance scope does not certify children that sanitized all provenance. This is the final merge7 local qualification, distinct from the preserved earlier 528/529 red.

Normal push of fix/macos and workflow_dispatch both succeeded. The fresh CI is documented below; its native failures mean the complete task is still open.

## Qualification

Initial complete merge-only run: [40658634706](https://github.com/adrienm7/ergopti/actions/runs/40658634706), success, head `74f683f5a6`. Started 09:41:42 and completed 10:26:51 Paris. This qualifies the first merge only, not the current candidate. Its macOS 26 default native XCTest profile passed 659 cases; selected Intel native cohorts passed 172.

Final2 local batch: full JS 519/529, Linux 19806 pass/1 failure across 804 modules, macOS meta 19 failed fixture cases. Every original exit and log is retained. Three upstream failures were corrected in dev and imported through the fourth normal merge: Ollama catalogue host ownership, Linux selector log vocabulary, and the shared sorted-key owner. The other failures have targeted old-red/new-green evidence and candidate fixes; no test, gate, or baseline was disabled or relaxed.

Final3 local batch: JS 529/529 and all common gates passed; macOS 25322/25322 across 2033 unique modules and E2E185/185; Linux19807/19807 across 804 modules and E2E302/302. All three actual producer exits 0, source bindings intact, residual observer qualified on exact private provenance.

Original nineteen-commit CI: [40684207718](https://github.com/adrienm7/ergopti/actions/runs/40684207718), attempt 1, head `4c6c8a8f03fe284a0dbe5a869366630eed18c03b`, **FAILURE**, 28 October **12:59:35–13:23:40 Paris**. Full graph: **47 jobs = 38 success, 4 failure, 5 skipped**. Two direct failing jobs: standalone E2E aborted at `run_e2e.lua:37`, missing `luv`, before any scenario; default full macOS 26 Swift target executed **674 cases = 669 passed + 5 failed + 0 skipped**, with 25 failed assertions (2 unexpected). The five failed methods were three App Cloner ownership/log/URI methods and two release filesystem methods. The profile was inactive. Intel selected native cohorts independently passed **172 cases, 0 failed, 0 skipped**; that is not the full Mac26 target. Common completed successfully. The macOS and release verdict jobs failed by dependency; macOS Build/Install were skipped, Windows/Linux were unselected, and Publish was skipped. No test was cancelled or retried. Receipt: `/workspace/scratch/oct28-ci-final19/final-receipt.json`, SHA256 `eb42d379c0940559c4cc3eacd758e4e3ed60ba26d48860ca033f1b1864c12d91`.

The ten follow-up commits above repair these CI failures and additional reproduced replay/timing/gate faults. Their component proofs do not establish final combined qualification. The subsequent dispatched runs and actual conclusions are recorded above and below with their exact source scopes.

## Historical merge7 CI — failed before the checked receipt correction

[Run **40714812019**](https://github.com/adrienm7/ergopti/actions/runs/40714812019), attempt **1**, head `ffa0231b7675a307c070b39c30c014f6b389af10`, macos selection, **FAILURE**. Started **28 October 16:19:43 Paris**, completed **16:56:48 Paris**. Full actual graph: **47 jobs = 38 success + 3 failure + 1 cancelled + 5 skipped**.

- **One direct failing job:** Mac26 default complete Swift target executed **674 cases = 672 passed + 2 failed + 0 skipped**, five failed assertions, zero unexpected. Both failing methods are `NativeAppClonerBundleOwnershipTests`: `testActualNativeCliLogLimitsRetireOwnedResourcesAndPreserveRawPaths` and `testActualNativeOwnershipPreservesCompletedAndForeignBundles`. The first's exact physical probe list contains only `clone:result-closed-fd` and `shortcut:result-closed-fd`: each still returns status 0 on a closed result descriptor. Each preserves its completed destination and retires its workspace, `ownership_closed=true`; no resource leak is inferred. Reader-closed pipe cases now return 141, all six admitted clone quota cases return 153, and their retirement checks succeed. The second method fails its expected nonzero status assertion at Swift line 156. These native results required the later proved correction in commit 30; the earlier portable receipt-writer result alone did not establish the Darwin contract.
- **Critical actual native passes:** the URI method now passes; both repaired HFS/release filesystem methods pass; all **six ReleaseRenameWorker** methods pass; the owned worker completion method passes. These are real Darwin XCTest receipts, not Linux script-port evidence. Strict-source release observation remains honestly script-only; that native receiver is not represented as actual arm_swap Lua execution.
- **Standalone E2E repaired:** job `122912832295` succeeds at **16:28:24 Paris**, full **185/185**, profile inactive, one historical rolling_buffer_cap driver-specific NA explicitly reported. The former missing-luv abort is gone.
- **Intel selected native cohorts:** job `122912832497` succeeds at **16:34:29 Paris**, **172 passed, 0 failed, 0 skipped**, including the exact NumberRow and native PAC controls. This is selected Intel coverage, not the Mac26 full target. The qualification profile is inactive.
- **Tooltip cancellation:** job `122912832680` concludes **cancelled** at **16:54:24 Paris**, `runner_id=0`, empty runner name and `steps=[]`. It had remained queued in every preceding snapshot; no actual Tooltip execution may be claimed. The API's started timestamp alone does not establish execution. Logs are unavailable. Later check annotations establish that no hosted runner was acquired after multiple attempts, with three macOS arm64 capacity notices. Root and this observer issued no cancellation. Evidence: `/workspace/scratch/oct28-ci-final30/historical-tooltip-407148-annotations.json`. Subsequent runs execute and pass Tooltip; this historical job itself remains unexecuted.
- **Dependent failures:** macOS verdict rejects a skipped predecessor; release verification rejects the failed required macOS lane. These are two downstream failure jobs, not two further independent product bugs.
- **Five skips:** Windows/Linux are unselected; macOS Build/Install are skipped dependent stages; Publish is skipped. Common's full unit/integration/E2E/build/install/verdict chain succeeds. Both architectures' managed Ollama runtime/build and both lease-silence jobs succeed. No retry or rerun was requested by this observer.

Final receipt: `/workspace/scratch/oct28-ci-merge7/final-receipt.json`, SHA256 **`424c249b0debcb34ba4f0105a521169a770391de2c1fca663d144949b1772b4d`**. Native evidence: `native26-evidence.json` SHA256 `86a3e0c85e617cc6d41a50dc63cd5d47ac31be393ad552ef6025bf0197525743`; exact failed physical probe: `cloner-native-failed-probe.json` SHA256 `08384b9ddab05f55396ed43d04dcc4fb6a67ef2e71addb341b4896ffc5ac6314`. Raw native log SHA256 `c1cd8790e78c81ec4c2360bad8eac9a84f85d1c323ff9184cdc89566d9d092a2`. All files are in `/workspace/scratch/oct28-ci-merge7/`; full raw jobs/run and downstream verdict logs are retained there.

## Historical appendix and completed author-worktree cleanup

The separately verified [eight-commit historical appendix](/workspace/scratch/oct28-legacy8-report-appendix.md), SHA256 `e6dda1afd52a6a943c81fcaa3cfc7b2c25d32d994e406c15adad6b7299ca99c6`, records original subjects, bugs, causes and regression evidence. These predate the current batch and are not eight new fixes. In particular **`efa02d82` was a GNU/BSD false positive explicitly reverted by `5aeec2a7`; it is not an active delivered fix**.

Three no-longer-needed author worktrees/caches were retired after actual process checks, recovering **1.52 GiB** as reported by Root. Their branches, thin bundles and ignored-file archives were retained, and the shared dependency target was preserved. Cleanup receipt: `/workspace/scratch/oct28-author-cleanup-20261028T163426/receipt-final.json`, SHA256 `4fe8aaccbd0682b77d503e83f1831d5e124c996626286f062581bca5a1b9affa`. This was the state at that cleanup checkpoint. Later retirement receipts below record additional cleanup; two fresh validation worktrees now serve the combined 37ad batch.

## Limits and maintainer questions

- Portable Linux-host tests do not establish Darwin/AppKit/TIS behavior. The candidate must pass native CI before those checks are reported as qualified.
- Hosted/headless CI does not establish interactive Accessibility consent, physical keyboard behavior, or every macOS timing condition.
- The updater intentionally retains a failed staging directory for recovery. Power failure and adversarial same-user interference are outside the tested transaction guarantees.
- The runtime-inventory omission proof exercises the detector slice, not every invariant of a complete source-guard run. Path-prefix E2E probes exercise the real bootstrap only; complete ordinary-path scenarios are independently required.
- The Linux logger test fix is one line and fully covered by a stale-cache reproduction and a missing-log negative control. No Linux product code changes. Its exact earlier full-suite cache writer was not attributed; the incorrect cached logger binding itself was reproduced. The corresponding Mac test does not replace that logger counter, and Windows has no Lua package cache.
- The upstream handover asks whether to repoint or retire the cold official Ollama lane now that production selection uses the native installer. CI files and owned Ollama installation remain outside our owned changes.
- No finite campaign proves that no bug remains. Physical keyboard/event delivery, TCC/Accessibility consent, interactive input-source transitions and the field Ctrl+G conflict cannot be certified by these headless controls.
- The private `ca5` L66 candidate was **not integrated**: dev's upstream release-order and isolated refusal/retry fixes supersede it. It must not be listed as a delivered Root fix.
- Current owned changes contain no protected-zone edits; dev changes imported by the authorized ordinary merges are explicitly distinguished from Root's owned fixes.

## Field issues imported from dev and remaining native confirmation

- L64: the original 320 MB post-reboot replay blocked the main thread for 138130 ms. Dev now contains bounded resumable replay (`f896a40a8d`) and a reboot-stable cache location (`0d31132a21`), imported by the normal merges. Root separately fixes reproduced replay publication/refusal safety in `5e11e36cea21`. Those upstream changes are not counted as Root-authored fixes. Actual large-ledger field confirmation after reboot remains useful; no native performance measurement is inferred from Linux-host SQLite tests. Initial proof: `/workspace/scratch/oct28-keystats-startup-readonly/report.json`.
- L66: dev now contains the old-layout owner exchange (`a584256d82`) and isolated shortcut refusal/retry (`b01388dd0b`), imported intact by the normal merges. Root did not duplicate the independent implementation work. The original analysis is `/workspace/scratch/oct28-l66-readonly/analysis.md`; these are imported upstream fixes, not Root-authored fixes. Interactive layout/chord behavior and any remaining competing Ctrl+G owner require field evidence.

## Complete normal development merge index

These eleven history-preserving synchronization commits import upstream behavior; they are not eleven new bug fixes. Earlier source-bound qualification and CI receipts above identify which trees passed or failed.

- `74f683f5a6ad49a62e5dad8837b8375375a01d3c` — chore(macos): merge current dev into fix branch; incoming dev parent `ed95abafa137c71a273e406206c9e43a3697e40c`.
- `cea098034fa6551e6dad08c152b021dd8925e951` — chore(macos): merge the latest release preparation from dev; incoming dev parent `a8de93681bd02c02ce73814897b3d573673195e6`.
- `dee1da0e9c501e025081deb5db59d9fc0915b7dc` — chore(macos): merge current release fixes from dev; incoming dev parent `80e3196d689a53856b4671b7b6c81191b88827a8`.
- `d895f9471b2de3d948c186707888c1ed7edd310d` — chore(macos): merge the latest preflight fixes from dev; incoming dev parent `85e34b905a5016846dc98cf1126dd1ca9572940d`.
- `22894401427cecdf9669ab7cf9e8a92ebc29ef96` — chore(macos): merge current layout and replay fixes from dev; incoming dev parent `88e350f9343ec34c180196fe2c56598ff15b524f`.
- `47fb581644719ce4904d38661f625815a39c773c` — chore(macos): merge the latest afternoon release fixes from dev; incoming dev parent `184d7b5f9a7fb458d666ed69de3ca61dd40d14dd`.
- `ffa0231b7675a307c070b39c30c014f6b389af10` — chore(macos): merge the latest release fixes from dev; incoming dev parent `5ee230e8aa062f0a9f61827b126808029be17f8e`.
- `c80cf8dddb3e04df4849ac501cec1ca92b9e1c71` — chore(macos): merge the final gesture release updates from dev; incoming dev parent `f4e3eb5eced266169d51d59ab7e40f3b64e2f85b`.
- `80e8092f2051ad4927dcc880f9585a0e69f6613a` — chore(macos): merge current Linux validation fixes from dev; incoming dev parent `463352a2d49d0fbe3fc9d7db3c8a425547b8a012`.
- `37ad319e514c3ade085dee292c35fca4e05d6cef` — chore(macos): merge held-key text fixes from dev; incoming dev parent `6d67374daeb70f3699a2266fd8118e77ca9658f3`.
- `ae73ed2f4d7b915e66b1628c057d346c456d91aa` — chore(macos): merge release source-contract fixes from dev; incoming dev parent `42acb5cdcf2c027925a672b94b30bcbc79bccc34`.

## Completed validator retirement

At **18:35:10 Paris**, the two completed/interrupted historical Common and HS validator worktrees were archived and normally removed after exact c715 patch verification and proof retention. This reclaimed 1.06 GiB of allocated checkout bytes; archives and source bundle occupy about 29.9 MiB. Branch refs, original/Root indexes and dependencies remained unchanged. At that checkpoint only the original, Root integration and active final34 oracle checkout remained. Receipt: `/workspace/scratch/oct28-validator-final-retirement/receipt.json`.

## Final historical author-worktree retirement

At **18:54:32 Paris**, the unused oracle author worktree was normally removed after full final34 qualification and publication of head `80e8092f20`. This reclaimed 558 MiB; the verified ignored-content archive occupies 15.4 MiB, and the verified source bundle was reused. Only the original and delivery worktrees remained at that checkpoint. Root/original HEAD/index and both dependency inodes were unchanged. Receipt: `/workspace/scratch/oct28-oracle-final-retirement/receipt.json`, SHA256 `0cbc39ddbbc37dcd4f48fd52ffdf84bbf7ae4210bbb39217fb134196deaf6de8`.

Two fresh, independently indexed worktrees were subsequently allocated for the new field fix and combined 37ad validation. They remain active until those tasks complete.

## Real field admission race — proof for atomic fix 34

The field snapshot `docs/field-reports/mac-2026-10-28_181733` records controlled reload acceptance at **18:17:36.865 Paris**, field-request admission at **18:17:37.368**, and fence completion/reload at **18:17:38.024**. Same-Lua-session identity is established by the cause-bearing interrupted `done.json`, the same lease token in the field run's own captured log window, and the next boot only after **18:17:38.239**; PID alone would be insufficient across Lua reload. Both relevant source blobs are identical at loaded revision 4d70 and published revision80.

The minimal canonical guard and three regressions are now committed as fix 34 below. They refuse a valid request with the existing `busy` reason when `TerminationCoordinator.terminal_in_progress()` owns shutdown, before results allocation, accepted/running receipts, configuration snapshot or steps. Readiness remains advertised so a refused pre-fence transition can resume safely; no request is silently left for the next session to discard. The exact final test on old80 yields **31 pass / 3 fail**, then **34 pass / 0 fail** with the correction. The real coordinator's held reload/exit and actual fence-refusal followed by a healthy retry are covered; an independent peer replays 34/34.

Component source tree: `7c82d090801308bbfdcf40b1c754901b33a3ef70`; patch SHA256 `3b5216fbe2426269ea412544810b36819369f4bd917b10daa4fec5eaa988e611`. Evidence: `/workspace/scratch/oct28-latest-field-review/ready.json`, `/workspace/scratch/oct28-field-admission-peer/peer-review.json`, and `/workspace/scratch/oct28-field-admission/`. The separate Screen Recording settings-URL refusal remains a root-cause-unconfirmed field question; no fallback is added.

## Thirty-fourth atomic fix and tenth normal development merge

`5d14ff8156196892edb2c3d7d39551a4a42c07ed` — **fix(macos): refuse field runs during terminal transitions**. **Committed locally, not yet published.** This is the one fix for the field race described above, not a second counted finding.

**Bug, cause and regression:** requests were admitted while the canonical terminal coordinator already owned shutdown, causing interrupted work. The new guard checks that existing owner before allocating or publishing run state. The exact final regression suite changes from **31 pass / 3 fail** on old revision 80 to **34 pass / 0 fail**. All eight full macOS component groups pass **25,380 cases across 2,039 modules**, plus **185/185 E2E**. All 12 required quick gates pass; independent qualification and final residual observation exit 0.

One original orchestration preflight failed on concurrent `git write-tree` index locking before any quick gate started; that umbrella exit 1 is retained. The quick gates then ran separately after HS completion, without restarting or weakening a test. A verifier invocation with a missing import is likewise preserved before the successful corrected invocation. The normal atomic commit hook exits 0 and the exact component tree `7c82d09080` remains unchanged. This developer field-run/Hammerspoon terminal owner exists only on macOS; the other OS drivers do not run these owners. Evidence: `/workspace/scratch/oct28-field-admission/ready.json`, SHA256 `fbe5dd6c1e504e3e58687f71fa6292af6c1459e04cb1cad6f7dfc77b001a8e6c`.

`37ad319e514c3ade085dee292c35fca4e05d6cef` — **chore(macos): merge held-key text fixes from dev**. **Committed locally, not yet published.** Incoming parent `6d67374daeb70f3699a2266fd8118e77ca9658f3` adds the upstream Unicode carrier that avoids keys the user still holds, its three regressions, healthcheck and documentation. All eight incoming paths remain exactly dev after canonical generation; both owned field-fix files are unchanged. Eleven quick gates pass, including 34 field tests and three incoming carrier tests; the normal merge hook exits 0. These upstream input changes are not a Root-authored hotstring fix. Receipt: `/workspace/scratch/oct28-merge10-verification/source.json`.

Because incoming dev changes actual macOS input source and nonhistorical documentation, new full Common (529 JS checks plus 18 other gates) and macOS (eight groups plus E2E) producers ran on exact combined37ad/tree0bc in separate worktrees. Both have now completed, with the actual outcomes recorded below. The earlier7c82 component qualification is retained without being rebound. Common is red; no combined success or new CI qualification is claimed. Proof directories: `/workspace/scratch/oct28-combined34-common/` and `/workspace/scratch/oct28-combined34-hs/`.

## Combined37ad verification update

The full macOS producer on exact head `37ad319e514c3ade085dee292c35fca4e05d6cef`, tree `0bc786dfbffe727cf6fb549be0fe7cd7857ae066`, completed at **19:49:44 Paris** with **25,385 passed / 0 failed across 2,040 unique modules**, followed by **185/185 E2E** and one pre-existing explicit host/driver-specific NA. The five-case increase over the field-fix component is three carrier cases plus two existing adapter-census cases. All 16 gates and the durable wrapper exit 0; physical source/index remain unchanged. The subsequent sequential residual observer and independent qualifier also exit 0. Receipt: `/workspace/scratch/oct28-combined34-hs/qualification.json`, SHA256 `f9a59259e55cf0e842037d9710c91316e204def916665c5597567e89299437b3`. These completed results qualify this exact macOS snapshot, not a later correction.

**Historical 19:50 Paris progress checkpoint:** the Common producer had not yet completed. At that observation, 490/529 checks had completed and a new actual failure appeared at check 483: `macos/adapters/unicode_carrier.lua` duplicates the canonical `NS_PER_MS` constant. This source arrived in dev6d and remains unresolved, alongside the two protected failures 250 and 474. Root is investigating this new failure in the nonprotected driver source. No complete Common qualification was claimed at that checkpoint, and the running producer was not restarted or changed to incorporate the new requirement. The completed outcome is recorded next.

## Completed Common37ad results and next candidate

The full Common producer on exact head `37ad319e514c3ade085dee292c35fca4e05d6cef`, tree `0bc786dfbffe727cf6fb549be0fe7cd7857ae066`, completed at **19:53:48 Paris**. All **529 unique checks** executed: **526 pass / 3 fail**. Checks 250 and 474 are the previously documented protected failures; check 483 is the newly identified upstream `NS_PER_MS` duplicate in the macOS carrier. The JS subprocess and durable outer child wait both return 1. All 18 other gates return 0. Physical source/index are unchanged; the sequential residual observer exits 0 at **19:54:17 Paris**. Receipt: `/workspace/scratch/oct28-combined34-common/qualification-observed-three.json`, SHA256 `2162819cfd044179dc44bf1812555c2791fe416f2cef4b6ada0ff0c92414e734`. The older predictive two-failure qualifier was retained without execution; it is not evidence for this three-failure outcome. The batch is genuinely red, with no skipped or weakened test.

Root is preparing a separate macOS semantic-staleness-owner candidate in four files; it is **not committed, not published and not counted as atomic fix 35**. Focused real-health coverage passes 12 cases and carrier coverage passes 4, including three newly added cases in total. With the new real health predicate wired, the old carrier passes its three existing cases and fails the new delegation case, actual exit 1; this is not an old-source missing-API failure. Boundary and snapshot mutants also fail. Full verification had not started at that historical checkpoint; the later candidate35 launch is recorded below.

A fresh fetch at **19:54 Paris** exits 0: dev remains `6d67374daeb70f3699a2266fd8118e77ca9658f3` and published fix/macos remains `80e8092f2051ad4927dcc880f9585a0e69f6613a`. In hosted run `40739753554` on head80, three Install cells now succeed and two remain queued. The run is not final; no whole-CI success is claimed.

## Historical candidate35 peer acceptance and precommit content qualification

The semantic-staleness-owner candidate now has independent peer acceptance. Its frozen **staged tree is `6c9db77db58334bb6435f73cec2094e72934653e`**, based on commit `37ad319e514c3ade085dee292c35fca4e05d6cef`; patch digest prefix `de7cdf`. Owner-ready receipt SHA256: `aedcdfe990aea9f63103cefe95d215f754cc3aa69987ff25bb73d9f549d065a1`; peer receipt SHA256: `6dbce7c5d3c13757f33a2a65b1a9ac03632972bba14afc4a9660bd55e0525328`.

Full macOS verification started at **19:59:31 Paris** under durable wrapper `2729822`; full Common verification started at **19:59:45 Paris** under wrapper `2730321`. Both results were pending at launch. The later completed macOS outcome and still-pending Common progress are recorded below; the expected protected failures are not substituted for actual results.

This is **precommit qualification of the frozen staged content**, not qualification of commit37ad's committed content. At that checkpoint candidate35 was uncommitted and unpublished. The later owner-only commit is now superseded as recorded in the opening status and remains outside the 34 delivery commits. A subsequent atomic commit must preserve the exact qualified tree; its commit-to-content binding must be recorded separately, without rewriting the original receipts.

## Historical candidate35 macOS completion and progress checkpoint

Precommit macOS qualification completed at **20:10:50 Paris** for staged tree `6c9db77db58334bb6435f73cec2094e72934653e`, based on commit `37ad319e514c3ade085dee292c35fca4e05d6cef`: **25,388 passed / 0 failed across 2,040 unique modules**, followed by **185/185 E2E** and one pre-existing explicit host/driver-specific NA. All 16 gates and the durable child wait exit 0. All 12,856 physical source entries remain unchanged at each gate. The sequential residual observer ran after both producer and wrapper ended and exits 0; the independent qualifier also exits 0. Receipt: `/workspace/scratch/oct28-combined35-hs/qualification.json`, SHA256 `af7ca4f51583c53c7451eb01967f332e437e4c7466425e60431e3559f9acecd9`, independently verified by Root.

This is qualification of the exact staged content, **not a new committed SHA** and not a rewrite of the earlier37ad receipts. At that checkpoint candidate35 was uncommitted and Common35 was still running: **332/529** checks complete at **20:11:25 Paris**, with only protected check 250 failed so far; check 483 has not yet executed. No complete Common result or combined green is claimed.

On published head80, hosted run `40739753554` has four Install cells qualified successfully. The final clean/Karabiner/upgraded-state cell remains queued at the **20:10 Paris** observation. At that checkpoint the final verdict had not yet been created and the run remained pending. The terminal result is now recorded in the opening status; these progress observations never established global CI success.

## Latest upstream reconciliation and remaining questions

The three earlier Common failures are now resolved **upstream in dev42ac**, not silently waived, skipped or repaired in protected areas by this campaign. Root imports that source through a normal merge and will run new source-bound suites. The candidate's independent health API is superseded by dev's canonical `health.now_ms`; no compatibility shim or duplicate implementation is carried into delivery.

The confirmed remaining out-of-scope product bug is the owned-Ollama bootstrap's interrupted-download workspace leak, with its unchanged-source signal proofs recorded above. Whether to extend cleanup ownership there after the protected release work remains a maintainer question. The Swift worker flow hypotheses and Screen Recording settings-URL refusal remain **unconfirmed**, separate from counted bugs. Physical TCC, input-source and chord behavior still need field evidence. The old80 hosted capacity refusal also leaves its final Install cell unexecuted; fresh CI must actually qualify the new merged source.

## Eleventh normal development merge and committed-source full verification

`ae73ed2f4d7b915e66b1628c057d346c456d91aa` — **chore(macos): merge release source-contract fixes from dev**. The normal merge is committed cleanly with parents `37ad319e51` and `42acb5cdcf`, exact tree `fc5b9f2251109a97e5adf736f084d44f8ad134b1`. All nine incoming paths exactly retain dev; both owned field-admission files are unchanged. Canonical generation and 14 other quick gates exit 0, including all three checks that failed on the earlier source. The normal merge hook exits 0. The true `verify-change` plan for `origin/dev..HEAD` exits 0 and the fresh canonical inventory contains 529 checks. Receipts: `/workspace/scratch/oct28-merge11-verification/{source.json,receipts.json,commit-receipt.json}`.

One initial orchestration preflight exits 1 before any gate runs: its source comparison mistakenly compares incoming dev against integration HEAD and therefore includes both existing owned field files. The original script and `preflight-failure.json` are retained. Correcting the incoming range to `6d..42ac` verifies the actual nine upstream paths; the subsequent gates then pass. This is preserved as a harness preflight error, not a product failure or a replaced test exit.

A new **committed-source** Common producer starts at **20:24:14 Paris**, durable wrapper `3296362`, and full macOS verification starts at **20:24:15 Paris**, wrapper `3296626`. Both use exact head `ae73ed2f4d`/tree `fc5b9f2251`; their completed outcomes are recorded below. Linux preparation has GO for the same committed source, owing to the five changed shared locales, but has not yet launched. No old candidate35 receipt is rebound to this tree. The private superseded `f699073f0d9fe66a23cfb2f2e45a71a28c4ec785` is not an ancestor of delivery. Delivery remains 34 atomic commits plus 11 normal development merges, with no new atomic fix35.

## Completed merge11 qualification and strict test-oracle follow-up

All three full producers have completed on **committed** head `ae73ed2f4d7b915e66b1628c057d346c456d91aa`, tree `fc5b9f2251109a97e5adf736f084d44f8ad134b1`. These results do not qualify a future source-oracle correction until its content and selected checks are bound separately.

- **macOS:** 25,385 passed / 0 failed across 2,040 unique modules, plus 185/185 E2E and one pre-existing explicit host/driver-specific NA. All 16 gates and durable child wait exit 0; completion **20:35:45 Paris**. The sequential observer exits 0 and all 12,856 physical source entries remain unchanged. Qualification SHA256: `fee62dac5453b8402b45c8678aad4dea6844e76fa1ce6ae25fc2c88fdec29d4f`.
- **Linux:** 19,810 passed / 0 failed across 804 unique modules, plus 302 E2E records. All 15 gates and durable child wait exit 0; producer completion **20:31:12 Paris**, final qualification **20:37:32.562 Paris**. A fresh sequential observer exits 0 and physical source remains unchanged. Qualification SHA256: `8fa9b8abc9a8eb1a4fa47f8d348251d9b390ba120b42e01de2480fec0ec2b3e5`; ready receipt SHA256: `a71334a473374771202f29ab3d0bcae2215210960cf6d6a5d833cc51f4e0c0a3`. The one-case increase over 19,809 is the exact upstream f4e gesture-info test, unchanged from dev42ac.
- **Common:** 529 unique checks execute, **528 pass / 1 fail**. The only failure is 487; all 250/474/483 now pass. Actual JS and durable wrapper child wait exit 1; producer completion **20:42:09 Paris**. All 18 other gates exit 0; source/index are unchanged and the sequential observer exits 0. `qualification-observed-one.json` SHA256: `fbf8e0794e139d072c887802a9b44d3d5414608f2cef0828767a1c69b0094863`. This is a genuine retained red, not overall green.

**Linux receipt-accounting correction, without rerunning or changing a suite:** the E2E output has 302 executed records but 274 distinct human labels; those labels are not unique case IDs. An initial diagnostic qualifier failed because it incorrectly required unique labels. A raw-multiset diagnostic then found exactly one expected measurement difference: the canonical menu row count changes from 2258 to 2257 while remaining within the unchanged accepted bound `100 < rows <=3000`. The E2E source is identical to the previous proof. Root approved normalization only of that anchored, once-emitted numeric measurement; all other 301 records, their labels and multiplicities match the previous receipt exactly. The final normalized comparison matches all 302 records and explicitly discloses the 274-label count. Both initial errors and every diagnostic version remain retained. No production source, test, assertion or suite was modified or rerun to obtain this result.

**Remaining failure 487:** `tools/test/test-recommended-defaults-rule.cjs:154` still expects raw `gesture_recommended_info`, while the unchanged actual upstream Windows handler now uses `MenuCommand.GESTURE_RECOMMENDED_INFO`. The driver and oracle both match dev42ac; this is an observer-source contract mismatch, not permission to change a recommendation, default, gesture or product route. Root has assigned a one-file, test-only correction: require the strict canonical route, preserve every existing cross-OS assertion, and add negative controls. Independent peer review waits for the frozen patch. No final source SHA or full-Common launch is yet claimed; the prepared proof directory `/workspace/scratch/oct28-recommended-final-common/` is not a completed run.

The macOS and Linux product/test-harness content remains unchanged by the proposed one-file CJS correction. Existing proofs can only support later source through explicit subtree identity and the actual verification planner; they must not be rewritten to a new tree. The next qualified test-only delivery atom 35 remains distinct from private superseded `f699`, which was never integrated or pushed. Delivery accounting remains 34 atomic commits, including the local field fix34; no commit beyond published80 has been pushed. A fresh remote observation at **20:41 Paris** still finds dev42ac and origin/fix/macos80 unchanged.
