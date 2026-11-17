<!-- TODO.md -->

# ErgoptiPlus continuation checklist

Open work only. Latest stable: [v1.0.9](https://github.com/adrienm7/ergopti/releases/tag/v1.0.9). Conventions and
tags: [workflow and verification memory](docs/memory/workflow-and-verification.md#project-todo-checklist-conventions).
Finished items and their history stay in Git: `git show e20edbf92b:TODO.md` is the long form before the 2026-11-17
pruning.

This file lists features and fixes. The checks only real hardware can answer are in
[TODO-tests-macos.md](TODO-tests-macos.md), [TODO-tests-windows.md](TODO-tests-windows.md) and
[TODO-tests-linux.md](TODO-tests-linux.md).

## Resume here

Any agent can continue from this file alone. Follow [AGENTS.md](AGENTS.md) and the skills it routes; report to the
maintainer in French with Paris times, ask questions as multiple choice with the recommended option first, and record
every maintainer request here.

- **Push.** `dev` only, linear: `git fetch origin dev && git rebase origin/dev`, then
  `git push origin HEAD:refs/heads/dev`. Never force-push, never a merge commit (rebase branches, do not merge `dev`
  into them), never `main`, a tag, a release or a `Dev-Prerelease: yes` trailer. Do not touch
  `remap-runtime-v16.3.0-ergopti.6`, `vendor/remap-runtime/manifest.json` or the ci-seed tags.
- **Identity.** Every commit is authored and committed as the maintainer (skill `commit-and-push`), with no AI
  trailer (`tools/lint/check-commit-identity.cjs` checks it in the `commit-msg` hook and over each pushed range in
  CI); in a fresh container set the repository's local `user.name` and `user.email` first.
- **Gates** before each commit: `node tools/lint/format.cjs --check` (Ruff 0.15.8 on `PATH`),
  `node tools/lint/lint-conventions.js --fail-on-violations` and the tests of the change; never bypass the hook.
- **Done** means local gates pass and CI on the three OS (ci.yml, `os_lanes=all`) shows no new red. Each push cancels
  the previous dev run: space the pushes so a full run completes, then read its reds by name.
- **Landing someone else's branch:**
  `git rebase origin/dev --exec 'git commit --amend --no-edit --reset-author --no-verify -q'`, then
  `node tools/dev/coordinator/renumber-suite-ordinals.cjs`, `node tools/test/test-js-feature-inventory.cjs`,
  `node tools/lint/check-commit-identity.cjs --range origin/dev..HEAD`, format and lint, push.
- **Site deploy.** Once a dev run completes with its 5 site jobs green:
  `gh workflow run deploy-site.yml --repo adrienm7/ergopti --ref dev -f run_id=<id>`.
- **New design questions:** pick the safest option that follows AGENTS.md, note « decided by the agent on <date>,
  to review by the maintainer » under « Maintainer decisions pending », and keep going.
- **Delete what you finish** in the same commit, naming it and its proof in the commit message; real-machine checks
  live only in the TODO-tests files. Never commit a non-anonymized field report, never cancel a CI run you did not
  start, never use `git stash`, `reset` or `clean` as shortcuts.

## Full accessibility (maintainer request, 2026-11-16, very important)

The goal is a totally accessible project: the site (ergopti.fr), Ergopti Studio (editor, Comparer, Optimiser,
benchmarks) on the site and inside the app, and Ergopti+ itself (menus, windows, dialogs, tooltips, onboarding) on
Windows, macOS and Linux. Target WCAG 2.2 level AA everywhere, AAA where it costs little; every new page or window
is held to it from now on.

- [ ] **Audit first.** An automated pass (axe-core or equivalent in the browser tests, a CI gate that fails on new
      violations with a ratchet baseline) plus a manual checklist per page and per native window; record the
      findings in docs/audits/accessibility/ with severity and owner.
- [ ] **Images and media.** Every image, icon, SVG, chart and keyboard drawing has a text alternative (meaningful
      `alt`, `aria-label`, or `alt=""` when decorative); charts and heatmaps also offer their numbers as a table;
      videos get captions and transcripts.
- [ ] **Colour vision.** No information by colour alone (shapes, labels, patterns as well); palettes checked for
      deuteranopia, protanopia and tritanopia; text contrast ≥ 4.5:1 (3:1 for large text and UI parts) in light and
      dark themes; a high-contrast option.
- [ ] **Motion sickness and vestibular disorders.** Honour `prefers-reduced-motion` everywhere (no parallax, no
      auto-playing or looping animation, no smooth-scroll jumps, instant transitions when reduced); a site setting
      to turn motion off; nothing flashes more than 3 times per second.
- [ ] **Dyslexia and reading.** A dyslexia-friendly font option (e.g. OpenDyslexic or Atkinson Hyperlegible),
      adjustable text size and line/letter spacing without breaking layouts (WCAG 1.4.12), plain-language texts,
      no justified text, comfortable line length; settings remembered per viewer.
- [ ] **Blind and low-vision users.** Full screen-reader support (NVDA, JAWS, Narrator, VoiceOver, Orca): semantic
      HTML and landmarks, headings in order, labelled forms and buttons, live regions for results and progress
      (Optimiser, Comparer), accessible names for every key of the keyboard drawings, a text/table view of every
      layout; zoom to 400 % and reflow at 320 px wide without horizontal scroll.
- [ ] **Keyboard and motor.** Everything usable with the keyboard alone, visible focus, logical focus order, skip
      links, no keyboard traps, generous target sizes (≥ 24×24 px), no time limits or a way to extend them, drag
      operations with a click alternative (WCAG 2.5.7).
- [ ] **Cognitive.** Consistent navigation, clear error messages with how to fix them, confirmations before
      destructive actions, help text for every metric and setting.
- [ ] **Ergopti+ native UI.** The menus, windows (WebView2 and native), tooltips, notifications and onboarding on
      the three OS expose names and roles to the platform accessibility APIs (UI Automation, NSAccessibility,
      AT-SPI), follow the system's high-contrast, reduced-motion and text-size settings, and are usable with a
      screen reader and keyboard only; the hotstring and prediction tooltips are announced or can be.
- [ ] **Languages.** Correct `lang` attributes per page and per passage; the 21 locales keep the same
      accessibility texts (alt texts and labels are translated, not left in English).
- [ ] **Accessibility statement.** A public page stating the conformance level, known gaps and a contact to
      report a barrier.

## Ergopti Studio

Design: [layout-editor.md](docs/design/layout-editor.md), [layout-analysis.md](docs/design/layout-analysis.md),
[analyser-scores.md](docs/design/analyser-scores.md), [layout-optimizer.md](docs/design/layout-optimizer.md); the
analyser study is [docs/audits/layout-analysers/report.md](docs/audits/layout-analysers/report.md) (its section 15
waits for the maintainer's review).

- [ ] **More figures per layout in the Comparer (maintainer, 2026-11-17), what remains.** Every figure from the
      engine's numbers with a hand-checked tiny-corpus test, legend and units, light and dark, phone width, 21 locales.
  - [ ] A key × key bigram matrix (which pairs a layout makes, coloured by count or by event).
  - [ ] Effort per word and the hardest words to type: the corpus tables hold n-grams only, so the built-in corpora
        and a user's text first need a word table (prepared once and cached like the n-grams).
  - [ ] Row jumps per key (a key pair two or more rows apart on one hand): no such metric exists yet; define it in
        docs/design/layout-analysis.md first, coordinated with the agent changing the engine's typing paths.
  - [ ] Check the figures again once the engine types through best paths (alternative copies, AltGr, dead keys):
        they read the engine's per-key output (keyValues, topGroups, fingerDistance), so they should follow.
- [ ] **Layout formats, what is left.** The library comes only from Oxeylyzer and cmini: add another source (genkey,
      GPL-3.0 like cmini; KLA's built-in list) once its layout list can be read. No third-party KLA JSON, XKB
      symbols, KLC or DOF file under a licence that allows shipping it has been found for the reader tests.
      KLAnext's `matrix` board is refused (`format_unsupported_board`): no matrix file was found to read its key
      indexes from. The ErgoDox index → ISO key table (`KLA_KEYS.ergodox`) maps 27 to Backslash and 60-62 to the
      brackets and quote, while the committed bépo and Optimot ErgoDox files put on 27 what their ISO files put on
      BracketLeft and on 39 what they put on Quote: check it against KLA's ErgoDox key set before changing it.
- [ ] **Studio i18n.** Left: a label-improvement pass over the Studio, editor and analyser strings; a label it
      rewrites is translated again in the 19 other locales, and a new label enters as `pending-translation` in
      `tools/lint/locale-identical-to-english-allowlist.json` until it is.
- [ ] **[LATER] Layout library credits.** The 35 cmini layouts and 25 credits are shown; check each credit known
      « from knowledge » against its author's own page.
- [ ] **More corpora.** French, English, German, Spanish and Italian books, Tatoeba, Wikipedia and MIT code are in.
      [CODE] Nothing from Wikisource yet. [DECISION] An e-mail or chat register: no candidate is cleared (Enron mails
      hold personal data, the Ubuntu IRC logs' licence is unchecked, Wikipedia talk pages sign each message with a
      user name).
- [ ] **[LATER] Large published frequency tables.** The `ergopti-count-table` format and its importer
      (`tools/build/import-count-tables.cjs`) ship Leipzig and Lexique tables. Not imported: Norvig's counts
      (www.norvig.com refused by the build environment's proxy), Google Books Ngram (several GB per language: a
      one-off offline streaming import that ships only letter and bigram tables, with licence and attribution),
      Tatoeba counts, other languages.
- [ ] **[LATER] Site keyboard display from a layout file (maintainer, 2026-11-14; not now).** The site's Ergopti
      keyboard display is hand-coded. Render it from a layout source (Ergopti TOML or `.keylayout`) so the site can
      display and emulate any layout; the maintainer's display tweaks become a documented display patch applied after
      loading, reproducing today's display exactly (pixel or DOM comparison test against the current rendering).
- [ ] **[RELEASE] Windows export step in native Lua.** The restricted host `windows/native/ergopti_lua_export.c`
      (pinned Lua 5.4.6, built by `tools/build/build_windows_lua_export.ps1` in package-windows) is done. Left: once a
      dev run builds « Windows / Build », commit its artifact `windows-lua-export-*` (`ergopti_lua_export.exe` and
      its `.json`) into `windows/vendor` with their `required` entries in `tools/build/windows_bundle_manifest.json`;
      then `test-windows-lua-export-identity.cjs` checks them and the Windows lane runs the byte-equality proof.
- [ ] **The optimizer in Ergopti+.** Mount `LAYOUT_OPTIMIZER_PAGE` in the app's Studio window on Windows, macOS and
      Linux, with « My typing » (keystats) as a corpus; the page already runs without workers where a host inlines it.
- [ ] **Optimizer follow-ups.** Pasted texts and files as corpora (as the Comparer); zones in the page (restrict a
      letter to keys by clicking them); per-viewer saved choices (localStorage); a browser test of the tab in
      `layout-editor.playwright.cjs` style.

## Layout generator from an Ergopti TOML source

Kalamine and KbdEdit give ideas, never code: every generator is written from the formats' own documentation
([layout-source-format.md](docs/design/layout-source-format.md),
[layout-windows-dll.md](docs/design/layout-windows-dll.md)).

- [ ] **[RELEASE] Sign the generated Windows layout DLLs.** The four DLLs, the uninstaller, `<dll>-setup.exe` and
      the editor's generic installer (`ergopti-layout-setup.exe`, `_generated/kbd_setup_stub.js`), SHA-256 with an
      RFC 3161 timestamp, once SignPath or the release PFX is on (`layout-windows-dll.md` « Signing »);
      `tools/kbd-dll.cjs` reports `signed: false` until then, and the job wiring is [CODE] once it exists.
- [ ] **Keyboard types JIS and ABNT.** Their keys (Yen, Ro, Henkan, Muhenkan, Kana, keypad comma) would enter
      `physical_keys.json`, which the Windows driver parses at boot: measure that parse cost, then decide.

## Parity audit

The [coverage and remaining-work register](docs/platform-parity-audit.md#review-status-at-pause--november-5-2026)
and the campaign reports under [docs/audits/platform-parity/](docs/audits/platform-parity/) record what is done.
Native receiving stays unqualified everywhere; the real-machine scenarios are in the TODO-tests files.

- [ ] **[CODE] Parity audit continuation.** Reconcile current source areas with the register (the 2026-11-12 census
      listed 381 areas, many changed since their campaign), then take one bounded module at a time across Windows,
      macOS, Linux and shared; do not restart a finished campaign without source drift or a new hypothesis. Left:
  - the census areas outside the campaigned modules, and the never-campaigned changed areas the
    [start-at-login report](docs/audits/platform-parity/2026-11-12-start-at-login/report.md) lists (menus, i18n,
    editors, healthcheck, onboarding, Linux install);
  - a deep pass of macOS `bindings.lua` and Linux `key_combinations.lua`
    ([shortcuts campaign](docs/audits/platform-parity/2026-11-11-shortcuts/report.md));
  - the configuration, lifecycle, notification and network adapters in depth
    ([adapters campaign](docs/audits/platform-parity/2026-11-11-adapters/report.md));
  - make the Linux runner's notify-send sentinel count fatal (`tests/run.lua`) once the ~370 notices that still reach
    the real notifier have a `ShellRunner._set_async_runner` seam
    ([notifications campaign](docs/audits/platform-parity/2026-11-12-notifications/report.md));
  - TWD-2 (the typing-speed widget hides when the burst ends): a Linux fifth-level key placed on a Ctrl key is
    reported as Ctrl by the input hook and ends the burst; its real-keyboard look on each OS is not yet in the
    TODO-tests files;
  - the macOS Carbon slots against the tap rewrite, to confirm on a Mac
    ([input/layout follow-up](docs/audits/platform-parity/2026-11-12-input-layout-followup/report.md));
  - a deleted Linux checkout's startup entry stays until a checkout run rewrites it
    ([Linux install campaign](docs/audits/platform-parity/2026-11-12-linux-install/report.md)).
- [ ] **[RELEASE] Windows/Linux feed-only update fallback.** The unavailable-features diagnostics section is
      published on both. Left: a feed-only list may install the channel's newest release only through authenticated
      metadata (decided 2026-11-06, as macOS): download the asset under its conventional name, compute size and
      SHA-256, rebuild the `asset_signing.json` record and verify `<asset>.sig` against the pinned key. Blocked until
      `public_key_spki_base64` is provisioned and enforcement leaves `off` ([update-signing](docs/tooling/update-signing.md)).
- [ ] **[CI] Native keyboard-source fixture (macOS).** The selection-deadline / cleanup-unavailable refusals of the
      Swift keyboard-source cohorts ([sequential audit](docs/audits/platform-parity/2026-11-05-sequential/report.md)).
      Both steps are bracketed with a text-input snapshot and `tsm-refusal.json`; the refused case now names
      `process_current_source_stale` (`tools/test/test-macos-tsm-refusal.cjs`): the system applies the restore to US,
      but `TISCopyCurrentKeyboardInputSource` in the test process keeps returning French, and every later case
      captures that stale source (TextInputMenuAgent did not restart). Left: why the process misses that one change
      (the notification that refreshes its cache, or the run-loop mode the fixture pumps), and whether the launcher's
      own long-lived process can be left on a stale source the same way. No retry is added while the cause is
      unproven.
- [ ] **Linux live runtime and editor receiving.** Write the Linux runtime, editor and diagnostics flows in the hosted
      desktop-webview CI shard: refused writes, native timer admission, stale epochs and physical cleanup
      ([native UI audit](docs/audits/platform-parity/2026-11-05-native-ui/report.md)).
- [ ] **Linux flow receiving.** A native terminal for LCP-004, chmod (make-executable from a file manager) and eject of
      a real device (maybe a loop device), the case/wrap transforms inside a native editor field
      ([flow review](docs/audits/platform-parity/2026-11-04-flows/report.md),
      [receipts](docs/audits/linux-container-proofs/2026-11-11-recovery/README.md)).
- [ ] **Linux native acceptance.** Multi-field Tab settling and grapheme deletion in host editors (hotstrings), pointer
      metrics, live layout apply on KDE (GNOME is proved by `run_input_sources_live.sh gnome`), desktop connectors and
      real mail/calendar (llm) ([18-scope review](docs/audits/platform-parity/2026-11-04-deep/report.md)); touchpad
      hotplug waits on its question under « Maintainer decisions pending ».

## Carried over from the 1.0.9 requests

- [ ] **Slowness, Windows boot.** Done so far: deferred emoji and symbol registration, the AI submenu built at its
      first open, lighter parsing (see `BOOT_OPERATION_CEILINGS` of the startup smoke). Next candidates: script parse
      (lighter boot includes; AHK has no runtime include, so only a smaller graph or a worker helps) and the remote AI
      catalogue (212 ms), to measure again now that the AI root is lazy. Measure each with interleaved base/candidate
      smoke-fixture boots (summed `process_cpu`). Rejected: a disk cache for the layout stage (native hotkey
      registration). The PC timings and the macOS field points `rerun_2026_11_02` and `main_thread_holds` are in the
      TODO-tests files.
- [ ] **[RELEASE] Before publishing.** On a quiet PC with no resident driver: the whole AHK suite,
      `npm run test:ahk-tray-rows-read-as-text`, every live check including `quit-over-a-log-flush`, the JS, macOS and
      Linux suites, and a Windows field report with a driver.

## Remaining code work

### Windows

- [ ] **EDD-1 on AHK: a pause stops typing, not configuration** ([decision](docs/memory/maintainer-decisions.md),
      [pause Windows inventory](docs/audits/platform-parity/2026-11-12-pause/windows-inventory.md)). The tray keeps
      its feature rows live and rebuilds under a pause, and every click-reached handler that still refuses shows
      `notify.paused_refused`. Left: remove the A and B suspend gates (a paused save writes the file) of
      `prompt_editor`, `paths_editor`, `layout_manager`, `hotstrings_config_window`, `action_picker`, `model_browser`
      and `menu_llm`, each classified in the inventory, with a test per editor; the AI menus' deferred work; then the
      PC run in TODO-tests-windows.md.
- [ ] **Immediate-Backspace restoration after Notepad-paste and terminal expansions.** Those owners emit after the
      keystroke and keep no undo record, so `HSE_UndoExpansion` refuses both hosts. Keep the record in
      `_HSE_CommitNotepadOwner` and `_HSE_CommitTerminalOwner` (as `_HSE_RememberUndo` does) and send the undo burst
      through the same owned output as the expansion (the clipboard owner of `_HSE_BeginOwnedNotepadTransaction`, the
      paced capture of `_HSE_BeginOwnedTerminalTransaction`); the PC qualification is in TODO-tests-windows.md.
- [ ] **TakeNote and the Windows 11 tabbed Notepad.** The Store Notepad opens a second file as a tab of the open
      window, so a same-named note of another folder shares one window with the first, and the module, which binds
      one window to one path, waits for a window that never comes (`takenote-native-document-owner` mode
      different-folder fails on the PC, passes on the Server runner's classic Notepad). Tell the two tabs apart (UI
      Automation tab items) or select the right tab before typing.
- **Parity literals.** PAR-58 families not yet consumed: `terminator_restoration`, `context_buffer`,
  `request_plan_*`, the keystats families, `row_options`, `menus/*`. PAR-74: 549 literals left; the rest of the menu
  files need `test-menu-manifest` to stop pinning their spelling. PAR-79: the 28 literals left are inventory pollers
  and sleeps before the registry loads.
- **Tests.** Source assertions left to convert to behaviour (3,780 `_Driver*` source reads in 994 files; 80 meta
  files still read `A_IsSuspended` from source). Guards that would send keys, paste or move the cursor when broken
  (text sender, tap-hold, dead keys, `SimulateActivity`) need a seam first. The ROI half-life tick and the click
  handlers are guarded a second time downstream, so a behaviour test of their own guard could not fail.
- **Signing follow-ups.** Delete `.github/ci/stable_windows_signing_exception.json` once SignPath is configured; flip
  update enforcement to `required` after the `off` release. The relay exe and the vendor binaries are unsigned.
- **Older findings.** The seven « Remaining findings » of
  [the 2026-10-28 Windows audit](docs/audits/windows-2026-10-28/README.md); item 36, the updater production coupling
  (the first trusted PowerShell host acquisition).

### macOS

- [ ] **[CI] MLC-005 relocation rows.** The helper is proved by device and inode (`test_lease_helper_identity.lua`)
      and the five relocation-row commits are on dev since 2026-11-16: confirm the `symlinked_applications`,
      `spaced_accented_path` and `translocated` rows green in the next hosted macOS 26 Install-and-launch run.
- [ ] **Field report follow-ups (2026-11-03).** Decide from the next report which half of the 230 ms cold
      `karabiner.layout_actions` phase to reduce (`karabiner_layout_actions` in TODO-tests-macos.md; the
      regeneration itself stays synchronous, see the rejected proposals). A Metrics toggle still reads the hardware
      UUID synchronously when no start-delay prefetch ran (`modules/keystats/host_signature.lua`).
- [ ] **One folder name for Ergopti on the three OS.** Remove the boot migration only once the maintainer's
      machines pass the checks of the TODO-tests files
      ([handoff](docs/tooling/one-folder-name-handoff.md)).
- [ ] **[RELEASE] Owned runtime rebuild.** The pinned runtime (16.3.0-ergopti.6) predates MRT-004: the next build
      ships the « Réparer le service » helper role, the helper's one-hash report rule
      (`OwnedVirtualHIDDaemonReportStageOwner.admitImage`) and the raised descriptor limit, renames the owned runtime
      folder `ErgoptiPlus`, and updates the manifest pin (the maintainer's step: agents do not touch the pinned
      runtime).
- [ ] **Item 31, owned Karabiner runtime** ([ADR 011](static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md),
      [handoff](docs/tooling/next-release-handoff.md)). After the maintainer's WP9 pass (`owned_runtime_wp9` in
      TODO-tests-macos.md), delete the shared mode. The managed-daemon row of
      `_shared/core/network/data/owned_runtimes.json` under the proxy relay waits for a short design note (who
      launches the relay, how its refusal receipt reaches the Swift owner; Swift and Go).
- [ ] **[LATER] Owned runtime with a Developer ID (maintainer: not now, 2026-11-04).** It would allow
      `SMAppService.daemon` for both jobs (no password, one « Ergopti » Login Items group) and an Ergopti-signed
      DriverKit extension activated with `OSSystemExtensionRequest` (needs Apple's DriverKit HID entitlements); the
      root Core keeps its own Input Monitoring row either way.

### All drivers

- [ ] **Structure plan, phase 2** ([plan](docs/design/structure-plan.md), resume point
      [docs/plans/structure-migration-resume.md](docs/plans/structure-migration-resume.md)). S01 to S20 are on dev
      (S18 to S20: settings, menu, tray); S21 (ai) is being proved on `claude/ergopti-structure-s21-proof-*`; S22 to
      S38 remain, one step per commit with `tools/audit/structure/apply-step.cjs`, landed in blocks of a few steps.
      Paths that describe a published artifact (a prior release's payload, a historical pin) keep their old spelling.
- **Provider flags inferred, not read.** Only provable with a live key: SambaNova's `enable_thinking: false` (off is
  its default, the docs show only `true`) and the Chutes Qwen `enable_thinking` field; a refusal is dropped and
  remembered either way.
- **108. Per-device physical bindings.** Deferred until designed: the collision, source, modifier and output joins of
  a shortcut bound to a key position on one device; `keyboard_hook.capture_position` hands only `native_code` and
  `mods`.

### Linux

- [ ] **[LATER] Legacy Linux updater probes.** `tools/build/add-linux-legacy-update-probes.sh` adds
      `_shared/data/locales/en.json` and an empty `_shared/lua/` to the release tarball so pre-move updaters (v1.0.9
      … v1.0.10-dev.175) admit it. Remove that step, its call, `test-linux-legacy-update-probes.cjs` and the frozen
      helpers of `tools/test/fixtures/linux-pre-move-ownership` once the first release whose updater finds a staged
      shared root by `build_stamp.txt` has been out for one full release cycle. The structure step that moves
      `linux/infra/version.lua` (also required by v1.0.9) must add that probe too.

## CI acceptance

Each closes on a named green hosted or native run, recorded here.

- [ ] **Dev site deployment gated on its site jobs (maintainer, 2026-11-14).** ergopti.fr/dev was last deployed
      on 2026-11-10 at 21:03: `deploy-site.yml` published only from a ci.yml run that concluded success, and `dev`
      never does while a baseline red remains. A `dev` push now publishes from a completed red run when Common / E2E
      tests (Shared UI rendering), Common / Build and Common / Install and launch (Stable site and Development site)
      all succeeded; `main` keeps the whole-run success and a cancelled run never publishes
      (`tools/ci/site-deploy-admission.cjs`, which logs the jobs that gated it; same exact tested bytes, no rebuild).
      Those site jobs still follow Common Integration, so a red Common lot (today Packaging and boot) skips them and
      nothing deploys until it is green. GitHub runs a `workflow_run` workflow from the default branch, so the
      gate takes effect once `main` carries this change (the maintainer's merge); until then a manual Deploy site
      dispatch on `dev` with a run ID uses it. Worker G. Closes on the first `dev` push that deploys with ergopti.fr/dev/editeur
      in gh-pages `dev/`.
      [RELEASE] Left (2026-11-15): the gate is on dev (1d9c242070) and a manual dispatch deployed /dev; the automatic
      deploy needs this change on main.
- [ ] **16/38.** One complete non-release three-OS checkpoint on the final source (units, E2E, packaging,
      installation, launch) with exact receipts; it also carries the first hosted run of: the Linux X11 window list
      (962a25a973), AppImage Build and `install-linux` rows (dce846a0bd), the Linux per-step installs (17e80f2882),
      "Qualify the installed managed Ollama route plan" (c0a50b5e41), the Linux private runtime in every package,
      and the run-timing summary (`run-timing.cjs --step-summary`; Flatpak under 5 min).
      Initial audit preflight [42099804561](https://github.com/adrienm7/ergopti/actions/runs/42099804561) failed Arch native server detection, shared UI browser installation and macOS stubbed replay. Follow-up [42108198520](https://github.com/adrienm7/ergopti/actions/runs/42108198520) at `4ca161c3e512eecc4c78499db0465139c9a71861` is green: 114 successful jobs, with only Release / Publish skipped; Arch integration, shared UI rendering and all OS verdicts passed. Later dead-key preflight [42121216727](https://github.com/adrienm7/ergopti/actions/runs/42121216727), at `04ebe1089bf387ccbfef43bbfd3b2f3e9b1cd6d9`, failed Common / Install and launch (Stable site) at Install production site browsers, followed by its mandatory verdicts. Requalify that browser installation and the final source checkpoint; no successful browser/render receipt follows from the failed step. Hosted results remain separate from physical dead-key receiving.
      2026-11-11 Linux and macOS lanes at `85f3dfee20` (Linux [43012051378](https://github.com/adrienm7/ergopti/actions/runs/43012051378), macOS [43012056158](https://github.com/adrienm7/ergopti/actions/runs/43012056158)): every Linux job is green (Unit, five distribution rows, Integration, five E2E shards, Build, all 20 Install-and-launch rows), including the installed managed Ollama route plan and its Go twin (network-ai, job 130500747601), the X11 cursor-display window switching step (input-display, job 130500747586), the AppImage Build and `install-linux` AppImage row and the per-distribution installs. The run-timing summary ran in Release / Verify (job 130525465817). Flatpak was 378 s cold (over 5 min): 986a3d5629 caches the flatpak-builder module state: cold 568 s, cache saved ([43105583384](https://github.com/adrienm7/ergopti/actions/runs/43105583384) attempt 2, job 130839886024), then warm 58 s with the module cache restored ([43126416939](https://github.com/adrienm7/ergopti/actions/runs/43126416939) at `7188928a48`, Linux Build job 130890961113); Flatpak under 5 min done. That run's Linux lane is green end to end (Linux Verdict job 130894504733). Both runs' Common lot "Distribution and updates" fails only on `test-windows-updater-original-source` (f9aea2f6c1 changed `test_framework.ahk` without resealing: the maintainer's reseal), so Common and Release Verify are red. Still open: Windows, the final source.
      [RELEASE] Left (2026-11-15): Windows, macOS and Common are green (run 43693237215); the Linux updater E2E stays
      red until a post-move prerelease exists, then one all-green run on the final source.
- [ ] **macOS lane.** Claimed by worker K (2026-11-13). L32 and L42 Swift in the Build stage; the Issue #101
      Swift and Go cells; native qualification of the Hotstrings category boot publication and the obsolete-leaf
      setters; item 31's lane once its runtime build is green. Already green (run 41257389239): Launcher XCTest,
      Native XCTest (Intel), Build and all five Install-and-launch rows, guardian fixes included; macOS Unit,
      Integration and every E2E cell on run 41261068581.
      2026-11-11 run [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137) at `6736a355`: macOS Unit, Integration, every E2E cell (Native XCTest Intel, Launcher
      XCTest macOS 26 with `Test Suite 'All tests' passed`, both Managed Ollama and Managed Ollama build cells = the
      Issue #101 Swift and Go cells, Lease silence, Tooltip canvas, Archive update controls) and Build are green. L42:
      the credentialed-redirect refusals (`testRealPACSourceRedirectsHaveFreshCredentialFreeOwners`,
      `testRedirectIsRefusedWithoutSecondConnection`) pass in the full suite; L32's `memory_footprint_mb` is a Lua
      field probe covered by the green Unit lots, not Swift. Still open: native Hotstrings category boot publication
      and obsolete-leaf setters need an installed driver on a real Mac (no hosted row types into them), and item 31's
      lane waits on its runtime build, which the pinned runtime rules keep out of scope tonight.
      Requalified 2026-11-11 at `85f3dfee20` in [43012056158](https://github.com/adrienm7/ergopti/actions/runs/43012056158): macOS Unit, Integration, all 12 E2E cells, Build (with the
      layout extension payload receipt) and all five Install-and-launch rows green; macOS Verdict job 130559010960 green.
      Worker K 2026-11-13: no hosted code work is left here. L32 and L42 are closed above; what remains needs an
      installed driver on a real Mac (Hotstrings category boot publication, obsolete-leaf setters) or item 31's runtime
      build, which the pinned runtime rules keep out of reach: hardware and maintainer only.
      [RELEASE] Left (2026-11-15): nothing hosted is left; item 31 waits on the runtime build. The Hotstrings boot
      publication and obsolete-leaf setters on an installed Mac are in TODO-tests-macos.md (2026-11-15).
- [ ] **Ollama Go cell** Claimed by worker K (2026-11-13). (cda1e10c5e) on the final source before a release (passed on run 40021624397).
      Green again on both architectures in [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137) (Managed Ollama and Managed Ollama build, Intel and Apple silicon);
      it closes only on the release candidate's own source, which tonight's no-release rule excludes.
      Worker K 2026-11-13: release-only, nothing to change in code; the known macOS Intel flake
      `TestCancellationAndConcurrentClosePhysicallyRetirePeer` stays with worker G (CI baseline reds).
      [RELEASE] Left (2026-11-15): a pass on the release candidate's own source.
- [ ] **40.** Signed native execution of the eight Karabiner default/recommended/switch variants.
      A hosted runner runs the eight variants only against the ad hoc signed app of the "karabiner config"
      Install-and-launch row (`hs_native_bootstrap_probe.py`); the Developer ID signature exists only on a release
      build, which tonight's no-release rule forbids, so the signed run needs the next release candidate.
      Ad hoc receipt 2026-11-11: `macOS launch gate [karabiner_config] passed on arm64` in [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137) (job 130257482253),
      which requires all eight variants to build, merge and publish on the installed app.
      [RELEASE] Left (2026-11-15): the ad hoc signed receipt passed (run 42929436137); the eight variants on a Developer
      ID signed build remain.
- Moved to TODO-tests-windows.md and TODO-tests-macos.md (2026-11-15): 104, 105, the common autocorrection sections
  and the macOS dynamic hotstrings.
- [ ] **34, 37, 102, 129.** Native macOS delimiter transactions; macOS packaging with both extension TOML files;
      Windows native cases and Fedora/Alpine ShellRunner fixtures (Linux done in the start-up E2E).
      macOS packaging received 2026-11-11: 85f3dfee20 makes the macOS and Linux builds require every hotstring file the
      shipped extension manifest binds (`tools/build/check_layout_extension_payload.py`); the macOS Build of
      [43012056158](https://github.com/adrienm7/ergopti/actions/runs/43012056158) (job 130512589181) prints `magickeyreplace.toml ... sections=replace`, `suffixes_a.toml` and
      `PASS bound=6`, and the Linux Build of [43012051378](https://github.com/adrienm7/ergopti/actions/runs/43012051378) passes the same check. Fedora/Alpine ShellRunner fixtures
      received: the full Linux unit suite passes on Fedora's and Alpine's own LuaJIT in 43012051378 (jobs 130494409773, 130494409706) and their Integration rows too. Still open: native macOS delimiter transactions (typing into an
      installed driver on a real Mac) and the Windows native cases (maintainer; Windows counterpart of the payload check:
      run it from the Windows packaging against the registry `windows_bundle_manifest.json` ships).
      Done 2026-11-15 (`claude/ergopti-todo-win-payload-check`): the Windows packaging runs the same payload check on
      the static bundle ZIP the exe embeds (`static_bundle.zip::static/layouts/registry`, ci-windows.yml right after
      « Build static asset bundle »); proof: test-layout-extension-payload.cjs (archive cases and the step order). The
      native macOS delimiter transactions and the Windows native cases are in TODO-tests-macos.md and
      TODO-tests-windows.md (2026-11-15).
- Moved to TODO-tests-macos.md and TODO-tests-windows.md (2026-11-15): 121, 123, 137, the AI Agent submenu
  composed-menu qualification.
- [ ] **[RELEASE] First `main` push after 1.0.9.** `main` is still at 4d834c866a; dev.174 and dev.175 are published
      as v1.0.10 (ci.yml keeps the legacy core up to counter 169, the `v0.0.0-dev.169` bridge). Merge to `main` with
      `Release-As: 1.0.10`, then check that CodeQL, which scans `main` only, closes the 32 alerts fixed on dev on
      4 November (a3d69950e5..89b0b774c8).
- [ ] **CodeQL Go.** Claimed by worker K (2026-11-13). After the `native_http` Go module is published, re-enable Go and check a non-empty analysis.
      Worker K 2026-11-13, code side: there is no CodeQL workflow in the repository (default setup, a repository
      setting), so re-enabling Go is the maintainer's. Both shared modules carry their own `go.mod` at the package root
      and physical `go:embed` inputs, as `docs/memory/workflow-and-verification.md` requires. The standalone
      `native_http` module stays standard-library only by design (`test-managed-bootstrap-policy.cjs`), yet its root
      package imports `golang.org/x/sys/unix` on Linux and macOS (`listener_event_{linux,darwin}.go`, spliced into
      Ollama's module); a standalone extraction therefore covers `proxyrelay`, `cmd/ergopti-proxy-relay`, `route_plan`
      and the other-OS files, and the root package only where the autobuilder may fetch x/sys. Decided by the agent on
      2026-11-13, to review by the maintainer: no `require` is added, because it would let CI fetch a module
      (`GOPROXY=off`, "never injected" in `tools/test/fixtures/native-http-receiving/go.mod`); check after enabling
      that the analysis lists the root package, and pin x/sys v0.37.0 there only if it does not.
      [RELEASE] Left (2026-11-15): CodeQL is GitHub's default setup, a repository setting: re-enable Go after
      `native_http` is published.
- Moved to TODO-tests-windows.md (2026-11-15): native Windows TLS fixture.
- [ ] **Intermittent fixtures.** Claimed by worker K (2026-11-13). Close each after it stays green: Linux window switch, cffi-lua clone, desktop-webview
      AI focus, Windows `config` group, macOS Go `TestIdleDeadlinePhysicallyRetiresPeer`, macOS Swift
      `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope`.
      Scan of ci.yml runs 2026-11-07..10 (macOS and Linux): the cursor-display window switch step passed 40/40;
      no cffi-lua clone retry or desktop-webview AI-focus failure appeared (the webview lane's 4 failures were a
      managed Python download, a 504 and an on-screen pill check); `TestIdleDeadlinePhysicallyRetiresPeer` and
      `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope` never failed (Swift launcher step 37 passes,
      4 other failures). A new intermittent, `NativeAppClonerBundleOwnershipTests.testActualNativeCliLogLimits...`
      (runs 42438031643, 42480689370, `[Errno 1] Operation not permitted`), is fixed at its cause in bce01f27: XNU
      answers `killpg(group, 0)` with EPERM while the last members are unreaped zombies.
      Worker G, 2026-11-14 (Paris): Windows config-transition « guarded native adapter: genuine acquired-read timer
      custody » (dev run 43611195865, control mode, 0 hits in 512 attempts) is a geometric draw, not a hang: 57 hosted
      modes over 7 runs needed 71.5 attempts on average, up to 432, so 512 missed one mode in about 150 runs. The bound is
      2048 (about 3e-12 per run; a run pays it only on a miss), and `test-windows-config-timer-custody-bound.cjs`
      recomputes the chance from that sample and fails at 512. Keep it listed until the config-transition shard stays green.
      Worker C, 2026-11-14 (Paris): `test-linux-nix-native.cjs` (« 0 !== null » at `inventoryPhaseControls`, Release ci,
      run 43604680663, one local run in three) is fixed at its cause: the phase owner's capture watcher can send its
      TERM after the worker (`run-linux-managed-http-phase.py`) published `closed.json` with status 0, and Python
      resets its handlers to SIG*DFL while it finalizes, so the worker died by signal and the owner read status null.
      The worker now ignores TERM and INT once its closure receipt is final; regression
      `test-linux-managed-phase-late-term.cjs` floods the real worker with TERM after its receipt (fails on attempt 1
      with the old worker, 3 runs of 3), and the original test passed 8 runs of 8.
      Worker G, 2026-11-13 (Paris): the baseline flake `TestCancellationAndConcurrentClosePhysicallyRetirePeer` (macOS
      Intel Managed Ollama) is fixed at its cause in 694ac4c90e: a 120 ms deadline and a 200 ms idle clock could end
      the request before a slow runner had started the peer, so the retirement check found no receipt. Each case now
      cancels once the peer has recorded itself; a slow-start case (peer delayed 300 ms) fails with the old timing and
      passes now. `TestClientErrorPrivacyRetainsContextCause` had the same 100 ms race (4ae913e873). Keep it listed until
      the Intel cell stays green. Landed on 2026-11-14; both Managed Ollama and Managed Ollama build cells, Intel and Apple
      silicon, passed with the `slow-start` case in CI run
      [43579693369](https://github.com/adrienm7/ergopti/actions/runs/43579693369).
      New 2026-11-11: Install-and-launch `symlink_logs_dir` failed once in [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137) (job 130257482167) with "Quit did
      not end both processes within 10 s (the Quit AppleEvent was never answered)" while the same build quit in
      0.3–0.4 s in every other row. Its re-run (attempt 2, job 130295289361) passed and the macOS Verdict of
      42929436137 is green (job 130295941982); keep it listed until it stays green.
      Scan 2026-11-12 of ci.yml runs 2026-11-07..12 on dev, claude/* and tmp/\_ (282 of 353 runs listed, 71 runs of
      2026-11-07..10 and the second job pages of ten large runs not read; logs read for the A/B buckets and one sample
      per other failure group): `symlink_logs_dir` Quit timeout only once (job 130257482167 above); its failed-launch
      artifact (launch-gate-failed-ci-macos-15-symlink_logs_dir\_\_tilde_paths-attempt-1, with the launcher and
      Hammerspoon samples) could not be read from this session (artifact storage host refused by its network policy),
      so it stays unexplained. No failure of the window switch, cffi-lua clone, desktop-webview AI focus,
      `TestIdleDeadlinePhysicallyRetiresPeer` or `testBridgeHardDeath...` in the logs read; the sampled Linux install
      and webview failures were an APT mirror timeout (1200 s) and WIP tests. `NativeAppClonerBundleOwnershipTests`
      EPERM appears twice more, in [42940650392](https://github.com/adrienm7/ergopti/actions/runs/42940650392) and [42927169227](https://github.com/adrienm7/ergopti/actions/runs/42927169227), (2026-11-11, macOS 26); whether
      their sources hold its fix bce01f27 is not checked (that commit is not reachable from this clone). Nothing reproduced, so nothing was changed here; the keyboard-source refusals are under « [CI] Native
      keyboard-source fixture ».
      Worker K scan 2026-11-13 of the 11 completed ci.yml runs of that day (43347126427 to 43504755033, both attempts
      of 43430776650, every failed job's full log grepped): no failure of the Linux window switch (8 input-display jobs,
      `test:linux:window-switch` clean), the cffi-lua clone (absent from every log), desktop-webview AI focus
      (`PASS native GTK AI text focus: 31 cases` in all 8 jobs), `TestIdleDeadlinePhysicallyRetiresPeer`,
      `testBridgeHardDeath...`, the `symlink_logs_dir` Quit timeout or the App Cloner EPERM. One Windows config-group
      lookalike: `config-scope-global` in 43347126427 (job 131629578949, a structure-proof WIP source) stopped at
      `[WATCHDOG] run_llm_model_browser timed out` on test 23/29 (`model-browser-native-json`); single occurrence, not
      reproduced, kept listed. The macOS Intel `TestCancellationAndConcurrentClosePhysicallyRetirePeer/stall-header`
      failure (43430776650 job 131906822890) belongs to worker G's fix. Nothing reproduced, so no code changed.
      Worker A 2026-11-14: Windows core « Plain native CAS: a newer native copy retires only the old restore right
      (plain-native-cas-owner) » failed once in [43535291046](https://github.com/adrienm7/ergopti/actions/runs/43535291046)
      (job 132263577729, 2207/2208) and passed in 43530845290 and 43518505775. Cause: `_CB_PlainAuthenticate` refuses to
      read while any other window holds the clipboard, so a listener reading the foreign copy (the runner's clipboard
      history) defers settlement to the retry service, while the fixture asserted it at once. The production path is
      right; the fixture now waits for that real retry, and the new `foreign-wins-held` case holds the reader's lease
      at authentication so the deferred path runs on every run (branch `claude/ergopti-todo-cas-flake`).
      New 2026-11-14 (worker L), fixed at its cause: the Linux fedora Integration job of run 43514634523 failed
      `system-event-capture-policy` and `system-capture-integer-origin` (`run_system_event_capture.lua`: sleep
      86000 instead of 120000 ms). The fixture anchored its fake wall clock at the real now and advanced it by
      minutes; the job ran at 23:59:26 UTC, a gap crossed midnight and the day read back held only its share. Any
      branch, `dev` included, failed it in the last minutes before local midnight. The wall origin is held at
      23:00 today at the latest; regression `system-capture-before-midnight` starts the fixture at 23:59:26.
      New 2026-11-14 (worker L), not reproduced, kept listed: in [43538811340](https://github.com/adrienm7/ergopti/actions/runs/43538811340) (a branch touching no LLM code)
      Linux E2E network-ai failed `OwnedOllamaContainer.test_umask_0002_private_group_parents_install_and_start`
      (the owned Ollama start expired, `ollama_unreachable`), green on `dev` run 43506243390; macOS E2E Managed
      Ollama (Intel) failed « The managed Ollama build handoff never arrived » because its build job waited for a
      runner from 03:24 to 04:10 Paris and finished at 04:18:45, after the consumer's wait ended at 04:17:20 (CI
      capacity, not code).
      Worker C 2026-11-14 (Paris), not mine, left open: desktop-webview « The privacy owner follows real GTK fields
      on the accessibility bus » failed in [43611736406](https://github.com/adrienm7/ergopti/actions/runs/43611736406)
      (branch `claude/ergopti-todo-nix-late-term`, whose commits touch only the managed phase worker and the native
      theme data), the same AT-SPI family as worker J's secure-field probe below; its own fixture may need the same
      ready-file wait.
      Worker J 2026-11-14, two Linux intermittents fixed at their cause (keep listed until they stay green):
      (1) desktop-webview « The secure-field probe on a real accessibility bus » failed once in 16 runs
      ([43549510667](https://github.com/adrienm7/ergopti/actions/runs/43549510667), job 132327549143):
      `FAIL one application with a focused text field: expected role=61, got inconclusive`, the next two checks green; again in [43579693369](https://github.com/adrienm7/ergopti/actions/runs/43579693369) (job 132404013294). `run_atspi_focus.sh` probed each GTK fixture after a fixed
      `sleep 3`; a first application slow to start on a freshly installed runner was not up yet (reproduced locally
      by delaying the fixture's start 4 s: the old script fails that first check only, the new one passes). The
      fixture now writes a ready file once its window is active and its field focused, the script waits for it and
      for the accessibility bus address (`wait_a11y_bus.py`) instead of sleeping, and prints the probe's own errors.
      Regression: `test_atspi_fixture_lifetime.py` FixtureReadinessTest. (2) network-ai
      `run_owned_ollama_container.py` hit its 60 s ceiling in 2 of 14 runs, on a different case each time
      (worker L's « not reproduced » entry above; `test_umask_0002...` in [43538811340](https://github.com/adrienm7/ergopti/actions/runs/43538811340), `test_unreachable_pac...` in [43504755033](https://github.com/adrienm7/ergopti/actions/runs/43504755033)), with
      `Local Ollama repair failed (runtime_retry_refused)` and the owned daemon not running. `runtime_repair.lua` refused a delivered
      readiness-retry timer when the budget's precise clock (`uv.hrtime`) showed less than the poll delay elapsed;
      the timer runs on libuv's loop clock, read from the coarse monotonic clock on Linux, so it can end a few
      milliseconds early on the budget's clock and a daemon still starting at the first probe was refused. The repair
      now waits out that shortfall before probing (the master budget still bounds every wait). Regression:
      `test_runtime_repair.lua` « a retry timer ending short on the budget clock waits out the shortfall, then probes ».
      Linux only: macOS and Windows do not compose this repair.
      [LATER] Left (2026-11-15): no known code left; keep watching each listed fixture over further runs.

## Maintainer decisions pending

Each question names the default kept meanwhile; an answer moves into the item or into
[maintainer decisions](docs/memory/maintainer-decisions.md).

- [ ] **Site placements decided by the agent on 2026-11-14 (implemented: fb510e1113, f555c231e5).** The former
      Utilisation page is split into `/ergopti/utilisation` (« Essayer » : online typing and text replacements) and
      `/ergopti/installation` (downloads, OS guides, printable layouts); `/utilisation` without an anchor lands on
      installation. No `/ergopti/faq`: the layout has no FAQ content yet (« Autocritiques » stays in Informations).
      Ergopti+ sub-pages: présentation (Pour qui, Déjà en Ergopti, Comparatif), hotstrings, ia, fonctionnalités
      (tap-holds, raccourcis, trackpad, métriques), configuration (réglages, vie privée), installation (démarrer,
      télécharger), faq; no « versions » page, its changelog stays in the app. The floating reference keyboard only
      shows on the `/ergopti` pages. The Studio icon (`static/img/logo/studio.svg`: a keycap and a pencil on the dark
      disc of the logos) is new. Approve or change.
- [ ] **Windows layout DLL builder on a PC without the ARM64 C++ tools? (asked 2026-11-16)** The PC's Visual Studio
      2019 Build Tools have the x64/x86 tools only; `build_windows_keyboard_layout.ps1` requires ARM64 too and refuses
      before compiling. The three other images compile there (TODO-tests-windows.md, PC run 2026-11-16).
      `docs/design/layout-windows-dll.md` wants all four images in every package (the installer copies the one of
      the running Windows), so an x64-only package would break an ARM64 install. Kept meanwhile: four images or
      nothing.
  1. **(recommended) Keep the builder strict;** the release package stays CI-built (the Windows runner has ARM64),
     and the PC checks install the CI artifact `Ergopti_windows_layout.zip`.
  2. Add `-Builds amd64,x86,wow64` for a local check into a folder of its choosing, never packaged and never
     written to `vendor/keyboard_layout`.
  3. Install the « MSVC ARM64 build tools » component on the PC (administrator, Visual Studio Installer).
- [ ] **Linux: a touchpad unplugged while gestures are on (asked 2026-11-16, deep audit linux-gestures « Device
      loss / hotplug »).** A failed touchpad read stops the reader and logs « re-enable gestures to retry »
      (`modules/gestures/manager.lua` `pump`); plugging the pad back starts nothing. Read in the source on 2026-11-16:
      the master stays on with no reader, and `capture_scope_state` refuses that state, so every gesture setting
      (the switch, bindings, the restore and clear of the section) is refused until the daemon restarts. macOS and
      Windows receive gestures from the OS, which keeps them across a reconnect. Kept meanwhile: today's stop.
  1. **(recommended) Look for the pad again:** while the master is on and its pad is lost, the pump runs the
     finder every few seconds (a new `[gestures]` registry delay, one INFO line at loss and one at return, none per
     attempt) and reopens it; « on, waiting for its touchpad » becomes a state the gesture scope admits, so settings
     stay editable meanwhile. A pad first plugged after a start that found none is not watched.
  2. Turn the master off at loss (the config keeps `enabled = true`, the next start reads the pad again) and
     notify the user once; settings stay editable.
  3. Keep today's stop and only make the settings editable while no reader runs.
- [ ] **Open questions of the 2026-11-15 hand-off.** The identity gate's false positive on every PDF's root trailer
      key in containers whose home is the root account's (left unchanged); the casing of BEO, INTS, UCIEA, AHEI,
      MTGAP-T and CTGAP 3 (the agent's spelling kept); the dead-key marker style (`key-legend-dead`: accent colour
      and corner mark); ISO ticks for split and ortholinear boards.
- [ ] **Agent decisions to review.** Each is implemented as written; confirm or change:
  - one-shot modifiers: one `sticky_altgr` covers AltGr and Kana (Windows sends the layout's own AltGr key, Kana on
    a Kana-style layout); the shipped AltGr key keeps its Tab tap;
  - value limits ([inventory](docs/design/value-validation-inventory.md), « Migration status »): LLM temperature 0
    to 1.3, context length 80 to 4000, CapsWord idle timeout at most 3600 s, URLs at most 2048 characters, the
    updater interval on its snap-to-preset rule, `tap_holds.sticky_timeout_ms` up to 2147483647 ms, and each
    family's row decision;
  - compilers: Kana keeps AltGr in a KLC when its key is Right Alt;
  - Ergopti Studio: one page per window; the menu row right after « Keyboard layout »; the editor's tab bar
    placement; the key-colour selector and its green-to-red scale; the Comparer's colours, folding and share
    wording; one fingering profile per keyboard model (version 1 profiles not carried over); app downloads land
    in the Downloads folder rather than a save dialog (Hammerspoon and WebKitGTK have none); the KLA JSON and
    Kalamine TOML exports (coordinator, 2026-11-14); the source's `nav` layer as the one navigation source,
    `layers.toml` its compiled form with a `# source:` and `# body-fnv1a32:` header (coordinator, 2026-11-15);
  - Linux: the GNOME extension's `org.ergopti.InputSource1` admits any client of the session bus; GTK 3 Compose
    sets `GTK_IM_MODULE` only, from the user installer only;
  - pause: a dead key pending in the system's own layout (no emulation) stays the OS's state; the macOS pause and
    resume notices are kept (Linux shows them too);
  - parity: GSD-1, the macOS live x1 swipe fires twice for a touch going right then back left (Windows and Linux
    once), kept as it is; HCD-3, macOS and Linux type one field for the named personal tags, as Windows;
  - performance: no `input.latency` span on Windows (its InputHook callbacks receive no event time, and a second
    permanent low-level hook for a metric would add a hook timeout risk to every key); the Linux `migrations.toml`
    parse is not cached (about 7 ms cold under LuaJIT).
- [ ] **macOS `migrations.toml` boot parse (about 30 ms of Lua 5.4).** Port the Windows typed SHA-256 registry cache
      (`settings/engine/publication/registry_cache.ahk`: a typed codec that evaluates no cached code, validation kept
      on a hit) to Lua, or not? Config migration is where a wrong cache would rewrite a user's settings; the Mac
      measurement of the saving is `migrations_registry_parse` in TODO-tests-macos.md. Kept meanwhile: no cache.
- [ ] **Linux keystats boot: a persistent sqlite3 child?** Registration, the two migration checks and the open walk
      cost one sqlite3 process each (about 4 ms); the remaining cut is a persistent child for the synchronous writer
      ([design](docs/design/linux-sqlite-persistent-child.md)). Approve it, then implement ([CODE]). Kept meanwhile:
      one process per query.
- [ ] **Parity decisions THD-1 to THD-4 and HCD-1, HCD-2, HCD-4, HCD-5.** Tap-holds
      ([report](docs/audits/platform-parity/2026-11-10-tap-holds/report.md)): THD-1 the pair tap and the layer, THD-2
      the lone window, THD-3 layer-hold pair activity, THD-4 the macOS thumb Backspace under modifiers. Hotstring
      cascade ([report](docs/audits/platform-parity/2026-11-11-hotstring-cascade/report.md)): HCD-1 an expired best
      candidate (macOS falls to a lower rule), HCD-2 a bare `:` or `;` ends a trigger on macOS only, HCD-4 the delay
      on `@` tags, HCD-5 an uppercase one-letter tag (privacy). Each report names the default kept meanwhile.
