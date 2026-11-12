# Structure migration: resume point

This file is the single place to resume the phase 2 structure migration
(docs/design/structure-plan.md) from this branch alone. It is updated in the
same commit as each step or checkpoint. Times are Paris time.

## Where things stand (2026-11-13, 00:35)

- Branch: `claude/ergopti-todo-structure-phase2`, fast-forward only. Base:
  dev `520bb24c`, merged in `ee1aa96f`; the plan appendices were regenerated
  on it (`e81e64b8`).
- Steps landed on dev: none. The migration is not authorized to land yet.
- **S01 is NOT green on CI.** The proof on dev `520bb24c` is
  `claude/ergopti-todo-structure-phase2-proof-2` at `244ef275`; `ci.yml` run
  43311674550 (`os_lanes=all`) has 28 failing jobs, far outside the dev reds.
  Local gates (JS suite, Linux and macOS Lua groups) showed no new red,
  because about 120 checks are already red locally (root user, no `pwsh`, no
  Windows) and mask S01's breakage there. **Measure S01 by CI, not locally.**
- S02 (`core/crypto`) applies and passes the runner's gates on top of S01,
  locally only. It needed three tooling fixes (`b3060b7f`, `7c3a977e`,
  `5261cc0d`) and the driver-root rule (`476e929a`, `24b22b12`). It has no CI
  run yet. Do not go further than S02 until S01 is green on CI.
- S02's local measurement (c21, against S01's c20 on the same base) shows new
  reds of its own, not yet read:
  - JS: js-0035 (banner-marker safety), js-0241 (driver tree parity I1),
    js-0253 (port × driver adapter matrix), js-0280 (scan coverage of
    platform/), js-0281 (untracked artifacts), js-0441 (Windows unit matrix
    groups);
  - Lua: macOS meta, 3 new failures; macOS modules, 1 new failure.

### S01 CI failures (run 43311674550): causes found and their state

Fixed on the branch after `244ef275`:

- Data and source contracts:
  - `test-no-plan-refs-in-source`: the runner's own "Phase 2" headers
    (`2bb32649`);
- Distribution and updates:
  - `test:windows-dev-script` and `test:linux-field-report-contract`: two
    regex spellings of a moved path (`6d807dcd`).

Diagnosed, not fixed yet:

- **`_shared` root successors** (task « root-successor sites »). A shared
  folder S01 scatters, whose nearest new home is `_shared` itself, widens a
  scan or mkdir to the whole shared tree. Example: the `test:linux-package-
setup` fixture makes `_shared/data`, which became `_shared`, then copies into
  `_shared/core/text/data/`, which nobody made (ENOENT).
  - The driver-root rule (list element on its own line → one element per real
    home; elsewhere the name is kept while the folder keeps files; refusal
    when emptied) is committed for driver roots only.
  - Extending it to `_shared` (`Census.TREES` in place of `Census.DRIVERS` at
    the `splitScopeLine` call) gives S01 8 expansions, 11 kept names and 10
    refusals. Each refusal needs a listed edit in `edits.cjs`:
    `linux/tests/hardware/run_ollama_runtime_acceptance.py`,
    `linux/tests/unit/modules/llm/runtime/test_shared_loader_sources.lua`,
    `tools/audit/shared-literal-inventory.cjs`,
    `tools/codegen/codegen-managed-bootstrap.cjs`,
    `tools/diagnostics/macos_ollama_serve_command_receiving_test.py`,
    `tools/diagnostics/notepad-callers.ps1`, `tools/lint/lint-conventions.js`,
    `tools/test/test-macos-python-system-compat.cjs`,
    `tools/test/test-managed-bootstrap-policy.cjs`,
    `tools/test/test-section-decoration-parity.cjs`. Also review the 8
    expansions (the bundle manifest globs, `native_http_clock_evidence.cjs`,
    `audit-file-headers.cjs`) once property lines are excluded (`24b22b12`).
- **Contract vector ledger** (`test:contract-vector-ledger`). It reads each
  contract as `_shared/lua/test/<name>`. S01 spreads the contracts over the
  feature folders of `_shared/tests/lua` and renames some
  (`menu_numbered_caption_contract.lua` → `menu/numbered_caption_contract.lua`);
  its replayer regex expects `require("test.<contract>")`. It needs a design
  change: probably the ledger's `contract` values become paths relative to
  `_shared/tests/lua`, rewritten by a new edits list, and the family filter
  moves off the old name prefixes.
- **Linux, every distro: `native-locale-catalog`**
  (`test_i18n_persistence.lua:66` → `tests/hardware/test_i18n_catalog.py`).
  It fails only on CI (as an ordinary user); locally both trees fail the same
  way. Read the CI artifact `linux-distro-unit-log-<distro>` (the blob host is
  blocked from this container).

Not yet read:

- Common: Ai and network, Shared ui, Input and actions.
- Windows: every AHK unit group (keystats, core, ui, meta, keymap-gestures,
  hotstrings-shortcuts, config-scope-features, config-updater).
