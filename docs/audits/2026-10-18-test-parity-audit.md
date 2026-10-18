<!-- docs/audits/2026-10-18-test-parity-audit.md -->

# Audit: test parity across the three drivers

Run on 2026-10-18 against `dev` at `25f2c426a4`. Scope: the Windows
(AutoHotkey), macOS (Hammerspoon Lua) and Linux (LuaJIT) test trees, the shared
corpus (`_shared/tests/corpus`), the shared Lua contracts (`_shared/lua/test`)
and the JS gate (`tools/test`). No test was run and no test or source file was
changed; every number below comes from static census scripts over
`git ls-files`.

Maintainer goal: the three OS ship the same features, so they should carry
roughly the same kind and number of tests, without duplicates or useless tests,
in tidy trees.

## Headline

- **Raw counts are not the parity problem.** Windows registers 9,588 tests,
  macOS 11,449 and Linux 6,579. macOS and Linux also each run about 940 cases
  from 105 shared Lua contracts that this census does not attribute to them.
  Per thousand lines of production code that is 46 (Windows), 55 (macOS) and
  65 (Linux) tests: Linux has half the code, and its density is the highest.
- **The kinds of tests differ more than the counts.** 26% of Windows tests
  inspect production source rather than call it. The rate is 15% on macOS and
  21% on Linux. The Windows rate comes from one design decision:
  `windows/tests/run_all.ahk:14-18` deliberately does not include `modules/`,
  so module-level behaviour can only be asserted on source text.
- **Three Linux conformance skips are stale and their guards are false-green.**
  They claim that Linux has no reply parser, no PromptBuilder and no shared
  locale cascade. Linux uses all three. This is the most concrete parity gap
  found (work item 1).
- **Five near-verbatim duplicate files exist, all in the Lua drivers.** The
  worst is `linux/tests/unit/adapters/test_system_proxy.lua`, whose 13 tests
  are all repeated in `test_system_proxy_callbacks.lua`.
- **Tree tidiness is the largest structural gap.** Windows keeps 1,407 test
  files flat in two directories. macOS has two `meta/` directories. Linux's
  `unit/meta/` holds 121 files, yet 83% of their tests are behaviour tests.

## Method

1. **Features.** `_shared/modules/features/manifest.toml` declares 369 feature
   entries. 133 of them ship on all three drivers. The other 236 are
   platform-restricted: 70 macOS-only gesture modes and sensitivities, the
   Windows-only `shortcuts.keyboard.win_*` and `shortcuts.personal.*`, and the
   Linux-only `mod_combos`. A gap on a driver that does not ship the feature is
   not counted.
2. **Tests.** A test is one registration: `Test("…")` in AHK, `*.it("…")` in
   Lua, `def test_*` in the Linux hardware Python, and
   `test/it/check("…")` in JS. Dynamic names built by concatenation are
   counted once per registration site.
3. **Kinds.** For each test, the census inspects the test body and the AHK
   function the test names. It also follows file-local helpers that the body
   calls. A test is _source_ when that code reads production source
   (`_Driver*`, `FileRead` of an `.ahk` path, `read_driver_source`, or
   `io.open` of a driver `.lua` path). Otherwise it is _behaviour_. Tests under
   `e2e/` count as _e2e_, and tests under `hardware/`, `distro/` and `startup/`
   count as _native_. The classification is a heuristic and errs toward
   _behaviour_.
4. **Feature families.** A test counts for a family when its path or its name
   matches the family keywords. One test can count for several families. The
   counts measure relative weight; they are not an exact attribution.
5. **Duplicates.** Two checks: identical normalized test names that appear in
   different files of one driver, and file pairs whose distinctive lines
   overlap by at least 60%. Lines that appear in more than six files are
   ignored. Every pair cited below was then compared by hand with `diff`.

## Totals per driver

| Driver  | Tests  | Behaviour | Source inspection | E2E / native                        | Test files | Files > 800 lines |
| ------- | ------ | --------- | ----------------- | ----------------------------------- | ---------- | ----------------- |
| Windows | 9,588  | 7,101     | 2,483 (26%)       | 4 E2E registrations, 2 hardware     | 1,428      | 71                |
| macOS   | 11,449 | 9,739     | 1,681 (15%)       | 4 E2E registrations, boot scenarios | 1,494      | 66                |
| Linux   | 6,579  | 5,133     | 1,352 (21%)       | 94 hardware (88 Python)             | 449        | 43                |
| JS gate | 1,570  | n/a       | n/a               | 441 suite checks in 9 feature files | 99         | 55                |

