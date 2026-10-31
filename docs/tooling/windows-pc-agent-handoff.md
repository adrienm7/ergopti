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
  `_shared/modules/llm/thinking_off_vectors.json`; 400 retry with persisted
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

## Found tonight for the PC agent

- False-green ratchet red on dev since 9aa90d28a5's batch:
  `tools/test/find-false-greens.cjs` reports an unfloored source-scan loop in
  `windows/tests/unit/infra/config/scope/test_hotstring_dynamic_menu_scope.ahk:26`
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
  them through `_shared/lua/diagnostics/private_label.lua` (placeholder pinned
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
  `macos/modules/llm/managed_ollama_pull.py` `ERROR_CLASSES`), one automatic
  retry on `digest_mismatch`, then `ollama.digest_mismatch` (the key exists in
  all 21 locales), with an AHK test that fails without the retry.
- PAR-41 on macOS (`ctrl_g` to the `secondary_g` slot) needs a config schema
  v20 step (`shortcuts.keys.ctrl_g` copied into `shortcuts.keyboard.secondary_g`,
  `true` to `open_chatgpt`, `false` to `none`, then deleted, for `hs` only). A
  bump moves every driver's stamp: the AHK tests that treat 19 as current
  (`tests/unit/infra/config/persistence/test_config_snapshot_inline_records.ahk`,
  `test_config_semantic_snapshot.ahk`,
  `tests/unit/infra/config/migration/test_config_journal_boot.ahk`,
  `test_config_journal_nul_suffix.ahk`) must move to 20 and pass under
  AutoHotkey first. The macOS side follows (manifest slot, `open_chatgpt` on
  `hs` in `actions.toml`, the fixed `ctrl_g` hotkey and its menu row retired).
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
  shared `_shared/lua/llm/local_server_menu.lua`. The Windows twin
  `_shared/modules/llm/local_server_menu.ahk` (`Key := ... "menu.llm.local_servers.none"`
  with `Labels`) needs the same split: `searching` keeps the list,
  `none_detected` takes none; move `test_local_server_menu.ahk` line 88
  (`"menu.llm.local_servers.none|LM Studio, llama.cpp"`) to the new key. The
  panel's own report (`local_server_panel.ahk` line 572) keeps
  `menu.llm.local_servers.none` with the host.
- Maintainer decisions of 2026-10-31 for the PC (recorded in
  `docs/memory/maintainer-decisions.md`):
  - Build the timer-delay ceiling on Windows: a relative timer delay above
    2^53 ms, infinite or NaN is refused before `SetTimer`, as
    `_shared/lua/number_policy.lua` `MAX_TIMER_DELAY_MS` does; replay
    `_shared/tests/corpus/timer/delay_ceiling_vectors.json` in an AHK test.
  - Build the key-chord policy on Windows from
    `_shared/tests/corpus/tap_hold/key_combination_chords.json` (the macOS and
    Linux replay is `_shared/lua/test/key_combination_chords_contract.lua`),
    with an AHK test replaying the same cases.
  - Item 109, branded debug GUI: still blocked while AHK 2.0.26 has no
    supported invisible Variables/KeyHistory snapshot; yours to settle.
  - A real `Comments` field in `ErgoptiPlus.exe`'s version information,
    through a version `.res` resource built with the exe.
  - The `WH_KEYBOARD_LL` probe of `input_probe.ahk` stays in the release exe;
    nothing to remove.
