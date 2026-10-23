<!-- docs/audits/2026-10-24-cross-os-parity-todo-entries.md -->

# TODO entries from the cross-OS parity audit

Paste block for `docs/ERGOPTIPLUS_TODO.md`, from
[2026-10-24-cross-os-parity.md](2026-10-24-cross-os-parity.md). Entries are numbered `P1` to `P85` in
priority order; the coordinator replaces `Pn` with the next free item numbers (numbers are never
reused). Row ids (`H1`, `R3`, ...) are the audit's. Tags follow the TODO: **[CODE]**, **[CI]**,
**[PHYS-W/M/L]**. Every entry that adds a user-facing string also needs the 21 locales, and every
feature entry covers the three OS or states why one cannot have it, in the menu reason text.

## A. Behaviour that differs without a good reason (fix first)

- [ ] **P1. Linux repeat key doubles at a word start and repeats spaces.** [CODE] Windows
      (`hotstring_match.ahk:505-520`) and macOS (`expander.lua:1053-1067`) need a non-boundary
      predecessor; Linux (`repeat_key.lua:202-225`) doubles any previous codepoint. Align Linux on
      the two that agree and add the shared repeat-key vectors (P2) first so the bug fails. Audit H1.
- [ ] **P2. Shared repeat-key and idle-reset vectors.** [CODE] `hotstrings/vectors.json` has 45 vectors
      and none on the repeat key; `idle_resets_word` has no vectors either. Add
      `_shared/tests/corpus/hotstrings/repeat_key_vectors.json` and idle/word-reset vectors, replayed
      by the three E2E harnesses. Audit H2, H11.
- [ ] **P3. One metrics master-switch key.** [CODE] Windows reads `metrics.metrics_enabled`
      (`config_io.ahk:1490`), macOS and Linux `metrics.enabled`; the latter is declared but unread on
      Windows. Move Windows to `metrics.enabled`, no migration (no users), delete the old key and its
      readers. Audit C1, S1.
- [ ] **P4. One name set and one default for the WPM readouts.** [CODE] Three vocabularies
      (`wpm_widget_*`, `float_*`, `wpm_menubar_*` against `menubar_*`), defaults true on macOS and
      false on Windows/Linux, a dead Windows key `metrics_wpm_menubar_colors`, and three position
      stores. Pick one set, one default and one position store; add a single-source test. Audit C2,
      C3, S3.
- [ ] **P5. Manifest `platforms` must match what each driver reads.** [CODE] `llm.trigger.disabled_apps`
      is declared hs only but Windows writes it; `llm.navigation.nav_modifiers` is declared
      hs+linux but Windows reads it; `mod_combos` is marked linux-only but macOS has it. Fix the
      declarations and add a gate that fails when a driver reads a manifest key declared for other
      platforms (extend `test-menu-manifest-keys-have-readers.cjs`). Audit C5, T1.
- [ ] **P6. One base expansion-delay key.** [CODE] Windows and Linux use `[delays] default_sec`, macOS
      `hotstrings.expansion_delay`; the 750 ms value is "kept in sync" by comment only. One key and a
      single-source test in `test-defaults-single-source.cjs`. Audit H5, C7.
- [ ] **P7. Decide and align the complex-key window multiplier.** [CODE] macOS doubles the expansion
      window after Shift/Alt keys (`keymap/init.lua:139,1862`); Windows and Linux do not, although the
      Ergopti layout is Shift/AltGr-heavy. Port it with vectors, or write the reason in the memory
      topic and the menu text. Question for the maintainer. Audit H3.
