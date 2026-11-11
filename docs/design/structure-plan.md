<!-- docs/design/structure-plan.md -->

# Structure plan: shared values and one feature-first driver tree

Maintainer request of 2026-11-11. Phase 1 (this document, its generated
appendices, the measurement tools and two ratchets) is a plan only: several
sessions and the maintainer's Windows work are changing the driver trees, so
no driver file moves yet. Phase 2 applies the plan one feature at a time once
the coordinator says go, after the AHK and Linux/macOS feature work in flight
has landed.

The first version of this plan (layer-first, 2026-11-11 afternoon) was
reviewed by the maintainer the same day: « decided by the maintainer on
2026-11-11: feature-first ». The comparison of the two is in
[Feature-first against layer-first](#feature-first-against-layer-first). The
remaining open choices were decided by the coordinator on 2026-11-11, to review
by the maintainer; they are collected in [Decisions](#decisions).

## The two rules

**Rule A — everything common lives in `_shared`.** Each OS folder holds only
its implementation. Configuration variables and defaults, colours, delays,
timeouts and durations, thresholds, counts, sizes and limits, path names,
enum, reason and key names live once in `_shared`; so does every user-facing
text, translated in every locale (the `i18n` skill), and every piece of logic
that is not OS-specific (parsers, rule engines, matchers, formatters, state
machines, data tables).

**Rule B — one simple, feature-first tree in every OS folder.** The top level
of every driver and of `_shared` is one folder per feature a user can name,
plus `core/` (foundations) and `platform/` (OS bindings no feature owns).
Inside a feature the same layered sub-folders everywhere. Knowing the Windows
tree means knowing the macOS and Linux trees; a developer looking for
gestures opens `gestures/` on any of them. No folder holds fewer than 2 or more
than 20 entries (40 in tests).

## Findings in numbers (measured 2026-11-11 on `dev` at c96d2090)

| measurement                                                           | value                                                                                                                                                                                                   |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| tracked files under the four trees                                    | 10,005                                                                                                                                                                                                  |
| Rule B today: code folders over 20 entries                            | 27 (worst: `_shared/lua` 113, `linux/infra` 112, `windows/infra` 109, `macos/adapters` 92, `macos/infra` 89, `macos/modules/llm` 68, `windows/modules/keystats` 66, `windows/` and `linux/adapters` 58) |
| Rule B today: one-entry code folders                                  | 34 (plus 40 that mirror a real folder on another driver)                                                                                                                                                |
| Rule B today: test folders over 40 entries / with one entry           | 18 / 97                                                                                                                                                                                                 |
| Rule B today: first- and second-level folders on one or two drivers   | 21                                                                                                                                                                                                      |
| after the plan: code folders over 20 / with one entry                 | 0 / 8 (all `_shared/*/data/*` folders that codegen reads by path)                                                                                                                                       |
| after the plan: test folders over 40 / with one entry                 | 15 / 28                                                                                                                                                                                                 |
| after the plan: first- and second-level folders on one or two drivers | 21, each declared OS-specific or holding code that exists on those drivers only                                                                                                                         |
| plan size                                                             | 8,092 moves in 38 steps, 1 retired README, 52,412 reference rewrites, 32 driver Lua shims to retire                                                                                                     |
| Rule A: hand-typed values in production driver source                 | 1,921 (Windows 642, macOS 783, Linux 374, and 122 macOS/Linux logic pairs)                                                                                                                              |
| Rule A: constant names declared on two or three drivers               | 54, 13 of them with different values                                                                                                                                                                    |
| Rule A: Lua functions or tables both Lua drivers carry                | 104 functions, 18 data tables                                                                                                                                                                           |
| hardcoded UI strings at display call sites                            | 0 (the `test-no-hardcoded-ui-strings` baseline is empty)                                                                                                                                                |

## Rule A: inventory

`node tools/audit/shared-literal-inventory.cjs --write` scans every production
`.ahk` and `.lua` file of the three drivers (tests, `vendor`, `_generated`, the
Swift launcher and the bundled apps excluded) and writes:

- [rule-a-inventory.tsv](structure-plan/rule-a-inventory.tsv): one row per
  item, `file`, `line`, `kind`, `name`, `value`, proposed shared home,
  proposed name and mechanism;
- [rule-a-duplicates.md](structure-plan/rule-a-duplicates.md): the names
  declared on two or three drivers, and the Lua logic macOS and Linux both
  carry, with the feature's `_shared/<feature>/engine/` as home;
- [rule-a-gates.md](structure-plan/rule-a-gates.md): the existing
  single-source and tree gates, how strict each is, and whether CI runs it.

The detectors are lexical and over-report on purpose (a reviewer drops a false
positive faster than a scanner finds a missed copy). A file's own identity
(its log tag, owner name, driver name) is not counted. The proposed name is
`[<feature>] <lower_snake_name>`, the feature being where Rule B puts the file.

### Kinds, homes and mechanisms

Homes are named by today's path, so Rule A work can start before Rule B; the
second column of each row gives the feature-first path the same file reaches.

| kind                                                 |              count | shared home today → after Rule B                                       | mechanism                                                                      |
| ---------------------------------------------------- | -----------------: | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| duration (`*_MS`, `*_SEC`, `*_TIMEOUT`, …)           |                537 | `_shared/modules/timings/constants.toml` → `_shared/core/timing/data/` | shared data file read at boot (`Timings.ms/sec`, `TimingsGet`)                 |
| bare timer delay (`SetTimer`, `Sleep` with a number) |                 18 | the same registry                                                      | shared data file; the call names a registry key                                |
| limit, size, count, threshold                        |                410 | `constants.toml [limits]` → `_shared/<feature>/data/constants.toml`    | shared data file                                                               |
| colour                                               |                  4 | `_shared/data/native_theme.toml` → `_shared/core/ui/data/`             | shared data file                                                               |
| path, file and bundle name                           |                174 | `_shared/data/identifiers.json` → `_shared/core/text/data/`            | generated constant (`codegen-identifiers.cjs`)                                 |
| enum, reason, key name                               |                656 | `_shared/modules/<feature>/*.json` → `_shared/<feature>/data/`         | generated constant table that raises on an unknown name, as `config_keys` does |
| Lua function both Lua drivers carry                  |                104 | `_shared/<feature>/engine/`                                            | one Lua module both drivers require, under the same module name                |
| Lua data table both Lua drivers carry                |                 18 | `_shared/<feature>/data/*.json`, or `_shared/<feature>/engine/`        | a data file when AHK needs it too, else one Lua module                         |
| user-facing text                                     | 0 at display calls | `_shared/data/locales/*.json` → `_shared/core/i18n/data/locales/`      | the `i18n` skill, every locale                                                 |

**Which mechanism for AHK.** AutoHotkey cannot require Lua, so logic shared
by the three drivers takes one of two forms: a data file every driver reads
at runtime (the timing registry, the menu manifest, `behaviors.json`), or a
generated AHK source (`windows/_generated/`, as `config_keys.ahk` already is),
next to a hand-written port in `windows/<feature>/engine/`. A data table that
all three use is a data file; a rule engine whose rules are data is a data
file plus three small interpreters; a closed name set is a generated
constant. Lua-only logic is one module in `_shared/<feature>/engine/`.

### Biggest duplicates

- **Layout registry and emulation** (`modules/keymap/layout_registry.lua`,
  `layout_emulation.lua`, `composer_check.lua`): 14 identical or near-identical
  functions on macOS and Linux (`shipped_layout`, `with_source`,
  `read_shared_json`, `sha256_text`, `extension_roots`, …). Home:
  `_shared/layouts/engine/registry/`.
- **Field run** (`infra/field_run.lua`): 10 shared functions. Home:
  `_shared/diagnostics/engine/field_run/`.
- **Remote LLM API** (`modules/llm/api_remote.lua`): 6. Home:
  `_shared/ai/engine/api/`.
- **Window bridges** (`ui/healthcheck`, `ui/error_dialog`, `ui/onboarding`,
  `ui/physical_shortcuts`): identical `init_message`, `failure_contract`,
  `retire_observation`. Home: one bridge helper in `_shared/core/ui/engine/`.
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
  percent-encode only; no gate compared Lua function bodies across the two Lua
  drivers.
- `test-driver-tree-parity` measures directories down to depth 2 with a
  floor and a union ceiling; it does not see folder sizes.

The ratchet `tools/test/test-shared-literal-inventory.cjs` (`js-0508`) holds
the hand-typed values per driver and kind and the macOS/Linux logic pairs
(baseline
[shared-literal-inventory-baseline.json](../../tools/test/shared-literal-inventory-baseline.json));
no count may rise, and one that falls must be lowered in the same change.

### Rule A order of work

1. The logic pairs at similarity 1.00, starting with the layout registry, and
   the values both Lua drivers type identically: one module in
   `_shared/<feature>/engine/`, both drivers require it (macOS and Linux only,
   no AHK risk).
2. Durations and limits into the timing registry, driver by driver, each with
   the registry read and the baseline lowered.
3. Enum and reason names into generated constant tables, one feature at a time.
4. Path and identifier names into `identifiers.json`.
5. AHK logic that mirrors Lua: a data file first, codegen when the logic is a
   closed set.

Rule A moves values, Rule B moves files. A Rule A migration of a feature waits
until that feature's Rule B step has landed: after it, moving a Lua file from
`<driver>/<feature>/engine/` to `_shared/<feature>/engine/` keeps its module
name, so no caller changes (see [Lua module names](#lua-module-names)).

## Rule B: current trees

[current-trees.md](structure-plan/current-trees.md) shows the architecture
folders of the three drivers side by side to depth 3 with their entry counts,
then every folder outside the bounds and every folder on one or two drivers
only.

Today's trees are layer-first: `adapters/`, `infra/`, `modules/`, `platform/`,
`ui/`. One feature is spread over five folders (gestures: `modules/gestures`,
`ui/gesture_conflicts`, `ui/menu/menu_gestures`, `adapters/…`, `_shared/lua/gestures`),
`infra/` and `adapters/` are flat and over 89 entries on every driver, and
the same feature has different names in different layers (`keystats`,
`metrics_typing`, `wpm`; `llm`, `model_browser`, `menu_llm`; `keymap`,
`layout_manager`, `layer_editor`).

## Rule B: target tree

The rules are data in
[tools/audit/structure/rules.cjs](../../tools/audit/structure/rules.cjs), so a
file created after this plan lands where its siblings land.

```text
<driver>/                    windows, macos, linux: the same names
  README.md, entry point     ErgoptiPlus.ahk | init.lua | ergopti_hotstrings.lua
  ai/                        prediction, providers, local runtimes (today llm)
  apps/                      per-application profiles, bundled apps
  clipboard/
  diagnostics/               field checks and runs, logs, health, crash and issue reports
  gestures/
  hotstrings/                matcher, catalogue, dynamic, expander, editors
  layouts/                   registry, emulation, keylayout, composer, layer and layout editors
  menu/                      the tray menu's builder and transactions
  metrics/                   keystats, wpm, the metrics pages (today keystats)
  onboarding/
  remap/                     layers, nav layer, caps word, chords, key handlers
  settings/                  config, scopes, migration, preferences, paths
  shortcuts/                 keyboard and physical shortcuts, actions, action picker
  tap_hold/
  tray/                      the tray icon
  updater/                   updater, changelog, update check, downloads
    each feature:  engine/ (its logic)  adapters/ (its OS bindings)
                   ui/ (its windows, ui/menu/ its tray-menu section)
                   data/  native/        — only the ones it needs
  core/                      foundations every feature uses
    crypto/ events/ fs/ i18n/ lifecycle/ logger/ network/ process/ text/ timing/ ui/
    each domain: engine/ adapters/ ui/ data/ as above
  platform/                  OS bindings no single feature owns
    focus/ input/ system/    (Windows also native/, Linux also desktop_focus/)
  _generated/ vendor/
  tests/{unit,meta,integration,…}/  mirror the feature tree (tests/unit/gestures/engine/…)
         fixtures/ support/ hardware/  split by feature

OS-specific, by name and on one driver only:
  macos/launcher/            the Swift host application
  macos/apps/bundled/        App Cloner, Encryptor (.app bundles)
  linux/install/             shell installers (bin/ folds into it)
  linux/platform/desktop_focus/  GNOME Shell and KWin focus readers
  linux/updater/native/      the updater's O_TMPFILE publication
  windows/layouts/native/    the keyboard DLL sources
  windows/platform/native/   the WH_KEYBOARD_LL navigation-event owner

_shared/                     the same feature names
  <feature>/engine/          the Lua both Lua drivers require (today _shared/lua/)
  <feature>/data/            data files (today _shared/modules/ and _shared/data/)
  <feature>/ui/<page>/       web pages (today _shared/ui/)
  core/<domain>/ …, core/ports/ and core/features.json unchanged
  tests/{corpus,fixtures,lua,conformance}/
```

[target-tree.md](structure-plan/target-tree.md) is the side-by-side view of the
three drivers after the moves, with the residual folders, the asymmetries left
and the Lua shim collisions.

### Three features, current path → new path

**gestures**

| tree     | today                                                        | after                                                       |
| -------- | ------------------------------------------------------------ | ----------------------------------------------------------- |
| windows  | `modules/gestures/actions.ahk`                               | `gestures/engine/actions.ahk`                               |
| windows  | `modules/gestures/raw_touchpad.ahk`                          | `gestures/adapters/raw_touchpad.ahk`                        |
| windows  | `ui/gesture_conflicts.ahk`                                   | `gestures/ui/gesture_conflicts.ahk`                         |
| windows  | `ui/menu/menu_gestures.ahk`                                  | `gestures/ui/menu/menu_gestures.ahk`                        |
| macos    | `modules/gestures/engine.lua`                                | `gestures/engine/engine.lua`                                |
| macos    | `modules/gestures/native_app_switcher.lua`                   | `gestures/adapters/native_app_switcher.lua`                 |
| macos    | `ui/gesture_conflict_notice.lua`                             | `gestures/ui/gesture_conflict_notice.lua`                   |
| linux    | `modules/gestures/mt_decoder.lua`                            | `gestures/engine/mt_decoder.lua`                            |
| linux    | `ui/menu/menu_gestures.lua`                                  | `gestures/ui/menu/menu_gestures.lua`                        |
| \_shared | `lua/gestures/direction.lua`                                 | `gestures/engine/direction.lua`                             |
| windows  | `tests/unit/modules/gestures/test_display_mirror_toggle.ahk` | `tests/unit/gestures/engine/test_display_mirror_toggle.ahk` |

**layouts**

| tree     | today                                           | after                                                  |
| -------- | ----------------------------------------------- | ------------------------------------------------------ |
| windows  | `modules/keymap/keylayout/keylayout_parser.ahk` | `layouts/engine/keylayout/keylayout_parser.ahk`        |
| windows  | `ui/layer_editor/init.ahk`                      | `layouts/ui/layer_editor/init.ahk`                     |
| windows  | `native/keyboard_layout/_generated/kbdergop.c`  | `layouts/native/keyboard_layout/_generated/kbdergop.c` |
| macos    | `modules/keymap/layout_registry.lua`            | `layouts/engine/registry/layout_registry.lua`          |
| macos    | `adapters/input_source_selector.lua`            | `layouts/adapters/input_source_selector.lua`           |
| linux    | `modules/keymap/layout_registry.lua`            | `layouts/engine/registry/layout_registry.lua`          |
| linux    | `ui/layout_manager/bridge.lua`                  | `layouts/ui/layout_manager/bridge.lua`                 |
| \_shared | `lua/layouts/registry.lua`                      | `layouts/engine/registry/registry.lua`                 |
| \_shared | `ui/layout_composer/composer.css`               | `layouts/ui/layout_composer/composer.css`              |
| \_shared | `keymap/layer_actions.toml`                     | `layouts/data/layer_actions.toml`                      |

**metrics**

| tree     | today                                     | after                                          |
| -------- | ----------------------------------------- | ---------------------------------------------- |
| windows  | `modules/keystats/keystats_reader_db.ahk` | `metrics/engine/reader/keystats_reader_db.ahk` |
| windows  | `modules/keystats/keystats_walker.ahk`    | `metrics/engine/walker/keystats_walker.ahk`    |
| windows  | `ui/wpm/wpm_widget.ahk`                   | `metrics/ui/wpm/wpm_widget.ahk`                |
| windows  | `ui/menu/menu_metrics.ahk`                | `metrics/ui/menu/menu_metrics.ahk`             |
| macos    | `modules/keystats/sqlite_writer.lua`      | `metrics/engine/journal/sqlite_writer.lua`     |
| macos    | `modules/keystats/network_watcher.lua`    | `metrics/adapters/network_watcher.lua`         |
| macos    | `ui/metrics_typing/init.lua`              | `metrics/ui/metrics_typing/init.lua`           |
| linux    | `modules/keystats/metrics_collector.lua`  | `metrics/engine/metrics_collector.lua`         |
| linux    | `adapters/wpm_surface.lua`                | `metrics/adapters/wpm_surface.lua`             |
| \_shared | `lua/keystats/queries.lua`                | `metrics/engine/queries.lua`                   |
| \_shared | `data/db/schema.sql`                      | `metrics/data/db/schema.sql`                   |
| \_shared | `ui/metrics_typing/index.html`            | `metrics/ui/metrics_typing/index.html`         |

### How a path is classified

1. **Feature.** The first segment after today's layer (a folder name or a
   file stem) names the feature through the tables of `rules.cjs`; a folder
   that is a synonym of its feature dissolves (`modules/keystats/` →
   `metrics/`), any other stays a named sub-module (`ui/healthcheck/` →
   `diagnostics/ui/healthcheck/`).
2. **Sub-folder.** Today's layer gives it: `modules/` and `infra/` → `engine/`,
   `adapters/` and `platform/` → `adapters/`, `ui/` → `ui/`, data → `data/`,
   `native/` → `native/`. A file of a feature module whose name says it binds
   the OS (`raw_touchpad`, `*_worker`, `x11_*`, …) goes to `adapters/`.
3. **Menu sections.** The tray menu's builder, engine and transactions stay
   in `menu/`; each feature's section (`menu_gestures`, `menu_llm/`, …) moves
   to `<feature>/ui/menu/`.
4. **Bounds.** A sub-folder over 20 entries splits into named sub-modules, the
   same names on every driver (`metrics/engine/{reader,journal,walker,…}`,
   `ai/engine/{api,ollama,prediction,…}`). A code folder left with one file
   becomes that file in its parent (a one-file `engine/` folds into the
   feature); a folder holding only one folder hands its content up
   (`core/events/adapters/*` → `core/events/*`). Parity wins: a folder that is
   real on another driver stays a folder everywhere. `_shared` data folders keep
   their layout, which codegen reads by path.

**Residuals.** 8 one-entry folders, all `_shared/*/data/*` (a `db/migrations/`
folder is read as a directory; the others are named data sets). 15 test
folders over 40 entries are behaviour suites (Windows LLM servers, updater,
gestures meta tests) and split when their owner next touches them.

**Parity unit.** Rule B compares names: a module that is one file on a driver
(`layouts/ui/layer_editor.lua`) and a folder on another
(`layouts/ui/layer_editor/`) is the same module. A feature has only the
sub-folders it needs, so `gestures/adapters/` exists where the gestures code
binds the OS; the mismatch ratchet counts features and their sub-folders
(depth 2), and lists those that exist on one or two drivers with the reason.
A one-entry folder that mirrors a real folder on another driver (Windows
`clipboard/engine/` beside the three files of macOS) is kept and reported,
not counted as a violation.

### Lua module names

`_shared` becomes the shared Lua root: `package.path` gains `_shared/?.lua`
and `_shared/?/init.lua` beside today's `_shared/lua/?.lua`, so a shared module
is required as `gestures.engine.direction`, exactly like a driver module in
`<driver>/gestures/engine/`. Two consequences:

- **Moving logic to `_shared` changes no caller.** When Rule A moves
  `macos/layouts/engine/registry/layout_registry.lua` to
  `_shared/layouts/engine/registry/layout_registry.lua`, every
  `require("layouts.engine.registry.layout_registry")` keeps working.
- **Collisions are refused.** Both roots are on the path and the first match
  wins silently, so a module name may exist in one root only. Today 32 driver
  shims re-export a shared module under a name the mirror makes identical
  (`macos/core/timing/engine/timings.lua` beside
  `_shared/core/timing/engine/timings.lua`); the step that creates one retires
  the shim (its callers already use that name) or renames it, and
  `apply-step.cjs` refuses until it does. The list is at the end of
  [target-tree.md](structure-plan/target-tree.md).

The `_shared/lua/` entry stays on `package.path` until the last shared Lua
file has left it (the `core/*` steps move most of them), then the
`tests/shared_lua` step removes it.

## Move map, rewrites and steps

- [move-map.tsv](structure-plan/move-map.tsv): every file that moves or is
  retired, `old`, `new` (or `(retired)`), `step`. Every other tracked file of
  the four trees stays where it is; `node tools/audit/structure/plan.cjs
--map-all` prints all 10,005 rows, `=` for the files that stay.
- [steps.md](structure-plan/steps.md): the 38 steps in order, with their move
  and rewrite counts per category and their gates.
- [rewrites.tsv](structure-plan/rewrites.tsv): every rewritten token per step
  (Lua require name, `#Include` path, repository path), with the number of
  files that carry it per category.
- [referencing-files.md](structure-plan/referencing-files.md): the workflows,
  packaging manifests, build scripts, tools and repository tests that name a
  moved path, with the steps that touch each.

The appendices are a snapshot of 2026-11-11 on c96d2090. Regenerate them with
`npm run audit:structure-plan` (about a minute); the applier recomputes
everything from the index of the day anyway.

### Ordering, one feature at a time

A step moves one feature (or one `core/` or `platform/` domain) on the three
drivers, its `_shared` part and its tests together, so every step leaves a
consistent, green tree.

1. **Package path** (step 0, hand-written): add `_shared/?.lua` and
   `_shared/?/init.lua` beside `_shared/lua/` in `macos/init.lua`,
   `linux/ergopti_hotstrings.lua`, the Linux literal module loader and bytecode
   package, the shared root resolvers, the test runners and the bundle
   builders; gate: both Lua suites and the packaging tests.
2. **`core/*`** (11 steps: crypto, events, fs, i18n, lifecycle, logger,
   network, process, text, timing, ui), then **`platform/*`** (5): the
   foundations every feature requires, so later steps rewrite fewer names.
3. **`settings`, `menu`, `tray`**: what other features' menu sections and
   preferences call.
4. **The features**, alphabetically: `ai`, `apps`, `clipboard`,
   `diagnostics`, `gestures`, `hotstrings`, `layouts`, `metrics`, `onboarding`,
   `remap`, `shortcuts`, `tap_hold`, `updater`; then `install` and the retired
   `linux/modules/README.md`.
5. **Test data**: `tests/fixtures`, `tests/hardware`, `tests/support`, and
   `tests/shared_lua`, which also removes `_shared/lua/` from `package.path`.

Within the features any order works, because Lua names are root-relative and
`apply-step.cjs` re-relativises `#Include` lines against the final location
of their target; a concurrent change can make a later feature urgent. The
largest steps (`ai` 1,157 moves, `metrics` 879, `hotstrings` 707) can be split
by sub-folder if their review is too long.

### Applying a step

```bash
node tools/audit/structure/apply-step.cjs --list                 # the steps of today
node tools/audit/structure/apply-step.cjs gestures               # dry run: moves and rewrites
ERGOPTI_STRUCTURE_PHASE=2 node tools/audit/structure/apply-step.cjs gestures --apply
```

`--apply` refuses without `ERGOPTI_STRUCTURE_PHASE=2` (the coordinator's go),
when a touched file has local changes, and when the step creates a Lua module
collision. It rewrites references first, then `git mv`s the files,
re-relativises the relative `#Include` lines of moved AHK files, `git rm`s a
retired file and stages exactly what it touched. It commits nothing: the
step's gates run first, then `test-structure-folder-bounds --update-baseline`
lowers the ratchet, then one commit per step
(`refactor(structure): move <feature> into its feature folder`).

### Gates

Every step runs the base gates; `steps.md` adds the category gates of the
references it rewrites.

| id             | gate                                                                                                                                |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| G-lint         | `node tools/lint/format.cjs --check` and `node tools/lint/lint-conventions.js --fail-on-violations`                                 |
| G-tree         | `node tools/test/test-driver-tree-parity.cjs` (its baselines and `features.json` `tree` fields follow the step)                     |
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

`tools/test/test-structure-folder-bounds.cjs` (`js-0507`, baseline
[structure-folder-bounds-baseline.json](../../tools/test/structure-folder-bounds-baseline.json))
ratchets per tree the oversized and one-entry folders, code and tests apart,
and the depth-2 folders on one or two drivers. It was rebaselined on
c96d2090, where Windows test folders had grown past the first baseline. The
plan's target is at or below every count, so the ratchet never blocks a step.

Proposed for phase 2, when the last step lands: extend
`test-driver-tree-parity.cjs` to an equality check of the feature list and of
each feature's sub-folders on the three drivers and `_shared`, with the
OS-specific list of `rules.cjs` as its only allowance; check the top level
against `_shared/core/features.json`; and turn the bounds ratchet into the
plain 2..20 check with the residual data folders listed as exemptions.

## Risks

The layer-first plan moved 3,071 files; feature-first moves 8,092 and rewrites
52,412 references instead of 37,131, because almost every path changes its
first segment. The risks are the same kinds, larger:

- **Windows `#Include`.** About 3,100 `#Include` lines name a relative path
  and 170 more go through `%A_LineFile%`; nearly all of them change, since a
  file and its include usually move to different feature folders (`infra/`
  neighbours scatter into `core/`, `settings/`, `hotstrings/`). `apply-step.cjs`
  rewrites both sides: references to a moved file in every includer, then the
  includes of each moved file against the final location of their targets. The
  three dynamic forms (`#Include %A_ScriptDir%`, the `@@HANDOFF@@` and
  `@@LEASE@@` templates) and the 455 `A_ScriptDir` uses of the root test runners
  are left alone: the plan does not move `windows/tests/run_*.ahk` (TODO.md
  « Remaining code work » judged that move not worth it). Include order
  matters in AHK (a class used at load time must be included first); the
  rewrite keeps every line in place and only changes its path. Every Windows
  step needs G-windows on the Windows lane before its commit.
- **Lua `require` names.** Every driver module name changes its prefix
  (`infra.logger` → `core.logger.engine.logger`); the token scan finds the
  quoted names. About 40 names are built at runtime by concatenation
  (`"modules.llm." .. name`, `"ui.metrics_" .. page`) and are searched by hand in
  their feature's step. The shared root moves from `_shared/lua` to `_shared`
  (step 0 above) and the 32 shim collisions must be retired step by step.
- **Shared root resolvers.** The Linux entry point probes
  `_shared/lua/toml_codec/source_open.lua` to find the shared root, the literal
  module loader exports `ERGOPTI_LITERAL_SHARED_ROOT`, and
  `test-shared-root-resolvers.cjs` pins the resolvers; step 0 changes all of
  them together.
- **Packaging manifests.** `tools/build/windows_bundle_manifest.json`,
  `macos-bundle-manifest.json`, `build-features-manifest.js` and
  `build-menu-manifest.js` name driver paths; their steps run G-packaging, and
  the bundle stamp changes with them.
- **Updater ownership.** The Linux updater proves a rollback tree from
  `linux/install/ownership_schema.sh` and its driver and shared sentinels; an
  installed copy of an older release still expects the old paths. A moved
  sentinel keeps its old path in the schema's retired list for one release, and
  the macOS and Windows updaters' installed-file lists move with their step.
- **`features.json` and `behaviors.json`.** `features.json` gives each
  canonical feature a `tree` (`modules` or `ui`) that the tree-parity gate
  reads; it becomes the feature folder and its sub-folder. The 22 `owners`
  arrays of `behaviors.json` name driver files by repository path and are
  rewritten as ordinary path tokens; `test-features-manifest-no-drift` checks
  the projections.
- **Pinned-source tests.** Repository tests that read a driver file by path
  (`test:no-pinned-source-reads-lua/-linux` count them) are rewritten like any
  other reference; the count must not rise.
- **CI path filters.** `ci-linux.yml`, `ci-macos.yml` and `ci-release.yml`
  name moved paths (see referencing-files.md); a filter that misses a new path
  would skip the lane, so G-ci checks them.
- **Concurrent work.** A branch that edits a file a step moves conflicts at
  integration. Each step is recomputed on the day, and `--apply` refuses a dirty
  touched file, so a step waits for the edit rather than overwriting it.
- **Codegen outputs.** `_generated/` folders stay where their generator writes
  them; a generator whose input moves (`menu_manifest.json` readers,
  `config_keys`, the composer data) is rerun in its step, never hand-edited.

## Feature-first against layer-first

« decided by the maintainer on 2026-11-11: feature-first »

|                                   | layer-first (first version)                                                        | feature-first (this version)                                                                         |
| --------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| finding a feature                 | five places (`modules/x`, `ui/x`, `ui/menu/menu_x`, `adapters/…`, `_shared/lua/x`) | one folder, `x/`, on every driver and in `_shared`                                                   |
| what a folder says                | the kind of code (adapter, service, window)                                        | the capability; the kind is the sub-folder (`engine/`, `adapters/`, `ui/`)                           |
| moving logic to `_shared`         | changes its module name (`infra.x` → `infra.config.x` in another root)             | keeps it (`x.engine.y` in either root)                                                               |
| ports-and-adapters contract       | visible at the top (`adapters/` implements `core/ports`)                           | inside each feature (`x/adapters/`); `core/ports/` still declares the contracts                      |
| cost                              | 3,071 moves, 37,131 rewrites, 50 steps                                             | 8,092 moves, 52,412 rewrites, 38 steps                                                               |
| AHK `#Include` churn              | moderate: neighbours mostly move together                                          | high: most includes change, all mechanical                                                           |
| cross-feature code                | hidden in `infra/`                                                                 | explicit in `core/` and `platform/`, which every reviewer can see grow                               |
| folder bounds after the plan      | 5 oversized, 13 one-entry code folders                                             | 0 oversized, 8 one-entry code folders                                                                |
| one-entry folders kept for parity | about 20 on Linux (`ui/*` bridges)                                                 | 22 to 39 per driver: a feature's uniform sub-folders hold one file where its code is small           |
| risk of a wrong home              | low: the layer is mechanical                                                       | real: the feature tables in `rules.cjs` decide where a cross-cutting file goes; review them per step |

## Decisions

Decided by the maintainer on 2026-11-11: feature-first, as above.

Decided by the coordinator on 2026-11-11, to review by the maintainer:

1. The feature list: `ai`, `apps`, `clipboard`, `diagnostics`, `gestures`,
   `hotstrings`, `layouts`, `menu`, `metrics`, `onboarding`, `remap`,
   `settings`, `shortcuts`, `tap_hold`, `tray`, `updater`; with `core/` and
   `platform/`. `remap` (layers, nav layer, caps word, chords, the Windows key
   handlers, the macOS Karabiner runtime) is the one name the request did not
   give.
2. The sub-folders `engine/`, `adapters/`, `ui/`, `data/`, `native/`, only
   those a feature needs; `core/<domain>/` uses the same ones, `platform/<domain>/`
   none (it is all OS binding).
3. Tests stay in `tests/<kind>/` mirroring the feature tree, rather than a
   `tests/` inside each feature: the runners, module groups and CI lanes
   discover suites from `tests/`, and the root runners are not moved.
4. Each feature's tray-menu section lives in `<feature>/ui/menu/`; `menu/`
   keeps the builder and transactions.
5. Bounds: 2..20 direct entries per code folder, 2..40 per test folder.
   Exempt: `vendor`, `_generated`, the SwiftPM launcher, `.app` bundles, data
   corpora, `data/locales`, Go packages, the `core/ports` catalogue (one
   specification per port).
6. Parity wins over the one-entry rule; Rule B compares module names, so a
   one-file module may be a file on one driver and a folder on another.
7. `_shared` is the shared Lua root (module names `x.engine.y`), with the
   collision rule above.
8. No file is renamed except a one-file folder folded into its parent; redundant
   prefixes (`keystats_*.ahk` inside `metrics/engine/`) stay, to keep blame
   and the rewrite small.
9. Phase 2 runs one step per commit, in the order above, after the AHK and
   Linux/macOS feature work in flight has landed.

## Phase 1 Rule A fixes

None. The trivially safe candidates (`NS_PER_MS`, `MS_PER_SEC`,
`POLL_SECONDS` on both Lua drivers) have no shared home yet that both drivers
already load at the point of use, so each needs a design choice rather than a
mechanical edit; they head Rule A's order of work.

## Tools

| tool                                               | purpose                                       |
| -------------------------------------------------- | --------------------------------------------- |
| `tools/audit/structure/census.cjs`                 | folder table, bounds, mismatches of the index |
| `tools/audit/structure/rules.cjs`                  | the feature-first target tree as rules        |
| `tools/audit/structure/plan.cjs --write`           | appendices 1 to 4                             |
| `tools/audit/structure/apply-step.cjs`             | one step, dry run by default                  |
| `tools/audit/shared-literal-inventory.cjs --write` | appendices 5 and 6                            |
| `tools/test/test-structure-folder-bounds.cjs`      | Rule B ratchet (`js-0507`)                    |
| `tools/test/test-shared-literal-inventory.cjs`     | Rule A ratchet (`js-0508`)                    |