All three E2E harnesses replay the same shared hotstring corpus
(`windows/tests/e2e/run_e2e.ahk`, `macos/tests/e2e/run_e2e.lua`,
`linux/tests/e2e/run_e2e.lua`), plus boot or startup scenarios on macOS and
Linux. E2E coverage is equal but narrow: on every driver it covers hotstrings
only.

## Feature-family matrix

Format: total (b = behaviour / s = source inspection, n = native). The ratio
column is the largest driver count divided by the smallest.

| Family                                   | Windows          | macOS             | Linux              | JS  | Ratio |
| ---------------------------------------- | ---------------- | ----------------- | ------------------ | --- | ----- |
| Hotstring engine core                    | 1006 (b796/s210) | 617 (b427/s190)   | 871 (b607/s264)    | 35  | 1.6   |
| Capsword                                 | 23 (b3/s20)      | 46 (b39/s7)       | 30 (b29/s1)        | 0   | 2.0   |
| Magic key                                | 82 (b66/s16)     | 113 (b104/s9)     | 135 (b67/s68)      | 2   | 1.6   |
| SFB / distances reduction                | 2 (b1/s1)        | 2 (b1/s1)         | 2 (b1/s1)          | 2   | 1.0   |
| Autocorrection (incl. French)            | 21 (b20/s1)      | 29 (b7/s22)       | 9 (b3/s6)          | 0   | 3.2   |
| Dynamic hotstrings                       | 18 (b12/s6)      | 145 (b96/s49)     | 41 (b17/s24)       | 0   | 8.1   |
| Personal hotstrings / editor             | 238 (b200/s38)   | 192 (b99/s93)     | 109 (b67/s42)      | 0   | 2.2   |
| Personal info editor                     | 33 (b24/s9)      | 71 (b35/s36)      | 19 (b2/s17)        | 0   | 3.7   |
| Hotstring preview tooltips               | 347 (b233/s114)  | 343 (b277/s66)    | 103 (b88/s15)      | 2   | 3.4   |
| Tap keys / tap-hold                      | 347 (b215/s132)  | 121 (b94/s27)     | 325 (b168/s157)    | 0   | 2.9   |
| Key combination taps / mod combos        | 130 (b111/s19)   | 99 (b81/s18)      | 331 (b251/s78/n2)  | 0   | 3.3   |
| Wrap symbols / selection                 | 131 (b73/s58)    | 141 (b107/s34)    | 65 (b54/s11)       | 5   | 2.2   |
| Case transforms                          | 23 (b20/s3)      | 14 (b14/s0)       | 50 (b46/s4)        | 1   | 3.6   |
| Keyboard shortcuts                       | 363 (b209/s154)  | 966 (b867/s99)    | 409 (b361/s48)     | 8   | 2.7   |
| Script control (pause, suspend, reload)  | 480 (b238/s242)  | 656 (b577/s79)    | 169 (b118/s51)     | 3   | 3.9   |
| Gestures                                 | 179 (b98/s81)    | 619 (b521/s98)    | 147 (b133/s14)     | 2   | 4.2   |
| Layout / keymap / AltGr / Kana           | 615 (b437/s178)  | 1263 (b1118/s145) | 408 (b278/s124/n6) | 63  | 3.1   |
| Remap install (Karabiner, registry, XKB) | 106 (b92/s14)    | 1215 (b1081/s134) | 7 (b5/s2)          | 2   | 174   |
| Metrics / keylogger                      | 934 (b645/s289)  | 1308 (b1241/s67)  | 312 (b259/s53)     | 67  | 4.2   |
| WPM widget / menubar                     | 67 (b24/s43)     | 64 (b54/s10)      | 52 (b51/s1)        | 0   | 1.3   |
| LLM predictions + navigation             | 521 (b471/s50)   | 285 (b271/s14)    | 199 (b168/s31)     | 0   | 2.6   |
| LLM models / servers / download          | 557 (b485/s72)   | 723 (b570/s153)   | 128 (b110/s18)     | 225 | 5.6   |
| LLM profiles / prompts                   | 204 (b154/s50)   | 353 (b343/s10)    | 184 (b169/s15)     | 41  | 1.9   |
| LLM agent / translate / vision / tone    | 173 (b142/s31)   | 243 (b227/s16)    | 218 (b129/s88/n1)  | 18  | 1.4   |
| LLM remote API providers                 | 122 (b111/s11)   | 90 (b83/s7)       | 47 (b46/s1)        | 0   | 2.6   |
| Menu / tray rendering                    | 832 (b554/s278)  | 2235 (b1742/s493) | 458 (b283/s174)    | 17  | 4.9   |
| Onboarding                               | 62 (b38/s24)     | 191 (b176/s15)    | 34 (b29/s5)        | 0   | 5.6   |
| Updater                                  | 409 (b277/s132)  | 194 (b170/s24)    | 194 (b163/s31)     | 39  | 2.1   |
| Config TOML / defaults / scope           | 1600 (b1333/…)   | 1630 (b1240/…)    | 1032 (b682/…)      | 136 | 1.6   |
| Config migrations                        | 138 (b112/s26)   | 49 (b43/s6)       | 31 (b17/s14)       | 1   | 4.5   |
| Backup / restore / reset                 | 402 (b274/s128)  | 514 (b432/s82)    | 253 (b167/s86)     | 26  | 2.0   |
| Diagnostics / healthcheck                | 237 (b191/s46)   | 222 (b194/s28)    | 171 (b83/s40)      | 58  | 1.4   |
| Logging                                  | 1045 (b664/s381) | 1726 (b1631/s95)  | 383 (b275/s106)    | 29  | 4.5   |
| i18n / locale                            | 98 (b67/s31)     | 90 (b75/s15)      | 79 (b58/s21)       | 22  | 1.2   |
| Clipboard / selection                    | 189 (b114/s75)   | 236 (b210/s26)    | 157 (b109/s48)     | 11  | 1.5   |
| Synthetic input / text sender            | 266 (b207/s59)   | 164 (b144/s20)    | 75 (b72/s3)        | 1   | 3.5   |
| Startup / boot / shutdown                | 612 (b442/s170)  | 827 (b642/s181)   | 124 (b95/s29)      | 95  | 6.7   |
| Process / shell runner                   | 224 (b165/s59)   | 188 (b152/s36)    | 153 (b134/s15)     | 33  | 1.5   |
| HTTP / network                           | 350 (b264/s86)   | 336 (b285/s26)    | 424 (b373/s21)     | 161 | 1.3   |
| File system / watchers                   | 109 (b59/s50)    | 387 (b298/s89)    | 131 (b110/s21)     | 1   | 3.6   |
| Secure field detection                   | 29 (b14/s15)     | 37 (b37/s0)       | 15 (b15/s0)        | 0   | 2.5   |
| Window info / focus / app detection      | 98 (b60/s38)     | 127 (b120/s7)     | 144 (b120/s20)     | 1   | 1.5   |