- Owned runtimes on Windows (decided 2026-10-31; rows with `os = "windows"`
  and status `follow_up` in `_shared/data/owned_runtimes.json`): delete the
  winget Ollama.Ollama fallback in `windows/modules/llm/ollama_deps_checker.ahk`
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
  `.ahk` touched): (1) port `_shared/lua/llm/local_server_fingerprint.lua` as
  `_shared/modules/llm/local_server_fingerprint.ahk`: `Parse(Root, Order)`
  groups rows sharing a `base_url` (first in `server_order` is the default)
  and refuses a fingerprint on an unshared address, a duplicate in one group,
  a `model_field` outside `^[A-Za-z_][A-Za-z0-9_]*$` or an empty `equals`;
  `Identify(Body, Id, Identities)` returns the one row of Id's group whose rule
  matches a `data[]` object exactly. (2) In `local_server_discovery.ahk`, keep
  per answering address the identified row, else the group's default; turn the
  others into `{status: down, shadowed_by}`, set `server` on a kept row the
  listing names differently, and count both in the verdict-change check; pass
  the identities from `windows/modules/llm/local_servers.ahk`. (3) Port
  `label_of` into `local_server_menu.ahk` and use it for row, page-row and view
  labels. (4) `local_server_auth.ahk`: record `address_default` and make
  `EntryMatches` refuse a generic openai/openai_compat entry for a non-default
  row. (5) Replay `_shared/tests/corpus/llm/local_server_fingerprint.json` in a
  new `test_local_server_fingerprint.ahk`. (6) Counts: `test_local_server_ports.ahk`
  cases 28 -> 30; `test_local_server_auth.ahk` `affinity_cases` 24 -> 28 and its
  stale `Catalogue["order"].Length` 4 -> 13; check
  `test_local_server_panel_view_preparation.ahk`. (7) `LocalServerPortsDescriptor`
  accepts the `vllm`/`tabbyapi` descriptors and ignores the `fingerprint` key.

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
  `windows/ui/menu/menu_llm/menu_main.ahk` without running AutoHotkey: the
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
  the tray menu moved to `_shared/modules/menu/menu.toml`. Run:
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
- PAR-81: `windows/ui/hotstrings_config_window/hcw_mutations.ahk` and `webview.ahk` in
  `tools/lint/hex-literal-baseline.json` (shrink with
  `node tools/lint/lint-conventions.js --update-hex-baseline`), from the
  generated `windows/_generated/native_theme.ahk`. The 24 colours of
  `_shared/modules/tooltip/constants.toml` and `wpm_widget/constants.toml` stay
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

- `_shared/go/native_http/cmd/ergopti-proxy-relay`, standard library only.
  `GOOS=windows go vet` and `go test -c` pass; the SSPI path
  (`proxyrelay/sspi_windows.go`, `secur32.dll` through `syscall`, current logon,
  `Negotiate` then `NTLM`, service `HTTP/<proxy host>`) has never run on a real
  Windows machine.
- `probe --upstream http://host:port --authority registry.ollama.ai:443
--dial-timeout-ms N --handshake-timeout-ms N` prints one JSON line, pinned by
  `_shared/tests/corpus/network/proxy_auth_relay_probe_vectors.json`: exit 0
  `not_needed` or `required` with its scheme (the sign-in succeeded on the
  probe), exit 3 `refused` with a reason from
  `_shared/modules/network/proxy_auth_relay.json`, exit 2 invalid arguments.
- `run --upstream URL --variable HTTPS_PROXY <deadlines> --idle-timeout-ms N
-- ollama.exe serve` binds `127.0.0.1:0`, sets `HTTPS_PROXY` of the child to
  `http://ergopti:<per-run token>@127.0.0.1:<port>` and exits with the child's
  code. On Windows a forwarded stop kills the child; keep both in the owned job
  object so ending the relay also ends the daemon.
- Deadlines: `constants.toml` `[adapters]` `proxy_relay_*_ms`.

To do on the PC:

1. Bundle `ergopti-proxy-relay.exe` (`GOOS=windows GOARCH=amd64`, and arm64 if
   shipped) beside the other vendor helpers, signed with the rest (item 132).
   A missing binary is the refusal `relay_unavailable`.
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
   `not_needed`, `required_negotiate`, `required_ntlm`, `direct`,
   `not_applicable` or a refusal reason. The Windows list is pinned to
   `STEP_IDS` only (`test-network-field-check-parity.cjs`), so adding it is your
   choice; the label `field_check.step.proxy_relay` exists.
5. Physical checks on a corporate network: a model pull behind an NTLM-only and
   a Negotiate proxy; Debug > Test network; quitting Ergopti during a pull leaves
   no relay and no daemon behind.