- macOS E2E: Managed Ollama (15 Apple silicon and Intel), Launcher XCTest
  (26), Archive update controls (26).
- The verdict jobs follow from these. The jobs list is
  `mcp__github__actions_list list_workflow_jobs 43311674550`; one log tail with
  `get_job_logs job_id`, about 100 lines, shows a lot's failed checks.
- Remaining checks of the Distribution and updates lot:
  `test:windows-control-cli` and `test:windows-field-report-contract` need
  `pwsh` (CI only), and `test:linux-package-setup` is the `_shared` root
  successor above.

### Next actions, in order

1. Extend the root-successor rule to `_shared`, with the listed edits for the
   10 S01 refusals; review the expansions.
2. Fix the contract vector ledger (design above).
3. Read the unread failing jobs one by one, and fix each cause in the
   tooling.
4. Rebuild the proof: run `run-phase2.cjs --to _shared` in a fresh worktree,
   push it to a new `claude/ergopti-todo-structure-phase2-proof-<n>`, and
   dispatch `ci.yml` with `os_lanes=all`. Repeat until only dev reds remain
   (list below).
5. Then S02's proof the same way, then S03 onwards.

### Baseline: the reds dev already has

A red outside this list is the step's (the coordinator, 2026-11-12 22:00).

- Seen in tap-hold run 43294939933 (also red on dev): Windows meta; Linux E2E
  desktop-webview, updater, platform-metrics, input-display; Common Shared ui
  (App Cloner); Common Packaging and boot.
- Seen in Windows run 43291765266: Windows Build AV-surface ceilings; App
  Cloner.

### Decisions to review by the maintainer

- C1, the Windows cohort requalification (decided by the coordinator on
  2026-11-12).
- Folder bounds may rise during a step, named in the commit (`5261cc0d`),
  decided without the coordinator.
- A scattered folder whose nearest home is a tree root (`476e929a`, for driver
  roots), decided without the coordinator:
  - a list element names each real new home;
  - elsewhere the name is kept while the folder keeps files;
  - otherwise the site is refused.

## Next commands

Reproduce a step in a disposable worktree created from this branch's tip
(the runner commits each step there; never in the main checkout):

```bash
ERGOPTI_STRUCTURE_PHASE=2 node tools/audit/structure/run-phase2.cjs \
  --to _shared --receipt /tmp/s01-receipt.json
```

Then push that worktree's HEAD to a new proof branch and dispatch `ci.yml`
(workflow_dispatch, `os_lanes=all`). Compare its red jobs with the baseline
list above. Local JS and Lua runs help only for checks that are not already
red locally.

## Open work, besides the next actions above

- Side task approved by the maintainer: COSMIC `zcosmic_toplevel_info` v2+
  (ext-foreign-toplevel-list announcement) in
  `linux/adapters/cosmic_toplevel_worker.lua`, keeping v1 when only v1 is
  offered. The LuaJIT fake `tests/hardware/run_cosmic_toplevel_fake.lua`
  needs to cover v2+; update the TODO line and `maintainer-decisions.md`.

## Known traps

- `ERGOPTI_STRUCTURE_PHASE=2` is required: without it both `apply-step
--apply` and the runner refuse.
- Fix the tooling, never the stepped output. Every fix is an atomic commit
  with a regression test that fails on the previous tooling.
- `edits.cjs` texts are what files hold before their step, and its `to` texts
  hold the new spelling, since a placeholder blocks later rewrites inside them.
- A scattered folder whose nearest successor is a tree root must never widen
  a glob or scan scope to that tree. Driver roots follow the root-successor
  rule; `_shared` still widens (next action 1).
- Before reusing a worktree, stop every process still running in it: a stale
  measurement once wrote into a tree the next step was being applied to.
- Local Linux and macOS runs are root, with no `pwsh` and no Windows; about
  120 JS checks are red locally on dev itself, so they prove nothing there.
- `repin.cjs` re-pins whole-file hashes automatically. A hash of a derived
  value needs a `DERIVED_PINS` entry, and the runner records its pre-step value
  with the tree's own tools (`repin.cjs --derive-out`).
- The JavaScript CI lanes have no Ruff. A Python line that the formatter
  re-wraps after a step can only be checked by the gate that reads it.
- Some tools read Lua through `tools/lib/config-key-source-view.cjs`, which
  patches `fs.readFileSync`. A hash of such a source is a hash of the expanded
  view.
- The full Linux Lua suite takes longer than a two-minute shell timeout. Run
  it in the background, or filter it with `luajit tests/run.lua --only <name>`.

## Regenerating the move map

`docs/design/structure-plan/move-map.tsv` and the other appendices come from
the Git index:

```bash
npm run audit:structure-plan
```

Run it after every dev merge. A file that moved on dev, such as `check_notice`
now under `_shared/lua/updater`, otherwise keeps its old row.
