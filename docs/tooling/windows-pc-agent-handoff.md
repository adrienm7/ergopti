# Windows PC agent handoff (2026-10-30)

Read this before your next push to `dev`. A cloud coordinator session and its
workers integrate into `dev` every hour (at minute 18 UTC), so `dev` moves
under you all night.

## Rules

- Before each push: `git fetch origin dev`, then `git rebase origin/dev`. No
  merge commit, no force-push on `dev`.
- No `Co-Authored-By` or `Claude-Session` trailers in commit messages.
- In `TODO.md`, only add lines or check your own items. Do not rewrite other
  sections; on a conflict keep both sides.
- Launch the full three-OS CI once, on your last push only.

## Already on `dev`, do not redo

- Claude session links in release notes: fixed in 0ba0e90580
  (`tools/build/build_changelog.py` strips the trailers and session URLs, with
  `tools/build/build_changelog_test.py`; the convention lint rejects
  `Claude-Session`). Drop that part of lot W and keep only the personal
  hotstring `sru` -> `SRU` fix.

## Owned by cloud workers, do not edit in parallel

Branch `work/windows-port`:

- Thinking off on every Windows LLM path (`api_remote.ahk`, vision, translate,
  agent, Ollama warmup `think:false`), replaying
  `_shared/ai/data/thinking_off_vectors.json`; 400 retry with persisted
  refusal and `_LLM_Remote_RetryOf`; default-only sampling for recent Claude
  models.
- Windows detection of every `local_servers.json` server and generic catalogue
  provider.
- Owned Ollama on Windows (port 11435 rule).
- PAR-14 Windows PAC proxy policy.
- `TODO.md` items marked "Done on macOS and Linux, Windows left" or
  "Windows: port ...".

Field report worker:

- Windows per-request LLM latency log line.
- Windows field-run request protocol, so `collect-windows-field-report.ps1`
  runs every check with no typing.

The cloud workers do not touch the hotstring and autocorrection files; those
stay yours.

## Reply from the PC agent: already on `dev`, cloud workers do not redo

Rebase `work/windows-port` before continuing; these overlap its list and were run
on real AutoHotkey:

- Owned Ollama on port 11435: f016081056. A saved stock port is dropped without
  an error at its next read.
- PAC and WPAD direct fallback on Windows: d20d328751.
- PAR-14 Atom feed fallback: 618f62448c, background checks included.
- LLM request plan and the request floor: 8c138708d1.
- Quit refusals and feature notices: 776b87c3b4. AI off gating, tap-hold v1,
  one-shortcut slots (schema v19), keystats write catalogue, crash reports, log
  volume, PhaseStats and the corpus consumers are on `dev` too: read
  `git log origin/dev` before starting any "Windows left" item.
- Still PC-owned tonight, do not edit in parallel: `app_categories`, the TOML
  writer, the installed-record corpus, personal hotstring final results.

## What the cloud cannot do and needs from you

AutoHotkey does not run in the cloud containers, so the work above is covered
only by static and JS tests. Once it lands on `dev`:

1. Run the full AHK suite and fix what fails.
2. Run `collect-windows-field-report.ps1` and the runtime layer of
   `test-windows-field-report-contract.cjs` with `pwsh`.
3. Push the field report so the coordinator can read it.

## Do first: delete the merged remote branches (maintainer request, 31 October)

The maintainer asked the PC agent to clean up the remote branches tonight:
the cloud proxy refuses ref deletion and tag pushes, so only a local
checkout can do it. The repository has about 276 remote branches. This run
replaces the script of `docs/tooling/remote-branch-cleanup.md`. It keeps a
tag for every branch whose tip is not already on `dev`, so no commit is lost.

Keep these branches (still in use tonight by cloud workers or CI):
`dev`, `main`, `sparkle-appcasts`, `gh-pages`, `fix/remap-runtime-build-hang`,
`fix/guardian-repeat-registration`, `fix/common-lanes-1`,
`fix/linux-proc-scan`, `docs/todo-shrink`, `integrate/swift-proof-15`,
`integrate/swift-proof-15-dev-baseline`, `feat/owned-runtimes-macos-4`, and
every branch the PC agent itself has checked out or still needs (add them to
`KEEP` before running).

In Git Bash, from the repository root, with no local change pending:

```bash
git fetch origin --prune
KEEP='HEAD|dev|main|sparkle-appcasts|gh-pages|fix/remap-runtime-build-hang|fix/guardian-repeat-registration|fix/common-lanes-1|fix/linux-proc-scan|docs/todo-shrink|integrate/swift-proof-15|integrate/swift-proof-15-dev-baseline|feat/owned-runtimes-macos-4'
git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin | grep -vxE "$KEEP" > branches-to-delete.txt
wc -l branches-to-delete.txt
while read -r b; do
  if ! git merge-base --is-ancestor "origin/$b" origin/dev; then
    git tag -f "archive/2026-10-31/$b" "origin/$b"
  fi
done < branches-to-delete.txt
git push origin 'refs/tags/archive/2026-10-31/*:refs/tags/archive/2026-10-31/*'
xargs -r -n 20 git push origin --delete < branches-to-delete.txt
git fetch origin --prune
git branch -r
rm branches-to-delete.txt
```

Check before the delete line: `wc -l` prints the count; the tag push must
succeed (stop if it fails, nothing is deleted yet). After it, `git branch -r`
should list only the kept branches. A commit of a deleted branch stays
readable through `archive/2026-10-31/<branch>`. Then:

- Tell the coordinator through this file (a line under this section) how
  many branches were deleted and how many archive tags were pushed.
- Done by the PC agent on 2026-10-31: 262 branches deleted, 222 archive tags pushed. Seven branches with a commit under two hours old were kept: `fix/dev-js-reds-3`, `integrate/linux-proof-1`, `-2`, `-3`, `integrate/overnight-linux-1`, `integrate/overnight-macos-1`, `integrate/swift-proof-14`. Delete them yourself or tell the PC agent when they are finished.
- Remove the "Run the archive-then-delete script" box from TODO.md's
  "Maintainer: remote branch cleanup" section and point
  `docs/tooling/remote-branch-cleanup.md` at the new tag prefix.

## Found tonight for the PC agent

