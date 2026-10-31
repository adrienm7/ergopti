<!-- TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-30. Latest stable: [v1.0.8](https://github.com/adrienm7/ergopti/releases/tag/v1.0.8)
(released 2026-10-30 from main; v1.0.7 was main 18d69a24c0). **Next step: the two machine lists below, the PC one on the
Windows PC and the Mac one on the Mac.** Open work only: a finished item is removed, its lessons go to
[docs/memory](docs/memory/README.md), and the history stays in Git
(`git log --follow -p -- TODO.md`). On 2026-10-30 the finished items, the fixed entries of the Mac
field ledger and the 24 and 27 October handovers were removed; the full earlier file is
`git show 7f80d3d141:TODO.md`. Item numbers are stable and never reused. This file is the only
checklist: open questions are in "Questions for the maintainer" at the end, and there are no separate
handoff files (an agent writes what is left into the item itself).

Tags: **[CODE]** software to write or adopt; **[CI]** only a hosted or native CI run qualifies it;
**[PHYS-W]**, **[PHYS-M]**, **[PHYS-L]** needs a real Windows PC, Mac or Linux machine.

**Generic caveat, stated once.** Unless an item says otherwise, native macOS and Linux qualification
and every physical-device acceptance remain OPEN and their qualification flags stay false; portable
tests, containers and software-supplied events are never physical evidence. The maintainer has a
Windows PC (physical tests on request) and a work Mac (reproduce on CI first, then at most one short
command); there is no Linux machine.

**Rules for every agent.** dev and main stay linear (rebase or cherry-pick, never `git merge`); a
release is a push to `main` carrying a `Release-As: X.Y.Z` trailer; Codex agents push to dev, so
fetch and rebase first, and preflight on `tmp/preflight-dev` with
`gh workflow run ci.yml --ref tmp/preflight-dev -f os_lanes=all`; a hook failure caused by someone
else's dirty file is waited out or bypassed with a private index plus compare-and-swap `update-ref`
running the hooks, never with `--no-verify`; never weaken a test; quality over speed. Run the pinned
ruff 0.15.8 and Prettier before every commit. After touching
a sealed Windows updater source, reseal with
`node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write`. Procedures:
[workflow and verification memory](docs/memory/workflow-and-verification.md).

## PC Windows todo (run by the agent on the Windows PC)

For a field report, check out a branch and run
`powershell -ExecutionPolicy Bypass -File tools/dev/collect-windows-field-report.ps1`. It creates
`field/win-<today>-<branch>` derived from that branch, collects the system facts, runs its own checks,
copies today's logs scrubbed, writes their digest and their analysis (`analysis.md`), writes the report (with `base.txt` naming the base and commit) under `docs/field-reports/`, commits and
pushes. The Linux PC runs `bash tools/dev/collect-linux-field-report.sh` the same way.

Start from a fresh `dev` and work on a `fix/windows-pc-<date>` branch; build and run the AutoHotkey driver live
on the PC; push the branch and say so, dev integration stays with the coordinator. Order:

1. **Privacy first:** the "PRIVACY: private hotstring text reaches AI prompts on Windows" item of "Windows
   side to do on the PC" below.
2. **v1.0.7 parity on Windows** (macOS and Linux shipped it, Windows still lacks it):
   - Gestures: the menu shows one « Infos… » row (`MenuCommand.GESTURE_RECOMMENDED_INFO`) that opens the
     reason dialog. Check on the PC that the dialog opens and that the menu has no long text row.
   - Local AI servers: when the process scan fails, the oMLX or Ollama port now comes from the server's
     settings file. Check that an oMLX or Ollama server on a non-default port is found.
   - Hotstrings: Windows sends text with `{Text}` (VK_PACKET), so the macOS bug where `axa` turned into `XA`
     cannot happen here. Type `axa` and Space fast twenty times; every one must give `AXA`.
3. **Every remaining item of "Windows side to do on the PC (from October 25)"** below, in its order.
4. **"Windows counterparts of the 26 October work"** in "Windows side to do on the PC" below (hotpath_slow_ms, crash kind,
   palette, requires_ai, request_plan port, tap_hold v1 migration, Quit refusals, config_migrate op).
5. **Antivirus surface ceilings:** the "Review the Windows antivirus surface ceilings" item of "Windows side to
   do on the PC" below. Lower them once a Windows build confirms the counts.
6. **Physical checks:** "Maintainer checks > Windows PC" below; report each line as pass, fail or not run.

Every commit keeps the AHK UTF-8 BOM (repository encoding gate), reseals a touched updater source and
passes the Windows CI lane (`gh workflow run ci.yml --ref <branch> -f os_lanes=windows`).

### Windows manual checks for the maintainer (batched by the PC agent, 2026-10-31)

Decisions of 2026-10-30: app categories follow macOS and Linux with no migration, the shared TOML writer is the
reference, the installed-record corpus follows Lua. A `metrics\app_categories.json` is no longer read.

- [ ] Tray > Gestures: one « Infos… » row, no long text row, and it opens the dialog.
- [ ] Ollama or oMLX on a non-default port with the process scan failing: the server is still found.
- [ ] Type `axa` then Space fast, 20 times: always `AXA`.
- [ ] Type `sru` with a personal `sru` -> `SRU` final entry: `SRU`. Type a hotstring containing `{left}`: the caret moves.
- [ ] With live Ollama, token-by-token predictions display correctly, then enable the row (PAR-12).
- [ ] System Ollama on 11434, AI on: Ergopti's listens on 11435 and the other one is untouched.
- [ ] Type `fb` + Space, Enter and ★ with the abbreviation and brand packs, at 1, 2 and 3 arrows, consumed and not.
- [ ] Type on a real keyboard with the composed layout (Debug > "Test the composed layout").
- [ ] Block api.github.com and run an update check: the Atom fallback reports the version.
- [ ] "Create a GitHub issue" signed in: the form opens with no "Whoops" page.
- [ ] Install a build with 5d6beccf83, update to the next one: the exe restarts, the three scripts are in
      `%LOCALAPPDATA%\Ergopti\vendor\`, the command line shows `-File` and no `-EncodedCommand`.
- [ ] `tools\dev\run-windows-dev.ps1` with the exe running: the exe closes, the tray appears, saving an `.ahk` reloads
      once. `npm run dev:windows` from Git Bash and cmd; double-click `ErgoptiPlus.ahk` with and without the exe.
- [ ] The ten window-toggle actions, also without WebView2: no orphan WebView2 process.
- [ ] Win+S targets (browser, mail, Regedit, Settings, web search); Backspace word start in Windows Terminal with
      Claude Code, Notepad Ctrl+Backspace, browser Ctrl+L, AltGr+Backspace on AZERTY and Kana; native pair popup;
      Versions Retry button.
- [ ] Brightness joined source; retired Metrics shortcuts across a three-OS full save and an installed upgrade.
- [ ] Corporate network: Debug > diagnostics (`github_api`, `proxy_pac`), a model pull behind a PAC, the Windows
      security warning for the native CA case, and decide whether NTLM relays get an option.
- [ ] Accounts: SignPath application (`docs/tooling/signpath-foundation-application.md`); update-signing key
      (`docs/tooling/update-signing.md`), one release with `off`, then `required`; VirusTotal and Defender submissions.
- [ ] Testers: retry the download behind a block page, and retest number-row, key-combination and priority-100 setups.

## Mac todo (run by the agent on the Mac)

Check out `dev` (or the branch to test) and run `bash tools/dev/collect-macos-field-report.sh`. It creates
`field/mac-<today>-<branch>` derived from that branch, runs the field checks in the developer app, writes the
report (with `base.txt` naming the base and commit) under `docs/field-reports/`, commits and pushes. The
developer app's managed Ollama is built locally from the repository pins and needs Go, the Xcode Command Line
Tools and python3 3.11.4 or newer. Set Debug > Log level > DEBUG first. Order:

1. **v1.0.7 fixes to confirm:**
   - **Hotstrings (axa):** type `axa` and Space fast twenty times, also holding the `a` while pressing
     Space; every one must give `AXA`. The day log should show `Synthetic text moved off a held key` next
     to `Terminator-expand: 'axa'`. Then check ordinary hotstrings in Edge, VS Code and a terminal.
   - **oMLX:** oMLX on port 8181 is found in API mode, with no `ps` deadlock.
   - **Composer (L52):** the composer is enabled after a single re-read, and `06_field_composer` passes.
   - **Keystats cache:** it now lives in `~/Library/Caches/ergopti_plus/metrics`. Check the one-time move
     line from TMPDIR. Automated: `field_storage`'s `keystats_cache_place` passes only when the live cache
     sits there and no `<TMPDIR>/ergopti_metrics/<device>/db.sqlite` is left.
   - **Gestures:** the menu shows one « Infos… » row that opens the dialog, and `tap_3` recommends left
     click.
   - **Three-finger swipe (L46):** each step of 25 units (4, 29, 54, 79…) gives one more action, and two-finger
     scrolls never switch tabs.
2. **Open [PHYS-M] items of "Mac field session 2026-10-27: problem ledger > Open TODO"** below: L16, L17,
   L24, L26, L27, L28, L42, L43, then the [CODE]-only L18 and L23 once a day log measures them
   (L34 closed: the later runs stayed within budget, see the ledger).
3. **"Maintainer checks > Mac hardware session"** and **"Maintainer checks > Mac"** below, section by
   section; report each line as pass, fail or not run.
4. **Native macOS ownership contracts (from the former root TODO.md).** On a real Mac, run the launcher XCTest
   suite (`static/ergopti_plus/macos/launcher/`), the FSEvents/pathwatcher startup refusal
   (`macos/infra/file_watchers.lua`), the POSIX filesystem capability tests and the ServiceManagement process
   boundaries: hosted gates cannot execute Darwin poll/FD behaviour or the hidden `FSEventStreamStart` result.
   `swift test` there needs full Xcode.app, not just the Command Line Tools (`no such module 'XCTest'`
   otherwise); confirmed on a CLT-only checkout 2026-10-29, see
   [macos-hammerspoon memory](docs/memory/macos-hammerspoon.md). Needs the maintainer to install Xcode.app once; the field
   run cannot install it (an App Store download behind an Apple ID).
5. **Production Hammerspoon profile (from the former root TODO.md).** Collect the `hotpath_profiler`,
   `boot_profiler` and `perf` artifacts on the Mac and measure MLX adoption, WPM `mouseMoved` traffic, Terminal
   identity lookup, keystats app attribution, canvas/AX work and the remaining synchronous shell helpers before
   optimizing any of them from source reading alone. The field run now collects part of it with no person:
   `field_boot_cost` (boot wall, CPU, slowest stages), `field_idle_cost` (idle CPU share, memory) and
   `field_slow_lines` (the day's slow HotPath segments by own time, ingest ticks, preferences saves). Left
   for hands: a working day of typing before the run, so the slow lines have something to measure.
6. **Field run checks (`field_run/NN_<step>.json`, each step's `proves` line in
   `static/ergopti_plus/macos/data/field_run.json`).** A failing step's codes are `fail_<check step>`; read the
   step's report and log window before the day log. The read-only checks added for the field run alone:
   - `field_permissions`: Accessibility is granted (fail otherwise); Input Monitoring, Screen Recording and
     secure input are named; Automation is skipped (no query without a prompt); the bundle identifier is a
     declared one; the running bundle's strict signature is valid; the signing identity (team or ad hoc)
     says whether a rebuild keeps the grants.
   - `field_event_taps`: each keymap tap (keyDown, loopbackKeyUp, flagsChanged, mouse) is enabled, by name;
     the tap watchdog runs; the worst of five 100 ms timers is under 250 ms late; the session's holds over
     250 ms and 1 s, late keys and the Lua heap are named.
   - `field_input_sources`: the selected source and the enabled list (as the text-input system holds them, not
     the preference) are readable; the Ergopti layouts enabled are counted; every installed Ergopti `.keylayout`
     parses with `xmllint` (read as XML 1.0, its C0 control references blanked) and every Ergopti bundle `Info.plist` with `plutil -lint` (a failure names the count).
   - `field_storage`: the keystats database passes `PRAGMA quick_check` opened `-readonly` and lock-free
     (`immutable=1`, so the ingest never meets a lock; an issue counts when a second scan sees it) (a damage names the
     number of issue lines only); `config.toml`, `config_karabiner.toml`, the personal hotstrings and personal
     info files each parse with the driver's TOML reader, read-only; today's log exists; the logs folder takes a
     probe file (removed at once); the auto-reload file watcher owner is published (FSEvents accepted it);
     the keystats cache is under `~/Library/Caches/ergopti_plus/` with no TMPDIR copy left
     (`keystats_cache_place`: `caches`, `legacy_left`, `outside_caches`).
   - `field_launcher_roles`: the launcher resolves; `--managed-http-worker` with malformed arguments exits 64
     at once (any other exit or a timeout: the role did not dispatch); the same worker carries one direct GET,
     with the request `native_http.py` sends, to a loopback server the check opens and closes. An exit 64 there
     (the 2026-10-30 `native_child_status=64`), a refusal stage or `not_reached` names where it broke.
   - `field_network_hosts`: one HEAD, one after the other, to the root of every host of
     `_shared/data/identifiers.json` (`github`, `github_api` for the update feed, `huggingface`, `ollama`,
     `ollama_registry`) (the registry at `/v2/`, whose root answers 503) through the managed transport (route lookup, PAC or proxy,
     TLS); any
     answer below 500 passes, a failure names the native reason by the host's key. Nothing is downloaded.
   - `field_app_health` (after the AI steps): no crash report of the last day in the driver's `crash_reports`
     folder (absent: none) nor in `~/Library/Logs/DiagnosticReports` for the app's processes (ErgoptiPlus and
     its launcher roles, Hammerspoon, Ollama, Python, Karabiner): they fail as `<process>:<count>`, the three
     newest are listed with closed tokens (hang or crash, exception, signal, termination namespace); other
     apps' reports are counted only; the app's resident memory (MB) and CPU share from `ps` are named.
   - `field_ai_local` (after the AI steps, read-only): the owned Ollama binary passes `codesign --verify
--strict`; a running server lists its models (not running: skip, never started here); one token is
     predicted from the check's own text with the smallest catalogue model already installed (none: skip, never
     a download); the MLX runtime and the catalogue models in its cache are counted.
   - `key_accounting` (automatic, no person): the app opens its own scratch text field, brings it to the
     front and types `wkjx` there only, checking before each key that the field still has the focus (a lost
     focus stops the sequence with its code; no key reaches another app); the passive tap must see each key
     once, the field must hold exactly `wkjx`, the previous app must get the focus back. The keys are
     selftest keys (`SyntheticInput.emit_selftest_key_stroke`): the keymap decodes them as typing only while
     the developer runtime's published scratch window has the focus and consumes them anywhere else (one
     `keymap.selftest_gate` warning per run names why), keystats never counts them, and the typing stops
     before a key while the keymap taps are off (`keymap_tap_off`). They are posted after Karabiner: the
     virtual keyboard path and the ledger's double count are `physical_keys_only`.
   - `hotstring_roundtrip` (automatic, after `key_accounting`): the first shipped, enabled, terminator
     hotstring with a plain lowercase trigger no other file registers is typed as selftest keys into the
     scratch field, after a Space and followed by Space; the field must hold exactly the Space and its
     expansion (plus the Space unless Space is a consumed terminator), and `terminator_to_text_ms` is named.
     Codes: `keymap_absent`, `no_enabled_trigger`, `space_not_terminator`, `not_expanded`,
     `mismatch_<n>_bytes`, `typing_incomplete`.
   - `prediction_tooltip` (automatic): with predictions on and the active model already on this Mac (Ollama
     listed by a running server, or an MLX model in the cache; nothing is started or downloaded),
     `le chat dort sur le ` is typed into the scratch field and the prediction tooltip must show within 45 s;
     `keystroke_to_tooltip_ms` (last key to tooltip) is named. Codes: `llm_disabled`, `no_installed_model`
     (a remote backend included), `tooltip_not_shown`, `typing_incomplete`.
   - `driver_reload` (last step): the configuration is put back, the run's state goes to `resume.json`, the
     driver reloads through the termination coordinator, and the reloaded driver's field run resumes, naming
     the reload's duration (request to a ready field run, `reload_ms` in the report) and taking a fresh
     configuration snapshot for the guard. A reload refused, or accepted and never started, fails by name.
   - `field_menu_build`: one rebuild of the menu tree, as a state change triggers it, must be accepted by
     AppKit; its duration in ms, the number of top-level rows and the three slowest rows (`id:ms`) are named.
   - `field_boot_cost` (after `field_composer`): the boot that started the app completed; its wall and CPU
     totals and its slowest stage are named, the three slowest stages in its log window.
   - `field_idle_cost`: over 30 quiet seconds the driver's process CPU share must stay at or under 3 %
     (`idle_cpu_percent`); resident memory and its growth, Lua heap growth and main-thread holds over 250 ms
     in the window are named.
   - `field_slow_lines`: one `awk` pass over today's log (a summary only reaches the task's pipe) tallies
     the HotPath `Slow <segment>: X ms own` lines by segment, and the `Slow ingest tick` and
     `Slow preferences save` lines; `slow_dominant` names the segment with the most own time (the five
     largest in the log window), the two others are `count:worst_ms`; `log_lease_bound_failures` and
     `log_layout_change_before_baseline` fail when a `Lease-bound input startup failed` or a
     `Layout … detected change before its baseline` line is in the day log (item 38).
   - `field_fifo_safety`: in a folder of its own under `TMPDIR`, a FIFO (a reader attached first, so a
     regressed guard cannot freeze the app) is named `named_pipe` by `followed_mode`, `exists` sees it, and
     both `append` and the atomic `write` refuse it and leave it in place; the folder is removed.
   - `field_local_servers` (after `field_ai_local`, read-only): every server of
     `_shared/modules/llm/local_servers.json` must have a discovery descriptor the driver accepts
     (`servers_catalogue`, else `undescribed_<n>`); one detection sweep, the AI menu's own (process,
     settings file, listening port, then `GET /models`), names each server as `server_<id>`:
     `up:<port source>:<models>`, `not_running:<port source>`, `needs_key:...` or `no_answer:...`. A
     server added to the shared list is reported by the next run with no driver change.
   - `field_layout_rows` (after `field_idle_cost`): from the Ergo-L file the app ships, a loose layout typing
     the symbols first is written as `~/Library/Keyboard Layouts/ErgoptiFieldRows-<n>.keylayout` under a new
     name and id, enabled through the enabled-sources preference, selected, and read back from a fresh
     process (`rows_build:keys_13` when the launcher's keyboard probe types its thirteen base cells); a second
     build that also moves the edge keys replaces it live and retires it (`rows_replace`, the design note's
     M4); then the user's selected source is selected again, every check build is disabled and deleted
     (`rows_retire`), and the selected id and the `AppleEnabledInputSources` list must be identical to the
     ones read before (`rows_restore`). `rows_ghosts` counts builds the system keeps listing until logout
     (M5a). A failure names its code: `requires_logout`, `select_refused`, `readback_mismatch`; the step's log
     window names each build and the source id the probe read.

## Maintainer requests of 2026-10-30 (coordinator session; everything here is to be done)

The coordinator integrates the worker branches `fix/linux-owned-ollama`, `fix/linux-privacy-menu`,
`fix/linux-layout-emulation` and `fix/llm-thinking-off` into dev linearly; each worker writes its own remainder
into its item below or into the matching existing item.

- [ ] **Release notes leaked agent session links.** [CODE] Done: `build_changelog.py` strips `Claude-Session`
      and `Co-Authored-By` lines and any `claude.ai/code/session_` link (0ba0e90580, test
      `tools/build/build_changelog_test.py`), and the convention lint flags the trailer. Left: rewrite the
      bodies of the releases already published with such lines, once the maintainer agrees.
- [ ] **Ergopti's own Ollama on macOS starts.** [CODE] [PHYS-M] The serve owner refused every launch
      (`NATIVE_PRODUCTION_QUALIFIED` stayed False since 2026-10-09; 6170813ea9 opens it). The field run of
      18:26 then failed in the readiness check: `NativeHTTPError at native_http.py:490 _read_exact`, the
      `--managed-http-worker` closed its pipe. afecfadd93 logs the serve phase and the worker's exit status;
      the next field report names the cause (74 parent lost, 75 budget, a signal a crash). Fix it from there.
- [ ] **Field run downloads.** Done: e8ff7479e1 keeps the Ollama and MLX test models, so a run no longer pulls
      about 740 MB over the maintainer's shared connection. Left [PHYS-M]: one complete download of each test
      model on a connection that does not count.
- [ ] **Field report marks.** [CODE] Done: the macOS collector marks its field run steps and the Linux one
      every tray check run of the day (`field_checks.txt`); the three collectors print ✅ pass, ❌ fail, ⏭️
      skip, ⌨️ needs_typing, ⚠️ other and a "Check verdicts summary" line through the shared analyser, over
      the `check=<id> verdict=<...>` lines of their own probes (Linux `tools/dev/linux-field-shell-checks.sh`,
      Windows step `collector_checks`, macOS `macos-field-shell-checks.sh`) and the last run of each tray
      check clicked today (runs and failures counted). Left [PHYS-W] [PHYS-L]: one real run of each
      collector; the Windows runtime layer of `test-windows-field-report-contract.cjs` runs only where pwsh
      is installed.
- [ ] **Windows field run without a click.** [CODE] [PHYS-W] Done: the shared protocol
      `_shared/data/field_run_protocol.json` (files, verdicts, refusal reasons, identifiers, required keys;
      the macOS declaration is pinned to it) and its Windows side: `infra/field_run.ahk`, started in
      developer source mode only, runs `windows/data/field_run_steps.json` (boot cost against [budgets]
      boot_total_ms, the network check, the composer check) without their windows; the collector writes the
      request, waits for done, copies `field_run/` and writes `field_run_checks.txt`, which the analysis
      marks, and skips with a verdict line when no developer driver of the clone is ready. Left [PHYS-W]:
      AutoHotkey never ran this code (written without Windows): start `tools/dev/run-windows-dev.ps1`, run
      the collector, and check that the three results and done.json arrive; then run the AHK suite and
      parse. The Linux side is the Linux worker's (`fix/linux-input-config-2`).
      is installed. Linux no longer needs a click (branch `fix/linux-input-config-2`): the daemon owns the
      macOS field run's protocol (`linux/infra/field_run.lua`, `linux/data/field_run.json`, the same file
      names, verdicts and reasons, pinned against macOS by a test) and runs its composer and network checks
      headless; `tools/dev/linux-field-run.sh` sends the request from the collector and prints a mark per
      step (`tests/hardware/run_field_run_live.lua`, CI step "Run the field checks without a click"). The
      Windows tray checks still need a click (another worker owns that side and the shared declaration;
      the Linux side moves onto it if its names differ).
      is installed. Linux no longer needs a click (branch `fix/linux-input-config-3`): the daemon reads the
      shared protocol `_shared/data/field_run_protocol.json` (file names, verdicts, reasons, identifier
      and code rules, folders, the keys of each document) and only its steps from
      `linux/data/field_run_steps.json` (`linux/infra/field_run.lua`), and runs its composer and network
      checks headless; `tools/dev/linux-field-run.sh` sends the request from the collector, to the clone's
      folder first, then the installed one, and prints a mark per step
      (`tests/hardware/run_field_run_live.lua`, CI step "Run the field checks without a click"). The
      Windows tray checks still need a click (another worker owns that side). Open in the shared
      declaration: `step_kinds` has no `guard`, the kind macOS and Linux write for `config_guard`, and
      `documents.refused` lists `request_id`, which both drivers leave out for a request without a valid
      one.
- [ ] **Field log analysis.** [CODE] Done: `tools/dev/field-log-analyse.py` (Python 3.8, stdlib) runs at the end
      of every collector on the scrubbed day logs only and writes `analysis.md` and `analysis.json` at the top
      of the report: errors and warnings grouped by module and template with first and last time, an example
      and the groups new since the previous report of the same OS tag; boot total and stages, reload time
      (request to next boot), menu rebuild and per submenu, hot-path segments (hotstrings, tooltip and
      preview, keystroke), phase summaries and Windows latency lines, main-thread holds, preferences saves,
      keystats ingest ticks, synchronous diagnostics, LLM latencies per backend, late key events, each with
      count, p50, p95, max, worst occurrences and a verdict against the budget its code declares
      (`[logger] hotpath_slow_ms` and the Windows per-segment overrides, `SLOW_TIMER_CALLBACK_COUNT_MS`,
      `SLOW_SAVE_REPORT_MS`, ingest `REPORT_THRESHOLD_MS`, or the budget the line states); lifecycle events;
      and a ranked top 10. One vector per driver spelling
      (`tools/test/fixtures/field-log-analyse/vectors.json`) fails the test when a source stops writing a
      template it reads. The `[budgets]` section of `_shared/modules/timings/constants.toml` now declares boot,
      reload, menu rebuild, local and remote AI request and prediction display budgets from the measured
      macOS logs; the driver that takes each measure writes "Over budget: <what> took N ms (budget B ms)."
      (`_shared/lua/perf_budget.lua`, `windows/infra/perf_budget.ahk`), and Windows writes one
      `LLM request: kind= provider= family= outcome= in N ms.` line per prediction
      (`modules/llm/llm_request_latency.ahk`). Left [PHYS-M] [PHYS-L] [PHYS-W]: the Lua and AHK suites
      did not run where this was written (no Lua or AutoHotkey there): run `npm run test:hs`, `test:linux`
      and the AHK suite; the Linux driver measures no reload or menu rebuild yet, the Windows one no menu
      rebuild, so those budgets are judged on macOS only.
- [ ] **macOS field holds of 2026-10-30 (worker `perf/macos-field-holds`).** [CODE] [PHYS-M] From the field
      report `mac-2026-10-30_210120` (141 holds over 250 ms). Done: the unjournaled-ledger admission scans data.sql
      with native finds (17 s hold, append prepare=17225 ms; about 15x faster); the personal-row alias check of a
      preferences save is indexed once (hotstrings=970 ms of the 2 s saves, which are also the 2 s
      `startup_controller` holds; 3.3 s to 0.16 s with 12 personal groups); the dynamic-rule preview provider tests
      a suffix before its settings-reading section guard (preview.providers 1.7 ms per key); the synchronous
      diagnostics line names its slowest collectors on the three OS; the keyboard-layout row times its sources,
      bundles, variants and rows stages. Left, from the next field report: (1) menu rebuilds are 90 of the holds
      (28 s, about 300 ms each, keyboard_layout up to 420 ms). The recurring evening ones followed
      input-source notifications that changed nothing (26 in 3.5 min, same layout); the tap-key rows now
      rebuild only on a visible change. Read the new `menu_keyboard_layout.*` phases for the rest; (2) preferences save `sparse` (about 280 ms) and `write` (600 to 800 ms, 4 metadata forks) were not
      reproduced off the Mac; (3) keystats append `write` 150 to 350 ms and the ledger read itself remain on the
      main thread; (4) name the collector behind the healthcheck 100 to 230 ms from its new line, and the
      ignored-window AX probe (500 ms timeout); (5) the one-off holds of `field_run`, `error_dialog`, `keymap/utils`
      timers and `menu_state` (shell.ioreg 146 ms).
- [ ] **Thinking off for every model on every backend and OS (workers `fix/llm-thinking-off`,
      `fix/llm-thinking-off-2`).** [CODE] The rule depends on the MODEL, not on the provider: model families
      of `thinking_off.json` declare an intent and a control kind, each provider and local server the dialect
      that carries it; a 400 naming an injected field is retried once without it and remembered. Done on the
      three OS: cloud providers, local servers, MLX, default-only sampling, the resolved Ollama `think` of
      every Ollama body (predictions, warmups, test prediction, models manager check, vision and agent: false,
      or the family's level when Ollama ignores false, gpt-oss `low`; the single-source guard fails a literal),
      and capability listings (OpenRouter `supported_parameters`, Anthropic Models API `capabilities`, Gemini
      `models.list` `thinking`): fetched per provider off the request path, cached `ttl_hours`, and a control
      a listing says a model lacks is skipped before sending. Left: run the Windows suite (AutoHotkey could
      not run in the cloud container: `model_capabilities.ahk`, the `think` spec of `vision.ahk` and
      `LLM_OllamaThink` are covered by the shared corpus but unexecuted); the listing cache lives in memory,
      so a restart fetches it again on its first request.
- [ ] **Every known cloud AI provider in `api_providers.json`, on the three OS (workers `feat/llm-providers`, `-3`).**
      [CODE] Done (official documentation read 2026-10-30, each descriptor's `_source`): Perplexity, Moonshot,
      DashScope, Z.ai, MiniMax, SiliconFlow, DeepInfra, SambaNova, Hugging Face, NVIDIA NIM, Nebius, Novita,
      Hyperbolic, Scaleway, OVHcloud, Upstage, AI21, Venice, Vercel AI Gateway, Poe, Featherless, Inception,
      Chutes, Requesty, Baseten, Reka, StepFun, Volcengine Ark, Baidu Qianfan, iFlytek Spark, Baichuan. The three
      drivers read the catalogue generically (key, requests, `<base>/models` listing), so no driver code changed;
      labels are brand names read from the catalogue, like the providers before them, so no locale key.
      `test_api_provider_catalogue.lua` (macOS, Linux) requires a default-model thinking vector and a recorded
      listing or its reason for every provider; the shared corpora are replayed by the three drivers. Not added:
      GitHub Models (retired 2026-07-30), Lambda Inference (shut down), 01.AI (API stopped 2026-09-03), Aleph Alpha
      and Liquid AI (no public hosted API), Writer (its reference documents `POST /v1/chat`, not
      `/chat/completions`, and lists `{"models": [...]}`), Tencent Hunyuan (moving to TokenHub `hy3`, whose
      international address is only in third-party sources), BytePlus ModelArk (documentation unreadable).
      Inferred, not read: Chutes and Featherless honour `chat_template_kwargs.enable_thinking` on Qwen; SambaNova
      `enable_thinking: false` (only `true` is shown); whether Qianfan `ernie-5.1` is hybrid. Watch: Perplexity
      ended Sonar chat-completions support on 2026-09-27 (requests still answer, converted to its Agent API);
      `dashscope-intl` is a legacy shared domain; Moonshot K2 retires by December.
      Per-account providers (worker `feat/llm-providers-3`): Azure OpenAI / Foundry, Amazon Bedrock, Cloudflare
      Workers AI, Databricks, Snowflake Cortex are rows whose `base_url` is a template
      (`_shared/lua/llm/api_url_template.lua`, AHK port, shared corpus): the add-entry form of the three OS asks one
      value per placeholder (`menu.llm.api_prompt_field.<name>`), stores the filled address and needs a model, since
      these rows have no default model; an unfilled template is never sent. IBM watsonx.ai (model gateway, IAM token
      from the API key) and Google Vertex AI (the `authorized_user` credentials file, its refresh token exchanged)
      declare an `auth` block (`_shared/lua/llm/api_token_exchange.lua`): macOS and Linux exchange the key, cache and
      refresh the token, pause a minute after a refusal, and the key test waits for it. Left:
  - [PHYS-W] Run the AHK suite on Windows: `test_llm_api_url_template.ahk`, `test_llm_api_add_account_address.ahk`
    (the form with a template provider, the access-token refusal) and the rest of `run_all.ahk` were written
    without an AutoHotkey run.
  - Windows token exchange: the Windows driver refuses watsonx and Vertex AI with
    `menu.llm.api_provider_token_exchange_unavailable`; it needs the async form POST and the token cache the Lua
    drivers have (port of `api_token_exchange.lua`).
  - The first prediction after start (or after a key change) on an access-token provider is refused while the token
    is fetched (the boot pre-warm on macOS fetches it early); a Vertex service-account key (signed JWT) is not
    taken; the IBM gateway lists only the models an administrator configured.
  - Cloudflare AI Gateway was not added: its `/compat` address is deprecated for Workers AI's own, and a gateway
    used with the user's provider key needs a second header (`cf-aig-authorization`) the entries cannot hold.
  - The listing reader takes `data` (and `models` for Gemini) only: DashScope's native listing
    (`output.models[].model`) and Writer's `models[]` would need a per-provider listing shape on the three OS.
  - With about forty providers, the Linux zenity prompt of the screen actions lists every one on a line.
- [ ] **Every known local AI server in `local_servers.json`, on the three OS.** [CODE] Detection by process,
      settings file and port like the existing four, with the thinking-off dialect: vLLM (8000), SGLang
      (30000), KoboldCpp (5001), text-generation-webui (5000), TabbyAPI (5000), GPT4All (4891), AMD Lemonade
      (8000), Docker Model Runner (12434), Microsoft Foundry Local (dynamic port), llamafile (8080, shared with
      llama.cpp and LocalAI), a hand-started `mlx_lm.server` (8080), exo (52415), Msty, AnythingLLM. Ports
      shared by several servers are probed once and named together, as llama.cpp and LocalAI are.
      Windows (30 Oct): detection is data-driven (`LocalServerPortsDescriptor`, `.exe` names, command-line and config ports, the shared port corpus), so a server added to the JSON needs no AHK code; the new servers themselves are not in the JSON yet on any OS.
      macOS: detection reads every server of the shared list through the shared discovery descriptor
      (`local_servers.lua`, `llm.local_server_ports`), so the added servers need no macOS code; the field
      run's `field_local_servers` fails when the driver cannot use a declared server's descriptor and names
      each server's answer read-only (branch `fix/macos-overnight-d`). Left: the shared entries themselves
      (another worker), then one field report on a Mac running some of them [PHYS-M].
- [ ] **Mac field report 2026-10-30 21:01, functional errors left open (worker `fix/macos-field-errors`).**
      Fixed there: shortcut full rebind on each bounded retry (35cc4a5d), pre-dispatch Ollama pull receipt
      (6f6b752f), one model-list error per outage (6051b50c), MLX server stopped before a repair (fcdb6f27),
      both schema versions named (9cfe90de), plus the diagnostics below. Left, one line per family:
  - [PHYS-M] **Ctrl+. after a layout flip.** Confirm on the next field run that no "Some shortcuts are still
    unregistered" line follows a "rebinding every shortcut (retry N)" line. If one does, the static chord was
    rebound while `hs.keycodes.map` still described the previous layout (18:30:09 rebound "for Ergopti" with
    a map lacking '.'): rebinding then needs the map's own change notification, not the TIS event.
  - [CODE] **Ollama pull refused while reading its request.** Such an exit leaves an empty receipt, which
    cannot be told from a crash after submission, so its task slot stays owned. Passing the receipt path on
    the command line would let the owner publish a pre-dispatch refusal for that stage too.
  - [PHYS-M] **Eventtaps refused at 10:07.** The errors now name `accessibility_trusted`; if it reads false,
    macOS withdrew the grant at run time and nothing asked the user again until the next boot.
  - [PHYS-M] **Personal hotstring reload rolled back (11:37, twice).** The editor and the registry now name
    the refusing step; read that line on the next save that fails.
  - [PHYS-M] **Key events lost upstream** (key-ups without key-down until 15:32, repeated key-downs until
    11:44): no line names a cause; they coincide with main-thread holds and Karabiner lease failures.
  - [PHYS-M] **MLX discovery after the 01:19 repair.** The rebuilt server answered `/v1/models` but 404 on
    every POST route for 340 s before discovery gave up; not reproducible without the Mac.
  - [PHYS-M] **Screenshot without an image (10:15).** The error now names `interactive=` and the stderr: an
    interactive capture with empty stderr would be an Escape reported as success, to be settled as a cancel.
  - [CODE] **Field check `app_health`** logs an ERROR from `fs_dir` when the driver's `crash_reports` folder
    does not exist yet (20:56, 21:06); an absent folder is zero reports (field-run owner).
  - [PHYS-M] **Keystats ingest "database is locked"** once at 20:52, during the field run's read-only checks;
    confirm whether the `quick_check` of `field_storage` overlapped the ingest transaction.
- [ ] **Container note.** `tools/test/test-managed-ollama-protocol.cjs` stops in a cloud container on Git's
      "dubious ownership" when run as a non-root user over a root-owned checkout; give the test its own
      `safe.directory` for its child Git calls instead of relying on the host configuration.
- [ ] **Remap guardian killed at every developer start (worker `fix/macos-guardian-adhoc`).** [CODE]
      [PHYS-M] macOS killed an ErgoptiPlus process ~3 s after "Registering the remap guardian" (CODESIGNING 4,
      Launch Constraint Violation) and the guardian only ran after the 10 s throttle. Done: an ad hoc build
      removes its exact legacy agent and its Background Items record, proves the old guardian gone, then
      registers; the register role names it `developer_adhoc_reregistered` (deferred while leases are live or
      approval is pending, refused when a removal is not proven), the driver logs it and `field_login_items`
      reports `guardian_registration`. Left [PHYS-M]: the next field run must show that note, no
      `ErgoptiPlus` codesigning kill in `field_app_health`, and `guardian_state` ready with a `guardian_wait`
      under 10 s.
- [ ] **Timed reload lost the app (2026-10-30 21:06).** [CODE] [PHYS-M] Accepted reload, lease revocation
      requested, an error window, then nothing: no boot, no crash report. Done: every coordinator stage and
      teardown step writes `reload_breadcrumb.txt` synchronously, the next boot appends `boot` and the macOS
      collector copies it; the error window stays closed during a reload or quit. `driver_reload` stays
      disabled (`reload_lost_the_app`). Left [PHYS-M]: reload by hand from the menu until one is lost, run the
      collector, and fix the stage the trail's last line names; then enable `driver_reload` again.

## Maintainer: remote branch cleanup (run on your machine; the cloud container's proxy refuses ref deletion and tag pushes)

The fix/<os> integration is on dev (2026-10-29), so it can run now. The script first tags the three fix
branches, because their audit handovers cite their original commits and their `.bundle` archives need them as
prerequisites, and the tmp branches whose commits never landed on dev (see the next section). The Mac field
branch is not kept, since every problem it
reported is fixed. It then deletes every remote branch except `dev`, `main`, `sparkle-appcasts` and
`gh-pages`.

```sh
git fetch origin --prune
for b in fix/macos fix/linux fix/windows \
    tmp/wip-todo-ae tmp/wip-todo-ae-par30 tmp/wip-todo-af tmp/wip-todo-ag tmp/wip-todo-ag2 tmp/wip-todo-ag3 \
    tmp/wip-todo-ah tmp/wip-ci-fix tmp/wip-fr-uncommitted tmp/wip-field-auto tmp/wip-field-run-checklist \
    tmp/wip-issue103 tmp/wip-issue104; do
  if git rev-parse -q --verify "origin/$b" >/dev/null; then
    git tag -f "archive/${b//\//-}" "origin/$b"
  fi
done
git push origin 'refs/tags/archive/*:refs/tags/archive/*'
git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin \
  | grep -vxE 'HEAD|dev|main|sparkle-appcasts|gh-pages' \
  | xargs -r -n 20 git push origin --delete
```

The resulting tags are `archive/fix-macos`, `archive/fix-linux`, `archive/fix-windows` and one
`archive/tmp-wip-<name>` per branch of "Commits never landed on dev" below.

## Commits never landed on dev (on tmp branches, archived by the cleanup above)

`git cherry -v origin/dev <branch>` still lists these on 2026-10-30. Some may have landed under another
patch (a squash): compare by subject with `git log --oneline dev | grep <subject>` before integrating.
After the cleanup, read them through the `archive/tmp-wip-<name>` tags.

- `tmp/wip-todo-af`: 8634b1ff80 (Linux acknowledges the layout scope once loaded), 358e211a10 (Windows
  number-row design answer), 3337d99bc8 (Linux number-row order onboarding), 4fcb4a979a (logger scalar),
  then `tmp/wip-todo-ag3` d5cf3ba50b (number-row strings for that work; it conflicts in the 21 locales
  unless the AF commits come first). AF also left: reconcile the Linux `keyboard_layout_scope` comments and
  the design note with the ninth batch. 8634b1ff80 is superseded by `fix/linux-layout-emulation` (its
  participant settles asynchronously, which the global scope's synchronous assertion refused); do not land
  both. That branch also reconciles the comments and both design notes.
- `tmp/wip-todo-ah`: 53b1bc5375 (reset every `hs.*` cache entry between macOS test files) and five CI
  speed-ups (Ubuntu archive reuse, AHK shard split, one macOS checkout per E2E cell, Intel E2E start,
  SwiftPM cache trial); run them on `tmp/preflight-dev` before dev.
- `tmp/wip-todo-ag`: 5fb762dc57, 8a3afb1eb3 (Linux reads config keys and menu command ids from the
  generated owner), 26fc3fbe61 (same on macOS), f091a98200 (generate the section and dynamic-table
  constants). `tmp/wip-todo-ag2`: d2f705b248 (machine-translation corrections).
- `tmp/wip-todo-ae`: 0c101e36bd (share the personal information editor source), 419a361a88 and
  9ec0d6d122 (keystats query catalogue typed slots and its cross-driver test).
- `tmp/wip-ci-fix`: f44fcc1e64, c9b90d11d7, ba13937b8c, 5009ad87b8 (Linux distribution-row CI fixtures):
  check each against dev first, later fixes may have replaced them.
- One commit each, probably superseded on dev: `tmp/wip-field-auto` 43675932bd (field run driven from the
  developer app), `tmp/wip-field-run-checklist` cf852cf23d (version-aware privacy panes, L29),
  `tmp/wip-issue103` b449da5713 (Windows updater reseal), `tmp/wip-issue104` aec2fb58cb (developer-build
  remap guardian).
- `tmp/wip-fr-uncommitted` (0d7e53b28b): an Ollama warmup-stop attempt, superseded by 708bc6671d; reference
  only.
- `tmp/wip-todo-ae-par30`: 41f72525cf is an unvalidated work-in-progress snapshot of the PAR-30 Linux
  updater signature gate; redo it from the item, do not cherry-pick it as is.

## Linux open items from the July plan

The July Linux driver plan (X11/Wayland hotstring engine, 2026-07-30) is retired; its rejected
gesture routes are in `docs/memory/rejected_proposals.md`. Its notifier, LLM manifest section and LLM
HTTP transport items are done (`linux/adapters/notifier.lua`, `[sections.llm]` lists `linux`,
`linux/modules/llm/api_remote.lua`). Still open on 2026-10-29:

- M3.3: split `linux/ui/menu/menu_builder.lua` into one module per section builder. [CODE] Every
  submenu already renders through `_shared/lua/menu/renderer.lua` (`infra/manifest_menu.lua`); the
  split itself landed on 2026-10-30 (branch `fix/linux-menu-split-2`), option (a): the analysers follow
  the module boundary.
  - The root binds each builder as `local _build_x = require("ui.menu.menu_x").build` and the shared
    zenity dialogs and binding helpers name by name from `ui/menu/menu_dialogs.lua`. It keeps the
    imports, the facade, header and separator checks, the header builder, the pause greying and
    `M.build` (about 480 lines).
  - Gates read the root through `tools/lib/linux-menu-parts.cjs`. It admits only that wiring (part
    modules hold the root's own imports, their `LOG`, local definitions, `M.<field>` exports and
    `return M`) and recomposes the root the single-source analysers already read. `readSourceFile()`
    is the by-path reader; directory scans keep reading files raw so a part is never counted twice.
    `test-linux-menu-parts.cjs` and the caption-binding, language-owner and lifecycle checks carry
    split-module counterexamples (`tools/test/lib/linux-menu-split.cjs`).
  - Lua tests: the runner reloads the cached `ui.menu.menu_*` modules whenever the root's file runs
    (`tests/support/menu_part_reload.lua`; the root never writes `package.loaded`), and text checks
    read `helpers.read_menu_source()` (root, then each bound part).
  - A part may import only what the root holds, so the root still carries imports only parts use
    (`ParentSource`, `Version`...). Hoisting them would need the analysers' import whitelist
    (`closedModuleExport` in `tools/lib/menu-native-llm-parent-binding.cjs`) to follow the parts too.
  - Left: renaming or deleting the root itself (`require("ui.menu.menu_builder")` callers, the frozen
    census oracle's `CURRENT_SOURCE_RETIREMENTS` in `test-native-menu-rows.cjs`, the
    `linux_evidence.json` paths). The coordinator's plan named this last step; it was not started.
- 20 of the 36 gesture slots are physically out of reach on some machines. [PHYS-L] The menu greys
  them; since 30 October the reader start also names every unreachable slot and warns for each bound
  one (`modules/gestures/slot_report.lua`, a binding written by hand never passes through the menu).
  Left: a three-finger pad on a real machine.
- Without a grab, the desktop (GNOME 47+) acts on the same gesture.
- The 9 two-finger slots fight with scrolling everywhere. The decoder already refuses a scrolling
  pair as a swipe (its rule 1) and the reader start now names each bound two-finger slot; the desktop
  still acts on the same ungrabbed touches, which no code here can stop without the grab.
- No external process can move, focus or close a window under Wayland.
- The decoder's event trace is a reconstruction, not a capture. [PHYS-L] Code done 30 October:
  `tests/support/touchpad_record.lua` reads `libinput record` files, `test_touchpad_record.lua` replays
  every `linux/tests/fixtures/touchpad_record_*.yml` trace into the decoder, and the uinput round trip
  replays its own kernel capture through that reader. Left: one recording from a real touchpad
  (`linux/HARDWARE.md` section 13).
- Done: the navigation layer's wheel bindings run on Linux (the recommended layer makes it the
  volume, as on Windows and macOS). The hook grabs the mice only while the held layer binds a wheel
  direction and forwards everything else through the virtual device
  (`tests/unit/adapters/keyboard_hook/test_keyboard_hook_nav_wheel.lua`, hardware-free). Left
  [PHYS-L]: a real mouse on a real desktop (pointer speed under the hold follows the virtual
  device's libinput settings, not the mouse's); mouse buttons stay no layer source on Linux.
- Remote API keys now live in the desktop secret service (`linux/modules/llm/api_token_store.lua`, commit
  "keep remote API keys in the desktop secret service"; refused, never written in plaintext, without one).
  Left: [PHYS-L] on a real desktop, add a key with the keyring locked and check the unlock prompt takes the
  keyboard under the grab (`ui/modal.lua`), then restart and check the plaintext migration of an older
  `api_keys.json`. `install.sh` now installs `secret-tool` (apt `libsecret-tools`, dnf `libsecret`, zypper
  `secret-tool`, pacman, xbps and apk `libsecret`); the deb and rpm still only recommend it.

## Next fix/<os> agent pass (read when the maintainer asks for a new fix/linux, fix/macos or fix/windows)

The 28 October passes (Codex agents, one per OS) were squashed onto dev as
`fix(macos|linux|windows): land the fix/<os> audit branch`. Their original histories are kept as tags `archive/fix-<os>` once the maintainer
runs the branch cleanup below. Each pass left a full handover; read it first:

- macOS: [docs/audits/macos/2026-10-28/](docs/audits/macos/2026-10-28/) (`TODO.md`, `report.md`).
- Linux: [docs/audits/linux/2026-10-28-closeout/](docs/audits/linux/2026-10-28-closeout/) (`README.md`, "Outstanding
  TODO").
- Windows: [docs/audits/windows-2026-10-28/](docs/audits/windows-2026-10-28/) (`README.md` "Remaining findings",
  `POST_VALIDATION.md` "Resume from a fresh checkout").

**How a pass must run, so no time is lost:**

1. Branch `fix/<os>` from the current `dev`, never from an old fix branch. Keep it linear: rebase onto dev, and
   never run `git merge dev` into it. The 28 October passes merged dev a dozen times each, so they could not be
   replayed commit by commit and had to be squashed.
2. Push every hour and dispatch `gh workflow run ci.yml --ref fix/<os> -f os_lanes=<os>`. A pass is done only
   when its lane and Common are green.
   - On 28 October the Windows pass stopped with 3 unit groups red.
   - The Linux pass stopped with the RPM and AppImage installed-data checks red.
   - The coordinator had to fix both before the release.
3. Stay in the OS's own files. Shared tests (`tools/test/*.cjs`) touched by two passes conflicted: the macOS and
   Linux passes rewrote the same App Cloner, bash-resolution and PAC source tests in different ways. Leave
   shared files to the coordinator, or announce them first.
4. Workflows (`.github/workflows/*`) may be edited when a fix needs it; say so in the commit.
5. Evidence goes into one `docs/audits/<os>/<date>/` folder: a README with the remaining work at the top, then
   any archives. Keep each archive under 10 MB.
6. Host notes:
   - Run as a normal user with `USER` and `LOGNAME` set; the JS suite refuses root.
   - Use Node 22.22.2 and Ruff 0.15.8, and PowerShell 7 for the Windows host checks.
   - AutoHotkey under Wine is narrower evidence only; it does not replace Windows CI.
   - **Host-only reds on the Linux container** (not bugs): JS `test-ahk-tap-follower`, `test-linux-install-sandbox`,
     `test-linux-runtime-native-registration`, `test-macos-managed-bootstrap-http`, `test-managed-ollama-protocol`,
     `test-managed-remote-retirement` (no pwsh), `test-linux-deb-package-owner` (refuses root),
     `test-drift-guard-covers-every-output` (worktrees only, node_modules symlink). Lua as root: every
     EACCES/unreadable/denied case, Linux test 102, four `test_sqlite_first_open` native cases; macOS screenshot
     EACCES, two mlx-repair unreadable neighbour, errors-log refuses denied, the eight `release-arming-physical`
     cases (refuse root). Confirm with
     `setpriv --reuid=65534 --regid=65534 --clear-groups` and set `XDG_RUNTIME_DIR`. Run the macOS suite per
     group: one process slows down progressively here.

**Left open by the 28 October passes:**

- Windows (from its README, "Remaining findings"):
  1. A crash-torn SQL ingest can acknowledge an unreadable ledger. The admission prototype is in the evidence
     archive (`windows-ledger-admission-r19`); its lifecycle cases are not qualified.
  2. Configuration restore can publish a substituted staging file, through a pathname race. It needs a native
     design that owns destination creation; test it on a real Windows.
  3. Uninstall can recycle a foreign replacement, through an unregister race. It needs an identity-preserving
     quarantine.
  4. Stored n-grams cannot tell literal bracket text from control markers. This needs a versioned token format
     and a policy for the existing history.
  5. The native builder validation has literal-path and schema defects. Its review patches are archived; an
     official MSVC regeneration is required.
  6. The diagnostic archive acknowledgement fails intermittently (run 40709098135); the cause is unknown.
  7. Developer interpreter selection still needs native PowerShell 5.1 qualification, and three Ollama DELETE
     cases failed under Wine, cause unknown.
- Linux (from its closeout):
  1. Physical acceptance (evdev/uinput grabs, polkit, autostart, Wayland/X11) still needs a real machine.
  2. Done 30 October: on CPython 3.8.20 (uv) both XKB suites pass (42 and 265 tests, 14 skips for
     xkbcli >= 1.13 and the xkbcommon binding, absent here), `generate_xkb_files.py --check` reproduces the
     shipped files and every installer CLI starts; nothing needed a fix.
- macOS (from its TODO, plus Mac bugs the Linux pass proved): items 1 to 6 done 30 October on
  `fix/macos-overnight-c`.
  1. Done: `native_bootstrap_python` owns its workspace; INT/TERM/HUP release it, restore the caller's handlers
     and re-raise, so the status stays 143 and the caller's EXIT report names the stage
     (`test_native_python_bootstrap_interrupt.lua`, real bash and a real group SIGTERM in both download stages).
  2. Done: `network_env.lua`, the MLX download and the webview locale base split on the host separators
     (`native_path`) and the URL base is percent-encoded (`test_posix_backslash_source_paths.lua`, tree scan).
  3. Done: the installers share `sha256_file_digest` (`network-retry.sh`), the release stage and the Karabiner
     checksum parser strip shasum's escape marker (`test_sha256_digest_escaped_names.lua`). Left: the build-time
     `tools/build/build_macos_app.sh` digests (lines 261, 811) take the first field too; a shared JS test pins the
     second spelling, so the coordinator owns that change.
  4. Both leads confirmed in the source and fixed. `OwnedProgramWorker.runBridge` verified a terminal before
     forwarding it, so an unforwarded receipt exited 0 (`OwnedProgramForwardingTests`, requires exit 70; not run
     here, the macOS launcher lane runs it). `InstalledPhysicalSourceBridge` short-circuited its nonblocking
     setup after a refusal, so the first read of a quiet held child blocked before the cancel
     (`test_native_bridge_transport_setup.lua`; a native reproduction still needs a real installed peer).
  5. Done: the case asserts the `pcall` status and an empty return; the archived r29 fault probe now fails it.
  6. Done: the cause was a collection of earlier modules' garbage finishing inside one step (heap 40 MB to
     15 MB in a 14 ms step, against 0.5 ms of replay work). Each step now runs after a full collection with the
     collector paused, the 20 ms budget is unchanged, and a new bound caps a step's own allocation at six blocks.
- CI: the macOS 26 "Run Swift launcher tests" step hit its 10-minute limit twice on 28 October, in main run
  40764020578 and fix/macos run 40765470617. `HomebrewArchiveAcceptanceTests` alone took 289 s, and a real PAC
  trust test was still running at the limit. Move the real-network cases into their own job, or raise the step
  budget with a measured reason.

## Mac field session 2026-10-27: problem ledger

Every problem seen on the maintainer's Mac on 2026-10-27 (macOS 26.6.2, arm64), from issue
[#104](https://github.com/adrienm7/ergopti/issues/104) (body; no comments), the field reports
`mac-2026-10-27_150026`, `_151611`, `_152936`, `_164726` and `new.txt` (the day's WARNING/ERROR
log) on the `field/mac-2026-10-27` branch, which never reaches dev. Builds seen: ba73f58 (15:00),
92d4615 (15:16), b014076 (15:29), 228f79f2 (16:47 developer app). The 16:28 to 16:54 boots ran
after every 14:00 to 15:38 fix below, so "not seen after 16:28" is the evidence for those fixes.
The automatic report `mac-2026-10-27_194738` (developer app from about dev 57fd72c1fb, boots
19:47:05 and 19:48:21) is "the 19:47 run" below; L40 onwards come from it. The report
`mac-2026-10-27_210657` is "the 21:06 run": its Lua and shell were current (dev 35725ebc22 era),
but the collector reused a running developer app whose launcher predates L40 and L41 (fixed by
e4ca76b1c9), so no Swift fix was active. Labels are local to this ledger. A label cited here without its own entry below was fixed; its entry is in
`git show 7f80d3d141:TODO.md`. Shas on `tmp/wip-audit-field` change when rebased onto
dev.

### Open TODO

- **L46** [CODE][PHYS-M] Two-finger scrolls switched tabs through the vertical three-finger swipe
  (`swipe_3_up` tab_prev, `swipe_3_down` tab_next); the maintainer turned the option off. The
  day logs hold no live fire line (the swipe action was off and the log collapses repeats), but
  show the shape: `Finger join (fast-path): 2 → 3` immediately followed by `n 3 -> 2` (14:25:52).
  Causes in `modules/gestures/engine.lua`: a third contact joined a pair on ONE frame; a count drop
  shifted startPos but left endPos frozen, so a palm touching below the pair for a frame committed
  a vertical swipe toward it; a resting thumb moved the centroid two thirds of the scroll; a
  three-contact touch-down continued as a moving pair; a three-finger touch landing on a scroll's
  momentum. Fixed on dev (6d3aa65273), then rebalanced on `tmp/wip-three-finger-swipe2` after the
  first Mac test missed deliberate swipes: a pair that has scrolled (direction locked, travel past
  the two-finger lock `SWIPE_MIN_2`, or a macOS scroll phase) or outlived `multi_finger_landing_ms`
  (300) never promotes; before that a third finger promotes once held `pair_join_confirm_ms` (20);
  every contact must cover `Geometry.COHESION_MIN_SHARE` (0.3) of the travel since the promotion;
  a three-finger gesture that continues as a moving pair aborts; `scroll_momentum_guard_ms` (200)
  follows only a native momentum phase or a locked pair lifting. Each refusal writes one DEBUG line
  `Three-finger candidate rejected by <gate>: <measured value>` (gates: frames held, pair scroll,
  landing window, cohesion, scroll guard). Linux `mt_decoder.lua` had the same one-frame peak and
  whole-touch travel: same rules there (`finger_join_frames` 2, landing, peak-only travel, pair
  abort, scroll guard, same DEBUG lines). The cohesion share stays with the other spatial
  thresholds in `geometry.lua`: the timings registry is read through `sec` by the 22 engine test
  stubs, which have no `count`. Windows: no shared flaw, the precision touchpad driver recognises
  three-finger swipes itself and sends the configured key chords
  (`windows/modules/gestures/init.ahk`), so Ergopti counts no contacts there. Mac confirms:
  re-enable the vertical three-finger swipes, scroll with two fingers for a few minutes (with and
  without a thumb resting), no tab switch; deliberate three-finger swipes (slow, fast flick,
  staggered landing) switch tabs every time; any miss leaves a `rejected by` line naming the gate.
  Second Mac test (field report `mac-2026-10-28_095854`, macOS 26.6.2, built-in trackpad): swipes
  worked, then were refused for a while in a row (09:47, 10:00 to 10:04) while scrolling kept
  working. Causes on `tmp/wip-three-finger-stuck`: (1) frames were timed when Lua processed them,
  and a main-thread stall (keystats tap found disabled at 10:01:31) delivered 35 queued frames in
  2 ms, so `frames held: 2 -> 3 held 35 frame(s), 2 ms` refused a real swipe; the engine now times
  frames by the touch device's capture stamp (`modules/gestures/frame_clock.lua`), and Linux by the
  kernel's SYN_REPORT stamp. (2) macOS emits momentum after a swipe's last two fingers lift for
  the scroll the blocker swallowed; that momentum armed the scroll guard
  (`10 ms / 6 ms / 0 ms since the last scroll`), so each swipe refused the next one within its
  momentum: the "suddenly stops" chain. Momentum now arms the guard only after a scroll phase the blocker let through.
  (3) A 4 -> 3 -> 2 cascade measured the pair from the three-finger centroid, so the jump aborted
  the gesture (`pair travel 9.07` at 09:47:02). (4) An aborted swipe that had already fired armed
  the guard and let its tail scroll; it now keeps the block and arms nothing. (5) An aborted
  gesture stayed aborted while one finger rested, refusing every swipe silently. (6) Cohesion
  logged a false `0.00` when the direction locked on the promotion frame. The
  `finger count unstable` lines are the intended 60 ms settle after a count change, not a refusal. Linux shares
  only (1): its decoder commits at the lift, has no momentum source or re-tap path, and sets its
  drop origin on the pair's own frame. Windows: unchanged, the precision touchpad driver
  recognises the swipe. Mac confirms: after a reload no `has no capture timestamp` ERROR line,
  and `Confirmed multi-finger join` lines still read about 8 ms per frame (the stamp is in
  seconds, as the touchdevice frame callback documents); ten vertical three-finger swipes
  in a row, one every half second, right after a two-finger scroll stops and while a finger rests,
  each switch a tab; a swipe landing on a still-running two-finger momentum is refused with
  `scroll guard`; two-finger scrolls with and without a resting thumb never switch tabs.
  Third Mac test (field report `mac-2026-10-28_125123`, 12:51 to 12:53): swipes are accepted, but a
  normal one switched two or three tabs (sd 19.84 committed 3 steps at sensitivity 5; 138
  `INCREMENTAL FIRE` lines in about 40 s) and a small one could switch none. Causes on
  `tmp/wip-three-finger-step`: the step was one action per 5 units and the first action needed a
  whole step; and `INCREMENTAL FALLBACK REBASE ... diff=-1` (sd 39.78 after 8 steps, 4.91 after 1)
  took no action back but restarted the count at the current point, so the next small move
  forward fired the same step again (double counting). Incremental mode now fires its first
  action after `Geometry.INCREMENTAL_FIRST_STEP` (4, or one step if shorter) and each further
  action after one more sensitivity; a shrinking distance holds the actions fired, and a reversal
  needs half the first step back from the last fire. `swipe_3_up`/`swipe_3_down` first defaulted
  to 50 (4.9 and 45 one tab, 54 two); on the Mac two actions then needed far too long a swipe, so
  the default is 25 per action: 4.9, 19.84 and 26 give one tab, 29 to 54 two, 54 and more three.
  The menu's "Distance per action" keeps that meaning and offers 20, 25 and 30 around it. A value the user chose is kept (saves are sparse, so only
  an explicit choice is in `config.toml`). Linux has no incremental mode (one action at the lift)
  and Windows uses the precision touchpad driver. Mac confirms: no explicit
  `[gestures.sensitivities]` swipe_3 value in `config.toml` (or remove it), then a normal and a
  short deliberate vertical three-finger swipe each switch exactly one tab, a swipe past 29
  units (the logged `sd`) two, and lifting never adds or removes one.
  Since 30 October the field run proves the capture stamp from the session's own touches, with no
  manual step: `field_gesture_frames` fails `unstamped:N` on any frame without a stamp, names
  `gesture_frame_spacing_ms` (about 8), and skips when the trackpad was not touched.

- **L16** [CODE][PHYS-M] Slow ingest tick, `append` phase 466 to 563 ms, peaks 1531 and 1709 ms
  (new.txt 14:25:50 to 16:53:38, 20 lines, still on 228f79f2). The 1.2 to 1.8 s ticks are the
  log_manager.lua:1722 holds. `LedgerAppend.flush` (adapters/ledger_append.lua) takes the lock,
  reads the journal, publishes it atomically, reads the tail, appends, clears the SQLite outbox
  and publishes the journal again; `prepare_append` reads the whole data.sql (68 MB) only without
  a journal, so the cost is not proven yet. The 22:55 report (`mac-2026-10-27_225536`, code of
  16:48) shows the same 481 to 689 ms `append` for one entry, all day, while `outbox` (lock and
  journal read with an empty batch) stays at 2 to 4 ms. Hypothesis from code: each of the two
  journal publications of a non-empty flush is a `write_atomic` of an existing file, which runs
  four synchronous `hs.execute` forks (`ls -led` twice on the source, `cp -p`, `ls -led` on the
  staging copy) from the large Hammerspoon process, so about eight forks per tick. Instrumented on
  `tmp/wip-mac-holds`: `LedgerAppend.flush` reports its stages and the line now ends with
  `; append: lock= journal= prepare= publish= write= clear= settle= release= ms; metadata_commands=<n>
in <ms> ms` (`adapters/metadata_command_stats.lua` counts every metadata fork). Mac confirms: the
  next `Slow ingest tick` line names the stage; if `publish` and `settle` carry it with
  metadata_commands=8 near the total, the fix is to stop forking for the private journal. The 23:33 run measured a fork: four `mkdir -p` of the keystats start took 161 ms, about 40 ms each, so eight journal forks match the 0.3 to 0.7 s append. Fixed on `tmp/wip-mac-holds-2` (016ef6adc5): the driver-owned journal is published by `FileSystem.write_private_if_unchanged` (same lock, route, staging and compare-before-write, no carried ACL or xattrs); a flush forks nothing (`test_append_retry.lua`: 4 forks before, 0 after). Mac confirms: no `Slow ingest tick` and no `Main-thread hold` line from log_manager.lua during typing. Since 30 October the field run's event taps check names `worst_hold_ms` and `worst_hold_site` (file and line).
- **L17** [CODE][PHYS-M] "Slow preferences save 1.9 to 2.1 s (prepare about 1.25 s, write about
  0.8 s; operations=293)" (new.txt 15:27:35 to 16:48:20, 6 times, also on 228f79f2). It is the
  2.06 s hold of startup_controller.lua:263 (15:28:57, 16:48:20). Next: profile `prepare` for 293
  operations and why a one-key save carries 293. Instrumented on `tmp/wip-mac-holds`: `prepare`
  now starts before the runtime snapshot and the line adds `; prepare: snapshot= decode= models=
sparse= wrap= rows= gestures= llm= shortcuts= hotstrings= ms; proposed=<rows>; metadata_commands=<n>
in <ms> ms` (the forks of the write phase). Not reproduced here: the save writes the whole sparse
  snapshot by design (the 293 are every non-default row, not the changed key). Mac confirms: the
  next slow-save line names the prepare stage and how much of `write` the forks take. Not reproduced: the same whole-snapshot save over `_generated/config_template.toml` costs 58 ms of Lua here against 1291 ms of prepare on the Mac, so the gap is not the save's CPU. The slow-save line now also gives `lua_heap=<before>-><after> MB` (380a8d4445) to tell a garbage collection apart. Mac confirms: the next slow save names its prepare stage and whether the heap dropped.
- **L18** [CODE] keystats start still holds the main thread 1.1 to 1.3 s from the deferred timer
  at menu_state.lua:531 (new.txt 16:28:06, 16:48:13, on 228f79f2). Next: move the SQLite open and
  offset replay of `kl.start` into slices like the recovery. The 22:55 report splits it: 150 to
  270 ms before `sqlite_writer` initializes, then 917 to 1047 ms between `rotation Initialized` and
  `Aggregate cache recovery continues in 8 ms slices` on the two boots that started a recovery;
  boots without a recovery hold 264 to 874 ms (16:54 to 22:55). Not changed on `tmp/wip-mac-holds`
  (time box); the slicing remains the fix. Fixed on `tmp/wip-mac-holds-2` (58f82e9fdc) after the 23:33 run (1300 ms: 161 ms of four `mkdir -p` forks, 696 ms of the one-time L19 index build, 392 ms of the synchronous first `ingest_once`, 48 ms of watchers): existing folders are answered from their attributes and the first ingest runs on the first 5 s tick, which flushes the outbox first (`cold_rollover_context_process.lua` asserts no synchronous ingest and no fork; 4 forks before). The index build happens once per cache and is done on this Mac. Mac confirms: `Keystats engine start (deferred)` under 100 ms and no hold from menu_state.lua:531. Since 30 October the field run's storage check names `keystats_start_ms`.
- **L23** [CODE] "Ignored-window prewarm incomplete; tracking remains fail-closed" (new.txt
  15:28:28, 16:28:04) and 1 s holds from keymap/utils.lua:1426 and :1455 (14:26:05, 15:34:09).
  Next: log which prewarm stage was incomplete and bound the 1 s probe. Instrumented on
  `tmp/wip-mac-holds`: the warning reads `prewarm incomplete (probe stage <watchers|focused_window|
application|app_name|title|context_watchers|secure_field>, TTL refresh <armed|not armed>)`, and a
  probe over 250 ms logs `Slow ignored-window probe <ms> ms (<stage>=<ms> ...)` from the refresh
  and TTL timers too (`test_winfilter_prewarm.lua`). The bound is not added: it needs the stage
  that waits first. Mac confirms: the next prewarm warning and any slow probe name the AX read.
- **L24** [PHYS-M] key_event_health: key events 250 ms or more late (max 879 ms), 100 key-downs
  without key-up, 81 key-ups without key-down, 62 keys stuck over 3 s, one key stuck 518 s
  (new.txt 09:54 to 10:36, session totals); issue #104 shows 1 late key. Most late events follow
  the main-thread holds of L16 to L19. Next: after those, re-read the totals; lost key-ups without
  a hold point at the Karabiner virtual HID path (big item 2). `tmp/wip-mac-holds-2` names every timer hold from 250 ms on (82c220c089: one `Main-thread hold of N ms in an hs.timer.<kind> callback (<site>)` evidence line per site and minute, with the `shell.<program>` fork phases of d0993e39e4 and the Lua heap); the 23:33 log counted 7 to 18 such holds per 5 minutes without a site. The menu rebuilt twice at every boot (591 then 513 ms); the login item state is now asked before the prime build (fec27c153e) and each refresh logs its requester at DEBUG.
- **L25** Known limitation, plus one open bug. "Failed to enable 'Composer Check' —
  reason=process_failed" (new.txt 14:31:52, 16:48:44). The TIS probe (issue #104 and `_152936`)
  shows macOS 26.6.2 refuses it: register 0 and enable 0, but the source stays disabled, select
  returns -50, the HIToolbox preference route is refused too, and removed sources stay listed
  until logout. The rollback disable right after was refused "busy": `run_bounded_process`
  (modules/keymap/input_sources.lua) published the terminal before freeing the mutation slot, so
  a mutation started from that callback was refused. Fixed af5765a659. Mac confirms: after a logout, the probe's `after-logout` mode for M5b/P6.
  Correction (tmp/wip-composer-macos26): the "HIToolbox preference route is refused" was never
  measured. Probe v4's restart ran `launchctl kickstart -k user/<uid>/com.apple.SystemUIServer`,
  which answers 113 (no such service: SystemUIServer is `com.apple.SystemUIServer.agent` in
  `gui/<uid>`), so nothing re-read the list; its bundle clone inserted "$1<name>$2" literally
  (the "unexpected character '$'" line), so P4 d and P7 never had a valid layout. The driver's
  editor ran the same kickstart, which is why every enable read `process_failed` (L52). Probe v5
  decides, in one collector run plus one after a logout: P9 a-d (preferences plus synchronize and
  TIS notification, SystemUIServer, TextInputMenuAgent, cfprefsd, each on its own layout, enabled
  state also read in a fresh process), P8 b (new content in the enabled Ergopti layout in place,
  select away and back), P10 and P8 a (the kept EPProbeKeep layout after the logout; the
  collector runs `after-logout` first when the marker exists). The product follows the
  documented behaviour until then: pending activation at the next login (L52). Probe v5 then
  showed the preference route works at once from a fresh process (L52, tmp/wip-composer-macos26-2):
  the "limitation" was a stale TIS list in the writing process, not macOS.
- **L26** [CODE][PHYS-M] field run 03_field_network: fail (`_164726`); the PAC host is unknown
  off the company network (new.txt 16:48:20). Sub-steps were not captured (L13). Next: read the
  sub-steps in the next report; a PAC that cannot be fetched while direct works must not fail the
  check. The 19:47 run has them: see L41 and L42.
- **L27** [PHYS-M] field run 04_field_toolchain: fail (`_164726`), sub-step unknown; candidates
  are `timer_late_ms` (main-thread hold) and the Shortcuts or Homebrew steps. Next: read the
  sub-steps in the next report. The 19:47 run names it: `karabiner_signature` exit_1, see L43;
  every other step passed (timer late 0 ms).
- **L28** [PHYS-M] field run 06_field_composer: fail, same cause as L25 (now L52: info:pending_logout). 07_key_accounting:
  needs_typing, not a failure: the maintainer types the prompted text on the next run. The 19:47
  run is the same (composer_ready fail:not_enabled; the TIS probe again shows register 0, enable
  0, select -50 and the source still disabled): known limitation, not re-fixed.
- **L32** Partly fixed on tmp/wip-field-run-checklist (cce99afbc7): the shared schema enum lacked
  `missing`, `unavailable` and `not_used`, so the share projection turned a refused Screen Recording
  grant (and a guardian needing approval) into `unknown`. Still open: the resident size breakdown.
  Input Monitoring: done 30 October in code (`fix/macos-overnight-c-2` 28a6dec3, 10bcfeca), the
  launcher role `--input-monitoring status` answers from IOHIDCheckAccess (never prompts) and the
  field run's permissions check reads it; the macOS Build stage must compile and run its XCTest.
  Original entry: issue #104 diagnostics: Input Monitoring, Login Items and Screen Recording read
  `unknown`; memory used 843 MB with 93 MB free. Next: read or label those permissions, and
  measure the 843 MB resident size.
  nil`, has no behavior effect: `executeAndReturnError`returns a non-optional descriptor and
 `error == nil`alone decides, which is the intended check. Next, on a Mac with swiftc: replace it
  by`\* = script.executeAndReturnError(&error)`and`scriptReturned = error == nil`, then fix
main.swift:1290 "will never be executed", OwnedSuspendedImageGuardian.swift:58-59 trailing
closures and RemapLeaseWorker.swift:1297 `var`; the Linux container has no swiftc to compile
  them.
- **L42** [CODE][PHYS-M] 03*field_network on the 19:47 run: `pac_download fail:failed` and
  `pac_script fail:invalid` because the PAC host (http, company intranet name) does not resolve
  off the company network; environmental, the fallback goes direct. Two defects behind the other
  values are fixed on tmp/wip-field-1947b: `route_plan fail:lookup_failed` lost the real stage
  because the port read the route role's stdout while its `STAGE` line is on stderr, so the PAC
  fallback could not apply (5d93e78e90); and the WARNING carried the company PAC URL (1dfaec8298).
  Mac confirms: the next run shows `route_plan info:direct_fallback:<stage>` or a named stage,
  and no URL in "PAC download failed". Next [CODE], once L41 is settled and direct `transfer`
  passes: report `pac_download`/`pac_script` as info when the fallback covers their failure, as
  L26 asks. The 21:06 run confirms the route fix
  (`route_plan info:direct_fallback:native_pac_download`) and a URL-free warning; `pac_download`/`pac_script` still fail off the company network, which is
  the open follow-up above, not a defect of the fixes. The 22:31 run is the same; fixed on
  tmp/wip-field-run-hygiene (ec15345d22): where the driver's PAC fallback covers the stage, the
  check reports `pac_download info:unreachable_direct` (or `http*<n>\_direct`), `pac_script
  skip:not_fetched`(or`info:invalid_direct`), and `transfer` proves the direct path. Only macOS
has that port: Windows strict admission (`ergopti_network_routes.ps1` `pac_failed`) and the
Linux Ollama lookup still refuse an unusable PAC, so their check keeps failing, which matches
what they do; their fallback is the deferred item "PAC unusable: direct fallback". Open on macOS:
`route_lookup pass:selected`in the 22:31 run carried no fallback marker although the route role
saw`native_pac_download`; confirm on the Mac whether the HEAD worker's CFNetwork lookup went
  direct by itself. Done in code 30 October (49020f18, e45e7572): the worker writes a closed
  `# native_http_route kind=`marker per attempt and the check reads`route_lookup pass:selected:direct`  (or`:http`), so the next report answers it; the macOS Build stage must compile it. Mac confirms: off the company network, 03_field_network passes with those
  info values.
- **L43** [PHYS-M] 04_field_toolchain `karabiner_signature fail:exit_1` (19:47 run). Not a
  wrong check: `karabiner_cask info:absent` only means Homebrew did not install it; Karabiner
  16.0.0 is installed from the pqrs package (its services run, karabiner.txt), so the app exists
  and `codesign --verify --deep --strict` refused it. Mac must run
  `codesign --verify --deep --strict --verbose=4 /Applications/Karabiner-Elements.app` and
  `spctl -a -vv` on it. Next
  [CODE]: carry codesign's first stderr cause as a closed token in the step value, so the report
  says why without a manual run. The 21:06 run is unchanged (`exit_1`); not Swift, so the rebuild
  will not clear it. Fixed on tmp/wip-field-run-hygiene (cc172a504d, 58fd867081): the step runs
  `--verbose=4`, logs codesign's bounded diagnostic and carries its first cause, and a new
  `karabiner_gatekeeper` step runs `spctl --assess -vv`. The 22:55 Mac shows the cause: a
  `com.apple.FinderInfo` xattr on the bundle root ("detritus not allowed") while Gatekeeper accepts
  it as Notarized Developer ID from team G43BCU2T37; that case is now `info
strict_only:finder_detritus`, any other cause, team or a rejection still fails. Mac confirms:
  04_field_toolchain passes with those values. The collector's karabiner.txt lines are the
  coordinator's change on dev.
  import`in both. The first child now also calls TISEnableInputSource on the listed source, and
  new fresh children read again after 0.5, 1, 2 and 4 s (window 8 s,`[ui]
  input_source_confirm\*\*`). Mac confirms: the log shows "reads on after N fresh read(s)" and the
check `composer_ready=pass:enabled`; "still reads off after 5 fresh read(s)" means the delay
  is not the difference: then try registering before the write (the probe's order).

### Expected, no defect

- **L35** "Ergopti driver not started in this Hammerspoon" (new.txt 11:19 to 11:21): the stock
  Hammerspoon.app started next to a standalone ErgoptiPlus; the guard kept it inert.
- **L36** "Config migration ... refused (newer)" (new.txt 15:32:19, 15:34:29): an older build met
  a config written by a newer schema and left it untouched. Linked to L20.
- **L37** Lease heartbeat answered after 1.06 s, under its 2.5 s deadline (new.txt 09:59:00): a
  main-thread hold, covered by L16 to L19.
- **L38** "Aggregate cache recovery interrupted after 267 slice(s)" (new.txt 16:28:13): the sliced
  recovery resumes at the next start by design.
- **L39** Ad hoc signing of the developer app loses the Accessibility and other grants on each
  build (`_164726`): known; `tools/build/create_macos_signing_identity.sh` gives a stable
  identity.

## Windows side to do on the PC (from October 25)

Work done on Linux and macOS only; the AHK side is built and run live on the Windows PC.

- [x] **PRIVACY: private hotstring text reaches AI prompts on Windows.** [CODE] Fixed on macOS (private
      expansions now hidden from every prompt) and Linux (separate AI context). Read-only look at Windows:
      `_HSE_MirrorCanonicalEffectToLlm` (`hotstring_dispatch.ahk`) and `_HSE_MirrorLiteralEditToLlm`
      (`hotstring_send.ahk`) copy `Effect.InsertedText` into `_LLM_Bridge_Buffer` and the agent buffer, and the
      Effect objects from `HSE_ApplyExpansion` carry no private flag, so a phone/SSN/IBAN expansion can be sent
      to Ollama or a remote provider. Add `IsPrivate` to those Effects, clear both buffers on a private effect
      and keep appending later typing (as Linux); AHK test: a private expansion then a prediction request
      carries no secret. Do this first on the PC.
- [x] **Hosted Windows unit failures.** [CODE] Run 40235626114 (e2aa642f8c) still fails `meta`,
      `config-scope-features`, `core` and `keymap-gestures` (likely the gesture greying, dbc29c5077);
      `hotstrings-shortcuts` passes since the second round of fixes. `test_hotstrings_scope.ahk:520` (expected 0.5, got 1.0) is
      unexplained: print `_HotstringsOverrides["autocorrection"].Sections[family]` after
      `HotstringsOverridesApplyBase()`.
- [x] **AI off disarms the AI keys and the agent's manual actions.** [CODE] Done on Linux and macOS
      (bc2048765a, 6d96986979). Windows: `AiActionIsAi`/`AiActionBlocked` in `modules/gestures/config.ahk`;
      split `TapHoldTapAction` (`platform/remap/tap_hold_loader.ahk`) so a blocked AI tap returns the native
      tap, configured readers in `menu_taphold.ahk` and `tap_hold_writer.ahk` use the new
      `TapHoldConfiguredTapAction`; per-press gates in `TapKeyShouldFire`, `ScriptShortcutSlotRunsAction`,
      `KeyCombinationOwns`/`KeyCombinationFire`, `GestureDispatch`, `_MagicEditorBrokerWinner`; AI hotkeys
      through `HotkeyRegistrarSetEnabled` from `LLM_Menu_ActivateRuntime` and `_LLM_Menu_ApplyToggleCommitted`;
      `_LLM_Agent_ManualRefusal` passes `LLM_Menu_AiEnabled()`; `requires_ahk = ["ai:on"]` on the two agent
      actions with the codegen token and the picker greying; tests `test_ai_action_gate.ahk`,
      `test_llm_agent.ahk`, `test_llm_agent_requester.ahk`; reseal.
- [x] **One app-category file on the three OS (PAR-34).** [CODE] Windows keeps `app_categories.json` in the
      metrics dir and accepts legacy flat string values the Lua codec refuses, and it preserves unknown
      members the codec drops. Align the location (decision pending), the record shape and the score range,
      and replay `_shared/tests/corpus/metrics/app_category_store_vectors.json` in AHK.
- [x] **AI off disarms the agent's automatic mode.** [CODE] Done on Linux and macOS (e284077ba9). Windows:
      the AHK agent runner arms no typing pause and refuses a triage or request in flight while the AI is
      off, cancels the pause at the switch-off and re-arms on the next keystroke; rewrite
      `test_llm_agent_ai_off.ahk` (it feeds the agent with the AI off on purpose) to assert that.
- [x] **Release notes in the update-check window (PAR-52).** [CODE] `windows/ui/update_check/init.ahk`:
      seed `state.notes = {body, owner, repo}` in the `available` message (from `UPDATER_LATEST_RELEASE.Body`,
      `UPDATER_GH_OWNER`, `UPDATER_GH_REPO`, as `_Updater_ReleaseNotesSeed`), serve `open_url` in the
      `available` phase through the allowlist behind `_Updater_OpenManualUrl`, add `"open_url", "available"` to
      `UC_PAGE_ACTIONS`, then drop `open_url:available` from `luaHostsOnly` in
      `tools/test/test-update-check-dialog.cjs`.

- [ ] **Review the Windows antivirus surface ceilings (27 Oct).** d7d98e133b raised the exe bundle's DllImport
      ceiling in `tools/ci/windows-exe-av-surface.json` from 52 to 54 for the two staged-file custody P/Invokes of
      `vendor/ergopti_updater_download.ps1` (`CreateFileW`, `GetFileInformationByHandle`, from bdfa026d16). Check
      whether a bundled type already declaring them could be reused, then lower it back. The same build log notes
      `key_state_polling` dropped to 59: lower its script ceiling from 62 once a Windows build confirms 59.
- [x] **Windows counterparts of the 26 October work.** [CODE] The Lua side is on dev: - read `[logger] hotpath_slow_ms` in `hotpath_profiler.ahk`; - drop the dead crash kind (`error_dialog/init.ahk`, `ERROR_REPORT_KINDS`, then the shared `KINDS` and the
      `crash_multi_line_without_recent_issues` vector together); - read the 14-colour palette from `native_theme.toml`; - use `dialog.action_picker.requires_ai` for the greyed AI actions; - port `llm/request_plan` (debounce, batching) with its vectors, accept -1 "never", never hold explicit
      requests, read `llm.trigger.min_request_interval_ms` with a menu row, then delete
      `rate_limit_min_interval_ms` from `inference.json`; - `tap_hold.toml` v0→v1 migration (`_shared/tap_hold/migrations.toml`) in the loader and writer, stop
      reading and writing `explicit_delays`; - Quit refusals before `ExitApp` with `notify.quit_refused` (PAR-45); - the registry op that re-encodes a value in `config_migrate.ahk`, then delete the macOS
      `[llm.profiles] user_profiles` reader import.

## Decisions of 2026-10-26 to implement (the maintainer's answers of that day)

- [ ] **Versioned `tap_hold.toml` migrator.** [CODE] Linux done (`_shared/tap_hold/migrations.toml`,
      macOS has no tap_hold.toml); in progress: byte-preserving rewrite (agent AE); Windows side on the PC.
- [x] **Registry op that re-encodes a value.** [CODE] Windows `config_migrate.ahk` first (PC), then the Lua
      engines, then delete the macOS `[llm.profiles] user_profiles` reader import (0146a938c5).

## Big item 1: Windows corporate networks and trust (items 62, 132)

- [ ] **62. WinHTTP transport for the managed remote downloads.** [CODE] Done (1d15b51e66, 7c001b2456
      and the following commits): managed requests, updater artifact download and Ollama archive
      download use WinHTTP (`vendor/ergopti_winhttp_transport.ps1`, worker
      `ergopti_managed_http_worker.ps1`); `curl.exe` stays only for loopback Ollama. Proven on this PC
      against owned loopback services with real SSPI NTLM and Negotiate proxies, CONNECT, untrusted
      TLS, bounds, deadlines and PAC failover. Left: the native CA cases (a click on the Windows
      security warning or an elevated LocalMachine scope), enterprise acceptance behind a real
      proxy/PAC (Kerberos, TLS inspection, revocation) through Debug > diagnostics (`github_api`,
      `proxy_pac`), and item 36 (external trusted binding).
- [ ] **132. SignPath Foundation signing.** [CODE] Apply, integrate Windows signing, then delete
      `.github/ci/stable_windows_signing_exception.json`. Before applying, check the current
      conditions on signpath.org/foundation (open-source license, public repository, build and
      signing from CI with a maintainer approval per signing request, a published code-signing
      policy and privacy statement, a reputable project; the keystats-like metrics module and the
      hooks need a clear explanation). Decided 2026-10-22: apply now. Done: SignPath wired in
      `ci-windows.yml`, off until configured (61fb29d64d); README code signing policy and privacy
      (c6db589c76). Left (maintainer): apply, then set the variables and secrets; eligibility table,
      form answers and switch-on steps in the
      [handoff](docs/tooling/signpath-foundation-application.md).
- [ ] **`ErgoptiPlus.exe` flagged by a corporate proxy (Netskope, Airbus tester).** [CODE] [PHYS-W]
      Done: no hidden PowerShell clipboard stage, own version resource, English metadata, tar.exe
      extraction, the keylogger naming gone (keystats rename; the gate forbids `keylog` in the script
      and the bundle), string-surface ceilings and a per-build record with the exe SHA-256 in CI
      (e2c9dfb79d), the submission pack
      [windows-exe-false-positive-submission-pack.md](docs/tooling/windows-exe-false-positive-submission-pack.md).
      Left (maintainer): signing (132), VirusTotal lookup, Microsoft and vendor submissions, the
      tester's block page and retry (T1-T4); decide whether the `WH_KEYBOARD_LL` probe in
      `input_probe.ahk` stays in the release exe. Playbook:
      [handoff](docs/tooling/windows-exe-flagged-by-proxy.md).

## Big item 2: macOS Karabiner input reliability (items 31, 117, 140)

- [ ] **117/140. Karabiner lease failures on Apple silicon.** [PHYS-M] Exit 73, PONG/READY
      timeouts since dev.155. The lease budgets are ordered so a slow CLI keeps the lease, every
      exit 73 names its cause, each deploy decision is one INFO line (recovery deploys wait for a
      typing pause; an unchanged `karabiner.json` is never republished), and the lookup that froze
      the main thread 13 s is gone (0292ec401d, e57f4cce77). Issue #100: on-time deadlines fired
      while the Ergopti menu was open, because `hs.task` streaming output is read only in the
      default run loop mode; an on-time deadline now waits for a `/bin/cat` echo before judging the
      worker (25411ee080, after v1.0.5). Reproduce on the Mac with these log lines; the only
      workaround is Configuration > Ergopti uses Karabiner > Off. Recovery deploys (28 of 33 on
      2026-10-19) cannot be reduced without fewer lease failures. Leftovers: the starvation
      hypothesis for silent PONG/READY timeouts: done 30 October (`fix/macos-overnight-c`), every lease
      failure logs `Memory free when the Karabiner lease failed (<kind>): N%.` once a minute, and the field
      run's lease check names `lease_failure_kinds` (pong:N, ready:N) and `memory_free_percent`. The late-event
      gate is in every consuming physical tap already: tap keys (`actions/system.lua`), script control and the
      modifier injector call `KeyEventHealth.passes_late_event`, with behavioural tests. Mac action: send the
      field report; a low free percentage next to the PONG/READY kinds confirms starvation.
- [ ] **Dropped letters on macOS.** [PHYS-M] Unproven. Every consumed and never delivered key is
      reported ("typed key(s) swallowed", decisions only, never the key). Since 30 October the field run's
      lease check fails `swallowed_keys` on any such key, so the report proves it without a person. Mac
      action: Debug > Report a bug right when a letter disappears, then compare with lease failures or
      Karabiner deploys.
- [ ] **31. HS-274 exact physical key accounting with an owned Karabiner runtime.** [CODE] Work
      packages WP3-WP10 (production consumer, headless producer v2, reproducible runtime, launchd
      ownership, owned configuration, native and real-Mac acceptance, enable and retire); media keys
      without a macOS keycode; VirtualHIDDevice incompatibility blocks owned mode with an
      explanation. Plan: [ADR 011](static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md).
      Estimate 30-40 agent-days plus hardware time. The owned runtime stays dormant at default
      startup.
      Status 2026-10-24: WP3 largely done and dormant; WP6 Lua owner (`runtime_owner.lua`,
      `runtime_vhid.lua`, read-only ports) and WP7 owned deploy done, dormant behind the hidden
      `[karabiner] runtime = "owned"`; one-click Debug field checks shipped (lease, owned runtime
      dormancy, network, 30 s key accounting). Left: WP5 artifact manifest (hosted macOS run), a
      closer for another running Karabiner, the production capture owner, the Swift lease worker's
      owned CLI path, who starts the Console (Lua or `InstalledPhysicalSourceBridge`: duplicates
      otherwise), `UninstallWorker.swift`, the karabiner_model diff 16.0.0 to 9312593e, WP8-WP10.
      Next: the maintainer sends the `Field check result:` log lines from the Mac.

## Big item 3: Windows input-hook architecture (items 49, 91, 50)

- [ ] **49. Keyboard-hook order.** [PHYS-W] [CODE] AutoHotkey removes and reinstalls its low-level
      hook around SendInput, so hook order is undefined. Record the real order before and after a
      SendInput rehook; audit terminal capture against KLE, dead-key, digit, profile, tap-hold,
      combination and script-shortcut consumers (down, repeat, up, owner change while held, pause,
      reload); finish event-specific capture and replay and modifier ownership (source pin,
      authenticated event stream, non-hook handler conversion, chained/repeat semantics). Regenerate
      the DLL and manifest only through the official MSVC generator (the four pending patches of the
      12 October consolidation were found already in the tree on 2026-10-23).
      Measured on the maintainer's PC (Debug > Record keyboard hook order, 2026-10-24): before a
      SendInput the test hook is first; after it the AutoHotkey hook is first, so SendInput does
      reinstall the AutoHotkey hook in front of any hook installed earlier. SendEvent does not
      (item 50: hotstring output already uses SendInput at level 0, so it is exposed to this rehook). Consumers that rely on their own hook staying ahead of AutoHotkey's (the
      native nav owner DLL, item 91) lose that position at the first SendInput of the other paths.
      Consumer audit:
      [windows-input-hooks.md](docs/design/windows-input-hooks.md). Left:
      decide per remaining SendInput consumer (text sender, HSE dispatch) whether it can avoid
      SendInput or make the consumer order-independent (single-hook/RawInput source, needs an MSVC
      DLL and manifest); the terminal-capture hardware list; the `SetWindowsHookExW` string in the
      exe for antivirus (the AV-surface gate allows it).
- [ ] **91. Simultaneous and first-key hold arbitration.** [CODE] Integrate with the
      single-hook/RawInput source (needs a genuine MSVC DLL and manifest pair); [PHYS-W]
      held-alone-then-joined order, AltGr hook provenance.
- [ ] **50. SendEvent against SendInput.** [PHYS-W] `SendMode("Event")` is set, yet the hotstring
      send/dispatch, text sender and config I/O still call SendInput. Measure expansions, pastes and
      predictions (latency, lost or interleaved keys) before choosing.
      Measured on the maintainer's PC (8 repetitions per scenario, all exact, 0 lost, 0 interleaved in
      both modes): expansion median 50.6 ms (SendInput) vs 136.8 ms (SendEvent), prediction 56.1 vs
      191.0 ms, paste 3.6 vs 3.8 ms, a concurrent key during the send 201 vs 282 ms. \*\*Finding
      (2026-10-24, real engine on the maintainer's PC): hotstring expansion already used SendInput
      (`HSE_DispatchMatch`); there are no native `Hotstring()` registrations left, so a hotstring's
      output is final on every driver and does not trigger another hotstring (the comment on
      `SendMode("Event")` described the retired native engine; `SendMode` now only affects `Send`,
      `Click`, `MouseMove`). One real bug fixed (0c85debc93): the Space tap-hold completed a trigger
      from its level-2 thread, and with another AutoHotkey hook SendInput fell back to SendEvent, so
      the burst re-entered the watcher and cascaded (final text `foo qbar qzz` instead of
      `foo qzy `); all engine output now goes at level 0. Deliberate cascading is built (858c9aa, 0746b18c86):
      `hotstrings.cascade_max_arrows` counts arrows (1 = one expansion, 2 = a > b > c), default 3,
      range 1 to 10, the whole chain resolved before one send (one SendInput burst on Windows), a rule
      fires once per chain, a link fires only where typing the same text would; the typed delimiter
      lands once after the final output unless the user marked it consumed (★ ships consumed).
      Space tap completes an end-character trigger like a plain space on the three drivers (Windows
      already via `TextPressKeyFed`, Linux pinned by 504ee63, macOS emits a native space).
      `test_hotstring_output_is_final.ahk` is already in `run_all.ahk`. Left: on each OS type `fb` + Space,
      Enter and ★ with the abbreviation and brand packs, at 1, 2 and 3 arrows, consumed and not.
- [ ] **Per-layer layout composer.** [CODE] Done on the three OS (docs/design/layout-composer.md): shared
      model, page, 21 locales, Windows host, macOS and Linux install paths, tests, one-click Debug
      "Test the composed layout". Left: typing the composed layout on a real keyboard on each OS.

## Wave 2: mid-size work

- [ ] **Windows config policy (items 33, 42) and the TOML parse cost.** [CODE] Done: the Windows
      keyboard binding publication (ef238c2758), the macOS Karabiner obsolete-leaf intent
      (54a537b724), the Windows retired cleanup projections (300790cb37), the Linux `--config FILE.toml`
      watcher (3dd420292d), per-row admission of outdated API providers on Windows. Left: native macOS
      qualification of the Hotstrings category boot publication and of the obsolete-leaf setters; the
      Windows cleanup still cannot offer bare root keys or unknown `[[x]]` generations; the Linux
      symlink watcher case under a real luaposix `posix.stat`. Parse cost: every document-mode write
      parses source, expected model and final candidate, and every start pays two builds after
      ready; reuse one parse per transaction before adding any cache.

Not started:

- [ ] **Ollama redirect policy and Go compile (decision 5).** [CODE] [CI] Code done (cda1e10c5e): an
      unresolved download host is left to the proxy or the native worker; private, loopback,
      link-local and CGNAT addresses and names resolving to them stay refused; the build recipe
      patches upstream `ValidateRedirectTarget`. The hosted Go cell (`go vet`, `go test` through
      `build-macos-managed-ollama.py`) passed on a throwaway branch (run 40021624397). Left: the same
      cell on the final source before a release.
- [ ] **Ergopti-started Ollama behind a PAC proxy.** [CODE] Linux done (89d22d782c, fake-lookup
      tests). macOS in code (launcher role `--managed-proxy-route`, 06addb2e3f; per-origin route
      plan 1fd254d92e and 749e00c4c8); Swift compiled and tested on the hosted macOS cell. Windows
      is covered by the WinHTTP transport (62). Left: a real-PAC pull on the maintainer's Mac (Debug >
      Test network). The network check already has its `route_plan` step (shared
      `field_check_network.lua`); the blob host inventory check is the field-run step
      `field_ollama_blob_host` since 30 October (`blob_host` fails `unplanned_host` when the registry
      redirects a blob to a host `route_origins.json` does not plan).
      The daemon start now looks up every inventory origin (it read only the single-origin variable,
      so `pac_probe_client = "ollama"` never resolved at start; fixed with the fallback below).
      Windows (30 Oct): the launcher looks up both `route_origins.json` "ollama" origins natively and starts the daemon with HTTPS_PROXY/NO_PROXY from the shared route plan (57276199); a relay demanding a Windows login is never exported and the pull refuses with a named reason, the start stays (local models offline). Left: [PHYS-W] a pull behind a PAC; maintainer decision: an option for NTLM relays (a local authenticating forwarder, or none).
- [ ] **PAC unusable: direct fallback (maintainer decision).** [CODE] [PHYS-M] macOS done on branch
      `tmp/wip-pac-fallback`: when the PAC or WPAD route lookup fails at a stage listed in
      `proxy_policy.json` `pac_unavailable_fallback` (PAC download, evaluation, WPAD discovery, lookup
      budget, empty route), `network-retry.sh`, the Swift spool and native worker, and the Python
      receiver go direct (no relay, loopback exclusions kept) with one WARNING naming the stage, then
      log that the direct connection worked or an error naming both causes; the Ollama pull shows
      `network.failure.pac_unreachable_direct_failed`; the Debug network check reports the lookup as
      `info direct_pac_download` (or the stage met). Decision: an explicit inherited relay
      (`HTTPS_PROXY` and the others) wins and never falls back; a relay the PAC names that then fails
      is NOT retried direct (only the PAC's own list, such as `PROXY a; DIRECT`, is followed), on
      every OS. Mac must confirm: on the company network, an Ollama pull and the MLX install log the
      WARNING with `native_pac_download` or `native_pac_evaluation`, then the direct success line (or
      the two-cause error), Debug > Test network shows the `route_lookup` info step, and the Swift
      change compiles in the macOS cell. Linux follows it for the Ollama daemon start (fe9199b9, 838af0c0:
      the shared policy's `falls_back_direct` read by `managed_ollama_proxy.lua`): a GIO lookup that
      fails or times out sends that origin direct with a WARNING naming `native_proxy_lookup` or
      `native_proxy_budget`; a pull that daemon then fails to fetch shows
      `network.failure.pac_unreachable_direct_failed` and logs the stage (`pac-direct-fallback-pull`).
      Linux left: GIO names no finer stage than the lookup, and the daemon holds one relay, so a PAC list such as
      `PROXY a; DIRECT` keeps only its first entry (following it needs a reachability probe of `a`
      before the daemon starts, a new network behaviour to decide); [PHYS-L] a pull on a PAC-only network whose PAC is
      unreachable. Deferred: Windows (`ergopti_network_routes.ps1` still refuses with `pac_failed` or
      `wpad_failed`) must follow the same policy.
      Windows (30 Oct): no longer deferred, `ergopti_network_routes.ps1` `New-ErgoptiPacDirectFallback` goes direct at the policy's stages; [PHYS-W] confirm on a network whose PAC is unreachable.
- [ ] **AppImage self-contained.** [CODE] `.zsync` and update information are done (10c016e51f,
      6fb83014e3). Built on ubuntu:22.04 (glibc 2.35 floor, no bundled libc or loader, musl refused in words,
      tray closure kept); the build refuses a foreign loader or a staged C library (dce846a0bd). Left: hosted
      CI evidence of the Build and `install-linux` AppImage rows on the distro matrix.
- [ ] **Linux X11 window list.** [CODE] `getAll()` is covered by the Openbox receipts (962a25a973),
      run on Xvfb and Openbox in a Linux container on 30 October: `x11_window_list_names_owned_clients`
      lists the three owned clients and all 34 native window receipts pass. Left: the first hosted
      run; Flatpak: wmctrl is only a documented host program.

## Cross-OS parity, centralisation and constants (audit of 2026-10-24)

Maintainer rule: the same behaviour on Windows, macOS and Linux wherever possible, unless there is a
good reason stated in the menu reason text; everything that can be common lives in `_shared`
(hexagonal architecture: rules and ports in `_shared`, OS code only in adapters); every constant,
delay, colour and label has one declaration. Source: the cross-OS parity audit of 2026-10-24, in Git
at 49c62d77a1 (`docs/audits/2026-10-24-cross-os-parity.md`; row ids `H1`, `R3`, `L6`, ... refer to
it, and "audit test item N" to `docs/audits/2026-10-18-test-parity-audit.md` there); entries are
`PAR-1` to `PAR-85`, stable ids. Rows tagged I in the
audit come from grep counts: confirm them before starting. Done and verified: about 35 entries (see git log); the list below is what remains. Decisions taken: PAR-7 shared multiplier, PAR-17 identical defaults with stated exceptions, PAR-19 implement on Windows and Linux.

### A. Behaviour that differs without a good reason (fix first)

- [ ] **Tests write the real user config.** [CODE] Fixed (the magic-key catalogue test, and both Lua
      runners now move a real HOME to a scratch dir, `_shared/lua/test/runner_home.lua`). The keystats
      tests own their HOME fixture (29b7c5a0fe). Left: on Lua 5.4 an `io.popen` child still sees the real
      HOME.
- [ ] **Reasoning off in every AI request: verify the open rules.** [CODE] [CI] Done on the three OS
      (branch `fix/llm-thinking-off`): model families in `_shared/modules/llm/thinking_off.json` (intent and
      control kind per family, matched on the normalized model id) crossed with each provider's
      `thinking_dialect` in `api_providers.json`, resolved by `_shared/lua/llm/thinking_off.lua` and its AHK
      port `_shared/modules/llm/thinking_off.ahk`, pinned by `thinking_off_vectors.json`; applied to
      predictions, the Test-API probe, translation, tone, the screen reading and the agent. An HTTP 400 naming
      an added field is retried once without it (WARN) and remembered for that provider and model. Ollama
      bodies send `think:false`; local servers keep their `request_fields`. The refusals persist across
      restarts (macOS settings, Linux state file, Windows state store; 200 pairs at most) and expire after
      `refusal_expiry_days` (thinking_off.json) so a later provider fix is picked up, a cancelled
      Windows prediction also cancels its retry, and the families that accept only the default sampling
      (Claude Opus 4.7+, Sonnet 5/5.5, Haiku 5.5, Fable, Mythos) are sent no temperature. Left: (1) no
      capability discovery (OpenRouter `/models` `supported_parameters`, Anthropic Models API
      `capabilities`, Gemini `models.list` `thinking`): it needs a per-provider listing fetch and cache
      before each request, while the persisted refusal already makes a wrong guess cost one request;
      (2) Ollama gpt-oss ignores `think:false` (it wants a level such as `low`) and every Ollama builder
      writes `false`; (3) unverified families: `grok-3-mini`, `hermes-4`, the generic name heuristic
      (`*qwen3*`, `*deepseek*`, `*-r1*`, `*think*`, `*reasoning*`), Together/Kimi effort, Fireworks
      DeepSeek (read from a search summary), OpenAI `gpt-5-mini`/`gpt-5-nano`, Gemini 2.5 Flash
      image/TTS/audio.
      The AHK suite and parse of this change must run in hosted Windows CI (no AutoHotkey in the cloud
      container).
- [x] **Retire the orphaned Windows gesture-notice entries.** [CODE] The gesture status submenu and notice
      are gone (dbc29c5077); the `gesture_conflict_dismissed.*` storage entries they wrote stay in user
      state. Remove them in a config migration.
- [ ] **Review the machine translations of October 25.** [I18N] New keys (gesture recommendation notes,
      cascade depth, tap-hold defaults, missing-program messages) are hand-written in French and
      machine-written in the 19 other locales.
- [ ] **PAR-6. Make the base expansion delay user-settable on all three.** [CODE] Done (a737049): the
      base is user-settable everywhere, section delays are stored as `delay_offset` or `delay_unlimited`,
      old absolute values migrate keeping the effective delay, shared vectors `base_delay_vectors.json`.
      Left: run the Windows corpus test on the PC.
- [x] **PAR-8. Word delimiters in config leaves on Windows.** [CODE] Done: the consume choice is the
      leaf `[hotstrings.terminator_consume]` on macOS and Linux (76716e7); Windows writes built-in states
      through the live config writer and moves the old override strings at boot (2d734b6); macOS and
      Linux end a word on a user delimiter when deciding a repeat, as Windows does (1748df6: Linux
      `repeat_key.lua`, the only decision site, and the macOS expander, each with a regression test).
      Left: run the rewritten AHK tests on the PC (never executed); no menu toggle for built-in
      consumption on any driver.
- [ ] **PAR-12. Token streaming reason.** [CODE] Done: reason text rewritten in 21 locales and the key renamed
      `token_streaming_unvalidated_on_windows`. Left [PC]: enable the row on Windows after a live Ollama check.
- [ ] **PAR-14. Check-only fallback when the GitHub API is blocked: Windows.** [CODE] Linux and shared
      pieces done (28bdd5a5d9, vectors `check_only_vectors.json` and `list_cache_vectors.json`). Windows
      needs the Atom fallback in `core.ahk` plus an AHK feed parser, then a reseal of the sealed updater
      sources (only when `run_all.ahk` has no foreign hunk).
      Windows (30 Oct): the Atom fallback and its parser are on dev (`core.ahk`, `test_updater_check_only_fallback.ahk`); [PHYS-W] a check with api.github.com blocked.
- [ ] **PAR-15. Tap-hold thresholds.** [CODE] Done: exact per-key thresholds pinned, one one-shot timeout
      (macOS read 3000 against 2000 ms), Linux holds the key's own side. macOS reads the shared per-key
      thresholds too (8cb8f04); one fallback `default_activation_ms = 200` (macOS was 250). Left: Windows
      still holds a 0.2 literal pinned to it by a gate; check the Karabiner JSON on a Mac.

### B. Missing features on one OS

- [ ] **PAR-30. Sign the Windows and Linux update assets.** [CODE] [CI] Done: ECDSA P-256 detached signatures
      over a record of asset name, size and SHA-256, signer and reference verifier
      (`tools/build/update-asset-signature.cjs`), Linux verifies with OpenSSL, Windows with CNG, shared
      vectors, CI signs the Windows exe and publishes the `.sig`. Linux transfer flow done (cd824ccf8e:
      `signature_gate.lua` fetches the `.sig` and verifies after adoption; no separate "warn" value, a bad
      signature is logged in words while enforcement is "off"); macOS needs nothing beyond Sparkle's EdDSA
      and the release-installer SHA-256 plus designated requirement. Left: the Windows `release_install`/`self_update` path (enforcement `"off"` until
      the maintainer provisions the key: five steps in `docs/tooling/update-signing.md`), then flip it to
      `"required"`.

### C. UI-only gaps, reasons and docs

- [ ] **PAR-41. One shortcut data model.** [CODE] Design note written
      (`docs/design/one-shortcut-model.md`, 4ca41ed2e9): one action slot per chord with neutral role-based ids.
      Done on macOS and Linux (sixth integration batch): schema v15 `v14_to_v15` migration of the slots and
      Ctrl-letter switches, role table with per-driver families, manifest slots, both drivers adopt the role
      names, migrated-config binding proof, AHK fixtures pinned to v15, per-slot parameters carried by
      `rename_prefix`. Left: the Windows adoption, macOS `ctrl_g` to `open_url` later.
- [x] **PAR-45. Notifications: one behaviour for toggles and refusals.** [CODE] Done on macOS and Linux
      (shared `feature_notice.lua`, Linux quit refusal). Left: Windows `NotifyFeature(label, enabled)` around
      `NotifierSend` at the same call sites, and a Windows quit-refusal path firing `notify.quit_refused`.
- [ ] **PAR-52. Release notes on macOS and Linux update windows.** [CODE] Done on macOS and Linux
      (80a5a650a6): shared `release_notes/pane.js` in the `update_check` page, repository-only links. Left:
      the Windows host (section "Windows side"), a visual check on a Mac and a Linux desktop.

### D. Instrumentation and diagnostics

- [ ] **PAR-53. Bring HotPath-style slow-segment logging to macOS and Linux.** [CODE] Done (shared
      `hotpath_segments.lua`, always-on Linux spans, one warning per segment per 10 s, and nesting
      attribution: a segment is judged on its own time and reported with its enclosing segment,
      `hotpath_nesting_vectors.json` replayed on macOS and Linux). Left: Windows prints the exclusive
      time but still judges and reports on the wall clock (`_HotPathNestedMs`); the threshold question.
- [x] **PAR-54. PhaseStats and child-process timing.** [CODE] Done on macOS and Linux (`process.<program>`,
      `toml.parse`, `menu.rebuild`, `boot.stage`, `boot.stage_cpu`). Windows: port `phase_stats_core.lua` with
      the same phases (`boot_profiler.ahk` already measures stages).
- [x] **PAR-55. Crash reports: one content, one cap, one notice.** [CODE] Done on macOS and Linux (shared
      `crash_report.lua`, vectors `diagnostics/crash_report_vectors.json`, 20 newest kept). Left: Windows
      `crash_report_worker.ahk` adopting the same fields, names and cap.
- [ ] **PAR-56. Log-volume metrics on all three drivers.** [CODE] Done on macOS and Linux (per-level,
      dropped, suppressed and collapsed counts in the shared logger core, on the interval evidence record).
      Left: Windows `_LoggerEmit` counting the same seven figures in the same order.
- [x] **PAR-57. Retention read from timings on Windows.** [CODE] `logger.ahk:112` is a literal 14. Read
      `Timings` and extend `test-logger-scalars-single-source.cjs`. Audit G5.

### E. Tests and corpora

- [ ] **PAR-58. Windows consumer for the shared Lua contracts.** [CODE] 105 contracts (about 940 cases)
      run on macOS and Linux, none on Windows. Convert the highest-value ones (`config_scope_*`,
      `toml_*`, `menu_*`) to JSON vectors and replay from one AHK consumer per family. Audit test
      item 11, section 14. Lua side done: 302 JSON vectors replayed by both drivers; the ledger
      (`tools/test/test-contract-vector-ledger.cjs`) classifies 288 Lua sites, 13 data-driven and 275 kept in
      Lua with a reason code. Left [PC]: the AHK consumers per family.
- [ ] **PAR-59. Corpus replay gaps.** [CODE] Done on macOS and Linux (file warnings, route plan, GET
      redirects, document lease; the download-document contract is Linux-only by design). Left: Windows
      consumers of `http/get_redirect_vectors.json`, `native_presentations/original_captions.json`,
      `route_plan_vectors.json`.
      Windows (30 Oct): `get_redirect_vectors` (`test_corpus_updater_redirect.ahk`) and `original_captions` (`test_window_title_captions.ahk`) were already replayed; `route_plan_vectors.json` is now replayed by the PowerShell twin `vendor/ergopti_route_plan.ps1` (`test-windows-route-plan.cjs`).
- [x] **PAR-60. Hotstring `family_samples.json` plus chaining, synthetic-output and erase vectors.** [CODE]
      Done on macOS and Linux (`family_samples.json`, `sequence_vectors.json`, `cascade_vectors.json` in both
      E2E harnesses). Left: a Windows `family_samples` consumer.
- [x] **PAR-61. Tap-versus-hold decision corpus.** [CODE] Done on macOS and Linux (`decision_vectors.json`,
      23 vectors, shared contract). Left: a Windows consumer through its tap-hold engine.
- [ ] **PAR-63. Remaining 2026-10-18 test items.** [CODE] Done on Linux and macOS (personal-info editor,
      field masking, native-only number row; model records, downloads, keystats corpus and the toggle gaps
      were already covered). Left: Windows dynamic hotstrings, Windows root runners and the
      `test-driver-tree-parity.cjs:19` exclusion.
- [x] **PAR-64. Installed-record and layout corpora on Windows.** [CODE] Windows replays 1 of 4 files.
      Replay extensions, preservation and updates. Audit L6.

### F. Centralisation and hexagonal architecture (value order)

- [x] **PAR-65. Extract the LLM request plan to `_shared/lua/llm/request_plan`.** [CODE] Phase 1 done on macOS
      and Linux: `debounce.lua` and `batching.lua` with request-transcript vectors (`_shared/tests/corpus/llm/`)
      replayed by both drivers (48be669def, 7442ab5edd, d18f573791; the decisions of October 26 are on
      `work/todo-af`). Left: the Windows twin replaying the vectors, then the HttpClient, TimerScheduler and
      TooltipRenderer ports, the live prompt, the token budget, the info-bar text and the agent flows. Audit R1.
      Checked 30 October: on macOS and Linux those are done, `_shared/lua/llm/request_plan/` holds `ports`,
      `token_budget`, `live`, `info_bar` and `agent`, required by both prediction engines, the remote and MLX
      clients and the agent runner; only the Windows twin is left [PC].
- [ ] **PAR-67. Shared keystats query catalogue and walker.** [CODE] Reader catalogue, shared walker and
      aggregation vectors done; `meta.rev` shared and a gate refuses SQL spelled by hand in both Lua drivers.
      In progress: write-statement catalogue with typed slots (agent). Windows: adopt it later.
- [x] **PAR-68. Hotstring override parser into `_shared` on `toml_codec`.** [CODE] Done on macOS and Linux
      (shared `hotstrings/overrides.lua`, `override_parse_vectors.json`). macOS now reads a duplicate key or
      header as invalid TOML (was last-wins). Left: Windows `_ParseOverrides` replaying the vectors.
- [ ] **PAR-71. Finish the route-plan rollout and make `proxy_policy.json` the codegen source.** [CODE] Done on
      macOS and Linux (generated shell and Lua precedence, Linux lookup limits from the policy, drift guard).
      Left, Windows: generated or read AHK copy in `http_client.ahk` (reseal), the route-plan consumer
      replaying `route_plan_vectors.json`, the native lookup limits from the policy.
      Windows (30 Oct): `http_client.ahk` reads the curl relay names from `proxy_policy.json` (its ratchet entry removed); route plan ported (`vendor/ergopti_route_plan.ps1`). Left: wire it into the owned Ollama daemon start and pull (`ollama-runtime-launch.ps1`, `ollama-model-pull.ps1`; decide what an SSPI-only relay exports), the native lookup limits from the policy; [PHYS-W] a pull behind a PAC.
      Windows (30 Oct, later): the route plan is wired into the owned daemon start (57276199); the healthcheck PAC limit reads the policy (1255b8b6). Left: [PHYS-W] a pull behind a PAC, and the maintainer's decision on an NTLM/Negotiate relay option (today such a relay is never exported and the pull refuses with `network.failure.proxy_windows_login`).
- [ ] **PAR-72. Shared registries and catalogues.** [CODE] Done: layout registry store, shortcuts
      catalogue, healthcheck report runner, agent learning store (daee88e48d..e105336d39); gesture
      direction and temperature were already shared with vectors. Left: the registry install/select flows and
      the healthcheck bridge stay per driver (different converters and bridges).
- [ ] **PAR-73. Collapse generated per-driver artifacts and tap-hold timeout duplicates.** [CODE] Done:
      `[hs_timeouts]`, `action_catalogue.lua`, and `features_manifest.lua` (one shared
      `_shared/lua/features/manifest_data.lua`, eae6f45708). Left: `config_template.toml` (decision pending).
- [ ] **PAR-74. Config-key and command-id constants by codegen.** [CODE] Generate constants from
      `config.schema.json` and `menu_manifest.json` for AHK, Lua and JS; lint raw literals such as
      `private_filter_enabled`. Audit R10. Lua and shared Lua done (567 sites to 0); JS and Node tools done
      (83 sites to 0, the ratchet now scans `tools/`, CommonJS `tools/lib/_generated/config_keys.cjs`). Left
      [PC]: 1243 AHK literals in the shrink-only `config-key-literal-baseline.json` (read
      `windows/_generated/config_keys.ahk`).
- [ ] **PAR-76. Long refactors, plan before starting.** [CODE] Generate the AHK config-migration op table
      from `migrations.toml` (R17); extract menu row-ordering rules to data (R18); pure hotstring
      injection plan (R26); FileSystem port spec for lease/atomic write (R33); canonical `.keylayout`
      parser (R23); Windows updater `check_session`/`rate_limit` vectors (R25). Done on macOS and Linux: R18
      (`_shared/modules/menu/row_order.json`, generated `row_order_data.lua`, single-source gate), R33
      (`_shared/lua/file_system/ports.lua`, both owners checked at load), R23 (`layouts/keylayout.lua` the
      only reader, gate), R26 (`hotstring_engine/injection_plan.lua`, both engines, 18 vectors, no driver
      divergence). Left [PC]: R17, R25, and the AHK readers of R18, R23, R26 and R33.

### G. Constants, delays, colours, labels (value order)

- [ ] **PAR-79. Replace repeated timer literals with registry keys.** [CODE] Done on Lua and JS
      (ed257e285a): registry keys for the repeated delays, the literal gate in `test-fast-timer-inventory.cjs`
      with a shrink-only `timer-literal-baseline.json`. Left: 139 AHK sites (`STALE_TEMP_MS` x5, gesture poll
      `-100` x6, safety flush `-2000` x3...), ~25 Swift `usleep`, 40 baselined Lua/JS sites.
- [ ] **PAR-80. `[limits]` section for byte caps.** [CODE] Done (7376321788): `[limits]` with the process
      output, declaration file and changelog caps, a retyping gate with a shrink-only baseline. Left: the AHK
      caps, `MAX_TEXT_BYTES` and `MAX_BODY_BYTES` (public module fields).
- [ ] **PAR-81. Theme tokens and palette codegen.** [CODE] Done: `_shared/ui/theme.css` linked by the
      shared pages; `_shared/data/native_theme.toml` generating `_shared/lua/native_theme_data.lua` for the macOS
      and Linux palettes; the dead macOS download-window page removed; hex lint with a shrink-only baseline
      (`tools/lint/hex-literal-baseline.json`, 53 files). Left: an AHK emitter replacing the typed palette in
      `hcw_helpers.ahk` (then retire `test-color-presets-parity.cjs`), and moving the baselined literals onto
      tokens with per-page pixel diffs.
- [ ] **PAR-82. Hard-coded UI string gate.** [CODE] New `tools/test/test-no-hardcoded-ui-strings.cjs`
      (TrayTip, MsgBox, alert, title literals fail unless allowlisted; reuse
      `tools/lint/audit-gui-titles.cjs`), including the Linux `install.sh` echo table. Audit K6, I9.
- [ ] **PAR-83. Identifiers and hosts in one file.** [CODE] Done for Lua (948ebef074, bb1899206e):
      `_shared/data/identifiers.json` generating `_shared/lua/identifiers.lua`, typed copies held to a
      shrink-only baseline. Left: an AHK emitter and the AHK, Swift, shell, Python and JS-page copies.

## Backlog (one line each)

- [x] **Windows field reports: confirm the scrubber covers the AHK log.** [CODE] Checked 2026-10-30: of the 45
      AHK logger calls whose arguments carry a text-like name, every one that logs typed or model text has a
      case in `test-field-log-scrub.cjs`; the others log key names (nav-layer payloads), counts, menu titles
      or error messages. Linux is done: since
      432c934 its collector copies logs only through `tools/dev/field-log-scrub.py` and pushes
      `hotstring-collisions.py` instead of the personal file, and the commit "scrub the Linux expansion
      trace from field reports" added the one Linux spelling it missed (the injector's
      `inject(): bc=N text='…'` trace, written by default). The Windows collector routes its copies
      through the same scrubber (`Copy-ScrubbedLog`, 432c934); check that every AHK line carrying typed
      text has a template case in `tools/test/test-field-log-scrub.cjs`.

- [ ] **Windows: a personal immediate `sru` -> `SRU` (priority 100) loses to the bundled `sru` -> `sur`.**
      [CODE] [PHYS-W] Field report of 2026-10-30, section « metiers », whole word, not case-sensitive, final
      result. The same entry wins on macOS. Static reading of the Windows path (priority 100 accepted, both
      specs in `HSE_StarByTriggerCI`, `_HSE_Beats` by priority, no native registration) found no cause: get the
      user's version, a diagnostic report right after typing `sru`, and the entry's line in
      `personal_hotstrings.toml`. Since then the bundled `sru` waits for a terminator, which hides the symptom.

- [ ] **macOS cold official-Ollama lane.** [CI] since bc09e4584c no product path calls the stock
      `ollama_deps_checker.install_for_selection()` (selection goes through `install_native_for_selection`,
      `runtime_install_offer.lua`), so the macOS "official cold Ollama without stock Python" lane only proves
      the official installer still works cold. Repoint it at the native install or retire it.

Maintainer requests of 2026-10-30 (Windows, macOS and Linux each):

- [ ] **AI menu: a button to test a prediction.** [CODE] It runs one prediction on a sample context with the
      active backend and shows the result or the refusal reason.
- [ ] **"Create a GitHub issue" button is broken.** [CODE] It opens a GitHub page saying "Whoops, something
      went wrong". Check the generated `issues/new` URL (length limit, query encoding, template or label
      names) and fix it on the three OS. Checked on 2026-10-30 from the cloud container: every prefilled id
      (version, os, driver, diagnostics) is a field of `bug_report.yml`, and the Lua builder measures its
      budget on the percent-encoded URL. The prime suspect is `max_url_bytes` = 7000 in
      `_shared/modules/diagnostics/issue_templates.json` being above what GitHub accepts for a signed-in
      issue form. The container's proxy blocks the signed-in page, so reproduce it from a browser: copy the
      URL the button opens, note its length, and retry with the diagnostics value shortened.

Added October 22 (from the agents' reports; details in their commits):

- [ ] **macOS swallowed-keys check on v1.0.6.** [PHYS-M] The fixes (03a2c2fa4b, d026f3e024,
      a414e83fb7, 19fa9fa872, 89cbcae90b, 9b500a9e8c, c21e920d7e, bb6fcc2cc2) shipped in v1.0.6;
      they need a Mac day of typing with the `key_event_health` counters (`infra/key_event_health.lua`,
      written to the driver log). _Hands:_ the day of typing. Once typed, the field run's
      `diagnostics` step carries the `key_*` counters and `field_event_taps` the late keys of the
      session, so no reading by hand is left.
- [ ] **Keystats rename leftovers.** [CODE] The rename is done (180a53e4de, 1 283 files, 579 paths). Left:
      the comment in `macos/apps/Encryptor.app/Contents/Resources/Scripts/main.scpt` (a compiled
      script: recompile on a Mac); declare each persisted name once and make tests read it instead
      of pinning spellings, so the next rename is cheap.
- [ ] **Issue #101: Mac follow-ups.** [PHYS-M] Fixed, to confirm on the Mac with the next release:
      ATS key so the URLSession can fetch an `http://` company PAC (c0c29cd8ab); direct route when the
      PAC lookup names no route (719c7fcd76); no retry of a refused route (ace928dc1c); the lookup now
      names its failing step (363a63f79d: `native_proxy_budget`, `native_pac_download`, ...); lease
      line cap judged per line (5deb892d58); Ollama 412 upgrade request shown (08aaeaf3c2);
      diagnostics PAC probe on the three OS (f798aae1f9); one-click Debug checks (lease, owned
      runtime, network, 30 s key accounting). Left: (1) read the Mac's next log lines `Slow ingest
tick`, `Slow preferences save` and `Field check result:` to name the dominant main-thread
      phase before slicing it; (2) an explicit proxy override field; (3) local server probes (oMLX,
      Jan) all answer "Network request failed"; (4) `keymap/utils.lua` ignored-window TTL probe
      (1 s): bound it only after measuring the AX call time (secure-field cache); (5) rebuild the
      inverse oracle of `macos_native_http_receiving_facts_test` (red since 719c7fcd76), compile the
      Swift on macOS CI, add Go table cases for the new stages; (6) the network check's digest step
      is skipped (HEAD only); (7) PAC fetch/evaluation failures now fall back to a direct connection on
      macOS (item "PAC unusable: direct fallback"): confirm on the Mac.
      Field run (branch `fix/macos-overnight-d`): (1) is `field_slow_lines` (the segment the day's
      `Slow <segment>` lines charge most, the slow ingest ticks and preferences saves with their worst
      duration); (3) is `field_local_servers` (each server's answer and port source); the PAC route of (7)
      shows in `field_network`'s route steps, but a PAC that fails on purpose needs a PAC the maintainer
      breaks. (2), (4), (5), (6) are code.
- [ ] **macOS input follow-ups (swallowed keys).** [CODE] Done: late keys pass through (ed2d9fe65c),
      AXValue read once per burst (34765cde7c), no error window for a lease failure that recovered
      within 60 s (fcf4af85dc), `key_*` counters in the diagnostics (6f2daed2e5). Lease token reuse
      was analysed and refused (ADR 012): a reused token could never reach READY because the
      revocation tombstone is monotone; reuse needs a native acknowledged rearm, decided NOT to
      build for now. The next Mac log carries `Lease token decision=` and `written in N ms`, and since
      30 October the field run's lease check names `deploy_write_ms` and `deploy_kb`: if the write is
      short, keep it; if long, shrink the 743 KB file instead.
- [ ] **Linux correction parity remainders.** [CODE] Done (06bbbe5985): Backspace pops the word, erased
      n-grams get `e`, synthetic output chains. Erased and synthetic vectors in the shared corpus, replayed on
      macOS and Linux (ee2eab6b1e, `keystats/correction_erased_vectors.json`). Left [PC]: the AHK replayer
      (`KLW_WalkTypingEntry`); Windows word separators are wider than Linux's three.
- [ ] **Developer mode on the three OS (maintainer decision, 27 October).** [CODE] [PHYS-M] [PHYS-W] Each app
      runs the clone with the built app's helpers, config and AI runtimes, reloads a saved source file, and
      starts with one command; the updater, uninstall and remote layout catalogue stay off in a source run.
      Inventory per feature: `docs/design/developer-mode.md`. Commands: macOS `bash tools/dev/run-macos-dev-app.sh`
      (done: guardian 6f667b3380, network receiver c0e3359a19); Linux `bash tools/dev/run-linux-dev.sh` (done in
      branch `tmp/wip-devmode3`: Reload relays the runner, a saved driver or `_shared/lua` `.lua` restarts the
      daemon, the native archive backend is built into the clone); Windows `tools\dev\run-windows-dev.ps1`,
      run with `powershell -ExecutionPolicy Bypass -File` (same branch: `infra/dev_source.ahk` reloads on a saved
      `.ahk`, the run reads `%APPDATA%\Ergopti\paths.toml` like the exe). Left: (1) [PHYS-W] on the PC with the exe installed and
      running, run the command from a PowerShell in the clone: the exe closes by itself (taskkill without /F; if it
      stays, the script names it and stops), the tray icon appears, Debug logs say "Developer source mode; the driver
      runs from <clone>\static\ergopti_plus\windows (clone root from the developer variable)" and "Developer source
      watcher started"; the config is the
      exe's (same hotstrings, same `paths.toml` choice, no onboarding); save any driver `.ahk` with a harmless
      comment change: within about 2 s the driver reloads once and keeps a Pause; the tray's Reload still works;
      AI menus (Ollama), the metrics window (WebView2, sqlite3.dll) and Alt+Tab navigation (ergopti_nav_owner.dll)
      work; Start at login in this mode registers the interpreter and the clone's script, and that login start
      derives the root, so it is a developer run too (wanted, maintainer decision of 27 October): confirm it. (2) [PHYS-W] check that
      `npm run dev:windows` works from Git Bash and from cmd (it calls Windows PowerShell 5.1). (2b) [PHYS-W]
      double-click works: quit the exe from its tray, double-click `static\ergopti_plus\windows\ErgoptiPlus.ahk`
      in Explorer: the same Debug lines appear, the "Developer source mode" one ending "(clone root from the
      script location)",
      a saved `.ahk` reloads, About shows the updater off and Uninstall greyed; then start the exe and
      double-click again while it runs: the source run yields after about 3 s (no second tray icon, a
      "Another instance owns the single-owner mutex" WARNING in `bootstrap.log`) and the exe keeps running. (3) [PHYS-M] the Mac lines of the hardware session cover the macOS
      mode. (4) Linux, on a real desktop with the package installed: the unit is stopped, the tray appears, a
      saved `.lua` restarts the daemon (`Debounced source reload firing` then a new boot), the tray's Reload
      restarts it, and a second `run-linux-dev.sh` while one runs reports "already running". (5) [CODE] decide
      whether the layout catalogue should fetch the remote registry in a developer run (today all three read the
      clone's registry, by design of `local_source`). (6) [CODE] `bin/ergopti-hotstrings` run from a clone still
      prefers `/usr/lib/ergopti` when a package is installed; fix or retire that branch.
- [ ] **Owned, pinned third-party runtimes on the three OS (maintainer decision, 27 October).** [CODE] Ergopti
      installs and runs its own pinned Ollama, MLX environment, Karabiner runtime and any other third-party
      runtime, whether or not the user has one, and never uses, stops or modifies the user's copy. Ollama:
      always the managed daemon on its own port and models directory (agent AK, macOS first, then Linux and
      Windows). MLX: already Ergopti's own environment; keep it so. Karabiner on macOS: this activates item 31
      (owned Karabiner runtime, ADR 011, dormant today behind `[karabiner] runtime = "owned"`); plan it as the
      default. Rule from the maintainer: with tap-hold on, quit the user's Karabiner and run ours; with
      tap-hold off and theirs present, never activate ours (this rewords ADR 011 decision 3). WebView2 stays
      the system copy, with a version check and a clear refusal. Linux and Windows: inventory every external tool the drivers call (ydotool, xdotool, wmctrl,
      curl, Python, PowerShell modules, WebView2) and decide per tool whether Ergopti ships its own.
- [ ] **Ergopti's own Ollama on Windows and Linux too (maintainer requirement, 27 October).** [CODE] Same rule
      as macOS on every OS: Ergopti always installs and runs its own pinned Ollama, whether or not the system
      has one, and never selects, reuses, stops or modifies the user's Ollama. macOS is done (bc09e4584c:
      `ollama_binary.resolve()` returns only the owned runtime, pinned 0.40.4 from `managed_ollama_runtime.json`;
      the shared key `llm_ollama_owned_port` = 11435 in `defaults.json`, read through `ollama_endpoint`; a saved
      11434 override is refused and the old `llm.ollama_port` is migrated once and logged). Linux is done
      (1c75ea5: origin, serve address and readiness probe on `llm_ollama_owned_port` via `llm_bridge`
      `OLLAMA_OWNED_PORT`, the stock port refused, a PATH `ollama` no longer counted; Linux never saved a
      port, so nothing migrates; `test_owned_ollama_coexistence.lua` holds a fake system Ollama on PATH and
      11434). Left: Windows (it already has an owner for its own Ollama taking a models directory and port;
      check its installer and every caller against the rule), moved to `llm_ollama_owned_port`, the user's
      daemon on 11434 left untouched, with regression tests that an installed system Ollama is never
      resolved or started. [PHYS-W] [PHYS-L] confirm with a system Ollama running on 11434: Ergopti's
      listens on 11435 (Linux: enable the AI from the menu on a machine running `ollama serve`).
      Windows (30 Oct): done in code on dev: owned port from `llm_ollama_owned_port`, 11434 refused (`LLM_Option_TryNormalizeOllamaPort`), a saved 11434 dropped once and logged (`persist.ahk`), only the owned runtime is launched (`test_ollama_owned_only.ahk`). [PHYS-W] still open.
- [ ] **Ctrl+Caps Lock slot on macOS.** [PHYS-M] The `secondary_capslock` slot binds through its own native
      entry again (ea02cf7000: the generic registrar refuses Caps Lock and the whole shortcut start rolled
      back). The registrar tests say macOS never fires a Caps Lock hotkey: check on a real Mac that Ctrl+Caps
      Lock toggles Caps Lock; if not, report it and drop the slot's recommendation on macOS with a reason.
      Since 30 October the field run judges it from the session's own keys, with no manual step: when a
      Ctrl+Caps Lock was typed during the session, `field_capslock_chord` passes `delivered:N` or fails
      `never_delivered` (the keymap modifier tap counts the physical chord, the slot's native callback
      counts each delivery); with none typed it skips.
- [ ] **Layout emulation on macOS and Linux through one generated `.keylayout`, live (maintainer request, 27
      October).** [CODE] Decided by the maintainer: no pre-generated variants. The user picks a layout
      (Ergopti, Bépo, ...), the menu options (number row in direct access or symbols, row switches) and later
      per-key edits in a page; that produces one custom `.keylayout`, the single source the three OS already
      share: Windows emulates it (AHK reads a `.keylayout`), macOS installs it as the input source, Linux
      converts it to XKB (`_shared/lua/layouts/xkb_converter.lua`). The per-layer layout composer
      (docs/design/layout-composer.md) already compiles a composition into `composed.keylayout` and installs it on
      the three OS; build on it, do not add a second format. Left: (1) the menu options (Ergopti or Bépo base,
      `layout.direct_access_digits`, `layout.number_row_reorder_edges`, the row switches) feed the compiled
      `.keylayout` on macOS and Linux instead of narrowing a Windows-only emulation, with Ctrl/Cmd maps, dead
      keys and symbols from the layout; (2) a live replace with no logout: macOS caches a rewritten
      `.keylayout` until the input source is toggled or the user logs in, so write each build under a new
      versioned id, register it (`TISRegisterInputSource`), select it, then disable and remove the previous one
      (verify on the maintainer's Mac); Linux replaces the XKB files and reloads with `setxkbmap` on X11 and the
      desktop input-source setting on GNOME and KDE Wayland, with an honest reason where a compositor cannot;
      (3) the scope participant acknowledges only after the new layout is selected. Design note
      `docs/design/layout-option-emulation.md` first (agent AF), then slices.
      **Linux done** (branch `fix/linux-layout-emulation`, 30 October): the options convert the installed
      `.keylayout` (registry copy or `composed.keylayout`) with Ctrl, AltGr and dead keys from the layout; X11
      and GNOME/KDE Wayland load it live (two slots `<id>`/`<id>_live` replace the counter) and both succeed
      only on the cells read back from the session; the scope settles on that answer. Proved on Xvfb
      (`tests/hardware/run_layout_rows_live.lua`, `test_wayland_live_replace.py`). Left for Linux: W1 to W4 of
      the design note on a real GNOME and a real KDE session (mutter/KWin read `~/.config/xkb` and recompile
      on the slot switch); typing on a physical keyboard; the Bépo base needs a Bépo `.keylayout` in the
      registry (none exists, so only installed registry layouts and the composition are sources); the row
      switches (`layout.emulate_*_row`) stay Windows-only: they mix Ergopti rows with the OS layout, which has
      no `.keylayout` source on Linux; the onboarding control is 3337d99bc8 on `tmp/wip-todo-af`
      (compatible, it reads `number_row_live.available()`).
      **macOS done in code** (branch `fix/macos-overnight-d`, 30 October): (1) the menu rows store the choice and
      rebuild the layout typing now (an installed registry or composed layout, or the build typing for it) with
      `layouts/keylayout_rows.lua`, the shared `.keylayout` editor proved against the Linux converter on every
      vector and registry layout (`test-keylayout-row-options.cjs`; Cmd, Ctrl and Option keep the layout's
      cells through a copy of the keyMap they shared); (2) `layout_rows_build.lua` writes each build under a new
      name and id, enables it through the preference route, selects it, accepts it only on a fresh-process
      read-back of its base cells, then retires the previous build (two failed retirements refuse the next);
      (3) the global scope's layout participant settles only on that read-back and reverts the rows when the
      system did not take the layout. Left [PHYS-M]: the next field report's `field_layout_rows` answers M4 to
      M6 (live select, live replace, exact restore, ghosts until logout); if it fails on `select_refused` or
      `requires_logout`, the live path needs the in-bundle route of the design note. Choosing an option in the
      menu on the Mac and typing with it needs hands (the field step drives the same build path, not the menu
      click). An Ergopti bundle source types digits on both levels, so its rows stay greyed (`digits_on_both`).
- [ ] **Windows updater -File workers: real update check.** [PHYS] Install a build with 5d6beccf83
      by hand, then update from it to the next release: the exe is replaced and restarts, the
      three scripts are in `%LOCALAPPDATA%\Ergopti\vendor\`, the PowerShell command line shows
      `-File ...ergopti_updater_staging.ps1` and no `-EncodedCommand`.
- [ ] **Config policy remainders (33, 42).** [CODE] Done: macOS category authority (80c18d9cc2),
      explicit `--config` watcher topology (3dd420292d), `api_entries` retired rows (c03762d27b),
      parse cost (e525cd6615). Left: the physical keyboard slot parameters
      (`keyboard__win_SC03A__x`), the Windows `api_entries.json` per-row warning, the bare-root and
      unknown-`[[x]]` cleanup offers, and a reseal of the updater original source after e525cd6615
      once `run_all.ahk` is clean. The Linux reload as a daemon restart with the TTL-bound pending
      record is in (docs/design/driver-control-pending-record.md) and is now proven across real
      processes on the relay path (`tests/hardware/run_reload_restart_live.lua`, CI step "Restart
      the daemon through the local reload control") and on the systemd unit path
      (`tests/hardware/run_reload_restart_systemd.lua`: a real cgroup named after the unit, the exact
      `systemctl --user --no-block restart`, the successor completing the record, with a stand-in for the
      user manager this container cannot run; not a CI step). Left for it: one restart under a real
      user manager on a real session [PHYS-L].
- [ ] **Linux CI installs packages inside short test steps.** [CI] 18 steps moved and skipped when the
      suite is deferred (c52cb916a7, 285d3363a1); `Qualify three actual XI2 property cookies` and
      `The whole daemon, live` already had their install steps; the LuaJIT XI2 qualification, the
      35-minute managed HTTP preparation and the 18-minute manual Ollama acceptance now have theirs
      too (branch `fix/linux-input-config`), with the pinned contracts updated. No Linux test step
      runs the Ubuntu acquisition any more (the remaining ones are install, toolchain or package
      steps). Left: hosted validation.
- [ ] **macOS "Quit did not end both processes within 10 s".** [CI] Cause found: the Quit AppleEvent
      timed out while the launcher log had been silent since startup (run 39850037912); the gate now
      names the surviving process and keeps the failing attempt's evidence for 7 days
      (b2b5bb149b, bf05488dfb). Read `launch-gate-failed-*` if it recurs.
- [ ] **History hygiene of October 22.** Commits with another agent's message, already on dev:
      c6db589c76 (macOS cipher argv fix under a README subject), 90da28c725 (config snapshot test
      under a CI subject), 18ca214ead (also deletes ten handoff files), 6d9c659 ("applied for now"
      instead of "apply now"). Keep, or rewrite dev once with a lease: maintainer's call.
- [ ] **Signing and antivirus: maintainer actions.** Apply to SignPath at signpath.org/apply (the
      HubSpot form does not load in an automated browser; answers in
      [signpath-foundation-application.md](docs/tooling/signpath-foundation-application.md)), submit
      the Defender false positive, and ask the tester for the exact block page.

- [ ] **36. Windows updater production coupling.** [CODE] The "original23" collector stays inactive
      until enrolled; its source preparation stays in Git
      (`49c62d77a1:docs/handovers/2026-10-12-group6-ci/`). Missing: the first trusted PowerShell host
      acquisition (a pre-host native binding with an approved image contract).
- [ ] **62 (macOS and Linux).** [CODE] Packaged paths resolve every request and redirect natively;
      the environment fallback now resolves each origin of the client inventory and refuses two
      different relays (1fd254d92e, 749e00c4c8). The Go twin runs in the `network-ai` cell ("Qualify
      the Go route plan twin"). Linux wrapper test done 30 October:
      `linux/tests/hardware/run_managed_ollama_route_plan.py` installs the driver as the packages lay
      it out, takes LUA_PATH from the wrapper's own export line, runs from a foreign directory and
      answers both origins with a real PAC through glib-pacrunner on a private bus (8 cases, passing
      in a Linux container; a registry-only stage turns 4 red); CI step "Qualify the installed managed
      Ollama route plan". Left: confirm the Ollama blob host on the Mac, the first hosted run of the
      new step.
- [ ] **CI duration** ([target](docs/memory/workflow-and-verification.md)). Flatpak runtime cache and a
      bounded retry are in (07a601c97e plus the retry commit); confirm on a hosted run (target under
      5 min). Windows Integration still adds 4-5 min on the critical path; the macOS lane (about 58
      min) must stay within the five-runner budget.
- [ ] **CI structure.** [CODE] Slowest-test summary and `tools/ci/run-timing.cjs` shipped
      (e1aa4a5f48, cab1170446). Left: a per-step elapsed summary inside the CI run itself.
- [ ] **Test parity across the drivers.** [CODE] Done: Windows CapsWord behaviour tests, dynamic
      hotstrings, macOS audit-named tests renamed, neutral-installation gate. Left: Windows replay of
      the shared HTTP-redirect, timer-ceiling and key-chord corpora (needs a decision to build those
      policies on Windows), conversion of Windows source assertions to behaviour (audit item 14).
- [ ] **116. Guided third-party validation report.** [PHYS-M] macOS `field_check_toolchain` landed
      (timer, Shortcuts, Homebrew, Karabiner signature); needs a run on a real Mac. Package
      provenance beyond the signature check is open. The field run's `field_toolchain` step is that run,
      with no person: the next field report answers it.
- [ ] **139. Personal identities in logs.** [CODE] Done: email, URL-credential, foreign-profile
      rules (5ef12e8a2a) and config-directory name masking (20e845692b); opt-in redacted day log
      attachment (1c6f891ed3, item 138). Left: emitter-side pack labels (the TomlLoader SUCCESS line
      prints the pack label; check the macOS and Linux loaders: checked 30 October, the macOS registry already
      masks it, `file_label` and the Lua and TOML start/success lines go through `PrivateLabel.mask`), write-time masking in the three
      loggers, historical logs on disk stay unmasked (the collector masks at export), GitHub field
      editability after a form reload needs a real draft.
- [ ] **142 gaps.** [CODE] Windows: a Reload click during a pending reload now follows the join rule
      (standing-checks agent); no hash-check requirement identified for the Windows client. Linux:
      the reload restarts the daemon (pending record, see "Config policy remainders").
      Windows: done (`test_menu_reload_replay.ahk` reload-click-joins).
- [ ] **13/35.** [CODE] Enrol the complete guardian acceptance collector in main CI.
- [ ] **93. Linux ordered pairs.** [PHYS-L] XI2 property cookies proven on Xvfb in WSL and again on
      30 October in an Ubuntu 24.04 container (Xvfb 21.1.12, `run_xi2_property_cookies.py`: created,
      modified, deleted); the saved Xi packet is retired (libXi as a package dependency declined by
      the maintainer). Nothing else is provable on Xvfb: it reads no kernel device, so the join of a
      uinput Writer edge with the server's XKB/XI2 modifier state needs Xorg or a compositor reading
      real evdev nodes, and physical input needs a real kernel and desktop.
- [ ] **97/98.** [CODE] Native physical-position capture and all-owner collision admission. The
      MediaStore device contract now exists (`_shared/lua/keystats/media_identity.lua`: `device` is a
      decimal u64 string, as macOS fills it), so the Linux identity is no longer blocked on policy;
      the candidate is the owned descriptor's `st_rdev` from `fstat`, never a path or event-node
      number. Not added on 30 October because nothing on Linux would read it yet: no Linux producer
      calls `sqlite_writer.insert_media_events`, and `keyboard_hook.capture_position` hands the editor
      `native_code` and `mods` only. Decide the consumer first (Linux media-key metrics, or a
      per-device physical binding), then add the identity with it. The star setting migration is
      dropped (no users, no legacy migration).
- [ ] **106.** [PHYS-M] Genuine Apple Shortcuts invocation with bounded cancellation; only the
      refusal-in-time probe exists (in 116). _Hands:_ a genuine run needs a shortcut the maintainer
      owns and names (the `shortcuts` command cannot create or import one without a dialog, and running an
      arbitrary shortcut of theirs is not read-only); `field_toolchain`'s `shortcuts_list` and
      `shortcuts_refusal` are what a program can prove.
- [ ] **107.** [CODE] macOS forced output. Linux is settled by design: the number-row ordering and
      edge keys are applied by rebuilding the layout (`docs/design/linux-number-row-runtime.md`), so
      the hook's input+XI2+writer join is deliberately unreachable (nothing passes `numberRowMode`)
      and is not owed; left for Linux only [PHYS-L] mutter and KWin reloading a `~/.config/xkb`
      layout (W1 to W4 of that note).
- [ ] **108.** [CODE] Item 97's collision/source/modifier/output joins.
- [ ] **109. Branded debug GUI.** Blocked: AHK 2.0.26 has no supported invisible
      Variables/KeyHistory snapshot.
- [ ] **120 (formerly 46/47/48).** [CODE] Broad Ollama process termination on macOS stays debt (the
      other clauses of 46/47/48 were stale or by design; their context was lost and the maintainer
      retired them). Checked 30 October: the macOS driver no longer kills any Ollama broadly; quit and
      reload retire only the owned daemon (`api_ollama.stop_owned_server`), and the only `pkill -f`
      sweeps left name the expander, the HTTP helper and `mlx_lm` server. Proposal: close it.
- [ ] **L115.** [CODE] Provider error envelope guard: not reproducible under WSL LuaJIT (6 of 6
      runs pass); leave it or close it.
- Optional, not planned: XKB angle-name gaps and raw-input grammar (L118-L120); concurrent JSON
  backup replacement (L52, L60); ALSA fallback (L63); multi-group XKB recovery (L100); a real
  `Comments` exe field through a version `.res` resource.

## Maintainer checks

Record the commit, OS build, scale, layout and emulation state; report pass, fail or not executed
per line. Use a disposable profile (`paths.toml` pointing at a scratch folder) for anything that
writes configuration. Reload the driver from the working tree for dev-only fixes.

### Web-view window toggle actions (`tmp/wip-webview-toggle-actions`)

Maintainer decision of 2026-10-27: every Ergopti web-view page has a shortcut action in the shared
catalogue (`_shared/modules/actions/actions.toml`, group "UI") that toggles it. Closed or hidden:
open and focus; open behind another window: bring to front, never close; open and frontmost: close
through the page's own close. Ten actions, all three OS: `open_metrics_typing`,
`open_metrics_apps`, `open_hotstrings_editor`, `open_paths_editor` (existing ids, now toggles on
macOS and Linux too), and new `open_hotstrings_settings`, `open_layout_manager`,
`open_layer_editor`, `open_model_browser`, `open_changelog`, `open_healthcheck`. Not toggles, on
purpose: onboarding (a shortcut would abandon a half-finished setup), the download window (a
progress view owned by a running download), the release notes (a pane, not a window) and the
contextual dialogs. Owners: macOS `ui/window_toggle.lua`, Linux `ui/webview_manager.lua`
`toggle()`, Windows `GestureToggleOrFocusUI` (`modules/gestures/actions.ahk`). Pending
coordination: the model selector rework (`tmp/wip-model-selector-page`) must keep
`ui/model_browser` `window()`/`close()` (macOS) and the macOS `set_opener("model_browser", …)`
line of `menu_llm/models_selector.lua`.

For each OS, bind each of the ten actions to a keyboard shortcut (Shortcuts menu, keyboard slot or
tap-hold picker) and press it three times: from closed it opens and has the focus; click another
app's window so the page is covered, press again: it comes to the front and stays open; press once
more while it is frontmost: it closes. Also minimize it, press: it comes back.

- [ ] **Windows**: the ten actions above, including the WebView2-less fallbacks (native hotstring
      editor, native hotstrings settings, native ListView model browser) when WebView2 is absent;
      the close must run the page's own Close handler (no orphan WebView2 process in Task Manager).
- [ ] **Mac**: the ten actions. The model browser's opener is registered when the AI menu is
      built (the menu prime, a few seconds after a reload): press `open_model_browser` right
      after a reload and with the AI off, and note any `window_toggle` ERROR naming a page with
      no registered opener. A covered window must be presented, not closed (focus is read
      through Accessibility).
- [ ] **Linux** (no machine): GNOME Wayland and X11, the ten actions; GTK's is-active flag decides
      "frontmost", so check that a page covered by another app is raised, not closed.

### Mac hardware session (prepared 27 October, run from a branch of dev)

Clone only the current dev state and branch from it:
`git clone --depth 1 --branch dev --single-branch --filter=blob:none https://github.com/adrienm7/ergopti.git`,
then `git switch -c field/mac-2026-10-27` (if the clone is cut off: `git config --global http.version HTTP/1.1`).
Run the developer app: quit the installed ErgoptiPlus, back up `~/.config/hammerspoon` (the v15 migration
rewrites `config.toml`; keep a copy of the old one for section 3), remove an old `~/.hammerspoon/init.lua`
bootstrap if one exists, then `bash tools/dev/run-macos-dev-app.sh` (Command Line Tools are enough: it builds a
native single-architecture app whose Lua runs from the clone, then opens it; `--open-only` reopens without a
rebuild). Saving a `.lua` file reloads the driver; the menu Reload row reloads on demand. Rebuild only after a
Swift, native helper or LuaSocket change; each ad hoc rebuild asks again for Accessibility and Input
Monitoring. `~/Library/Logs/ergopti_plus/launcher.log` must say "developer source mode". Sparkle is off in
this mode, so the update lines of section 5 need a release build. Before starting, write down the commit (`git rev-parse
--short HEAD`), macOS version and build, chip (Apple silicon or Intel), keyboard (ISO or ANSI, built-in or
external), input source, Karabiner version and whether Ollama.app or oMLX is installed. Report each line as
pass, fail or not run.

**Give me the logs.** At the end of the session (and right after any failure) use Debug > Report a bug, or copy
`~/Library/Logs/ergopti_plus/ErgoptiPlus_<date>.log`, `ErgoptiPlus_errors_<date>.log` and
`ErgoptiPlus_llm.log` into `docs/field-reports/mac-2026-10-27/` on your branch and push it (the logger already
masks secrets, the home folder, e-mails and personal names; check nothing private is left). Set Debug > Log
level > DEBUG first for the whole session. I read: `Boot complete in`, `Boot CPU`, `Boot stage`, `Slow <segment>:
X ms own, Y ms total, parent ...` (HotPath, PAR-53), the periodic PhaseStats and log-volume summaries
(PAR-54, PAR-56), `Field check result:`, `typed key(s) swallowed`, `key_event_health`, lease lines (`exit 73`,
PONG/READY), `Lease-bound input startup failed`, `Layout poll detected change`, every ERROR and WARN.

#### 1. Start-up time and idle cost

- [ ] Cold start: quit Ergopti, wait 10 s, start it; note the `Boot complete in … ms` and `Boot CPU` lines.
      Repeat three times, then once right after a macOS login. Report the three numbers and the slowest
      `Boot stage` lines. _Field run:_ `field_boot_cost` reports the boot that started the field run (wall,
      CPU, slowest stage; the three slowest in its log window). _Hands:_ the three cold starts and the one
      after a login (a quit ends the field run, a login ends the session).
- [ ] Reload: Hammerspoon > Reload config three times; same lines. A menu click during the reload is held
      and replayed; a second Reload click joins the first one (no double reload). _Field run:_ the
      `driver_reload` step (the timed reload, owned by another worker) times one reload; three reloads compared
      line by line come with it. _Hands:_ the menu clicks during a reload.
- [ ] Idle: 10 minutes without typing, then Activity Monitor CPU and memory of Hammerspoon; the PhaseStats
      summary in the log should show no recurring work above a few ms per minute. _Field run:_
      `field_idle_cost` measures the driver's own CPU share over 30 quiet seconds (fails above 3 %) and names
      its resident memory, heap growth and main-thread holds; nothing here needs a person any more except
      the 10-minute figure, which the next report's PhaseStats lines give.
- [ ] Quit during a busy moment (typing, then Quit within a second): the app ends both processes within
      10 s (CI item "Quit did not end both processes within 10 s"); Quit wins over a reload in progress.
      _Hands:_ a quit ends the field run itself; the CI launch gate times the quit of a packaged app.

#### 2. Typing in real conditions (one working day if possible)

- [ ] Type normally for at least an hour in Safari, TextEdit, Terminal, VS Code and one Electron app (Slack
      or Discord). Note any dropped, doubled or reordered letter with the time; right after one, use Debug >
      Report a bug. I compare with `typed key(s) swallowed`, `key_event_health` and the lease lines
      (items "Dropped letters on macOS", "macOS swallowed-keys check on v1.0.6", 117/140).
- [ ] Hot path: after that hour, the HotPath lines name each slow segment with its own time and its parent;
      send them, they decide what to optimise next (Issue #101 point 1: `Slow ingest tick`,
      `Slow preferences save`).
- [ ] Hotstrings: expansions, chained expansions, the magic key on ISO and ANSI, Backspace right after an
      expansion (undo), hotstrings in a password field (none must fire, private text never logged), an
      ignored app. The injection order is new code (PAR-76 R26): any wrong erase count or replayed
      terminator (Return, Tab, a letter) is a fail.
- [ ] Tap-hold: each tap-hold key alone, fast rolls (`one-shot`), holding with another key; the Karabiner JSON
      thresholds equal the shared per-key thresholds (PAR-15: compare `~/.config/karabiner/karabiner.json`
      with the menu values). _Hands:_ the key presses. The threshold comparison is a program's job, left to
      the Karabiner input owner.
- [ ] Ctrl+Caps Lock toggles Caps Lock (new `secondary_capslock` slot binding, ea02cf7000; the tests say
      macOS may never fire a Caps Lock hotkey: report exactly what happens).
- [ ] Right Option + Return, Delete, Backspace and Escape run their script actions; Backspace word start in
      Terminal (`ab`, three Backspaces), TextEdit Option+Backspace and Safari Cmd+L.
- [ ] CapsWord: the pointer cancels it (item 44).

#### 3. Configuration migration and menus

- [ ] Schema v15 (PAR-41): with a copy of an old `config.toml` that has keyboard shortcut slots with
      parameters (for example a shortcut that opens a URL or types text), start the new build: every slot
      keeps its action and its parameter under its role-named id.
- [ ] Old `[llm.profiles] user_profiles`: a config that has them still shows the profiles in the AI menu
      (PAR-40), and the next save writes the new `llm.user_profiles` only.
- [ ] Clear and Restore per category and global, then restart: unknown keys kept, personal hotstrings kept
      by Restore, exact backups; recommended-settings restore asks no confirmation where it should not.
- [ ] Shortcuts group restore and clear; tap delay row opens the dialog and « Use global delay (…) » is
      right below it; tap and hold pickers: Tap-Holds > a key > « Tap → … » opens the shared action
      picker window (no submenu), picking Escape applies it and « ∅ » gives the key back; « Hold → … »
      lists only holdable actions; Shortcuts > « Combinaisons de touches » > a pair opens the same
      window for each of its three slots.
- [ ] Menu row order looks as before in every submenu (orders now come from one data file, PAR-76 R18).
- [ ] « Retirer les anciennes règles » on an upgrade (item 43); Login Items show one Ergopti (item 24,
      Debug > Show what starts Ergopti at login). _Field run:_ `field_login_items` names every login entry
      and whether it belongs to this copy. _Hands:_ the upgrade.

#### 4. AI predictions

- [ ] With a real local model (Ollama.app, then oMLX if installed): predictions appear; the request floor
      (default 300 ms, settable in the AI menu, 0 accepted) spaces automatic requests; an explicit
      shortcut is never held; asking for several variants sends them without delay; mashing the shortcut
      replaces the request in flight; the debounce "never" setting works; live mode answers at once at a
      word end.
- [ ] AI off disarms the AI keys, the agent's manual actions and the automatic mode; greyed actions show
      the dedicated "requires AI" hint.
- [ ] Agent: manual action refused with the right notice when paused, AI off or agent mode off; automatic
      triage skipped while typing a hotstring preview (new shared decisions, PAR-65).
- [ ] Tooltip typography and placement near screen edges, on two displays (item 111).
- [ ] Issue #100: with Ollama.app and a PAC proxy, enabling the AI downloads the model; with the Ergopti
      menu held open, no lease timeout.
- [ ] Issue #99: `memory_pressure | tail -1` during lease errors; oMLX listed (DEBUG line `Local server 'omlx'
probe answered ...`, else `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/v1/models`);
      `Ollama bootstrap failed (exit=137)` with an external Ollama; declining the download opens no error
      window.

#### 5. Network, updates and field checks

- [ ] Debug > Test network (PAC, proxy, download), on the office network if possible and at home: send the
      `Field check result:` lines; the new route-plan step shows which route each Ollama origin takes; an
      `http://` company PAC is fetched (Issue #101).
- [ ] Debug > Test Karabiner lease, Test key accounting (30 s, type during it), Test third-party tools
      (Shortcuts, Homebrew, timer; item 116), Test owned Karabiner runtime (must stay dormant). _Field run:_
      `field_lease`, `key_accounting` (typed by the app into its own field), `field_toolchain` and
      `field_owned_runtime` run each of them; nothing here needs a person.
- [ ] Update check window: release notes pane readable in light and dark, links open the repository
      (PAR-52); a Sparkle update from the previous release installs and relaunches; Homebrew live upgrade.
- [ ] MLX download behind a proxy (119/130/136); code 74.

#### 6. Windows and pages (visual)

- [ ] Open every page once in light and dark mode: metrics (apps and typing), changelog, release notes,
      model browser, hotstring editor, layout manager, onboarding wizard, download window. Colours now
      come from the theme (PAR-81, proven identical in Chromium): report anything that looks different in
      the real WebView.
- [ ] Onboarding wizard (item 7): fresh folder, existing folder, moved folder, Cancel, Finish then
      restart.
- [ ] App Cloner: clone an app, cancel the folder picker (system « Annuler » label is expected now), and
      clone into a full or read-only folder: an error dialog must appear, never an endless progress bar
      (4550befb08).
- [ ] Trackpad gestures (item 126); Diagnostics window focus (item 122); shared export (item 123).

#### 7. Edge cases

- [ ] `pipefail` and `printf %b` under the system bash 3.2 (automated: collector step `system_bash`), the native HTTPS downgrade refusal,
      `hs.fs.attributes` on a FIFO, the read-only dashboard with a hot journal. _Field run:_
      `field_fifo_safety` (a FIFO is named without being opened; append and the atomic write refuse it).
      Left for a program: the HTTPS downgrade (needs an HTTPS origin that redirects to HTTP) and the hot
      journal.
- [ ] Recompile `macos/apps/Encryptor.app/Contents/Resources/Scripts/main.scpt` from its source in Script
      Editor so its comment follows the keystats rename, and commit it.

### After v1.0.5 (actions)

- [ ] Post `/retest` on AppImage/appimage.github.io#10422 from **PowerShell** (Git Bash rewrites
      it): `gh pr comment 10422 -R AppImage/appimage.github.io --body '/retest'`; read the bot's
      screenshot (status window and tray menu, 98d41e630b) and warnings.
- [ ] Airbus tester (Netskope): retry the `ErgoptiPlus.exe` download and report T1-T4
      ([matrix](docs/tooling/windows-exe-flagged-by-proxy.md)).
- [ ] Give the v1.0.5 SHA-256 to VirusTotal; submit it to Microsoft Defender as a false positive if
      flagged.
- [ ] Number-row testers (October 13 and Discord): retest with their exact setup (native layout,
      emulation and row switches, CapsLock, outputs in the three modes); fix only a confirmed
      discrepancy. Key-combination testers (October 15): confirm c89d74eb, else ask for
      `[KeyCombinations] Pair`, `AHK drop detected` and `Menu command refused` lines.
      Priority-100 tester: confirm uppercase output (cf29c35e5f).

### Windows PC

Fixes of October 22 (dev, after v1.0.5):

- [ ] **Win+S open target** (ec1c4105d9): automated checks cover the target resolution; by hand only
      what leaves the driver: a browser, the mail client, Regedit with its prompt, Settings, a web
      search (steps in [windows-maintainer-checks.md](docs/tooling/windows-maintainer-checks.md)).
- [ ] **Backspace word start**: the engine-buffer cases are automated; by hand only Windows Terminal
      with Claude Code, Notepad Ctrl+Backspace, the browser Ctrl+L, and AltGr+Backspace on an
      AZERTY-style AltGr and a Kana layout.
- [ ] **Tap-hold and key-combination pickers**: automated except the native pair popup itself.
- [ ] **Versions tabs**: automated except the Retry button.

Standing checks:

1. **Seven-page wizard** (item 7): fresh, existing and moved folder; every page, Cancel, Finish then
   restart, rerun; No against recommended choices; WebView rendering and persistence; the layout
   step's controls never reload the UI.
2. **Clear and Restore** (item 5): per category and global, then restart; unknown and outdated keys
   preserved; personal hotstrings unchanged by Restore; exact backups; an external write refused.
3. **Number row and key combinations**: on AZERTY, US QWERTY and Ergopti, each ordering and
   edge-key choice, each row emulation switch, an inert choice ticked, greyed and suffixed « — non
   appliqué », the ² key; a pair assignment saved and reloaded.
4. **Installed build**: install, start, Diagnostics cold and reopened (UIA/render probes, cold
   WebView), Quit during a keystats flush, File/Exit and Windows shutdown with exit code 0;
   uninstall greyed on a source run. Item 101: capture the watcher/debt state if `watchers=0`
   recurs.
5. **Item 51 matrix**: arrows and both Shift+Tab over a multi-slot prediction move the marker once
   and wrap (also after reload, with `nav_modifiers = ctrl`, with a tap-hold Tab); footer "⇧G + Tab
   ou ↑/←"; bubbles and delayed expansions with emulation off and on; no "eeee"; one clipboard-log
   row per Ctrl+V; AltGr+Entrée/Suppr/Retour arrière/Échap script actions; AI menu; « Revenir à
   cette version » keeps a backup.
6. **Items 19, 49, 50**: tooltips near screen edges on Windows 10 and 11 at several DPI scales; hook
   order around a SendInput rehook; the send-mode measurement.
7. **Hotstrings** (items 34, 37, 102, 104, 105, 129), in the installed driver: delays 0.5 s
   recommended and cleared back to 1.0 s; handwritten delimiters and `[[hotstrings.terminators]]`
   through Add, Delete, toggle, save and restart; with no Ergopti layout installed the shipped pack,
   the 24 suffix rules and magic-key repeat appear once; personal files (duplicates, unreadable,
   junctions, depth 16) and their delay, priority, colour and tooltip edits; each common
   autocorrection family alone (34/95/11 rules); `run_all.ahk --only "programmable hotstrings"`
   and the compiled probe `tools/test/run-compiled-user-hotstrings.ps1`; `update` never proposes
   `date`. Full list: `49c62d77a1:docs/handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md`.
8. **Layout switching** (item 38): AZERTY with emulation to native Ergopti and back keeps AltGr
   usable without a reload, also on an AZERTY-style AltGr (LCtrl+RAlt) and a Kana layout.
9. **Touchpad registry** (item 13): values restored after OFF and removal; kept after a refusal.
10. **Managed network** (item 62), behind a company proxy: WinINet settings, PAC order and
    failover, WPAD absence, the eight remote CA cases, Negotiate and NTLM proxy challenges, then the
    installed updater (download, swap, rollback). The twelve detailed steps stay in Git
    (`49c62d77a1:docs/handovers/2026-10-04-group6-windows/README.md`).
11. **CapsWord auto-off**: delays, the eight default delimiters, each pointer kind, the LAlt then
    CapsLock trigger.
12. **AI off (#97)**: no local server sweep, no AI hotkeys, a refused AI hotkey leaves the driver
    running. Item 143: time the AI toggle behind an unfinished startup (3.05 s on the smoke).
13. **Prediction chord (item 112)**: in Notepad each slot's modifier+digit inserts that prediction
    and its correction form; the shortcut column is right-aligned and muted.
14. **Item 114**: observe the resident process during a prediction-key (1-5) or AltGr+Enter stall
    and collect the Notepad stale-admission diagnostics before changing anything.
15. **Items 30, 46-48, 54/81, 63, 73, 88, 96-98, 107, 108, 125, 138**: physical magic key under
    emulation; a real local model (chat, download, consent, pause/resume/shutdown, HTTPS behind the
    system proxy); installed menus (captions, unavailable reasons, state after restart);
    brightness up/down and refusal without a backlight; physical-key labels after a locale change;
    prediction tooltip typography; emulation picker precedence and dead-state output; chosen
    physical positions and arbitrary outputs including dead keys; number-row and magic-key
    shortcut delivery; free-text translation dialog; diagnostic export copy, write, reveal and
    browser.

### Mac

- [ ] **L46 three-finger swipe vs scroll** (`tmp/wip-three-finger-swipe2`): re-enable
      `swipe_3_up`/`swipe_3_down`, scroll with two fingers for a few minutes, no tab switch; a
      deliberate three-finger swipe (slow, flick, staggered) switches tabs every time, and a miss
      leaves a DEBUG `Three-finger candidate rejected by <gate>` line in the day log.
- [ ] **L46 swipes stop being accepted** (`tmp/wip-three-finger-stuck`): no
      `has no capture timestamp` ERROR after a reload; ten vertical three-finger swipes half a second apart, right
      after a two-finger scroll and with a finger resting, all switch tabs; landing on a running
      two-finger momentum is still refused (`scroll guard`); scrolls never switch tabs.
- [ ] **L46 one swipe, one tab** (`tmp/wip-three-finger-step`): with no explicit swipe_3
      sensitivity in `config.toml`, a normal and a short deliberate vertical three-finger swipe
      each switch exactly one tab, a swipe past 29 units (the logged `sd`) two.
- [ ] **Issue #100 retest** (after v1.0.5: 2353a72eed, 25411ee080, e57f4cce77): with Ollama.app and
      a PAC proxy, enabling the AI downloads the model; with the Ergopti menu held open, no lease
      timeout.
- [ ] **Issue #99**: `memory_pressure | tail -1` during lease errors; oMLX listed (DEBUG
      line `Local server 'omlx' probe answered ...`, else
      `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/v1/models` and
      `lsof -nP -iTCP -sTCP:LISTEN | grep -i omlx`); `Ollama bootstrap failed (exit=137)` with an
      external Ollama; which login item starts the second Hammerspoon; declining the download
      opens no error window.
- [ ] **Fixes of October 21-22**: tap and hold pickers (steps in the Mac list above); tap delay
      row opens the AppleScript dialog, « Use global delay (…) » right below; Shortcuts group
      restore/clear; Ctrl+S open target (as on Windows, registry keys answer « Windows only »);
      Backspace word start (Terminal Return, `ab`, three Backspaces, `c★`; TextEdit
      Option+Backspace; Safari Cmd+L).
- [ ] **Item 38**: no "Lease-bound input startup failed" or spurious "Layout poll detected change"
      (automated: `field_slow_lines`' `log_lease_bound_failures` and `log_layout_change_before_baseline`);
      Right Option + Return/Delete/Backspace/Escape run script actions; no Python or Rosetta notice;
      MLX behind a proxy; Versions rollback.
- [ ] **Installed app**: 7 (Cocoa Finish, folder disagreement, native restart), 116 page, 120
      provider menu, 122 Diagnostics focus, 123 shared export, 127 VS Code bridge retirement, 13/35
      guardian registration and retirement on both architectures, 24 Login Items, 43 « Retirer les
      anciennes règles » on an upgrade, 44 CapsWord pointer cancellation, 126 trackpad gestures,
      111 two displays, 30 magic key on ISO and ANSI, 46-48 and 88 a real local model and the
      tooltip typography, issue 94 (tap-hold menu refusal, symbol-wrap clipboard, ISO/ANSI captured
      once), 119/130/136 MLX PAC download, code 74, Homebrew live upgrade.
- [ ] **Shell and file edge cases**: `pipefail` and `printf %b` under bash 3.2 (automated: collector step
      `system_bash`), the native HTTPS
      downgrade refusal, `hs.fs.attributes` on a FIFO (automated: `field_fifo_safety`), the read-only
      dashboard with a hot journal.

### Linux (no machine available)

Wizard (7) on Wayland, physical input, installed-daemon restart; real kernel capture (93); magic
key grab, injection and hotplug (30); tap delay row (zenity/kdialog), group restore/clear, open
target, Backspace word start (GNOME Terminal Enter, `ab`, three Backspaces, `c★`; gedit
Ctrl+Backspace; Firefox Ctrl+L). L46: a two-finger scroll with a thumb resting reports two
fingers, a brisk three-finger tap still reports `tap_3` (the peak must hold two frames).

## CI final acceptance receipts

Qualification-only items: each closes on a named green hosted or native run, recorded here. They are
not open software work.

- [ ] **16/38.** One complete non-release three-OS checkpoint on the final source (units, E2E,
      packaging, installation, launch) with exact receipts.
- [ ] **36.** macOS Package job: Sparkle install/refusal/retry/relaunch, both Brew positives,
      full-policy denial, Brew archive scenarios (the deny-removal AppleEvent positive needs a Mac);
      Linux Flatpak/AppImage installation and PAC/session/TLS delivery.
- [ ] **40.** Signed native execution of the eight Karabiner default/recommended/switch variants.
- [ ] **63, 71.** Brightness joined source; retired Metrics-window shortcuts across a three-OS full
      save and installed upgrade.
- [ ] **104, 105.** Common autocorrection sections (native Windows/macOS, per-section E2E, package;
      the 140-rule corpus is never regenerated from production); dynamic hotstrings on macOS.
- [ ] **34, 37, 102, 129.** Native macOS delimiter transactions; macOS packaging with both
      extension TOML files; Windows native cases and Fedora/Alpine ShellRunner fixtures. Linux done in
      the start-up E2E: the tray's toggle and Delete rows, a refused write rolled back and retried, and
      the next start (`run_e2e.lua`, "the tray's delimiter toggle, Delete and a refused write"; the refusal needs a non-root runner and reports SKIP as root); the
      built-in date rules typed through the real daemon, `update` never proposing `date` (`dynamic-word-start`).
- [ ] **121, 123, 137.** AI Agent submenu composed-menu qualification on macOS and Windows; provider
      published before model loading (macOS). Linux done: the composed tray's agent row is disabled with
      its reason and runs nothing (`run_e2e.lua`, `agent-disabled-root`); the native export write/close refusal
      (`tests/hardware/run_diagnostics_save_receipts.py`, real RLIMIT_FSIZE and permission failures)
      passes 7/7 as a non-root user, and 5/7 fail when the save ignores the write receipt; the Linux E2E
      job runs it on every run outside a deferred stable-release profile.
- [ ] **Carbon and daemon-report Swift.** Carbon fixture compilation and both-architecture
      receipts; daemon-report Swift allocation failures on Intel and Apple silicon.
- [ ] **CodeQL Go.** After the `native_http` Go module is published, re-enable Go and check a fresh
      non-empty analysis.
- [ ] **Native Windows TLS fixture.** Seven `native_tls` cases fail since Git 2.56 moved the SDK to
      ucrt64; the trust install stays at `before_add`. Cause not proved.
- [ ] **Full Windows AHK suite.** Never completed green locally (about 90 min single-threaded);
      shard it, never raise `_SUITE_MAX_TIMEOUT_MS`.
- [ ] **Intermittent fixtures.** Close each after it stays green, root-cause a relapse from the
      logged attempt: Linux window switch, cffi-lua clone, desktop-webview AI focus, Windows
      `config` group (managed-network budget, artifact curl relay), macOS Go
      `TestIdleDeadlinePhysicallyRetiresPeer`, macOS Swift
      `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope` (failed once on macOS 26).

## Decided, do not re-raise

- **Delta updates (item 22)**: withdrawn by the maintainer; full signed downloads stay below 20 MB.
  Full signed, checksummed downloads keep one install and rollback path, without delta-base
  selection, patch rebuild or extra fallbacks. Reconsider only if release size or measured
  repeated-download cost grows.
- **Report a bug has no review screen**: the report is reviewable on GitHub (October 21).
- **Not defects after native review**: L48, L83 and the release-notes CR handling on Windows; L30,
  L85, L88 and L18 on macOS.
- **Configuration file style (October 20)**: `config.toml` keeps the 5/3 blank-line style everywhere
  (templates and the Windows writer); `windows/_generated/config_template.toml` changes only
  through `npm run build:manifest`; the release list and its ETag persist across restarts.
- **Credentialed redirects** are not followed, by design (L42).
- **Unsigned stable Windows releases** are authorised until SignPath signing is integrated (item
  132).
- **The AHK suite watchdog** is not raised to make a run finish; shard the suite instead.
- **Obsolete configuration scalars** are preserved until explicit cleanup; ordinary saves refuse a
  colliding subtree (ADR-009).
- **Unicode general categories and graphemes** are out of scope for the metrics character classes
  (L137); there is no Lua 5.4 AT-SPI backend, the FFI needs LuaJIT (L67).
- **A stored layout or number-row choice is never rewritten** by a layout change: where it cannot
  apply it stays ticked, greyed and suffixed « — non appliqué », and applies again by itself.
- **Moving the Karabiner lease token out of the rule text** is impossible: Karabiner compares
  variables only to fixed values. Fewer recovery deploys need fewer lease failures first.
- **Do not deduplicate the macOS Swift launcher XCTest classes between E2E and Build.** The managed
  native E2E cells run the SDK, logger and daily-log cohorts on macOS 15 (Apple silicon and Intel);
  Build's full Swift run repeats them on macOS 26 (`macos-latest`). Skipping them in Build saves
  about 42 s of 364 s of test time (measured 2026-10-20, run 39388400901) and nothing on the
  critical path, and drops their only macOS 26 coverage. Job, lot and step names state each cell's
  macOS version, read from `HOSTS` in `tools/ci/macos-stage-roles.cjs`.
- **Windows unit shards are grouped by test category, not by duration.** A new test file with no
  category fails a gate; a minute more of wall time buys a CI whose red job says what broke.
- **Maintainer workflow**: partial work is delivered into dev after the feasible container or CI
  work, with native or device gaps documented here rather than holding a branch.

## Questions for the maintainer

Each names the default kept meanwhile. Answer here; the agent then moves the decision into the item
or under "Decided, do not re-raise".

- **"Sticky" in French and Latin-script locales.** The sticky-modifier labels keep the English
  "Sticky", like the `menu.tapholds.sticky_*` strings. Use a French term such as « rémanent »?
- **Dutch "Rolls".** `category.rolls` and `hs_config.cat_rolls` keep "Rolls" (Dutch "Rollen" means
  "roles"). Another Dutch word?
- **A hand-written `config.toml` `[script]` row on macOS and Linux.** Windows reads `locale` from
  `config.toml` at start. macOS (`hs.settings` `i18n_locale`) and Linux (`storage.json`) read only their
  native alias store, so a `locale`, `log_level` or `show_error_dialog` typed into `config.toml` is
  ignored at start; only the Script scope writes both stores (`script_scope_runtime.lua`). Making
  `config.toml` win at start would switch most users back to French: installs copied
  `_generated/config_template.toml`, which ships `locale = "fr"`, while the wizard and the language
  menu persist only the native value. A safe change on both Lua drivers needs (a) every writer (menu,
  wizard) to write the `config.toml` leaf too, (b) one adoption at the first start of that build that
  writes the native value in use into `config.toml`, with a marker, and only then (c) the start
  reading `config.toml`. Kept meanwhile: the native store is the start authority on macOS and Linux.