Reading notes:

- **Remap install (ratio 174) is mostly legitimate.** macOS owns a large
  Karabiner lease and guardian subsystem (`macos/platform/remap/init.lua` alone
  is 305 KB). The Windows registry emulation and the Linux XKB plan are much
  smaller, and Linux tests its XKB plan natively in
  `linux/tests/hardware/run_xkb_*.lua`. Do not chase this ratio. Chase the
  missing kinds instead: there is no unit-level XKB plan test on Linux.
- **Gestures (ratio 4.2) is partly legitimate.** 70 gesture entries are
  macOS-only. The 29 swipes that ship on macOS and Linux are still thin, see
  work item 12.

## Shared single sources and who consumes them

The shared corpus and contracts are the cheapest parity tool: one vector file,
three consumers. They are not consumed uniformly.

| Shared source                                                  | Windows | macOS | Linux             | Note                                                                      |
| -------------------------------------------------------------- | ------- | ----- | ----------------- | ------------------------------------------------------------------------- |
| `corpus/llm/parser_test_vectors.json`                          | yes     | yes   | skip (stale)      | `linux/modules/llm/prediction_engine.lua:30` requires `llm.parser`        |
| `corpus/prompt_builder/vectors.json`                           | yes     | yes   | skip (stale)      | `prediction_engine.lua:28`, `api_remote.lua:37` load `llm.prompt_builder` |
| `corpus/locale/resolution_vectors.json`                        | yes     | yes   | replayed and skip | skip contradicts `test_corpus_locale_resolution.lua`                      |
| `corpus/llm/tone_vectors.json`                                 | yes     | yes   | no                | Linux has `modules/llm` tone tests but not the vectors                    |
| `corpus/llm/process_prediction_vectors.json`                   | yes     | yes   | no                |                                                                           |
| `corpus/llm/local_model_presence.json`                         | yes     | no    | yes               |                                                                           |
| `corpus/keylogger/*`                                           | yes     | yes   | no                | aggregation corpus                                                        |
| `corpus/http/get_redirect_vectors.json`                        | no      | yes   | yes               | Windows managed GET redirect policy                                       |
| `corpus/file_selection/*`                                      | no      | yes   | yes               |                                                                           |
| `corpus/menu/*` (singular)                                     | no      | yes   | yes               |                                                                           |
| `corpus/keymap/magic_source_tap_claims.json`                   | yes     | no    | no                | macOS and Linux magic-source tests use other fixtures                     |
| `corpus/network/*`                                             | yes     | no    | no                | managed network failure vectors                                           |
| `_shared/lua/test/*_contract.lua` (105 files, about 980 cases) | no      | yes   | yes               | Windows reimplements its own; see work item 11                            |
| `document_lease_contract`, `download_document_contract`        | no      | no    | yes               | `linux/tests/unit/ui/test_document_lease_contract.lua:6-7`                |
| `response_error_contract`                                      | no      | no    | yes               | `linux/tests/unit/modules/llm/test_api_remote.lua:328`                    |
| `user_model_records_contract`                                  | no      | yes   | no                | `macos/tests/unit/ui/menu/test_config_unused_source_shapes.lua:42`        |

