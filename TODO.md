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

- [ ] **Comparer follow-ups (2026-11-16).**
  - Let the ranking table choose its metric columns (today the 12 of `TABLE_METRICS` in `comparer_page.js`; every
    metric is in the details) and filter its rows.
  - The Comparer's heatmap: offer the other per-key metrics of `KEY_COST_METRICS` and name each key's worst groups
    for every event (analyse the shown layout with `keyGroups: true`), as the editor's panel does.
  - theme.css follows only `prefers-color-scheme`; the site has no light/dark toggle reaching the framed pages.
  - `layout_analysis.panel.ranking` (« Ranking against the library… ») also shows while ranking among the Comparer's
    ticks: reword it in the 21 locales.
  - Locally (Edge on a French Windows) `exerciseLongLabels` of layout-editor.playwright.cjs fails (« the tooltip
    holds the whole label »), and every `toLocaleString` without a locale prints French digits unless the browser
    runs with `--lang=en-US`; check both against CI before calling either a regression.
- [ ] **Layout formats, what is left.** The library comes only from Oxeylyzer and cmini: add another source (genkey,
      GPL-3.0 like cmini; KLA's built-in list) once its layout list can be read. No third-party KLA JSON, XKB
      symbols, KLC or DOF file under a licence that allows shipping it has been found for the reader tests.
      KLAnext's `matrix` board is refused (`format_unsupported_board`): no matrix file was found to read its key
      indexes from. The ErgoDox index → ISO key table (`KLA_KEYS.ergodox`) maps 27 to Backslash and 60-62 to the
      brackets and quote, while the committed bépo and Optimot ErgoDox files put on 27 what their ISO files put on
      BracketLeft and on 39 what they put on Quote: check it against KLA's ErgoDox key set before changing it.
- [ ] **Studio i18n.** Every Studio, editor and analyser string goes through i18n in English and French; left: a
      label-improvement pass, then the 19 other locales (the analysis strings and `layout_analysis.error.<code>` keep
      pending English).
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

## Parity audit pause and resumption

The [coverage and remaining-work register](docs/platform-parity-audit.md#review-status-at-pause--november-5-2026)
records the focused campaigns already completed, broader reviews, exact limits
and the next module candidates. The audit is paused at the maintainer's request.

- [ ] **What a pause must stop (maintainer, 2026-11-14 evening), on Windows, macOS and Linux.** Keystroke metrics
      (keystats), application usage metrics, the Ctrl+M action that moves the mouse (and every other mouse-moving
      action), and any other background behaviour driven by keys or by the active app; the census lists each feature
      × OS with whether it stops at pause, and every gap gets a fix and a regression test (worker P). Decided the same
      evening: a shortcut slot changed while paused is saved at once and applies on resume, the resume chord staying
      the one active when the pause started (Windows too, across a suspended reload); the magic key capture runs
      while paused on all three OS, the key inert until resume; the Windows tray stops greying the rows the pause
      allows; macOS ends CapsWord at pause like Windows and Linux. Keep-awake / activity simulation stops at pause and is restored
      on resume on all three OS (maintainer, 2026-11-14 night).
      [CODE] Left (2026-11-15): the census rows all stop (a0c00a3449, a4c0290550, 72e1bd30cc, fe94a73c13, 66fbe6d003,
      2f1c555ffc, 734fc9001d, 4a27438e76; test_keepawake_restored_on_resume.ahk, test_pause_closes_app_interval,
      test_paused_driver_records_no_keys); the Windows tray still greys 11 rows (`greyed_when_paused` in menu.toml,
      menu_init.ahk), overlapping EDD-1 below.
- [ ] **[CODE] Parity audit continuation** (claimed by worker H, 2026-11-13)**:** on resumption, reconcile current source areas with the linked coverage register, then deepen tap-holds/chords/layers as one bounded module across Windows/macOS/Linux/shared before moving to another. Keep native receiving and implementation of existing finding IDs separate; do not restart completed focused campaigns without source drift or a new hypothesis.
      Progress (10 November 2026, [tap-hold campaign](docs/audits/platform-parity/2026-11-10-tap-holds/report.md)): census reconciled (375 areas, 12 new and 206 changed since the last pinned census, still to review outside tap-holds). Fixed on Linux/shared: LAlt's Tab tap with no hold is tap-only (THL-001), the Alt-Tab and RCtrl Tab taps keep their strict threshold (THL-002), a pair starts from the earliest held first key (THL-003), a pair's release tap respects the decided tap minimum (THL-004), chord defaults pinned across drivers (THS-001). Decisions pending: THD-1, THD-3, THD-4 (pair tap and the layer, layer-hold pair activity, macOS thumb Backspace under modifiers) and THD-2's lone window. Minimum tap (decided 2026-11-10): Linux complete; macOS needs a Karabiner mechanism qualified on a Mac (`to_if_alone` has no minimum); Windows is the maintainer's change. Left: the report's Linux and macOS remaining rows; native receiving unqualified. Next module after this one: hotstring cascade.
      Progress (12 November 2026, [tap-hold follow-up](docs/audits/platform-parity/2026-11-12-tap-holds-followup/report.md)): register reconciled with the 24 campaigns since the pause (381 areas). Drift since `36d88cc2` reviewed: fixed a single foreign chord action turning every Linux key combination off (TCL-003). Open for the shared tap-hold file series (`wt/taphold-landed`): TCL-001 (manifest rows still in `tap_hold.toml`), TCL-002 (action ids not translated between macOS and Linux), TCL-004 (Mac thumb-key ids, a decision), TCL-005 to 007; the two 2026-11-10 macOS rows are fixed in the generator, proven on the model (Left Command's one-shot Shift holds Shift and stands down under modifiers; a pair takes the first key held earliest), with field points `lalt_one_shot` and `pair_press_order`.
      macOS minimum tap (11 November 2026): done in the generator. Each release-judged tap, a pair's included, is gated on a lease-scoped variable a `to_delayed_action` raises after `tap_hold.tap_min_duration_ms` (Karabiner v16 evaluates a to-event's own conditions when it posts it); the rollover keys keep no minimum, as the Linux roll keys. Generator test `test_generator_tap_minimum.lua`, corpus vectors without their macOS divergence; native timing under « To confirm on the Mac ».
      Progress (11 November 2026, [hotstring cascade campaign](docs/audits/platform-parity/2026-11-11-hotstring-cascade/report.md)): census 377 areas (14 new, 212 changed since the pinned census); module taken: hotstring cascade and trigger arbitration. Fixed: macOS takes each cascade link from the typed matcher's winner (HCM-001 to 004), macOS undoes the magic-key repeat and a stripped-space expansion (HCM-005, 006), Linux restores the typed casing and reports a refused or private undo correctly (HCL-001 to 003), inventory rows for the macOS undo and the Linux repeat window (HCS-001). Decisions pending: HCD-1 (an expired best candidate: macOS falls to a lower rule), HCD-2 (bare `:`/`;` end a trigger on macOS only), HCD-3 (named personal tags) done 2026-11-13 by worker F, decided by the agent, to review by the maintainer: macOS and Linux type one field for `@bic @cb @cc @iban @rib @ss @tel @tél`, as Windows does, from the shared `hotstrings/engine/personal_info/tags.lua` (Windows map pinned by `test-personal-info-tags-single-source.cjs`; regressions `hcd-3-named-tags`); before, the letters' aliases typed more personal data than asked. HCD-4 and 5 (delay on `@` tags, uppercase one-letter tag; privacy) stay pending. The macOS date delay and `+33` short trigger were fixed later on 2026-11-11 (HCM-007, HCM-008; checked by worker F on 2026-11-13). Left: the `+33` short trigger on Windows and the Windows rows of the report; native receiving unqualified.
      Progress (12 November 2026, [hotstrings engine campaign](docs/audits/platform-parity/2026-11-12-hotstrings-engine/report.md)): drift since the cascade campaign and the sending path reviewed. Fixed: the Linux terminal erase is paced after each Backspace, as on Windows and macOS (HSE-001). Decided by the maintainer on 2026-11-12 and done: the short entry forms load everywhere (HSE-002), a no-break space counts as a space inside a trigger (HSE-003), a letter magic key follows the word's case on macOS as on Windows (HSE-004); Windows lines below.
      Continued (11 November 2026, branch `claude/ergopti-todo-parity-audit`): the two reports' Linux, macOS and docs rows. Linux: LAlt's Tab under RCtrl's one-shot Shift types Shift+Tab (THL-005), LAlt tapping Backspace on the layer is swallowed before a user binding (THL-006). macOS: the `+33` short trigger keeps every digit of a number stored without its zero, through one shared helper (HCM-007), the date hotstrings respect the dynamic family's delay (HCM-008). Windows, report only: the `+33` short trigger drops the first digit of such a number (`dynamic_hotstrings.ahk:199`). Left: the macOS one-shot rows of the tap-hold report (Karabiner generator), the Windows rows; native receiving unqualified.
      Progress (11 November 2026, [gestures campaign](docs/audits/platform-parity/2026-11-11-gestures/report.md)): module taken: gestures and touchpad event ownership. Fixed: an incremental diagonal is counted and reversed along its own axis on macOS and Linux (GSS-001), a moving swipe locks or counts only a decided axis outside the diagonal band (GSM-001, GSL-001; a drift with its diagonal unbound falls back to its dominant straight slot on macOS and Linux, a bound diagonal still wins inside the band: decided by the maintainer on 2026-11-11), Linux releases a gesture's click hold at the next key press (GSL-002). Decided by the maintainer on 2026-11-11: GSD-3 (a pair swipe decides from 3.0 mm, diagonal 5.0 mm, on Linux as on macOS, one value in the shared timings registry `[gestures]`; the slot's step stays the user's). Decided by the maintainer on 2026-11-11: GSD-2 (the Linux decoder's swipe minimum and pair-scroll travel are millimetres through the pad's resolution, 10 mm each from the shared timings registry). GSD-1 (macOS live x1 fires, so a touch going right then back left fires two actions where Windows and Linux fire one from the finished swipe): kept as it is, decided by the agent on 2026-11-13, to review by the maintainer; the live feel can only be judged on a real trackpad, and changing it unseen is the riskier choice. Left: a physical mouse click releasing the Linux click hold (no pointer observer), native receiving unqualified.
      Progress (11 November 2026, [metrics campaign](docs/audits/platform-parity/2026-11-11-metrics/report.md)): module taken: metrics beyond the WPM widget. Fixed: the Linux ledger import admits text carrying a CR or a NUL (KML-001, a stuck device before), an imported Windows device's Wi-Fi changes on Linux and macOS (KML-002, KMM-003), no connectivity, topology or capture row under an excluded context on Linux and macOS (KML-003, KMM-002), an imported device's system rows on their own date on Linux (KML-004 part). macOS also arms right_option's no-hold one-shot Shift only on a quick release (tap-hold report). Decided by the maintainer on 2026-11-11: KMD-2 (non-typing rows are refused under an excluded app on every OS; verified on Linux and macOS, closed) and KMD-3 (Linux `awake_ms` is keep-awake time as on Windows and macOS; old Linux days cleared once and marked, decided by the coordinator on 2026-11-11, to review by the maintainer). KMD-1 (rows store `ts` in UTC and `utc_offset_min`, hours, night wakes and days use the recorded offset, an older Linux row the reader's current offset; Linux and macOS writers, migration, purge triggers and rebuilds done). The Windows counterpart of KMD-1 is in since 650a49bdb2 (2026-11-11: cache migration before `KLR_LoadPurgeSchema`, UTC writers and tombstone, `keystats_walker_events.ahk`); checked on the PC 2026-11-16, which added the no-loss, idempotence, partial-image and refused-migration cases to `test_klr_utc_offset_migration.ahk`. Left: native receiving unqualified.
      Progress (11 November 2026, [AI flows campaign](docs/audits/platform-parity/2026-11-11-ai-flows/report.md)): module taken: AI request-to-output flows. Fixed on Linux: a refused Backboard assistant creation (AIL-001) and a refused token exchange (AIS-001) are refused credentials, never retried; a failed streamed attempt's partial is withdrawn before its retry, which no longer streams (AIL-002). Decided by the maintainer on 2026-11-11: AID-1 (the macOS quick retry spends an attempt of `max_attempts`, two requests at most for one prediction at multiplier 2, as on Windows and Linux) and AID-2 (a token exchange answering 400 is a refused key, never retried, failing with the service's message; shared classifier and exchange reader, Windows mirror of both corpora left to the maintainer) and AID-3 (a model, key, provider or endpoint change retires the request in flight on macOS and Linux, as on Windows; shared `llm.request_settings`). The macOS counterparts of AIS-001 and AIL-002, checked 2026-11-13 (worker F): already covered, the report's remaining work records that AIS-001 does not reproduce (`post_and_parse` fails a refused exchange as `no_credential`) and AIM-001 withdraws a failed stream, and `api_ollama` streams only the first attempt. Left: native receiving unqualified.
      Progress (11 November 2026, [input/layout campaign](docs/audits/platform-parity/2026-11-11-input-layout/report.md)): module taken: remaining input/layout engine joins. Fixed: a moved macOS Cmd chord is released on its own key code (ILM-001), an emulated shortcut falls back to its character's US key under a non-Latin layout on Linux and macOS (ILL-003, ILM-002), an emulated Linux chord repeats while held (ILL-004). Fixed (order decided by the coordinator on 2026-11-11, to review by the maintainer): a bound shortcut slot and the prediction's digit run before the Linux layout emulation (ILL-001, ILL-002); open: the slot still matches the system layout's key, not the emulated letter. ILD-1 decided by the maintainer on 2026-11-11 (a two-modifier chord sends the logical key everywhere): macOS and Linux pinned, Windows counterpart in the report. ILD-2 decided by the maintainer on 2026-11-11 (Ctrl+AltGr sends Ctrl and the logical key, AltGr suspended, on every OS: Linux already, macOS done, shared vector, Windows counterpart below). Left: a tap-hold modifier's repeat over a passed key on Linux, native receiving unqualified.
      Progress (11 November 2026, [shortcuts campaign](docs/audits/platform-parity/2026-11-11-shortcuts/report.md)): census 377 areas (47 changed areas under modules campaigned since); module taken: keyboard shortcuts and text actions. Fixed on Linux: a held accented shortcut repeats like Windows (SCL-001), the accented shortcuts stand aside while a layout is emulated (SCL-002). SCD-1 decided by the maintainer on 2026-11-11 (no Linux keyboard slot runs through a pause; the shared paused actions list replaces the prefix test). SCD-2 and 3 settled with ILD-1 and ILD-2 (Ctrl+Alt+é sends Ctrl+Alt and the logical key; a Ctrl slot fires under AltGr, AltGr suspended; Linux already does both, Windows counterparts below). Next module: the updater. Left: macOS `bindings.lua` and Linux `key_combinations.lua` in depth, native receiving unqualified.
      Progress (11 November 2026, [updater campaign](docs/audits/platform-parity/2026-11-11-updater/report.md)): module taken: the updater, from the census. Fixed on Linux: a failed background check announces no release (UPL-001), the notification of a manual check without its window words each outcome (UPL-002), a release read from the public feed says it cannot be installed yet (UPL-003). UPD-1 decided by the maintainer on 2026-11-11 (a 200 that does not open a JSON array, and a Linux 304 with no usable cached page, are « no connection » with the feed fallback, through the shared `opens_release_array`; Linux and macOS done, Windows counterpart below). Windows, report only: UPW-005 (the signing policy compared case-insensitively). Left: the macOS manual check without its window, native receiving unqualified.
      Progress (12 November 2026, [network campaign](docs/audits/platform-parity/2026-11-12-network/report.md)): areas taken: proxies, trust, deadlines, downloads, request privacy. Fixed on Linux: a Negotiate company proxy is answered with the session's ticket (NET-002), the AppImage trusts openSUSE's CA bundle (NET-006), the unread download timeout copy is gone (NET-004); on Linux and macOS a local Ollama request gets the shared 180 s cold-load budget (NET-003). After review: the macOS remap downloads run behind the system network route (NET-001). Decided by the maintainer on 2026-11-12: the macOS no-token stream watchdog is removed, and the release archive has one shared budget (1,200 s absolute, 600 s idle) read on macOS and Linux, the Windows side listed below. ExcludeSimpleHostnames on macOS (NET-005): checked 2026-11-13 (worker F), no opaque child targets a dot-free host (every origin comes from `route_origins.json`, all public dotted hosts), so no request goes through the relay against the system rule; `test-managed-proxy-route-contract.cjs` now fails on a single-label origin, which would first need a route-plan step.
      Progress (12 November 2026, [layout manager campaign](docs/audits/platform-parity/2026-11-12-layout-manager/report.md)): module taken: the layout manager window's host on macOS and Linux. Fixed: the emulation reloads when the emulated layout is uninstalled, removed, updated or re-saved, the stored choice kept as decided by the maintainer on 2026-11-12 (LMH-001, 002; Windows line below); a paused driver admits only the page's ready signal (LMH-003); a layout shipping hotstrings reloads the driver (LMH-004); the Linux tray follows « Emulate without installing » (LMH-005); the last source reopens through a bounded UTF-8 read (LMH-006) and the store reads its export name and codes from the shared defaults (LMH-007). Native receiving unqualified.
      Progress (12 November 2026, [bundled apps campaign](docs/audits/platform-parity/2026-11-12-bundled-apps/report.md)): module taken: App Cloner and Encryptor on macOS and Linux. Fixed: a folder destination is refused instead of reported as decrypted (BAP-001), macOS browser clones get their own profile (BAP-002), cancelling one overwrite skips only that file on macOS (BAP-003), the Linux item to open is validated as on macOS (BAP-005), a second clone of a name gets its own Linux menu name (BAP-006), a refused write names its reason (BAP-007). Open: BAP-004 (VSCodium and Insiders settings, a catalogue change Windows reads too), BAP-008 (the Linux Encryptor's « Open with » registration); `main.scpt` to recompile on the Mac.
      Progress (12 November 2026, [layer editor campaign](docs/audits/platform-parity/2026-11-12-layer-editor/report.md)): module taken: the navigation layer editor host on macOS and Linux. Fixed: keys show the emulated layout's characters while one is emulated (LEH-001), the Linux page gets its answer when the folder moves during a save (LEH-002). LEH-003 (a macOS regeneration failing after the window closed is only logged): decided and fixed on 2026-11-12, an error notification names the window (`leh-003-late-regeneration-failure`; noted by worker F on 2026-11-13).
      Progress (12 November 2026, [webview hosts campaign](docs/audits/platform-parity/2026-11-12-webview-hosts/report.md)): module taken: the page window hosts. Fixed: the Linux hotstrings settings window no longer opens empty (WVH-001), the macOS editor windows are resizable (WVH-002), the native context menu stays closed outside text fields on macOS and Linux (WVH-003). Left: a macOS minimum window size, which hs.webview cannot set.
      Progress (12 November 2026, [AI flows follow-up](docs/audits/platform-parity/2026-11-12-ai-flows-followup/report.md)): drift since the AI-flows campaign and the selection actions reviewed. Fixed: the tone and translation actions refuse in an app excluded from the AI on Linux and macOS, as on Windows (AIX-001); the Linux key migration ends quietly when a save moved the keys (AIX-002) and a shutdown discards the keys an attempt stored (AIX-003). The campaign's leftover Linux retry row is parity with Windows. Native receiving unqualified.
      Progress (12 November 2026, [configuration follow-up](docs/audits/platform-parity/2026-11-12-config-followup/report.md)): the campaign's enum row and the cleanup of the same leaves. Fixed: an enum written in another case reads in its manifest spelling, as on Windows, in the Linux AI, hotstring, number-row and gesture readers and the shared emulation settings (CFX-001) and in the macOS preference loader (CFX-002); the Linux cleanup no longer offers saved swipe modes and steps for deletion (CFX-003). The macOS preference hydration beyond `load` and `current_view`, checked 2026-11-13 (worker F): `merge_saved_data` and `build_initial_state` consume only what `load` flattened, so they inherit its enum case adoption; no gap. NFD and NFC paths need a Mac: moved to TODO-tests-macos.md (`config_nfd_paths`). Left: native receiving unqualified.
      Progress (12 November 2026, [updater follow-up](docs/audits/platform-parity/2026-11-12-updater-followup/report.md)): the campaign's two uncompared rows. Fixed: a macOS manual check whose window cannot open runs and notifies its answer, through the shared `updater.check_notice` (UPX-001); the Linux bundle, checksum and signature are bound to the repository's download path for the release's tag, as on Windows and macOS (UPX-002). UPD-2 decided by the coordinator on 2026-11-12 from the maintainer's pause rule (a manual check runs during a pause, as on macOS and Linux; Windows line below). Native receiving unqualified.
      Progress (12 November 2026, [input/layout follow-up](docs/audits/platform-parity/2026-11-12-input-layout-followup/report.md)): the campaign's two open Linux rows. Fixed: a keyboard slot follows the emulated letter, as on Windows (ILX-001, through the shared `keylayout_emulation.chord_char`); a key passed under a tap-hold's held modifier repeats (ILX-002). Left: the macOS Carbon slots against the tap rewrite, to confirm on a Mac; native receiving unqualified.
      Progress (12 November 2026, [gestures follow-up](docs/audits/platform-parity/2026-11-12-gestures-followup/report.md)): the campaign's open Linux row. Fixed: a physical mouse click releases a gesture's click hold, as on Windows and macOS, a touchpad touch keeping it for the drag (GSX-001). Left: GSD-1, the modules not reviewed in depth; native receiving unqualified.
      Progress (12 November 2026, [notifications campaign](docs/audits/platform-parity/2026-11-12-notifications/report.md)): areas taken: notifications, their logs, levels and lifetime, tooltips and tray state. Fixed: a refused shortcut or gesture Quit is told on macOS and Linux (NUI-001); a refused macOS menu Reload is told (NUI-002); macOS logs a notice by its shape, never its text (NUI-004); one notification lifetime in the timings registry (NUI-006); Linux system action failures are error notices (NUI-007). After review: a notify-send that runs and fails is logged and kept in the log (NUI-003), a refused macOS source-change reload is told once per burst (NUI-005). The macOS pause and resume notices: kept, decided by the agent on 2026-11-13, to review by the maintainer (Linux announces them too through the same shared keys and levels, so only Windows, which ticks its row, goes without; removing a notice the user already sees on two OS is the riskier change). Left: make the Linux runner's notify-send sentinel count fatal (`tests/run.lua`) once the ~370 notices that still reach it through the real notifier have a `ShellRunner._set_async_runner` seam.
      Progress (12 November 2026, [lifecycle campaign](docs/audits/platform-parity/2026-11-12-lifecycle/report.md)): areas taken: reload, user Quit, signals and logout, wake, first run. Fixed on Linux: input that stops at run time exits non-zero so systemd restarts the daemon (LCY-001); a first run follows the session language, English fallback (LCY-002); a shortcut or gesture Quit takes the user Quit owner (LCY-003); a signal during an update's probation keeps the update (LCY-004); the degraded tray Quit takes the same owner. Left: native receiving unqualified.
      Progress (11 November 2026, [adapters campaign](docs/audits/platform-parity/2026-11-11-adapters/report.md)): areas taken: the Lua drivers' `adapters/` and `infra/` (clipboard, privacy, focus identity). Fixed on Linux: an X11 clipboard holding only an image is borrowed and restored whole (CBL-001). ADD-1 to 3 decided by the maintainer on 2026-11-11 (a password manager of the one shared list `_shared/data/secure_apps.json` is a secure field as a whole on macOS and Linux, Windows counterpart below; a borrowed unowned Linux clipboard goes back unowned, as on macOS; the Linux application identity is the WM class or app_id under X11 and Wayland, comm only as fallback, saved exclusion lists converted once). Left: configuration, lifecycle, notification and network adapters in depth, native receiving unqualified.
      Progress (11 November 2026, [configuration campaign](docs/audits/platform-parity/2026-11-11-config/report.md)): configuration, scopes and migration of the Lua drivers. Fixed: a `[script]` enum written in another case is adopted in its manifest spelling on macOS and Linux (CFS-001), a Linux setting edit removes its rollback copies once it commits (CFL-002), `storage.json` is private on the LuaJIT runtime (CFL-003). CFD-1 decided by the maintainer on 2026-11-11 (Linux stages are named per process, pid and start tick, and a dead process's stages are reaped at start; a foreign stage is still refused). The case variants of the other enum readers were done by the configuration follow-up (CFX-001, CFX-002, 12 November). Left: native receiving unqualified.
      Progress (11 November 2026, [macOS launcher campaign](docs/audits/platform-parity/2026-11-11-macos-launcher/report.md)): source reading only (no Swift toolchain here), nothing fixed. Findings for a Mac: MLC-001 (MJConfigFile seeded before the single-launcher lock, so a second launcher repoints the running runtime; the `.cjs` guard misses the top-level write), MLC-002 (a quit from outside skips the controlled exit and can report a runtime failure), MLC-003 (a second launch after boot shows nothing; product decision), MLC-004 (the leftover-runtime grace is a literal below the quit deadline), MLC-005 (exact-path check under App Translocation, to probe). Checked 2026-11-13 (worker F) against current source: MLC-001 is fixed (MJConfigFile is seeded only once the launcher holds the sole-launcher lock, before each runtime launch, `main.swift`), MLC-004 is fixed (the grace is `LauncherTimings.userQuitDeadline`, the poll `stale_runtime_poll_ms`, both from the registry). MLC-002 is implemented too (the launcher defers `applicationShouldTerminate`, posts the launcher quit request and the child runs its controlled exit through `launcher_guard.watch_quit_request`). Open: MLC-003 (product decision). MLC-005 fixed 2026-11-13 (worker F): `platform/remap/lease_helper.lua` compared the launcher's exported helper path with the bundle-derived one as text, so a translocated app (`/var` against `/private/var`), a symlinked Applications folder or an accented folder spelled NFC on one side and NFD on the other was refused although both name the running launcher; it now proves the same regular file by the exported device and inode (no symlink at the helper, the real path still an app's `Contents/MacOS/ErgoptiPlus`); regressions `mlc-005-relocated-launcher`. Linux compares the realpaths of both spellings on byte-exact filesystems, so it has no such gap; Windows has no counterpart identity proof. The gate's relocated rows (symlinked, « Applications de Léa », translocated) judge it on the next hosted Install-and-launch run.
      Progress (12 November 2026, [start-at-login campaign](docs/audits/platform-parity/2026-11-12-start-at-login/report.md), branch `claude/ergopti-todo-parity-b`): census 381 areas (18 new, 220 changed since the pinned census); never-campaigned changed areas listed in the report (menus, i18n, editors, healthcheck, onboarding, Linux install). Fixed: macOS tells the Login Items approval step instead of the failure dialog (SAM-001) and logs a failed startup read (SAM-002); Linux logs a failed startup read and each refused change (SAL-001). The macOS memory note on ordinary Hammerspoon over a checkout corrected. SAD-1 decided by the maintainer on 2026-11-12 (B: start at login on a source run): Linux writes the checkout launcher's autostart entry and reports a stale one (warning, rewritten on enable); the macOS developer app resolves its own launcher (native `SMAppService` answer for an ad hoc bundle to confirm on a Mac). Stale-entry row reason decided by the coordinator on 2026-11-12 (none: the warning, and the next enable repairs the entry). Left: the developer-app login item under « To confirm on the Mac », native receiving unqualified.
      Progress (12 November 2026, [i18n run-time campaign](docs/audits/platform-parity/2026-11-12-i18n-runtime/report.md), branch `claude/ergopti-todo-parity-b`): areas taken: locale choice, lookup chain and miss reporting at run time. Fixed: macOS and Linux warn once for each raw key shown, probes go through `has()` (I18-001); macOS warns about a saved locale without a catalogue (I18-002) and takes its fallback from `locales.system_fallback` (I18-003). Left: native receiving unqualified.
      Progress (12 November 2026, [menus/tray campaign](docs/audits/platform-parity/2026-11-12-menus-tray/report.md), branch `claude/ergopti-todo-parity-b`): composition from the shared manifest, pause greying, rebuild after a menu change and after a change behind Ergopti's back: no finding. The Linux About build's two synchronous startup reads measured (about 10 ms each), not proposed. Traced 2026-11-13 (worker H): the Linux agent mode switched by its binding now redraws the tray (agent-mode-tray-redraw); the updaters already rebuild and the Lua programmable source loads synchronously. Left: native rendering unqualified.
      Progress (12 November 2026, [onboarding campaign](docs/audits/platform-parity/2026-11-12-onboarding/report.md), branch `claude/ergopti-todo-parity-b`): the wizard's bridges, catalogue and answers. Fixed on macOS: the chosen language waits for Finish, as on Windows and Linux (OBM-001), and a missing or unshipped locale is refused instead of becoming English (OBM-002). Done 2026-11-13 (worker H): the Linux wizard's dialogs speak the chosen language (`(onboarding-host-dialog-locale)`). Left: native WebView receiving unqualified.
      Progress (12 November 2026, [diagnostics page campaign](docs/audits/platform-parity/2026-11-12-healthcheck/report.md), branch `claude/ergopti-todo-parity-b`): actions, pause, stale results: no finding (one shared validator and report owner, the collection a Windows capability). Left: native receiving unqualified.
      Progress (12 November 2026, [Linux install campaign](docs/audits/platform-parity/2026-11-12-linux-install/report.md), branch `claude/ergopti-todo-parity-b`): startup ownership, uninstall, configuration cleanup (download steps left to the other track). Fixed: a checkout's startup entry no longer takes the standalone installation's name, which blocked a later install (LIN-001). Left: a deleted checkout's entry stays until a checkout run rewrites it.
      Progress (12 November 2026, [editors campaign, first pass](docs/audits/platform-parity/2026-11-12-editors/report.md), branch `claude/ergopti-todo-parity-b`): page and bridge behaviour of the personal information, prompt, paths and hotstrings editors. Fixed on macOS: a refused personal information save is told (EDM-001). EDD-1 decided by the maintainer on 2026-11-12 (a pause stops typing, not configuration): macOS and Linux editors save while paused, the LMH-003 gate reverted, Windows counterpart below. Done 2026-11-13 (worker H): the macOS prompt editor tells a refused save (`(prompt-editor-save-failure)`). Left: the layer editor page, tooltips, WPM.
      Progress (12 November 2026, [pause, first and second pass](docs/audits/platform-parity/2026-11-12-pause/report.md), branch `claude/ergopti-todo-parity-b`): EDD-1 sharpened into a « real pause » (configuration and installs stay available, typing stays inert, a setting changed while paused applies on resume). Done on macOS and Linux: the physical shortcuts editor opens while paused; every menu's whole-scope restore and clear and the Configuration menu run while paused; the tray's feature rows stay live (`greyed_when_paused` is read by the AHK tray alone); Linux hotstring sections, keyboard groups, wrap choices and the pause layout switch work while paused (`edd1-paused-writes`). Left, see the report's last section: the macOS Shortcuts and both Gestures switches, Linux tap-hold edits, the programmable hotstrings switch, both AI menus, the personal editor and word expander rows (shared corpus), the macOS hotstrings submenus, the macOS magic key capture, and the audit that every typing feature (layout emulation first) is inert while paused.
      Progress (13 November 2026, [pause, third pass](docs/audits/platform-parity/2026-11-12-pause/report.md#third-pass-2026-11-13-worker-h), worker H): the macOS Gestures switch and slot rows, the Linux gestures restore and clear, Linux tap-hold tap and delay edits and the programmable hotstrings controls (shared policy) commit while paused and apply on resume. Loading the programmable source at once while paused confirmed by the maintainer on 2026-11-14. Then the macOS Shortcuts switch (recorded under ScriptControl's claim, started on resume) and the macOS hotstrings submenus (sections, language and extension « all sections », order, preview, delays, settings window). Each macOS shortcut's row, the wrap rows, the ChatGPT URL editor and the tap-key rows too; layout emulation checked inert while paused on macOS and Linux. Left: the macOS script-chord and keyboard slot rows, both AI menus, the personal editor, legacy shortcut and word expander rows, the macOS magic key capture, the typing-inertness audit.
      Progress (14 November 2026, [pause, fourth pass](docs/audits/platform-parity/2026-11-12-pause/report.md#fourth-pass-2026-11-14-worker-h-shared-rows-on-all-three-drivers), worker H): on Windows, macOS and Linux together, the personal hotstrings editor opens while paused, and the word expander, custom terminator and extension scope rows commit while paused, as do the AI privacy, trigger, display and generation rows. The shared policies, their AutoHotkey twins and corpora admit a paused snapshot and still refuse a malformed pause. Left: the AI enable switch, model, profile and API rows, the macOS legacy shortcut and slot rows, the magic key capture, the typing-inertness audit.
      Progress (14 November 2026, [pause, fifth pass](docs/audits/platform-parity/2026-11-12-pause/report.md#fifth-pass-2026-11-14-worker-p-shortcut-slots-changed-while-paused), worker P): a shortcut slot changed while paused is saved at once and takes effect on resume, the resume chord staying the one of pause time (decided by the maintainer on 2026-11-14). macOS: the script chord slots, switch and restore, the keyboard slots and the editor legacy shortcut; Linux: the script chords; Windows: a global restore while paused keeps the chords of pause time across its reload (the Shortcuts submenu is greyed while paused). Then (sixth pass, decided by the coordinator on 2026-11-14) « capture the next key » for the physical magic key runs while paused on the three OS, saved at once and inert until resume; the Windows Layout submenu stays live while paused, only the layout manager and editor greyed with why. Typing-inertness audit done (report): every typing feature is gated on the three OS; fixed on Linux, metrics recorded keys and chords while paused; fixed on macOS, a pause ends a running CapsWord and its CapsLock, as on Windows and Linux (field point `pause_ends_capsword`). Background behaviours census (report): Linux metrics (application time, pointer, network, topology, system rows) and its spotlight now stop at pause; macOS forgets the distance seed. Keep-awake is restored on resume on the three OS (decided by the maintainer on 2026-11-14). Fixed (eighth pass): the macOS pause closes the foreground interval, so the time before it is credited. Fixed (seventh pass): the number-row choice is admitted while paused on the three OS (the shared policy and its Windows twin), saved at once and applied on resume; a pause edge between the capture and the write retires the capture.
      Progress (13 November 2026, [tooltips and WPM campaign](docs/audits/platform-parity/2026-11-13-tooltips-wpm/report.md), worker H): the editors campaign's tooltip and WPM rows. Fixed on Linux: the preview hides before its trigger window closes (TWL-001), the WPM widget and tray readout hide while paused (TWL-002), an AI suggestion left alone runs out after the shared lifetime (TWL-003). Open: the Linux `llm_prediction` delay row, decisions TWD-1 (a zero-delay preview's 3 s safety hide, Windows only) and TWD-2 (« 0 » shown on a non-typing key on macOS and Linux).
      [CODE] Left (2026-11-15): census areas outside the campaigned modules, the macOS bindings.lua and Linux
      key_combinations.lua deep pass, and the Windows rows of each report. [DECISION] THD-1 to THD-4, HCD-1/2/4/5,
      TCL-004, and the agent's GSD-1 and HCD-3.
      Windows rows rechecked 2026-11-16 against the source: ADD-1 (`SFD_IsSecureAppWindow`), UPD-1 (an HTML 200
      reads the feed), UPD-2, ILD-2, SCD-2 and SCD-3 were already done. Fixed that day: the `+33` short trigger of a
      number stored without its 0 (HCM-007's Windows row, `_DynHS_InternationalPrefix`, shared
      `international_prefix_vectors`) and UPW-005 (the signing policy read case-sensitively). Also fixed that day,
      from the tooltips and WPM report: Linux has the Delays submenu's AI row and its overlay reads the
      `llm_prediction` override (`tooltips-wpm-llm-delay-row`), and a lifetime of 0 keeps the prediction until the
      next activity on Windows too, which hid it after the 50 ms floor (`llm-zero-lifetime`). Still open on
      Windows: the Notepad and terminal Backspace undo (item below); KMD-1 was already in (650a49bdb2, rechecked on
      the PC 2026-11-16, see the metrics campaign line).
      TWD-1 and TWD-2, decided by the maintainer and done on 2026-11-16. TWD-1: a hotstring preview with no delay
      hides after the shared `[timing] safety_timeout_sec` on the three OS (Windows read a typed 3.0, macOS and
      Linux kept the bubble until the next key), a no-delay row of a macOS timed stack too; the single-source gate
      `test-tooltip-style-single-source.cjs` requires the three readers (tests `twd1-zero-delay-safety`,
      `twd1-stacked-safety`). TWD-2: the typing-speed widget shows only while text is typed and hides as soon as
      the burst ends: a shortcut (Ctrl, Alt but not AltGr, Win or Cmd, Fn), a function, navigation or media key, a
      shortcut modifier tapped alone, a focus change, the idle delay, or any pointer input, a single pixel of
      movement, a click, a wheel or touchpad scroll (never a move the driver posts itself). Shift, AltGr and
      Shift+AltGr (macOS: both Option keys) are level modifiers and never end it, held or tapped; AltGr's LCtrl
      on Windows is no lone Ctrl. One rule: `[typing_burst]` of `_shared/metrics/data/wpm_widget/constants.toml`
      names the keys by `KeyboardEvent.code`, mapped through `physical_keys.json`
      (`metrics/engine/wpm/typing_keys.lua` and `activity.lua` on macOS and Linux, `WPMWidget_TypingBurstIndex`,
      `WPMWidget_Burst*` and `WPMWidget_PointerEndsBurst` on Windows). Tests `twd2-typing-burst`,
      `twd2-level-modifiers`, `twd2-pointer-hides`. Left: a real-keyboard look on each OS (not yet in the
      TODO-tests files), and a Linux fifth-level key placed on a Ctrl key, which the input hook reports as Ctrl.

## Dead-key composition parity follow-up

[Focused audit](docs/audits/platform-parity/2026-11-05-dead-keys/report.md), pinned source `f2c3ea43542c985fb20e5f0887976f1c02525341`: five new roots, [generated comparison](docs/audits/platform-parity/2026-11-05-dead-keys/capabilities.md). Evidence boundaries remain explicit; these are follow-ups, not implemented fixes.

- [x] **Pause and a pending dead key (macOS, Linux).** A pending composition is native state there and Ergopti's pause
      does not cancel it (both Windows engines do); decide whether the pause must clear it, and how.
      Done 2026-11-13 (worker F): the layout emulation, which owns its pending dead key in Lua on both drivers, drops
      it when the script pauses (`layout_emulation.drop_pending_dead_key`, called by macOS `pause_processing` and the
      Linux pause listener), so it never composes with the first key after the resume; held custom modifiers keep
      their own release path. Tests `(pause-drops-dead-key)` on both drivers. A dead key pending in the system's own
      layout (no emulation) stays the OS's state, as with Ergopti not running: decided by the agent on 2026-11-13,
      to review by the maintainer.

## Cross-platform feature inventory

- [ ] **Windows/Linux diagnostics:** (claimed by worker F, 2026-11-13: the section is published on both; the feed-only fallback stays blocked on the empty `public_key_spki_base64` and `off` enforcement, a maintainer key-provisioning step, so no code step can run before it) add the manifest-derived unavailable-features explanation already collected and rendered on macOS. Evaluate authenticated fallback metadata for feed-only update installation; retain current refusal without authenticated assets (macOS uses signed Sparkle metadata for newest-channel updates). Progress: Linux and Windows now publish the section through one shared Lua collector and its AHK mirror (AHK test written, not run on Linux); the feed-only fallback evaluation remains. Decided 2026-11-06 (align on macOS): a feed-only list may install the channel's newest release only through authenticated metadata, otherwise the refusal stays. Windows/Linux design: download the asset under its conventional name, compute size and SHA-256 locally, rebuild the `asset_signing.json` record and verify `<asset>.sig` against the pinned key before installing. Blocked: `public_key_spki_base64` is empty and enforcement is `off`, so every such install would refuse today; build it once the key is provisioned (docs/tooling/update-signing.md).
      PC run 2026-11-11: the AHK mirror of the unavailable-features section (`test_healthcheck_core.ahk`, ui group) passed natively.
      [RELEASE] Left (2026-11-15): the feed-only fallback waits on the release signing key (`public_key_spki_base64`
      empty, enforcement `off` in asset_signing.json).
- Moved to TODO-tests-windows.md (2026-11-15): qualify physical shortcut delivery on Windows.
- Moved to TODO-tests-linux.md and TODO-tests-windows.md (2026-11-15): incremental touchpad gesture modes and step
  sizes (the Windows check is « Windows incremental swipes (raw touchpad reader) »).
- Moved to TODO-tests-linux.md (2026-11-15): focused-application identity on GNOME, KDE and COSMIC (field point
  `wayland_focus`).

## Sequential WPM, wrap and personal-info parity follow-up

[November 5 sequential audit](docs/audits/platform-parity/2026-11-05-sequential/report.md) at `7aecd9a25b35efdcff68898919506dc2f6fd02d0`: four reviewers stayed on one module at a time, with independent root replays before advancing. [Generated capability and intentional-difference comparison](docs/audits/platform-parity/2026-11-05-sequential/capabilities.md). These are bounded source/actual-owner findings; Windows native execution and desktop receiving remain qualified. Findings below remain open; this campaign changes evidence and tracking, not production behavior.

### Policy, documentation and verification debt

- [ ] **[CI] Native keyboard-source fixture:** Claimed by worker B (2026-11-14). Investigate selection-deadline/cleanup-unavailable refusals seen before and during this audit; the targeted retry passes, but that does not establish a repaired cause. Keep failed receipts and exact required cohorts.
      2026-11-11: the refusal of run 42014901978 (Intel macOS 15) follows one line no passing log shows,
      `CFMessagePortSendRequest FAILED(-1) to send to port com.apple.tsm.uiserver`: the service that applies the
      selection did not answer for about 11 s. 6736a355 brackets the cohort with a read-only snapshot of the text-input
      agents (launchd state, runs, last exit, crash reports, unified log) kept with its receipt, so the next refusal
      names the cause. The cohort passed 41/41 (Intel) and 40/40 (Apple silicon) over 2026-11-07..10 and again in
      [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137); the cause stays unproven until a
      refusal carries that snapshot.
      2026-11-12: scan of ci.yml runs 2026-11-07..12 (282 of 353 runs on dev, claude/_ and tmp/_): the cohort steps ran
      61 times on Intel and 62 on Apple silicon; 2 Intel refusals, [43013053161](https://github.com/adrienm7/ergopti/actions/runs/43013053161)
      (job 130500102196) and [43172671159](https://github.com/adrienm7/ergopti/actions/runs/43172671159) (tmp/ci-snapshot, job 131034291324),
      both after `CFMessagePortSendRequest FAILED(-1)` lines, as in 42014901978; none on Apple silicon. One macOS 26
      `KeyboardSourceProbeTests` refusal in the full launcher suite ([43108782369](https://github.com/adrienm7/ergopti/actions/runs/43108782369),
      job 130833096151) has no such line. Probes on hosted runners (temporary `probe-macos-tsm.yml`, removed in 3363b94e):
      `TextInputMenuAgent` owns `com.apple.tsm.uiserver`; stopping it prints the line (20 on macos-15, 31 on Intel), so
      does stopping `TextInputSwitcher` on Intel (12), not stopping SystemUIServer. But every perturbed cohort still passed
      12/12: agent stopped ([43189848716](https://github.com/adrienm7/ergopti/actions/runs/43189848716), job 131086084762), both stopped, either
      stopped or killed while the cohort selected ([43194666371](https://github.com/adrienm7/ergopti/actions/runs/43194666371), job 131102413569),
      and that fresh runner's unperturbed baseline printed four such lines and passed. So the unanswered server is a
      state the refusals share, not their cause; the cause is still unproven and no retry was added. 71a16621 (wording
      corrected in 4d2e7e55, 533e2762) writes `tsm-refusal.json` beside the number-row receipt and annotates the state
      (`tsm_uiserver_unanswered`, `fixture_refusal_unclassified` or `no_fixture_refusal`) with the agent snapshot; the
      verdict and the exact cohorts are unchanged (`tools/test/test-macos-tsm-refusal.cjs`). Next refusal: read its
      receipt and snapshot (did the agent's pid or run count change?) before trying another perturbation.
      2026-11-12 afternoon: the refusal now recurs on macOS 26 in the full launcher suite ("Run Swift launcher tests on
      macOS 26"), with no `tsm.uiserver` line in any of them: [43222724578](https://github.com/adrienm7/ergopti/actions/runs/43222724578) (job 131204789756) on
      `KeyboardCharacterMappingTests.testFreshKeyboardEventsFollowLayoutAndShiftFlags` at 13:26:12 UTC, then
      `KeyboardSourceProbeTests` (3), `NativeInputSourceSelectionTests` (4) and `NumberRowSourceProbeTests` (7)
      "unavailable"; [43228623723](https://github.com/adrienm7/ergopti/actions/runs/43228623723) (job 131226750544) on the number-row cohort's first selecting case
      (`testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI`, French) at 14:12:29, five seconds after
      `NativeInputSourceSelectionTests` passed, then six more "unavailable". With 43108782369 that is three macOS 26
      refusals without the line. The full-suite step carries no text-input snapshot or `tsm-refusal.json`, so the
      next step is to bracket it as the number-row step is.
      2026-11-14, worker B: both steps are bracketed (the full-suite step since 2026-11-12 evening). Scan of the 377
      completed ci.yml runs of 2026-11-11 to 2026-11-14 00:30 UTC: the number-row step ran in 163 macOS 15 jobs (4
      failed), the macOS 26 full suite in 83 (17 failed). Two refusals carry a receipt, both
      `fixture_refusal_unclassified` and without a `tsm.uiserver` line: [43276494558](https://github.com/adrienm7/ergopti/actions/runs/43276494558) (job 131404916213,
      Apple silicon, number-row step, 19:23 UTC on 11-12, first case
      `testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI`, 9 of 12 cases refused) and
      [43277967473](https://github.com/adrienm7/ergopti/actions/runs/43277967473) (job 131406033005, macOS 26 full suite, 19:11 UTC, first case
      `testFreshKeyboardEventsFollowLayoutAndShiftFlags`; the French selection succeeded at +219 ms, the restore
      answered `sourceUnavailable` at +6356 ms and +11390 ms). No refusal since 2026-11-13 11:21 UTC; the four
      later full-suite failures are `CatalogUpdateUserDriverTests` (NSCocoaErrorDomain Code=2) with
      `no_fixture_refusal`. The agent snapshot is written to the receipt file, not the log, so the pid and run-count
      question needs the artifacts `swift-launcher-failure-43277967473-1` and the `number-row-carbon-arm64-…` artifact of
      43276494558 before they expire; this session's network could not reach the artifact store.
      Cause still unproven, no code changed.
      [CODE] Left (2026-11-15): read the artifacts `swift-launcher-failure-43277967473-1` and the number-row artifact of
      43276494558 before they expire (agent pid and run count), then find the cause.
      2026-11-15, worker X: both artifacts read (`swift-launcher-failure-43277967473-1`, kept until 2027-02-10;
      `number-row-carbon-arm64-43276494558-1`, expiring 2026-11-19). The TextInputMenuAgent pid and run count are the
      same before and after both cohorts (423/1 and 419/1): the agent did not restart. Their TIS records show one
      mechanism, on Apple silicon macOS 26.7.2 and 15.8.2 alike: the French selection is seen at +219 ms and
      +221 ms, then the first restore to US returns 0 and, 6 s later, US reads enabled and selected while
      `TISCopyCurrentKeyboardInputSource` in the test process still returns French, now unselected. The system
      applied the restore; this process's current-source cache never followed, and every later case captured the
      stale French as its original (hence the cascade of "unavailable"). The receipt now names it
      `process_current_source_stale`, from the refused case's own records, with the wanted and current sources in
      the annotation (test-macos-tsm-refusal.cjs). Still unproven: why the process misses that one change (the
      notification that refreshes its cache, or the run-loop mode the fixture pumps), and whether the launcher's own
      long-lived process can be left on a stale source the same way.

## Native runtime, editor and diagnostics parity follow-up

[November 5 audit](docs/audits/platform-parity/2026-11-05-native-ui/report.md): nine bounded OS × module scopes at `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`; 15 qualified findings, including one shared frontend root affecting all three OSes. These are source/model/private native-port findings, not 15 native desktop reproductions. [Capability and intentional-difference comparison](docs/audits/platform-parity/2026-11-05-native-ui/capabilities.md). The canonical manifests exclude counterchecked LVB-002 and MRT-005.

### Qualification and policy follow-up

- [ ] **[NATIVE]** Exercise the retained runtime/editor/diagnostics receiving boundaries on Windows and macOS, and the Linux live GTK/session flows. Worker B 2026-11-14: the Windows and macOS boundaries need a real PC and a real Mac, so they stay for the maintainer; the Linux runtime, editor and diagnostics flows can run in the hosted desktop-webview CI shard and are still to be written there. Replay refused writes, native timer admission, stale epochs and physical cleanup; the private models do not certify these boundaries. Linux, partly (2026-11-11): a live installed session with an in-process WebView (the first-run onboarding window) now receives the reload request instead of crashing (44b2e10f, `tests/hardware/run_webkit_gc_signal.lua` in the desktop-webview CI shard); the runtime/editor/diagnostics flows themselves remain. Mac part routed by worker F (2026-11-13): the field point `native_ui_receiving` in TODO-tests-macos.md.
      [CODE] Left (2026-11-15): the Linux live runtime and editor flows in the desktop-webview shard are still to
      write. The Windows and macOS boundaries are in TODO-tests-windows.md and TODO-tests-macos.md (2026-11-15).

## Migration and update parity follow-up

Evidence: [six-scope recovery/lifecycle audit](docs/audits/platform-parity/2026-11-04-recovery/report.md). These 17 OS manifestations include shared causes; keep intentional platform policies and all current refusal guards.

### Linux

- Moved to TODO-tests-macos.md (2026-11-15): receive the recovery audit scenarios on isolated macOS.

## End-to-end parity follow-up

Evidence: [12-scope flow review](docs/audits/platform-parity/2026-11-04-flows/report.md). These are OS/flow work items, not a claim of 26 unique causes or native acceptance. Preserve intentional policies and all current refusal guards.

### Linux

- [ ] **[PHYS-W] / [PHYS-M] / [PHYS-L]:** execute only the receiving scenarios named by each flow report on isolated native hosts. Source/recording-port tests do not close native focus, selection, keyring, application or device qualification. Linux, partly (2026-11-11, [receipts](docs/audits/linux-container-proofs/2026-11-11-recovery/README.md)): linux-clipboard X11 target negotiation (`run_clipboard_owner.lua x11`) and the AI selection read and replacement on a real accessibility server (`run_llm_selection_focus.py`, 31 cases) now run in the desktop-webview CI shard. The locked/unlocked keyring and its password prompt (linux-crypto) are received too: a real gnome-keyring and its prompter, answered and dismissed (`run_keyring_receipts.sh`, in CI); it found and fixed a dismissed prompt read as an absent key and a clear on a locked keyring read as done (a6fa8892). The linux-desktop trash and pointer mutations run for real too (`run_desktop_actions_live.sh`: empty_trash cancelled and confirmed on a real gio trash, center_mouse, overlapping toggle_dark_mode; in CI), which found and fixed an empty-trash reported done without GVfs (3da58645). Remaining Linux: a native terminal for LCP-004, chmod (make-executable from a file manager) and eject of a real device (linux-desktop), the case/wrap transforms inside a native editor field. The Wayland clipboard protocol is received too: the clipboard owner over data-control in headless sway (`run_clipboard_owner_wayland.sh`, in CI).
      PC run 2026-11-11: the Windows WCP/WCR/WCF/WDS regressions (`test_clipboard_paste_transaction_ownership.ahk`, `test_keystats_text_cipher.ahk`, `test_wpm_config_types.ahk`, `test_system_actions.ahk`) passed natively on the maintainer's PC, which is not an isolated host.
      Windows, received 2026-11-12 (`tools/test/run-windows-receiving-scenarios.ps1`, temp profile, hosted step « Receive the recovery and flow scenarios »): WCP-001 with two real windows and the real clipboard, a foreground change during the snapshot refusing before any clear or copy chord (the chord is the one recorded port, so nothing is typed), and its control delivering and restoring; WCR on the real DPAPI (round trip read back by an independent Windows PowerShell process; tampered, other-entropy and marker-shaped envelopes refused and never re-persisted) and the metrics cipher sealing marker-shaped typing with the real MachineGuid key; WCF-001 with the widget pair in the real Registry under a private key, read back by the boot loader, and a refused write keeping the previous pair; WDS-002 with the real Clear-RecycleBin failing natively after launch (scoped to an absent drive letter, so the user's bin is never emptied) reaching one error line, and a zero exit reported as done. 8 of 8 passed on the maintainer's PC; every scenario failed once with its owner broken (startup foreground and focus checks, envelope validation, marker skip, pair publication, worker exit observer). Remaining Windows: WCP-002 (the paste into a new foreground window needs real key emission) and a DPAPI blob of another Windows account (a second account).
      [CODE] Left (2026-11-15): Linux LCP-004 native terminal, chmod, eject (maybe a loop device) and case/wrap in a
      native editor field. Windows WCP-002, the DPAPI second account and every macOS scenario are in
      TODO-tests-windows.md and TODO-tests-macos.md (2026-11-15).

## Deep OS × module follow-up

Audited source and immutable evidence: [18-scope review](docs/audits/platform-parity/2026-11-04-deep/report.md). These entries are implementation/validation work, not permission to remove deliberate safety checks or silently change explicit product contracts. Intentional differences and unresolved rationale are in the [provenance register](docs/audits/platform-parity/2026-11-04-deep/intentional-differences.md).

### Linux

- [ ] **Native acceptance:** run the unexecuted AHK/account-context/PnP and actual Mac/Linux device/provider scenarios from each module coverage register. Lua/PowerShell recording-port probes are not native desktop certification. Linux, partly (2026-11-11): the metrics privacy owner on a real GTK/AT-SPI desktop (`run_secure_focus_watch.py`, linux-metrics register) now runs in the desktop-webview CI shard, and the installed daemon grabs and re-emits a real uinput keyboard under systemd ([PHYS-L] proof). Remaining Linux: touchpad hotplug and SYN_DROPPED re-query (gestures), multi-field Tab settling and grapheme deletion in host editors (hotstrings), pointer metrics, live Wayland layout apply, desktop connectors and real mail/calendar (llm). Live Wayland layout apply on GNOME, received 2026-11-13 (worker D): a headless GNOME Shell 46 loads two builds under alternating slots through the Ergopti extension (`run_input_sources_live.sh gnome tests/hardware/run_user_layout_wayland_live.lua`, W1 to W3, run as an unprivileged user; not in CI, which installs no GNOME Shell); KDE stays.
      PC run 2026-11-11: Windows ran the whole AHK suite natively (14 module groups, 20,286 tests) and `e2e/run_e2e.ahk` 90/90; the account-context and PnP scenarios remain.
      [CODE] Left (2026-11-15): Linux touchpad hotplug and SYN_DROPPED, multi-field Tab and grapheme deletion, pointer
      metrics, KDE live layout apply. Windows account-context and PnP and the macOS device and provider scenarios are
      in TODO-tests-windows.md and TODO-tests-macos.md (2026-11-15).
      SYN_DROPPED re-query done 2026-11-16: the gesture decoder threw the kernel's slot registers away on a lost
      queue and never had them at open, so a contact landing on a retained coordinate (which the kernel omits) never
      fired; the reader now answers EVIOCGABS and EVIOCGMTSLOTS (`abs_info`, `mt_slot_values`) and the manager seeds
      the decoder at open and once the dropped packet ends (a touch held across the loss still owns no gesture).
      Regression `test_mt_register_resync.lua` (kernel filter and overflow model, real reader, manager and decoder;
      fails on the old code); the uinput round trip (`run_gesture_roundtrip.lua`, CI native lane) reads the
      registers back from a real kernel. Linux only: macOS and Windows receive gestures from the OS, not evdev.

## Carried over from the 1.0.9 requests (1-2 November)

Released as v1.0.9; these requests of 1-2 November are still open.

- [ ] **Slowness, every driver.** (claimed by worker F, 2026-11-13: the macOS timings are the field points `rerun_2026_11_02` and `main_thread_holds` of TODO-tests-macos.md, Linux is done, the Windows measurements need the Windows PC) Windows boot 7 s, `menu.rebuild` 1.7 s: lazy submenus, single-toggle update, one
      registry proof, full save after ready, disk caches; a toggle must not rebuild 1000 rows.
      Resume here (branch `wip/windows-boot-time`): parse fixes, the smoke operation caps, keyboard before tray root
      and the queued early tray click are committed (keyboard registered at 4.5 s instead of 5.1 s on the smoke
      fixture). Done 11 November: the emoji and symbol sections (1,575 rows on the maintainer's config) register
      after ready in 25 ms Critical slices (`HSE_DeferRegistration`, `[hotstrings] deferred_registration_*`), their
      `Seq` block reserved at the boot position: the registry after the slices is the boot one, 4,242 specs in the
      same order (dumped from both boots), and `(hotstring-deferred-rank)` pins the tie-break, the slicing and the
      stop at a registry clear; the prefix catalogue reads the cache, complete before ready. The AI submenu is
      built at its first open (`MenuDeferOrBuild`, `(llm-menu-built-at-first-open)`), so neither the boot nor a
      toggle's full root rebuild draws its rows. Medians of 7 interleaved boots of the maintainer-config fixture
      (metrics off in the copy: a quarantined smoke is paused and keystats refuses a new ledger while paused, so
      that fixture aborts beside a resident driver), summed `process_cpu`: emoji deferral 9,828 → 9,047 ms
      (hotstrings stage 2,344 → 1,734 ms CPU); then lazy AI 8,609 → 8,391 ms (`menu row llm` 156 → 63 ms, `tray menu`
      719 → 563 ms). The deferred slices cost about 0.75 s of wall over 1.2 s after ready on a loaded machine.
      Next: script parse (lighter boot includes; AHK has no
      runtime include, so only a smaller graph or a worker helps) and layout (rejected disk cache: native hotkey
      registration); the remote AI catalogue (212 ms) can now be measured again with the AI root lazy. Measure each with interleaved base/candidate smoke-fixture boots (summed `process_cpu`). CI of
      the branch: run 41737399378 (first run 41732233161 found two branch regressions, fixed since; its PAC and
      action-picker WebView reds pass locally).
      Windows boot, 3 November. Real logs: 4.75 s at best, 7.8 s typical, 15 s and more
      under load; parse 1-1.7 s, layout 1.2 s, hotstrings 1.0 s, tray 1.0 s (AI submenu 0.75 s), pre-logger 1.2 s.
      Three boots waited 24 s, 26 s and 446 s on a tray opened during boot (`native_menu_wait`): input waits for the
      open menu. Done, measured on a smoke fixture made from the maintainer's config (median of 3 interleaved runs,
      process CPU 7.75 → 7.20 s, menu usable 6.6 → 5.5 s; realistic-hotstrings fixture: hotstrings stage 1.9 → 1.1 s):
      quoted TOML text lexed in native runs (personal file parse 463 → 165 ms), snapshot comparison without map
      copies, one boot snapshot read for the AI options (4 → 1), personal-file metadata decodes only `[_meta]`
      (468 → 29 ms for three 35 KB files). Gate: the startup smoke bounds the boot's counted operations
      (`BOOT_OPERATION_CEILINGS`). Left, deliberate or rejected: parse, layout and hotstring registration (about
      4.4 s) are needed at the first key; the remote AI catalogue (212 ms, rejected while the AI root was eager); the
      boot's 9-13 registry deep compares (every write compares).
      macOS, 6 November: the four script-chord slot rows open the shared action picker, as on Windows, instead of
      inlining the 840-action catalogue each: the Shortcuts submenu fell from 3,537 to 177 rows (unit harness:
      35.5 → 2.6 ms, 5.1 → 0.4 MB allocated per build; field rebuilds grew the heap 13-16 MB and the GC landed in
      this stage, 320-342 ms). The Windows AI submenu is lazy since 11 November; Linux done 10 November: the tray builds a submenu's GTK
      rows when a dbusmenu client opens it and updates a toggled row in place (native publication of the 1007-row
      tree 125 → 1.2 ms, a toggle 118 → 1.0 ms, RSS 137 → 122 MB, headless SNI host; the shared Lua tree build,
      about 78 ms, is unchanged); macOS `menu_keyboard_layout.sources`
      re-reads the bundle variants from disk per rebuild (57-415 ms spikes) and needs a proven cache contract;
      hs.menubar has no per-row update, so a macOS toggle still re-pushes the root, but since 11 November its Lua
      build is bounded: a refresh asked only by clicks in one branch (`menu/ui/transactions/refresh_scope.lua`, through the click
      gate's `around_click`) rebuilds that branch's module and reuses the rows the other menu modules built last
      (`menu/ui/builder/branch_rows.lua`, a decorator over the menu modules, `builder.lua` unchanged). A pause flip, a request
      from outside a click, two branches, or a click in the layout, AI, agent, configuration, language, About,
      Hotstrings or Debug rows still rebuilds everything; Metrics, Shortcuts, Tap-Holds, Gestures and Apps may
      rebuild alone. Real-module tray harness (median of 15 builds, 1,531 rows): full tree 20.1 ms and 2.76 MB
      allocated, one branch 6.2-12.5 ms and 0.43-1.67 MB (gestures the largest); tests `(menu-branch-refresh)` in
      `test_tray_every_submenu_populated`, `test_menu_refresh_scope`, `(menu-click-scope)`. Not timed on a Mac (the
      next field report's `menu.rebuild` lines); the branch lists were decided by the coordinator on 2026-11-11
      overnight, to review by the maintainer.
      macOS, 6 November (wave 3): no cache: the build was repeating work with one answer. Both Keyboard Layouts
      scopes were listed up to four times per rebuild (input-source map, active version, bundles stage, version
      row) and the bundle's Info.plist and variant stats twice; one per-build snapshot now feeds every reader
      (2 listings, 1 plist read; `test_layout_bundle_external_refresh`, `test_input_sources_version_gt`). Not timed
      on a Mac: the next field report's `menu_keyboard_layout.sources` phase says whether the spikes are gone.
      Done 2026-11-15 (`claude/ergopti-todo-mac-layout-sources-cache`, de5c21d18d): the `menu_keyboard_layout.sources`
      disk reads (both scopes' highest bundle and its Info.plist variants) are kept between rebuilds only while an
      FSEvents watcher runs on both Keyboard Layouts folders and has reported nothing since; the driver's own installs
      invalidate at once; no watcher, no cache (`modules/keymap/layout_sources_cache.lua`, test_layout_sources_cache.lua).
      Decided by the agent, to review by the maintainer: FSEvents rather than a directory-time key. The next Mac field
      report's `menu_keyboard_layout.sources` phase confirms the spikes are gone. The Windows PC
      timings and the macOS field points `rerun_2026_11_02` and `main_thread_holds` are in TODO-tests-windows.md and
      TODO-tests-macos.md (2026-11-15).
- [ ] **Before publishing.** (checked by worker F, 2026-11-13: a release gate for the maintainer, no code step) Whole AHK suite on a quiet machine with no resident driver, `npm run test:ahk-tray-rows-read-as-text`,
      all live checks including `quit-over-a-log-flush`, JS, macOS and Linux suites, Windows field report with a driver.
      PC run 2026-11-11: the whole AHK suite ran natively on the maintainer's PC (20,286 tests, reds fixed or reported not executed except TakeNote different-folder) and `e2e/run_e2e.ahk` 90/90; the live checks were 21 pass / 7 fail.
      [RELEASE] Left (2026-11-15): the whole gate, run on the quiet PC before a release.

## Remaining code work

- Moved to TODO-tests-windows.md (2026-11-15): requalify the Windows key-combination and updater cohorts.
- [x] **Windows AV-surface ceilings (found 2026-11-12).** The first Windows / Build of the current tree, run
      43291765266 (artifact `ergoptiplus-av-surface-43291765266-1`), exceeds four ceilings of
      `tools/ci/windows-exe-av-surface.json`: elevated_run 4/3, elevation_wording 4/3, injection_wording 13/11,
      key_state_polling 69/58. The excess is already on `dev` (Build was skipped on every earlier run), at most +2
      key_state_polling from ILD-2 `_KLE_RealCtrlHeld`. The maintainer sets the new ceilings; they guard the antivirus
      surface, so no agent raises them alone.
      Done 2026-11-13 by worker I without raising a ceiling (d10ad40fbc): the new key-state reads of the
      physical-shortcut capture and ILD-2 go through `platform/input/key_state.ahk`, the gesture menu and onboarding share
      one elevated launch (`GestureRestartRunElevated`), and the touchpad reader loads `hid.dll` with `#DllLoad`.
      Windows Build green on run 43536962831 (key_state_polling 58, elevated_run 3, elevation_wording 3,
      injection_wording 11); the ceilings the shared launch dropped are lowered to that measure
      (powershell_policy_bypass 16 -> 15, hidden_window_style 3 -> 2, powershell_mentions 52 -> 46).
      Same landing: Windows Integration Driver startup, red on `dev` since run 43306862276 (realistic-hotstrings
      `toml.flat_values` 1212/1201), follows its new owners: every boot reads the shared tap-hold `shared_file.toml`
      (Mac thumb positions, macOS-only modifiers), the schema v22 migration step and `tap_hold.max_activation_ms`.
      The Windows Unit tests meta red (`desktop-ci-evidence`, « a delay between attempts » 0/2, run 43275487956) was
      already fixed by a8f7c69c2c (the SwiftPM resolve fakes run ahead of Git Bash's own `sleep`): meta is green on
      `dev` runs 43306862276 and 43457158223, so it left the baseline list.
- [x] **Linux hardware test still passes the removed pause argument (found 2026-11-12).** Done 2026-11-13 (worker D):
      the three calls pass the edit source only, and the paused step now expects the copy to run (EDD-1: a pause stops
      typing, not configuration) and an unchanged copy to keep both files byte for byte; the paused session still
      forwards the pair. Needs `/dev/uinput`, so only the Linux E2E desktop-webview job runs it.
      `linux/tests/hardware/run_simultaneous_configuration_real.lua` still passes `script.is_paused` to `Scope.edit`
      and `Scope.copy_taps_to_chords`, which take `expected_source` there since the EDD-1 pause-argument removal,
      so the pause function lands in `expected_source` and Linux E2E
      desktop-webview fails (« original publisher clears only the known third slot », line 252). Drop the argument,
      then confirm with that E2E job.
      Claimed by worker A: both calls now pass only `edit_source()`, and the paused copy is expected to succeed
      with identical bytes (EDD-1); `test_hardware_scope_calls_take_one_source.lua` guards the argument. Proof: run
      43535291046 (2026-11-14), whose Linux E2E desktop-webview job no longer fails « original publisher clears only
      the known third slot »; its remaining reds are the baseline ones.
- [x] **Windows global restore and the preferences source (found 2026-11-12).** On macOS the remap save wrote
      `config.toml` without handing the bytes to the preferences, so « Restore recommended values » refused at the
      shortcuts participant (fixed in 3e209162 by `Preferences.replace_source`). Check whether the AHK global restore
      cohort has the same handoff gap now that `[tap_holds]` and `[mod_combos]` live in `config.toml`.
      Checked 2026-11-13 by worker I: no such gap on Windows, so no code change. The AHK scopes keep no loaded
      source to compare with: `ConfigScopeCommitOperations` (`settings/engine/scope/scope.ahk`, `Build()`) reads `config.toml`
      fresh at commit time, checks drift against that image and publishes under its expected-old hash, and
      `ConfigGlobalScopeApply` puts the tap-hold owner in the same cohort, so no participant hands bytes to the next.
      Covered by `test_config_scope_manifest.ahk` (`scope-hash-precondition`, « inventory source drift refuses
      before any backup »). Decided by the agent on 2026-11-13, to review by the maintainer.
      Checked 2026-11-13 by worker E: no gap on Windows. `ConfigScopeCommitOperations` admits a fresh source
      generation of `config.toml` at each commit (`TOML_BuildConfigUpdatedContent`) and checks the bytes it read,
      so no acknowledged source outlives a remap save the way macOS's preferences snapshot did.
- [x] **ci-acceptance-3 commits not yet on `dev` (2026-11-12).** Closed by worker G on 2026-11-13 (Paris). Checked
      against `dev` by subject: cf44fb4e, aef8ae05 and da7cf001 were already there; 84e97e47 (number-row selection
      timeline) and 4ae1131a (launcher helper resolution logged at boot) are now landed. Not landed, on purpose: the
      MLC-005 relocation rows (faa1ade6, 13af8690, b74741e8, 14d21718, 365dae29). Their gate,
      [43292636135](https://github.com/adrienm7/ergopti/actions/runs/43292636135) job 131487813938, failed on two real
      launcher defects, now the item « MLC-005 relocated launcher refused » under macOS; the rows land with that fix.
      The `ci(probe)` commits were temporary and removed on that branch. The receipts of 8886f2ba and ec54b45e
      (43243856260 passed with the snapshot bracket; 43276494558 refused on macOS 15 without a `tsm.uiserver` line,
      which 84e97e47 now prints) belong to « [CI] Native keyboard-source fixture ».
- [x] **Windows compiled upgrade exit 1 (closed 2026-11-12 on its credible cause).** ed11665a is the credible cause,
      unproven: the upgrade step was never reached afterwards. Watch for a `startup-smoke: uncaught` line on the
      next failure of Windows Install and launch.
      Reached again on 2026-11-14 (run 43536962831), with another cause: the structure step 471744488c had respelled
      the v1.0.9 prior release's extracted asset paths to the new layout, while the published package still ships
      `_shared/core/config_schema/migrations.toml` and `_shared/data/locales/en.json`. Fixed by worker I in
      46536e589d; Install and launch green on run 43549510667.

### Windows (the PC agent's)

State on 2026-11-01. Whole AHK suite at d85a24eb53: 17277/17288 in parallel, the other 11 (clipboard and focus contention
between workers) green alone. All live checks pass, typed by the harness.

- **Parity.** PAR-58 families not yet consumed: `terminator_restoration`, `context_buffer`, `request_plan_*`, the

- [x] **UPD-2 on AHK (decided by the coordinator on 2026-11-12, after the maintainer's real pause).**
      Done 2026-11-13 by worker E: `_Updater_RequestPolicy` allows a manual request whatever the pause and the
      suspend boundary keeps in-flight manual checks; installs keep the AHK-14 pause contract through
      `_Updater_InstallRequestPolicy` (download reservation, managed-failure retry, signature fetch,
      `ForInstall` publication) and refuse visibly while paused; an install asked after a check that crossed a
      pause owns a fresh request. The update-check window keeps its `BornSuspended` capture (F-25) and refuses
      only `update` while paused. AHK-31's suspend cancellation now drives a background request, with a new case
      for a manual check kept through a pause in preparation. Decided by the agent on 2026-11-13, to review by the
      maintainer: the one-click « Update now » is an install and refuses while paused. Installs while paused stay
      the follow-up below. A manual check,
      the changelog and Versions windows, the release links, the channel and interval settings and the update prompt
      should run while paused, as macOS `check_now` and Linux `check_for_updates`; background checks keep their pause
      drop. Tried on 2026-11-12 (ea031503, reverted in 79d1914b): `_Updater_RequestPolicy` allowed a manual request
      whatever the pause, the suspend boundary (`_Updater_SwapAsyncRequestsForBoundary`) kept in-flight manual records,
      the `_Updater_RefuseManualWhileSuspended` guards left the manual entry points, and `UpdateCheck_Perform` lost its
      `BornSuspended` parameter. Windows CI run 43285586086 then showed what else relies on the pause revoking manual
      work, to handle in the same change: `test_updater_transport_ownership.ahk` AHK-31 (a cancellation during owned
      preparation) and AHK-33 (a pause inside the download START must still reject the reservation: installs stay
      pause-sensitive, so `_Updater_TryReserveDownloadTransaction` and `_Updater_ManagedFailureOwnerIsCurrent` need the
      request's pause generation of their own), the native update-consent fixtures
      (`tests/fixtures/update_check_native_consent_body.ahk`, cases 1718-1720), `test_managed_terminal_failure.ahk:159`,
      and the F-25 class loop in `test_webview_bridge_suspend_guard.ahk` that requires every message handler to read
      `A_IsSuspended` (`_UpdateCheck_OnWebMessage`). Installs while paused stay a separate follow-up: the self-update
      transaction stops at a pause in four places, the `updater-self-update` suspend step
      (`_Updater_QuiesceSelfUpdateForSuspend`, `core/lifecycle/engine/lifecycle.ahk`), the staging monitor
      (`_Updater_CancelSelfUpdateForSuspend`), the staging completion (« Update staging completion discarded while
      suspended ») and the swap handshake (« the driver was suspended before the swap handshake completed »).
- [x] **ILD-2, SCD-2 and SCD-3 on AHK (decided by the maintainer on 2026-11-11).** Ctrl+AltGr+key sends Ctrl and the
      logical key, AltGr suspended. `modules/keymap/keylayout/keylayout_emulation.ahk` `_KLE_OnAltGr`: with a Ctrl other
      than AltGr's own physically held, `_KLE_OnShortcut(Sc, "^")` (`"^+"` with Shift) instead of `_KLE_Emit`;
      `test_keylayout_emulation.ahk` `_KLT_OptionsDecide` routes `ctrl altgr` presses the same way, so the shared vector
      `ctrl_altgr_sends_ctrl_and_the_logical_key` replays. `modules/keymap/layout/accented_shortcuts.ahk`
      `AccentedShortcuts_Register`: add the `<^<!` and `<^<!+` prefixes (SCD-2, Ctrl+Alt+é sends Ctrl+Alt+C).
      `modules/shortcuts/utils.ahk` `AddShortcut` for a `^` slot: also `<^>!^` + scan code to the same callback, guarded by
      the physical Ctrl (SCD-3, a `ctrl_x` slot fires for Ctrl+AltGr+x). Tests beside each.
      ILD-2 and SCD-2 done 2026-11-12 (`claude/ergopti-todo-windows-ahk`, 7163ba50 and ee18e2d9: `_KLE_AltGrShortcutMods` with `_KLE_RealCtrlHeld`, the `<^<!` and `<^<!+` chords). Left: SCD-3. `AddShortcut` in `modules/shortcuts/utils.ahk` has no production caller, so the `<^>!^` registration belongs where the `ctrl_x` slots are really registered; find that registrar first, then add the hotkey guarded by `_KLE_RealCtrlHeld()` and test Ctrl+AltGr+x running the `ctrl_x` action.
      SCD-3 done 2026-11-13 by worker E: the Ctrl slots are bound by `KeyboardShortcutsBindAll`
      (`settings/engine/io.ahk`), and Ctrl+AltGr already reaches `_KLE_OnAltGr` with a real Ctrl (ILD-2), so the slot is
      run there: `_KLE_AltGrSlotFor` names the `primary_`/`primary_shift_` slot of the logical key, which runs
      through `RunKeyboardShortcutAction` (Shortcuts gate kept); without one the chord goes on as Ctrl and the key.
      Test `SCD-3` in `test_keylayout_emulation.ahk`; the press on a PC is in TODO-tests-windows.md.
- [ ] **EDD-1 on AHK (decided by the maintainer on 2026-11-12: a pause stops typing, not configuration).** Remove the
      `A_IsSuspended` page-message gates that drop or refuse a configuration write while suspended, in
      `ui/prompt_editor/init.ahk` (`_PromptEdWeb_OnWebMessage` and `_PromptEdWeb_Save`), `ui/paths_editor`,
      `ui/personal_info_editor`, `ui/personal_toml_editor_webview.ahk`, `ui/layer_editor`, `ui/layout_manager`
      (`_LayMgrWeb_*`), `ui/hotstrings_config_window`, `ui/action_picker`, `ui/model_browser` and
      `ui/physical_shortcuts`; keep `ready`'s handling. Test in each editor's suite: a save while suspended writes the
      file. Extended the same day into a « real pause »: also remove the Suspend gates on every configuration or
      install action, i.e. the tray rows the manifest marks `greyed_when_paused` (they stay live while suspended;
      `menu_init.ahk` is now the only reader of that key, so delete it from `menu.toml` together with the gates),
      each menu's whole-scope restore and clear and the Configuration menu's, opening the physical shortcuts
      editor, adding or deleting hotstrings, and installs (layouts, Ollama or MLX models, apps). Then confirm that
      nothing that acts on typing stays active under Suspend (hotstrings, layout emulation, tap-holds, layers and
      chords, shortcuts, gestures, AI predictions and their warmups and local server), with a regression for any
      that still acts, and that a setting changed while suspended applies on resume. Every executable
      `A_IsSuspended` read is listed by file and line, classified, in
      [the Windows inventory](docs/audits/platform-parity/2026-11-12-pause/windows-inventory.md): the writers
      (`infra/hotstrings/personal_toml_io.ahk` among them) refuse too, and the tray root rebuild is refused while
      suspended, which must change before the rows stop greying. See `docs/memory/maintainer-decisions.md`.
      Owned by the parity-b pass (decided by the coordinator on 2026-11-12): its Windows slice for personal hotstrings and personal info is 392ae998, and the remaining gates are listed in [the pause Windows inventory](docs/audits/platform-parity/2026-11-12-pause/windows-inventory.md) on `claude/ergopti-todo-parity-b`.
      [CODE] Left (2026-11-15): the personal info and TOML slice is done (392ae998); the suspend gates of prompt_editor,
      paths_editor, layer_editor, layout_manager, hotstrings_config_window, action_picker, model_browser, menu_llm and
      `greyed_when_paused` remain, each classified against windows-inventory.md; the PC run that confirms them is in
      TODO-tests-windows.md (2026-11-15).
      [CODE] Progress (2026-11-15, branch `claude/ergopti-pause-c2-drop-greyed`): the tray root rebuilds under a pause
      (f092410e7e on dev); the tray greys no feature row any more and the watchdog rebuilds the root once a pause or
      resume settled (c3f678a972, test_tray_pause_greys_features.ahk); every click-reached handler that still refuses
      while paused shows `notify.paused_refused` (667663b685, 72fb9945e5, test_bridge_suspend_guard.ahk
      paused-refusal-notice); the key is now `boot_deferred`, the Windows boot shell's alone (ca4af9d52d). Left: the A
      and B gates themselves (a paused save writes), the AI menus' deferred work, then the PC run.
- **Parity.** PAR-58 families not yet consumed: `terminator_restoration`, `context_buffer`, `request_plan_*`, the
  keystats families, `row_options`, `menus/*`. PAR-74: 549 literals left, the rest of the menu files need
  `test-menu-manifest` to stop pinning their spelling. PAR-79: the 28 literals left are inventory pollers and sleeps
  before the registry loads. PAR-83 done 2026-11-16: the Ollama archive URL's host comes from
  `Identifiers.Hosts.GITHUB` through the download plan (`-ReleaseHost`), no Windows copy left in the baseline. Moving `tests/run_*.ahk` to
  `tests/runners/` is not worth it (455 `A_ScriptDir` uses, 1,908 includes).
- **Tests.** Source assertions left to convert to behaviour; `--reverse` on the `llm` group has 3 order-dependent reds.
  PC run 2026-11-11: `--reverse` on the `llm` group passes 2295/2295 after the order fixes. Count of `_Driver*` source
  reads in the Windows tests: 3,780 in 994 files (meta 3,000, unit 778), down from 3,796. The timer, LLM tray probe,
  keep-awake, scroll capture and password detector pause guards now run under a real `Suspend`. 80 meta files
  still read `A_IsSuspended` from source. Guards that would send keys, paste or move the cursor when broken (text
  sender, tap-hold, dead keys, `SimulateActivity`) need a seam first. The ROI half-life tick and the click
  handlers are guarded a second time downstream, so a behaviour test of their own guard could not fail.
- Moved to TODO-tests-windows.md (2026-11-15): the field report with a driver (step 2 of its order).
- **Signing follow-ups.** Delete `.github/ci/stable_windows_signing_exception.json` once SignPath is configured; flip
  update enforcement to `required` after the `off` release. The relay exe and the vendor binaries are unsigned.
- **Older findings.** The seven "Remaining findings" of
  [the 2026-10-28 Windows audit](docs/audits/windows-2026-10-28/README.md); item 36 updater production coupling (the
  first trusted PowerShell host acquisition); a408a29790 (the four longest AHK unit shards split) was never landed
  and is not on the remote; not redone: every Windows unit shard now ends within 9 minutes (run 43291765266), so the
  split no longer shortens the critical path (decided by the agent on 2026-11-13, to review by the maintainer).
- **TakeNote and the Windows 11 tabbed Notepad.** The Store Notepad titles a window « Notes.txt – Bloc-notes » with
  an en dash; the matcher read only « - » and never found the window (fixed, `takenote-title-separator`). Left: by
  default it opens a second file as a tab of the open window, so a same-named note of another folder shares one
  window with the first, and the module, which binds one window to one path, waits for a window that never comes
  (`takenote-native-document-owner` mode different-folder fails on the PC, passes on the Server runner's classic
  Notepad). Tell the two tabs apart (UI Automation tab items) or select the right tab before typing.
- **Whole AHK suite on the PC (2026-11-10, `fix/windows-pc-2026-11-10`).** 20,286 run, 16 red: 2 token-exchange
  budgets and 1 shortcut path case (fixed), 2 TakeNote (above). The other 11 need what the CI runner installs
  and this PC does not have: the Kana layout (`one-shot-native-kana-*`, 2), a top row that types letters, while
  the PC's first layout is the custom `d001040c` (`layout-row-native-flags`, `layout-row-external-native-flags`,
  `layout-row-pending-dead-key`, 7), and file symlinks, which need Developer Mode (`unblock-selected-file-reparse`,
  2). Skip each with its reason when the prerequisite is absent instead of failing.
  PC run 2026-11-11: the token-exchange and shortcut path cases are fixed, the Kana one-shot cases pass (da5daad768), the layout-row and symlink cases report not executed with their reason (bb49219540); TakeNote different-folder stays (above).

- [ ] **Immediate-Backspace restoration after Notepad-paste and terminal expansions.** Those owners emit after the
      keystroke and keep no undo record, so a Backspace right after their expansion does not type the trigger back.
      Claimed by worker E, then left on 2026-11-13 (decided by the agent, to review by the maintainer): the record is
      cheap (`_HSE_CommitNotepadOwner` and `_HSE_CommitTerminalOwner` could keep it as `_HSE_RememberUndo` does), but
      the undo burst must go through the same owned output as the expansion (the clipboard owner of
      `_HSE_BeginOwnedNotepadTransaction`, the paced capture of `_HSE_BeginOwnedTerminalTransaction`), which only a
      PC run in Notepad and a terminal can qualify. Until then `HSE_UndoExpansion` keeps refusing both hosts.
      [CODE] Left (2026-11-15): not started (bb083f60a4); the Notepad and terminal owners keep no undo record. The PC
      run that qualifies the fix is in TODO-tests-windows.md (2026-11-15).

- [x] **LogsDirPath under the old folder name.** `settings/engine/migration/legacy_folder_migration.ahk` renames a custom logs folder named
      like the old app folder to `Ergopti`, as macOS and Linux do since 2026-11-11 (shared `renamed` rule).
      Done 2026-11-13 by worker E: `LegacyFolderCustomLegacyLogs`, `LegacyFolderCustomLogsStep` and the `renamed`
      rule of `LegacyFolderRebased`; the logger's entries move, the user's own files stay (tests
      `legacy-folder-custom-logs`).

- [x] **Hotstring header rows outlive their expiry** in the « both » stack of `llm.trigger.while_hotstring_tooltip`
      until the next render.
      Done 2026-11-13 by worker E: the panel arms a repaint at its first header deadline
      (`_LLM_TooltipArmSharedHeaderExpiry`, through the repaint-only `_LLM_TooltipRenderOwnedNavigation`); test
      `llm-hotstring-tooltip-both-expiry`. Seeing the row leave on screen is in TODO-tests-windows.md.

- [x] **Restored API entry without a usable key.** DPAPI keeps the key inside the backup: check whether a restore under
      another user or machine yields an unusable key, and give it the « API key… » re-enter row as macOS and Linux do.
      Done 2026-11-13 by worker E: it does (`LLM_ApiToken_Decrypt` keeps the envelope, which was then sent as the
      key). `LLM_ApiToken_Unusable` makes the menu row offer only the key edit, skips the model listing and refuses
      the request (test `api-entry-restored-key`); a real restore under a second account is in TODO-tests-windows.md.

### macOS

- [ ] **MLC-005 relocated launcher refused (found by worker G on 2026-11-13).** In
      [43292636135](https://github.com/adrienm7/ergopti/actions/runs/43292636135) (macOS 26, job 131487813938) the
      launch gate of the relocation rows passed `symlinked_applications` but failed two scenarios on
      `platform/remap/lease_helper.lua`: `spaced_accented_path` (« bundle-owned ErgoptiPlus helper no longer matches the
      running launcher »: the exact-path or identity proof refuses an install under « Applications de Léa », then Quit
      did not end both processes in 10 s) and `translocated` (« ERGOPTI_LAUNCHER_EXECUTABLE differs from the
      bundle-owned helper »: the launcher exports its translocated path while the Lua tree derives another). Fix both
      in the launcher/helper proof, then land the rows of branch `claude/ergopti-todo-ci-acceptance-3` (faa1ade6,
      13af8690, b74741e8, 14d21718, 365dae29) with a green macOS 26 Install-and-launch row. Needs a Mac or the hosted
      macOS 26 lane; the failed-launch artifact (13983003738) holds the launcher logs.
      [CODE] Left (2026-11-15): 5fcb564b04 proves the helper by device and inode (test_lease_helper_identity.lua).
      The five relocation-row commits are on dev since 2026-11-16 (ported from `claude/ergopti-todo-mlc005-rows`,
      branch deleted). Left: confirm the three relocation rows green in the next hosted macOS 26 Install-and-launch run.

- **Field report 2026-11-03 (`mac-2026-11-03_102716`), branch `fix/macos-field-2026-11-03`.** Done: ai_local no
  longer lists the owned endpoint without its binary (no ERROR); n-gram history merges paced (458 ms slice); the
  dashboard no longer resends an unchanged history each live update (250 ms holds, +73 MB heap per minute). Already on
  dev: blob Range redirect (e6942d05c2), diagnostics phase A (e76a5443f8), post-wake AX hold (1f2884f13c), owned
  Ollama Go test enrolment (627bfad0af). Done since: the hardware UUID keystats start needs is read by an ioreg child
  during the start delay (`modules/keystats/host_signature.lua`), no longer by `ioreg -d2` on the main thread (151 ms
  at boot+1 s); a later Metrics toggle still reads it synchronously when no prefetch ran. Karabiner regeneration stays
  synchronous (merge 170 ms, layout actions 230 ms cold: event_taps `runloop_late_ms` 294), no safe non-blocking
  design: the work is in-process Lua plus native calls (`hs.keycodes.map`, `hs.json`, the file write), which no child
  can do, and slicing it across run-loop turns would let layout, pause and lease events land between a build and the
  layout serial, lease token and epoch it was validated against. Measured on Linux Lua 5.4 under the stub harness
  (shipped recommended preset, 6 rounds): layout actions 1.1-1.8 ms, build 27-40 ms, merge 9-30 ms, encode 11-44 ms
  (258617 bytes); so the field 230 ms in `karabiner.layout_actions` is native, not the Lua loop. Next: split that
  phase on the Mac (`Layout.keyboard_form()` registry snapshot vs the 548 `hs.keycodes.map` lookups) before touching
  it. The menu Apps folder reader already uses `FsDir.try_entries_quiet`; the obsolete `find` follow-up is closed. Done 2026-11-11: `Config.resolve_layout_actions` times that phase's two halves apart (`karabiner.layout_actions.keyboard_form`, the registry snapshot, and `karabiner.layout_actions.key_codes`, the 548 lookups; regression in `test_actions_not_rebuilt_per_layout`), so the next Mac field report's phase lines and slow-callback attributions name the half to move. Left: decide from that report; the read is in TODO-tests-macos.md (2026-11-15).
- **One folder name for Ergopti on the three OS.** The shared roots and boot migrations are already on dev. The maintainer's machine checks against `docs/tooling/one-folder-name-handoff.md` are in the three TODO-tests files (2026-11-15); remove the migration only once those checks pass. Rename the owned Karabiner runtime folder (`ErgoptiPlus`) in its next rebuild (item 31). Checked 2026-11-11: no code step is left here. The runtime folder rename is the maintainer's release step: it changes the compiled runtime, so it needs a rebuilt and republished pinned remap runtime (`vendor/remap-runtime/manifest.json`), which agents do not touch; removing the migration waits for the maintainer's machine checks.
- **31. Owned Karabiner runtime** ([ADR 011](static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md),
  [handoff](docs/tooling/next-release-handoff.md)). Status on 4 November, all on `dev`:
  - Done: the owned runtime is the default (`RUNTIME_DEFAULT = "owned"`, the two Configuration rows and
    `remap_switch.lua` gone). Runtime `16.3.0-ergopti.3` published (prerelease `remap-runtime-v16.3.0-ergopti.3`,
    downloaded back: sha256 `eced1bfd…dc4567`, 12351916 bytes) and pinned; its hosted sudo install acceptance passed on
    macos-15, macos-15-intel and macos-26 (Remap runtime build run 41895547018: files, Core and VirtualHIDDevice jobs
    loaded, pqrs' package installed in the same shell, stage retired). The install is offered once by itself (one
    confirmation, one administrator prompt), the driver approval pane opens and is watched, the Tap-Holds row retries;
    the field run and the collector (`--installed`) report every install fact.
  - Decided: field-tested on the CI-signed dev build, never the ad hoc developer app; no Developer ID for now (item
    below).
  - Next: the maintainer's WP9 pass (handoff checklist, in TODO-tests-macos.md since 2026-11-15) once a signed dev build
    is authorized, then the shared-mode deletion. Checked 2026-11-11: both steps are the maintainer's (a signed dev build and a physical Mac); no code step precedes them. Done on 1 November: the per-OS feature requirements table (`docs/design/feature-requirements.md`) and
    the driver-only VirtualHIDDevice update offer (3ebab93a17).
- **Owned runtime with a Developer ID (maintainer: not now, 2026-11-04).** With the self-signed CI certificate the
  install takes one administrator prompt (the root Core and pqrs' daemon are LaunchDaemons bootstrapped by the
  helper), Login Items lists them as separate « unidentified developer » rows, and the driver approval names pqrs'
  extension. A Developer ID would allow: `SMAppService.daemon` for both jobs from `Contents/Library/LaunchDaemons`
  (no password, one « Ergopti » Login Items group; launchd kills SMAppService jobs of a bundle with no Team ID,
  `RemapLeaseGuardian.swift`), and an Ergopti-signed DriverKit extension in `Contents/Library/SystemExtensions`
  activated with `OSSystemExtensionRequest` (needs Apple's DriverKit HID entitlements for the team). The root Core
  keeps its own Input Monitoring row either way: launchd starts it, not Ergopti.
- **Owned runtimes.** The rows in state "to do" of `_shared/core/network/data/owned_runtimes.json` are all item 31 (shared
  Karabiner app, owned runtime, VirtualHIDDevice). The Swift-owned managed daemon under the proxy relay needs a short
  design note first (who launches the relay, how its refusal receipt reaches the Swift owner; Swift and Go). Done on 1
  November: App Cloner on the managed Python with pinned PyObjC 12.1 (managed-pyobjc.json, ensure-managed-pyobjc.sh
  under the native PTY guardian, consent offer from the Apps menu, stable link `native-bootstrap/app-cloner/python3`;
  existing clones keep /usr/bin/python3 until re-cloned). Checked 2026-11-11: the managed-daemon relay row stays blocked on that design note (who launches the relay, how its refusal receipt reaches the Swift owner), a maintainer decision; no code step is open before it.
- **Checks left to a program from the Mac session.** Done on 1 November: `field_tap_hold_thresholds` (9901da4d94;
  PAR-15 is confirmed by the next field run's result);
  the HTTPS downgrade refusal is already covered by `ManagedPACSourceTests` and `ManagedBootstrapDownloadTests`.

- [ ] **Owned runtime rebuild (macOS release step).** The next runtime build ships the MRT-004 « Réparer le service »
      helper role and the helper's one-hash report rule (`OwnedVirtualHIDDaemonReportStageOwner.admitImage`); rebuild it
      and update its manifest pin.
      [RELEASE] Left (2026-11-15): not started; the pinned runtime (16.3.0-ergopti.6, 110d8949fb) predates MRT-004
      (ff861e3640).

- [x] **`events_typing.rich_text` in clear (AHK-005 / WM-002 left).** With metrics encryption on, Windows and Linux
      store it empty; macOS still writes the typed text to SQLite. Done 2026-11-13 (worker F): the macOS writer stores
      nothing there while encryption is on, and the shared encrypt pass first empties the local device's stored copies
      (`text_migration_core.clear_rich_text_sql`, macOS and Linux backends; the Windows AHK pass needs none, its
      writer never fills the column). Tests: `test_rich_text_not_stored_encrypted.lua`, runner contract.

### All drivers

- [ ] **Structure plan (maintainer request 2026-11-11):** [docs/design/structure-plan.md](docs/design/structure-plan.md).
      In progress: see « Resume here » at the top (branch `claude/ergopti-todo-structure-phase2`).
      Rule A: every common value, text and logic in `_shared`. Rule B, decided by the maintainer on 2026-11-11:
      feature-first trees (`<feature>/{engine,adapters,ui,data,native}`, `core/`, `platform/`), the same on every
      driver and in `_shared`; file prefixes the folder repeats are renamed away (`keystats_walker.ahk` →
      `walker.ahk`); `remap` is named `keyboard`; tests stay in `tests/<kind>/` mirroring the feature tree.
      Start trigger: the go comes from the maintainer, as soon as the maintainer's AHK session has pushed its last
      feature commits; the coordinator then launches phase 2 at once, one step per commit with
      `tools/audit/structure/apply-step.cjs` (`--check-all` must be clean first).
      [DECISION] Left (2026-11-15): phase 2 steps S1 to S17 are on dev (471744488c … 1f3361a57c); S18 to S38 remain, to
      launch only with the maintainer's go ([CODE] after that).
- **Provider flags inferred, not read.** Checked against the docs on 1 November (90344262aa): Featherless and
  Qianfan confirmed. Rechecked on 10 November (7ae1147b): the Perplexity, `dashscope-intl` and Moonshot K2 watches
  are closed and guarded by `test-llm-provider-retirements.cjs`. Left, both only provable with a live key (the docs
  hosts are unreachable from cloud sessions and show no off example): SambaNova's `enable_thinking: false` (off is
  its default, docs show only `true`) and the Chutes Qwen `enable_thinking` field; a refusal is dropped and
  remembered either way.
- **Tooling found on the way (4 November).** The source seal now reads Git blobs without creating a temporary checkout. On the Windows PC these fail on a clean `dev` for
  environment reasons, so only CI proves them: `test-site-github-release` and the site deploy admission controls
  ("file changed before capture"), `test-keylayout-row-options` (different Lua keyboard ids),
  `test-linux-field-report-contract` (setup error), `test-menu-manifest` in a worktree (a `node_modules` junction
  copy fails with `EPERM`). Make each one pass locally or skip with a stated reason.
  PC run 2026-11-16 (worktree on dev 164d6536aa, its own `npm ci` node_modules, `PYTHONUTF8=1`): all pass or skip
  with their reason, so nothing is left here: `test-site-github-release` (35 controls),
  `tools/test/fixtures/site-deploy-admission-controls.cjs` (165 controls), `test-keylayout-row-options` (10 cases),
  `test-menu-manifest`, and `test-linux-field-report-contract` skips (« a Linux shell tool; not run on Windows »).
  A worktree whose `node_modules` is a junction to the main checkout was not retried.
- **108. Per-device physical bindings.** Deferred until designed: the collision, source, modifier and output joins
  of a shortcut bound to a key position on one device; `keyboard_hook.capture_position` hands only `native_code` and
  `mods` (macOS capture is item 31's).

- [x] **Modifier-chord action labels from the key name table.** The action pickers still show raw or French chords
      (« Cmd + Option + Shift + Enter ») on every driver; the tests that pin this label family change with it.
      Checked 2026-11-13 (worker F): already done on the three drivers, every picker row goes through the shared
      `key_names.chord_label` (macOS `gestures/actions.lua` and `remap/config.lua`, Linux `gestures/manager.lua`,
      Windows `KeyNameChordLabel` in `gestures/actions.ahk`), pinned per locale by `test_action_catalogue_parity.lua`
      and Linux `test_key_names.lua`. No code step left.
      Verified done by worker A on 2026-11-13: every driver names a chord through the key name table (shared
      `key_names.lua` `chord_label` on macOS and Linux, its AHK port `KeyNameChordLabel` on Windows), and the web
      picker shows the host's labels; pinned by `test_key_names.lua` (Linux), `test_action_catalogue_parity.lua`
      and the script-action projection corpus (macOS) and `test_gestures.ahk` (Windows).

### Linux (container proofs of 2026-11-10)

- [ ] **Legacy Linux updater probes (remove later).** Installed Linux updaters before the structure move (v1.0.9 …
      v1.0.10-dev.175) admit a staged tarball only with `_shared/data/locales/en.json` and a `_shared/lua/` folder;
      `tools/build/add-linux-legacy-update-probes.sh` adds both to the release tarball (decided by the coordinator on
      2026-11-13, confirmed by the maintainer on 2026-11-14: Linux has no users yet, so this protects any v1.0.9 …
      v1.0.10-dev.175 installation that exists in the future, and stays minimal: one generated file, the empty
      `_shared/lua/` v1.0.9 requires, one regression test; proved locally by the real v1.0.9 installer applying a
      post-move tarball, and in CI by each release's own `ownership.sh`, frozen from the v1.0.9 and v1.0.10-dev.175
      tags in `tools/test/fixtures/linux-pre-move-ownership`, recording the packed tarball). Remove that step, its
      call, `test-linux-legacy-update-probes.cjs` and those frozen helpers once the first release whose
      updater finds a staged shared root by `build_stamp.txt` (a9c6e90be8) has been out for one full release cycle.
      The structure step that moves `linux/infra/version.lua` (also required by v1.0.9) fails this build until it
      adds that probe too. macOS only loses the boot-health probation if `macos/infra/updater_boot_ready.lua` moves;
      Windows replaces one exe and probes nothing (rechecked on the v1.0.10-dev.175 sources on 2026-11-14: its
      workers and caches are the installed build's). The live updater E2E step installs this checkout and updates
      it to the newest published prerelease, so it stays red until a post-move dev prerelease exists. Landed by worker G on 2026-11-14; its check passed in CI run
      [43579693369](https://github.com/adrienm7/ergopti/actions/runs/43579693369) (Common Packaging and boot, 25/26).
      [LATER] Left (2026-11-15): remove the probe step, its call, its test and the pre-move fixtures once a post-move
      release has served a full cycle.
- [x] **GNOME input source switch.** GNOME Shell 46 ignores runtime writes of `mru-sources` and `current`: on a
      `sources` change it keeps its in-memory MRU and activates its first entry, and a non-interactive activation
      writes no `mru-sources`. Done 2026-11-11 in `adapters/input_source_switch.lua`, decided by the coordinator on
      2026-11-11 overnight, to review by the maintainer: the switch writes `sources` as the target alone, waits
      `gnome_input_source_settle_ms`, writes the list back with the target first (as the installer already places an
      activated layout) and `mru-sources`; a failure after the first write puts the list back, coalesced writes end on
      no switch, never another layout. Left: the installer's `apply_gnome` (desktop_activation.py, W1 to W3) still
      writes the list with the layout first, which a running shell ignores; it needs the same sequence and a Python
      reader of the shared settle constant. 2026-11-11: the installer's live selection (`_gnome_select`, apply-wayland)
      now writes the slot alone first and waits the settle time the daemon passes (`--gnome-settle-ms` from the shared
      registry), and its XWayland read-back finds the layout by content in mutter's « (unnamed) » keymap (before, it
      looked only for the layout's name, which mutter never writes, so every GNOME apply ended `not_loaded`). Still
      `not_loaded` on GNOME 46 headless with both in place: one more cause is not found yet. Found 2026-11-11: GNOME
      Shell reads the user registry (`~/.config/xkb/rules/evdev.xml`) only when it starts, so an id registered after
      login is unknown to it and the slot alone switches the session to its `us` fallback. apply-wayland now compares
      the registry's date with the shell's start, registers both slots and answers `needs_relogin` without touching
      the setting; after the next login every build alternates live. [Proof](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md).
      2026-11-13: the daemon's runtime switch no longer writes `sources` (see « GNOME layout switch through the Ergopti
      GNOME Shell extension » above). Done 2026-11-13 (worker D): the installer switches the running Shell the same
      way. `apply-wayland` (`_gnome_select`) writes the lists with the slot first for the next login, then activates
      the slot through the extension once the Shell lists it (a bounded poll, no settle time: `--gnome-settle-ms` and
      `gnome_input_source_settle_ms` are removed), and answers `gnome_extension_missing` with the setting put back
      when the extension does not run; `apply_gnome` (W1 to W3, install) asks the extension too and otherwise says the
      layout is active at the next login (the extension activates listed sources only, so an id the Shell has not
      read never falls back to `us`). Proved on a headless GNOME Shell 46 as an unprivileged user:
      `run_input_sources_live.sh gnome tests/hardware/run_user_layout_wayland_live.lua` holds W1 to W3 (7 checks
      over the new login), and `gnome-no-extension` names the extension; `test_wayland_live_replace.py` models the
      Shell with a fake extension. Linux only.

### Linux performance (2026-11-11, branch `claude/ergopti-todo-linux-perf`)

Claimed by worker L on 2026-11-13 (branch `claude/ergopti-todo-linux-perf-2`), taken over from worker D.

Measured with `tools/bench/linux-session-bench.py` (real daemon, Xvfb session over the kernel model; report in
`docs/audits/performance/linux/2026_11_11/report.md`). Budgets and the reuse rules below were decided by the
coordinator on 2026-11-11, to review by the maintainer.

- [ ] macOS boot: `migrations.toml` (74 KB) is parsed and validated at every boot (about 30 ms of Lua 5.4); a
      generated, hash-checked Lua mirror would remove it (maintainer decision, numbers in the report).
      Other OS, measured or read 2026-11-14 (worker L): Windows already skips the parse with a typed cache keyed by
      the registry's SHA-256 and the parser files' identity (`settings/engine/publication/registry_cache.ahk`, validation still runs
      on a hit; its parse cost about 0.5 s); Linux parses the same file under LuaJIT in about 7 ms cold and under 1 ms
      warm (`settings.engine.migration.migrate.load_registry`, 21 runs), not worth a cache. Decided by the agent on
      2026-11-14, to review by the maintainer: not built tonight. The parity path is a port of the Windows cache to
      Lua (native `hs.hash.SHA256` of the source, a typed codec that evaluates no cached code, validation kept on a
      hit) rather than a generated mirror, whose staleness only a gate would catch; it needs a Mac to measure the
      30 ms it would save, and config migration is the place a wrong cache would rewrite a user's settings.
      [DECISION] Left (2026-11-15): port the Windows typed SHA-256 registry cache to Lua or not; the Mac measurement of the
      saving is in TODO-tests-macos.md (2026-11-15).
- [ ] Windows counterparts (the maintainer's PC): the same `[Span]` TRACE/DONE pair and names in
      `infra/hotpath_profiler.ahk` for `hotstring.expand`, the tray submenu build and a layout switch; a
      millisecond-stamped kernel-to-output latency (`A_TickCount` against the hook's event time) as
      `input.latency`; a `load` phase before `BootProfiler` starts; the last interval summary at exit.
      2026-11-14 (worker L), code done, the field read stays on the maintainer's PC: `HotPath_SpanTrace` /
      `HotPath_SpanDone` (`infra/hotpath_profiler.ahk`) write the Linux and macOS pair, `[TRACE] [Span] <name>…` and
      `[DONE] [Span] <name> done in N ms (<outcome>)`, at DEBUG only, for `hotstring.expand` (the InputHook typing
      path, its held-back end key and the Space tap-hold; outcome fired, declined or pending), `tray.fill` (each
      deferred submenu build) and `layout.switch` (an input source from the menu, and an emulated layout up to its
      reload handoff). Test: `test_hotpath_span_lines.ahk`. Already present before, verified in the source: the `load`
      phase is BootProfile's « Pre-logger initialization (including script parse + load) » line with its replayed
      stamps, and the last interval summary is written at exit by the logger's `OnExit` (`_LoggerOnExitFlush` →
      `HotPath_StopStatistics` → a final `HotPath_FlushStatistics` with the PerfCounters line). Decided by the agent
      on 2026-11-14, to review by the maintainer: no `input.latency` on Windows, because the InputHook callbacks
      receive no event time (only `vk`, `sc` or the character); only the opt-in input probe's low-level hook sees
      `KBDLLHOOKSTRUCT.time`, and a second permanent low-level hook for a metric would add a hook timeout risk to
      every key.
      [DECISION] Left (2026-11-15): code done (9a3fa08e75; test_hotpath_span_lines.ahk); the maintainer's review of
      shipping no `input.latency` on Windows. The field read on the PC is in TODO-tests-windows.md (2026-11-15).

- [x] Keystats boot: `open_db`'s own spawns (mkdir, schema checks), device registration and the open-walk read still
      cost about 30 ms of sqlite3 processes.
      Done 2026-11-13 (worker L): `open_db` reads the registry DDL and the raw tables lacking `utc_offset_min` in one
      sqlite3 process (the missing names first, so the multiline DDL is the exact remainder) and runs the shell
      `mkdir` only when the folder is absent (in-process metadata probe, no luv: the no-luv contract holds). A warm
      open is 2 processes instead of 4, the whole keystats store boot (open, registration, both migration checks,
      open walk) 6 instead of 8: median 37.6 → 29.5 ms over three sets of 21 boots (p95 40.6 → 32.3 ms), measured
      on the writer alone against the HEAD copy. Regression: `keystats-open-processes` in
      `test_sqlite_first_open.lua` (fails on the old writer with 3 processes and a mkdir). Worker D measured an
      in-process mkdir through luv before (keystats stage 49 and 44 → 45 and 43 ms) and reverted it for the no-luv
      contract (branch `claude/ergopti-todo-linux-desktop`, 59ea694c). Other OS: macOS (`hs.sqlite3`) and Windows
      (`sqlite3.dll`) open the store in process, so no per-query process cost exists there; this cost is the Linux
      driver's sqlite3 CLI design.
- [ ] Keystats boot, the rest: registration, the two migration checks and the open walk are one sqlite3 process
      each (about 4 ms: a shell, then sqlite3). Merging the reads would hand the public migration functions a value
      read before the registration, which their tests drive one query at a time, so the remaining cut is a
      persistent sqlite3 child for the synchronous writer ([design](docs/design/linux-sqlite-persistent-child.md)).
      A design for the maintainer (worker D and worker L agree, 2026-11-13). Bench note: the session bench's tray
      panel needs the Python that has GObject (`/usr/bin/python3.12` on Ubuntu 24.04 when `python3` is a newer
      build); run the Lua suite as an unprivileged user, root passes every EACCES probe.
      [DECISION] Left (2026-11-15): approve the persistent sqlite3 child of
      docs/design/linux-sqlite-persistent-child.md, then implement it ([CODE]).

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
  - pause: a dead key pending in the system's own layout (no emulation) stays the OS's state.