- [ ] **P8. Word delimiters in config leaves on Windows.** [CODE] macOS and Linux store
      `terminator_states`/`terminators` as config leaves; Windows keeps a delimiter string in the
      override file. Move Windows onto the leaves and read one catalogue for the separator set (the
      Windows set is wider than Linux's three). Add terminator vectors. Audit H7, H8.
- [ ] **P9. Linux sends `think:false` on Ollama requests.** [CODE] Windows and macOS disable thinking
      (`ollama_payload.ahk:88-123`, `api_ollama.lua:1432`); Linux only strips `<think>` text
      afterwards (`api_ollama.lua:234-250`), wasting tokens and latency on thinking models. Mirror
      the payload and add a request-shape test. Audit A1.
- [ ] **P10. Linux package installs must not be offered updates.** [CODE] The background check and the
      prompt offer an update that `manager.lua:1501-1506` then refuses with an ERROR (which can open
      the error window). Apply the existing "a build that cannot update is greyed" rule to
      `installation_kind()` package installs in the check and the prompt. Audit U2.
- [ ] **P11. Windows uninstall removes its Startup shortcut.** [CODE] `uninstall.ahk` never touches
      `A_Startup`; macOS and Linux remove their login item. Remove it, then add a test that fails
      while the shortcut is left behind. Audit U6.
- [ ] **P12. Token-streaming reason contradicts the code.** [CODE] The row says Windows cannot show
      suggestions token by token but `ollama_streaming.ahk` and `prediction_exec.ahk:578` stream.
      Enable the row on Windows, or fix the reason in 21 locales. Audit M9, A19.
- [ ] **P13. Persist the update ETag and release list on Linux.** [CODE] Windows and macOS keep them
      across restarts, Linux starts with a full request each time, which spends the 60 requests per
      hour quota. Persist through the Storage port with a vector. Audit U3.
- [ ] **P14. Check-only fallback when the GitHub API is blocked.** [CODE] macOS falls back to the
      public Atom feed; Windows and Linux do not. Add the fallback for the update check (installs keep
      needing API digests) with a vector. Audit U4.
- [ ] **P15. Hold threshold, one-shot timeout and hold-side parity.** [CODE] Fix the stale "ONE
      global" header of `tap_hold/defaults.toml` and `test-tap-hold-threshold-parity` (range only),
      pin exact values, make the one-shot timeout one value (Windows/Linux 2000 ms, macOS 3000 ms), and
      let Linux honour the right-ctrl hold side. Audit T4, T8, T10.
- [ ] **P16. Tap-hold defaults merge per key on every driver.** [CODE] Linux's user `tap_hold.toml`
      replaces defaults wholesale, Windows merges per key, macOS has no user file. Merge per key on
      Linux, state the macOS reason in the SCHEMA row. Audit T5, C19.
- [ ] **P17. Maintainer decision: shipped tap-hold and key-combination defaults.** [CODE] caps_lock,
      left_ctrl, tab and right_ctrl defaults differ by OS ("defaults are deliberate"), and macOS
      recommends one key-combination pair against three on Windows/Linux. Record the decision, then
      align or document in the manifest `reason_key`. Audit T2, T6.
- [ ] **P18. Debounce default 500 / 200 / 500 ms.** [CODE] macOS uses 200 ms with no stated reason.
      Align or declare `default_per_platform` with a `reason_key`; extend
      `test-defaults-single-source.cjs`. Audit A8, C10.
- [ ] **P19. Pause and resume switching of the layout.** [CODE] Only macOS has
      `pause_switch_enabled`, `on_pause`, `on_resume`; the manifest gives no reason. Either implement
      on Windows (emulation stop on suspend) and Linux (XKB group switch), or add the `reason_key`.
      Audit L7, C14.

## B. Missing features on one OS

- [ ] **P20. Linux per-app metrics exclusion, and one key name.** [CODE] Windows
      `metrics_disabled_apps`, macOS `metrics.disabled_apps`, Linux none (the reason
      `metrics_extras_are_not_on_linux` only restates the gap). Rename to one key, implement on
      Linux through `focus_guard.lua`. Audit C4, S1.
- [ ] **P21. Linux LLM parity batch.** [CODE] Add per-app trigger disabling (`llm.trigger.disabled_apps`),
      model delete, hardware/RAM ranking, warmup, min/max words and reset-on-navigation rows, and the
      AI-acceptance and autocompletion delay rows. Split into one commit per capability. Audit A4-A7,
      H10.
- [ ] **P22. LLM telemetry on Linux.** [CODE] Write `events_llm` rows (generation, accepted,
      dismissed, tokens, cost) so the LLM dashboard tab is populated; today only counters exist
      (`keystats.lua:373-376`). Add a corpus replay. Audit A16.
- [ ] **P23. Per-app LLM profile overrides on macOS and Linux.** [CODE] Only Windows has
      `llm.app_profile_overrides`. Port the rule to a shared module and the rows to the other two, or
      add the `reason_key`. Audit A3.
- [ ] **P24. Windows preview-switch parity.** [CODE] macOS and Linux have the four `preview_*` switches; Windows has none for its own tooltip and `dynamic.enabled` is absent.
      Add the toggles and replace the descriptive-only reason. Audit H9, C8.
- [ ] **P25. Linux magic-key editor.** [CODE] Linux reads the key from configuration only. Add the
      dialog (reuse the macOS/Windows editor contract) and drop `no_magic_key_editor_on_linux`. Audit
      H13, M11.
- [ ] **P26. Linux keyboard-slot binding and personal shortcuts file.** [CODE] Stated gaps
      (`no_keyboard_slot_binding_on_linux`, `no_personal_shortcuts_file_on_linux`) with no scheduled
      work. Design the Linux surface or keep the reasons and say so in the docs. Audit M11.
- [ ] **P27. Linux logger sub-files and a pre-config log.** [CODE] `sub_files.toml` has no Linux
      platform value; route hotstrings, llm and keystats, declare the pre-sink fatal record, and align
      the Windows/macOS topic sets. Audit G1, G2, G4.
- [ ] **P28. Windows and Linux network field check.** [CODE] macOS has `field_check_network` (system
      proxy, PAC, HEAD through the managed transport); company-proxy failures are exactly what
      `AGENTS.md` warns about. Add the Debug row on the other two, per the field-test pattern in
      `AGENT_RULES`. Audit D3, D2.
- [ ] **P29. Windows hook-health and Linux `running_apps` snapshot fields.** [CODE] The diagnostic
      schema has key-accounting for macOS and kanata/kernel fields for Linux but nothing for the
      Windows hook, and `running_apps` is missing on Linux. Add them with schema and parity-test
      updates. Audit D5.
- [ ] **P30. Sign the Windows and Linux update assets.** [CODE] [CI] Only macOS verifies a signature
      (Sparkle EdDSA); Windows trusts the API digest, Linux a `.sha256` asset. Publish detached
      signatures and verify them in both updaters. Audit U1.
- [ ] **P31. Linux layout install on pure Xorg.** [CODE] [PHYS-L] The converter writes
      `~/.config/xkb`, which Xorg ignores. Detect the session and install through the documented
      path or refuse with a clear message; surface Compose conflicts in the result. Audit L3, L4.
- [ ] **P32. macOS and Linux nav-layer repeat count, pointer and wheel bindings.** [CODE] Reasons say
      "for now" (repeat count) or unsupported (pointer, wheel on Linux). Schedule or drop. Audit T12.
- [ ] **P33. List one-shot Shift in the Linux picker and unify `sticky_*`.** [CODE] The Linux engine
      implements it (`tap_hold_engine.lua:105-110`) but the picker does not offer it; macOS names it
      `sticky_shift`. Audit T9.
- [ ] **P34. Mouse metrics, event families and app-category store on Linux and macOS.** [CODE] Linux
      writes 4 event tables of 15; the `mouse` column exists with no capture; app categories live in
      three stores. Capture mouse, write window/system/session tables, one category store. Audit S2,
      S4, S8.
- [ ] **P35. Windows decision on the `accented_letters` shortcut features.** [CODE] ahk-only without
      a feature reason. Keep with a `reason_key`, or move to a layout variant everywhere. Audit M12,
      L10.
- [ ] **P36. Decide gesture modes and sensitivities beyond macOS.** [CODE] 70 macOS-only entries and
      the Windows-only absence of 2- and 5-finger slots have no reason. Add `reason_key` or implement.
      Audit M13, C11.

## C. UI-only gaps, reasons and docs

- [ ] **P37. Give every genuine platform restriction a `reason_key`.** [CODE] 228 of about 380
      manifest entries are restricted and 14 carry a reason; 288 menu rows lack one (most are frames).
      Add a gate that requires `reason_key` on every feature entry and every non-frame row whose
      platforms are not all three, with a baseline lowered to zero. Audit headline 1.
- [ ] **P38. Rewrite stale `platform_reason` texts.** [CODE] `llm_configuration_surface_is_not_on_linux`
      (Linux has the profile/trigger/display/navigation rows), `kanata` wording in two texts, and
      the `token_streaming` text (P12). One wording for the Linux engine. 21 locales. Audit M7, M8.
- [ ] **P39. Regenerate `config.schema.json` metrics from the manifest.** [CODE] The schema requires
      `enabled`, lists dead keys and sets `additionalProperties:true`, so it validates nothing. Generate
      it and drop the permissive flag. Audit C15.
- [ ] **P40. Unify user LLM profile storage.** [CODE] Windows/Linux `llm.user_profiles` (string),
      macOS `llm.profiles.user_profiles` (array). One schema. Audit C9.
- [ ] **P41. One shortcut data model.** [CODE] Three models (16 legacy booleans, `keyboard.*` slots,
      `shortcuts.keys.*`) and OS-named ids. Move to action slots with neutral ids. Large; plan first.
      Audit C12, C13.
- [ ] **P42. Retire the macOS `[features]` override layer.** [CODE] `config_overrides.lua` and the
      `loglevel` alias contradict the no-back-compat rule. Delete with tests. Audit C16.
- [ ] **P43. Unify duplicated per-OS prompt strings.** [CODE] `menu.llm.*_prompt` against
      `menu.settings.*_prompt`, `ollama_port_*` against `mlx_port_*`. One key set, 21 locales. Audit I5.
- [ ] **P44. Windows-specific reset error texts everywhere.** [CODE] Only Windows has
      `dialog.reset_defaults.{rollback,commit,acquire,reload_refused}`. Use them on macOS and Linux.
      Audit C20.
- [ ] **P45. Notifications: one behaviour for toggles and refusals.** [CODE] `notify_feature` and
      `quit_refused` fire on macOS only. Decide and align. Audit N1, N2.
- [ ] **P46. Route hard-coded visible text through i18n.** [CODE] Windows `TrayTip` (6 sites), French
      literals on macOS (`models_manager_mlx_hf.lua:1137`, `models_manager_mlx_download.lua:1402,1438`,
      `profiles.lua:211`, `personal_info_editor/init.lua:39-45`), Linux `SPECIAL_KEYS`, shared UI
      titles. Add the gate (P62). Audit N7, I6-I8, K6.
- [ ] **P47. Extend `audit-translations.cjs` to Linux and `_shared`, both directions, unused keys.**
      [CODE] It scans Windows and macOS only. Add Linux, shared Lua/JS and an unused-key mode with a
      baseline; then delete the confirmed orphan keys (`apps.cloner.*`, `apps.encryptor.*`). Audit I2,
      I4, K7.
- [ ] **P48. Review values equal to English in each locale.** [CODE] 263-385 per locale and about 30 in
      `fr` (`sg_actions.sticky_*`, `shortcuts.altgr*`). Triage through the i18n skill. Audit I3.
- [ ] **P49. Fix stale docs.** [CODE] `SCHEMA.md`, `logger/SPEC.md` section 10-11 and `logger/README.md`,
      `windows/README.md`, `linux/modules/README.md` (updater is 5 files), tooltip README (macOS and
      Linux), `windows/modules/keystats/README.md:7`, memory notes "Linux has none yet" and "ONE
      global". Audit C19, G7, U13, S12, T2, T4.
- [ ] **P50. Metrics suspend and reset-session rows on all three.** [CODE] Linux-only today with a
      weak reason. Offer on Windows and macOS. Audit S5, M10.
- [ ] **P51. Uninstall failure dialog on Linux without zenity.** [CODE] KDE hosts get only stderr.
      Fall back to kdialog, then stderr plus notify-send. Audit U7.
- [ ] **P52. Release-notes page on macOS and Linux.** [CODE] Confirm macOS opens
      `_shared/ui/release_notes`; wire it if not. Audit U5.

## D. Instrumentation and diagnostics

- [ ] **P53. Bring HotPath-style slow-segment logging to macOS and Linux.** [CODE] Windows declares
      31 segments, macOS 2, Linux spans exist but only time at DEBUG. Always time on Linux, add the
      inventory test for both Lua drivers, then cover the typing path. Audit P1, P2, P6.
- [ ] **P54. PhaseStats and child-process timing on Windows and Linux; CPU in boot profile on macOS and
      Linux.** [CODE] Mirror macOS `process.*` phases. Audit P3-P5.
- [ ] **P55. Crash reports: one content, one cap, one notice.** [CODE] macOS content and notice wins;
      Linux caps at 20, Windows no cap. Share the format and retention policy with vectors. Audit D6,
      R31.
- [ ] **P56. Log-volume metrics on all three drivers.** [CODE] Nothing counts lines per level or
      dropped/collapsed lines. Add counters to the evidence record. Audit G6.
- [ ] **P57. Retention read from timings on Windows.** [CODE] `logger.ahk:112` is a literal 14. Read
      `Timings` and extend `test-logger-scalars-single-source.cjs`. Audit G5.

## E. Tests and corpora

- [ ] **P58. Windows consumer for the shared Lua contracts.** [CODE] 105 contracts (about 940 cases)
      run on macOS and Linux, none on Windows. Convert the highest-value ones (`config_scope_*`,
      `toml_*`, `menu_*`) to JSON vectors and replay from one AHK consumer per family. Audit test
      item 11, section 14.
- [ ] **P59. Corpus replay gaps.** [CODE] `http/get_redirect_vectors.json` (Windows, macOS),
      `native_presentations/original_captions.json` (Windows), `config_outdated/file_warning_vectors.json`
      (macOS, Linux), `route_plan_vectors.json` (Linux, Windows), `document_lease_contract` and
      `download_document_contract` (macOS). Audit R35, C21, section 14.
- [ ] **P60. Hotstring `family_samples.json` plus chaining, synthetic-output and erase vectors.** [CODE]
      Two or three expansions per manifest family, replayed by the three E2E harnesses. Audit H15,
      test item 13.
- [ ] **P61. Tap-versus-hold decision corpus.** [CODE] `tap_hold/vectors.json` pins accessors only; add
      decision vectors (tap, hold, roll, one-shot) replayed by the three engines. Audit T15.
- [ ] **P62. Contract tests for shared modules no test requires by name.** [CODE] `layouts.composer`,
      `hotstrings.personal_model`, `keystats.text_migration_runner`, `menu.click_intent`,
      `llm.config_guard` and five more. Check corpus coverage first. Audit R36.
- [ ] **P63. Remaining 2026-10-18 test items.** [CODE] Windows dynamic hotstrings, Linux personal-info
      editor, Linux model records and downloads, keystats corpus on Linux, toggle-level gaps
      (`preview_autocorrect_enabled`, `direct_access_digits`, `reset_on_nav`, `rolls.left_arrow`,
      `french_magickey.text_expansion`, `chatgpt_url`), Windows root runners and the
      `test-driver-tree-parity.cjs:19` exclusion. Audit section 14.
- [ ] **P64. Installed-record and layout corpora on Windows.** [CODE] Windows replays 1 of 4 files.
      Replay extensions, preservation and updates. Audit L6.

## F. Centralisation and hexagonal architecture (value order)

- [ ] **P65. Extract the LLM request plan to `_shared/lua/llm/request_plan`.** [CODE] Prediction
      orchestration is 3007 / 3927 / 2108 lines in three drivers and only prompt, parser, rewrite and
      tone are shared. Pure state machine with HttpClient, TimerScheduler and TooltipRenderer ports and
      a request-transcript corpus. Phase it: debounce and batching first. Audit R1.
- [ ] **P66. Move the menu frame builders to `_shared/lua/menu/frames`.** [CODE] Six identical bodies
      in macOS `menu_*` and Linux `menu_builder.lua` (5648 lines); frames from a state snapshot,
      replayed by `corpus/menus`. Audit R2.
- [ ] **P67. Shared keystats query catalogue and walker.** [CODE] About 85/73/66 SQL statements and
      three walkers; named queries in `data/db/queries.sql` with codegen, walker in
      `_shared/lua/keystats/walker.lua`, AHK replays `aggregation_vectors.json`. Audit R3.
- [ ] **P68. Hotstring override parser into `_shared` on `toml_codec`.** [CODE] macOS hand-rolls 190
      lines that Linux does in 25. Vectors for `[__global__]` passthrough. Audit R4.
- [ ] **P69. Shared ownership protocols.** [CODE] `scope_owner.lua` (5 methods copied 6 times,
      `S`/`L`), `storage_owned.lua` (104 identical windows), shared `error_dialog/core.lua`, and
      `owned_timer` for the dependency checkers. Do these four as small commits. Audit R5-R7, R14.
- [ ] **P70. Factory per macOS/Linux infra shim.** [CODE] `native_presentation`, `manifest_reader`,
      `manifest_menu`, `timings`, `text_cipher`, `text_migration`, `config_backup`, `locale`,
      `user_code` take `{platform}` and live in `_shared/lua`. Audit R15, R28, R32.
- [ ] **P71. Finish the route-plan rollout and make `proxy_policy.json` the codegen source.** [CODE]
      `route_plan.lua` has no production consumer on Windows or Linux; policies are hand-typed in Lua,
      Python, Go and generated Swift. Audit R12, C21.
- [ ] **P72. Shared registries and catalogues.** [CODE] `layout_registry` state machine into
      `layouts/registry.lua`; `shortcuts/catalogue.lua`; shared gesture `direction.lua` with boundary
      vectors; `llm/temperature.lua` with vectors; healthcheck report core; `llm/agent_learning_store`.
      One commit each. Audit R8, R9, R13, R20, R21.
- [ ] **P73. Collapse generated per-driver artifacts and tap-hold timeout duplicates.** [CODE]
      macOS/Linux `features_manifest.lua` (67% common), `action_catalogue.lua` (81%),
      `config_template.toml` (90%); `[hs_timeouts]` repeated per key in `defaults.toml`. Audit R22,
      R24.
- [ ] **P74. Config-key and command-id constants by codegen.** [CODE] Generate constants from
      `config.schema.json` and `menu_manifest.json` for AHK, Lua and JS; lint raw literals such as
      `private_filter_enabled`. Audit R10.
- [ ] **P75. Shared Lua helper modules and a redefinition lint.** [CODE] `table_util`, `path_util`,
      `shell_quote`, URL-encode, trim (54 inline patterns); lint forbids redefinition. Audit R16, K10.
- [ ] **P76. Long refactors, plan before starting.** [CODE] Generate the AHK config-migration op table
      from `migrations.toml` (R17); extract menu row-ordering rules to data (R18); pure hotstring
      injection plan (R26); FileSystem port spec for lease/atomic write (R33); canonical `.keylayout`
      parser (R23); Windows updater `check_session`/`rate_limit` vectors (R25).
- [ ] **P77. Remove platform branches from shared UI JS.** [CODE] `healthcheck/script.js:57`,
      `layout_manager/script.js:116`, `onboarding/script.js:396,713`, `program_parameter.js:59-66`;
      the host passes capability flags and one `program_parameter` source. Audit R19.

## G. Constants, delays, colours, labels (value order)

- [ ] **P78. Timing registry liveness and duplicate-name gate.** [CODE] 41 of 145 keys have no reader,
      111 constant names are defined in more than one file (38 with different values). Add
      `tools/test/test-timings-registry-liveness.cjs` and a duplicate check in
      `test-keystats-timings-single-source.cjs`; prune or wire the unread keys. Audit K2, K1.
- [ ] **P79. Replace repeated timer literals with registry keys.** [CODE] `STALE_TEMP_MS` x5,
      gesture poll `-100` x6, safety flush `-2000` x3, `DEFAULT_TIMEOUT_MS = 30000` x4,
      `LONG_SESSION_THRESHOLD_MS` x3 JS, `TAP_WATCHDOG_INTERVAL_SEC` 5 against 2, `PUMP_INTERVAL_SEC`,
      Swift `usleep` literals. Gate: no numeric literal in `SetTimer/Sleep/doAfter/setTimeout`
      with a baseline, hosted in `test-fast-timer-inventory.cjs`. Audit K1.
- [ ] **P80. `[limits]` section for byte caps.** [CODE] `MAX_OUTPUT_BYTES` 65536 in 3 files and
      similar in 6; gate in the registry test. Audit K3.
- [ ] **P81. Theme tokens and palette codegen.** [CODE] 810 hex literals, 19 `--accent` declarations,
      the hotstring palette typed in three drivers, byte-identical `macos/ui/download_window/style.css`
      against `_shared`. Create `_shared/ui/theme.css` and a native-theme TOML; codegen the palette and
      retire `test-color-presets-parity.cjs`; lint "hex literal outside theme" with a baseline in
      `lint-conventions.js`. Audit K5.
- [ ] **P82. Hard-coded UI string gate.** [CODE] New `tools/test/test-no-hardcoded-ui-strings.cjs`
      (TrayTip, MsgBox, alert, title literals fail unless allowlisted; reuse
      `tools/lint/audit-gui-titles.cjs`), including the Linux `install.sh` echo table. Audit K6, I9.
- [ ] **P83. Identifiers and hosts in one file.** [CODE] `_shared/data/identifiers.json` via codegen
      for `ErgoptiPlus.ahk/.exe/.app`, bundle ids, service names, GitHub/Ollama/HuggingFace hosts;
      extend `test-repo-url-single-source.cjs` to hosts and ids. Add the `ollama_install.sh` port to
      `test-ollama-port-single-source.cjs`. Audit K9, K4.
- [ ] **P84. Closed enums for reasons, phases and log tags.** [CODE] About 189 `reason`, 56 `phase`
      and 62 `[TAG]` literals plus the evidence-record field names (not censused: do that first).
      Extend `codegen-contracts-json.cjs`; gate in `test-logger-scalars-single-source.cjs`. Audit K11.
- [ ] **P85. Tooltip dequeue and ring constants.** [CODE] `dequeue.js` 0.2/0.05 against `dequeue.lua`
      0/0, `RING_SIZE` 64 against 32, "mirrored" comment at `tooltip/constants.toml:398`. Single-source
      test in the tooltip family. Audit K2.