The conformance ledger (`_shared/tests/conformance/manifest.json`) records
seven Linux skips. Three of them are wrong today. Each guard checks a different
thing from what the rationale claims:

- `linux/tests/unit/meta/test_corpus_cross_driver.lua:234` probes
  `require("modules.llm.parser")`. The real module is the shared `llm.parser`,
  so the guard stays green although Linux has a parser.
- `test_corpus_cross_driver.lua:274` only searches `ergopti_hotstrings.lua` for
  `llm.prompt_builder`. The engine modules load it.
- `test_corpus_cross_driver.lua:435` says Linux does not replay the shared
  locale cascade. `linux/infra/locale.lua:25` requires `locale.core`, and
  `linux/tests/unit/meta/test_corpus_locale_resolution.lua` replays the vectors.

## Ranked parity work items

Suggested locations follow the tidy tree proposed at the end of this report.

1. **Linux: replay the LLM parser and PromptBuilder corpora, and retire the
   three stale skips.** Add `linux/tests/unit/modules/llm/test_corpus_llm_parser.lua`
   and `test_corpus_prompt_builder.lua`, mirroring
   `macos/tests/unit/meta/test_corpus_llm_parser.lua` and
   `test_corpus_prompt_builder.lua`. Then remove `CONF-LINUX-LLM-PARSER`,
   `CONF-LINUX-PROMPT-BUILDER` and `CONF-LINUX-LOCALE-CASCADE` from the ledger
   and from `test_corpus_cross_driver.lua:214-280,435`. Kind: behaviour
   (corpus replay). The skip guards are false-green today.
2. **Linux: consume the remaining LLM vectors.** Replay `tone_vectors.json` and
   `process_prediction_vectors.json` in `linux/tests/unit/modules/llm/`, next to
   the existing translate, vision, agent and rewrite consumers. Kind: behaviour.
   The same move closes most of the Linux "LLM predictions" gap
   (199 tests against 521 on Windows).
3. **Windows: dynamic hotstrings.** Windows has 18 tests (12 behaviour), against
   145 on macOS and 41 on Linux. `windows/modules/dynamic_hotstrings/` has two
   modules, and `user_code.ahk` alone is 23 KB. Add behaviour tests for rule
   families, date expansion and the prefix rules, and widen the replay of
   `corpus/dynamic_hotstrings/prefix_vectors.json`, which Windows runs only
   from `meta/test_corpus_dynamic_hotstrings_prefix.ahk` (2 tests). Put them in `windows/tests/unit/hotstrings/dynamic/`.
4. **Windows: capsword behaviour.** Windows has 23 tests, of which 20 inspect
   source (`meta/test_capsword_*.ahk`). macOS has 39 behaviour tests and Linux 29. Drive the capsword state machine through its infra entry points. Mirror
   `macos/tests/unit/platform/remap/test_watchers_capsword*.lua` and
   `linux/tests/unit/modules/test_caps_word_*.lua`. Location:
   `windows/tests/unit/hotstrings/test_capsword.ahk`.
