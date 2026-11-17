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

The site and the Studio pages are scanned by axe-core in CI (tools/test/browser/site-accessibility.playwright.cjs,
ratchet baseline beside it, findings in [docs/audits/accessibility/](docs/audits/accessibility/README.md)); lower the
baseline as violations go.

- [ ] **Manual audit.** A checklist per page and per native window (keyboard walk, NVDA, JAWS, Narrator, VoiceOver,
      Orca, 400 % zoom and 320 px reflow), recorded in docs/audits/accessibility/; extend the axe scan to the app's
      own WebView windows (onboarding, menus' pages, metrics), not only those the site embeds.
- [ ] **Images and media.** Charts and heatmaps (Comparer, benchmarks) offer their numbers as a table and their bars
      say the visible label (axe `label-content-name-mismatch` on the score bars); videos get captions and
      transcripts.
- [ ] **Colour vision.** No information by colour alone (shapes, labels, patterns as well); palettes checked for
      deuteranopia, protanopia and tritanopia; non-text contrast ≥ 3:1 for UI parts and chart marks (axe does not
      check it).
- [ ] **Motion.** A pause button for the auto-advancing Ergopti+ hero demo when motion is not reduced (WCAG 2.2.2).
- [ ] **Dyslexia and reading.** Check every page at 200 % text with the wide spacing setting for clipped or
      overlapping text; plain-language texts, no justified text, comfortable line length.
- [ ] **Blind and low-vision users.** Screen-reader runs; heading order and landmarks per page; accessible names
      for the keys of the Studio's keyboard drawings (editor, Comparer, Optimiser) and a table view of a layout
      there (the site's drawings are tables since this pass).
- [ ] **Keyboard and motor.** Keyboard walk of the Studio (no traps, logical order), a click alternative for every
      drag (WCAG 2.5.7), no time limits; the download buttons nested in links on the installation pages (two
      focus stops each) become links styled as buttons; the legacy /ergopti-plus-old lists hold paragraphs.
- [ ] **Cognitive.** Consistent navigation, clear error messages with how to fix them, confirmations before
      destructive actions, help text for every metric and setting.
- [ ] **Ergopti+ native UI.** The menus, windows (WebView2 and native), tooltips, notifications and onboarding on
      the three OS expose names and roles to the platform accessibility APIs (UI Automation, NSAccessibility,
      AT-SPI), follow the system's high-contrast, reduced-motion and text-size settings, and are usable with a
      screen reader and keyboard only; the hotstring and prediction tooltips are announced or can be.
- [ ] **Languages.** `lang` on foreign passages across the site (English names, quotes); the site is French
      only and the Ergopti+ page French and English: decide whether the accessibility texts get the 21 locales.

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
- [ ] **Layout formats, what is left.** The library comes only from Oxeylyzer and cmini: add another source: genkey
      (GPL-3.0 like cmini) once its layout list can be read, or KLA's built-in list (107 files under MIT in
      `layouts/` of patorjk/keyboard-layout-analyzer at c4f2f9bb43, which the KLA reader reads: four are reader
      fixtures in `tools/test/fixtures/layout-formats/third-party`). No third-party XKB symbols,
      KLC or DOF file under a licence that allows shipping it has been found for the reader tests.
      KLAnext's `matrix` board is refused (`format_unsupported_board`): no matrix file was found to read its key
      indexes from.
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
- [ ] **Incremental scoring with context choices.** Since the engine types each character the way that costs least
      in its context, `scoreSession` falls back to a whole-stream walk whenever the layout or the trial offers a
      choice of ways or uses a chord (exact, but Swann: Ergopti 95 → 17, Ergo-L 130 → 18 trials per second; AZERTY
      unchanged). Re-walk only the n-grams of the characters whose ways changed and of the multi-way characters whose
      shares of ways changed, re-planning only their contexts; keep the property test's 1e-9 bound
      (docs/design/layout-optimizer.md, « Follow-ups »).

## Layout analysis: best way of typing and bonuses (maintainer request, 2026-11-16)

Design: [docs/design/layout-analysis.md](docs/design/layout-analysis.md), « Ways of typing » and « Coverage and
simplicity bonuses ».

- [ ] **To review by the maintainer** (decided by the agent on 2026-11-16):
  - the choice of ways uses the default weights, not the user's, so live weight editing (`rescore`) stays exact;
  - a dead key closed by the space bar (any level) is never a context alternative: the pair metrics leave thumb keys
    out, so it hid SFBs behind an extra press (bépo typed « . » that way 6,936 times on Nemolivier);
  - `coverage_cap` 1,000 and the weights `coverage_bonus` 0.05, `simplicity` 0.03 (each bonus worth less than one
    point of SFB);
  - `char_coverage` (share of `reference_characters`, weight 0.1) is kept beside the new coverage bonus: retire it,
    or keep both;
  - simplicity rules left out as not objective: shifted sign related to its base sign, consistent layer logic, few
    mechanisms;
  - the trigram metrics of a layout with choices complete a fourth character as a Markov chain (SFS within 0.04
    points of the text’s own stream on Swann and Nemolivier).

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
      real mail/calendar (llm) ([18-scope review](docs/audits/platform-parity/2026-11-04-deep/report.md)).

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
      TODO-tests-macos.md), delete the shared mode and set the three macOS `follow_up` rows of
      `_shared/core/network/data/owned_runtimes.json` to done. [BLOCKED] on that pass.
