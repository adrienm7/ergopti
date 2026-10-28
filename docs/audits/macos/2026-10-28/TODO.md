<!-- docs/audits/macos/2026-10-28/TODO.md -->

# Remaining items after the bounded macOS audit

The user stopped new research and requested durable records before container deletion. This file preserves already-found work; it does not authorize changing protected areas or count unconfirmed source hypotheses as bugs. All times in the report use Europe/Paris.

## Confirmed bug left in a protected installer

- [ ] Give `native_bootstrap_python` operation-local ownership of its uv-wheel and Python-archive temporary workspaces in `static/ergopti_plus/macos/modules/llm/native_python_bootstrap.sh`, with cleanup on interruption and preservation of the primary refusal status. The owned Ollama installation path was explicitly excluded from edits.

**Proof:** the unchanged helper and the caller's real EXIT reporting trap are exercised by the archived `oct28-protected-bootstrap-report/probe-uv-python.py`. The normal download-refusal control returns `1` and removes its workspace. A real process-group SIGTERM during either the uv or Python download returns `-15` and leaves the allocated directory and controlled partial bytes. No live group member remains. The caller EXIT trap reports a stage; the native PTY guardian owns its separate source snapshots, not these download folders.

**Scope:** actual Linux Bash, filesystem and process signals with one strict local download port. No Darwin/native PTY execution is claimed. This is distinct from delivered `c71552b77386ae5eaf4cb0d0461f1b47e4da5d43`, which repairs the private MLX bootstrap owners. Windows and Linux product installers do not use this macOS owned-Ollama helper.

**Next verification:** before any later fix, replay both original interruption cases and the normal refusal control against the exact current source. The fix needs regressions requiring workspace removal and owned process retirement, plus preservation of foreign/replaced paths and the original failure. Check the same function's two allocation paths, not only its first download. Reuse the existing lifecycle ownership contract; do not add silent fallback or cleanup of unverified paths.

The complete recorded source pins, exact arguments, receipts and reproduction are in `recorded/oct28-protected-bootstrap-report/` in the evidence archive.

## Completed test-oracle repair

- [x] `d02675fa2df11b8d5d0adbfa1e673164b7a41ea1` — `test: verify executable recommended info owners`; published through merge12 `b56677ea345e115828e2bf5b5dbfcf5cf5e46c7e` with the identical fully verified whole tree. The old Common check 487 failure is resolved.

The corrected one-file oracle preserves all original assertions and rejects 22 negative controls, including all eleven already-proved lexical decoys across the three OS. Independent peer acceptance and full Common 529/529 plus 18 other gates with actual exit0 are archived. The initial candidate and failed diagnostic proofs remain available; no product/default/gesture behavior changed. This item is complete and does not authorize further audit.

## Unconfirmed native hypotheses: reproduce before considering fixes

- [ ] `OwnedProgramWorker.runBridge`: reproduce a terminal receipt output-write refusal with the real native test session. The source-flow hypothesis is that a recorded terminal state might coexist with process exit zero after forwarding fails. The Lua consumer still requires a terminal receipt and exit zero and therefore fails closed. No actual Swift/Darwin failure was proved.
- [ ] `InstalledPhysicalSourceBridge`: reproduce cancellation/setup refusal before nonblocking descriptor setup with a quiet real child and owned native transport. Check bounded refusal and actual owned-group retirement. The source-only hypothesis is that a short-circuited setup can leave blocking pipes before cancellation is consumed. Existing guardian closure might already resolve it; no native failure was proved.

The archived `recorded/oct28-native-receipts/ready.json` names the exact source pins, candidate lines, proposed native probes and limits. Do not count these two hypotheses as delivered fixes or confirmed bugs.

## Already-recorded field questions requiring a real Mac

- [ ] Confirm physical keyboard/input delivery, Accessibility/TCC consent and interactive layout transitions with an isolated real runtime. Hosted/headless checks and virtual fixtures do not certify every physical timing condition.
- [ ] Reproduce the single Screen Recording settings URL refusal in its original application/MDM context before proposing a fallback. Other Terminal variants were accepted; the cause remains unconfirmed.
- [ ] Retain field confirmation for the L59 orphan key-up question and the L66 competing Ctrl+G owner after the upstream fixes. The private L66 candidate was not integrated; `dev` already contains the release-order and isolated shortcut refusal/retry changes.
- [ ] Decide later whether to repoint or retire the cold official Ollama lane now that production selection uses the owned native installer. CI and owned-installation changes remained protected. A successful bootstrap receipt does not establish daemon serving or model execution when those verdicts explicitly say not executed.

## Source and infrastructure history that is not an unfixed product bug

The five locale entries, Windows raw command literal and duplicate `NS_PER_MS` issues were repaired upstream in `42acb5cdcf2c027925a672b94b30bcbc79bccc34`. They pass on the imported source and should not be reopened from an old CI log. The separate stale check 487 and all eleven known lexical decoys are completed above.

CI `40739753554` covers older source `80e8092f2051ad4927dcc880f9585a0e69f6613a`; it is not a final-source verdict. Its last clean/Karabiner/upgraded installation cell never executed because GitHub could not allocate an ARM runner after repeated attempts. The annotations establish infrastructure capacity, not a driver bug. Four other installation cells and all executed macOS product cohorts passed. The new run is [40765470617](https://github.com/adrienm7/ergopti/actions/runs/40765470617), exact published source `b56677ea345e115828e2bf5b5dbfcf5cf5e46c7e`, created 21:41:08 Paris. Run **40765470617**, attempt1, finished **FAILURE** at **2026-10-28T22:40:15+01:00 Paris**, on exact source `b56677ea345e115828e2bf5b5dbfcf5cf5e46c7e`. Its complete census is **47 jobs: 39 success, 5 skipped, 3 failure**. The observer completed with actual child exit0. The immutable final receipt has SHA256 `92d9f6903302da8252503c2deb9905d4e4645ed3275fee7be5b40ab3c780bd42`. Every skipped or unexecuted stage remains classified as such; a green neighboring job is never substituted.

## Incomplete final-source qualification

- [ ] Inspect the retained terminal run and exact failing/cancelled/unexecuted cells before claiming complete macOS qualification. No workflow retry was started at shutdown.

The macOS26 Swift step hit its fixed ten-minute action deadline at **22:37:22.851755 Paris**. Its actual transcript records **387 case starts, 386 distinct passed cases, no printed XCTest assertion failure, and no full successful suite summary**. The final started-but-unfinished case is `ManagedPACSourceTests.testRealPACSourceTrustAnchorsPreserveHostnameAndDowngradeRefusal`. The earlier `HomebrewArchiveAcceptanceTests.testRealBrewZIPInstallXZUpgradeAndRefusalsPreserveInstalledState` completed successfully in **288.971 seconds**; that duration does not establish why it was slow or rule out a later test hang. The native job therefore fails and the macOS Build/Install stages remain unexecuted; the two final verdict failures are downstream of this stage refusal. The workflow timeout is in a protected area and was not changed. Investigation and full current-source native/build/install qualification remain TODO; no automatic retry or test bypass was used. An earlier progress inference incorrectly called the Swift step successful when later always-run diagnostics started; the retained `native-stage-correction.json` corrects that inference against the actual step verdict and transcript.
