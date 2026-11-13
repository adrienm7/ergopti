# Structure migration: resume point

This file is the single place to resume the phase 2 structure migration
(docs/design/structure-plan.md) from this branch alone. It is updated in the
same commit as each step or checkpoint. Times are Paris time.

## Where things stand (2026-11-13, 03:00)

- Branch: `claude/ergopti-todo-structure-phase2`, fast-forward only. Base:
  dev `520bb24c`, merged in `ee1aa96f`.
- Steps landed on dev: none. The migration is not authorized to land yet.
- **S01 is NOT green on CI yet.** The last proof, run 43311674550 on
  `claude/ergopti-todo-structure-phase2-proof-2` (`244ef275`), had 28 failing
  jobs. The fixes below are on the branch; a new proof
  (`claude/ergopti-todo-structure-phase2-proof-3`) is being built from
  `91b3a046`. About 120 checks are red locally on dev itself (root user, no
  `pwsh`, no Windows), so **measure S01 by CI, not locally.**
- S02 (`core/crypto`) applies locally on top of S01 and has no CI run yet.
  Its own new local reds, not yet read: js-0035, js-0241, js-0253, js-0280,
  js-0281, js-0441; macOS meta (3), macOS modules (1).

### S01 CI failures (run 43311674550) and their state

Fixed on the branch (each with its commit):

- plan refs in source (`2bb32649`); dev-script and Linux field-report
  regexes (`6d807dcd`); package fixture mkdir (`224b6c89`);
- Windows proxy relay bundle: Go module path kept (`f7130e9c`, `40acfe64`)
  and its derived fingerprint (`efb60d94`); proxy policy reader
  `Path(__file__)` (`fe1cf7c5`); feature requirements driver keys
  (`40acfe64`); cohort frame pin chain across runner rounds (`29206850`);
- every Windows AHK unit group: backslash climbs (`\..\..\_shared\…`) were
  read as regex escapes or against the shared Lua root (`1c231ac1`); four
  fixtures listed their staging folders apart from their files (`67eb94ff`);
- contract vector ledger: contracts named by repository path (`a670f896`)
  and the family carried through S01 by a listed edit (`91b3a046`).

Open, to check on the next proof:

- Linux, every distro: `native-locale-catalog` (CI only; read the artifact
  `linux-distro-unit-log-<distro>`, the blob host is blocked here).
- macOS E2E: Managed Ollama, Launcher XCTest, Archive update controls.
- Windows `control-cli-native-session` (core group) and Windows meta
  `hotif-globals-boot-safe`: probably dev reds; compare with a dev run.
- The `_shared` root successors (10 refusals if the driver-root rule is
  extended to `_shared`); kept as targeted listed edits for now.

### Next actions, in order

1. Push the new proof to `claude/ergopti-todo-structure-phase2-proof-3` and
   dispatch `ci.yml` with `os_lanes=all`; fix what is red outside the dev
   reds, in the tooling.
2. Then S02's proof the same way, then S03 onwards.

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
- A Go module path stays as written when its folder moves (`f7130e9c`):
  it names the module, and respelling it would change every committed binary.
- Files with driver sections (`DRIVER_SECTION_FILES`, `40acfe64`): keys of
  `[detection.<driver>.…]` resolve against that driver.
- The contract ledger's family is listed per folder, with names excluded
  where S01 mixes the family with its neighbours (`91b3a046`).

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
now under `_shared/updater/engine`, otherwise keeps its old row.
