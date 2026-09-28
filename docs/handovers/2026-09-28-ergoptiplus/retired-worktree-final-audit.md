# Retired worktree final audit

Committed comparison: dev@2d065e7c808fb3006fa23dfa3e2584e1747d3b9e. Current dirty files also inspected where specified. No repository or Git-reference mutations; no tests or implementation performed.

## Actionable findings

- **preserve pending work: actions-D4-staged.patch** — Confirmed absent in both committed dev and current files: 21 locales retain active_model_label and old model_label wording; Mac formatter and five test lookups still use active_model_label. This 23-path staged delta is not integrated. Rebase and test before application.
- **preserve pending work: diag-integration-unstaged.patch** — Mac extension scan/load boot hooks and Windows historical-fragment routing test are missing in current source. Requires the unintegrated f35930ec2 and e58cadf95 foundations already exported in branch-original-patches. Boot snippet is stale against subsequent initialization changes; do not apply blindly.
- **original provenance: actions-D4-history.bundle** — Original detached 28-commit history: 13 patch-equivalent commits and 15 plus commits all have same-subject adapted counterparts in dev. Same-subject mapping is not a proof of full semantic equivalence. Exact bundle retained, git bundle verify passed; requires f4d0bfd633ab7af50044199917e1e3db4241d8be, confirmed ancestor of dev.
- **conservative preservation: windows-master-state-unstaged.patch** — 23 tracked paths, mainly excluded W1 manifest/defaults/loader/test prerequisite delta. Much is present or superseded in dev, but full semantic equivalence is not proven within this bounded audit. Preserve original for review, never wholesale apply stale generated output.
- **no missing tracked changes: shortcut-refusals** — Archived staged/unstaged/untracked state empty. Original non-equivalent commits already preserved by branch-original-patches.
- **no lost untracked fixture: windows-master-state** — Archived feature_state_boot_smoke support file is byte-identical current. Archived neutral_config_manifest test is superseded by current additional assertions and navigation-owner correction; exact old 4552-byte test retained for provenance.

## Exact exported originals

Directory: `D:/ewt/_scratch/retired-worktree-originals/`. Byte-exact copies with hashes in the adjacent JSON report.

| Artifact | Bytes | SHA256 |
|---|---:|---|
| actions-D4-staged.patch | 30572 | 2eb7fbf20259524e64d9e38896896ceec914747b176557ce75fcfbb592532937 |
| diag-integration-unstaged.patch | 3457 | 03124e7aa042449c3f6f580e92e69e7349f4a0ed6233e0da266cfb790b98902f |
| windows-master-state-unstaged.patch | 511775 | 693d5509b76fa6279742923d8b9599120599969faa04abbef14d942f5cb32de6 |
| actions-D4-history.bundle | 483526 | 917cd6218564fb48e398384e32844707b9d0bbd384eb3b7945250c07121a6a79 |
| windows-master-state-test_neutral_config_manifest.ahk | 4552 | 32447ec7b4d0b4932ca735e21fca9079ae866c6fb99ff92a978e57861cee06ba |

## Ignored ZIPs

- Generated build output, locale/hotstring TSV and Python bytecode are reconstructible.
- Both personal_shortcuts.ahk files are generated forwarding stubs pointing only at Temp/ergopti-full-startup-*/suspend-marker/config/autohotkey/personal_shortcuts.ahk. No user shortcut bodies.
- today.log is a 68-byte synthetic typing record containing text x and a test UUID; test_results.txt is an old 5/5 E2E receipt.
- The only other entries outside generated/fixture classifications are .claude/settings.local.json, tests/test_config.ini, and one zero-byte fixture write lock; all byte-identical current root.
- No missing implementation or user-authored config found; do not include these ignored ZIPs in GitHub handoff. Local machine settings were not exported.

## Limits

- Added-line presence is a bounded screening heuristic, not proof of semantic equivalence. No tests run.
- D4 original history has adapted counterparts; exact 483526-byte bundle retained instead of claiming patch equality.
- Windows original delta is mainly W1 prereqs already integrated in adapted form, but full semantic equivalence not proven in this bounded audit; preserve original.
- No git refs/index/source mutations. No full archive copy.
- Per-file added-line screening in JSON is conservative (source formatting/CRLF can produce differences). The D4 absence finding additionally checks actual locale values and live formatter/test references, not merely line matches.
- Both pending patches need current-owner tests before integration. No claim that all old work is integrated. No full 632 MB archive copy.
