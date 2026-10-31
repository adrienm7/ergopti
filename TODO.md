<!-- TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-31. Latest stable: [v1.0.8](https://github.com/adrienm7/ergopti/releases/tag/v1.0.8)
(released 2026-10-30 from main; v1.0.7 was main 18d69a24c0). **Next step: the two machine lists below, the PC one on the
Windows PC and the Mac one on the Mac.** Open work only: a finished item is removed, its lessons go to
[docs/memory](docs/memory/README.md), and the history stays in Git
(`git log --follow -p -- TODO.md`). On 2026-10-31 every item was checked against the code and
`git log origin/dev`: the finished ones were removed, the others cut down to what is left, and duplicates merged
(the file before that pass is `git show 1aa287427a:TODO.md`; the one before the 2026-10-30 pass is
`git show 7f80d3d141:TODO.md`). Item numbers are stable and never reused. This file is the only
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

1. **Run what the cloud wrote without AutoHotkey.** Parse and the full AHK suite (`run_all.ahk`, then
   `e2e/run_e2e.ahk`) on dev, and fix what fails. Unexecuted so far: the field run, budgets and LLM latency line
   (`infra/field_run.ahk`, `infra/perf_budget.ahk`, `modules/llm/llm_request_latency.ahk`; e4ffacc709,
   8d52300169), the menu without dynamic rows (eeee484c6c, 65f298c3f7; the test list is in
   [the PC handoff](docs/tooling/windows-pc-agent-handoff.md)), thinking off and model capabilities
   (`model_capabilities.ahk`, the `think` spec of `vision.ahk`, `LLM_OllamaThink`), the per-account provider form
   and the access-token refusal (`test_llm_api_url_template.ahk`, `test_llm_api_add_account_address.ahk`), the owned
   Ollama daemon's proxy (743181a933) and the route plan twin (`vendor/ergopti_route_plan.ps1`).
2. **Field report.** Run `collect-windows-field-report.ps1` (Windows PowerShell 5.1, then `pwsh`) with
   `tools/dev/run-windows-dev.ps1` started, and the runtime layer of `test-windows-field-report-contract.cjs`; the
   expected files and refusals are steps 3 to 7 of the handoff's field run section. Push the report.
3. **Windows code left** (AutoHotkey, so the PC's): the [CODE] parts that name Windows in "Maintainer requests of
   2026-10-30" (provider token exchange), "Cross-OS parity" (PAR-53, PAR-58, PAR-63, PAR-74, PAR-76 R23, PAR-79,
   PAR-80, PAR-81, PAR-83), "Wave 2" (config cleanup offers) and the antivirus ceiling of "Windows side to do on the
   PC" below.
4. **Physical checks:** "Windows manual checks for the maintainer" just below and "Maintainer checks > Windows PC";
   report each line as pass, fail or not run.

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
2. **Open [PHYS-M] items of "Mac field session 2026-10-27: problem ledger > Open TODO"** below: L46, L24,
   L32, L42, L43, and "macOS main-thread holds" in "Maintainer requests of 2026-10-30" (ledger L16, L17, L18, L23).
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
   - `field_app_health` (after the AI steps): no crash report since the current app start (the launcher's
     `ps` elapsed time, `app_uptime_s`) in the driver's `crash_reports`
     folder (absent: none) nor in `~/Library/Logs/DiagnosticReports` for the app's processes (ErgoptiPlus and
     its launcher roles, Hammerspoon, Ollama, Python, Karabiner): they fail as `<process>:<count>`, the three
     newest are listed with closed tokens (hang or crash, exception, signal, termination namespace); an
     earlier start's reports of the last day and other apps' reports are counted only; the app's resident memory (MB) and CPU share from `ps` are named.
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
     `keystroke_to_tooltip_ms` (last key to tooltip) is named. Predictions the user turned off skip with
     `llm_disabled` (the check never turns them on). Failure codes: `no_installed_model`
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
   - `field_pac_fallback` (after the AI downloads): one `awk` pass over today's log counts the PAC-then-direct
     lines every writer prints (shell admission, Swift spool, Python receiver, Ollama pull):
     `pac_fallback_counts` is `warnings:worked:failed`, `pac_fallback_stages` the stages named;
     `pac_fallback_outcome` is `no_pac_failure` (information) on a network whose PAC works, passes as
     `direct_worked`, and fails on `no_outcome`, `direct_failed` or `unlisted_stage:<stage>` (a stage outside
     `proxy_policy.json` `pac_unavailable_fallback`).
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

- [ ] **Release notes leaked agent session links.** Done: `build_changelog.py` strips `Claude-Session` and
      `Co-Authored-By` lines and any `claude.ai/code/session_` link (0ba0e90580), and the convention lint flags the
      trailer. Left (maintainer decision): rewrite the bodies of the releases already published with such lines.
- [ ] **Ergopti's own Ollama on macOS starts.** [PHYS-M] The serve owner was opened (6170813ea9); the readiness
      failure of the 18:26 run (`native_child_status=64`) was the alias path handed to the launcher's API worker,
      fixed in 6335790e5a, with the metadata wait (894585a213), the pull's closed stdin (b71b4a67db) and named
      refusals (4545f672d1, 721074f21d). Left: the next field report shows the owned daemon ready and a pull done.
- [ ] **Field run downloads.** Done: e8ff7479e1 keeps the Ollama and MLX test models. Left [PHYS-M]: one complete
      download of each test model on a connection that does not count.
- [ ] **Field report marks.** Done on the three collectors (✅ ❌ ⏭️ ⌨️ ⚠️ and the "Check verdicts summary" line
      through the shared analyser). Left [PHYS-W] [PHYS-L]: one real run of each collector; the Windows runtime layer
      of `test-windows-field-report-contract.cjs` runs only where pwsh is installed.
- [ ] **Field run without a click on Windows and Linux.** [PHYS-W] [PHYS-L] Done: the shared protocol
      `_shared/data/field_run_protocol.json` (e5315ec576; `guard` kind and the refusal without a `request_id`
      declared in 29cb604df0), Windows `infra/field_run.ahk` with its steps and the collector side (e4ffacc709),
      Linux reading the same declaration (53c1766514, CI step "Run the field checks without a click"). Left:
      AutoHotkey never ran the Windows side (step 1 and 2 of "PC Windows todo"); a Linux run on a real desktop.
- [ ] **Field log analysis.** Done: `tools/dev/field-log-analyse.py` on every collector, the `[budgets]` section and
      the "Over budget" lines (8d52300169). Left: run `npm run test:hs` and `test:linux` where Lua runs and the AHK
      suite on the PC; [CODE] the Linux driver measures no reload or menu rebuild and the Windows one no menu
      rebuild, so those budgets are judged on macOS only.
