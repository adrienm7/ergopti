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

## Next session (state on 2026-11-17, read first)

- **Goal unchanged:** a fully green `dev` CI, then publish dev prerelease 176; then empty this file.
- **Load and disk (maintainer):** at most 5-6 agents at once and at most 2 running heavy local suites (full AHK
  groups, WSL Lua suites, interactive desktop checks); prefer CI on temporary `ci/verify-<sha>` branches (deleted
  after reading). After each agent: remove its worktree and scratch files; purge stale scratch dirs, WSL `/root`
  copies and the npm cache regularly; compact the WSL disk image when no agent uses WSL (C: reached 2.8 GB free).
- [ ] **Land the optimizer speed-up.** Branch `perf-typing-ids` (6 commits, rebased on c8cd556bab): Ergopti 57 →
      110, Ergo-L 39 → 93, bépo 35 → 57 optimizer trials/s; golden gap 0, property and stress tests exact. Rebase
      on `dev`, push, then delete the remote branch.
- [ ] **CI reds left after verify run 44072500520** (decisions taken 2026-11-17):
  - Windows SSPI curl flake: the TLS test server closes while the client's TLS close is still in flight (reset
    10054). Maintainer decision: half-close then wait (bounded) for the client's close, and revise the pinned test
    « queued peer TLS close is processed without a peer wait ».
  - macOS Intel « managed Ollama build handoff never arrived »: maintainer decision: make the consuming cell
    `needs` the Intel build job and update `macos-stage-contract.json` with its review.
  - Shared-literal ratchet: `windows.path_name` 49/48 (`NOTIFIER_PRODUCT_NAME`, 11de860899) and
    `macos+linux.lua_function` 105/104 (`reload_emulation`, e13e110319): move them to a shared home.
  - Linux desktop-webview: `programmable_publication_stale` in the real-GTK field test (5b4110f703), maybe flaky.
  - Re-read the first complete run after these; keylayout owner pin and Menus « cold command section » to confirm.
