# Structure migration: resume point

This file is the single place to resume the phase 2 structure migration
(docs/design/structure-plan.md) from this branch alone. It is updated in the
same commit as each step or checkpoint. Times are Paris time.

## Where things stand (2026-11-14, 03:50)

- Branch: `claude/ergopti-todo-structure-phase2-night`, fast-forward only,
  rebased on dev `42f8c1327`. Never merge dev into a branch: rebase it, so
  each block lands linear (dev refuses merge commits). The old branch
  `claude/ergopti-todo-structure-phase2` is frozen; nothing more is pushed
  there.
- Steps landed on dev: S01+S02 (dev `520bb24c8..42f8c1327`, landed by the
  coordinator, its two flaky reds accepted). Next block: S03–S05, built on
  the night branch.
- S03–S05, proof 16 (run 43481259457): reds beyond the baseline in 7 Common
  JS jobs, Windows unit core and meta, Linux E2E network-ai. Local triage
  (full JS suite and both Lua suites against the night tip, which matches the
  baseline exactly) found these causes, all fixed on the night branch:
  - tools that name their driver as `path.join(root, 'macos')`, a variable
    driver piece, a single driver, a regex-escaped module or a
    `rawget(<alias>, "a.b")` key (`f0501dbc`, `325e8497`, `5a2605ef`,
    `20195e69`, `5f420497`); Lua tools proved by their requires
    (`1b5bfed2`); module prefixes completed by test helpers refused
    (`902adaa3`);
  - folder-gain lists written one element per line or as `(?:a|b)`
    (`abd4e8c4`, `5d9ce9e2`); fixture mkdir ladders (`e269c4a3`);
  - an included AutoHotkey test's `A_ScriptDir . "\..\x"` climbs from
    windows/tests (`8ac047d6`);
  - listed edits for synthetic or piece-wise paths: config migration vectors,
    path resolver source and folder chain, hs.fs.dir wrapper, port wiring join,
    locale layouts, input probe includes, i18n boot folder, network runtime
    tree, OS-purity exemption (`82519f95`, `0d741678`, `4ca11e1d`, `13f0012f`,
    `ef39e799`, `bcc05405`, `eadf5853`, `968a7315`, `00fb8335`, `c6901bc1`);
  - small test-source changes in the same spirit as the predicate: adapter
    compliance names modules and ports (`b84c04d6`), the compile guard's
    roots are counted from its table (`4006af3b`), the read interlock child
    mirrors its include layout at any depth (`cc1bae45`);
  - the shared literal baseline moves with a step, named in its commit
    (`84cebf24`).
- Proof 19 (S03–S05 on the tip): both Lua suites match the baseline
  exactly (the logger order leak is gone). Windows AHK changes are
  unverified locally (no AutoHotkey here); CI is their proof.
- Proof 21 (`…-proof-21` at `86de9408`, run 43514443381, S03–S05 on dev
  `ed5adcad`): two reds beyond the baseline, both fixed on night since:
  - Data and source contracts: the path-forms check expected the OS-purity
    edit again on a tree where it had landed, because that edit appends to
    its own text (`3d0d23e2`);
  - Windows unit core: the read interlock child copied the reader's ports
    sibling by its old name, file_system_ports.ahk (listed edit `3838a95a`).
- S06–S08, built locally on the S05 tip: both Lua suites match the
  baseline (six Linux case names embed the moved module path). The JS suite
  had 14 new reds, all fixed on night (`93ec1adc`..`812b987b`):
  - tools naming the Windows driver now follow its .ahk paths;
  - a bare Python `Path(__file__).parents[n]` in a moving file is recounted;
  - regex-escaped tool paths (`infra\/x\.lua`) follow their unique tail;
  - a scan list gains each new home once, never nested under another;
  - a join onto a scattered folder no longer widens to the driver root;
  - listed edits: the opaque admission fixture, the flatpak probe's
    installed path (`/app/lib/ergopti/…`), its portable runtime fixture;
  - five Linux tests find the network probes by module name.
- Installed-tree paths (`lib/ergopti/<driver-relative>`) are not read by
  the plan; later steps that move `ui/dialog_host.lua` or
  `modules/updater/manager.lua` need listed edits for those sites.