5. **Linux: personal info editor.** Linux has 19 tests, of which 2 are
   behaviour; macOS has 35 behaviour tests and Windows 24. Add bridge-handler
   behaviour tests (save, validation, trigger-char sync), mirroring
   `macos/tests/unit/modules/dynamic_hotstrings/test_personal_info*.lua`.
   Location: `linux/tests/unit/ui/personal_info_editor/`.
6. **Linux: startup and shutdown lifecycle.** Linux has 124 tests, against 612
   on Windows and 827 on macOS. `linux/tests/e2e/startup_scenarios.lua` has 7
   scenarios; `macos/tests/e2e/boot/boot_scenarios.lua` has 12. Add init-order,
   shutdown-pairing and fatal-boot behaviour tests in
   `linux/tests/unit/infra/startup/`, and the missing boot scenarios to the
   E2E file.
7. **Linux: metrics and logging.** Metrics has 312 tests, against 934 and 1,308.
   Logging has 383, against 1,045 and 1,726. Add a Linux consumer of
   `corpus/keylogger` aggregation, which Windows and macOS already replay, and
   logger sink and privacy behaviour, mirroring
   `macos/tests/unit/lib/test_logger_*.lua`. Location:
   `linux/tests/unit/modules/keylogger/` and `linux/tests/unit/infra/logger/`.
8. **Linux: LLM models, servers and downloads.** Linux has 128 tests, against
   557 and 723. Start with the shared `user_model_records_contract`, which runs
   on macOS only. Then add the download window's owner and callback tests,
   which macOS has under `unit/ui/menu/menu_llm/download/` (7 files). Location:
   `linux/tests/unit/modules/llm/models/`.
9. **macOS: consume the Linux-only shared contracts.** Register
   `document_lease_contract`, `download_document_contract` and
   `response_error_contract` in `macos/tests/unit/ui/` and
   `macos/tests/unit/modules/llm/`. Replay `corpus/llm/local_model_presence.json`.
   Kind: behaviour; the cost is small because the contracts already exist.
10. **Windows: consume the macOS and Linux corpora it skips.** Replay
    `corpus/http/get_redirect_vectors.json` against the Windows managed HTTP
    client, plus `corpus/menu`, and `corpus/file_selection` if the Windows
    gesture file-selection actions (`modules/gestures/system_actions.ahk`) are
    meant to match. Location:
    `windows/tests/unit/adapters/`, `windows/tests/unit/ui/menu/`.
11. **Windows: a path to the shared contracts.** The 105 Lua contracts give
    macOS and Linux about 940 identical cases each (config scope, TOML shapes,
    menu rows, onboarding answers, physical editor). Windows cannot run Lua and
    re-tests these areas by hand, often by source inspection. Move the highest
    value contracts to JSON vectors under `_shared/tests/corpus/`, starting
    with `config_scope_*`, `toml_*` and `menu_*`. Replay them from one AHK
    consumer per family. This is the largest single parity lever.
12. **macOS and Linux: gesture direction vectors.** Each of the 16 diagonal swipes and the
    5-finger swipes that ship on macOS and Linux is named by at most one test
    file per driver, and most by none. Linux has 0 tests for `gestures.swipe_3_down`. Add
    `_shared/tests/corpus/gestures/direction_vectors.json`, covering the
    finger count, the direction and the threshold to the action id, and replay
    it in `macos/tests/unit/modules/gestures/` and
    `linux/tests/unit/modules/gestures/`.
13. **All drivers: hotstring families end-to-end.** Rolls, SFB, distances,
    autocorrection and the French families have at most a handful of named
    tests on any driver. SFB and distances have 2 each. The shared corpus pins
    engine semantics, not the shipped family data. Add
    `_shared/tests/corpus/hotstrings/family_samples.json`, with two or three
    expansions per manifest family, and replay it from the three E2E
    harnesses.
14. **Windows: convert source assertions in the heaviest areas to behaviour.**
    The shares are script control 242 of 480, WPM 43 of 67, secure field 15 of
    29, tap-hold 132 of 347, logging 381 of 1,045 and menu 278 of 832. Their
    root cause is `run_all.ahk:14-18`, which excludes `modules/`. Extract the
    logic each area needs into `infra/` (the pattern the runner documents), or
    drive it through the existing child-process harnesses in
    `windows/tests/support/`. Retire each meta test once its behaviour twin
    exists.
