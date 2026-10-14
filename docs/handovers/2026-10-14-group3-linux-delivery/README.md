# Group 3 Linux delivery checkpoint

The number-row backend and its diagnostic input correction are integrated in
`dev` at `f716daa9ca68c502dde22195da7f8c5fd53d97a0`, with ordinary merge history.
No Group 3 TODO item is removed. All thirteen remain partial, and items 16/38
retain their transversal validation requirements. Item 22 remains excluded.

## Integrated atoms

- `d70c2d9aa3ba3e8a3e68bfa027acc3cb72bd0221`: retain original Linux
  Reader/Writer/Probe/Capture issuers, number-row output owners, Shift handoff
  and retirement. The original thirty-three unit cases remain; twenty-two
  additions bring the whole module to fifty-five cases on both Lua ABIs.
- `ab8da4fa9bb5bff8feb707a099252a1eeb8c8dd1`: bind the existing XI2 diagnostic
  to the current Probe input. Only its exact input SHA and TODO107 change;
  native expectations, admission checks and workflows remain unchanged.

The integration preserves concurrent Windows commits `52feb455`, `9b87607`,
`f647fd9d` and `c793ea08`. The first Dev push was rejected when a peer advanced
Dev; the successor retains that work and the unpublished merge `1789782f`.
No force push, reset, squash or rewritten history was used.

## Exact validation

[Manual run 38512774080](https://github.com/adrienm7/ergopti/actions/runs/38512774080)
tests the actual integrated SHA above on `codex/ci-validation`, with
`os_lanes=linux`. Hosted Validate receives the exact SHA and executes the
non-push release refusal. The whole run succeeds: 25 successful jobs, zero
failed jobs and three skipped jobs (Windows, macOS and release publication).

| Scope                      | Actual result                                                   |
| -------------------------- | --------------------------------------------------------------- |
| Common                     | 426 checks pass; properties pass                                |
| Linux units                | 521 modules, 13,693 passes, zero failures                       |
| Linux E2E                  | 193 passes, zero failures                                       |
| Genuine Xvfb source cohort | 65 checks, zero failures                                        |
| XI2 native diagnostic      | Original C3 prerequisite and LuaJIT ABI29/cookies3 pass         |
| Packaging                  | Installable bundle, .deb, .rpm, AppImage and Flatpak build pass |
| Installation/startup       | All seventeen scenarios pass                                    |
| Windows/macOS in this run  | Not selected; skipped                                           |
| Release                    | Skipped; no release published                                   |

XI2 artifact `11871097976` has official archive SHA-256
`c284f304d0a51e1af34580837a34743e388a6d49f3ba6514b90d19a9c7539eac`.
Its seven members, committed source pins and included process-family/display
retirement receipts are received. It explicitly reports a CONTROLLED runtime,
zero input injections, `native_epoch_claim=false` and `input_output_grant=false`.
Additional original-C3 raw files are not included in that seven-member artifact;
no independent rehash of those absent files is claimed.

The earlier genuine run
[38507668185](https://github.com/adrienm7/ergopti/actions/runs/38507668185)
failed: the diagnostic required historical Probe `97444` while the integrated
Probe was `ef40b9`. It refused before native execution and evidence-directory
creation; mandatory artifact absence followed. That run passed Common426,
units13693 and E2E193/native65, but skipped packaging/installations. Its failure
is preserved separately from the corrected success.

Private controlled receiving also preserves the whole55 positive cohort under
LuaJIT and Lua5.4. Removing only the invalid-mode guard yields54 passes and the
sole named invalid-intent failure on each ABI; raw names, order and literal
expected-false/actual-true cause are checked. This is software causality, not
physical input qualification. The independent dead-key corpus remains unchanged.

## Remaining work

Production `Runtime.xi` is still undeclared, so connected admission refuses and
public physical/forced-row availability remains false. Runtime declaration,
generation/staging and Root-owned enrollment need coordinated ownership.
Connected input/source/modifier/output lifecycle and actual Writer/Xorg device
association require separate receiving; ordinary package startup does not
qualify forced physical delivery or Wayland.

Windows native-HKL forced-symbol/output and macOS forced digit/symbol owners
remain software work before their native and physical tests. Existing registry
KLE delivery and read-only native probes are already implemented and must stay
intact. The Windows continuation remains four stages: implement the original
native owner, join all-ten admission/dispatch, receive independent native
before/after cases, then validate physical keys on the maintainer's PC.

The physical editor, magic defaults, combinations, automation and window
switcher retain their TODO requirements for owner currency, collision handling,
modifier/output retirement, native discovery, packaging and device acceptance.
The earlier macOS failures remain separate; this Linux result does not close
them. Historical French-category writer causality remains unproved without
contemporaneous evidence; preferences must not be forcibly enabled.

The optional Lua/AHK metadata policy guard has34 passing private Source controls;
its AHK83 component/loader/native receiving and coherent enrollment remain open.
The optional Python recipe coherence case passes sixteen private controls and
fails only its new case with the exact old pin. It is unadopted while Root's
fifteen-case enrollment contract remains unchanged. Neither preparation grants
runtime or native authority. Essential earlier preparations remain in the
[published capsule](../2026-10-13-group3-essential-preparations/README.md).

## Coordination and branch custody

Owned lock `9c277cc0` was deleted normally only after the whole corrected run
terminated, with exact owner/nonce/empty-commit proof and the unchanged advertised
old-SHA deletion guard. Remote absence and all other refs, Source bytes, raw and
logical index and local refs remained exact. The preceding owned `7add` lock
was separately released after its whole failed run. Neither lock was a
validation branch; validation used only `codex/ci-validation`.

Obsolete owned remote `codex/ci-actions` at `a3a5430f` was deleted after fresh
ancestry, fifty-one terminal branch runs and zero open PR checks. It was already
absent locally. `feat/actions` remains the canonical branch for unfinished
software and ownership coordination. No main, site, peer branch or peer workflow
was changed or stopped.