- A second S03–S08 build found four more tool paths (a `windows\\x\.ahk`
  regex, an `#Include` string in a tool naming `'windows/…'`, a bare path
  one named Lua driver holds, the source-run owner's joined pieces), fixed
  in `943d30cb`.
- Proof 22 (S03–S08, `…-proof-22` at `51601507`, run 43538289052): not
  landable. New reds, all fixed on night since (`75849616`..`ef524691`):
  - Windows unit meta: base-name lookups of a renamed file
    (`_DriverFileSource("network_info.ahk")`), folder scans of a folder the
    step takes files out of (`_DriverDirConcat("infra")`, now expanded to
    `_DriverDirsConcat(folder, homes…)`); three more meta failures fell
    outside the 5000-line log window and the artifact host is blocked here;
  - Windows unit core: fixture writes into a folder no DirCreate makes, and
    an `A_LineFile` climb in a test that moved deeper;
  - Ai and network: the trusted guardian controls stage the receiver on a
    base the plan cannot read (listed edit). A local check red in the
    baseline hid it: compare error tails of baseline-red checks too.
- S09–S12 built locally on the S08 tip: 14 JS and 6 Lua reds, fixed on
  night (tool regex and suite paths, join shape, driver-keyed blocks, gain
  scope, listed edits, role-based UI and adapter partitions in macOS meta).
- Later steps need listed edits once their input text exists: S14 (the two
  AT-SPI workers in `literal_appdir_contract.py`), S30 (`wpm_surface` in
  the focus audit's overlay detector).
- **Next: proof 23 = S03–S12 rebuilt from the night tip**, dispatched once
  run 43538289052 has finished (one run at a time); land if only baseline
  reds, as for every block.
- **The real dev baseline is run 43309556011** (dev `520bb24c`, all lanes).
  Its only reds: Common Shared ui; Linux E2E desktop-webview, updater,
  input-display, platform-metrics; Windows Integration Driver startup (and
  the verdicts). Any other red on a proof is the steps'.
- Proof 5 (S01+S02, run 43366970653): 13 red jobs, 7 of them the steps'.
  Fixed since: hotstrings tails (`9a4f62ce`, `b5e4b75a`), the PAC paths
  fixture (`607b4f91`), the Linux XI2 receiver (`d61082f5`), constant
  concatenation when the constant's own folder moves (`1d783d68`).
  Unexplained: Common Ai and network (`test-managed-ollama-protocol`, CI
  only), macOS Launcher XCTest (green on dev), macOS Archive update controls.
- Proof 6 (S01–S38, branch `…-proof-6` at `3270b5dd`, run 43396604286): 46
  red jobs, from two causes:
  - Windows: every AHK lane stops in `build_windows_nav_owner.ps1`, whose
    manifest fingerprint covers the moved sources' paths. Now a derived pin
    (`93ffa01c`).
  - macOS and Linux Lua: files that reach their driver root by naming or
    counting their folders (the menu manifest readers, the Karabiner lease
    helper, the Linux webview manager). Listed edits (`b0b78a2b`). Chains of
    `dir = NativePath.dirname(dir)` and nested `dirname(dirname(…))` were
    already followed by the tooling.
- Proof 7 (S01+S02, `3c4cf6ad`, run 43413113897): 16 red jobs, 5 outside
  the baseline, all fixed since:
  - Test infrastructure: the isolated platform gate lacked
    `tools/lib/driver-roots.cjs` and `_generated` markers (`dd48b0e7`);
  - Ai and network: the native HTTP worker's historical pin names the moved
    proxy policy (`119073d0`);
  - Linux E2E network-ai: a Python f-string LUA_PATH (`a523295c`), Go tests
    joining `..` from their package folder (`c1c66474`), the network fixture's
    staged modules (`1d9f811e`);
  - macOS Launcher XCTest and Archive update controls: a Ruby `require
"json"` respelled as a Lua module (`a8ebd6dc`), the locales climb in
    CatalogUpdateUserDriverTests (`7d880ab7`).
- Proof 9 (S01+S02 from `7d880ab7`, `…-proof-9` at `475a6374`, run
  43421949833): one red outside the baseline, Common Ai and network. The
  serve-command receiving test copies `_shared/python`, which S01 splits into
  the ai and network features; now a listed edit names both homes
  (`677fc455`). Every other red matched the baseline.
- Proof 10 (S01+S02 = `319d5efe..a1063539` on `677fc455`, run
  43430776650): Ai and network green; only extra reds were the macOS Intel
  managed Ollama build (Go test
  `TestCancellationAndConcurrentClosePhysicallyRetirePeer`, passed on proof 9
  with the same sources) and its runtime job. Attempt 2 (failed jobs re-run):
  both Intel jobs green; the only other red, macOS Install and launch "Cold
  native bootstrap", stalled 46 min in its build step with no log (job
  131947368406), while proof 9 passed it in 4 min (job 131893758591). Sent to
  the coordinator for the flake call and landing at 16:50.
- S01's output leaves two no-op sweep terms (`^dynamic_hotstrings%.` in
  Linux `test_dynamic_dry_run_dispatch.lua`, `^logger%.` in macOS
  `test_resolver_lifecycle_admission.lua`): clean them once S01 is on dev.