15. **Toggle-level gaps from the manifest.** Each of these features ships on the
    driver with the zero, yet no test file there names it:
    `hotstrings.preview_autocorrect_enabled` (Linux 0, macOS 21),
    `layout.direct_access_digits` (Linux 0, Windows 12),
    `llm.generation.reset_on_nav` (Linux 0, Windows 12),
    `hotstrings.rolls.left_arrow` (Linux 0), `gestures.swipe_3_down` (Linux 0),
    `hotstrings.french_magickey.text_expansion` (macOS 0, Windows 6) and
    `shortcuts.chatgpt_url` (Windows 0, macOS 14). Lower-ratio cases are
    `llm.navigation.val_modifiers` (Windows 21, macOS 1) and
    `metrics.system_auth_filter_enabled` (macOS 12, Windows 2, Linux 1).

Lower priority: onboarding on Windows and Linux (62 and 34, against 191 on
macOS; the Lua contracts partly cover Linux), and synthetic input on Linux (75,
against 266 and 164). Linux unit tests for the XKB layout plan are also missing:
today that plan is tested only natively.

## Duplicates and useless tests

Ranked by certainty and payoff. "Identical" means checked with `diff`.

1. **`linux/tests/unit/adapters/test_system_proxy.lua` (324 lines, 13 tests).**
   Every test is repeated in `test_system_proxy_callbacks.lua`. The callbacks
   file is a superset: it adds a logger capture and two settlement-listener
   tests (lines 330-348). Delete the former.
2. **`linux/tests/unit/infra/test_managed_http_aggregate_cancel.lua` and
   `test_managed_http_queued_deadline.lua`.** The two files are identical except
   for the header, the describe name and one assertion (`aggregate_cancel:212`).
   Merge them into one file. `test_managed_http_deadline_arm.lua` and
   `linux/tests/unit/adapters/test_managed_http_public.lua` share 75 to 80 lines
   of the same fixture. Extract it to
   `linux/tests/support/managed_http_fixture.lua`.
3. **`linux/tests/unit/adapters/test_xkb_chord_numeric_symbols.lua` (2
   tests).** Its whole describe block is copied verbatim into
   `test_physical_chord_source_currency.lua:128-150`. Delete the standalone
   file.
4. **`linux/tests/unit/adapters/test_managed_http_public.lua:201,234` and
   `linux/tests/unit/meta/test_http_client_curl.lua:1679,1711`.** The bodies
   carry the same names and differ by 2 lines. Keep one copy, in the adapter
   file.
5. **macOS same-behaviour pairs.** Each pair asserts one behaviour under the
   same name in two files. Keep the one next to the owning module:
   - `unit/lib/test_file_watchers_git_defer.lua:25` and
     `unit/ui/menu/test_menu_watchers_git_defer.lua:22`
   - `unit/lib/test_git_status.lua:75` and `unit/lib/test_reload_gate.lua:71`
   - `unit/lib/test_logger_dedup_errors_mirror.lua:140,156` and
     `unit/lib/test_logger_file_sinks.lua:430,469`
   - `unit/modules/llm/test_warmup_gate_respects_pause.lua:91` and
     `test_warmup_parked_during_pause.lua:179`
6. **macOS repeats inside one file.** `meta/test_tooltip_mousemoved_lag.lua`
   asserts three facts twice (lines 55/95, 65/105 and 73/113).
7. **macOS copied fixtures.**
   `unit/ui/menu/test_custom_terminator_add_transaction.lua` and
   `test_custom_terminator_delete_transaction.lua` share 83 lines.
   `unit/lib/test_file_watcher_self_write_fixture_scope.lua` and
   `unit/ui/menu/test_menu_config_watcher_fixture_scope.lua` overlap by 70%.
   `unit/modules/keylogger/test_ingest_survives_stop_start.lua` and
   `test_process_exit_stop_skips_ingest.lua` overlap by 60%. Extract the shared
   setup into `macos/tests/support/`.
