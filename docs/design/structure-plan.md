<!-- docs/design/structure-plan.md -->

# Structure plan: shared values and one driver tree

Maintainer request of 2026-11-11. Phase 1 (this document, its generated
appendices, the measurement tools and two ratchets) is a plan only: several
sessions and the maintainer's Windows work are changing the driver trees, so
no driver file moves yet. Phase 2 applies the plan step by step once the
coordinator says go, after the AHK and Linux/macOS feature work in flight has
landed.

Every choice below that the request left open was decided by the coordinator
on 2026-11-11, to review by the maintainer. They are collected in
[Decisions to review](#decisions-to-review).

## The two rules

**Rule A — everything common lives in `_shared`.** Each OS folder holds only
its implementation. Configuration variables and defaults, colours, delays,
timeouts and durations, thresholds, counts, sizes and limits, path names,
enum, reason and key names live once in `_shared`; so does every user-facing
text, translated in every locale (the `i18n` skill), and every piece of logic
that is not OS-specific (parsers, rule engines, matchers, formatters, state
machines, data tables).

**Rule B — one simple, logical tree in every OS folder.** Knowing the Windows
tree means knowing the macOS and Linux trees: same folder names, nesting and
module split. A module that is OS-specific exists only where it belongs,
under a name that says so. No folder holds fewer than 2 or more than 20
entries (40 in tests); `_shared` mirrors the same names.

## Findings in numbers (measured 2026-11-11 on `dev` at 6fec42de)

| measurement                                                            | value                                                                                                                                                                                                           |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| tracked files under the four trees                                     | 10,066                                                                                                                                                                                                          |
| Rule B: code folders over 20 entries                                   | 28 (worst: `_shared/lua` 113, `linux/infra` 112, `windows/infra` 109, `macos/adapters` 92, `macos/infra` 89, `macos/modules/llm` 68, `windows/modules/keystats` 66, `windows/adapters` and `linux/adapters` 58) |
| Rule B: code folders with one entry                                    | 54, plus 22 that mirror a real folder on another driver                                                                                                                                                         |
| Rule B: test folders over 40 entries                                   | 17 (worst: `linux/tests/hardware` 322, `windows/tests/fixtures` 235, `_shared/lua/test` 202, `macos/tests/support` 137)                                                                                         |
| Rule B: layer and domain folders on one or two drivers                 | 21 (32 at every depth)                                                                                                                                                                                          |
| Rule B, after the plan: code folders over 20 / with one entry          | 5 (all `_shared` data catalogues) / 13                                                                                                                                                                          |
| Rule B, after the plan: layer and domain folders on one or two drivers | 11, every one declared OS-specific or shared from `_shared/lua`                                                                                                                                                 |
| plan size                                                              | 3,071 moves in 50 steps, 4 retired README markers, 37,131 reference rewrites                                                                                                                                    |
| Rule A: hand-typed values in production driver source                  | 1,927 (Windows 644, macOS 786, Linux 375, and 122 macOS/Linux logic pairs)                                                                                                                                      |
| Rule A: constant names declared on two or three drivers                | 54, 13 of them with different values                                                                                                                                                                            |
| Rule A: Lua functions or tables both Lua drivers carry                 | 104 functions, 18 data tables                                                                                                                                                                                   |
| hardcoded UI strings at display call sites                             | 0 (the `test-no-hardcoded-ui-strings` baseline is empty)                                                                                                                                                        |

## Rule A: inventory

`node tools/audit/shared-literal-inventory.cjs --write` scans every production
`.ahk` and `.lua` file of the three drivers (tests, `vendor`, `_generated`, the
Swift launcher and the bundled apps excluded) and writes:

- [rule-a-inventory.tsv](structure-plan/rule-a-inventory.tsv): one row per
  item, `file`, `line`, `kind`, `name`, `value`, proposed shared home,
  proposed name and mechanism;
- [rule-a-duplicates.md](structure-plan/rule-a-duplicates.md): the names
  declared on two or three drivers, and the Lua logic macOS and Linux both
  carry;
- [rule-a-gates.md](structure-plan/rule-a-gates.md): the existing
  single-source and tree gates, how strict each is, and whether CI runs it.

The detectors are lexical and over-report on purpose (a reviewer drops a false
positive faster than a scanner finds a missed copy). A file's own identity
(its log tag, owner name, driver name) is not counted. The proposed name is
`[<target domain>] <lower_snake_name>`, the target domain being where the
structure plan puts the file.

### Kinds, homes and mechanisms

| kind                                                 |              count | shared home                                                                   | mechanism                                                                      |
| ---------------------------------------------------- | -----------------: | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| duration (`*_MS`, `*_SEC`, `*_TIMEOUT`, …)           |                539 | `_shared/modules/timings/constants.toml`                                      | shared data file read at boot (`Timings.ms/sec`, `TimingsGet`)                 |
| bare timer delay (`SetTimer`, `Sleep` with a number) |                 18 | the same registry                                                             | shared data file; the call names a registry key                                |
| limit, size, count, threshold                        |                414 | `constants.toml [limits]`, or `_shared/modules/<domain>/constants.toml`       | shared data file                                                               |
| colour                                               |                  4 | `_shared/data/native_theme.toml` (native), `_shared/ui/theme_tokens.js` (web) | shared data file                                                               |
| path, file and bundle name                           |                174 | `_shared/data/identifiers.json`                                               | generated constant (`codegen-identifiers.cjs`)                                 |
| enum, reason, key name                               |                656 | `_shared/modules/<domain>/*.json`                                             | generated constant table that raises on an unknown name, as `config_keys` does |
| Lua function both Lua drivers carry                  |                104 | `_shared/lua/<target domain>/`                                                | one Lua module both drivers require                                            |
| Lua data table both Lua drivers carry                |                 18 | `_shared/modules/<domain>/*.json`, or `_shared/lua/<target domain>/`          | a data file when AHK needs it too, else one Lua module                         |
| user-facing text                                     | 0 at display calls | `_shared/data/locales/*.json`                                                 | the `i18n` skill, every locale                                                 |

**Which mechanism for AHK.** AutoHotkey cannot require Lua, so logic shared
by the three drivers takes one of two forms: a data file every driver reads
at runtime (the timing registry, the menu manifest, `behaviors.json`), or a
generated AHK source (`windows/_generated/`, as `config_keys.ahk` already is).
A data table that all three use is a data file; a rule engine whose rules are
data is a data file plus three small interpreters; a closed name set is a
generated constant. Lua-only logic is one `_shared/lua` module.

### Biggest duplicates

- **Layout registry and emulation** (`modules/keymap/layout_registry.lua`,
  `layout_emulation.lua`, `composer_check.lua`): 14 identical or near-identical
  functions on macOS and Linux (`shipped_layout`, `with_source`,
  `read_shared_json`, `sha256_text`, `extension_roots`, …). Home:
  `_shared/lua/modules/layout/`.
- **Field run** (`infra/field_run.lua`): 10 shared functions. Home:
  `_shared/lua/infra/field_check/`.
- **Remote LLM API** (`modules/llm/api_remote.lua`): 6. Home:
  `_shared/lua/modules/llm/api/`.
- **Window bridges** (`ui/healthcheck`, `ui/error_dialog`, `ui/onboarding`,
  `ui/physical_shortcuts`): identical `init_message`, `failure_contract`,
  `retire_observation`. Home: one `_shared/lua/ui/shell/` bridge helper.
- **Updater boot readiness**, **process lifecycle callbacks** and
  **keyboard shortcut defaults**: 3 to 4 functions each.
- **Constants**: `NS_PER_MS`, `MS_PER_SEC`, `POLL_SECONDS`,
  `ACCESS_RETRY_SECONDS` and the `FAILURE_*` reason names are typed on both
  Lua drivers with the same value; `MAX_DEPTH` is 64, 128 or 32 depending on
  the file and driver; `USER_AGENT` differs per driver by design and belongs in
  `identifiers.json` with one entry per driver.

### Existing gates and where they are lenient

[rule-a-gates.md](structure-plan/rule-a-gates.md) lists 130 gates. CI runs
all of them. The leniencies that matter for Rule A:

- `test-duplicate-constant-names` sees only a name declared in two files,
  only for `*_MS`, `*_SEC`, `*_TIMEOUT`, `*_MAX` and `*_BYTES`; a copy under
  another name, or the same value under two names, passes. 22 names are
  tolerated.
- `test-timings-registry-liveness` checks that registry keys have readers, not
  that driver literals read the registry; `limit-literal-baseline.json` covers
  `*_BYTES` only.
- `test-no-hardcoded-ui-strings` is strict but only at display call sites; a
  string built into a variable before the call passes.
- `test-logger-scalars-single-source`, `test-tooltip-*`, `test-wpm-*` and the
  other per-value `*-single-source` gates each pin a named list; nothing finds
  a new value outside the lists.
- `test-shared-lua-helpers-single-use` covers copy, trim, quote and
  percent-encode only; no gate compares Lua function bodies across the two Lua
  drivers.
- `test-driver-tree-parity` measures directories down to depth 2 with a
  floor and a union ceiling; it does not see folder sizes or depth 3.

Missing until today: a count of hand-typed values per driver and kind, and a
cross-driver logic comparison. The new ratchet
`tools/test/test-shared-literal-inventory.cjs` holds both counts (baseline
[shared-literal-inventory-baseline.json](../../tools/test/shared-literal-inventory-baseline.json));
no count may rise, and one that falls must be lowered in the same change.

### Rule A order of work

1. Values both Lua drivers type identically, and the logic pairs at
   similarity 1.00, starting with the layout registry: one `_shared/lua`
   module each, both drivers require it (macOS and Linux only, no AHK risk).
2. Durations and limits into the timing registry, driver by driver, each with
   the registry read and the baseline lowered.
3. Enum and reason names into generated constant tables, one domain at a time.
4. Path and identifier names into `identifiers.json`.
5. AHK logic that mirrors Lua: a data file first, codegen when the logic is
   a closed set.

Rule A moves values, Rule B moves files; they are independent and can
interleave, but a Rule A migration of a module waits until that module's
Rule B step has landed, so the shared home already has its final path.

## Rule B: current trees

[current-trees.md](structure-plan/current-trees.md) shows the architecture
folders of the three drivers side by side to depth 3 with their entry counts,
then every folder outside the bounds and every folder on one or two drivers
only.

The causes are few. `infra/` and `adapters/` are flat on every driver (89 to
112 entries), the tests of those folders already use domain names the code
does not (`tests/unit/infra/config`, `logger`, `lifecycle`, …). `ui/` holds 30
to 45 entries because every window is a direct child. Windows keeps the
hotstring engine in `infra/hotstrings`, the others in `modules/hotstrings`.
The layout feature, canonical in `_shared/core/features.json`, is spread
through `modules/keymap`. `_shared/lua` has 60 folders and 60 flat files of
its own vocabulary.

## Rule B: target tree

The top level stays the layers every driver already has; only what breaks
the bounds or the parity moves. The rules are data in
[tools/audit/structure/rules.cjs](../../tools/audit/structure/rules.cjs),
so a file created after this plan lands where its siblings land.

```text
<driver>/                    windows, macos, linux: the same names
  README.md, entry point     ErgoptiPlus.ahk | init.lua | ergopti_hotstrings.lua
  _generated/                codegen output (its generator owns the split)
  adapters/                  native implementations of the shared ports
    clipboard/ diagnostics/ focus/ input/ network/ processes/ storage/ system/
  infra/                     runtime services
    config/{migration,publication,scope,preferences}/ field_check/ file_system/
    i18n/ input/ lifecycle/{reload,shutdown}/ logger/ menu/ network/
    text/{toml}/ ui/
  modules/                   features the user operates (features.json names)
    actions/ diagnostics/ dynamic_hotstrings/ gestures/
    hotstrings/{engine,catalogue}/ keymap/
    keystats/{reader,journal,walker,capture,apps,system,privacy,context,ui}/
    layout/ llm/{api,ollama,local_servers,bootstrap,prediction,agent,settings}/
    shortcuts/ updater/
  platform/                  OS integration seams
    network/ remap/{tap_hold,keys,runtime,layers}/ tray/
  ui/                        what the user looks at
    menu/{engine,features,hotstrings,keyboard,llm,transactions}/
    panels/                  changelog, update_check, download_window, model_browser,
                             healthcheck, field_check, onboarding, config_cleanup,
                             metrics_apps, metrics_typing
    editors/                 layer_editor, layout_manager, hotstring_editor,
                             hotstrings_config_window, personal_info_editor,
                             paths_editor, prompt_editor, physical_shortcuts, action_picker
    dialogs/                 error_dialog, proxy_override, gesture conflicts, offers, prompts
    overlays/                tooltip, wpm
    shell/                   webview hosts, console window, log openers
  native/ data/ apps/ vendor/
  tests/{unit,meta,integration,…}/   mirror the code paths above
                             fixtures/ support/ hardware/ split by feature

OS-specific, by name and on one driver only:
  macos/launcher/                     the Swift host application
  macos/platform/remap/data/          Karabiner remap data
  macos/ui/dialogs/permission_dialog  the TCC grant walkthrough
  linux/install/                      shell installers (bin/ folds into it)
  linux/platform/desktop_focus/       GNOME Shell and KWin focus readers
  linux/native/archive_output/        the updater's O_TMPFILE publication
  linux/ui/dialogs/{numeric,token}_prompt
  windows/native/{keyboard_layout,nav_event_owner}/
  windows/ui/overlays/spotlight

_shared/                     the same names one level down
  lua/{infra,adapters,modules,platform,ui}/<same domain>/   both Lua drivers
  ui/{panels,editors,dialogs,overlays,menu}/<window>/  ui/lib/   web pages
  modules/<feature>/ data/ core/ go/ python/ ahk/ keymap/ tap_hold/   unchanged
```

[target-tree.md](structure-plan/target-tree.md) is the same side-by-side view
after the moves, with the residual folders and the asymmetries left.

Four rules produce it:

1. **Domains.** A flat `infra/` or `adapters/` file goes to the domain its name
   says, with one vocabulary for the three drivers and `_shared/lua`. Two
   domains change layer: diagnostics (crash report, snapshot, issue report)
   joins `modules/diagnostics`, which every driver already has, and the
   Windows hotstring engine joins `modules/hotstrings`.
2. **Groups.** `ui/` groups its windows into six groups; an oversized feature
   folder (`keystats`, `llm`, `ui/menu`, `platform/remap`,
   `modules/hotstrings`, `infra/config`, `infra/lifecycle`) splits into named
   sub-modules, the same names on every driver.
3. **Singletons.** A code folder left with one file becomes that file in its
   parent, named after the folder (`init.lua`, `bridge.lua` take the folder
   name, so `require("ui.panels.changelog")` names the window). Parity wins
   over this rule: a folder that is real on another driver stays a folder on
   all three (`linux/ui/panels/changelog/bridge.lua` mirrors the two-file
   Windows folder). A test folder that is a singleton today is left to its
   suite.
4. **Markers.** A folder that only holds a Convention S README
   (`macos/platform/tray`, `windows/platform/{network,tray}`,
   `windows/ui/physical_shortcuts`) is retired; the absence is declared once in
   `_shared/core/features.json`, which the menu's reason text already cites.

**Residuals.** `_shared/core/ports` (23 port specifications), `_shared/data`
(22), `_shared/modules/llm` (37 data files), `_shared/lua/modules/keystats` (22)
and `_shared/lua/modules/llm` (21) stay over the bound: they are catalogues
codegen reads by path, and splitting them belongs to their generators. The 14
test folders still over 40 entries are behaviour suites (Windows LLM servers,
updater, gestures meta tests); each suite splits when its owner next touches
it.

**Parity unit.** Rule B compares names: a module that is one file on a driver
(`ui/panels/changelog.lua`) and a folder on another (`ui/panels/changelog/`) is
the same module. Below the domain level a sub-module exists where its code
exists (`modules/keystats/walker` is Windows-only because only Windows has a
walker); the mismatch ratchet therefore counts the layer and domain level.

**Lua module collisions.** Both the driver root and `_shared/lua` are on
`package.path`, first match wins. Mirroring the names makes 33 driver shims
that re-export a shared module carry exactly the shared module's name
(`macos/infra/timings.lua` and `_shared/lua/infra/config/timings.lua`); the
list is at the end of [target-tree.md](structure-plan/target-tree.md). The
step that creates one retires the shim (its callers already use that name)
or renames it; `apply-step.cjs` refuses until it does.

## Move map, rewrites and steps

- [move-map.tsv](structure-plan/move-map.tsv): every file that moves or is
  retired, `old`, `new` (or `(retired)`), `step`. Every other tracked file of
  the four trees stays where it is; `node tools/audit/structure/plan.cjs
--map-all` prints all 10,066 rows, `=` for the files that stay.
- [steps.md](structure-plan/steps.md): the 50 steps in order, with their move
  and rewrite counts per category and their gates.
- [rewrites.tsv](structure-plan/rewrites.tsv): every rewritten token per step
  (Lua require name, `#Include` path, repository path), with the number of
  files that carry it per category.
- [referencing-files.md](structure-plan/referencing-files.md): the workflows,
  packaging manifests, build scripts, tools and repository tests that name a
  moved path, with the steps that touch each.

The appendices are a snapshot of 2026-11-11. Regenerate them with
`npm run audit:structure-plan` (about a minute); the applier recomputes
everything from the index of the day anyway.

### Ordering

One step moves one target module on the three drivers, its `_shared` mirror
and its tests together, so every step leaves the tree consistent and green.
Leaves first: `infra/*` (11 steps), `adapters/*` (8), `platform/*`, then
`modules/*`, `ui/*`, and the test data folders last. Within a layer the order
is alphabetical; a step can be reordered when a concurrent change makes a
later one urgent, because no step depends on another's file names (Lua names
are root-relative and `apply-step.cjs` re-relativises `#Include` lines against
the final location of their target).