- [ ] **Sign-in relay for the Swift-owned managed Ollama.** The design is written
      ([proxy-auth-relay.md « macOS managed daemon »](docs/design/proxy-auth-relay.md#macos-managed-daemon-design-not-built)):
      a Go `listen` command (bind `127.0.0.1:0`, one JSON line with port and token, serve until stdin EOF); the Swift
      worker behind `SuspendedImageOwner` starts it as the daemon's sibling before resuming the daemon;
      `managed_ollama_serve.py` runs `probe` before its bootstrap snapshot; Lua passes the `proxy_relay_receipt` path
      so a refusal lands in the receipt the pull reads. Until then, behind a proxy that requires a Negotiate sign-in,
      the managed daemon's pull fails while the stock start signs in. [CODE] Swift, Go, Python, Lua; the Swift tests
      run only on the macOS lane.

### All drivers

- [ ] **Structure plan, phase 2** ([plan](docs/design/structure-plan.md), resume point
      [docs/plans/structure-migration-resume.md](docs/plans/structure-migration-resume.md)). Left: S23 (clipboard) to
      S38, one step per commit with `tools/audit/structure/run-phase2.cjs`, two or three per push after a CI proof.
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

- [ ] **[RELEASE] First `main` push after 1.0.9.** `main` is still at 4d834c866a; dev.174 and dev.175 are published
      as v1.0.10 (ci.yml keeps the legacy core up to counter 169, the `v0.0.0-dev.169` bridge). Merge to `main` with
      `Release-As: 1.0.10`, then check that CodeQL, which scans `main` only, closes the 32 alerts fixed on dev on
      4 November (a3d69950e5..89b0b774c8), and that the dev site deploys by itself: `deploy-site.yml` runs from the
      default branch, so the gate that publishes a red `dev` run whose site jobs all passed
      (`tools/ci/site-deploy-admission.cjs`, on dev since 1d9c242070) takes effect only then. Closes on the first
      `dev` push that deploys with ergopti.fr/dev/editeur in gh-pages `dev/`.
- [ ] **[RELEASE] 16/38, one all-green three-OS checkpoint on the final source** (units, E2E, packaging,
      installation, launch). Windows, macOS and Common are green (run 43693237215); the Linux E2E updater stays red
      until a post-move dev prerelease exists, since its live step updates this checkout to the newest published
      prerelease.
- [ ] **[RELEASE] macOS release cells.** The Ollama Go cell (cda1e10c5e) passes on the release candidate's own
      source; item 31's lane runs once its runtime build is green; item 40, the eight Karabiner
      default/recommended/switch variants, runs on a Developer ID signed build (the ad hoc signed receipt passed in
      run 42929436137).
- [ ] **[RELEASE] CodeQL Go.** CodeQL is GitHub's default setup, a repository setting: re-enable Go once the
      `native_http` Go module is published, then check that the analysis lists the root package (it imports
      `golang.org/x/sys/unix` on Linux and macOS); pin x/sys v0.37.0 there only if it does not (no `require` is added
      meanwhile, since CI runs with `GOPROXY=off`).
- [ ] **[CI] Intermittent fixtures.** Close each once it stays green over further runs; no known code is left:
  - Linux: the window switch, the cffi-lua clone, desktop-webview AI focus, and desktop-webview « The privacy owner
    follows real GTK fields on the accessibility bus » (failed once in 43611736406; its fixture may need the ready-file
    wait the secure-field probe got);
  - Windows: the `config` group, including the config-transition timer custody (bound 2048,
    `test-windows-config-timer-custody-bound.cjs`) and one `run_llm_model_browser` watchdog on
    `model-browser-native-json` (43347126427, not reproduced);
  - macOS: Go `TestIdleDeadlinePhysicallyRetiresPeer` and `TestCancellationAndConcurrentClosePhysicallyRetirePeer`
    (Intel Managed Ollama, fixed with its `slow-start` case), Swift
    `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope`, and the Install-and-launch
    `symlink_logs_dir` Quit timeout (once in 42929436137, unexplained).

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
- [ ] **macOS `migrations.toml` boot parse (about 30 ms of Lua 5.4): cache it?** Windows skips the parse with a typed
      cache keyed by the registry's SHA-256 and the parser files' identity
      (`settings/engine/publication/registry_cache.ahk`, validation still runs on a hit); config migration is where a
      wrong cache would rewrite a user's settings. The Mac measurement is `migrations_registry_parse` in
      TODO-tests-macos.md. Kept meanwhile: no cache.
  1. **(recommended) Wait for the Mac measurement,** then port the Windows cache to Lua only if the parse costs over
     20 ms (native `hs.hash.SHA256` of the source and parser files, a typed codec that evaluates no cached code,
     validation kept on a hit).
  2. Port the Windows typed cache now, before the measurement.
  3. Never cache: 30 ms at boot is accepted.
- [ ] **Linux keystats boot: a persistent sqlite3 child?** Registration, the two migration checks and the open walk
      cost one sqlite3 process each (about 4 ms); the remaining cut is a persistent child for the synchronous writer
      ([design](docs/design/linux-sqlite-persistent-child.md)): about 29.5 ms of store boot would become 5 to 7 ms,
      and each later synchronous read (dashboard `query_rows`, `get_meta`) would save its 4 ms. Kept meanwhile: one
      process per query.
  1. **(recommended) Build the persistent child** as the design writes it (one `sqlite3` spawned through LuaJIT FFI,
     each success acknowledged by a per-call random token, a refused statement ending the child and the next call
     starting a new one, a read deadline added), then implement ([CODE]).
  2. Keep one process per query: 30 ms at boot is accepted.
  3. Link `libsqlite3` through FFI, the largest saving, which breaks the driver's rule of never linking SQLite.
- [ ] **Parity decisions THD-1 to THD-4 and HCD-1, HCD-2, HCD-4, HCD-5.** Tap-holds
      ([report](docs/audits/platform-parity/2026-11-10-tap-holds/report.md)): THD-1 the pair tap and the layer, THD-2
      the lone window, THD-3 layer-hold pair activity, THD-4 the macOS thumb Backspace under modifiers. Hotstring
      cascade ([report](docs/audits/platform-parity/2026-11-11-hotstring-cascade/report.md)): HCD-1 an expired best
      candidate (macOS falls to a lower rule), HCD-2 a bare `:` or `;` ends a trigger on macOS only, HCD-4 the delay
      on `@` tags, HCD-5 an uppercase one-letter tag (privacy). Each report names the default kept meanwhile.