- [ ] **macOS main-thread holds (field report `mac-2026-10-30_210120`; ledger L16, L17, L18, L23).** [CODE]
      [PHYS-M] Done: ledger admission with native finds (0b679b0b0d), the personal-row alias check indexed once
      (b5c0c0de37), the dynamic-rule preview guard (c17aa3e5d7), the slowest diagnostics collectors named
      (71a8b87f65), the keyboard-layout row stages timed (236ea82e52), a menu rebuild on an input-source
      notification only for a visible change (933707a1ae), the keystats journal published without forks (L16,
      016ef6adc5) and the deferred keystats start sliced (L18, 58f82e9fdc). Left, from the next field report: (1) the
      remaining menu rebuilds through the `menu_keyboard_layout.*` phases; (2) preferences save `sparse` (about
      280 ms) and `write` (600 to 800 ms, 4 metadata forks), not reproduced off the Mac (L17: the slow-save line
      names its prepare stage and `lua_heap`); (3) keystats append `write` 150 to 350 ms and the ledger read on the
      main thread (L16: no `Slow ingest tick` while typing, `worst_hold_site` in the field run); (4) the healthcheck
      collector behind 100 to 230 ms, and the ignored-window AX probe (L23, Issue #101 point 4): bound it once a
      `Slow ignored-window probe` line names the stage; (5) the one-off holds of `field_run`, `error_dialog`,
      `keymap/utils` timers and `menu_state` (shell.ioreg 146 ms); L18: `keystats_start_ms` under 100 ms.
- [ ] **Thinking off for every model on every backend and OS (merged with "Reasoning off in every AI request:
      verify the open rules").** Done on the three OS: model families of `thinking_off.json` crossed with each
      provider's dialect, the resolved Ollama `think` per family (98b9a2ad57), persisted and expiring refusals,
      default-only sampling, and capability listings skipping a control a model lacks (c1c8a9c181). Left: run the
      Windows suite on the PC (`model_capabilities.ahk`, `vision.ahk` `think`, `LLM_OllamaThink` are unexecuted);
      [CODE] verify the unverified families against their documentation: `grok-3-mini`, `hermes-4`, the generic
      name heuristic (`*qwen3*`, `*deepseek*`, `*-r1*`, `*think*`, `*reasoning*`), Together/Kimi effort, Fireworks
      DeepSeek, OpenAI `gpt-5-mini`/`gpt-5-nano`, Gemini 2.5 Flash image/TTS/audio.
- [ ] **Every known cloud AI provider in `api_providers.json`, on the three OS.** Done: about forty providers
      (official documentation read 2026-10-30, each descriptor's `_source`), the per-account providers whose
      `base_url` is a template (b5d321a4a3, form on the three OS), IBM watsonx.ai and Google Vertex AI with a token
      exchange on macOS and Linux (b56a4dc44d). Not added, with reasons in the commits: GitHub Models, Lambda, 01.AI,
      Aleph Alpha, Liquid AI, Writer, Tencent Hunyuan, BytePlus ModelArk, Cloudflare AI Gateway. Left:
  - Run the AHK suite on the PC (`test_llm_api_url_template.ahk`, `test_llm_api_add_account_address.ahk`).
  - [CODE] Windows token exchange (AutoHotkey, the PC's): Windows refuses watsonx and Vertex AI with
    `menu.llm.api_provider_token_exchange_unavailable`; port the async form POST and token cache of
    `api_token_exchange.lua`.
  - [CODE] The first prediction after start (or a key change) on an access-token provider is refused while the token
    is fetched; a Vertex service-account key (signed JWT) is not taken.
  - [CODE] The listing reader takes `data` (and `models` for Gemini) only: DashScope's native listing and Writer's
    `models[]` would need a per-provider listing shape on the three OS.
  - [CODE] With about forty providers, the Linux zenity prompt of the screen actions lists every one on a line.
  - Inferred, not read: Chutes and Featherless `chat_template_kwargs.enable_thinking` on Qwen, SambaNova
    `enable_thinking: false`, whether Qianfan `ernie-5.1` is hybrid. Watch: Perplexity Sonar chat completions
    (ended 2026-09-27, still answering), `dashscope-intl`, Moonshot K2 retiring by December.
- [ ] **Every known local AI server in `local_servers.json`, on the three OS.** [CODE] Detection is data-driven on
      the three OS (Windows `LocalServerPortsDescriptor`, macOS `llm.local_server_ports`, field step
      `field_local_servers`). Added (b459f5b6, each port and name cited from the project's sources in `_source`):
      SGLang 30000, KoboldCpp 5001, text-generation-webui 5000, GPT4All 4891, AMD Lemonade 13305 (its documented
      port, not 8000; `config.json` in `~/.config/lemonade` or `/var/lib/lemonade`), Docker Model Runner 12434
      (`/engines/v1`), exo 52415, and llamafile in the llama.cpp / LocalAI row; Linux detection proved on real
      stand-in processes, pgrep, ss and a settings file (99121ade). Left: (1) vLLM and TabbyAPI share 8000 with
      oMLX and 5000 with text-generation-webui, so a generic entry configured there would belong to two rows:
      choose one merged row per port (the oMLX label changes on every OS) or order-aware affinity in
      `local_server_auth.entry_matches`; (2) AnythingLLM always needs a key and takes a workspace slug as the model,
      Msty documents no port or dialect: both stay out; Foundry Local (Windows) and `mlx_lm.server` (macOS) belong to
      those drivers; (3) Windows: `test_local_server_auth.ahk` and `test_local_server_panel_view_preparation.ahk`
      count the four old servers and were not run: run them and read the catalogue; (4) the "none" row lists
      eleven labels; (5) [PHYS-M] [PHYS-L] one run with some of them installed.
- [ ] **Mac field report 2026-10-30 21:01, functional errors left open.** Fixed: shortcut full rebind on each
      retry, pre-dispatch Ollama pull receipt, one model-list error per outage, MLX server stopped before a repair,
      both schema versions named, the app-health census on an absent folder. Left, one line per family:
  - [PHYS-M] **Ctrl+. after a layout flip.** No "Some shortcuts are still unregistered" line after a "rebinding
    every shortcut (retry N)" line; if one follows, rebinding needs the `hs.keycodes.map` change notification.
  - [CODE] **Ollama pull refused while reading its request.** Such an exit leaves an empty receipt, so its task slot
    stays owned; passing the receipt path on the command line would let the owner publish that refusal too.
  - [PHYS-M] **Eventtaps refused at 10:07.** The errors now name `accessibility_trusted`; false means macOS withdrew
    the grant at run time.
  - [PHYS-M] **Personal hotstring reload rolled back (11:37).** The refusing step is now named; read it on the next
    failing save.
  - [PHYS-M] **MLX discovery after the 01:19 repair:** `/v1/models` answered but every POST route 404 for 340 s.
  - [PHYS-M] **Screenshot without an image (10:15):** an interactive capture with empty stderr would be an Escape,
    to be settled as a cancel.
  - [PHYS-M] **Keystats ingest "database is locked"** once at 20:52; the `quick_check` now opens `immutable=1`
    (8084562373): confirm it no longer appears.
  - Key events lost upstream: see L24.
- [ ] **Container note.** [CODE] `tools/test/test-managed-ollama-protocol.cjs` stops in a cloud container on Git's
      "dubious ownership" when run as a non-root user over a root-owned checkout; give the test its own
      `safe.directory` for its child Git calls.
- [ ] **Remap guardian killed at every developer start.** [PHYS-M] Done: an ad hoc build re-registers its guardian
      from scratch (2be257c9f5), `field_login_items` reports `guardian_registration`. Left: the next field run shows
      `developer_adhoc_reregistered`, no `ErgoptiPlus` codesigning kill in `field_app_health`, and `guardian_state`
      ready with a `guardian_wait` under 10 s.
- [ ] **Timed reload lost the app (2026-10-30 21:06).** [CODE] [PHYS-M] Done: the reload breadcrumb
      (`reload_breadcrumb.txt`, b12a654d79), the error window kept closed during a reload (02c58f8a94), a controlled
      reload bounded by its own deadline (c366dd1c5b); `driver_reload` stays disabled. Left: reload by hand from the
      menu until one is lost, run the collector, fix the stage the trail's last line names, then enable
      `driver_reload` again.

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

`git cherry -v origin/dev <branch>` on 2026-10-31, after removing those that landed under another id
(`tmp/wip-todo-ag`, `-ag2`, `-ae`, `tmp/wip-field-auto`, `tmp/wip-field-run-checklist` and 358e211a10 are on dev).
After the cleanup, read them through the `archive/tmp-wip-<name>` tags.

- `tmp/wip-todo-af`: 3337d99bc8 (Linux number-row order onboarding; it reads `number_row_live.available()`) and
  4fcb4a979a (logger scalar), then `tmp/wip-todo-ag3` d5cf3ba50b (its strings; it conflicts in the 21 locales unless
  the AF commits come first). 8634b1ff80 is superseded by dfb197a1ea; do not land it.
- `tmp/wip-todo-ah`: 53b1bc5375 (reset every `hs.*` cache entry between macOS test files) and five CI speed-ups
  (Ubuntu archive reuse, AHK shard split, one macOS checkout per E2E cell, Intel E2E start, SwiftPM cache trial); run
  them on `tmp/preflight-dev` before dev.
- `tmp/wip-ci-fix`: f44fcc1e64, c9b90d11d7, ba13937b8c, 5009ad87b8 (Linux distribution-row CI fixtures): check each
  against dev first, later fixes may have replaced them.
- Reference only: `tmp/wip-issue103` b449da5713 (an old reseal), `tmp/wip-issue104` aec2fb58cb (replaced by
  2be257c9f5), `tmp/wip-fr-uncommitted` 0d7e53b28b (replaced by 708bc6671d), `tmp/wip-todo-ae-par30` 41f72525cf
  (the PAR-30 Linux gate landed as cd824ccf8e).

## Linux open items from the July plan

The July Linux driver plan (X11/Wayland hotstring engine, 2026-07-30) is retired; its rejected gesture routes are in
`docs/memory/rejected_proposals.md` and the ungrabbed-touchpad limits in `docs/memory/linux-web-release.md`.

- M3.3: [CODE] the tray menu is split into one module per section (`ui/menu/menu_*.lua`, 2026-10-30 and 31, gates
  read the root through `tools/lib/linux-menu-parts.cjs`). Left: renaming or deleting the root itself
  (`require("ui.menu.menu_builder")` callers, `CURRENT_SOURCE_RETIREMENTS` in `test-native-menu-rows.cjs`, the
  `linux_evidence.json` paths); a part may import only what the root holds, so hoisting the root's part-only
  imports needs `closedModuleExport` in `tools/lib/menu-native-llm-parent-binding.cjs` to follow the parts.
- Gestures [PHYS-L]: the menu greys the slots out of reach and the reader start names them (d627f511fc); recorded
  `libinput record` traces replay into the decoder (1870e62e1a). Left: a three-finger pad on a real machine and one
  recording from a real touchpad (`linux/HARDWARE.md` section 13).
- Navigation layer wheel bindings run on Linux (ea4b3fa600). Left [PHYS-L]: a real mouse on a real desktop (pointer
  speed under the hold follows the virtual device's libinput settings).
- Remote API keys in the desktop secret service (e93a4f7368; `install.sh` installs `secret-tool`). Left [PHYS-L]: add
  a key with the keyring locked and check the unlock prompt takes the keyboard under the grab, then restart and check
  the plaintext migration of an older `api_keys.json`. The deb, rpm, Arch and Nix packages depend on it (939c0f60).

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
- Linux (from its closeout): physical acceptance (evdev/uinput grabs, polkit, autostart, Wayland/X11) still needs a
  real machine.
- CI: the macOS 26 "Run Swift launcher tests" step hit its 10-minute limit twice on 28 October, in main run
  40764020578 and fix/macos run 40765470617. `HomebrewArchiveAcceptanceTests` alone took 289 s, and a real PAC
  trust test was still running at the limit. Move the real-network cases into their own job, or raise the step
  budget with a measured reason.

## Mac field session 2026-10-27: problem ledger

Problems seen on the maintainer's Mac on 2026-10-27 and 28 (macOS 26.6.2, arm64; issue
[#104](https://github.com/adrienm7/ergopti/issues/104) and the `field/mac-2026-10-27` reports). Labels are local to
this ledger; a label cited elsewhere without an entry here was fixed (its entry is in `git show 7f80d3d141:TODO.md`
or `git show 1aa287427a:TODO.md`). L16, L17, L18 and L23 moved into "macOS main-thread holds", L25 and L28 into the
Mac todo's Composer (L52) line, L26 into L42, L27 into L43.

### Open TODO

- **L46** [PHYS-M] Two-finger scrolls switched tabs through the vertical three-finger swipe. Code done on dev
  (6d3aa65273, then frames timed by the touch device's capture stamp, momentum arming the scroll guard only after a
  scroll the blocker let through, the 4 -> 3 -> 2 cascade, and one action per 25 units in incremental mode); every
  refusal logs `Three-finger candidate rejected by <gate>`; `field_gesture_frames` proves the capture stamps. Linux
  shares only the frame clock (kernel SYN_REPORT stamp); Windows uses the precision touchpad driver. Left: the three
  L46 lines of "Maintainer checks > Mac", with no explicit `[gestures.sensitivities]` swipe_3 value in
  `config.toml`.
- **L24** [PHYS-M] key_event_health: late key events (max 879 ms), key-downs without key-up and key-ups without
  key-down, keys stuck over 3 s (10-27; again in the 10-30 21:01 report until 15:32, next to main-thread holds and
  Karabiner lease failures). Every timer hold from 250 ms is named (82c220c089). Left: re-read the totals once the
  holds of "macOS main-thread holds" are gone; lost key-ups without a hold point at the Karabiner virtual HID path
  (big item 2, "Dropped letters on macOS").
- **L32** [CODE] [CI] Permissions read `unknown` and 843 MB resident (issue #104). Done: the schema enum
  (cce99afbc7), Input Monitoring through the launcher role `--input-monitoring status` (58961fd2b2, f7faaa0558).
  Left: the macOS Build stage compiles and runs its XCTest; the resident size breakdown.
- **L42** [PHYS-M] 03_field_network off the company network: the route stage, the URL-free warning, the PAC fallback
  verdicts (`pac_download info:unreachable_direct`, `pac_script skip:not_fetched`) and the route kind marker
  `route_lookup pass:selected:direct` are in code (5d93e78e90, 1dfaec8298, ec15345d22, 8fedb505dd). Left: off the
  company network 03_field_network passes with those values (the macOS Build stage must compile the marker).
- **L43** [PHYS-M] 04_field_toolchain `karabiner_signature`: the cause is a `com.apple.FinderInfo` xattr on the
  bundle root while Gatekeeper accepts it (Notarized Developer ID, team G43BCU2T37), now
  `info strict_only:finder_detritus` (cc172a504d, 58fd867081). Left: 04_field_toolchain passes with those values.

## Windows side to do on the PC (from October 25)

- [ ] **Review the Windows antivirus surface ceilings (27 Oct).** [CODE] d7d98e133b raised the exe bundle's
      DllImport ceiling in `tools/ci/windows-exe-av-surface.json` from 52 to 54 for the two staged-file custody
      P/Invokes of `vendor/ergopti_updater_download.ps1` (`CreateFileW`, `GetFileInformationByHandle`). Check whether
      a bundled type already declaring them could be reused, then lower it back. (`key_state_polling` is lowered to
      59, 582e8dd12e.)

## Big item 1: Windows corporate networks and trust (items 62, 132)

- [ ] **62. WinHTTP transport for the managed remote downloads.** [PHYS-W] Done (1d15b51e66, 7c001b2456 and the
      following commits): managed requests, updater artifact download and Ollama archive download use WinHTTP;
      proven on the PC against owned loopback services (SSPI NTLM and Negotiate proxies, CONNECT, untrusted TLS,
      bounds, deadlines, PAC failover). Left: the native CA cases (a click on the Windows security warning or an
      elevated LocalMachine scope), enterprise acceptance behind a real proxy/PAC (Kerberos, TLS inspection,
      revocation) through Debug > diagnostics (`github_api`, `proxy_pac`), and item 36 (external trusted binding).
- [ ] **132. SignPath Foundation signing (merged with "Signing and antivirus: maintainer actions").** Done: SignPath
      wired in `ci-windows.yml`, off until configured (61fb29d64d); README code signing policy and privacy
      (c6db589c76). Left (maintainer): apply at signpath.org/apply (the HubSpot form does not load in an automated
      browser; answers in [signpath-foundation-application.md](docs/tooling/signpath-foundation-application.md)), then
      set the variables and secrets, then [CODE] delete `.github/ci/stable_windows_signing_exception.json`.
- [ ] **`ErgoptiPlus.exe` flagged by a corporate proxy (Netskope, Airbus tester).** [PHYS-W] Done: no hidden
      PowerShell clipboard stage, own version resource, English metadata, tar.exe extraction, no keylogger naming,
      string-surface ceilings and a per-build record with the exe SHA-256 in CI, the submission pack
      [windows-exe-false-positive-submission-pack.md](docs/tooling/windows-exe-false-positive-submission-pack.md).
      Left (maintainer): signing (132), VirusTotal lookup, Microsoft Defender and vendor submissions, the tester's
      block page and retry (T1-T4); decide whether the `WH_KEYBOARD_LL` probe in `input_probe.ahk` stays in the
      release exe. Playbook: [handoff](docs/tooling/windows-exe-flagged-by-proxy.md).

## Big item 2: macOS Karabiner input reliability (items 31, 117, 140)

- [ ] **117/140. Karabiner lease failures on Apple silicon.** [PHYS-M] Exit 73, PONG/READY timeouts since dev.155.
      Lease budgets ordered, every exit 73 named, each deploy decision one INFO line, the 13 s lookup gone, on-time
      deadlines wait for a `/bin/cat` echo (25411ee080), every lease failure logs the free memory and the field run's
      lease check names `lease_failure_kinds` and `memory_free_percent` (380ad99aa8). Workaround: Configuration >
      Ergopti uses Karabiner > Off. Left: send a field report; a low free percentage next to the PONG/READY kinds
      confirms starvation.
- [ ] **Dropped letters on macOS (merged with "macOS swallowed-keys check on v1.0.6").** [PHYS-M] Unproven. Every
      consumed and never delivered key is reported ("typed key(s) swallowed"), the v1.0.6 fixes shipped, and the
      field run fails `swallowed_keys` on any such key and carries the `key_*` counters. Left: a Mac day of typing,
      then the field report; Debug > Report a bug right when a letter disappears.
- [ ] **31. HS-274 exact physical key accounting with an owned Karabiner runtime.** [CODE] Work packages WP3-WP10
      (production consumer, headless producer v2, reproducible runtime, launchd ownership, owned configuration, native
      and real-Mac acceptance, enable and retire); media keys without a macOS keycode; VirtualHIDDevice
      incompatibility blocks owned mode with an explanation. Plan:
      [ADR 011](static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md). Estimate 30-40 agent-days plus hardware
      time. Status 2026-10-24: WP3 largely done and dormant; WP6 Lua owner and WP7 owned deploy done, dormant behind the
      hidden `[karabiner] runtime = "owned"`. Left: WP5 artifact manifest (hosted macOS run), a closer for another
      running Karabiner, the production capture owner, the Swift lease worker's owned CLI path, who starts the Console
      (Lua or `InstalledPhysicalSourceBridge`), `UninstallWorker.swift`, the karabiner_model diff 16.0.0 to 9312593e,
      WP8-WP10. The maintainer's decision of 27 October makes it the default (see "Owned, pinned third-party
      runtimes").

## Big item 3: Windows input-hook architecture (items 49, 91, 50)

- [ ] **49. Keyboard-hook order.** [PHYS-W] Measured on the PC (2026-10-24): SendInput reinstalls the AutoHotkey
      hook in front of any hook installed earlier, SendEvent does not. The remaining SendInput consumers (text
      sender, HSE dispatch) stay on SendInput, decided per site in
      [windows-input-hooks.md](docs/design/windows-input-hooks.md) (e51954e38b), with a gate on any new direct
      SendInput. Left: the terminal-capture hardware list; the single-hook/RawInput source is item 91.
- [ ] **91. Simultaneous and first-key hold arbitration.** [CODE] Integrate with the single-hook/RawInput source
      (needs a genuine MSVC DLL and manifest pair, regenerated only through the official MSVC generator); [PHYS-W]
      held-alone-then-joined order, AltGr hook provenance.
- [ ] **50. SendEvent against SendInput.** [PHYS-W] [PHYS-M] [PHYS-L] Measured on the PC: SendInput is faster
      (expansion 50.6 against 136.8 ms) and exact; all engine output goes at level 0; deliberate cascading is built
      (`hotstrings.cascade_max_arrows`, default 3). Left: on each OS type `fb` + Space, Enter and ★ with the
      abbreviation and brand packs, at 1, 2 and 3 arrows, consumed and not.
- [ ] **Per-layer layout composer.** [PHYS-W] [PHYS-M] [PHYS-L] Done on the three OS
      (docs/design/layout-composer.md), with the one-click Debug "Test the composed layout". Left: typing the
      composed layout on a real keyboard on each OS.

## Wave 2: mid-size work

- [ ] **Config policy (items 33, 42; merged "Windows config policy and the TOML parse cost" and "Config policy
      remainders").** [CODE] [CI] [PHYS-L] Done: the Windows keyboard binding publication, the macOS Karabiner
      obsolete-leaf intent and category authority, the Windows retired cleanup projections (with the inline-table and
      case-twin rows, e87aaee230, 68d5ed4c3e), the Linux `--config FILE.toml` watcher, `api_entries` retired rows and
      the Windows per-row warning (9557069d66), parse cost (e525cd6615), the Linux reload as a daemon restart (proven
      across real processes and on the systemd unit path). Left: [CI] native macOS qualification of the Hotstrings
      category boot publication and of the obsolete-leaf setters; [CODE] (Windows, the PC's) the cleanup still cannot
      offer bare root keys or unknown `[[x]]` generations, and the physical keyboard slot parameters
      (`keyboard__win_SC03A__x`); [CODE] the Linux symlink watcher case under a real luaposix `posix.stat`; [PHYS-L]
      one daemon restart under a real user manager on a real session.
- [ ] **Ollama redirect policy and Go compile (decision 5).** [CI] Code done (cda1e10c5e); the hosted Go cell passed
      on a throwaway branch (run 40021624397). Left: the same cell on the final source before a release.
- [ ] **Ergopti-started Ollama behind a PAC proxy (merged with PAR-71).** [PHYS-W] [PHYS-M] Linux done (89d22d782c);
      macOS in code (launcher role `--managed-proxy-route`, per-origin route plan, field step
      `field_ollama_blob_host`); Windows: the route plan is ported (`vendor/ergopti_route_plan.ps1`), wired into the
      owned daemon start (743181a933), and the curl relay names and the healthcheck PAC limit read `proxy_policy.json`.
      Left: a real-PAC pull on the Mac (Debug > Test network) and on the PC; maintainer decision: an option for
      NTLM/Negotiate relays (a local authenticating forwarder, or none; today such a relay is never exported and the
      pull refuses with `network.failure.proxy_windows_login`).
- [ ] **PAC unusable: direct fallback.** [PHYS-M] [PHYS-W] [PHYS-L] Done on the three OS: macOS (`network-retry.sh`,
      Swift spool and worker, Python receiver), Linux for the Ollama daemon start (50b424b997, afc7fa23db), Windows
      `ergopti_network_routes.ps1` `New-ErgoptiPacDirectFallback` (d20d328751); an explicit inherited relay wins and a
      relay the PAC names that then fails is not retried direct. Left: on a network whose PAC is unreachable, an
      Ollama pull and the MLX install (Mac) log the WARNING with the stage, then the direct success line; the same pull
      on the PC and on Linux; maintainer decision for Linux: following a PAC list such as `PROXY a; DIRECT` needs a
      reachability probe of `a` before the daemon starts (today only its first entry is kept).
- [ ] **AppImage self-contained.** [CI] Built on ubuntu:22.04 (glibc 2.35 floor, no bundled libc or loader, foreign
      loader refused, dce846a0bd). Both rows reproduced in a container on 31 October (Docker, registry mirror,
      proxy CA in the image): the build gives the 16 MB image and its `.zsync`; unpacked `--help`, the glibc ceiling
      (42 ELF files at most GLIBC_2.35) and the library closure pass; the catalogue smoke shows the XEmbed tray, the
      status window and the menu on buttons 1 and 3 (`/dev/fuse` must be 0666, as on the runners); the 11-image
      sweep runs on Ubuntu 22.04 to 26.04, Debian 12 and 13, Fedora, openSUSE Leap and Arch, and refuses in words
      on Debian 11 (glibc 2.31) and Alpine (musl). Left: the hosted run itself.
- [ ] **Linux X11 window list.** [CI] `getAll()` covered by the Openbox receipts (962a25a973), passing on Xvfb and
      Openbox in a container. Left: the first hosted run; Flatpak: wmctrl is only a documented host program.
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
- [ ] **PAC unusable: direct fallback (maintainer decision).** [CODE] [PHYS-M] macOS done on dev
      (7634296b28, cbaa14ad46, 7af4e65b10): when the PAC or WPAD route lookup fails at a stage listed in
      `proxy_policy.json` `pac_unavailable_fallback` (PAC download, evaluation, WPAD discovery, lookup
      budget, empty route), `network-retry.sh`, the Swift spool and native worker, and the Python
      receiver go direct (no relay, loopback exclusions kept) with one WARNING naming the stage, then
      log that the direct connection worked or an error naming both causes; the Ollama pull shows
      `network.failure.pac_unreachable_direct_failed`; the Debug network check reports the lookup as
      `info direct_pac_download` (or the stage met). Decision: an explicit inherited relay
      (`HTTPS_PROXY` and the others) wins and never falls back; a relay the PAC names that then fails
      is NOT retried direct (only the PAC's own list, such as `PROXY a; DIRECT`, is followed), on
      every OS. Mac: the field run proves it with no hands, `field_pac_fallback` (the WARNING with its stage,
      then the direct success line or the two-cause error, after the field run's own Ollama and MLX downloads;
      `no_pac_failure` on a network whose PAC works) and `field_network` (the `route_lookup` info step); left
      [CI] the Swift change compiles in the macOS cell. Linux follows it for the Ollama daemon start (fe9199b9, 838af0c0:
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
at 49c62d77a1 (`docs/audits/2026-10-24-cross-os-parity.md`; "audit test item N" refers to
`docs/audits/2026-10-18-test-parity-audit.md` there); entries are `PAR-1` to `PAR-85`, stable ids. Most entries are
done (see git log; the Windows ports landed on 2026-10-30); the list below is what remains. Physical checks of
PAR-12 and PAR-14 are in "Windows manual checks for the maintainer", PAR-15's in "Mac hardware session".

### A. Behaviour that differs without a good reason (fix first)

- [ ] **Review the machine translations of October 25.** [I18N] New keys (gesture recommendation notes,
      cascade depth, tap-hold defaults, missing-program messages) are hand-written in French and
      machine-written in the 19 other locales.

### B. Missing features on one OS

- [ ] **PAR-30. Sign the Windows and Linux update assets.** Done: signatures, verifiers on Linux (OpenSSL) and
      Windows (CNG), CI signing, and the Windows install path checking the signature before any download
      (fe5a1c2340). Left (maintainer): provision the key (five steps in `docs/tooling/update-signing.md`), one release
      with enforcement `"off"`, then [CODE] flip it to `"required"`.

### C. UI-only gaps, reasons and docs

- [ ] **PAR-41. One shortcut data model.** [CODE] Done on the three OS (schema migration of the slots, role-named
      keyboard slots on Windows: 7b09ad75b2, 141494ee23). Left: macOS `ctrl_g` to `open_url`, later.
- [ ] **PAR-52. Release notes on the update windows.** [PHYS-M] [PHYS-L] Done on the three OS (Windows f5786f5399).
      Left: a visual check on a Mac (in the Mac hardware session) and on a Linux desktop.

### D. Instrumentation and diagnostics

- [ ] **PAR-53. HotPath slow-segment logging.** [CODE] Done on macOS and Linux with nesting attribution, and the
      Windows floor read from `[logger] hotpath_slow_ms` (9160506857). Left (Windows, the PC's): Windows prints the
      exclusive time but still judges and reports on the wall clock (`_HotPathNestedMs` in `hotpath_profiler.ahk`).

### E. Tests and corpora

- [ ] **PAR-58. Windows consumer for the shared Lua contracts.** [CODE] Windows now replays the config scope plan,
      TOML leaf, inline scalar and batch writer (83 of 144 agreeing, c460a2fc3e), hotstring reader, numbered caption
      and row order vectors, and part of `corpus/menus/`. Left (the PC's): the rest of the `menu_*`/`menus` families
      and the 61 batch writer vectors that disagree.
- [ ] **PAR-63. Remaining 2026-10-18 test items.** [CODE] Done on Linux and macOS, and the `tests/` trees ratcheted
      (8a349463fc). Left (the PC's): Windows dynamic-hotstring behaviour tests (rule families, dates, a wider replay of
      `dynamic_hotstrings/prefix_vectors.json`) and moving the Windows root runners (`run_*.ahk`) to `tests/runners/`
      (audit test item 3 and the test-layout step 3).

### F. Centralisation and hexagonal architecture (value order)

- [ ] **PAR-73. Collapse generated per-driver artifacts.** Done: `[hs_timeouts]`, `action_catalogue.lua`,
      `features_manifest.lua`. Left (maintainer decision): `config_template.toml`.
- [ ] **PAR-74. Config-key and command-id constants by codegen.** [CODE] Lua, shared Lua, JS and Node done; Windows
      reads its menu, module, infra and UI keys from `windows/_generated/config_keys.ahk` (9e11b4b371, 94b5fd2e67,
      0839388a8b). Left (the PC's): 639 AHK literals in 82 files of the shrink-only
      `tools/lint/config-key-literal-baseline.json`.
- [ ] **PAR-76. Long refactors.** [CODE] Done: R17 (the AHK op table generated, c95a93ed00), R18, R25 (vectors on
      the three OS, 513846de6a), R26 and R33 on the three OS (Windows bc311516d0, 917745c073, e424583c43). Left (the
      PC's): R23, the AHK `.keylayout` reader (`keylayout_parser.ahk`) following the canonical form the Lua parser
      reads.

### G. Constants, delays, colours, labels (value order)

- [ ] **PAR-79. Replace repeated timer literals with registry keys.** [CODE] Lua and JS done; AHK moved to the
      registry (e7a548149f). Left: the 36 AHK sites left in `tools/test/timer-literal-baseline.json` (the PC's) and
      about 37 `usleep` calls in the Swift launcher sources.
- [ ] **PAR-80. `[limits]` section for byte caps.** [CODE] Done, with the AHK process output caps (daedb449ce) and
      `MAX_BODY_BYTES` reading `[limits]`. Left: the eight Lua constants of `tools/test/limit-literal-baseline.json`.
- [ ] **PAR-81. Theme tokens and palette codegen.** [CODE] Done, with the Windows palette from the generated theme
      (1a53f8ccc5). Left: moving the literals of `tools/lint/hex-literal-baseline.json` (40 files, mostly CSS and
      TOML) onto tokens with per-page pixel diffs.
- [ ] **PAR-83. Identifiers and hosts in one file.** [CODE] Lua and AHK (944ae6b5e6) generate from
      `_shared/data/identifiers.json`. Left: the copies of `tools/lint/identifier-literal-baseline.json` (Swift 19, JS
      15, Python 9, native headers 8, shell 6, AHK 3, PowerShell 2, Lua 1).
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
      shrink-only baseline. Emitters exist for JS, shell, Python, AHK and Swift; the JS pages, the macOS
      Lua and Python sites and the launcher constants read them (33600679a4, db7bc54668 [CI: Swift]). Left
      (`tools/lint/identifier-literal-baseline.json`): the AHK copies; the macOS owned-runtime Swift files,
      whose signing ids are derived from the launcher id (`.runtime-installer`, `.installed-physical-source`,
      `remap.core`/`console`/`cli`: declare them in `identifiers.json` first, which regenerates the Windows
      AHK copy) and whose `OwnedRuntimePublisherIdentity` raw values must stay literals (pin them with a
      test instead); the Swift test fixtures' app names; the runtime shell scripts
      (`ensure-ollama-deps.sh`, `_shared/.../ollama_install.sh`, `linux/install.sh`, the generated
      `managed-python-release.sh`), for which `test-shell-identifiers-sourcing.cjs` accepts only the
      build scripts' repo-root sourcing form; `Package.swift` (a SwiftPM manifest cannot read sources);
      the `tools/` build scripts.

## Backlog (one line each)

- [ ] **Windows: a personal immediate `sru` -> `SRU` (priority 100) loses to the bundled `sru` -> `sur`.** [PHYS-W]
      Fixed on the three OS (4741950f04: Windows forgets a final output at commit, a final entry whose output equals
      the typed text claims it, an immediate correction yields to a waiting final entry of higher priority). Left:
      the manual check line on the PC.
- [ ] **macOS cold official-Ollama lane.** [CI] since bc09e4584c no product path calls the stock
      `ollama_deps_checker.install_for_selection()`, so the macOS "official cold Ollama without stock Python" lane only
      proves the official installer still works cold. Repoint it at the native install or retire it.
- [ ] **"Create a GitHub issue" button is broken.** [PHYS-W] [PHYS-M] [PHYS-L] Fixed on the three OS (4e63c54c8a:
      4000 bytes, which holds even through the signed-out `/login?return_to=` re-encoding; measured anonymously).
      Left: a click while signed in opens the prefilled form with no "Whoops" page.

Added October 22 (from the agents' reports; details in their commits):

- [ ] **Keystats rename leftovers.** [CODE] The rename is done (180a53e4de). Left: declare each persisted name once
      and make tests read it instead of pinning spellings; the Encryptor `main.scpt` comment is a Mac line of "Mac
      hardware session" (7. Edge cases).
- [ ] **Issue #101: Mac follow-ups.** [CODE] [PHYS-M] Fixed, to confirm on the Mac: the ATS key for an `http://`
      company PAC, direct route when the PAC names none, no retry of a refused route, the lookup's failing step
      named, the lease line cap, the Ollama 412 upgrade request, the diagnostics PAC probe. The field run answers (1)
      (`field_slow_lines`) and (3) (`field_local_servers`); (4) is in "macOS main-thread holds"; (7) is "PAC
      unusable: direct fallback". Left [CODE]: (2) an explicit proxy override field; (5) rebuild the inverse oracle
      of `macos_native_http_receiving_facts_test`, compile the Swift on macOS CI, add Go table cases for the new
      stages; (6) the network check's digest step is skipped (HEAD only).
- [ ] **macOS input follow-ups (swallowed keys).** [PHYS-M] Done: late keys pass through, AXValue read once per burst,
      no error window for a lease failure that recovered within 60 s, `key_*` counters; lease token reuse refused (ADR
      012). Left: the field run's lease check names `deploy_write_ms` and `deploy_kb`: if the write is long, shrink
      the 743 KB `karabiner.json` instead.
- [ ] **Developer mode on the three OS (maintainer decision, 27 October).** [CODE] [PHYS-W] [PHYS-M] [PHYS-L] Done:
      macOS `bash tools/dev/run-macos-dev-app.sh`, Linux `bash tools/dev/run-linux-dev.sh`, Windows
      `tools\dev\run-windows-dev.ps1`; inventory in `docs/design/developer-mode.md`. Left: (1) [PHYS-W] the
      `run-windows-dev.ps1`, `npm run dev:windows` and double-click lines of "Windows manual checks for the
      maintainer" (expected Debug lines: "Developer source mode; the driver runs from <clone>\static\ergopti_plus\windows
      (clone root from the developer variable)" or "(clone root from the script location)", then "Developer source
      watcher started"; a second source run yields after about 3 s with a "single-owner mutex" WARNING; Start at login
      in this mode is a developer run too, by decision); (2) [PHYS-M] the Mac hardware session covers macOS; (3)
      [PHYS-L] on a real desktop with the package installed: the unit is stopped, the tray appears, a saved `.lua`
      restarts the daemon, the tray's Reload restarts it, a second `run-linux-dev.sh` reports "already running"; (4)
      maintainer decision: should the layout catalogue fetch the remote registry in a developer run (today the clone's
      registry, by design of `local_source`); (5) [CODE] `bin/ergopti-hotstrings` run from a clone still prefers
      `/usr/lib/ergopti` when a package is installed; fix or retire that branch.
- [ ] **macOS swallowed-keys check on v1.0.6.** [PHYS-M] The fixes (03a2c2fa4b, d026f3e024,
      a414e83fb7, 19fa9fa872, 89cbcae90b, 9b500a9e8c, c21e920d7e, bb6fcc2cc2) shipped in v1.0.6;
      they need a Mac day of typing with the `key_event_health` counters (`infra/key_event_health.lua`,
      written to the driver log). _Hands:_ the day of typing. Once typed, the field run's
      `diagnostics` step carries the `key_*` counters and `field_event_taps` the late keys of the
      session, so no reading by hand is left.
- [ ] **Keystats rename leftovers.** [CODE] The rename is done (180a53e4de, 1 283 files, 579 paths). Left:
      the comment in `macos/apps/Encryptor.app/Contents/Resources/Scripts/main.scpt` (a compiled
      script: `osadecompile` it, edit the comment, `osacompile -o` it back, on a Mac); persisted names
      read from their one declaration: macOS metrics state names (9dc1404758), the Linux topical log
      file (from the generated sub-file table); left [PC] the Windows tests' spellings.
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
      30 October the field run's lease check names `deploy_write_ms` and `deploy_kb`, and its
      `deploy_write_verdict` decides: `keep` under the 250 ms key-delaying hold
      (`infra/main_thread_hold.lua`), `shrink` (fail) from it on; only `shrink` leaves code to write
      (make the 743 KB file smaller).
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
      installs and runs its own pinned Ollama, MLX environment, Karabiner runtime and any other third-party runtime,
      and never uses, stops or modifies the user's copy. Ollama: done on the three OS (next item). MLX: already
      Ergopti's own. Karabiner on macOS: item 31 as the default, with the rule: tap-hold on quits the user's Karabiner
      and runs ours; tap-hold off with theirs present never activates ours (rewords ADR 011 decision 3). WebView2
      stays the system copy, with a version check and a clear refusal. Left: item 31, and the inventory of every
      external tool on Linux and Windows (ydotool, xdotool, wmctrl, curl, Python, PowerShell modules, WebView2) with
      a decision per tool.
- [ ] **Ergopti's own Ollama on Windows and Linux too.** [PHYS-W] [PHYS-L] Done in code on the three OS (Linux
      32fa07be7f, Windows f016081056 and 597cbbe983: owned port `llm_ollama_owned_port` = 11435, 11434 refused, only
      the owned runtime launched). Left: with a system Ollama on 11434, Ergopti's listens on 11435 and the other is
      untouched (Linux: enable the AI from the menu on a machine running `ollama serve`).
- [ ] **Ctrl+Caps Lock slot on macOS.** [PHYS-M] The `secondary_capslock` slot binds through its own native entry
      (ea02cf7000); the field run judges it from the session's own keys (`field_capslock_chord`: `delivered:N`,
      `never_delivered`, or a skip with none typed). Left: type Ctrl+Caps Lock during a session before the field run;
      on `never_delivered`, drop the slot's recommendation on macOS with a reason.
- [ ] **Layout emulation on macOS and Linux through one generated `.keylayout`, live (maintainer request, 27
      October).** Decided: no pre-generated variants; the menu options produce one custom `.keylayout`, the source
      the three OS share (Windows emulates it, macOS installs it, Linux converts it to XKB), built on the per-layer
      composer. Done in code: (1) the number-row options (ordering `layout.direct_access_digits` and edges
      `layout.number_row_reorder_edges`) rebuild the installed registry or composed `.keylayout` on macOS
      (`layouts/keylayout_rows.lua`, 91725b18f7, fc5d3a11df) and on Linux (`modules/keymap/number_row_live.lua` ->
      `layout_registry.apply_rows`, Ctrl, AltGr and dead keys kept); (2) a live replace with no logout: macOS writes
      each build under a new id, enables, selects and reads it back from a fresh process, then retires the previous
      one (aaf3518af7); Linux loads it on X11 and GNOME/KDE Wayland through two alternating slots, accepted only on
      the cells read back (dbe176e52b, 9b0a205029); (3) the scope participant settles on that read-back on both
      (dfb197a1ea on Linux). Left: [PHYS-M] the next field report's `field_layout_rows` answers M4 to M6 (on
      `select_refused` or `requires_logout` the live path needs the in-bundle route of the design note), and choosing
      an option in the menu and typing with it; [PHYS-L] W1 to W4 of the design note on a real GNOME and a real KDE
      session, and typing on a physical keyboard; [CODE] the Bépo base needs a Bépo `.keylayout` in the registry (none
      exists); the onboarding control is 3337d99bc8 on `tmp/wip-todo-af`. The row switches (`layout.emulate_*_row`)
      stay Windows-only: they mix Ergopti rows with the OS layout, which has no `.keylayout` source on macOS or
      Linux; an Ergopti bundle source types digits on both levels, so its rows stay greyed on macOS.
- [ ] **Linux CI installs packages inside short test steps.** [CI] Every Linux test step now has its own install
      step (17e80f2882). Left: hosted validation.
- [ ] **History hygiene of October 22.** Commits with another agent's message, already on dev: c6db589c76 (macOS
      cipher argv fix under a README subject), 90da28c725 (config snapshot test under a CI subject), 18ca214ead (also
      deletes ten handoff files), 6d9c659 ("applied for now" instead of "apply now"). Keep, or rewrite dev once with a
      lease: maintainer's call.
- [ ] **36. Windows updater production coupling.** [CODE] The "original23" collector stays inactive until enrolled;
      its source preparation stays in Git (`49c62d77a1:docs/handovers/2026-10-12-group6-ci/`). Missing: the first
      trusted PowerShell host acquisition (a pre-host native binding with an approved image contract).
- [ ] **62 (macOS and Linux).** [CI] Packaged paths resolve every request and redirect natively; the Go twin runs in
      the `network-ai` cell; the installed Linux route plan is proven against a real PAC (c0a50b5e41, CI step "Qualify
      the installed managed Ollama route plan"); the Mac blob host is the field step `field_ollama_blob_host`. Left:
      the first hosted run of the new step.
- [ ] **CI duration** ([target](docs/memory/workflow-and-verification.md)). [CI] Flatpak runtime cache and a bounded
      retry are in (07a601c97e plus the retry commit); confirm on a hosted run (target under 5 min). Windows
      Integration still adds 4-5 min on the critical path; the macOS lane (about 58 min) must stay within the
      five-runner budget.
- [ ] **CI structure.** [CODE] Slowest-test summary and `tools/ci/run-timing.cjs` shipped (e1aa4a5f48, cab1170446).
      Left: a per-step elapsed summary inside the CI run itself.
- [ ] **Test parity across the drivers.** [CODE] Done: Windows CapsWord behaviour tests, dynamic hotstrings, the
      shared HTTP-redirect corpus on Windows (c64788227a), macOS audit-named tests renamed, neutral-installation gate,
      many Windows source scans turned into behaviour tests on 2026-10-30. Left: Windows replay of the timer-ceiling
      and key-chord corpora (needs a decision to build those policies on Windows), and the rest of the source
      assertions to behaviour (audit item 14).
- [ ] **116. Guided third-party validation report.** [PHYS-M] `field_toolchain` runs it with no person (timer,
      Shortcuts, Homebrew, Karabiner signature and Gatekeeper); the next field report answers it. Package provenance
      beyond the signature check is open.
- [ ] **139. Personal identities in logs.** [CODE] Done: email, URL-credential, foreign-profile rules,
      config-directory name masking, the opt-in redacted day log attachment, and pack labels masked on the three OS
      (macOS and Linux `PrivateLabel.mask`, Windows at write time, 9390f45b2d). Left: write-time masking in the macOS
      and Linux loggers (historical logs on disk stay unmasked; the collector masks at export); GitHub field
      editability after a form reload needs a real draft.
- [ ] **13/35.** [CODE] Enrol the complete guardian acceptance collector in main CI.
- [ ] **93. Linux ordered pairs.** [PHYS-L] XI2 property cookies proven on Xvfb (`run_xi2_property_cookies.py`).
      Nothing else is provable on Xvfb: the join of a uinput Writer edge with the server's XKB/XI2 modifier state
      needs Xorg or a compositor reading real evdev nodes.
- [ ] **97/98.** [CODE] Native physical-position capture and all-owner collision admission. The MediaStore device
      contract exists (`_shared/lua/keystats/media_identity.lua`); the Linux candidate is the owned descriptor's
      `st_rdev`. Left (decision first): the consumer (Linux media-key metrics, or a per-device physical binding), then
      the identity with it.
- [ ] **106.** [PHYS-M] Genuine Apple Shortcuts invocation with bounded cancellation; only the refusal-in-time probe
      exists (116). A genuine run needs a shortcut the maintainer owns and names; `field_toolchain`'s
      `shortcuts_list` and `shortcuts_refusal` are what a program can prove.
- [ ] **107.** [CODE] macOS forced output. Linux is settled by design (the number row is applied by rebuilding the
      layout, `docs/design/linux-number-row-runtime.md`); its W1 to W4 are in the layout emulation item.
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
      per-device physical binding), then add the identity with it. macOS (checked 31 October): the
      consumers exist (`keystats/media_store` replays through `aggregator/core.media_policy`, the
      shortcut editor reads `physical_capture.position_available`), but the only producer of positions
      and media events is `modules/keystats/physical_capture.lua`, which only the owned Karabiner
      runtime starts (`adapters/runtime_capture_port.lua`, dormant behind
      `[karabiner] runtime = "owned"`): native capture on macOS is item 31's "production capture owner", not separate work.
      The star setting migration is dropped (no users, no legacy migration).
- [ ] **106.** [PHYS-M] Genuine Apple Shortcuts invocation with bounded cancellation; only the
      refusal-in-time probe exists (in 116). _Hands:_ a genuine run needs a shortcut the maintainer
      owns and names (the `shortcuts` command cannot create or import one without a dialog, and running an
      arbitrary shortcut of theirs is not read-only); `field_toolchain`'s `shortcuts_list` and
      `shortcuts_refusal` are what a program can prove.
- [ ] **107.** [PHYS-L] Forced number-row output is settled by design on macOS and Linux: both apply the
      number-row ordering and edge keys by rebuilding the layout, not by retyping keys in a hook (macOS
      fc5d3a11df, `number_row_live.lua` and `layout_rows_build.lua`, proved by the field run's
      `field_layout_rows`; Linux `docs/design/linux-number-row-runtime.md`), so the hook's input+XI2+writer
      join is deliberately unreachable (nothing passes `numberRowMode`) and is not owed. Left for Linux only:
      mutter and KWin reloading a `~/.config/xkb` layout (W1 to W4 of that note).
- [ ] **108.** [CODE] Item 97's collision/source/modifier/output joins.
- [ ] **109. Branded debug GUI.** Blocked: AHK 2.0.26 has no supported invisible Variables/KeyHistory snapshot.
- [ ] **L115.** [CODE] Provider error envelope guard: not reproducible under WSL LuaJIT (6 of 6 runs pass); leave it
      or close it (maintainer).
- [ ] **109. Branded debug GUI.** Blocked: AHK 2.0.26 has no supported invisible
      Variables/KeyHistory snapshot.
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
      10 s; Quit wins over a reload in progress. If the CI launch gate reports "Quit did not end both
      processes within 10 s" again, read its `launch-gate-failed-*` evidence (kept 7 days).
      _Hands:_ a quit ends the field run itself; the CI launch gate times the quit of a packaged app.

#### 2. Typing in real conditions (one working day if possible)

- [ ] Type normally for at least an hour in Safari, TextEdit, Terminal, VS Code and one Electron app (Slack
      or Discord). Note any dropped, doubled or reordered letter with the time; right after one, use Debug >
      Report a bug. I compare with `typed key(s) swallowed`, `key_event_health` and the lease lines
      (items "Dropped letters on macOS" and 117/140).
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

The October 22 fixes (Win+S targets, Backspace word start, the native pair popup, the Versions Retry button)
are lines of "Windows manual checks for the maintainer" above.

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
