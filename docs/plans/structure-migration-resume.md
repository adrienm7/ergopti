# Structure migration: resume point

This file is the single place to resume the phase 2 structure migration
(docs/design/structure-plan.md) from this branch alone. It is updated in the
same commit as each step or checkpoint. Times are Paris time.

## Where things stand (2026-11-12, 21:45)

- Branch: `claude/ergopti-todo-structure-phase2`. It is pushed fast-forward
  only and never rebased. A rebase would go to
  `claude/ergopti-todo-structure-phase2-night`.
- Base dev commit of the tooling: `5755f454` (merge base with `origin/dev`).
  `origin/dev` is now at `3ec911b1`; the branch has not merged it yet.
- Steps landed: none. The migration itself is not authorized to land on dev.
  This branch carries only the tooling that makes each step apply green.
- Step in progress: S01 (`_shared`, 867 moves, about 17 000 references in
  about 4 900 files). It applies cleanly with every format, lint and codegen
  gate green.
- Measured against the dev baseline:
  - the 34 JS checks that were new reds: 1 red left on `3e4e387d` (the shared
    helper ratchet), fixed by `b4659a72`;
  - Linux and macOS Lua groups: 0 new reds at the last full cycle.
- In progress: a full cycle on `b4659a72` (whole JS suite and both Lua
  drivers' groups, S01 applied by the runner). When it shows no new reds, S01
  is green locally. Windows is then proven on CI.
- Decision C for the Windows cohort pins is implemented as C1 (`9e01a8e0`).
  The (c) frames are the owner's input, not its output, so they are
  requalified, not regenerated. C1 was decided by the coordinator on
  2026-11-12, to review by the maintainer:
  - `edits.cjs` `REQUALIFIED_PINS` lists the five receipts;
  - `repin.cjs` records each old→new pin there, with the move that justifies
    it, and fails fast on a pin there it cannot attribute (a file the step
    removed, a hash shared by files the step made different, a derived pin);
  - the runner writes a "Requalification" section into the step commit.

## Next commands

Reproduce S01 in a disposable worktree created from this branch's tip:

```bash
ERGOPTI_STRUCTURE_PHASE=2 node tools/audit/structure/run-phase2.cjs \
  --to _shared --receipt /tmp/s01-receipt.json
```

The runner commits the step in that worktree. Then:

1. Run the JS feature checks and compare failing check ids with a run of the
   same checks on the base commit. The goal is no new reds.
2. Run the Linux and macOS Lua groups the same way.
3. Run Windows through `ci.yml` workflow_dispatch with
   `os_lanes=windows,macos,linux` on a proof branch rebuilt from dev
   (`claude/ergopti-todo-structure-phase2-proof`).

## Open work, in order

1. S01: re-measure the JS new-reds and fix any left in the tooling
   (`tools/audit/structure/plan.cjs`, `apply-step.cjs`, `edits.cjs`,
   `repin.cjs`), never in the stepped output.
2. Coordinator decision C for the Windows cohort pins, done as C1 except the
   TODO line, which waits for dev's TODO split (TODO.md + TODO-tests-\*.md).
   The original request:
   - classes (a) and (b), the review and generated-source pins: `repin.cjs`
     re-pins them, as it does today;
   - class (c), `tools/ci/windows-key-combination-cohort-original-inputs.json`,
     `tools/ci/windows-updater-original-diagnostic-cohort-inputs.json` and
     `tools/test/portable-control-inputs.json`: regenerate them through their
     owner, `prepare_windows_key_combination_cohort_inputs.py`;
   - class (d), `LEGACY_SHA` in that owner and `OLD` in
     `test_windows_key_combination_source_roster.py`: re-anchor them only as
     an explicit requalification, in a section of the step's commit body
     listing each old→new pin and its move-map entry;
   - `repin.cjs` must fail fast on any 64-hex match in a (c) or (d) file;
   - add the TODO line « requalify the Windows key-combination and updater
     cohorts on the real PC after the structure migration », outside « To
     confirm on the Windows PC ».
3. Merge the latest dev, regenerate the move map (below) and re-measure.
4. S02 onwards, one step at a time, CI only at step boundaries.
5. Side task: COSMIC `zcosmic_toplevel_info` v2+ in
   `linux/adapters/cosmic_toplevel_worker.lua`.

## Known traps

- `ERGOPTI_STRUCTURE_PHASE=2` is required: without it both `apply-step
--apply` and the runner refuse.
- Fix the tooling, never the stepped output. Every fix is an atomic commit
  with a regression test that fails on the previous tooling.
- `edits.cjs` texts are what files hold before their step, and its `to` texts
  hold the new spelling, since a placeholder blocks later rewrites inside them.
- A scattered folder whose nearest successor is `_shared` must never widen a
  glob or scan scope to the whole tree. Such sites are listed edits or
  refusals.
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