- Since proof 10: the prefix-sweep refusal (`585d7fe1`), the shared
  `is_driver_module` predicate in both drivers' test helpers with 35 sweeps
  converted (`1f56b340`; both Lua suites identical to the baseline), no live
  scope widened to the folder above a scattered one (`1035e4a4`: the CI shard
  groups' `tests/unit/infra`), and a shared file's path under a driver root
  follows its file (`6992c426`: the config migration's file-system adapter
  check, which refused every migration after S04).
- Proof 12 (S03–S05 on proof 10 plus those commits, in `wt-proof`): building,
  then both Lua suites against the baseline.
- Full chain locally (proof 8, S01–S38 from `267cc01a` in `wt-proof`), Lua
  suites against an unstepped tree (`scratchpad/{base,p8}-{macos,linux}-lua.log`):
  1,152 new failing macOS cases in 145 modules, 911 Linux cases in 92
  modules. Main classes: module-prefix sweeps and dissolved scan roots (see
  « Decisions to review »), a few unfollowed `require` names
  (`modules.shortcuts`), then a long tail to triage per module
  (`scratchpad/triage-{macos,linux}.txt`).
- Later steps, found on proof 6 locally (macOS and Linux Lua suites): init
  modules named with their stem (`3ef3fc4a`), the macOS keyboard data readers
  and the Linux tray source reader (`1b0998e0`), a climbing `Paths.shared`
  argument (`62e49843`), the flush bridge test (`267cc01a`).
- Proof 8 (S01–S38) is being built in `/home/user/wt-proof` from `267cc01a`
  (log `scratchpad/proof8-run.log`) for local Lua runs; rebuild it from the
  tip before its CI run.

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
- Linux `native-locale-catalog`: the probe's stand-in for the order file
  no longer matched since `83ea401b` (a branch commit, not dev); fixed in
  `2627e45d`. Reproduce as a non-root user (`runuser -u nobody`).

Open, to check on the next proof:

- macOS E2E: Managed Ollama, Launcher XCTest, Archive update controls.
- Windows `control-cli-native-session` (core group) and Windows meta
  `hotif-globals-boot-safe`: probably dev reds; compare with a dev run.
- The `_shared` root successors (10 refusals if the driver-root rule is
  extended to `_shared`); kept as targeted listed edits for now.

### Next actions, in order

1. Proof 7 on CI; send the coordinator the S01–S02 range when only baseline
   reds remain, else fix in the tooling and rebuild.
2. Fix what the local Lua suites still find on the full chain, then build
   proof 8 (S01–S38) from the tip and run it with `os_lanes=all`.

### Baseline: the reds dev already has

A red outside this list is the step's (the coordinator, 2026-11-12 22:00).

- Seen in tap-hold run 43294939933 (also red on dev): Windows meta; Linux E2E
  desktop-webview, updater, platform-metrics, input-display; Common Shared ui
  (App Cloner); Common Packaging and boot.
- Seen in Windows run 43291765266: Windows Build AV-surface ceilings; App
  Cloner.

### Maintainer decisions

- 2026-11-13, via the coordinator: module-prefix sweeps
  (`name:match("^modules%.")`) and dissolved folders used as scan roots are
  refused by the tooling (fail fast). Each site gets a listed edit, and the
  repeated "every driver module" sweeps become one shared predicate over the
  driver's production roots, with a regression test that can fail. Found on
  the full chain (178 sweep sites in 71 files, about 131 scan-root sites);
  an exact rewrite is not viable (`^modules%.` on macOS alone becomes 20
  prefixes and 48 names).
- 2026-11-13: land in small blocks: S01+S02, then S03–S05 and so on, each
  once its CI shows only baseline reds. A flaky-looking red is reported with
  both run ids; the coordinator judges flake or real.

- 2026-11-13, approved: the navigation owner fingerprint is a derived pin
  (`93ffa01c`); the DLL byte-identity check is tracked in
  TODO-tests-windows.md.
- 2026-11-13, 22:06: I land my own green blocks on dev (rebase linear, tree
  check, no merges, no trailers, gates, `git push origin HEAD:refs/heads/dev`)
  and send the coordinator one line (range, CI run). Dev moves often: rebase
  onto origin/dev before each proof and re-run a step where its moves meet
  new files.
- Worker G owns the Linux updater's shared-root probe
  (`infra/paths.lua` SHARED_PROBE_FILE, `install/ownership_schema.sh`
  OWNERSHIP_SHARED_SENTINEL, `_shared/data/locales/en.json` kept in the
  tarball): never change those here; if a step moves them, rebase over G's
  landing and keep G's behavior.

### Decisions to review by the maintainer

- The OS-purity ratchets exempt adapters/ by folder; S02 and S03 put three
  former adapters in core/ without one (core/crypto/crypto.ahk,
  core/events/boot_clock.ahk, core/events/timer_scheduler.ahk) while S03 adds
  core/ to the scan. A listed edit keeps their exemption by name (`c6901bc1`)
  instead of raising the baselines.
- The shared literal inventory (Rule A) baseline moves with a step under the
  runner, named in the commit like the folder bounds (`84cebf24`): S05 brought
  both drivers' i18n `scope_ready` to one spelling, an existing duplicate.

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
- Folder gains (`ffe92aff`, `1e98ba49`): a list or regex alternation of a
  driver's sibling folders that names the folder a step's file leaves also
  names the folder it moves into (adapters → core). This widens deliberately
  narrow scanners too (the OS-purity lists, the platform-only convention).
- The runner moves the I1 tree parity records (`57869cd5`) to the measured
  values at each step, named in the commit with the folder bounds.

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