8. **Absence ratchets for code that is already deleted.** These tests only
   prove that a removed symbol stays absent; they exercise no behaviour.
   - Windows: `meta/test_b7_1_dead_shims_absent.ahk:25,44`,
     `meta/test_b7_3_dead_fns_absent.ahk:29,43,57`,
     `meta/test_wpm_menubar_dead_code_removed.ahk:64-105` (6 tests),
     `meta/test_av_focus_mode_dead_code.ahk:70`,
     `meta/test_healthcheck_onwebmsg_dead_code.ahk:33`,
     `meta/test_keylogger_ui_dead_code.ahk:37` and
     `meta/test_dead_ps1_pipeline_absent.ahk:82`.
   - macOS: `meta/test_b7_2_dead_modules_absent.lua:46-60`,
     `unit/meta/test_dead_code_removed.lua:26,31`,
     `unit/modules/gestures/test_gesture_in_progress_removed.lua:25-38`,
     `unit/llm/test_api_mlx_discovery_dead_constant_removed.lua:34` and
     `unit/modules/llm/test_prediction_engine_no_dead_shims.lua:22`.
   - JS: the "old name must be absent" half of
     `tools/test/test-name-parity.cjs`.

   About 35 tests in all. The files that mix in a live assertion must keep it:
   `test_healthcheck_onwebmsg_dead_code.ahk:42`,
   `test_prediction_engine_no_dead_shims.lua:27` and
   `test_av_focus_mode_dead_code.ahk:63,77`.

9. **Tests for legacy paths under the no-back-compat decision.** Since
   2026-09-23 there are no users to migrate. These tests are not useless while
   their code ships. Delete them together with the legacy code when the
   maintainer retires it:
   - macOS remap legacy rules: `unit/platform/remap/test_legacy_rules_removal.lua`,
     `enable_transaction/test_legacy_rules_offer.lua` and
     `unit/ui/test_legacy_rules_cleanup.lua`, plus
     `unit/platform/remap/test_config_retired_integration_key.lua` (10 tests).
   - Linux: `unit/infra/test_legacy_hotstring_storage.lua` (8 tests).
   - Windows: `unit/test_shell_runner_legacy_state_machine.ahk` (21 tests),
     `meta/test_shell_runner_legacy_claims.ahk` (7 tests) and
     `unit/test_common_autocorrection_migration.ahk`.
10. **Audit- and date-named files.** These 29 files are not useless, but they
    are named after an audit rather than a feature, so a reader cannot find
    them:
    - Windows: `meta/test_audit_2026_07_20_*.ahk` (5 files),
      `meta/test_audit_test_gaps.ahk`, `unit/test_audit_v4_fixes.ahk` and
      `unit/test_audit_v5_fixes.ahk`, plus 15 `*_20260813.ahk` files. The
      largest is `unit/test_llm_menu_transactions_20260813.ahk` (59 tests,
      3,338 lines).
    - macOS: `meta/test_audit_v5_fixes.lua`, `meta/test_audit_v6_fixes.lua`,
      `meta/test_fresh_regressions_2026_07_21.lua`,
      `unit/meta/test_audit_hs_final_fixes.lua`,
      `unit/meta/test_audit_senior_hs_fixes.lua` and
      `unit/adapters/test_adapters_input_audit.lua`.

    Move each test to the file of the feature it protects.

Windows has no cross-file duplicate names: the AHK registry rejects them. Its
16 same-name repeats are concatenated names that differ at run time, such as
`unit/test_llm_api_add_production.ahk:392-419` and the
`FoldAsciiLower` cases in `unit/test_toml_loader.ahk:217-262`.

## Oversized files

Counted at more than 800 lines: Windows 71, macOS 66, Linux 43, JS 55. The
largest per driver:

- **Windows:** `unit/test_updater.ahk` (4,693 lines, 83 tests),
  `unit/test_llm_menu_transactions_20260813.ahk` (3,338),
  `unit/test_features_manifest.ahk` (2,836), `unit/test_managed_remote_transport.ahk`
  (2,737) and `unit/test_llm_agent.ahk` (2,732).
- **macOS:** `unit/ui/menu/menu_llm/test_settings_transaction.lua` (2,873),
  `unit/modules/keylogger/test_physical_history_session.lua` (2,639) and
  `unit/modules/keylogger/test_hs274_duplicate_count.lua` (2,161; also named
  after a finding id).
- **Linux:** `unit/meta/test_ui_bridge_handlers.lua` (3,373 lines, 174 tests),
  `unit/meta/test_http_client_curl.lua` (3,244), `unit/meta/test_storage_adapter.lua`
  (2,175) and `unit/modules/test_key_combinations.lua` (2,111).
- **JS:** `tools/test/test-menu-manifest.cjs` (14,276),
  `test-menu-parity.cjs` (8,664) and `test-ci-pipeline-wiring.cjs` (7,885).