### Applying a step

```bash
node tools/audit/structure/apply-step.cjs --list                 # the steps of today
node tools/audit/structure/apply-step.cjs infra/config           # dry run: moves and rewrites
ERGOPTI_STRUCTURE_PHASE=2 node tools/audit/structure/apply-step.cjs infra/config --apply
```

`--apply` refuses without `ERGOPTI_STRUCTURE_PHASE=2` (the coordinator's go),
when a touched file has local changes, and when the step creates a Lua module
collision. It rewrites references first, then `git mv`s the files, re-relativises
the relative `#Include` lines of moved AHK files, `git rm`s retired markers and
stages exactly what it touched. It commits nothing: the step's gates run first,
then `test-structure-folder-bounds --update-baseline` lowers the ratchet, then
one commit per step (`refactor(structure): move <module> into the shared tree`).

### Gates

Every step runs the base gates; `steps.md` adds the category gates of the
references it rewrites.

| id             | gate                                                                                                                                |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| G-lint         | `node tools/lint/format.cjs --check` and `node tools/lint/lint-conventions.js --fail-on-violations`                                 |
| G-tree         | `node tools/test/test-driver-tree-parity.cjs` (raise `BASELINE_SHARED`, lower `BASELINE_UNION` with the step)                       |
| G-bounds       | `node tools/test/test-structure-folder-bounds.cjs` (lower the baseline with the step)                                               |
| G-js           | `node tools/test/run-js-suite.cjs` for the rewritten tools and repository tests                                                     |
| G-macos        | `cd static/ergopti_plus/macos && lua tests/run.lua`                                                                                 |
| G-linux        | `cd static/ergopti_plus/linux && luajit tests/run.lua` and `--module=integration`                                                   |
| G-windows      | the Windows lane of `ci-windows.yml` (the maintainer's PC for live checks)                                                          |
| G-ahk-encoding | `npm run test:ahk-encoding` (BOM and LF of every rewritten `.ahk`)                                                                  |
| G-packaging    | `test-windows-bundle-manifest.cjs`, `test-macos-bundle-layout.cjs`, `test-features-manifest-no-drift.cjs`, the Linux install matrix |
| G-ci           | the workflow path filters and `test-*workflow*.cjs`                                                                                 |
| G-docs         | relative links of the rewritten documents                                                                                           |
| G-review       | a reviewer reads the `other` rewrites (fixtures, JSON corpora, scripts)                                                             |

### Rule B gate

Added in phase 1: `tools/test/test-structure-folder-bounds.cjs`
(baseline [structure-folder-bounds-baseline.json](../../tools/test/structure-folder-bounds-baseline.json)),
registered as `js-0507`. It ratchets per tree the oversized and single-entry
folders (code and tests apart, a singleton kept for parity counted as a
singleton) and the layer and domain folders on one or two drivers. The
plan's target satisfies every count, so the ratchet never blocks a step.

Proposed for phase 2, when the last step lands: extend
`test-driver-tree-parity.cjs` from its two ratchets to an equality check at
the layer and domain level, with the OS-specific list of `rules.cjs` as its
only allowance, and turn the bounds ratchet into the plain 2..20 check with
the residual catalogues listed as exemptions with their reason.

## Risks

- **Windows `#Include`.** About 3,100 `#Include` lines name a relative path
  (170 more go through `%A_LineFile%`) and resolve against the including file; `apply-step.cjs` rewrites both sides, but the three dynamic
  forms (`#Include %A_ScriptDir%`, the `@@HANDOFF@@` and `@@LEASE@@`
  templates) and the 455 `A_ScriptDir` uses of the root test runners are left
  alone: the plan does not move `windows/tests/run_*.ahk` (TODO.md « Remaining
  code work » already judged that move not worth it). Every Windows step needs
  G-windows on the Windows lane before its commit; a parse error is only seen
  there.
- **Lua names built at runtime.** About 40 module or path strings are completed
  by concatenation at runtime (`"modules.llm." .. name`, `"ui.metrics_" .. page`); the
  token scan cannot see them. The `modules/llm`, `ui/*` and
  `modules/shortcuts` steps search for those prefixes by hand.
- **Packaging manifests.** `tools/build/windows_bundle_manifest.json`,
  `macos-bundle-manifest.json`, `build-features-manifest.js` and
  `build-menu-manifest.js` name driver paths; their steps run G-packaging, and
  the bundle stamp changes with them.
- **Updater ownership.** The Linux updater proves a rollback tree from
  `linux/install/ownership_schema.sh` and its driver and shared sentinels; an
  installed copy of an older release still expects the old paths. A moved
  sentinel keeps its old path in the schema's retired list for one release, and
  the macOS and Windows updaters' installed-file lists move with their step.
- **`behaviors.json` owners.** 22 `owners` arrays in
  `_shared/modules/features/behaviors.json` name driver files by repository
  path; they are ordinary path tokens and the step rewrites them, then
  `test-features-manifest-no-drift` checks the projections.
- **Pinned-source tests.** Repository tests that read a driver file by path
  (`test:no-pinned-source-reads-lua/-linux` count them) are rewritten like any
  other reference; the count must not rise.
- **CI path filters.** `ci-linux.yml`, `ci-macos.yml` and `ci-release.yml`
  name moved paths (see referencing-files.md); a filter that misses the new path
  would skip the lane on the next change, so G-ci checks them.
- **Concurrent work.** A branch that edits a file a step moves conflicts at
  integration. Each step is small and recomputed on the day, and `--apply`
  refuses a dirty touched file, so a step waits for the edit rather than
  overwriting it.
- **Codegen outputs.** `_generated/` folders keep their layout; a generator
  whose input moves (`menu_manifest.json` readers, `config_keys`) is rerun in
  its step, never hand-edited.

## Decisions to review

Decided by the coordinator on 2026-11-11, to review by the maintainer:

1. Bounds: 2..20 direct entries per code folder, 2..40 per test folder.
   Exempt: `vendor`, `_generated`, the SwiftPM launcher, `.app` bundles, data
   corpora, `_shared/data/locales`, Go packages.
2. The top level keeps the existing layers; no feature-first rewrite of the
   whole tree. A feature-first layout (`gestures/{adapters,ui,…}`) would move
   all ten thousand files, break the ports-and-adapters contract and
   `features.json`'s `tree` field, and was rejected for that cost.
3. One domain vocabulary across `infra`, `adapters` and `_shared/lua`, as in
   `rules.cjs`; the canonical feature names of `features.json` are kept
   (`llm`, not `ai`; `keystats`, which the menu calls Metrics).
4. `_shared/lua` mirrors the driver layers (`_shared/lua/infra/config/…`), with
   the collision rule above; `_shared/ui` takes the `ui/` groups.
5. Parity wins over the singleton rule; Rule B compares module names, so a
   one-file module may be a file on one driver and a folder on another.
6. Convention S README folders are retired; the absence lives in
   `features.json`.
7. No file is renamed except a singleton folded into its parent; redundant
   prefixes (`keystats_*.ahk` inside `modules/keystats/`) stay, to keep blame
   and the rewrite small.
8. Phase 2 runs one step per commit, in the order of `steps.md`, after the AHK
   and Linux/macOS feature work in flight has landed.

## Phase 1 Rule A fixes

None. The trivially safe candidates (`NS_PER_MS`, `MS_PER_SEC`,
`POLL_SECONDS` on both Lua drivers) have no shared home yet in `_shared/lua`
that both drivers already load at the point of use, so each needs a design
choice rather than a mechanical edit; they head Rule A's order of work.

## Tools

| tool                                               | purpose                                       |
| -------------------------------------------------- | --------------------------------------------- |
| `tools/audit/structure/census.cjs`                 | folder table, bounds, mismatches of the index |
| `tools/audit/structure/rules.cjs`                  | the target tree as rules                      |
| `tools/audit/structure/plan.cjs --write`           | appendices 1 to 4                             |
| `tools/audit/structure/apply-step.cjs`             | one step, dry run by default                  |
| `tools/audit/shared-literal-inventory.cjs --write` | appendices 5 and 6                            |
| `tools/test/test-structure-folder-bounds.cjs`      | Rule B ratchet (`js-0507`)                    |
| `tools/test/test-shared-literal-inventory.cjs`     | Rule A ratchet (`js-0508`)                    |