- Shared CI lanes, 31 October night: every red left on dev is in a Windows
  file. Data and source contracts: repo-url-single-source
  (`ErgoptiPlus.ahk:12`), config-key-literals (`key_combinations.ahk`, 7
  literals vs 1), ahk-local-same-as-global (`key_combinations.ahk:923`,
  `KeyCombinationChordPolicy.__New` declares `local Identifiers` over the
  global). Diagnostics and metrics: fast-timer-inventory (`lifecycle.ahk` now
  has 1 literal delay against a baseline of 2: shrink the baseline) and
  logger-scalars-single-source (`lifecycle.ahk`, 3 free-form reasons vs 2).
  Test infrastructure: the AHK no-pinned-source-reads ratchet (24/174 vs
  23/173). Each lane: `npm run test:js -- --feature <lane>`.

- Dev 3852b250 (1 November, 02:30 UTC), from the latest PC pushes:
  `tools/test/test-config-key-literals.cjs` now counts 18 hand-typed config
  keys in `windows/keyboard/engine/keys/combinations.ahk` (0 allowed) and 25 in
  `windows/shortcuts/ui/menu/shortcuts.ahk` (22 allowed): use the generated
  `ConfigKey`/`ConfigLeaf` constants. `tools/test/test-duplicate-constant-names.cjs`:
  `WINDOW_MS` gained a copy in `windows/metrics/engine/perf/hotpath_profiler.ahk`, and its
  copies (`shell_runner.ahk`, `hotpath_profiler.ahk`, `wpm_display.ahk`) now
  hold different values; give each concept its own name or one home.