Split along the feature seams that the test names already use. For example,
`test_ui_bridge_handlers.lua` already groups its tests by bridge, and 14 of
them are named "has correct bridge_name".

## Tree tidiness

| Driver  | Problem                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Windows | `unit/` holds 646 flat files and `meta/` holds 761; only `unit/llm_nav_event_owner/`, `unit/updater/` and `unit/llm_profiles/` are grouped. `run_all.ahk` lists 1,687 `#Include` lines by hand. Next to `run_all.ahk`, the test root holds 7 ad-hoc runners and a benchmark: `run_hotstrings_config.ahk`, `run_llm_*.ahk` (4), `run_native_desktop.ahk`, `mini_runner.ahk` and `bench_parity_process_prediction.ahk`. Untracked `_ord_*_run_all.ahk` scratch runners appear there during agent work. `hardware/group7_*.ahk` is named after a work group.                                                                         |
| macOS   | There are two meta directories, `tests/meta/` (78 test files) and `tests/unit/meta/` (37). LLM tests are split between `unit/llm/` (22) and `unit/modules/llm/` (114), and menu tests between `unit/menu/` (7) and `unit/ui/menu/` (138). Benchmarks are split between `bench/` and `benchmarks/`. `scratch_test_dir/` is tracked through `.gitkeep` and collects leftovers (`jsonl_sqlite_open_failure/`). Ignored `*.ergoptiplus-write-lock-v1` files leak into `fixtures/`, which shows that some test does not clean up. `e2e/PLAN_E2E_REAL_HS.md` is a plan kept inside the test tree. 7 test files sit at the `unit/` root. |
| Linux   | `unit/meta/` holds 121 test files, but only 384 of its 2,219 tests inspect source; the rest are behaviour tests (`test_tap_hold_engine.lua`, `test_file_watchers.lua`, `test_http_client_curl.lua`, …). `unit/modules/` has 29 files at its root. The `unit/keymap/` file (1) duplicates the role of `unit/modules/keymap/` (3), and `unit/lib/` holds 2 files. Helpers are spread over `fakes/`, `support/` and `fixtures/`. Ignored `hardware/__pycache__/` is left behind by the hardware runs.                                                                                                                                |

**Proposed tree, the same on the three drivers.** It mirrors the driver
layout, which `tools/test/test-driver-tree-parity.cjs` already ratchets for
production code but deliberately excludes for `tests/`:

```text
tests/
  unit/<adapters|infra|modules/<module>|platform/<area>|ui/<window>>/test_*.{ahk,lua}
  meta/      source inspection only (one directory per driver)
  e2e/       corpus replays and boot scenarios
  native/    hardware and installed-host probes (today: hardware/, distro/, startup/)
  support/   fakes, fixtures builders, child scripts
  fixtures/  static data
```

Concrete steps, in order:

1. Move the Linux `unit/meta/` behaviour files to `unit/<area>/`. This is the
   largest misfiling, and the Lua runner discovers tests recursively.
2. Merge macOS `tests/unit/meta/` into `tests/meta/`, `unit/llm/` into
   `unit/modules/llm/`, `unit/menu/` into `unit/ui/menu/`, and `bench/` into
   `benchmarks/`.
3. Group the Windows `unit/` and `meta/` files by the `TEST_MODULE_GROUPS`
   areas of `windows/tests/test_framework.ahk:597-610`. The groups already
   match on path regexes, so subdirectories make them exact. This needs the
   `run_all.ahk` include list to change through its owner, so do it in one
   scripted move. Move the root runners to `tests/runners/`.
4. Extend `test-driver-tree-parity.cjs` to ratchet the `tests/` trees too.

## Limitations

- Family and kind attribution are keyword and pattern heuristics. Counts are
  reliable to within about 10% per family; spot checks found the misattributed
  tests in "keyword" families such as `roll` (rollback) and `agent`.
- The 105 shared Lua contracts register their cases inside the shared file,
  so the per-driver totals above exclude about 940 cases on macOS and Linux.
- JS checks are counted per registered test; many JS files are single-check
  scripts. Their parity role is cross-driver structure (menus, manifest,
  priorities), not behaviour.
- No test was executed. A test listed here as a duplicate or as useless must
  be removed under the false-green ratchet and `verify-change` gates, after
  `git grep` confirms that nothing else references it.
