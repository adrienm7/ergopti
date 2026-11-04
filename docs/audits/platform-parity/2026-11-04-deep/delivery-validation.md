# Integration validation and delivery delta

## Evidence contract

The 18 scoped reports audit `89b0b774c8c960c7ad458ac3cb98d5c97598e518`.
They remain revision-pinned evidence. The generated feature inventory separately
tracks shared declarations and restricted menus; it cannot discover every
runtime capability or prove native equivalence. This audit and its intentional
difference register are reviewed snapshots, not automatically inferred product
truth. Keep implementation changes tied to their documented boundary tests.

## Integration checks

- Existing audit workflow validation passed for the AHK envelope (9 findings)
  and Hammerspoon envelope (11 findings), using `validate-report --report`
  with the corresponding `findings.json` path.
- An integration check verified all 18 report paths, 30 unique OS-scoped IDs,
  all three envelopes' required fields/enumerations, and all 24 classified
  difference entries' three OS descriptions and evidence report links.
- Root independently replayed the safe Lua module probes and Windows
  source probes. Real PowerShell 7.4.6 executed the Windows touchpad workers
  with fake PnP primitives: onboarding incorrectly reported success for all
  three failure controls; the restart worker correctly refused them.
- No native Windows AHK, administrator-account switching, actual PnP,
  macOS desktop injection, real touchpad or live AI-provider acceptance is
  claimed. See each scope's reproduction and remaining checks.

## Intervening dev changes

A read-only delta review covered the intervening dev commits through
`601fde0284333199620c8b405c50878efa03b19d` before delivery.

- Windows now accepts quoted and legacy bare personal-hotstring TOML keys,
  and the editor consistently writes quoted keys. This fixes a separate
  editor/loader defect. It does not change the programmable reload admission
  owner (AHK-001) or metrics findings.
- macOS retains the shared runtime by default and explicit `runtime="owned"`
  selection. A new conditional Tap-Holds command offers signed owned-runtime
  installation with administrator confirmation when components are missing,
  then requests activation/reload. System Settings approval and native typing
  qualification can still be required. Earlier descriptions implying that no
  guided installation exists are historical at the audited revision.
- The source owners of the deep macOS input, hotstring and gesture findings
  were unchanged. Source review of newly added hosted acceptance does not
  establish that a hosted/native run passed.

## Generator ownership correction

The existing formatting self-test found that the five feature-inventory
projections registered by the earlier automation were missing from
`.prettierignore`. All five are now excluded from manual formatting; their
registered generator and drift check remain authoritative. The unchanged
formatting self-test passes after this correction. No application behavior or
native admission guard was changed.

## Repository checks

- Formatting passed with pinned Ruff 0.15.8 after installing it locally;
  all edited Markdown/JSON/code proofs use the repository formatter.
- AHK encoding passed (UTF-8 BOM + LF), and strict convention lint passed.
- Domain generation passed all 15 steps with a real Go 1.23.4 compiler,
  including drift checks. The initial aggregate failure used the unrelated
  `/usr/bin/go` command, which is not the Go compiler; no source was changed
  to bypass this failure.
- The feature inventory/parity check passed for 361 classified configuration
  entries; its report still marks 184 supported claims awaiting hardware proof.
- The Sparkle source/feed check passed after adding a real libxml2 2.9.14
  `xmllint`. The managed Ollama protocol check passed after exposing the
  already installed real Lua 5.4.8 engine under its required `lua5.4` name.
  Neither environment repair changes a test assertion.
- The general JS suite exposed a pre-existing site-deployment fixture failure:
  its superseded-reference scenario constructs an object without `ref`, while
  the admission owner correctly requires it. An isolated replay of five exact
  baseline modules reproduces the same error, without loading this audit's
  changes. See [baseline output](delivery-site-baseline.txt). No admission guard
  or unrelated deployment behavior was changed by this audit.

- A second pre-existing Pages workflow/validator mismatch failed the CI wiring
  check. An exact baseline extraction of its original validator reproduced all
  12 problem labels in order; source/workflow/lockfile identities matched the
  untouched baseline and index. See the [baseline diagnosis and receipts](delivery-ci-baseline/diagnostic.md).

The full initial run reached all 570 JS checks and reported 7 failures;
its native-AHK runner also explicitly reported one case not executed on Linux.
Five failed checks then passed their unchanged targeted reruns (domain build,
Sparkle XML, formatting ownership, managed Ollama and Lua globals). The two
remaining failures are reproduced on untouched baseline files as above. The
initial `verify-change` exit remains 1; it is not relabeled as a green aggregate.
Its separate formatting gate was successfully rerun after the local toolchain
and report-format corrections. See [complete initial output](delivery-verify-change.txt).

Native Windows/macOS/hardware/provider acceptance remains unexecuted regardless
of source-check success.

## Checks after rebasing onto reviewed dev

The audit commits were rebased onto reviewed dev `601fde0284333199620c8b405c50878efa03b19d`.
Generator-owned formatting now uses the Prettier API so its output is independent
of the manual formatter's ignore policy. This preserves readable projections
while preventing manual formatting from becoming a second output owner.
Regeneration preserves the JSON values and rendered Markdown; it changes no
application behavior or inventory declarations.

The inventory/parity and formatter-ownership checks passed. Whole-tree formatting,
strict conventions, AHK encoding and both official audit envelope validators
passed on the rebased tree. The integration check also verified every scope,
TODO ID, difference classification and relative Markdown link. The full
570-check run above remains attached to its original source baseline; it was not
rerun or reclassified as a green full run on the intervening runtime changes.