- [ ] **Exact-count ceilings in tests (maintainer: « ces tests avec seuil magic value c'est vraiment mauvais »).**
      `toml.flat_values` was raised to 1500/2600 on 2026-11-17 to unblock CI. Replace exact operation counts and
      similar magic thresholds (boot operation ceilings, literal ratchets where they only count) with budgets that
      mean something (time, order of magnitude, or a named single source), one ratchet at a time.
- [ ] **Intermittent tests to redo on a quiet PC** (the agent was stopped because the PC was overloaded): the
      « [CI] Intermittent fixtures » item below plus healthcheck collection, SendInstant, Ollama native,
      `groups247-*` order dependence, native clipboard/picker, WebView picker cleanup, `idle-caret-context`,
      `key-state-dllcall-uncaught`.
- [ ] **Register row** in `docs/platform-parity-audit.md` (module « Key combinations and macOS bindings ») for
      `docs/audits/platform-parity/2026-11-17-key-combinations-bindings/report.md`.

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
- [ ] **Images and media.** Videos get captions and transcripts (the charts, heatmaps and keyboard drawings have
      their tables since the second pass).
- [ ] **Colour vision.** Left after the third pass (heatmap key edges, finger hues, metrics muted text, AI tooltip
      hint and info lines): a colour-only review with the dataviz validator of the other app windows (onboarding,
      download window, the hotstrings window's 14-colour palette in `native_theme.toml`).
- [ ] **Dyslexia and reading.** Check every page at 200 % text with the wide spacing setting for clipped or
      overlapping text; plain-language texts, no justified text, comfortable line length.
- [ ] **Blind and low-vision users.** Screen-reader runs; heading order and landmarks per page; the Optimiser's
      result board (plain characters) has no table view of its own (« Open in the editor » gives one).
- [ ] **Keyboard and motor.** Keyboard walk of the Studio (no traps, logical order), no time limits.
- [ ] **Cognitive.** Consistent navigation; check that every error message says how to fix it and every metric and
      setting has its help text.
- [ ] **Ergopti+ native UI, what is left.** The clear fixes of the code audit
      ([table](docs/audits/accessibility/README.md#native-ergopti-ui-code-audit-2026-11-17)) are in on the three OS
      (tray / menu-bar names with the pause, labels and named controls, tooltips under high contrast, previews told
      to a running screen reader). Left: fixed font sizes in the Windows native windows other than the tooltips;
      the GNOME text scale; the WPM widgets, the spotlight overlay and `hs.alert` banners, still invisible to
      screen readers; the Swift update panel's XCTest, not yet run in CI. The spoken results are the
      « Accessibility » items of the three TODO-tests files.
- [ ] **Languages.** `lang` on foreign passages across the rest of the site (English names, quotes); decide whether
      the accessibility texts get the 21 locales.

## Ergopti Studio

Design: [layout-editor.md](docs/design/layout-editor.md), [layout-analysis.md](docs/design/layout-analysis.md),
[analyser-scores.md](docs/design/analyser-scores.md), [layout-optimizer.md](docs/design/layout-optimizer.md); the
analyser study is [docs/audits/layout-analysers/report.md](docs/audits/layout-analysers/report.md) (its section 15
waits for the maintainer's review).

- [ ] **Layout formats, what is left.** KLA's 16 files with characters on keys the library's keyboards lack (12 of
      them ErgoDox) stay in `not_imported` of `layout_library.json` until the keyboard model, the KLA reader and the
      library can place ErgoDox thumb and outer keys. KLAnext's `janiso` board is refused
      (`format_unsupported_board`) until the model has the JIS keys; its `ergolinear` has no layout to read.
- [ ] **[LATER] Layout library credits, what is left.** The credits were read on their authors' pages on 2026-11-17
      (`checked` and `evidence` in `layout_credits.json`). Still « knowledge »: QWERTY (US patent 207,559 is Sholes's,
      but its text names no letter order: read its drawings or another primary source) and KOY (neo-layout.org names
      no author, adnw.de has no page for it). The 53 « collection » credits come from KLA's « author » field, which
      can name the person who submitted the layout: check each against its author's page, first the doubtful ones
      (Klausler « Kaimakides », Neo 2.0 « Julian Asamer », CarpalxQ and QWERTY Wide Mod « Dave Ferree »).
- [ ] **[LATER] More Google Books and Leipzig languages.** The importer (`tools/build/import-count-tables.cjs`)
      streams Google Books 1-gram shards without storing them (`google_books_1grams`, French shipped). Left, one
      language per session at about 1 MB/s: English (24 shards, 6.4 GB), German (8, 6.2 GB), Spanish (3, 1.9 GB),
      Italian (2, 2.3 GB): add each to `static/corpus/count_table_sources.json` with empty `sha256` pins, its
      register entry and corpus with a `title_key` in the 21 locales, then run the importer with `--record-pins`.
      Languages with no Optimiser label yet (Portuguese, Dutch: Leipzig has `por_wikipedia_2021_1M` and
      `nld_wikipedia_2021_1M`) also need their `layout_optimizer.language.<code>` string and a library layout.
- [ ] **[LATER] Site keyboard for other layouts.** The site's Ergopti drawing is generated from
      `static/layouts/sources/ergopti.toml` (`tools/codegen/codegen-site-keyboard.cjs`, display patch
      `src/lib/keyboard/data/ergopti_display_patch.json`). Left from the maintainer's 2026-11-14 request: display and
      emulate any layout source the same way (a patch per layout, or a default patch for layouts without Ergopti+
      levels); the selector's older Ergopti versions (1.1 to 2.1) stay frozen snapshots without a source.
- [ ] **[LATER] « Ma frappe » saved read on macOS and Linux (2026-11-17).** Windows pushes its last complete Studio
      read at once (`metrics\cache\studio_ngrams.json`) because its worker replays new events and may re-save a
      1.1 GB reader image first (30 s and more). macOS and Linux have no such worker: they read `db.sqlite` read only
      and keep the projection per `meta.rev`, so only the first open after a restart pays the read. The same SQL took
      0.75 s warm and 4.5 s with a cold page cache on the maintainer's 1.1 GB image (290 KB of JSON). Measure that
      first open on a large macOS store (Hammerspoon reads on its main thread) and on Linux before deciding whether
      they save the read too.
- [ ] **[RELEASE] Windows export step in native Lua.** The restricted host `windows/native/ergopti_lua_export.c`
      (pinned Lua 5.4.6, built by `tools/build/build_windows_lua_export.ps1` in package-windows) is done. Left: once a
      dev run builds « Windows / Build », commit its artifact `windows-lua-export-*` (`ergopti_lua_export.exe` and
      its `.json`) into `windows/vendor` with their `required` entries in `tools/build/windows_bundle_manifest.json`;
      then `test-windows-lua-export-identity.cjs` checks them and the Windows lane runs the byte-equality proof.

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

## Parity audit

The [coverage and remaining-work register](docs/platform-parity-audit.md#review-status-at-pause--november-5-2026)
and the campaign reports under [docs/audits/platform-parity/](docs/audits/platform-parity/) record what is done.
Native receiving stays unqualified everywhere; the real-machine scenarios are in the TODO-tests files.

- [ ] **[CODE] Parity audit continuation.** Reconcile current source areas with the register (the 2026-11-12 census
      listed 381 areas, many changed since their campaign), then take one bounded module at a time across Windows,
      macOS, Linux and shared; do not restart a finished campaign without source drift or a new hypothesis. Left:
  - a fresh census against the last pinned one
    ([tap-holds follow-up](docs/audits/platform-parity/2026-11-12-tap-holds-followup/source-areas.json)) now that the
    structure phase moved most folders, then the areas outside every campaign (the never-campaigned list of the
    [start-at-login report](docs/audits/platform-parity/2026-11-12-start-at-login/report.md) was taken by the
    menus-tray, i18n-runtime, editors, healthcheck, onboarding, Linux install and tooltips-wpm campaigns);
  - the navigation layer's wheel on macOS (BNM-1 of the 2026-11-17 key-combinations and bindings pass): it stops
    when the Shortcuts switch is off, because it is a child of the bindings layer (`bindings.lua:288`) that switch
    pauses whole (`menu/ui/builder/state.lua:710-713`, `modules/shortcuts/init.lua:337-341`); on Windows and Linux
    only the layer gates it, and the macOS menu says it is no shortcut. Give it its own owner outside the
    Shortcuts-gated layer, still held back by a script pause, with a unit test that `pause_bindings` leaves it bound.
- [ ] **[RELEASE] Windows/Linux feed-only update fallback.** Built: the Versions window's feed-only list installs the
      channel's newest release through its required detached signature on both (`feed-only-install` tests, throwaway
      key in `feed_install_vectors.json`); without a key every feed row keeps the no-details refusal. Left, at release
      time once `public_key_spki_base64` is provisioned: the step-4 check of
      [update-signing](docs/tooling/update-signing.md) (a real feed-only install on Windows and Linux, the log saying
      the signature verified, an older row refused), then enforcement `required`.
- [ ] **[CI] Number-row cohort still selects in the XCTest process (macOS).** The refused restores were not a stale
      test-process cache: the TIS probe (`probe-macos-tis-cache.yml`) left HIToolbox's own current layout
      (`AppleCurrentKeyboardLayoutInputSourceID`, read by every process, the launcher included) on the old source while
      the selected list moved, 3 times in about 5,900 steps of a process that is an application and selects, under a
      storm of selection notifications, and never when a plain child selected (runs 44025301586, 44029045918);
      re-selecting the already-selected source does not repair it. The shared `KeyboardSourceSelectionFixture` now
      selects through the launcher's headless role, and refusals name `system_current_layout_stale` or
      `process_current_source_stale` from the recorded system layout. Left: `NumberRowSourceProbeTests.swift` keeps
      its own in-process selection because its bytes are the reviewed image `number_row_current_test_causal.py` pins
      (`CURRENT_TEST_SHA`); moving it to the shared fixture needs that review renewed. No retry is added.

## Carried over from the 1.0.9 requests

- [ ] **Slowness, Windows boot.** Left, largest first, process CPU measured 17 November on the maintainer's
      configuration (`tools/dev/bench-ahk-startup.cjs` smoke boots with one warm-up boot, loaded PC, median of 5
      interleaved boots, summed CPU about 7.6 s): script parse before the first line, 2.0-2.2 s (`/validate` alone
      takes as much; it follows code volume, full-line comments are only about 200 ms of it, so only a smaller
      include graph or a worker helps); hotstring registration 1.2 s, needed at the first key (the registrars cost
      about 0.5 ms per cached row with its case variants, the `generated_hotstrings.tsv` admission about 110 ms);
      layout and remaps 1.0 s (a disk cache is rejected: native hotkey registration), of which the two Ergopti
      `.keylayout` parses about 170 ms, their spec 60 ms, the registry read 70 ms (its `index.json` decoded twice),
      `platform/remap.ahk` 150 ms, the magic editor's source probe about 150 ms (per-key number-row policy reads)
      and cohort acquisition 135-250 ms; the configuration stage 690 ms; the tray menu 650-700 ms after the keyboard
      and before ready; the shortcuts stage 270 ms; the AI catalogue 230 ms (deferring it means a lazy accessor for
      its 184 readers). The i18n stage is 60-80 ms warm: its 700 ms and 480 ms of the hotstring stage in earlier
      notes were cold caches of a fresh private code copy, which the benchmark now warms first. A smoke boot beside a
      resident driver is suspended, so it does not measure the keyboard arbiter of the prefix-watcher stage. The PC
      timings and the macOS field points `rerun_2026_11_02` and `main_thread_holds` are in the TODO-tests files.
- [ ] **[RELEASE] Before publishing.** On a quiet PC with no resident driver: the whole AHK suite,
      `npm run test:ahk-tray-rows-read-as-text`, every live check including `quit-over-a-log-flush`, the JS, macOS and
      Linux suites, and a Windows field report with a driver.

## Remaining code work

### Windows

- [ ] **TakeNote probe on the PC.** TakeNote binds each note to its UI Automation tab (a1cd4d2891). The probe
      `takenote-native-document-owner` now reads the only visible RichEdit control (the selected tab's, not a restored
      one's), owns every window of the Notepad its canary proved, reports its first error before the cleanup's, and
      is not executed while another Notepad runs. Still to qualify on the PC with every Notepad window closed: both
      modes green, and no « ambiguous » or `last_observe_error` in the CLEANUP line; if Notepad keeps the hidden tabs'
      controls visible, read the selected document through UI Automation instead.
- [ ] **An expansion burst beside another AutoHotkey hook is not atomic.** SendInput then falls back to
      SendEvent. Since 2026-11-18 the burst goes out unpaced (`asa-space-burst-unpaced`): 10 to 15 ms instead of
      80 to 90, and `asa-space-fast` passes 20/20 beside a second hook. A key struck within those milliseconds
      still lands inside the burst. Holding such keys through the roll block was tried and lost a key
      (`#MaxThreadsPerHotkey`; see `project-hotstring-output-is-final` in `docs/memory/windows-ahk.md`); a fix
      needs an owner that buffers physical keys without one hotkey thread per key, such as the native capture.
- **Parity literals.** PAR-58 families not yet consumed: `terminator_restoration`, `context_buffer`,
  `request_plan_*`, the keystats families, `row_options`, `menus/*`. PAR-74: 549 literals left; the rest of the menu
  files need `test-menu-manifest` to stop pinning their spelling. PAR-79: 4 Windows timer literals left (13 in
  `timer-literal-baseline.json`, 9 of them in the archived `old/kalamine` scripts), and none can move: the 3 startup
  smoke sleeps of `ErgoptiPlus.ahk` and the UIA worker's idle `Sleep(250)` run before or without the registry.
- **Tests.** Source assertions left to convert to behaviour (3,799 `_Driver*` source reads in 991 files; 68 meta
  files still name `A_IsSuspended`, 57 of them outside comments). Counted over `windows/tests/**/*.ahk` as calls to
  `_DriverFuncBody`, `_DriverFuncBodyOrEmpty`, `_DriverSourceConcat`, `_DriverSourceNoComments`, `_DriverDirConcat`,
  `_DriverDirsConcat` and `_DriverFileSource`, and as `tests/meta` files containing `A_IsSuspended`. Guards that
  would send keys, paste or move the cursor when broken (text sender, inline auto-type, tap-hold, dead keys,
  `SimulateActivity`, the keep-awake start, the bridge start) need a seam first. Guarded a second time downstream,
  so a behaviour test of their own guard could not fail: the ROI half-life tick, the click handlers, the updater
  background tick, the ShellRunner pollers, the ingest tick and the click-hold key watcher (its paused branch does
  what the running one does). Owners outside the headless runner (`Ergopti_OnSuspendEnter`/`Resume`, the layout
  poll, the model browser bridge) stay source reads until they get a harness.
- **Signing follow-ups (maintainer).** The workflows and scripts are ready; only these steps are left. SignPath:
  after acceptance, set the secrets `SIGNPATH_API_TOKEN` and `WINDOWS_SIGNER_SUBJECT` and the variables
  `SIGNPATH_ORGANIZATION_ID`, `SIGNPATH_PROJECT_SLUG` and `SIGNPATH_SIGNING_POLICY_SLUG`, approve the first stable
  request, then delete `.github/ci/stable_windows_signing_exception.json` alone in a commit
  ([steps](docs/tooling/signpath-foundation-application.md)). Update assets: run `keygen`, store `UPDATE_SIGNING_KEY`,
  commit the public key, cut one `off` release and check both `.sig` files, then set `enforcement` to `required`
  alone in a commit ([steps](docs/tooling/update-signing.md)). The relay exe and the vendor binaries stay unsigned
  (a second SignPath request).
- **Older findings** ([the 2026-10-28 Windows audit](docs/audits/windows-2026-10-28/README.md)). Findings 1 to 4
  and 6 to 8 are fixed. Left: finding 5's native binaries and manifests, rebuilt in the official MSVC environment
  (the maintainer's step: the PAC source fingerprint covers the builder scripts). Item 36, the updater production
  coupling: the inactive « original23 » collector (`tools/ci/run-windows-updater-original-diagnostic-cohort.cjs`)
  needs a first trusted PowerShell host, which a PowerShell script cannot acquire for itself before it runs. It
  needs a native pre-host launcher with an approved image contract, which is a maintainer decision (which signed
  `powershell.exe` image, checked how) and a new tracked binary from the same MSVC build.

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

### All drivers

- [ ] **Structure plan, phase 2** ([plan](docs/design/structure-plan.md), resume point
      [docs/plans/structure-migration-resume.md](docs/plans/structure-migration-resume.md)). Left: S26 (hotstrings) to
      S38, one step per commit with `tools/audit/structure/run-phase2.cjs`, two or three per push after a CI proof.
      Paths that describe a published artifact (a prior release's payload, a historical pin) keep their old spelling.
- **Provider flags inferred, not read.** Only provable with a live key: SambaNova's `enable_thinking: false` (off is
  its default, the docs show only `true`) and the Chutes Qwen `enable_thinking` field; a refusal is dropped and
  remembered either way.
- **108. Per-device physical bindings.** Deferred until designed: the collision, source, modifier and output joins of
  a shortcut bound to a key position on one device; `keyboard_hook.capture_position` hands only `native_code` and
  `mods`.

### Linux

- [ ] **Archive downloads run one chunk per idle turn.** Measured on the model page flow (2026-11-17): an owned
      archive download reads 64 KiB, pauses, writes it and resumes only after the write's acknowledgement, a
      libuv event. The daemon's idle wait (`keyboard_hook.idle_wait`, up to 8 ms) polls the input and tray
      descriptors only, so each chunk waits up to two idle turns: about 4 MB/s at most, some 6 minutes for the
      1.4 GB Ollama archive. Each chunk's admission also re-reads `config.toml` (`runtime_source.read_source`,
      `install_resolver` stats of every ancestor): about 30 ms per chunk on a loaded 8-core WSL. Wake the idle
      wait on libuv's backend descriptor (as the tray's GLib companion does for D-Bus) and keep the per-chunk
      source check cheap without weakening the revocation it gives, then time a first install on the PC.
- [ ] **A touchpad tap's click meets an unknown field.** A button press is now counted before the click
      callback withdraws the field's privacy verdict (`keyboard_hook`, pointer-press-before-click), but a
      tap-to-click is counted on the frame that ends the tap, after the touch's own press already withdrew it:
      until the focus is read again (the periodic refresh after the settle delay) its click, and any wheel turn
      or travel just after a click, is not recorded. Count the tap in the context its touch began in, then
      extend `run_pointer_metrics_live.lua` with a uinput touchpad.
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

- [ ] **Screen-reader announcements of tooltips, decided by the agent on 2026-11-17.** Hotstring previews and
      finished AI predictions are announced only while the system says a screen reader runs (Windows
      `SPI_GETSCREENREADER`, VoiceOver, Orca), with no Ergopti+ setting; add a menu switch if users find them noisy.
- [ ] **Ergopti+ sections in French under the English page (decided by the agent on 2026-11-17, to review by the
      maintainer).** Ten sections of the Ergopti+ pages have no English text; they now say `lang="fr"`, so a screen
      reader reads them as French (`tools/test/test-ergopti-plus-languages.cjs`). Kept meanwhile: marked, not
      translated.
  1. **(recommended) Translate them** through `t()` and `locales/en.js`, dropping each `lang="fr"` as it goes.
  2. Keep them French on the English page.
- [ ] **Undo with no timer (decided by the agent on 2026-11-17, to review by the maintainer).** The Studio's restores
      offer « Undo » until the section is edited again or another restore replaces it, not for a few seconds (WCAG
      2.2.1, no time limits). Kept meanwhile: no timer.
  1. **(recommended) Keep it without a timer.**
  2. Hide the offer after a delay, paused while it has the focus or the pointer.
- [ ] **Site placements decided by the agent on 2026-11-14 (implemented: fb510e1113, f555c231e5).** The former
      Utilisation page is split into `/ergopti/utilisation` (« Essayer » : online typing and text replacements) and
      `/ergopti/installation` (downloads, OS guides, printable layouts); `/utilisation` without an anchor lands on
      installation. No `/ergopti/faq`: the layout has no FAQ content yet (« Autocritiques » stays in Informations).
      Ergopti+ sub-pages: présentation (Pour qui, Déjà en Ergopti, Comparatif), hotstrings, ia, fonctionnalités
      (tap-holds, raccourcis, trackpad, métriques), configuration (réglages, vie privée), installation (démarrer,
      télécharger), faq; no « versions » page, its changelog stays in the app. The floating reference keyboard only
      shows on the `/ergopti` pages. The Studio icon (`static/img/logo/studio.svg`: a keycap and a pencil on the dark
      disc of the logos) is new. Approve or change.
- [ ] **Row jumps in the global score? (decided by the agent on 2026-11-17, to review by the maintainer)** The new
      `row_jump` metric (two keys of one hand two rows or more apart, any fingers) is shown in the Comparer, the
      heatmap and the worst pairs, but has no weight: the study gives it none, and it overlaps SFBs and scissors.
      The effort per word uses the score's weights on the word typed alone, folded to lower case. Kept meanwhile:
      informative only.
  1. **(recommended) Keep it informative** until the study weighs it.
  2. Give it a small default weight (e.g. 0.5 point per %) in `score_weights.json` and the study.
  3. Count only jumps on different fingers, so it no longer overlaps the SFBs.
- [ ] **Open questions of the 2026-11-15 hand-off.** The identity gate's false positive on every PDF's root trailer
      key in containers whose home is the root account's (left unchanged); the casing of BEO, INTS, UCIEA, AHEI,
      MTGAP-T and CTGAP 3 (the agent's spelling kept); the dead-key marker style (`key-legend-dead`: accent colour
      and corner mark); ISO ticks for split and ortholinear boards.
- [ ] **Accessibility choices of the second pass (decided by the agent on 2026-11-17, to review by the
      maintainer).** The legacy `/ergopti-plus-old` page is kept and fixed, not retired, since the new Ergopti+ page
      links to it (« Ancienne version de cette page »); the system's « increase contrast » (`prefers-contrast:
more`, macOS and WebKit) does not switch the Studio frames to the black-and-yellow high-contrast theme, which
      stays the site setting's (the site itself has no such rule); the heatmap table lists keys by value, largest
      first, not in board order. Approve or change.
- [ ] **Configuration rows outside a reload** ([configuration follow-up](docs/audits/platform-parity/2026-11-12-config-followup/report.md)).
      (1) A `[script]` row (locale, log level, error dialog) absent from a restored or hand-edited config.toml on
      macOS: (a, recommended) reset its `hs.settings` value to the manifest default at the next adopt, as Windows
      whose file is the only store; (b) keep `hs.settings` as the authority and the file as an optional override
      (today's behaviour, kept meanwhile). (2) An external edit of config.toml while Linux runs: (a, recommended)
      rescan the hotstrings only and leave the rest to a reload, as macOS and Windows ignore it (today's
      behaviour, kept meanwhile); (b) re-read the whole configuration on Linux; (c) ignore it on Linux too.
- [ ] **Agent decisions to review.** Each is implemented as written; confirm or change:
  - a transform whose field changed after its Ctrl+C now puts the saved clipboard back over what the copy's own
    wait left (the selection), instead of keeping it as a possible user copy (decided by the agent on 2026-11-17);
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
  - Windows notifications (decided by the agent on 2026-11-17): every notice goes through `NotifierSend`, silent
    by default as the macOS and Linux adapters (which ask for no sound); only the notices that played the system
    sound keep it (`sound`: the update offer, the AI notices, the composer check). Feature, pause and quit notices
    lost their sound;
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
- [ ] **Wikisource texts as corpora: under which licence?** The built-in books come from Project Gutenberg
      (`static/corpus/text_sources.json`). Wikisource publishes its pages under CC BY-SA 4.0, while the works it
      transcribes are in the public domain and a faithful transcription arguably adds no new right. Kept meanwhile:
      no Wikisource text.
  1. **(recommended) Ship Wikisource texts as CC BY-SA 4.0,** the stricter reading, as the Wikipedia articles already
     are: only for a public-domain work Project Gutenberg lacks (author dead over 70 years, published before the US
     cut-off), each register entry naming the pages and revisions read and « Wikisource contributors » ([CODE]).
  2. Ship them as public domain, crediting Wikisource as the source only.
  3. No Wikisource: Project Gutenberg only.
- [ ] **An e-mail or chat corpus?** No candidate is cleared: the Enron mails hold personal data, the Ubuntu IRC logs'
      licence is unchecked, Wikipedia talk pages (CC BY-SA) sign each message with a user name. Tatoeba's short
      sentences are the conversational register meanwhile.
  1. **(recommended) None for now:** Tatoeba stays the conversational register until a source with a clear licence
     and no personal data is found.
  2. Check the Ubuntu IRC logs' licence and, if it allows shipping, import a bounded sample with nicknames replaced
     ([CODE]).
  3. Wikipedia talk pages under CC BY-SA 4.0 with the signatures stripped ([CODE]).
- [ ] **Norvig's n-gram counts? (decided by the agent on 2026-11-17, to review by the maintainer)** norvig.com/ngrams
      gives its code under MIT but no licence for its data files, which it says are « derived from the Google Web
      Trillion Word Corpus », distributed by the Linguistic Data Consortium under its own licence. Kept meanwhile:
      not imported; the Leipzig and Google Books tables cover the same need.
  1. **(recommended) Leave them out:** nothing read allows shipping counts derived from an LDC corpus.
  2. Ask Peter Norvig under which licence the counts may ship, then import them ([CODE]).
- [ ] **Tatoeba's full exports as count tables? (decided by the agent on 2026-11-17, to review by the maintainer)**
      Tatoeba's sentences are CC BY 2.0 FR, whose one condition is to credit each sentence's author; a count table
      holds no sentence, so its authors could only be credited together. Kept meanwhile: the 30,000-sentence
      samples, which name each author on its line.
  1. **(recommended) Import counts of every French and English sentence,** crediting « Tatoeba contributors » with
     a link to the export that names each author ([CODE]).
  2. The same, with the export's author list shipped beside each table ([CODE]).
  3. Keep the samples only.
- [ ] **Key-combination parity decisions KCD-1 to KCD-8 (2026-11-17 pass).** Kept meanwhile: each OS as it is.
  - KCD-1, « Copy tap → combo » under symmetry: Windows writes only the earlier order's chord
    (`KeyCombinationChordCopyRows`), macOS and Linux (shared `plan_chord_copy`) every order's own chord, which
    shows once symmetry is turned off. 1. **(recommended)** Windows follows the shared planner. 2. The shared
    planner writes only the owner order under symmetry.
  - KCD-2, a program launch or the monitor Alt-Tab in a chord: refused on Windows and Linux, admitted on macOS
    (Karabiner runs them). 1. **(recommended)** Keep macOS admitting them, with a platform reason on the chord
    picker of Windows and Linux. 2. Refuse them on macOS too.
  - KCD-3, a refused `[mod_combos]` delay or a non-boolean `enabled`: Linux turns every chord off, Windows and
    macOS warn and use the declared value. 1. **(recommended)** Linux warns and uses the declared value. 2. Keep Linux failing closed.
  - KCD-4, the one-shot Shift as a pair's tap: the Linux menu refuses it, its read admits it, Windows and macOS run
    it. 1. **(recommended)** Linux offers it. 2. Refuse it as a pair tap everywhere.
  - KCD-5, under symmetry the macOS menu hides the reverse-order pairs, tap and hold included, though the
    generator still applies them. 1. **(recommended)** List every pair, as Windows and Linux; only the chord row is
    shared. 2. Keep them hidden and stop applying their tap and hold.
  - KCD-6, `[mod_combos] enabled` switches every key combination on macOS, only the chords on Windows and Linux.
    1. **(recommended)** macOS reads `category_enabled.key_combinations` as its master and `[mod_combos] enabled`
       as the chords only, with a migration. 2. Windows and Linux read `[mod_combos] enabled` as the master.
  - KCD-7, a pair or chord across two keyboards: Linux refuses it, Windows and macOS admit it.
    1. **(recommended)** Keep it, with a platform reason. 2. Linux admits it.
  - KCD-8, the pair rows: summary, empty word, slot order and grouping differ on each OS.
    1. **(recommended)** All follow Windows (tap, hold, chord; a submenu per first key; the chord in the summary).
    2. Leave each OS's menu as it is.
- [ ] **Ctrl+★ → Ctrl+S on Linux (BND-1, BND-2, 2026-11-17 pass).** macOS has `cmd_star` (Cmd+★ to Cmd+S, extra
      modifiers kept), Windows `layout.ctrl_magic_save` (Ctrl + magic key to a bare Ctrl+S), Linux neither; its
      reason `platform_reason.layout_emulation_is_windows_only` says Linux installs the layout as XKB with nothing to
      switch off, stale since Linux emulates the layout (`modules/keymap/layout_emulation.lua`). Kept meanwhile: no
      Linux option. 1. **(recommended)** Port `ctrl_magic_save` to the Linux emulation, keep extra modifiers on
      Windows and Linux as macOS does, and correct the reason in the 21 locales ([CODE]). 2. Keep it off Linux and
      only correct the reason's text.
- [ ] **Parity decisions THD-1 to THD-4 and HCD-1, HCD-2, HCD-4, HCD-5.** Tap-holds
      ([report](docs/audits/platform-parity/2026-11-10-tap-holds/report.md)): THD-1 the pair tap and the layer, THD-2
      the lone window, THD-3 layer-hold pair activity, THD-4 the macOS thumb Backspace under modifiers. Hotstring
      cascade ([report](docs/audits/platform-parity/2026-11-11-hotstring-cascade/report.md)): HCD-1 an expired best
      candidate (macOS falls to a lower rule), HCD-2 a bare `:` or `;` ends a trigger on macOS only, HCD-4 the delay
      on `@` tags, HCD-5 an uppercase one-letter tag (privacy). Each report names the default kept meanwhile.