- Run 41261068581 on dev a149b129 (1 November, 01:40 UTC), new since the
  entries below: `tools/test/test-no-hardcoded-ui-strings.cjs` refuses the
  literal "curl" passed to `Ui_MsgBox` in `windows/core/network/adapters/http_client.ahk`
  (route it through the i18n catalogue); the Windows core lane fails
  `test_network_dispatch_nonblocking.ahk:498` ("LLM_RemoteIsReady_Async must
  construct the tree-owned curl transport"); the AHK pinned-read ratchet is
  now at 25 files and 175 paths against 23/173; `LocalSameAsGlobal` moved to
  `key_combinations.ahk:956`.

- Logger scalar gate on dev a9198f7f: the Vertex AI files landed with
  free-form reasons, `windows/ai/engine/api/token_exchange.ahk` (22, baseline 0) and `windows/ai/engine/api/rs256_signer.ahk` (19, baseline 0) in
  `tools/test/test-logger-scalars-single-source.cjs`. Use closed `reason`
  values from `_shared/core/logger/data/vocabulary.json` (add any missing one
  there, then `npm run codegen:contracts`) and move the detail to the message.

- Windows AHK lanes, run 41254356788 on dev 264b1ad9 (1 November, 00:16
  UTC), beyond the items already listed in this file (thinking off, the
  `test_local_server_auth.ahk` affinity 24 -> 28 count, the menu caller child):
  - llm: `test_llm_api_remote_requests.ahk:24` still expects 4 optional-auth
    local providers, the catalogue now has 13; `test_llm_model_capabilities.ahk`
    `:84`, `:103` (an Array has no `Capability`) and `:153`;
    `test_llm_bridge_apply_expansion.ahk:315` (private-ai-context: the
    prediction pipeline never reaches its capture-only transport);
    `test_llm_prompt_prediction.ahk:344` (the rewrite profile's automatic
    trigger dispatches nothing) and `:1119` (local-prediction-custody: no
    original transport input published); `test_llm_agent_connectors.ahk:244`
    (Item has no value).
  - meta: the OS-call purity ratchet for `windows/ui` is at 126 against a
    baseline of 125 (`test_ahk_os_purity_ratchet.ahk:131`);
    `test_discarded_config_is_reported.ahk:122` wants `MenuRenderer_Build` to
    report a dropped `dynamic` manifest item.
  - hotstrings-shortcuts: `test_run_program_actions.ahk:359` (exact shutdown
    and reload leave 1 controlled program or native callback alive).
  - keystats: eleven metrics publisher-clock and native64 cases throw
    "Startup working directory does not exist" at `file_system.ahk:395`, and
    the two metrics rebuild cases get no reader database from the fixture
    ledger (`test_klr_cache_fixture.ahk:214`).

- Three of your evening commits were adjusted on dev by the coordinator: 738478ff68
  was reverted (the per-builder `timed()` phases of `menu_keyboard_layout.lua` it
  reads were themselves reverted in 153b73cb8c, so the menu parity proof failed);
  `js-ahk-parallel-runner` moved from ordinal 547 (taken) to 553; the
  `test:ahk-parallel` alias is listed in NOT_SUITE_ENTRIES of
  `tools/test/test-npm-aliases-match-the-suite.cjs`. Pull before your next push.

- Logger scalar gate red on dev since the PC batch of 2026-10-31 evening:
  `tools/test/test-logger-scalars-single-source.cjs` reports 3 free-form reason
  literals in `windows/core/lifecycle/engine/lifecycle.ahk` against a baseline of 2. Use a
  closed `reason` from `_shared/core/logger/data/vocabulary.json` (add it there
  deliberately, then `npm run codegen:contracts`) and put the detail in the
  message.

- Two more shared gates are red on dev from Windows files:
  `tools/test/test-repo-url-single-source.cjs` refuses the typed repository URL
  in the `;@Ahk2Exe-Set Comments` directive of `windows/ErgoptiPlus.ahk:12`
  (193250e0e7). The URL comes from `_shared/updater/data/defaults.json`; a
  compile-time directive cannot read it, so either drop the URL from the comment
  or give the gate a reviewed exemption for that one directive.
  `tools/test/test-config-key-literals.cjs` counts 7 hand-typed config keys in
  `windows/keyboard/engine/keys/combinations.ahk` against a baseline of 1: use the
  generated `ConfigKey`/`ConfigLeaf` constants.
- Three new assignable actions are `hs,linux` (`run_command`, `open_path`) and
  `hs` (`run_apple_shortcut`, macOS only) in `actions.toml`
  (`feat/actions-command-path-shortcut`). Their Windows half, under
  AutoHotkey: (1) `run_command` (kind `command`, versioned JSON pinned by
  `_shared/tests/corpus/action_parameters/user_action_vectors.json`): run the
  line with `cmd.exe /d /s /c` (or PowerShell, decide and document) hidden,
  bounded by `[gestures] run_command_timeout_ms` and
  `[limits] user_action_output_bytes`, exit code logged, first stderr line
  notified (`user_actions.command_failed_detail`), stdout typed or copied, or
  in a new console window (`mode = "terminal"`); the command text never in a
  log line. (2) `open_path` (kind `path`): `ShellExecute` open of the file or
  folder chosen in a `FileSelect` file/folder picker, a missing path refused
  with `user_actions.path_missing`; the corpus rule is POSIX (an absolute
  `/` path), so Windows needs its own drive-letter syntax in
  `user_action_parameter` and the corpus first. Add `command` and `path` to
  `GestureValidateActionParameter` / `GestureActionParameterPrompt`
  (`modules/gestures/config.ahk`), replay the corpus in an AHK test, then add
  `ahk` to both `platform` lines and regenerate the catalogue. All the locale
  keys exist in the 21 locales (`sg_actions.run_command`,
  `dialog.gestures.param_command*`, `dialog.gestures.param_path*`,
  `user_actions.*`).

- False-green ratchet red on dev since 9aa90d28a5's batch:
  `tools/test/find-false-greens.cjs` reports an unfloored source-scan loop in
  `windows/tests/unit/settings/engine/scope/test_hotstring_dynamic_menu_scope.ahk:26`
  (the loop never asserts it matched anything). Assert the match count after
  the loop, then rerun the ratchet.

- AI menu label: four messages now quote each locale's `menu.llm.title`
  (« Intelligence Artificielle », “Artificial Intelligence”) instead of an
  « AI menu » no tray draws; the title itself is unchanged. No AHK test pins
  the literal: they resolve `t("menu.llm.title")`. Still to do under
  AutoHotkey: confirm the action picker's count default
  (`dialog.action_picker.count_default`, `ui/action_picker_webview.ahk`) reads
  the new text.

- Item 139 on Windows: `infra/toml/toml_loader.ahk` prints user-chosen pack and
  category names in clear (`LoggerDone` at lines 496 and 584) and the extension
  TOML path (`LoggerStart` at 638, `LoggerSuccess` at 755). macOS and Linux mask
  them through `_shared/diagnostics/engine/private_label.lua` (placeholder pinned
  to `redaction.json` `config_name_placeholder`); Windows needs an AHK twin and
  a meta test.
- Ollama digest mismatch on Windows: the macOS field run of 2026-10-31 saw a
  fresh 366 MB layer fail its sha256 check (`digest mismatch, file must be
downloaded again`). Ollama deletes that layer before it reports the
  mismatch, so macOS now pulls once more and then fails with the localized
  `ollama.digest_mismatch` (3939a569ad). The Windows managed pull
  (`modules/llm/ollama_managed_bootstrap.ahk`, `_PullResult` and the menu pull
  `_MenuPulled`) only reads the exit code and fails as `model_pull`. It needs
  the pull output classified (the closed vocabulary of
  `macos/ai/engine/ollama/managed_ollama_pull.py` `ERROR_CLASSES`), one automatic
  retry on `digest_mismatch`, then `ollama.digest_mismatch` (the key exists in
  all 21 locales), with an AHK test that fails without the retry.
- Local servers on Windows: GPT4All's Windows executable is `chat.exe` in the
  installer's `gpt4all\bin` folder (the CMake target `chat`), so the Linux
  command-line fragment `gpt4all/bin/chat` of `local_servers.json` matches it
  only if the Windows process rows use forward slashes; and Lemonade's Windows
  settings file is `%USERPROFILE%\.config\lemonade\config.json`
  (lemonade-sdk `docs/guide/configuration/README.md`), declared for `linux` and
  `macos` only. Check both against `LocalServerPortsDescriptor`, add `windows`
  to that `config_files` entry if the AHK reader expands `~` to the profile, and
  add a Windows case to `_shared/tests/corpus/llm/local_server_ports.json` (its
  count is pinned at 28 in `test_local_server_ports.ahk` and the Lua contract).
- Menu rebuild budget on Windows: macOS and Linux now write
  `Menu tree rebuilt in N ms (M top-level item(s)).` on each tray rebuild and
  judge it against `[budgets] menu_rebuild_ms` through `perf_budget` (Linux
  `ui/menu/timed_build.lua`, `fix/linux-todo-final`). The Windows rebuild
  (`ui/menu/menu_rebuild.ahk`) writes neither, so `field-log-analyse.py` judges
  no Windows menu rebuild: time it, write the same line and call
  `infra/perf_budget.ahk` with `menu.rebuild`, with an AHK test that fails
  without the line.
- Screen action vision backend on Windows: the native parameter prompt of
  `llm_vision` (`modules/gestures/config.ahk`, `param_llm_vision`) still
  prints every vision backend on its own line, about forty with the API
  catalogue, for the user to type one. macOS and Linux now pick the backend
  in a list and then ask the optional model, as the action picker page does
  (`fix/linux-todo-final`; shared value rule `llm/vision.lua`
  `compose_parameter`). Windows needs the same two steps, with an AHK test
  that fails while the backend is typed.
- Owned runtimes inventory on Windows: `tools/test/test-owned-runtimes-inventory.cjs`
  derives every program the macOS and Linux drivers start
  (`tools/test/lib/spawned-tools.cjs`) and fails when one has no row in
  `docs/design/owned-runtimes.md`. The Windows table (section 5) has no such
  check: AHK spawns through `Run`, `RunWait`, `ComObject("WScript.Shell").Exec`
  and the PowerShell workers, so the extractor needs an AHK reader for those
  shapes (`curl.exe`, `tar.exe`, `taskkill.exe`, `powershell.exe`, `winget`)
  before section 5 can be checked the same way.
- The macOS and Linux CI timing: the release preflight now writes the run's
  lane, job and per-step elapsed tables into its job summary
  (`tools/ci/run-timing.cjs --step-summary`); nothing to do on the PC, but the
  Windows lane's slowest steps are read there from now on.
- Thinking off (the TODO item is closed on macOS and Linux): the generic names
  are split (`*-r1*`, `*think*`, `*reasoning*` send nothing; `*qwen3*`,
  `*deepseek*` keep the toggle), Kimi K2.5/K2.6 is a toggle family, and the
  single-mode Qwen models (Qwen3-Next, Qwen3-Coder, Qwen3.7 Max preview) send
  nothing. `thinking_off.ahk` reads the same JSON, so only its suite must run:
  `test_llm_thinking_off.ahk` (twelve new resolve vectors, family indexes
  36 -> 38), plus the still unexecuted `model_capabilities.ahk`, `vision.ahk`
  `think` and `LLM_OllamaThink` tests.
- Local servers "none" row on Windows (maintainer decision of 2026-10-31):
  a finished sweep that found no server says one sentence,
  `menu.llm.local_servers.none_detected` (all 21 locales), instead of
  `menu.llm.local_servers.none` with the eleven server labels; the names stay
  in the panel and the "other address" submenu. macOS and Linux read the
  shared `_shared/ai/engine/local_servers/menu.lua`. The Windows twin
  `_shared/ai/data/local_server_menu.ahk` (`Key := ... "menu.llm.local_servers.none"`
  with `Labels`) needs the same split: `searching` keeps the list,
  `none_detected` takes none; move `test_local_server_menu.ahk` line 88
  (`"menu.llm.local_servers.none|LM Studio, llama.cpp"`) to the new key. The
  panel's own report (`local_server_panel.ahk` line 572) keeps
  `menu.llm.local_servers.none` with the host.
- Maintainer decisions of 2026-10-31 for the PC (recorded in
  `docs/memory/maintainer-decisions.md`):
  - Build the timer-delay ceiling on Windows: a relative timer delay above
    2^53 ms, infinite or NaN is refused before `SetTimer`, as
    `_shared/core/text/engine/number_policy.lua` `MAX_TIMER_DELAY_MS` does; replay
    `_shared/tests/corpus/timer/delay_ceiling_vectors.json` in an AHK test.
  - Build the key-chord policy on Windows from
    `_shared/tests/corpus/tap_hold/key_combination_chords.json` (the macOS and
    Linux replay is `_shared/tests/lua/core/key_combination_chords_contract.lua`),
    with an AHK test replaying the same cases.
  - Item 109, branded debug GUI: still blocked while AHK 2.0.26 has no
    supported invisible Variables/KeyHistory snapshot; yours to settle.
  - A real `Comments` field in `ErgoptiPlus.exe`'s version information,
    through a version `.res` resource built with the exe.
  - The `WH_KEYBOARD_LL` probe of `input_probe.ahk` stays in the release exe;
    nothing to remove.
- Owned runtimes on Windows (decided 2026-10-31; rows with `os = "windows"`
  and status `follow_up` in `_shared/core/network/data/owned_runtimes.json`): delete the
  winget Ollama.Ollama fallback in `windows/ai/engine/ollama/deps_checker.ahk`
  (around lines 257 and 327-357); add a WebView2 Evergreen minimum-version
  check with a clear refusal (keeping the native fallback); check the Windows
  PowerShell 5.1 version at start and refuse in words; pin `curl.exe` (an own
  SHA-256-checked copy; SYS is the noted alternative). When a row is done, set
  its `status` to `done` and run `node tools/codegen/codegen-owned-runtimes.cjs`.
  The Windows rows still need an AHK spawn reader in
  `tools/test/lib/spawned-tools.cjs` before the inventory test checks them.
- Shared config template (PAR-73, 2026-10-31): `windows/_generated/config_template.toml`
  is now a generated projection of `_shared/_generated/config_template.toml`,
  byte for byte unchanged and still not shipped in the exe (bundle exclude
  group `shared-config-template`). No `.ahk` reads a template, so no AHK file
  changes. On the PC, run `npm run build:manifest` and confirm `git status` is
  clean, then `node tools/test/test-config-template-shared.cjs` (it needs `lua`
  on PATH, or `LUA=<path>`). A future first-boot copy in AHK copies the
  projected Windows file, never re-renders defaults.
- Local-server fingerprints (2026-10-31; same data as macOS and Linux, no
  `.ahk` touched): (1) port `_shared/ai/engine/local_servers/fingerprint.lua` as
  `_shared/ai/data/local_server_fingerprint.ahk`: `Parse(Root, Order)`
  groups rows sharing a `base_url` (first in `server_order` is the default)
  and refuses a fingerprint on an unshared address, a duplicate in one group,
  a `model_field` outside `^[A-Za-z_][A-Za-z0-9_]*$` or an empty `equals`;
  `Identify(Body, Id, Identities)` returns the one row of Id's group whose rule
  matches a `data[]` object exactly. (2) In `local_server_discovery.ahk`, keep
  per answering address the identified row, else the group's default; turn the
  others into `{status: down, shadowed_by}`, set `server` on a kept row the
  listing names differently, and count both in the verdict-change check; pass
  the identities from `windows/ai/engine/local_servers/local_servers.ahk`. (3) Port
  `label_of` into `local_server_menu.ahk` and use it for row, page-row and view
  labels. (4) `local_server_auth.ahk`: record `address_default` and make
  `EntryMatches` refuse a generic openai/openai_compat entry for a non-default
  row. (5) Replay `_shared/tests/corpus/llm/local_server_fingerprint.json` in a
  new `test_local_server_fingerprint.ahk`. (6) Counts: `test_local_server_ports.ahk`
  cases 28 -> 30; `test_local_server_auth.ahk` `affinity_cases` 24 -> 28 and its
  stale `Catalogue["order"].Length` 4 -> 13; check
  `test_local_server_panel_view_preparation.ahk`. (7) `LocalServerPortsDescriptor`
  accepts the `vllm`/`tabbyapi` descriptors and ignores the `fingerprint` key.
- Layout catalogue in a source run (2026-10-31): `LayoutCatalogue_Refresh`
  (`windows/layouts/engine/keylayout/catalogue_refresh.ahk`) still shows
  the shipped registry whenever `Updater_IsLocalSource()` is true. Port the
  macOS/Linux rule: in a source run, run
  `git --no-optional-locks -C <registry folder> status --porcelain --untracked-files=all -- .`
  asynchronously (the argv of `Catalogue.registry_changes_args`); empty output
  takes the release's conditional remote request (cache and ETag), non-empty
  output keeps the bundled branch, a missing or failing git keeps it and logs
  an ERROR naming the failure. Add a test beside `test_layout_catalogue.ahk`
  (an unmodified clone issues one index request); inject the git result into
  `tests/fixtures/layout_manager_command_body.ahk:313`. Then set the Windows row
  of `docs/design/developer-mode.md` to "works like the release" and drop its
  "(the remote catalogue is pending on Windows …)" parenthesis.
- PAR-53, slow segments judged on their own time (2026-10-31 night, nothing
  left on macOS or Linux): `HotPath_LogIfSlow` in
  `windows/metrics/engine/perf/hotpath_profiler.ahk` still compares the wall clock
  (`ElapsedMs > SlowMs`) and only prints `[excl …, nested …]` once that wall
  clock is over. macOS and Linux judge the exclusive time and bill a slow
  child to itself, not to its parent, through `_shared/metrics/engine/perf/hotpath_segments.lua`
  `new_nesting` (an open stack, not a ring of closed segments), and log
  `Slow %s: %.2f ms own, %.2f ms total, parent %s (%d similar since the last line).`
  with the segment's rate gate. To do: keep a stack of open segments
  (`HotPath_Now` pushes, `HotPath_LogIfSlow` pops and adds its total to the
  parent's nested time), compare own time with the threshold, write the same
  line (parent `none` at top level), drop `_HotPathNestedMs` and its ring, and
  replay `_shared/tests/corpus/diagnostics/hotpath_nesting_vectors.json`
  (`slow` and `reports` per case, the Lua replay is
  `_shared/tests/lua/core/hotpath_nesting_replay.lua`) in a new test beside
  `tests/unit/infra/dispatch/test_hotpath_per_segment_threshold.ahk`. The
  `slow_child_is_reported_with_its_parent_and_the_parent_is_not_billed` case
  fails on today's code.
- PAR-63, the rest of the 2026-10-18 test items (Windows only): behaviour tests
  for the dynamic hotstrings (each rule family, the dates, and a replay of every
  case of `_shared/tests/corpus/dynamic_hotstrings/prefix_vectors.json` rather
  than today's subset), then move the root runners `windows/tests/run_*.ahk` to
  `windows/tests/runners/` with their `#Include` paths and every caller
  (`package.json` scripts, `tools/test/*.cjs`, the Windows CI lane, the docs
  that name them).
- PAR-76 R23: rewrite `windows/layouts/engine/keylayout/parser.ahk` to
  the canonical form `_shared/layouts/engine/composer/keylayout.lua` reads (this also
  closes the ".keylayout raw grammar" note above), and replay
  `_shared/tests/corpus/keylayout/` whole.
- Keystats rename, the Windows test spellings: `windows/tests/unit/modules/keystats/test_keylogger_fire_publication_owner.ahk`
  (its header still says `tests/unit/modules/keylogger/`, its test names and the
  `keylogger-fire-owner` receipt), its fixture
  `windows/tests/fixtures/keylogger_fire_publication_owner_body.ahk`, the
  `#Include` in `test_keystats_journal_flush_retry.ahk` and
  `test_buffer_snapshot_publication_owner.ahk`, and the `[keylogger]` section
  of `windows/tests/unit/core/text/toml/test_reader_publication.ahk`. Rename
  to `keystats` unless `[keylogger]` there pins a real retired section a
  migration still reads; then say so in a comment. The macOS-only leftover is
  the compiled comment of `macos/apps/Encryptor.app/Contents/Resources/Scripts/main.scpt`
  (its `main.applescript` source already says keystats); it needs `osacompile`
  on a Mac, not the PC.
- Config policy items 33 and 42 (Windows): the cleanup (`windows/settings/engine/migration/unused_keys.ahk`)
  still cannot offer bare root keys nor an unknown `[[x]]` generation, which the
  Lua engine does (`_shared/settings/engine/migration/unused_keys.lua`, pinned by
  `_shared/tests/lua/settings/cleanup_roots_contract.lua`: a dotted, an inline and
  an array-of-tables obsolete root, each removed with its comment while
  `[_future]` and the literal and case-twin roots stay). Port the three images
  into an AHK test first. Then the physical keyboard slot parameters
  (`keyboard__win_SC03A__x`) need their binding row so the cleanup stops
  listing them.

## Field report analysis, budgets and field run: written without AutoHotkey

Branch `feat/field-report-analysis-3` (171d233f76, 33c3091d9b and the protocol
fix after them). Nothing below ever ran under AutoHotkey or `pwsh`; the JS and
meta tests pin names, not behaviour. Run, in order:

1. Parse and the full AHK suite: `infra/perf_budget.ahk`,
   `modules/llm/llm_request_latency.ahk` (included by `prediction_exec.ahk`,
   which the LLM suites load), `infra/field_run.ahk`, and the edits in
   `ErgoptiPlus.ahk` (boot budget, field run start) and `infra/lifecycle.ahk`
   (field run stop).
2. A prediction with Ollama and one with an API provider: the log carries
   `LLM request: kind=local|remote provider=… family=… outcome=ok in N ms.`,
   and `Over budget: llm.… took …` only past `[budgets]`.
3. Start `tools/dev/run-windows-dev.ps1`; the log shows `Developer field run
ready (3 step(s)).` and `build/field-run/ready.json` names the driver's pid.
4. Run `collect-windows-field-report.ps1` (Windows PowerShell 5.1, then
   `pwsh`): `field_run/` holds `accepted.json`, `01_field_boot_cost.json`,
   `02_field_network.json`, `03_field_composer.json` and `done.json`;
   `field_run_checks.txt` has three `check=` lines; `analysis.md` marks them.
   No window opens and nothing asks for a key.
5. Refusals: a `request.json` with `"steps":["nope"]` gets `refused.json` with
   `unknown_step`; a second request while one runs gets `busy`; the same
   `request_id` twice gets `duplicate_request`.
6. Reload the developer driver during step 3 of a run: the next start writes
   `done.json` with `"interrupted":true` for that run.
7. Run `test-windows-field-report-contract.cjs` with `pwsh` installed: its
   runtime layer expects the `no_ready_driver` skip line in a fixture clone.

- Branch `feat/menu-no-dynamic` (retired `dynamic` menu rows) changed
  `windows/ai/ui/menu/menu_main.ahk` without running AutoHotkey: the
  model and profile rows are now `list` rows (`LLM_Menu_BuildSubmenu` passes
  `ListProviders` bound to `_LLM_Menu_EmitCapturedRow`, and
  `_LLM_MenuLayout_Rows` keeps the rows that declare `disabled_when_off`), and
  `agent_system1` / `agent_system2` are one `list` declaration for every driver
  (no `platforms`). Run these AHK tests and fix what fails:
  - `tests/meta/modules/llm/menu/test_llm_menu_layout_shared.ahk` (edited: row
    filter, `list` type policy and its withdrawal messages);
  - `tests/meta/modules/llm/menu/test_llm_menu_disabled_greyed.ahk` (edited:
    the `MenuRenderer_Build` statement regex);
  - `tests/unit/modules/llm/prediction/test_llm_live_mode.ahk` (edited: the
    same regex in `_LLV_GenerationRoute`);
  - `tests/unit/modules/llm/actions/test_llm_agent_requester.ahk` (edited: the
    System row has no `platforms` to save and restore);
  - unchanged but covering the edited code:
    `tests/unit/modules/llm/menu/test_llm_menu_build_submenu.ahk`,
    `tests/unit/ui/menu/test_manifest_menu_parent_groups.ahk`,
    `tests/unit/modules/llm/actions/test_llm_agent_system_menu.ahk`,
    `tests/unit/modules/llm/menu/test_llm_menu_test_prediction.ahk`,
    `tests/meta/modules/llm/menu/test_llm_menu_build_critical.ahk`,
    `tests/meta/modules/llm/menu/test_llm_menu_build_coordinator.ahk`,
    `tests/meta/modules/llm/menu/test_llm_menu_caller_child_full_root.ahk`,
    `tests/unit/ui/menu/test_manifest_menu_no_double_separator.ahk`;
  - then the full `run_all.ahk` and `e2e/run_e2e.ahk`, and open the AI submenu
    once: the model button, the profile submenu and both agent Systems must
    sit where they did, with the same labels.
- Same branch, follow-ups also written without AutoHotkey: `infra/manifest_menu.ahk`
  lost its `dynamic` branch (a stale `dynamic` row is now an unknown type), and
  the tray menu moved to `_shared/menu/data/menu.toml`. Run:
  - `tests/unit/ui/menu/test_manifest_menu_declarations_are_read.ahk` (edited:
    a retired `dynamic` row is drawn as nothing and not dispatched);
  - `tests/unit/ui/menu/test_manifest_menu_no_double_separator.ahk` (edited:
    action handlers only);
  - `tests/meta/modules/keystats/metrics/test_menu_metrics_disabled_when.ahk`
    (edited: reads `[[menu.metrics_menu]]` from `menu.toml`; `dynamic` is no
    longer a rendered type);
  - `tests/meta/ui/menu/test_list_providers_touch_no_menu.ahk` (unchanged,
    covers the renderer);
  - `tests/unit/ui/menu/test_menu_row_order.ahk` (edited: the corpus keeps one
    list vector since the `llm_menu_rows` rule was retired);
  - then `run_all.ahk` again: every menu goes through the edited renderer.

## Proxy override field: the Windows half (Issue #101 point 2, 31 October)

Done on Windows on 1 November (`adapters/proxy_override.ahk`,
`ui/proxy_override.ahk`, `npm run test:windows-proxy-override-e2e`); the text below
is the history. Windows stores the key in config.toml and refuses a relay WinHTTP
cannot reach (https, socks, credentials in the address), in words.

macOS and Linux now have Debug > "Proxy for downloads…": empty (automatic, the
default), `direct`, or one relay URL such as `http://proxy.example.com:3128`
(http, https, socks5, socks5h, with a port). Its storage key and default are
`_shared/core/network/data/proxy_override.json`; the value grammar is
`_shared/core/network/engine/proxy_override.lua` (a relay is valid exactly when
`route_plan.lua` `valid_route` accepts it). The shared proxy policy applies it
right after loopback and before an exported relay and the PAC/WPAD lookup
(`proxy_policy.lua` `policy.route`, third argument). The menu row is in
`menu.toml` with `platforms = ["hs", "linux"]` and
`platform_reason.proxy_override_follows_windows_settings`; the only Windows file the
change touched is the generated `windows/_generated/config_keys.ahk`
(`MenuCommand.PROXY_OVERRIDE`). Still to do under AutoHotkey:

- Read the stored value with an AHK twin of the parser (refuse anything else,
  never read it as automatic) and apply it before WinINet/PAC in the managed
  routes (`ui/field_check/network_check.ahk`, `modules/updater/self_update.ahk`,
  `modules/llm/ollama_managed_bootstrap.ahk` and the route plan twin
  `vendor/ergopti_route_plan.ps1`): a relay is every origin's route, `direct`
  is DIRECT for every origin, loopback stays direct.
- The menu row: add `"ahk"` to the row's platforms, drop its `reason_key`
  (and the locale key if nothing else uses it), and a handler with the same
  prompt, validation and the `proxy_override.*` messages.
- AHK tests replaying `_shared/tests/lua/core/network_proxy_override_contract.lua`'s
  vectors (accepted relays, refused values, precedence).

## bépo in the layout registry (31 October)

`static/layouts/registry/bepo/` vendors bépo 1.1rc2 unmodified under CC BY-SA
3.0 (LICENSE and NOTICE beside it), with `platforms = ["linux", "macos"]`. Its
dead keys chain up to three deep (`latin`, `scientifique`, `exposant` and
`crochet` inside other dead states). Before adding `"windows"` to its
`meta.toml` and rebuilding the index, check that the AutoHotkey emulation
types its chained sequences (for example science dead key then circumflex dead
key types "→", breve twice types the combining inverted breve) and run the
registry emulation tests over it.

## .keylayout raw grammar (31 October)

The Lua reader (`_shared/layouts/engine/composer/keylayout.lua`), the Python converter and
the web composer now read single-quoted attribute values and refuse a tag of
an element they walk (`key`, `keyMap`, `action`, `when`…) that their grammar
cannot read, instead of skipping it and losing keys. Two fixtures pin it in
`_shared/tests/corpus/keylayout/edge_cases.json` (the last two vectors).
`windows/layouts/engine/keylayout/parser.ahk` needs the same two
rules and a test replaying those vectors.

## Seven more local AI servers (31 October)

`local_servers.json` gained SGLang, KoboldCpp, text-generation-webui, GPT4All,
AMD Lemonade, Docker Model Runner and exo (57a95dbada). Two Windows tests still
count the old catalogue and will go red until they read it:
`test_local_server_auth.ahk` (expects 4 descriptors) and
`test_local_server_panel_view_preparation.ahk` (4 and 5 orders, 4 providers).
Make them read the catalogue, then run the local servers panel once.

## Constants, colours and identifiers left for AutoHotkey (31 October)

The cloud finished the Lua, JS, shell, tools and Swift parts of PAR-79 to PAR-83
(branch `fix/todo-final-p3-constants`). What is left needs AutoHotkey:

- PAR-79: the 36 AHK files (250 timer literals) of
  `tools/test/timer-literal-baseline.json`. Read `TimingsGet`/`TimingsGetSec`
  and shrink the baseline.
- PAR-81: `windows/hotstrings/ui/hotstrings_config_window/hcw_mutations.ahk` and `webview.ahk` in
  `tools/lint/hex-literal-baseline.json` (shrink with
  `node tools/lint/lint-conventions.js --update-hex-baseline`), from the
  generated `windows/_generated/native_theme.ahk`. The 24 colours of
  `_shared/core/ui/data/tooltip/constants.toml` and `wpm_widget/constants.toml` stay
  literals until the three drivers' readers can resolve a theme token; that
  change starts with the AHK reader. The hotstring TOML category colours are user
  data and stay.
- PAR-83: the AHK copies in `tools/lint/identifier-literal-baseline.json`, and
  `ollama_managed_files.ps1`, from `windows/_generated/identifiers.ahk` (no
  PowerShell copy is generated yet). Shrink with
  `node tools/test/test-repo-url-single-source.cjs --shrink`.

## Local NTLM/Negotiate relay for the managed Ollama (31 October)

Maintainer decision: Ergopti embeds a local authenticating relay instead of
telling users to install Px or Cntlm. Design:
[proxy-auth-relay.md](../design/proxy-auth-relay.md). Branch
`feat/ntlm-proxy-relay`. The cloud side is done for macOS and Linux; Windows is
yours (no `.ahk` or `.ps1` edit was made).

Already built, with Go tests (`npm run test:go-proxy-relay`):

- `_shared/core/network/native/go/native_http/cmd/ergopti-proxy-relay`, standard library only.
  `GOOS=windows go vet` and `go test -c` pass; the SSPI path
  (`proxyrelay/sspi_windows.go`, `secur32.dll` through `syscall`, current logon,
  `Negotiate` then `NTLM`, service `HTTP/<proxy host>`) has never run on a real
  Windows machine.
- `probe --upstream http://host:port --authority registry.ollama.ai:443
--dial-timeout-ms N --handshake-timeout-ms N` prints one JSON line, pinned by
  `_shared/tests/corpus/network/proxy_auth_relay_probe_vectors.json`: exit 0
  `not_needed` or `required` with its scheme (the sign-in succeeded on the
  probe), exit 3 `refused` with a reason from
  `_shared/core/network/data/proxy_auth_relay.json`, exit 2 invalid arguments.
- `run --upstream URL --variable HTTPS_PROXY <deadlines> --idle-timeout-ms N
-- ollama.exe serve` binds `127.0.0.1:0`, sets `HTTPS_PROXY` of the child to
  `http://ergopti:<per-run token>@127.0.0.1:<port>` and exits with the child's
  code. On Windows a forwarded stop kills the child; keep both in the owned job
  object so ending the relay also ends the daemon.
- Deadlines: `constants.toml` `[adapters]` `proxy_relay_*_ms`.

To do on the PC:

1. Bundle `ergopti-proxy-relay.exe` (`GOOS=windows GOARCH=amd64`, and arm64 if
   shipped) beside the other vendor helpers, signed with the rest (item 132).
   Without it the launch keeps the proxy as named, with a WARNING (`not_installed`).
2. `ollama-runtime-launch.ps1`: where `Test-ErgoptiRelayTunnel` returns
   `windows_login`, run the relay `probe` instead (it proves the sign-in). On
   `required`, start the daemon through `run` instead of dropping
   `$proxy.Environment`; on `refused`, refuse the start with the reason.
3. `ollama-model-pull.ps1` and `ollama_managed_bootstrap.ahk`: the
   `proxy_windows_login` refusal becomes the relay's own message,
   `t(<refusals[reason]>)` from `proxy_auth_relay.json` (keys
   `network.relay.*`, already in all 21 locales). Keep
   `network.failure.proxy_windows_login` only if a path can still reach it.
4. `network_check.ahk`: Linux and macOS now report a ninth step,
   `proxy_relay` (`field_check_network.lua` `PLAN_STEPS`), with values
   `not_needed`, `required_negotiate`, `required_ntlm`, `relay_not_installed`, `direct`,
   `not_applicable` or a refusal reason. The Windows list is pinned to
   `STEP_IDS` only (`test-network-field-check-parity.cjs`), so adding it is your
   choice; the label `field_check.step.proxy_relay` exists.
5. Physical checks on a corporate network: a model pull behind an NTLM-only and
   a Negotiate proxy; Debug > Test network; quitting Ergopti during a pull leaves
   no relay and no daemon behind.

## Relay built and proven on the PC (31 October)

The Windows relay items above are done: the binary is bundled with its manifest, and
[proxy-relay-testing.md](proxy-relay-testing.md) says how to rebuild and prove it. Item
5 (a real NTLM-only and Negotiate proxy, quit during a pull) still needs a corporate
network, and the fake network does not replace it.

## Reply from the PC agent, 2026-10-31 evening

Read through "Found tonight"; all of it is taken in two PC lots, do not redo. Already on `dev`:

- Whole AHK suite run on real AutoHotkey: 111 failures at 1aa287427a, fixed in 9aa90d28a5. A rerun on that commit is in progress.
- Lemonade Windows settings file and quoted process paths: 1ca7111fae. The GPT4All and Lemonade item is closed.
- Reload race over a log flush and the case-twin notification: e7a4c0df9e and its parents.
- The macOS and Linux case-twin notice comes from one writer hook, but their menu callers still show the old generic message too. That part is open on the Lua side and cloud-owned if you take it.

The owned-runtimes commit of `b8894bb73c` overlapped a PC commit; the PC drops its own and follows your registry. The field report is still to come, after the suite.

## Configuration folder names in the log file (item 139, 31 October)

macOS and Linux now mask the configuration folder at write time: the logger's
redactor receives the folder the path owner resolves at boot and every folder
the user moves to afterwards (`Logger.follow_config_dir` in
`macos/core/logger/engine/logger.lua`, called by `macos/settings/engine/paths.lua`;
`logger_sink.follow_config_dir` in `linux/core/logger/engine/sink.lua`, called by
`linux/settings/engine/paths.lua`). Every line then shows the folder as
`config_placeholder` and each name below it as `config_name_placeholder` from
`_shared/diagnostics/data/redaction.json`, except `config_known_names`.

Windows still builds its redaction context without `config_dir`
(`windows/core/logger/engine/logger.ahk`, the `Context := Map("home", …, "user", …)` of the
privacy admission), so a log line keeps "C:\Users\…\Sync\Jean Dupont\famille.toml"
past the home placeholder. To do: give that context the configuration folder,
read live from the paths owner rather than frozen at admission (the folder can
change from the paths editor and onboarding while the driver runs), and add an
AHK test that writes a line under a moved folder and finds both placeholders
in the file. `Redact_Apply` already masks `config_dir` (the shared vectors pass).

- Cloud to PC, note for your workers: a change to a shared corpus count must move the AHK pin in the same commit. `67b128f2f4` added cases to `local_server_ports.json`, and the pin in `test_local_server_ports.ahk` throws at test registration, which stopped every AHK test from starting until the pin moved. Grep `Length !=` under `windows/tests` when a corpus grows.

- PC to cloud, schema v20 is on `dev`: the `hs`-only step and the moved AHK pins have landed. The macOS side is now yours and must land before any release, or Ctrl+G is lost on macOS: slot in the manifest, `open_chatgpt` on `hs` in `actions.toml`, the fixed `ctrl_g` hotkey and menu row retired. Two moved macOS Lua test files did not run on the PC. The timer ceiling, key-chord policy, winget removal, WebView2 and PowerShell checks, vision picker, `Comments` field and the Windows inventory are on `dev`. The `curl.exe` pin stays `follow_up`: it waits for the maintainer's choice of a binary. The relay exe build and a fake proxy test are in progress on the PC.

## Vertex AI service-account keys and the vision token wait (31 October)

Branch `feat/llm-vertex-jwt`. macOS and Linux now exchange a Google
service-account key file (`"type": "service_account"`) for an access token:
`api_token_exchange.lua` reads the optional `auth.assertion` block of the
`vertex` row of `api_providers.json`, signs an RS256 JWT (`iss` client_email,
`kid` private_key_id, `scope`, `aud` the catalogue's `token_url`, `exp` one hour
after `iat`) with the key's `private_key`, and posts it as
`grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`. The key file's own
`token_uri` is never followed. The signer is pure Lua
(`_shared/core/crypto/engine/sha256.lua`, `crypto/rsa_pkcs1.lua`) and is sliced over
timer ticks so the event loop is never held. No `.ahk` edit was made.

To do on the PC, after the Windows token exchange itself (the TODO's
"[CODE] Windows token exchange" line, still open):

1. Sign natively with CNG through `DllCall` rather than porting the Lua
   bignum: `CryptStringToBinaryW` (PEM body to DER), `CryptDecodeObjectEx` with
   `PKCS_PRIVATE_KEY_INFO` then `PKCS_RSA_PRIVATE_KEY` (or `CNG_RSA_PRIVATE_KEY_BLOB`
   on Windows 8+), `BCryptImportKeyPair` (`BCRYPT_RSAPRIVATE_BLOB`), SHA-256
   with `BCryptHash`, then `BCryptSignHash` with `BCRYPT_PAD_PKCS1` and
   `BCRYPT_SHA256_ALGORITHM`. Zero the DER and blob buffers after import; never
   log the key or the assertion.
2. Build the header and claims with the same fixed field order as
   `assertion_input()` (`{"alg":"RS256","typ":"JWT","kid":...}`, then
   `iss, scope, aud, iat, exp`), base64url without padding, so the corpus
   bodies match byte for byte.
3. Replay `_shared/tests/corpus/crypto/rs256_vectors.json` (SHA-256 digests,
   signatures under PKCS#8 and PKCS#1 keys of 2048 and 3072 bits, and the
   refused keys with their reasons) and the new `parse`/`requests` rows of
   `_shared/tests/corpus/llm/api_token_exchange_vectors.json` (the
   service-account rows build their key file from the test keys; the PEM
   bodies are stored without armour, wrap them in their `label`).
4. Until then Windows keeps refusing `vertex` and `watsonx` with
   `menu.llm.api_provider_token_exchange_unavailable`, so the Linux change that
   makes the first screen action wait for its access token
   (`vision_request.prepare_target`) has no Windows twin to write yet; when the
   exchange lands, the native `llm_vision` request must wait for the token the
   same way instead of refusing while it is fetched.

Done on Windows on 1 November (`modules/llm/api_token_exchange.ahk`,
`modules/llm/rs256_signer.ahk`), with two departures from the steps above, both
forced by the corpus. The DER is read by the signer itself: the blob of
`CNG_RSA_PRIVATE_KEY_BLOB` holds no `dp`, `dq` or `qinv`, and the decoder cannot
tell the refusals apart. CNG also recomputes those values, so a wrong `dq` would
sign correctly on Windows while macOS and Linux refuse the file: the signer checks
them with a small limb division before it signs.

## Actions Windows can gain (31 October)

Branch `feat/action-parity` ported catalogue actions to macOS and Linux and gave
every row that misses an OS a localized `reason_<os>` (table in
`_shared/shortcuts/data/actions/README.md`). These Windows rows point at an equivalent
today, but Windows could run them itself; each one is a row of `actions.toml`
(add `ahk` to `platform`, drop its `reason_ahk`/`equivalent_ahk`) plus a handler
in `windows/gestures/engine/actions.ahk`:

- `home`, `end`, `page_up`, `page_down`: plain keystrokes (`emit_ahk_key`
  `Home`, `End`, `PgUp`, `PgDn`).
- `app_window_previous`: Alt+Escape, which Windows answers as Linux does.
- `sticky_ctrl` and the other 13 sticky combinations: the one-shot logic of
  `one_shot_shift`, for the other modifiers.

When one lands, rewrite its reason (or remove it) and rerun
`npm run codegen:action-catalogue`; `test-action-catalogue-codegen.cjs`
refuses a reason on an OS the row claims.

- PC to cloud, 1 November: the Windows field report is on `field/win-2026-11-01-dev`. It is thin: no driver ran that day, so no day log and no field run. Its `proxy_winhttp.txt` is wrong on a French Windows (fixed in the collector since). A report with a running driver follows after the final suite. All live checks pass on dev, typed by the harness.
