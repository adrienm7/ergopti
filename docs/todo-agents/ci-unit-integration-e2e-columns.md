<!-- docs/todo-agents/ci-unit-integration-e2e-columns.md -->

# CI: Unit, Integration and E2E columns on every row

## Request

Every row of the CI graph (Windows, macOS, Linux, YAML, shared code & web) shows three test
columns in this order: Unit tests, Integration tests, E2E tests. Unit jobs keep only unit tests.
Job names read in two levels, `<Row> / <Stage> (<item>)`, with no internal job id.

## Done

### Two-level job names (1f46d8323d)

Each name part had one owner:

- the row (`Linux`) is the caller job name in `ci.yml`;
- a second level (`Unit tests`) was the caller job name of a per-stage reusable workflow
  (`ci-linux-unit.yml` and its siblings, introduced on October 21), which then repeated it;
- the raw id (`test-linux`) and `Matrix: linux` came from a matrix job whose name was an
  expression: GitHub then shows the job id in the graph and the matrix group header.

The per-stage workflows were folded back into the four lane files (`ci-common.yml`,
`ci-windows.yml`, `ci-linux.yml`, `ci-macos.yml`), so one nesting level is gone. A matrix job now
has the static stage name and GitHub appends the matrix value; a single job names its subject in
parentheses. `test-ci-pipeline-wiring.cjs` enforces the rule (no `${{`, no `/`, matrix name ==
stage name, single job == `Stage (subject)`), with mutation controls.

Job names listed by the API (`.../actions/runs/<id>/jobs`), before in run 39649887068, after in
run 39670279734:

| Before                                                         | After                                                          |
| -------------------------------------------------------------- | -------------------------------------------------------------- |
| `Linux / Unit tests / core`                                    | `Linux / Unit tests (core)`                                    |
| `Windows / E2E tests / Engine E2E corpus`                      | `Windows / E2E tests (Engine E2E corpus)`                      |
| `macOS / Build / ErgoptiPlus.app (macOS 26)`                   | `macOS / Build (ErgoptiPlus.app, macOS 26)`                    |
| `YAML, shared code & web / Verdict / Production site receipts` | `YAML, shared code & web / Verdict (Production site receipts)` |
| graph group `Matrix: linux / Unit tests / test-linux`          | graph group `Matrix: Linux / Unit tests`                       |

The shared root job `Check formatting and plan unit tests` now reads
`Check formatting and plan shared tests`, since it plans both shared test stages.

Hosted proof: probe run 39660668875 (static matrix names, branch deleted) and run 39670279734
(commit 1f46d8323d, all lanes green, 38.7 min).

### Integration stage on every row

Order on every lane: Unit tests, then Integration tests (needs every Unit row), then E2E tests
(needs Integration). Build and its later stages wait for Integration where they waited for Unit.
The receipt chains follow through their owners: `tools/ci/ci-stage-status.cjs` (Windows and
Linux), `tools/ci/macos-stage-roles.cjs` (new `integration` stage, one stubbed cell, which now
plans the E2E cells), `tools/ci/js-feature-matrix.cjs` and `validate-js-feature-results.cjs`
(Common: an `integration-` feature folder is an Integration lot), the desktop and Linux evidence
verifiers, `.github/linux-ci-coverage.json` (new mandatory `integration-linux` row with
per-shard subjects), the release qualification scope (`windows-native-desktop` now owned by
`integration-ahk`) and every CI-shape test.

What moved (nothing deleted, each test still runs exactly once):

- **YAML, shared code & web**: two new feature folders. `integration-generators-and-parity`
  (js-0031, 0160, 0226, 0227, 0228, 0229, 0239, 0248: generators, drift guard, manifest
  parity) and `integration-packaging-and-boot` (js-0099, 0102, 0108, 0125, 0177, 0184, 0198,
  0199, 0206, 0217, 0263: Linux installer and uninstaller sandbox, bundle payloads, AHK boot
  smokes), taken from `data-and-source-contracts` and `distribution-and-updates`. Job
  `common-integration`, one row per lot.
- **Windows**: job `integration-ahk`, three lots. `Driver startup` (full-driver startup smoke,
  was on the `hotstrings-shortcuts` unit row), `Fresh clone bootstrap` (fresh Git clone and warm
  start, same), `Native cohorts and contracts` (native desktop AHK cohorts, manifest parity,
  managed Ollama file component: these ran on all 14 unit rows, now once). The Kana layout
  install stays in Unit (its real probes need it) and is also done in the native lot.
- **Linux**: job `integration-linux`, two rows. `driver` runs the new `integration` module group
  of `tests/support/module_groups.lua` (8 files: daemon CLI, owned process deadline, lifecycle
  callbacks and native timer, sqlite first open, LLM prediction engine, config backup files,
  tap-hold integration). `native` runs the metrics aggregation and histogram equivalence
  checks, the XI2 LuaJIT ABI qualification and the manual managed Ollama runtime acceptance,
  which were on the `meta` unit row.
- **macOS**: job `integration-hs` (`Integration tests (Lua module wiring, stubbed hs)`), the new
  `integration` module group (12 files: E2E corpus and property runner integration, bootstrap
  TOML, LLM agent and feature end-to-end flows over stubbed hs, preference round trips).

Selecting a Lua `integration` group fails when a file it names was not discovered, so a rename
cannot silently move a test back into Unit or drop it.

Docs: `README.md` (CI section), `docs/TESTING.md` (stage definitions and the Integration table).

## Evidence

- Run 39688508159 (bce94157b7): red on the module group meta checks, the Swift launcher CI
  check and the Windows Ollama file component probe, all still reading the old layout; fixed in
  afbeeb98b6 and f55b1ad7c4.
- Run 39691011422 (f55b1ad7c4, `os_lanes=all`): green. First attempt 29 minutes wall clock,
  every job green except `macOS / E2E tests (Tooltip canvas (macOS 15, Apple silicon))`
  ("LayoutManager observation or cleanup incomplete", a native canvas flake); its rerun
  (attempt 2) passed. Linux Integration (driver) ran 134 assertions over its 8 files, macOS
  Integration 116 over its 12.
- Check-run names on f55b1ad7c4 (`/commits/<sha>/check-runs`) match the job names: 94 checks,
  every one `<Row> / <Stage> (<item>)` except the two root jobs `Check formatting and plan
shared tests` and `Release plan`.

## Remaining

- Watch the CI duration: Windows Integration adds about 4 to 5 minutes on the critical path
  (three parallel lots), while each Windows unit row sheds the native desktop and Ollama file
  checks it used to repeat.
