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

## Handover (state on 2026-11-24 00:45 Paris, read first)

Everything is on `dev` (tip `78fa30d1fa`); `v1.0.10-dev.178` is published. Stable `v1.0.10` waits for the
maintainer, who will try `dev.178` on the Mac first: never push `main` without their explicit go.

- [ ] **[CI] Read the next complete `dev` run** and turn any red green. Run 45289220983 (`88310973bc`) had one
      red, the Windows updater source seal, resealed by `470a83a50b`; run 45292696642 (`282f8c1192`) stopped at the
      formatting of this file. Never verified on a runner yet: the Swift lease fix (XCTest
      `testParentEOFKeepsFencedQueuedBehindHangupAfterStaleReadyRead`, no Swift toolchain in the cloud container), the
      Windows `TEST_NATIVE_SETTLE_TIMEOUT_MS` waits (15 AHK tests, then on 2026-11-24 the per-file limits and four
      child fixtures guarded by `tools/test/test-ahk-native-settle-bound.cjs`; production
      `SR_TREE_TERMINATION_CONFIRM_BUDGET_MS` stays 500 ms unless a forced-termination test flakes alone), the Ubuntu APT and Playwright download retries,
      and the keyring proof readiness wait. A macOS Apple-silicon job « not acquired by Runner » is GitHub capacity:
      rerun the failed jobs, do not move it to Intel.
- [ ] **[macOS] Owned runtime artifact.** The admin-shell helper changes of 2026-11-23 (stale runtime retirement
      before install, refusal note `refused-<case>:<file>:<line>`) only reach users once the maintainer rebuilds
      and republishes the runtime (`16.3.0-ergopti.7`); `vendor/remap-runtime/manifest.json` is theirs to move.
- [ ] **[macOS] Install journal left by an interrupted install** (field report 2026-11-24, dev.178,
      `refused-cleanupPending` at `OwnedRuntimeInstallJournal.swift:94`). Fixed in the launcher: the install's
      administrator shell retires `.runtime-install-journal`, `.runtime-service-journal` and the
      `.runtime-install-<UUID>` stages once `lsof` shows no helper holds them (field point
      `owned_install_stale_journal`). Left for the `.7` helper: `OwnedRuntimeInstallJournal.retireUnpublished` still
      refuses a journal with only its header (a failure between `create()` and the stage's first record), so that
      helper leaves cleanup pending until the next install's shell retires it.
- [ ] **[macOS] Menu requests of 2026-11-24 (maintainer, photo of the dev.178 menu).** Tap-Holds title without a
      dot while the owned runtime was not installed and its install refused: fixed, red 🔴 even with the switch off
      and repainted when the runtime fails after a build (field point `tap_holds_title_red_dot`). Windows and Linux
      draw no Tap-Holds dot: their tap-holds have no separate runtime. The « Ergopti+ » header pill sat left of the
      menu's middle (about 30 % to 52 % of its width): now centred on the whole menu width, its column metrics
      calibrated on the photo (field point `menu_header_pill_centred`); Windows and Linux draw no header pill.
      Debug: « Console » reads « Console Hammerspoon » (macOS only: Windows offers Window Spy, the variable list
      and the key history under their own names, Linux has no console row), and « Afficher une fenêtre à chaque
      erreur » opens the Logs section, before a separator, on the three OS. « Journal détaillé » replaced the
      log-level selector (unticked INFO, ticked DEBUG, same `script.log_level`; maintainer-decisions « Detailed
      log »). The bug report's warnings group ends with « Detailed log: off — turn on Debug › Detailed log and
      reproduce for more detail » while the switch is off (report_vectors.json, three ports). macOS gains the
      Windows « Suspendre » row right before « Recharger », ticked while paused; the title pill still toggles
      (field point `tray_suspend_row`). Linux draws the same row before « Recharger » (maintainer, 2026-11-24), and its paused header row still resumes. Configuration groups its rows under « — Réinitialisation — »,
      « — Fichiers et assistant — » (cleanup, paths, wizard: no more one-row group), « — Réseau — » (proxy) and
      « — Accessibilité — » (window font and spacing), the same on the three OS (field point
      `configuration_titles`).
- [ ] **[macOS] Engine dialog icon.** On dev.178 the install result dialog (`hs.dialog.blockAlert`, an `NSAlert`
      that sets no icon and so shows the engine's application icon) still showed the hammer, although
      `build_icon` gives the embedded Hammerspoon.app `CFBundleIconFile` ErgoptiPlus and removes `CFBundleIconName`
      (b3c3708a80). On the Mac: `plutil -p /Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/Info.plist | grep -i icon`
      and `ls …/Hammerspoon.app/Contents/Resources/*.icns`; if both are right, the icon is a stale Launch Services
      entry of the updated bundle (`lsregister -f` on it, then restart Ergopti); otherwise fix the build step.
- [ ] **[macOS] Check `dev.178` on the Mac** (then move what stays open to TODO-tests-macos.md with its field
      point): no hammer icon in the menu bar, rounded icon in Quick Look, Accessibility guidance names
      ErgoptiPlus.app, the Tap-Holds submenu is greyed except « Réessayer l'installation… » while the runtime is not
      installed, AltGr and Shift+AltGr are emulated once a layout is chosen, the update window keeps a right margin beside its progress bar and its button row (fixed 2026-11-24), no « Aggregate cache recovery failed »
      or `%s` in the log.
- [ ] **[Maintainer] Questions left open:** keystats day-by-day aggregate publication shipped, review welcome. The
      Tap-Holds dot is settled (maintainer, 2026-11-24): 🔴 whenever the owned runtime is missing, refused or failed,
      even with the switch off; the warning keeps the shared yellow 🟡 (no orange).

## Next session (state on 2026-11-17, read first)

- **Goal unchanged:** a fully green `dev` CI, then publish dev prerelease 176; then empty this file.
- **Load and disk (maintainer):** at most 5-6 agents at once and at most 2 running heavy local suites (full AHK
  groups, WSL Lua suites, interactive desktop checks); prefer CI on temporary `ci/verify-<sha>` branches (deleted
  after reading). After each agent: remove its worktree and scratch files; purge stale scratch dirs, WSL `/root`
  copies and the npm cache regularly; compact the WSL disk image when no agent uses WSL (C: reached 2.8 GB free).
- [ ] **CI reds left after verify run 44072500520** (decisions taken 2026-11-17):
  - macOS Intel « managed Ollama build handoff never arrived »: maintainer decision: make the consuming cell
    `needs` the Intel build job and update `macos-stage-contract.json` with its review. Done locally on
    2026-11-18: both managed Ollama builds run in their own job `e2e-ollama-build`, which `e2e-hs` and Build
    need (stage roles, admission, contract and tests updated); confirm on the next run that « macOS / E2E tests
    (Managed Ollama build (macOS 15, Intel)) » ends before « macOS / E2E tests (Managed Ollama (macOS 15,
    Intel)) » starts and that the receiver admits the handoff on its first poll.
  - Re-read the first complete run after these; keylayout owner pin and Menus « cold command section » to confirm.
- [ ] **Exact-count ceilings in tests (maintainer: « ces tests avec seuil magic value c'est vraiment mauvais »).**
      `toml.flat_values` was raised to 1500/2600 on 2026-11-17 to unblock CI. Replace exact operation counts and
      similar magic thresholds (boot operation ceilings, literal ratchets where they only count) with budgets that
      mean something (time, order of magnitude, or a named single source), one ratchet at a time.
      Done 2026-11-18: the startup smoke has no count ceiling left. It names the owners of the boot's repeated
      work (`BOOT_WORK_OWNERS`: re-parses, config.toml snapshot reads, registry deep compares), a lexer test
      proves slow steps do not grow with run length, and the re-parse debts (personal-file activation,
      terminator records, LLM privacy rows) read the admitted snapshot document. The unit ratchets of the flat
      write and the typed transaction parses now name the owner that must not parse twice. The logger, the
      feature loader and the metrics settings read config.toml through the boot read stretch
      (`ConfigTomlReadBootServedSnapshot`), so the table has no snapshot-read debt left.
      Done 2026-11-19: the Studio speed checks (13 ms per library layout in the engine test, 600 ms per layout in
      the analyser scores) time the analysers against a reference walk of the same table in the same process
      (`tools/test/lib/table-walk-speed.cjs`); an engine five times slower fails the bound on any load. The
      best-swaps browser test reads the panel's `LIMIT`/`CYCLE_LIMIT`, the Studio and app-window keyboard walks
      end when a stop repeats (bounded by the document's elements) instead of after 1500/800 presses, and the
      shared-parse memo test reads `TOML_SHARED_PARSE_ENTRIES`. Reviewed and kept: the stretch counts in
      test_journal_boot and the saved-options read in ai/menu test_persistence equal one comparison or read per
      stretch or build, against loop counts the test itself chooses, never a product ceiling. Left: the two
      speed bounds (120 and 5000 walks) rest on ratios measured with every core busy and a quiet ratio estimated
      1.6 times higher; read the ratio each test prints on a quiet PC and on CI, and set each bound to twice the
      highest.
      Done 2026-11-20: the startup smoke times the slowest Hotstrings menu render against the same boot's other
      deferred submenu builds (`HOTSTRINGS_RENDER_SHARE`, at most all of them together; clean boots 0.07-0.25,
      a reparse per metadata question 9.5). The Ergopti extension tests of the three drivers read their bound
      files from the extension manifest and the SFB, rolls, repeat-correction and suffix counts from the shipped
      files; the Windows cache test counts the symbol rows of magickey.toml; the Linux and macOS preview-menu
      tests expand `hotstrings_preview_frame`; the Linux id-less header test checks every menu keeps headers at
      its top level, like the macOS one. Each was proved by a source mutation that made it fail. Reviewed and
      kept: frozen historical references (the 101 distance rules, the 140 common autocorrections), corpus floors
      (`tests/e2e/contract.lua`) and non-vacuity floors (`>= 10`, `> 400`). Later the same day the six row
      counts left beside a declaration read it: the Windows delays frame and per-file controls from the shipped
      manifest, the gesture list from its declared status templates, the profile frame corpus without its native
      rows, the LLM source mutations from the canonical inventory, and the macOS preview menu from the shipped
      `preview_presence_controls`. Each was proved by a source mutation that made it fail. Kept: the handwritten
      canonical LLM rows, the oracle the manifest is compared with.
- [ ] **The target's own paste can still lose to Windows' clipboard readers.** Done 2026-11-22: the paste
      transport's leases (`CB_IsBusy`, the plain CAS and its authentication, the restore retry) outwait a reader
      of another process for `CB_PASTE_READER_WAIT_MS` (100 ms) instead of refusing on the first try, a refused
      SendInstant publication is logged with the holder, and the payload carries the clipboard-history and cloud
      exclusion formats, so expansions no longer land in Win+V
      (`test_clipboard_reader_wait.ahk`, a known reader process, red on the old code). Left: the application's
      own single `OpenClipboard` after Ctrl+V. explorer.exe and msrdc.exe (WSLg) still open the clipboard after
      writes, with or without the exclusion formats, and msrdc renders every delayed text format, so neither the
      formats nor a delayed-rendering receipt can prove the paste (a single open 0-140 ms after a write failed
      about 1 time in 60-120). The `gesture-transform-native-render-focus` and `wrap-native-render-focus` current
      modes still fail that way now and then (sends=1, Edit empty), at the old head too. The TextSend payload
      (`CB_WriteTextWithReceipt`, LLM and diagnostics) is still published through `A_Clipboard`, without the
      exclusion formats. macOS and Linux have no clipboard lock (NSPasteboard and X11/Wayland selections serve
      each reader separately), so the race does not exist there; their transient hints
      (`org.nspasteboard.TransientType`, `x-kde-passwordManagerHint`) are not set yet.
      Count ratchets now compare named ledgers (a new item and a fixed entry both fail: `tools/test/lib/known-debt.cjs`
      and the per-file OS-purity ledgers of both drivers) and the TOML cost tests compare two input sizes. What is
      left needs a measurement or a design first.
  - `unit/ai/api/test_post_save_owner.ahk` still caps one API save at 400 registry deep compares for the owners
    its `_WAPO_GUARD_COMPARE_OWNERS` table does not name yet. Since 2026-11-24 the two anonymous transition guards
    (104 of the 152 compares measured 2026-11-22) are bounded by their traced unit instead,
    `ConfigTransitionGuardCompareBudget`: two per guard at its admission and first unproven check, two per guard
    and durable effect, none per journal read. Left: `check_write:ConfigMigrateBoot<ConfigSchemaCanPrepareWrite`
    (29, one per write-entry admission, `_ConfigSchemaEntryAdmitted` and `ConfigFullStateCanPersist`) and about 19
    other compares; read them from the `# api-save registry compares` lines of a Windows run, give each a unit
    counted apart from the reads, then drop the ceiling.
  - `test-driver-tree-parity.cjs` (shared 66, union 87, tests 18/75, canonical 9) and
    `test-port-vector-traceability.cjs` (73) are floors and ceilings that the structure phase 2 runner rewrites with
    `--update-baseline --allow-rise`; listing the directories instead means changing that runner with them.
  - The two Studio speed bounds (120 and 5000 table walks) rest on ratios measured with every core busy; read the
    ratio each test prints on a quiet PC and on CI, and set each bound to twice the highest.
  - Kept on purpose: order-of-magnitude bounds that state their reason (the Linux e2e 3000 tray rows against the
    former 103 058), loop-progress bounds a test chooses for its own loop, frozen historical references, corpus
    floors and non-vacuity floors.
- [ ] **SendInstant paste races Windows' own clipboard readers.** Rerun on a quiet PC on 2026-11-18 (no resident
      driver, 3 runs per group): healthcheck, Ollama native, `groups247-*`, pickers, `idle-caret-context`,
      `key-state-dllcall-uncaught`, `tap-keys-kana-native`, the `config-*` groups and the model browser stayed
      green; the app picker refusal failed once among neighbours (BM_CLICK, now exclusive). Two clipboard fixtures
      still failed once each, alone in the exclusive phase: `gesture-transform-native-render-focus` current
      (sends=0) and `sendinstant-native-snapshot-copy` current. On this PC (clipboard history on) explorer.exe and
      `cbdhsvc` open the clipboard after every write (probe: 40 writes, 492 foreign lock samples from the two).
      The gesture child alone failed 13 of 40 runs: twice `CB_IsBusy` saw explorer.exe and SendInstant took the
      clipboard-free path; three times SendInstant returned with no paste and no log, which an instrumented loop
      put at `CB_WritePlainSnapshot` (its single-shot CAS and `_CB_PlainAuthenticate` both refuse any open
      lease); seven times Ctrl+V was sent but the Edit never pasted (explorer.exe held the lock just after the
      paste in 4 of the 6 instrumented cases); once the capture timed out. The production paste can lose an expansion the same way. Decide whether publication
      waits for readers (bounded, like `CB_OpenClipboardWithin`) before authenticating and pasting, then make the
      fixtures hold a known reader instead of depending on the desktop's.

## Full accessibility (maintainer request, 2026-11-16, very important)

The goal is a totally accessible project: the site (ergopti.fr), Ergopti Studio (editor, Comparer, Optimiser,
benchmarks) on the site and inside the app, and Ergopti+ itself (menus, windows, dialogs, tooltips, onboarding) on
Windows, macOS and Linux. Target WCAG 2.2 level AAA everywhere (maintainer, 2026-11-23: the latest WCAG, AAA on the
site, Ergopti+ and every app window); every new page or window is held to it from now on.

- [ ] **[CODE] AAA findings down to zero (maintainer, 2026-11-23).** axe-core's AAA rules (`wcag2aaa`,
      `wcag21aaa`, `wcag22aaa`, one list in `tools/test/lib/wcag-tags.cjs`) run in the site, Studio and app-window
      gates: any new finding fails CI. The shared text tokens of `theme.css` now hold 7:1 in both themes
      (`test-app-colour-contrast.cjs`, section 7); what is left is recorded in the baselines, all
      `color-contrast-enhanced`: 4 site nodes (the changelog frame) and 402 app-window nodes, colours a page spells
      itself (the changelog's dark palette, the download window, the metrics dashboards' tints, the editors' chips,
      the paths, token and physical-shortcut editors). Left: lower both baselines to zero; a check that measures the 44 px of 2.5.5 (axe's
      `target-size` stops at the AA 24 px); the public statement `/accessibilite` still names AA as the target
      (French text, `i18n` skill). The tool survey and every AAA criterion no tool measures, with its check, are in
      [aaa-criteria.md](docs/audits/accessibility/aaa-criteria.md); those checks belong to the manual audit below.

The site and the Studio pages are scanned by axe-core in CI (tools/test/browser/site-accessibility.playwright.cjs,
ratchet baseline beside it, findings in [docs/audits/accessibility/](docs/audits/accessibility/README.md)); lower the
baseline as violations go.

- [ ] **Manual audit.** A checklist per page and per native window (keyboard walk, NVDA, JAWS, Narrator, VoiceOver,
      Orca, 400 % zoom and 320 px reflow), recorded in docs/audits/accessibility/. The axe scan covers the app's own
      WebView windows since the fifth pass (21 windows, `npm run test:browser:app-accessibility`, fake host and
      fixture data); the layout manager's contrast nodes are gone too (0 in both schemes, 2026-11-24).
- [ ] **Colour vision.** The onboarding, download window and hotstring palette review is done (fourth pass,
      [audit](docs/audits/accessibility/README.md#colour-vision-review)). The preview rows now carry a glyph per
      category beside the trigger label on the three drivers (✓ autocorrection, ✦ magic key, ✎ personal, • other;
      the maintainer's decision of 2026-11-19 in docs/memory/maintainer-decisions.md), read by the screen-reader
      notice and hidden by `hotstrings.preview_category_glyphs`. Left: a look at the glyph in a real bubble on
      each OS (the unit tests check the drawn label's text and font, not its pixels).
- [ ] **Dyslexia and reading, what is left.** Every site page and every Studio frame it holds (the Comparer, the
      editor, the Optimiser, the model browser and the release notes) is measured at 200 % zoom with the WCAG 1.4.12
      spacing and at the site's 200 % text with wide spacing (`tools/test/browser/site-reading.cjs`, in the site
      accessibility gate, ratchet `site-reading-baseline.json` per page, mode, frame and check, empty): no clipped,
      overlapping or justified text, no prose line over 80 characters, nothing slid under the sticky header, no
      sideways scroll on a 320 or 375 px phone, and no sentence of 30 words or more in a page's running text
      (`long-sentence`, WCAG 3.1.5; the 64 left on the other pages were cut)
      ([eleventh pass](docs/audits/accessibility/README.md#eleventh-pass-reading-in-the-frames-plain-language-and-help-text-2026-11-20-paris-time)).
      The app's windows take the reader's font and spacing from the Configuration menu on the three OS
      (`script.reading_font`, `script.reading_spacing`): Windows seeds them beside each locale seed and loads the
      font from `_shared/ui/fonts/`, macOS and Linux inline it (`_shared/core/ui/engine/webview/reading_preferences.lua`);
      proof `test-reading-preferences-seed.cjs`, `reading_preferences_contract.lua` on both Lua runners and
      `test_reading_preferences.ahk`. Field report of 2026-11-24 (macOS, dev.178): with OpenDyslexic every window
      read « M é t r i q u e s » and the metrics toolbar wrapped, and a change reached only the windows opened after
      it. The OpenDyslexic faces carry side bearings and a space far wider than the system font's: theme.css and the
      site's accessibility.css now give back the page's spacing with « Par défaut » and add the WCAG 1.4.12
      increments on top of it with « Aéré » (now labelled « Aéré (lignes, lettres et mots plus espacés) » in the 21
      locales, paragraph spacing 2 em included); a saved choice is pushed into every open window on the three OS
      (`a11y_prefs.js` `receiveHost`: macOS `builder.push_reading_preferences`, Linux
      `webview_manager.push_reading_preferences`, Windows `ReadingPrefs_Track` and `ReadingPrefs_PushToOpen`); the
      setup wizard offers both lists above the languages from its first screen and saves through the menu's writer.
      Proof `tools/test/browser/app-windows-reading.playwright.cjs` (computed font, spacing, toolbar rows, live push
      and the wizard, as the Windows and the inline hosts deliver them). The native menus keep the system font on
      the three OS, which the menu label « Police des fenêtres » states: Windows tray menus would need owner-drawn
      rows (AutoHotkey's Menu draws them itself), the Linux tray is drawn by the desktop shell from dbusmenu, which
      carries no font, and macOS `hs.menubar` takes styled titles only in a font the process can resolve, which
      Hammerspoon cannot register from a bundled file, and a styled title loses the disabled grey. Left: a look at
      the dyslexia font in a real window on each OS (TODO-tests); the plain-language review of the Studio's own
      strings (the 21 locales' catalogue, not measured).
- [ ] **Blind and low-vision users.** The Optimiser's result boards have a table view of their own (each key's
      place, what it types on both layouts, whether it changed). Heading order and landmarks are a gate
      (`tools/test/lib/heading-landmarks.cjs`: one h1, no skipped level, one main, every other landmark named): the
      three Studio pages in the Studio keyboard walk, which they pass, and the 21 app windows in their scan's
      ratchet, which they all pass since the apps dashboard's tabs became tab panels with their own headings
      ([tenth pass](docs/audits/accessibility/README.md#tenth-pass-semantic-markup-and-keyboard-operability-of-the-app-windows-2026-11-19-paris-time)).
      Left: screen-reader runs.
- [ ] **Semantic markup and mouse-only controls.** The site's div and span are held by
      `npm run test:site-semantic-html` (576 → 451, each justified in `tools/test/site-semantic-html-allowlist.json`)
      and its images by `npm run test:site-image-alternatives`; every site page is checked for controls only a
      mouse can use by `tools/test/browser/keyboard-operability.playwright.cjs` in CI
      ([ninth pass](docs/audits/accessibility/README.md#ninth-pass-semantic-markup-keyboard-operability-and-reading-choices-2026-11-19-paris-time)).
      The app windows' div and span are held by `npm run test:app-windows-semantic-markup` (1162 → 276, each
      justified in `tools/test/app-windows-semantic-markup/`) and their mouse-only controls by the app windows scan
      ([tenth pass](docs/audits/accessibility/README.md#tenth-pass-semantic-markup-and-keyboard-operability-of-the-app-windows-2026-11-19-paris-time)).
      The Studio pages' div and span are held by `npm run test:studio-semantic-html` (143, each justified in
      `tools/test/studio-semantic-html-allowlist.json`, none interactive). Since 2026-11-22 the site gate also
      counts made-up elements (a custom element name or one HTML does not define, as generic as a div): the 92
      `<kbd-output>` became `<samp class="kbd-output">` and the 4 `<image-block>` a `<figure>`; on 2026-11-24
      the 42 empty spacers became margins of their neighbours (`.space-before-tiny`…), the page blocks
      `section`s (`bloc-introduction`, `bloc-fin`) or layout divs (`#page`, `.bloc-main`) and the reference
      keyboard an `aside`, and the 34 left are justified in the same list. Left: those 34 — the keyboard
      drawings' `keyboard`, `keyboard-row`, `keyboard-key` and `keyboard-legend` (their CSS and scripts select
      them by name), the controls' wrappers, the brand names and the drawn `nbsp`.
- [ ] **Keyboard and motor.** The Studio keyboard walk is a CI gate (`npm run test:browser:studio-keyboard`, the
      editor's « Try » field trap fixed) and the Studio has no time limit. The Windows driver's native windows
      (14 of them: settings prompts, pickers, editors, the hotstring settings, paths and update fallbacks) are walked
      with Tab and Shift+Tab in the AHK suite (`test_native_keyboard_walk.ahk`); none traps the keyboard. The app's
      21 WebView windows are walked the same way, each stop with a visible focus indicator, in the same gate as
      their scan (fifth pass), and since the tenth pass that scan also blocks an element a mouse can click or hover
      that the keyboard cannot reach, arrow keys that do nothing in a tab list, list box or menu, and a modal that
      Escape leaves open; the hotstring editor's sections move with the arrow keys and the metrics tooltips open on
      focus. Since 2026-11-22 the Studio keyboard walk refuses hover-only content too (an element with a hover
      listener that the keyboard cannot reach or that does not follow the focus, a drawing's values in hover
      titles only; the app windows' check, proved first on a small page): every Studio page and tab passes.
      Since 2026-11-24 the typing heatmaps' keys take the focus (one Tab stop per drawing, the arrow keys
      between keys, the popup beside the focused key, Escape hides it) and the scan reads hover handlers written
      in markup too, and the apps table's column explanations are listed under it (« What the columns mean »),
      each header described by its entry. Left: the macOS and Linux native windows.
- [ ] **Cognitive.** Consistent navigation; every metric and setting has its help text. Error messages: the
      about 60 shown on Windows or in the shared pages without a next step now say one, 63 of them pinned by
      `tools/test/test-error-messages-say-how-to-recover.cjs`
      ([audit](docs/audits/accessibility/README.md#error-messages-wcag-333)); the `layout_editor.error.*` codes
      are done too: 8 more end with their step and the 32 others are classified, each with its reason, so a new
      code fails the test until it has one or the other. Every card of the typing dashboard says what it counts
      behind its « i » (the AI and hotstring cards had `title` attributes only;
      `npm run test:metrics-cards-explained`), and the Studio's 37 metrics all have their definition. Left: the
      tray settings, whose rows carry no help line of their own, were not reviewed for one.
- [ ] **Ergopti+ native UI, what is left.** The clear fixes of the code audit
      ([table](docs/audits/accessibility/README.md#native-ergopti-ui-code-audit-2026-11-17)) are in on the three OS
      (tray / menu-bar names with the pause, labels and named controls, tooltips under high contrast, previews told
      to a running screen reader); on Windows the native windows' fonts follow the text size, and the WPM widget
      and the Spotlight overlay reach a running screen reader (fourth pass); on macOS and Linux the WPM widgets,
      the spotlight overlay and the `hs.alert` banners reach a running screen reader, and the Linux previews
      follow the GNOME text scale (fifth pass). Left: the Swift update panel's XCTest, not yet run in CI: it is
      in the full `swift test` of the macOS Build stage's launcher-native cell, which the dev runs since 2026-11-17
      skipped because earlier macOS unit stages failed (run 44753533322: menu_input, ui and modules). The spoken
      results are the « Accessibility » items of the three TODO-tests files.

## Ergopti Studio

Design: [layout-editor.md](docs/design/layout-editor.md), [layout-analysis.md](docs/design/layout-analysis.md),
[analyser-scores.md](docs/design/analyser-scores.md), [layout-optimizer.md](docs/design/layout-optimizer.md); the
analyser study is [docs/audits/layout-analysers/report.md](docs/audits/layout-analysers/report.md) (its section 15
waits for the maintainer's review).

- [ ] **Layout formats, what is left (2026-11-19).** The ErgoDox model is complete (maintainer, « Complete the
      model »): 73 of the 91 files left out for its keys came in, the library holds 783 layouts
      (`docs/audits/layout-analysers/report.md` section 13, « Every ErgoDox key »). To review by the maintainer: the
      board-only codes, the Shift keys read as QMK's mod-tap and the thumb rule (the ErgoDox's extra left thumb keys are idle since
      2026-11-21) (`docs/design/layout-analysis.md`,
      « ErgoDox keys »). Still in `not_imported`: KLA's four standard-board files need Tab, Caps Lock, Enter or a
      bottom modifier as character keys on ISO and ANSI (TypeMatrix's q and a, the ANSI BvoFRak's q, Arensito's à,
      AOEYK's \), which would also offer them to the optimizer; KLAnext's Einbinder Orthogonal, VCKB, VCKB2 and Yp Hina
      Fu put a letter on the ErgoDox's left 2-unit outer thumb key, where the board keeps Space (a code of its own
      there would draw two keys at one place: the Comparer's and the Optimiser's boards draw every non-modifier
      code); Hands Down Neu's four janiso files keep the backquote and « ~ » on a key KLAnext's QWERTY leaves without
      a character.
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
- [ ] **« Ma frappe » saved read on macOS and Linux, field check (2026-11-21).** macOS and Linux now save each
      complete Studio read beside their store, in the Windows format (`_shared/metrics/data/studio_ngrams.json`,
      `snapshot`; vectors in `_shared/tests/corpus/metrics/studio_ngrams_snapshot_vectors.json`), show it at once and
      read the store on the next turn; the purge and the dashboard reset remove it. Left: the first open after a
      restart still reads the whole store on the main thread (the same SQL took 0.75 s warm and 4.5 s with a cold
      page cache on the maintainer's 1.1 GB image), now after the saved read is shown. Measure it on a large macOS
      store and on Linux (the « Ma frappe » at once checks of TODO-tests-macos.md and TODO-tests-linux.md) before
      moving the read off the main thread.
- [ ] **« Ma frappe » fresh read on Windows (2026-11-18).** The Studio now shows the saved read at once (its marker
      keys made every tab refuse it before) and its SQL projection takes 1.7 s instead of 3.8 s on the maintainer's
      1.1 GB reader image, and the read reaches the window as soon as the worker writes its stage, before the
      image save (`KLPF_PollStudioStage`). Measured in the store's own `prefetch.log` (8 Studio reads, 2026-11-17
      to 19): the save took 5.7 to 26 s (16 s in the 45 s read of 2026-11-18 20:00), now off the wait. Since
      2026-11-20 the catch-up no longer copies the image: a worker writes through a copy-on-write overlay of the
      shared file (`SQLite_OpenCopyOnWrite`), and replays only the app-days the tail changed, a whole day only when
      it touches `events_system` (`KLR_ReplayScopeBegin`). Measured on a synthetic 1.1 GB image of 595 days with
      a 53 KB tail of one app on a heavy day (3 runs, a loaded machine): the copy took 20 to 29 s, the overlay 9 to
      14 ms; the replay took 65 to 98 s for 167 rows, 30 to 35 s for that app's 75; the catch-up 94 to 140 s, now
      34 to 40 s. Left: the replay of each touched app-day, still whole (`docs/memory/windows-ahk.md`, « A refresh
      clears and replays whole affected app-days », says why less is not exact). Read the next Studio reads in the
      store's `prefetch.log` to confirm the gain on the real store.
- [ ] **Library layouts that lose their own characters, what is left (2026-11-22).** BEO is still Oxeylyzer's
      letter block, without è ê ç ù (0.99 % of Swann unsupported, with ; and ?): its `beo.dof` is the only file
      found (Oxeylyzer's forks copy it; no author page, no cmini or oxeylyzer-2 entry). Re-encode it once a fuller
      source appears, then empty `KNOWN_GAPS` of `test-layout-analysis-engine.cjs` (« library-block-own-letters »),
      which checks that every letter block types its language's letters (`docs/audits/layout-analysers/report.md`,
      « Layout library »). Not a loss: Russian JCUKEN's 80 % unsupported on a French text.
- [ ] **Neo-family levels on the installed and emulated layouts, what is left (2026-11-20).** The Comparer's boards
      show every level (« Level shown »), the exports name what they leave out, and the editor keeps the seven
      levels through save and reload: Mod3 and Mod4 are held custom modifiers of the source, on Caps Lock and the
      ISO key left of Enter, the key right of left Shift and AltGr (`docs/design/layout-analysis.md`, « Layout file
      formats »; `tools/test/test-layout-editor-levels.cjs`). Since 2026-11-20 the drivers' emulation holds them
      on Caps Lock and AltGr too, Caps Lock never toggling and AltGr selecting no system level (Windows: suppressed
      SC03A and SC138, AltGr's fake LCtrl ignored; Linux: the hook's `onHeldModifierKey` keeps the grabbed key from
      XKB; macOS: right Option's flagsChanged edges deleted and its Option flag cleared), and types the dead keys of
      an emulated level, composing with the native base and Shift levels (`neo2_vectors.json`, replayed by the web,
      Lua and AutoHotkey engines). macOS cannot hold Mod3 on Caps Lock, which an event tap never sees held
      (`platform_reason.caps_lock_level_not_held_on_macos`): only a generated Karabiner rule could, still to do.
      Left, the native files: no `.keylayout` holds a custom modifier (macOS relies on the emulation); XKB holds
      Mod3 on Caps Lock as its fifth level and lists Mod4 (`custom_modifier_not_in_xkb`); the Neo XKB and KLC
      exports are refused for reasons older than the levels (`unbound_stateful_actions`, Caps Lock on the Roya or
      AltGr columns), as is the DLL package (`kbd_unit_invalid` on a dead-key result). Not checked on real
      hardware: a user tap-hold or remap on Caps Lock or AltGr may still take the key before the emulation (the
      Linux tap-hold engine runs first, an AHK static label is created first).
- [ ] **[RELEASE] Windows export step in native Lua.** The restricted host `windows/native/ergopti_lua_export.c`
      (pinned Lua 5.4.6, built by `tools/build/build_windows_lua_export.ps1` in package-windows) is done. Left: once a
      dev run builds « Windows / Build », commit its artifact `windows-lua-export-*` (`ergopti_lua_export.exe` and
      its `.json`) into `windows/vendor` with their `required` entries in `tools/build/windows_bundle_manifest.json`;
      then `test-windows-lua-export-identity.cjs` checks them and the Windows lane runs the byte-equality proof.

- [ ] **Other analysers, what is left (2026-11-24).** Every text corpus now carries genkey's skipgrams of gaps 1 to
      9 and Oxeylyzer's token pairs of gaps 1 to 3 with its exact totals, counted from its text
      (`LAYOUT_ANALYSER_SCORES.textTables`, `analysers` of each `_generated/corpus_<id>.js`, 1.43 MB for the 31 text
      corpora; docs/design/analyser-scores.md, « API »). Left: rerun `verify-analyser-scores.cjs` with `--genkey`
      and `--oxeylyzer` on a machine that may run the two tools (this cloud session could build genkey but not run
      it) and set their fidelity to `exact` on texts if the gaps are gone; the word lists and the 12 count-table
      corpora keep the trigrams' chain (no text to count from). keycraft (BSD-3, Go, its score scaled on its own
      layout set) needs its own run to be checked; shirolyzer's score is undocumented.

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

- [ ] **[CODE] Layout capabilities left open (maintainer request 2026-11-19, « installer, retirer, émuler, petits
      changements sur les 3 OS »).** The audit and its matrix are in
      [platform-parity-audit.md](docs/platform-parity-audit.md#layout-capabilities--november-19-2026); every gap it
      listed is fixed (LCP-05 to LCP-08) and `test-layout-capability-contract.cjs` pins each path. LCP-09 (2026-11-22):
      Hyprland now installs, switches and takes the number-row options live through `hyprctl keyword` with a read-back,
      selected again at the next session; Sway, niri and river are refused with a named reason
      (`layout_manager.failure_session_unsupported`; Sway reports no layout ids, so a refused layout could not be put
      back); a Hyprland configuration reload selects the recorded layout again (`configreloaded` on the event
      socket, `hyprland_reload_watch.lua`). Left, real machine
      only: the steps of TODO-tests-windows.md (remove a Studio DLL from the layout manager, re-save a source under
      another `dll_name`) and TODO-tests-linux.md (an X11 layout loaded again after a new session, the Hyprland
      selection). Decided with the
      recommended option: under an emulated layout of another family, the accented keys keep that layout's Command
      level on Windows and Linux; macOS draws no letter picker and says so in its reason.

- [ ] **[CODE] Parity audit continuation.** Take one bounded module at a time across Windows, macOS, Linux and shared;
      do not restart a finished campaign without source drift or a new hypothesis. The
      [2026-11-19 census](docs/audits/platform-parity/2026-11-19-census/report.md) (`b90ad8de`, S26 included: 190
      areas, 108 drifted, 69 never campaigned; 316 units, 99 never campaigned) ranks what is left and proposes the
      order. Its first campaign, secure-field detection, fixed SFC-01, SFC-02 (macOS `refresh()` fails closed), SFC-03
      (the port spec and a fail-closed vector replayed on the three drivers) and SFC-05 (the RoboForm AHK case
      asserts the application axis). The generated
      [platform parity table](docs/platform-parity-table.md) now gives every feature, action, layer entry and menu
      row its status, owner and reasons per OS, and `test-linux-feature-parity.cjs` gates it. Its Windows and macOS
      `not_yet` reasons are closed: Ollama token streaming on Windows (streaming-parity, `test_engine_state.ahk`) and
      the macOS Shortcuts restore and clear (shortcuts-scope-macos, `test_global_scope.lua`). Left:
  - SFC-06 (Credential Manager inside `explorer.exe`, field path only; no fix possible by process name);
  - logger engines, taken on 2026-11-20 ([report](docs/audits/platform-parity/2026-11-20-logger-engines/report.md)):
    LOG-01 to LOG-05, LOG-07 and LOG-08 fixed, replayed from `_shared/tests/corpus/logger/parity_vectors.json` by
    the three suites and the macOS native worker. Left: LOG-06, pair the 15 Lua files the report lists (among them
    `text_cipher.lua` on both drivers and macOS `phase_stats.lua`), then gate Lua pairing like
    `test_pairing.ahk`; the boot profilers, perf counters and keystroke integrity still need their own reading;
    the Swift retention replay runs in macOS CI only;
  - managed Ollama runtime, taken on 2026-11-20
    ([report](docs/audits/platform-parity/2026-11-20-managed-ollama/report.md)): OLL-01 (Linux pulls a
    digest-mismatched model once more, classes in `_shared/ai/data/ollama_pull_errors.json`, vectors replayed by the
    Windows and Linux suites), OLL-02 (`[llm] ollama_model_pull_timeout_ms` bounds a Windows pull instead of the
    30 min install budget) and OLL-03 (stale owners) fixed. Left: OLL-04 free-space check on macOS and Linux and an
    `ollama.no_space` message; OLL-05 the install's network and checksum classes (macOS markers never printed);
    OLL-06 one readiness bound once the cold start is measured (field checks); OLL-07 old runtime versions left on
    Windows and Linux; OLL-08 Linux reuse without a re-hash; OLL-09 macOS model delete through `ollama rm`; OLL-12
    the unused `ollama-release.sh`; OLL-13 Linux readiness without listener ownership or the pinned version;
  - tray adapters, taken on 2026-11-20 ([report](docs/audits/platform-parity/2026-11-20-tray-adapters/report.md)):
    TRAY-01 fixed (the Windows cold tray showed French startup rows to every user and an icon named by its file name
    until `I18nInit`; it now appears in the configured locale, named, and a first run in the wizard's language).
    Left: TRAY-03 a Linux desktop without a StatusNotifier host shows no icon and tells nothing (read the watcher, say so
    in the user's language); TRAY-04 rewrite `TrayMenu.spec.js` on the two real icon states and the option map, with
    vectors that can fail; TRAY-05 log a missing tray icon file on the three instead of drawing another;
  - update and download windows, taken on 2026-11-21
    ([report](docs/audits/platform-parity/2026-11-21-update-windows/report.md)): UPD-01 (a refused Windows digest
    named as a failed download), UPD-02 (a cancelled Linux update read « Ollama download cancelled »), UPD-03
    (Escape closes the Updates window on the three) and UPD-04 (its answer is announced) fixed, then UPD-05 to
    UPD-12 in the follow-up: closing an update's window no longer stops it on the three (agent decision, to review by
    the maintainer, in `docs/memory/maintainer-decisions.md`), a failed check names its rate limit or proven network
    cause, Windows and Linux show the download's progress with a Cancel, Linux keeps « Update now » and announces a
    restart only once armed, a refused signature is named everywhere, the macOS Versions install keeps its failure
    receipt and removes its stage, and the download page has no English fallback. Left: UPD-13 macOS names no proxy,
    offline or certificate cause (hs.http proves none; route the check through the launcher's managed HTTP worker);
  - metrics views, taken on 2026-11-21 ([report](docs/audits/platform-parity/2026-11-21-metrics-views/report.md)):
    MET-01 to MET-12 fixed (Windows WPM idle reset, AI output privacy, warm hosts after a reading change and the
    names of every WPM surface; Linux apps read state and range failure, heatmap names from the active layout and
    live n-gram tables; macOS missing and incomplete stores shown with their notice; the range status, numbers and
    metric definitions in the interface language on the three, the hard-coded-strings gate now scanning the
    pages' HTML). Left: MET-13 « Computing… » forever on an empty range; MET-14 the apps render-error alert; MET-15
    banners after a late locale; MET-16 calendar day values and the chart reading font; MET-17 net or gross hotstring
    counting in the live speed (maintainer decision);
    MET-18 the Windows pill's second keystroke; MET-19 a failed dashboard reset told to the page;
    MET-01 to MET-08 fixed (Windows WPM idle reset, AI output privacy, warm hosts after a reading change and the
    names of every WPM surface; Linux apps read state and range failure; the range status and numbers in the
    interface language on the three), then MET-13 to MET-16, MET-18 and MET-19 (the empty state of an empty range,
    the apps render alert cleared, the banners reworded when the locale lands, every value of the SVG drawings in a
    keyboard disclosure with the app windows scan counting a drawing without one, the Windows pill from the first
    key, a failed Reset told to the page on the three). Left: MET-09 Linux heatmap key names from the live XKB
    keymap; MET-10 Linux n-gram tables refresh while focused; MET-11 macOS empty and incomplete states published as
    the others do; MET-12 the 61 French `title` definitions and the French chart tooltip labels (« Précision »,
    « Acceptées ») to i18n keys, with the hard-coded-strings gate extended to the pages' HTML; the Chart.js reading
    font (rest of MET-16); MET-17 net or gross hotstring counting in the live speed (maintainer decision); the
    cosmetic Linux range reply `driver_meta` (rest of MET-19);
    interface language on the three). Left: MET-09 Linux heatmap key names from the live XKB keymap; MET-10 Linux
    n-gram tables refresh while focused; MET-11 macOS empty and incomplete states published as the others do;
    MET-12 the 61 French `title` definitions and the French chart tooltip labels (« Précision », « Acceptées ») to
    i18n keys, with the hard-coded-strings gate extended to the pages' HTML; MET-13 « Computing… » forever on an
    empty range; MET-14 the apps render-error alert; MET-15 banners after a late locale; MET-16 calendar day values
    (the chart reading font and spacing fixed); MET-17 net or gross hotstring counting in the live speed
    (maintainer decision); MET-18 the Windows pill's second keystroke; MET-19 a failed dashboard reset told to the
    page (the Linux range reply's `driver_meta` fixed);
  - timing engines, taken on 2026-11-22 (census units `macos/core/timing` and `linux/core/timing`, with the Windows
    reader, the `[budgets]` judges and the reload measures; tap-hold and key-combination timings left out): TIM-01
    (a Windows reload is now logged « Reload completed in N ms » and judged against `[budgets] driver_reload_ms`,
    the launch tick handed to the successor through its environment, `core/timing/engine/reload_timing.ahk`) and
    TIM-02 (`TimingsGet` admits only a TOML integer and `TimingsGetNumber` only a TOML number, as the Lua reader
    refuses a quoted value; English errors; the liveness gate refuses a non-integer key a Windows `TimingsGet`
    reads) fixed. The macOS `deferred_work`, `paced_job` and `paced_json` and the Linux `native_sleep` and
    `native_timer` are OS-specific by their reason. Then fixed: TIM-03 (the Linux Ollama chat is judged against
    `llm_local_request_ms`, dispatch to terminal marker), TIM-04 (Windows and Linux judge the first prediction
    display against `prediction_display_ms`, once per chain; Linux `ai/engine/prediction/display_budget.lua`) and
    TIM-05 (the Windows developer field run has a `driver_reload` step: resume file, reload owner, the successor
    records the measured reload and runs the next step; the collector follows the successor). Decided by the
    maintainer on 2026-11-22 (`docs/memory/maintainer-decisions.md`): TIM-Q1 option 1, implemented (the Lua `ms`
    and `sec` refuse a fraction, the liveness gate checks every key but `*_mm` and `*_factor`; no shipped value
    changed), and TIM-Q2 option 1, documented. The questions as asked:
    - TIM-Q1, a fractional duration: the Lua `ms` and `sec` accept 1.5 for a `*_ms` key, Windows now refuses it
      and the gate refuses it only for the keys Windows reads. 1. **(recommended)** Integer milliseconds for every
      duration key on the three: the gate checks every key that is not `*_mm` or `*_factor`, and the Lua `ms`
      refuses a non-integer. 2. Keep fractional durations legal on macOS and Linux.
    - TIM-Q2, where a reload starts: macOS counts from `hs.reload()`, Linux from its stamp after the cleanup-debt
      checks, Windows from the successor launch (after the configuration lease, so a reload queued behind a
      configuration write is not counted while it waits). 1. **(recommended)** Keep the three: each starts once
      the reload is admitted, as the budget's teardown-plus-boot measure assumes. 2. Count from the user's
      request, waits included, on the three.
  - the next campaigns in the report's order: pickers and prompts, small native units, layout tool pages.
    and the chart reading font; MET-17 net or gross hotstring counting in the live speed (maintainer decision);
    MET-18 the Windows pill's second keystroke; MET-19 a failed dashboard reset told to the page;
  - layout tool pages, taken on 2026-11-21
    ([report](docs/audits/platform-parity/2026-11-19-census/report.md#ninth-campaign-layout-tool-pages)): LTP-01 to
    LTP-07 fixed (the Windows layout manager seeds the language and reading choices; Ergopti Studio answers its page
    while paused on Windows through `WebViewHost` `RunsWhilePaused`; a Studio change refused during a Windows layout
    reload is answered `busy`; six host refusals worded in the 21 locales; on the three, both pages name the
    interface language, the layout manager keeps the focus on the row acted on and closes on Escape); desktop checks
    are field points. LTP-09 and LTP-10 fixed afterwards: the Windows personal information editor, paths editor and
    onboarding wizard seed the language and reading choices (`UNSEEDED_WINDOWS` is empty), and the physical shortcuts
    editor and the configuration cleanup answer their page while paused, every `WebViewHost` window placed by
    `test-webview-host-pause-census.cjs`. Left: LTP-08 `dir` on both pages (to PCK-22);
  - the next campaigns in the report's order: pickers and prompts, small native units.
  - small native units, taken on 2026-11-21
    ([report](docs/audits/platform-parity/2026-11-21-small-native-units/report.md)): SNU-01 to SNU-09, SNU-11 and
    SNU-13 to SNU-15 fixed (the Windows keep-awake reads the shared timings, credits its session to `awake_ms`,
    also at an accepted exit, and logs it; macOS credits a session the pause or a quit ends; the jitter radius and
    the Linux inhibitor's poll and ready bound are `[keep_awake]` registry entries; the Karabiner update and
    old-rules dialogs say their cause in the user's language and the old-rules report logs a dialog that raises;
    the Windows export host answers the shared refusal code; the Linux note logs its refusals and its Windows-only
    settings say where the Linux note goes). Left: SNU-10 the shipped `D:\Bureau` default note folder on Windows
    (maintainer decision); SNU-12 how each driver tells the end of a session (maintainer decision); the Linux
    note's folder and dated choice (`not_yet`);
  - the next campaigns in the report's order: pickers and prompts, layout tool pages.
    and the chart reading font; MET-18 the Windows pill's second keystroke; MET-19 a failed dashboard reset told to the page;
  - the next campaigns in the report's order: pickers and prompts, small native units, layout tool pages.
    receipt and removes its stage, and the download page has no English fallback. UPD-13 fixed afterwards: the
    macOS manual check runs through the launcher's native HTTP worker and names the offline, certificate or proxy
    cause its closed reason proves (field check in `TODO-tests-macos.md`, Swift unchanged);
  - the next campaigns in the report's order: pickers and prompts, metrics views, small native units, layout tool
    (Escape closes the Updates window on the three) and UPD-04 (its answer is announced) fixed. Left: UPD-05 closing
    the Linux download window refuses the downloaded update's install (decide cancel or install); UPD-06 carry the
    fetch receipt into the Lua update check so macOS and Linux name the proxy, offline or certificate cause as
    Windows does; UPD-07 update download progress on Windows and Linux (and a Windows cancel); UPD-08 a failed Linux
    update download drops the menu's offer; UPD-09 Linux says « restarting » before trying; UPD-10 a refused
    signature named on the three; UPD-11 the macOS Versions install passes no failure receipt and leaves its stage
    folder; UPD-12 the download page's English fallbacks and fixed `lang`;
  - pickers and prompts, taken on 2026-11-21
    ([report](docs/audits/platform-parity/2026-11-21-pickers-prompts/report.md)): PCK-01 (macOS key prompts masked),
    PCK-02 (macOS keys untrimmed), PCK-03, PCK-04 and PCK-14 (the shared entry grammar read by the macOS and Linux
    numeric prompts, vectors replayed through both), PCK-05 and PCK-12 (Escape on the token and cleanup pages),
    PCK-06 (Linux picker title-bar close), PCK-07 (a confirmation without an id refused on the three), PCK-08
    (Windows application picker headers), PCK-09 (Linux open_app refusal told), PCK-10 (macOS prompt editor
    validation), PCK-11 (Windows cleanup window focused), PCK-15 (a refused Windows pick keeps the picker open),
    PCK-16 (Windows WebView windows take the keyboard on open), PCK-17 (one Windows input box at a time), PCK-18
    (the dead Linux token bridge retired), PCK-19 (Escape on the model browser and physical shortcuts), PCK-20
    (prompt editor fields saved alike, shared vectors), PCK-21 (Windows application names, no window titles) and
    PCK-22 (`dir` from the locale on every page, logical CSS) fixed, then PCK-13 (a blank numeric answer resets a
    global setting to its default and removes an override, maintainer 2026-11-21 and 2026-11-22, on the three OS);
  - the next campaigns in the report's order: metrics views, small native units, layout tool
    pages.
    until `I18nInit`; it now appears in the configured locale, named, and a first run in the wizard's language),
    TRAY-03 (a Linux desktop with no tray host is told, in the user's language, what to install), TRAY-04
    (`TrayMenu.spec.js` 2.0.0 states the real `setIcon({ image })` contract and its vectors read the result on the
    three drivers) and TRAY-05 (a missing tray icon file is logged once and drawn as a warning sign whose name says
    so, never as the other state) fixed; their desktop checks are field points;
  - the next campaigns in the report's order: update and download windows, pickers and prompts, metrics views,
    small native units, layout tool pages.
    30 min install budget), OLL-03 (stale owners), OLL-04 (one free-space rule before the download on the three, the
    pinned archive plus `[limits] ollama_install_free_space_margin_bytes`), OLL-05 (the install failure's class and
    message on the three, classes in `_shared/ai/data/ollama_install_errors.json`, vectors replayed by the three
    suites), OLL-07 (Windows and Linux remove the earlier runtime once the
    pinned one runs), OLL-08 (Linux re-hashes the tree against its seal at every start), OLL-09 (macOS bounds
    `ollama rm` by `ollama_delete_timeout_ms`), OLL-12 (`ollama-release.sh` retired with its generator) and OLL-13
    (Linux admits readiness only from its own process group's socket with the pinned version), OLL-10 (Windows and
    Linux pull a model Ollama cannot load once more, one shared rule and its vectors) and OLL-11 (the lifecycle
    actions are rows of « Ollama d’Ergopti » on the three, with an uninstall that keeps or deletes the models)
    fixed, then OLL-14 (the free-space check counts the pinned unpacked runtime, and a pull that fills the disk
    names it on the three). Left: OLL-06 one readiness bound once the cold start is measured (field checks); the
    unpacked sizes of `ollama_release.json` are provisional (three times the archive): run
    `node tools/build/pin-ollama-release.cjs --archives <folder> --write` in CI on the five pinned archives and
    commit its values, then keep its `--check` in the job that downloads them;
  - the next campaigns in the report's order: tray adapters, update and download windows, pickers and prompts,
    metrics views, small native units, layout tool pages.
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
      (`CURRENT_TEST_SHA`); moving it to the shared fixture needs that review renewed. No retry is added. Renewal
      accepted by the maintainer on 2026-11-21, pending integration: 685cec9b89 (branch
      `agent/macos-number-row-xctest-review-candidate`, review notes in its message) drops the suite's private copy of the fixture (lines 19-72: the 5 s bound, the observed-selection
      loop, `selectAndObserve`'s in-process `TISSelectInputSource`, the restoration-observed guard) for
      `KeyboardSourceSelectionFixture.withSelectedSource`, which runs the same phases (`original.capture`, `select`,
      `restore.inner`, `restore.outer`) and refusal messages; the twelve methods and every assertion stay, the causal
      `XCTAssertThrowsError` moves from line 435 to 339, and the fixture's source scan now covers this file. The
      counterfactual is still the sole `NEEDLE` omission of `NumberRowSourceProbe.swift`, so the expected red stays
      one « did not throw error » in `testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject`. Left:
      the reviewer renews the image (« Maintainer decisions pending »), then CI proves it in ci-macos.yml's
      `e2e-hs` (« E2E tests ») lots of role managed-ollama-native, step « Qualify actual selected number-row Carbon
      XCTest controls » (twelve cases, seven TIS closures restored).
- [ ] **[CI] Prove the number-row cohort's shared-fixture selection on macOS.** The XCTest process left HIToolbox's
      current layout (`AppleCurrentKeyboardLayoutInputSourceID`) on the old source 3 times in about 5,900 steps when
      it selected itself (runs 44025301586, 44029045918). Since 22e1017c6a (image accepted by the maintainer on
      2026-11-21, [decision](docs/memory/maintainer-decisions.md)) `NumberRowSourceProbeTests.swift` selects through
      `KeyboardSourceSelectionFixture` and the launcher's headless role, as `KeyboardSourceProbeTests`; no retry is
      added. Left: the first macOS CI run after the push proves it in ci-macos.yml's `e2e-hs` (« E2E tests ») lots of
      role managed-ollama-native, step « Qualify actual selected number-row Carbon XCTest controls » (twelve cases,
      seven TIS closures restored); close this item on that green run.

## Carried over from the 1.0.9 requests

- [ ] **Slowness, Windows boot.** Left, largest first, process CPU measured 17 November on the maintainer's
      configuration (`tools/dev/bench-ahk-startup.cjs` smoke boots with one warm-up boot, loaded PC, median of 5
      interleaved boots, summed CPU about 7.6 s): script parse before the first line, 2.0-2.2 s (`/validate` alone
      takes as much; it follows code volume, full-line comments are only about 200 ms of it, so only a smaller
      include graph or a worker helps); hotstring registration 1.2 s, needed at the first key (the registrars cost
      about 0.5 ms per cached row with its case variants, the `generated_hotstrings.tsv` admission about 110 ms);
      layout and remaps 1.0 s (a disk cache is rejected: native hotkey registration), of which the two Ergopti
      `.keylayout` parses about 100-170 ms (both needed: Ergopti+ gives the AltGr keys), their spec 35-60 ms,
      `platform/remap.ahk` 150 ms and the ★ key slot's cohort registration 45-60 ms; the configuration stage
      500-700 ms; the shortcuts stage 170-330 ms; the AI catalogue 230 ms (deferring it means a lazy accessor for
      its 184 readers). The tray menu is built before readiness by decision (« Windows boot: keyboard before tray »
      in `docs/memory/maintainer-decisions.md`), so it cannot move after ready; what is left in it is the menu rows
      themselves. Done 18 November (same bench, 3 interleaved rounds of 3 boots, PC under heavy use, so whole-boot
      totals moved more with load than with the code): the shipped `index.json` is decoded once for both layouts
      (one decode 14-26 ms; `ErgoptiLayout_Init` 375 to 266 ms), the ★ key slot's source probe reads the base
      tables and the number-row mode once per probe instead of once per key (196 table builds to 2;
      `StarSlotStart` 248 to 156 ms), and the tray's Hotstrings total counts bundled files from the admitted
      hotstring cache rows instead of rescanning about 3,200 catalogue lines (172 to 31 ms; the tray stage 734 to
      500 ms CPU). The i18n stage is 60-80 ms warm: its 700 ms and 480 ms of the hotstring stage in earlier
      notes were cold caches of a fresh private code copy, which the benchmark now warms first. A smoke boot beside a
      resident driver is suspended, so it does not measure the keyboard arbiter of the prefix-watcher stage. The PC
      timings and the macOS field points `rerun_2026_11_02` and `main_thread_holds` are in the TODO-tests files.
      Done 18 November, second pass (quiet PC beside the resident driver, 4 interleaved rounds of one warm-up and 3
      boots per variant, medians of 12): the configuration stage was 250 ms CPU, and 160-190 ms of it was the typed
      read of the 33 KB personal hotstrings file for its `_meta` tables. The TOML document reader now reads a one-line
      assignment of simple tokens, splits a member list of bare keys and one-line scalars, decodes a one-line basic
      string or a Boolean and takes a quoted key without escapes by native matches instead of its lexer, with the same
      documents, records and spans on 518 TOML files (the shared tree and a real configuration): the personal file
      parses in 33-45 ms instead of 94-115 ms and config.toml, read about five times per boot, in 10-12 ms instead of
      16-20 ms (same process). The configuration stage went from 250 to 172 ms CPU with the member split alone, and
      from 195 to 141 ms with every shortcut in a later, quieter series (wall 197 to 140 ms); the whole boot stayed
      inside its noise (4.85 s elapsed both ways). Measured and left:
      the hotstring stage has no single hotspot (« Trimming per-row work in the Windows hotstring registrars » in
      `docs/memory/rejected_proposals.md`); the `.tsv` admission is 40-65 ms warm. Done 18 November, third pass:
      the AI catalogue include decoded `api_providers.json` (21 ms), walked the whole text again for the providers'
      spans (20 ms) and each provider's slice once more (24-32 ms), and each thinking_dialect was walked again on
      top. One decode now also returns the providers' member span tree (`JsonParseWithMemberSpans`), so the text
      is walked as one complete document per load instead of 170 times, with every refusal and its message kept
      (`test_remote_catalog_refusals.ahk`). Same bench, 4 interleaved rounds of one warm-up and 3 boots per
      variant, PC loaded by a WSL suite, medians of 12: the AI stage ('LLM defaults loaded') 255 to 170 ms wall
      and 250 to 172 ms CPU, every new boot below every old one but one; a standalone QPC harness on the same
      text, 119 to 61 ms. The whole boot stayed inside its noise (6.53 to 6.43 s). Linux decoded the same text
      three times for two owners (the remote catalogue and both local-server catalogue loads); it now decodes
      it once (`Json.decode_shared`), about 9 ms less (4.4 ms per LuaJIT decode under WSL). macOS decodes it once natively and once lossless, which the shape proof
      needs, and walks no slice again. Done 19 November: the same include decoded `local_servers.json`
      (16 KB), validated it whole twice more (request_fields, thinking_dialect), decoded each request field's
      slice and walked the dialect's slice again, 5 passes; one `JsonParseWithMemberSpans` now serves them,
      1 pass, every logged refusal kept (`test_remote_catalog_refusals.ahk`). Same bench, 4 interleaved
      rounds, medians of 12: the AI stage 123 to 114 ms wall and 125 to 109 ms CPU, inside a noisy PC's
      spread; the whole boot inside its noise (5.52 to 5.48 s). Linux decoded the file once per local
      catalogue load, two at boot; `Json.decode_shared` now serves both (1.2 ms per LuaJIT decode under WSL).
      macOS loads it once, natively and lossless for the shape proof, like `api_providers.json`.
      Done 20 November (same bench, interleaved rounds of one warm-up and one boot per variant, PC loaded by other
      agents, medians): the InputHook scalar end-key table (64,515 units, warmed in `core/lifecycle/engine/boot.ahk`)
      was filled by one `NumPut` per unit; it is written four units per Int64 store now, the same units in the same
      order (`test_siho_boot_window.ahk`): 'Paths and shared configuration loaded' 219 to 109 ms CPU over 5 rounds, a
      QPC harness 145-380 to 21-28 ms. `JsonParse` reads a member whose key has no escape and whose value is a plain
      scalar (a string without escapes, an integer of up to 18 digits, a literal) with its separator by one anchored
      match, a key before a container value and a plain array element likewise; the rest and every refusal keep the
      exact walk, with the same trees, counters and messages on the 728 JSON files of the tree
      (`test_json_decode_fast_path.ahk`). Over 620 shipped files 21.9 to 10.7 s, the menu manifest 190 to 82 ms; at
      boot over 15 rounds 'Config parsed (TOML + i18n)', where `HotstringsSeedLanguageCategoryGates` decodes the
      manifest first, 172 to 78 ms CPU, the shortcuts stage 94 to 47 ms and 'LLM defaults loaded' 78 to 63 ms. The
      whole boot stayed inside its noise. Measured and left: the script parse (1.1-2.6 s CPU here) follows code volume,
      11.9 MB over 577 included files, of which the functions no production code names are about 46 KB, so dead code
      is no lever, and `vendor/UIA.ahk` is about 70 ms; config.toml is decoded twice by design (the private shadow);
      the menu manifest is needed whole before the tray.
      Done 22 November (bench configuration with hotstrings and the AI on and three 37 KB personal files; PC heavily
      loaded by other agents, so whole-boot wall times moved with load; main-thread cycles from QueryThreadCycleTime,
      3 interleaved rounds of one warm-up and 3 boots per variant, medians of 9): the logger redacted each line with
      `Redact_Apply`, which resolved the rules and the context again for every line (the 17 shipped names lower-cased
      twice, each folder spelling, a bound callback per pass) and rebuilt the line once per pass: about 1.1 ms a
      line, 315-350 ms for a boot's 280 lines in a QPC harness, felt as one 200-300 ms main-thread stall wherever the
      first 500 ms flush timer fell (the Ergopti layout read, `platform/remap.ahk` or `MagicEditorStart` in turn:
      'layout and remaps' read 485-590 ms instead of 220-270). A flush now prepares the passes once
      (`Redact_Prepare`, `Redact_ApplyPrepared`) and skips a pass whose needle the text lacks with one native search:
      the same 280 lines in 24-45 ms with byte-identical output; 'layout and remaps' 1871 to 1179 Mcycles, the tray
      stage 968 to 687, the stages' sum 6423 to 5258 and a boot's logger flushes 3709 to 1967 Mcycles
      (`test_native_write.ahk` counts one preparation per batch). Full startup smoke, 2 interleaved runs per variant:
      green both ways, the first deferred menu build of a fixture boot at 11.5 s median before and 10.2 s after
      (32 fixture boots each, same load). macOS and Linux redact each line through the shared Lua module, which
      folded the line to lower case and rebuilt it once per pass and resolved the home-relative configuration folder
      again per line: an unmatched line now costs one fold and no rebuild (`redact_work.lua`), the 280 lines in
      47-59 ms instead of 104-219 ms under Lua 5.4, the 43 shared vectors unchanged. Measured and left: the script
      parse is linear in code volume (synthetic 5, 10 and 20 MB scripts validate in 1.0, 1.8 and 3.8 s CPU, about
      0.18 ms per KB; the entry's `/validate` 1.45-1.97 s); the two `.keylayout` parses take about 130 ms together in
      a QPC harness, 5 ms of it the tag scan and the rest interpreter cost per tag and attribute (a split-based
      attribute reader measured no gain); each additional personal hotstring file costs a full `TOML_ParseDocument`
      at discovery (60-120 ms for 37 KB, kept for the menu's metadata questions) and 140 ms of registration in
      `LoadExtTomlFile` (about 0.5 ms a row); the boot full save just after the ready line (`_SaveFullConfigDeferred`)
      holds the main thread about 990 Mcycles, measured once.
- [ ] **[RELEASE] Before publishing.** On a quiet PC with no resident driver: the whole AHK suite,
      `npm run test:ahk-tray-rows-read-as-text`, every live check including `quit-over-a-log-flush`, the JS, macOS and
      Linux suites, and a Windows field report with a driver.

## Remaining code work

### Windows

- **Parity literals.** PAR-58: `terminator_restoration`, `context_buffer`, `request_plan_*` and `row_options` are
  replayed on all three drivers (row options on macOS and Linux through `test-keylayout-row-options` and
  `test-xkb-row-options`). `session_events` and `metrics_maintenance` are replayed on all three drivers since
  2026-11-18 (on macOS: three session fixes in `modules/keystats/session_machine.lua`, synthetic text no longer
  opening a session, and a Purge found by its tombstone's UTC instant). `composite_key` is Windows-only by its own
  scope. `menus/*`: macOS and Linux replay every corpus whose rows they draw (per-corpus table in
  [the parity audit](docs/platform-parity-audit.md)). PAR-74: 2 literals left, in `_shared/settings/data/features/caps_word_auto_off_policy.ahk`, which
  cannot include the generated constants. PAR-79: 4 Windows timer literals left (13 in
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
  poll, the model browser bridge, the WPM display module that only a `WPMWidget` double stands for) stay source reads
  until they get a harness.
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
      [docs/plans/structure-migration-resume.md](docs/plans/structure-migration-resume.md)). S26 (hotstrings) is
      built on `fix/windows-pc-2026-11-17` and waits for its CI proof. Left: S27 (install) to S38, one step per commit
      with `tools/audit/structure/run-phase2.cjs`, two or three per push after a CI proof.
      Paths that describe a published artifact (a prior release's payload, a historical pin) keep their old spelling.
- **Provider flags inferred, not read.** Only provable with a live key: SambaNova's `enable_thinking: false` (off is
  its default, the docs show only `true`) and the Chutes Qwen `enable_thinking` field; a refusal is dropped and
  remembered either way.
- **108. Per-device physical bindings.** Deferred until designed: the collision, source, modifier and output joins of
  a shortcut bound to a key position on one device; `keyboard_hook.capture_position` hands only `native_code` and
  `mods`.

- [ ] **« Lancer le field report (tous les tests) » (maintainer requests, 2026-11-24).** Débogage's row just before «
      Tests » runs the driver's own field run in-app: on the three drivers the menu hands the field run session its
      field check steps in-process (`Session:submit_in_app`, shared by macOS and Linux in
      `_shared/diagnostics/engine/field_run/in_app.lua`; `SubmitInApp` in `field_run.ahk`), with no clone and no
      collector, and shows one report (`_shared/diagnostics/engine/field_check/field_report.lua`): verdict counts, each
      step with its TODO-tests field points, the steps not run here with their reason (guided: a person; reload, AI
      downloads, diagnostics, signed install: the collector), the Tests rows run separately and the folder of the result
      files to attach to an issue. An installed Mac app or Windows driver starts its session on demand on `folder.macos`
      or `folder.windows` of the shared protocol. Left:
  - **Progress window (maintainer request, 2026-11-24).** A shared WebView app window (`_shared/ui`, each driver's
    host, like the diagnostics and update windows; AAA tokens of `theme.css`, keyboard walk, live-region
    announcements) showing each step's state (pending, running, pass, fail, skipped, needs you) from the observer,
    then the counts and three buttons: open the results folder (Finder, Explorer, file manager), « Copier le rapport
    », « Créer une issue GitHub » through the bug-report link builder's public function with the summary in the URL
    and the report on the clipboard. Closing it during the run calls `Session:cancel_in_app` (logged pair). Add it to
    the app-window accessibility scan with fake hosts. The macOS and Linux observers are in place; today the report
    opens in the one-click checks' dialog.
  - **Field points still without an automatic driver step.** Linux: the collector's probe steps `linux_input_access`,
    `linux_autostart`, `linux_polkit_agent` and `linux_focus_listener` (points `physical_acceptance`, `wayland_focus`)
    run only from `collect-linux-field-report.sh`; a Linux field check step reading the same probes from
    `diagnostics/data/field_guided_steps.json` would put them in the in-app run. Windows: `TODO-tests-windows.md`
    carries no `field-point` ids and no `field_todo_coverage.json`, so its report would name steps only. macOS: 196
    step ids of the field run checks have no `field_check.step.*` label, so the report shows their steps as closed
    codes.

### Linux

- [ ] **Archive downloads: time a first install on the PC.** The owned archive download waited out the idle wait
      twice per 64 KiB chunk (the write's thread-pool acknowledgement, then the restarted pipe reader, which libuv
      registers only on its next poll) and read `config.toml` 28 times per chunk. Fixed on 2026-11-20: the idle
      wait polls libuv's backend descriptor, the curl reader's resume calls `event_loop.wake()`, and the AI
      preference reader reads the bytes only when the file's lstat change token moves (trusted once the file has
      been quiet 3 s). `tests/hardware/run_archive_download_throughput.lua`, 64 MiB from a loopback server on a
      shared 8-core WSL: 3.1 MB/s before (2 idle-wait timeouts and 28 full config reads per chunk), 11.0 MB/s
      with the wake alone, 17.7 to 21.1 MB/s with both (0 full reads per chunk), so about 70 s instead of 7.7 min
      for the 1.4 GB archive. Its `revoke` mode rewrites the model in place with the same size mid-download, on a
      trusted token: no byte lands after the edit. What remains per chunk is 14 `install_resolver` ancestor walks
      (about 1.5 ms, one lstat per ancestor each). Time a first real install on the PC.
- [ ] **[LATER] Legacy Linux updater probes.** `tools/build/add-linux-legacy-update-probes.sh` adds
      `_shared/data/locales/en.json` and an empty `_shared/lua/` to the release tarball so pre-move updaters (v1.0.9
      … v1.0.10-dev.175) admit it. Remove that step, its call, `test-linux-legacy-update-probes.cjs` and the frozen
      helpers of `tools/test/fixtures/linux-pre-move-ownership` once the first release whose updater finds a staged
      shared root by `build_stamp.txt` has been out for one full release cycle. The structure step that moves
      `linux/infra/version.lua` (also required by v1.0.9) must add that probe too.

## Dev prerelease numbering (maintainer request, 2026-11-23)

- [ ] **[CI] Restart the dev counter at each new core, once `v1.0.10` stable is published.** Today `N` in
      `vX.Y.Z-dev.N` is one counter across the whole series (decision of 2026-11-08 in
      [maintainer decisions](docs/memory/maintainer-decisions.md)), so the 1.0.10 prereleases read `dev.170`…`dev.177`
      when the core already says which release they lead to. Wanted: `N` counts the prereleases of its own core,
      `v1.0.11-dev.1`, `.2`… Not before that stable: semver orders `v1.0.10-dev.1` below the installed
      `v1.0.10-dev.177`, so the updaters would never offer it; `1.0.10` keeps `dev.178` and up. Change in `ci.yml`: take
      the highest `N` among tags of the computed core only (`next_n=1` when none), keep the request range from the
      newest dev tag of the whole series and the `v0.0.0` bridge rule up to 169; pin both cases in
      `tools/test/test-ci-release-reruns.cjs` and replace the 2026-11-08 decision text. Sparkle is unaffected: its
      build number is the CI run number (`ci-macos.yml`, `ERGOPTI_BUILD`).

## Test quality gates (maintainer request, 2026-11-23)

The suites have unit, integration and end-to-end tests, but nothing measures how much of the code they run or
whether they catch a change: no line coverage tool and no mutation testing exist (« coverage » in the CI files means
the list of mandatory jobs, `.github/linux-ci-coverage.json`). Only a few fixes were proved by a hand-made source
mutation (see Next session). Target, red in CI otherwise: 100 % of lines covered and 100 % of mutants killed, an
equivalent mutant being allowed only in a reviewed list that says why.

- [ ] **[CI] Line coverage per language, in CI.** One report per language, merged per driver:
  - Lua (macOS, Linux, shared): LuaCov under the existing runners (`tests/run.lua`), LuaJIT included;
  - JavaScript (tools, shared UI pages, site): c8 over the `tools/test/features` suites;
  - Swift (launcher): `swift test --enable-code-coverage` and `llvm-cov export`;
  - Python: coverage.py; Go (`native_http`): `go test -coverprofile`;
  - AutoHotkey: no coverage tool exists; instrument the sources in a copy (a counter call per statement) and
    run `run_all.ahk` on that copy.
- [ ] **[CI] Coverage gate.** Fails the lane below 100 %. Since today's figure is unknown, start with a per-file
      ratchet (a baseline that may only rise, as the existing `*-baseline.json` gates do), then lower nothing and
      raise each file to 100 %; generated files and vendored code are excluded by the generator registry and the
      vendor list, never by hand.
- [ ] **[CI] Mutation testing.** Stryker for JavaScript, mutmut for Python, a Go mutator (gremlins) for
      `native_http`, Muter for Swift; Lua and AutoHotkey have no mature tool, so a repository mutator (operator,
      boolean, comparison, return-value and removed-call mutants over a tokenized copy) runs their suites per
      mutant. Mutants run on the files a change touches in each push and on the whole tree nightly, since a full
      run is long.
- [ ] **[CI] Mutation gate.** 100 % of mutants killed, red otherwise, with the same ratchet as coverage until then;
      every surviving mutant is either killed by a new test or listed as equivalent with its reason.

## Bug report and feature links (maintainer request, 2026-11-24)

Field report on `dev.178` (macOS, 12:18 Paris): the bug link's Diagnostics field was a Markdown table of
config.toml rows (`gestures.enabled | boolean: true`…) cut before any error, with only a note pointing to the
clipboard and the saved file; the feature link said `unknown` for the version. Done on 2026-11-24: the report is
readable English lines grouped by diagnostic value (`share_policy.report_order`: errors, checks, permissions,
files, input, versions, system, hardware, AI, developer, report, then the unbounded changed settings), the
configuration keeps only the settings that differ from their manifest default, the bug form gained a required
« Full report » textarea for the clipboard and a short intro, both forms put a Driver dropdown (macOS, Windows,
Linux) before the system, and the feature form requires only the title and « Your proposal ». macOS's Suggest a
feature now collects the local state, which holds the versions. Proofs: `report_vectors.json` replayed by
share.lua, model.js and report.ahk, `configuration_vectors.json`, `test-issue-templates.cjs`.

- [ ] **[CI] Run the AHK suite on the change.** `report.ahk`'s readable report port, the default filter of
      `configuration.ahk` and their tests (`report-readable`, `report-budget`) were only parse-gated here: no
      AutoHotkey ran.
- [ ] **No raw log line can be shared.** The closed sharing policy carries recognised error codes and counts, not
      the recent log lines (`project-shared-export-schema-is-closed`): the « recent log lines » of the request
      need a privacy decision before any schema change. Meanwhile the opt-in redacted day log stays the way.
- [ ] **The URL budget stays 4,000 bytes.** It is set by the signed-out login redirect, which encodes the link
      again (measured in `test-issue-templates.cjs`). A budget counted on the re-encoded length would let a
      mostly-letter report grow by about a third; to measure on github.com before changing `issue_link` in its
      three ports.
- [ ] **A very large complete report.** GitHub refuses an issue body over 65,536 characters; a config.toml with
      hundreds of changed settings plus the JSON block could reach it. Measure on a real report before trimming.

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
    `model-browser-native-json` (43347126427, not reproduced; all four `config-*` groups, the bound check and
    `run_llm_model_browser.ahk` passed three times in a row locally on 2026-11-18, so only hosted runs are left);
  - macOS: Go `TestIdleDeadlinePhysicallyRetiresPeer` and `TestCancellationAndConcurrentClosePhysicallyRetirePeer`
    (Intel Managed Ollama, fixed with its `slow-start` case), Swift
    `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope`, and the Install-and-launch
    `symlink_logs_dir` Quit timeout (once in 42929436137, unexplained).

## Maintainer decisions pending

Each question names the default kept meanwhile; an answer moves into the item or into
[maintainer decisions](docs/memory/maintainer-decisions.md).

- [ ] **Package contact and category (2026-11-24):** decided by the agent on 2026-11-24, to review by the
      maintainer. The repository publishes no contact address, so the Debian, RPM and Arch Maintainer fields name
      the maintainer's GitHub commit address (`maintainer_email` in `_shared/core/text/data/app_metadata.json`) and
      the AppStream `contact` URL, the Debian `Upstream-Contact` and the exe's comments send users to the issue
      tracker; give a monitored address to replace it. The macOS category is `public.app-category.utilities` (the
      Linux entries' `Utility`) rather than productivity. The AppImage ships no AppStream file yet: appimagetool
      validates one when present and no `appstreamcli` ran here, so it is left for a run that can validate it.
- [ ] **Feature form identity (decided by the agent on 2026-11-24, to review by the maintainer).** The feature
      form keeps ErgoptiPlus version, Driver and Operating system, prefilled and optional, so an idea sent from an
      old version whose feature already exists can be answered at once. Kept meanwhile: kept. The other choice is
      to drop the three fields and keep only the title and the proposal.
- [ ] **The input probes in « Lancer le field report » (decided by the agent on 2026-11-24, to review by the maintainer).**
      « Mesurer SendEvent et SendInput » asks nothing, but it types into its own window for several seconds and any
      key the person presses spoils it, like « Enregistrer l'ordre des hooks clavier »; both are listed in the
      report as « run separately ». Kept meanwhile: separate. Choose:
  1. **(recommended) Keep both separate.**
  2. Run the SendInput comparison in the field report row, after a notice asking not to type.
- [ ] **The left thumb's second key:** decided 2026-11-21: the left thumb types on one key (NonConvert) and no second
      left thumb key types on any board, the ErgoDox included; implementation pending integration.
- [ ] **Renew the reviewed number-row test image:** decided 2026-11-21: renewal accepted; implementation pending
      integration.
- [ ] **Optimizer « an existing layout would do the job » (decided by the agent on 2026-11-19, to review by the
      maintainer).** After a run the Optimiser scores the library on the same corpus and settings and shows the
      most alike layouts and the best-scoring one; its small gap, `similar_score_gap` = 2 points, was confirmed by
      the maintainer on 2026-11-19. Since the mark (2026-11-24) the card says the gap in % of the marks with the
      points beside it, and the verdict still reads the gap in points against those 2 points; the similarity shown
      first is the weighted share of the characters on the same key and level, spaces aside, with the same finger
      and row and the unweighted share beside it; five alike layouts are listed. Choose whether the small gap
      becomes a %, and the measure shown first (docs/design/layout-optimizer.md, « Existing layouts »).
- [ ] **The mark's zero (decided by the agent on 2026-11-24, to review by the maintainer).** Every layout's mark is
      its total less the zero, a bound from the score's own costs on the board, corpus and settings
      (docs/design/layout-analysis.md, « Mark »): the most expensive key pair and triple, every other penalty at
      100 % (`distance` at 4 presses of the longest reach), `hand_run` at the corpus typed by one hand. Loose by
      nature: on Don Quichotte the zero is −8,416 and Ergopti+ reads +2.1 % on QWERTY, not tens of %. Two parts are
      a model's bound, not a proof (`distance` past 4 presses per character, `hand_run`'s chain, which has no finite
      bound). QWERTY is now the reference on every corpus, the Comparer's relative view included (AZERTY was the
      French one). Kept meanwhile: this bound. Choose:
  1. **(recommended) Keep this bound** and accept small ratios: no library layout reaches 0.
  2. A tighter bound over the corpus's own n-grams (to study: what share of the key bigrams one pair can hold).
  3. The optimizer run to maximise the cost on each corpus and settings: realistic ratios, but a found worst that
     a layout may pass (a negative mark), and seconds of search per change of settings.
- [ ] **Text replacements of the former « Essayer » page (decided by the agent on 2026-11-21, to review by the
      maintainer).** `/ergopti/utilisation` also typed Ergopti+'s ★ text replacements and listed them by category;
      the Studio's « Essayer » tab types the layout only (its dead keys and levels, any library layout), so the
      list and the ★ replacements went with the page. Kept meanwhile: removed.
  1. **(recommended) List the replacements on `/ergopti-plus/hotstrings`**, where Ergopti+'s hotstrings are
     presented, read from the same catalogues.
  2. Type the ★ replacements in the Studio's « Essayer » tab when Ergopti+ is chosen.
  3. Leave them out: the app shows its own hotstrings.
- [ ] **`pinky_ring` weight and the penalty floors (decided by the agent on 2026-11-24, to review by the
      maintainer).** The metrics, the floors (`floors` of `score_weights.json`), their editing in the Comparer's
      score settings (file version 3) and the « Difference to QWERTY / AZERTY » view are all shipped. Measured on
      2026-11-24 over the 783 library layouts: `pinky_ring` ranks them unlike `half_scissors` (Spearman 0.03 on
      Swann, 0.07 on English Wikipedia), so it is no duplicate. Kept meanwhile: `pinky_ring` at weight 0 and every
      floor at 0, so no score moves while the score's normalisation changes (docs/design/layout-analysis.md, the
      agent's decisions of 2026-11-19). Choose a `pinky_ring` weight (Oxeylyzer's ratio to its SFB weight would give
      about 0.14 beside `sfb` 5) and any non-zero floor (Cyanophage: SFB 0.3 %, hand balance 1 point).
- [ ] **Row jumps in the global score (review note).** Decided 2026-11-21: `row_jump` counts same-hand bigrams on
      different fingers only (one finger's move stays an SFB) and weighs half the SFB weight (`sfb` 5, `row_jump`
      2.5), on dev since 732f924251 ([decision](docs/memory/maintainer-decisions.md), « Layout score: graded costs »).
      Review the shipped scale against `docs/audits/layout-analysers/graded-costs-ranking.md`.
      the maintainer on 2026-11-19, and the similarity shown first, the weighted share of the characters on the
      same key and level, spaces aside, with the same finger and row, the unweighted share beside it, on
      2026-11-22 (`docs/memory/maintainer-decisions.md`). Kept meanwhile: the gap is said in points, not in %,
      since the score has no zero; five alike layouts are listed. Choose whether a gap in % of the run's gain
      over its start would read better (docs/design/layout-optimizer.md, « Existing layouts »).
- [ ] **Optimizer change penalty (decided by the agent on 2026-11-19, to review by the maintainer).** The
      Optimiser can take off its objective the cost of leaving the start layout: a weight in score points per % of
      the corpus's characters moved, each weighted by its occurrences as `layoutSimilarity` weighs them (100 − its
      weighted same-key share), and a hard « at most N changed characters » (a letter and its capital count once).
      Kept meanwhile (`score_weights.json` `change_penalty`): presets « few changes » 3, « balanced » 1, « free » 0,
      the slider up to 5, « at most 6 changed characters » when the limit is switched on, and « free » chosen
      first, so a run moves what pays as before until the reader asks otherwise. Measured on AZERTY, the first 60 000 characters of Nemolivier, 3 000 swaps: weight 0 moves 92 % of
      the typed characters for +102 points, 1 moves 71 % for +95, 3 moves 8 % for +36. Choose the presets, whether
      « balanced » should be the first one, and whether the hard limit should count a letter and its capital as two
      (docs/design/layout-optimizer.md, « Change penalty »).
- [ ] **The left thumb's second key (decided by the agent on 2026-11-19, to review by the maintainer).** The
      thumbs' own keys are NonConvert (left thumb), Convert and KanaMode (right), as on JIS; their effort and pairs
      were settled on 2026-11-19 (docs/memory/maintainer-decisions.md). Kept meanwhile: one key for the left thumb,
      so the layouts that need two there (Cahi, Chia, SNTH) stay out of the library. Choose whether the left thumb
      gets a second key.

- [ ] **Accessibility texts stay French (decided by the agent on 2026-11-19, to review by the maintainer).** The
      site's accessibility statement (`/accessibilite`) and its settings dialog (`A11ySettings.svelte`) do not get
      the 21 locales: the site has no locale system (only the Ergopti+ pages read in English, through `t()`), and
      what Ergopti+ and Ergopti Studio show in the app already goes through the 21 locales. Under the English
      Ergopti+ page they say `lang="fr"` with the rest of the site's header, footer and banner, so a screen reader
      reads them as French (`tools/test/test-site-languages.cjs`). Kept meanwhile: French only.
  1. **(recommended) Keep them French** until the site itself offers a language choice, then route them through it.
  2. Translate the dialog and the statement into English now, with the Ergopti+ `t()` dictionary.
  3. Give them the 21 locales, which first needs a locale system for the whole site.
- [ ] **AAA tools: axe-core only (decided by the agent on 2026-11-24, to review by the maintainer).** Of the tools
      surveyed ([aaa-criteria.md](docs/audits/accessibility/aaa-criteria.md)), only axe-core measures AAA rules
      without a new dependency or a network fetch; IBM Equal Access and Lighthouse have no AAA rule. Kept meanwhile:
      axe-core's three AAA rules, no new dependency.
  1. **(recommended) Keep axe-core alone** and write the repository's own checks for what it misses (2.5.5).
  2. Add HTML_CodeSniffer (pinned npm package), injected into the same Playwright pages, for its `WCAG2AAA`
     errors; its notices need a person anyway.
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
      Utilisation page is split into « Essayer » and `/ergopti/installation` (downloads, OS guides, printable
      layouts); `/utilisation` without an anchor lands on installation. « Essayer » is now Ergopti Studio's tab
      (`/studio/essayer`, maintainer 2026-11-21, `docs/memory/maintainer-decisions.md`): `/ergopti/utilisation`
      redirects to it with `layout=ergopti`, anchors kept. No `/ergopti/faq`: the layout has no FAQ content yet (« Autocritiques » stays in Informations).
      Ergopti+ sub-pages: présentation (Pour qui, Déjà en Ergopti, Comparatif), hotstrings, ia, fonctionnalités
      (tap-holds, raccourcis, trackpad, métriques), configuration (réglages, vie privée), installation (démarrer,
      télécharger), faq; no « versions » page, its changelog stays in the app. The floating reference keyboard only
      shows on the `/ergopti` pages. The Studio icon (`static/img/logo/studio.svg`: a keycap and a pencil on the dark
      disc of the logos) is new. Approve or change.
- [ ] **List the text replacements of the former « Essayer » page on `/ergopti-plus/hotstrings` (maintainer
      2026-11-22, `docs/memory/maintainer-decisions.md`).** `/ergopti/utilisation` also typed Ergopti+'s ★ text
      replacements and listed them by category; the Studio's « Essayer » tab types the layout only, so the list
      went with the page. List them by category on `/ergopti-plus/hotstrings`, read from the same catalogues
      (being implemented by another change).
- [ ] **« Essayer » becomes a Studio tab (maintainer, 2026-11-21).** The site placements decided by the agent on
      2026-11-14 (fb510e1113, f555c231e5) are approved ([decision](docs/memory/maintainer-decisions.md)), except the
      « Essayer » page (`/ergopti/utilisation`: online typing and text replacements), which moves into a tab of
      Ergopti Studio. Another agent is implementing it; close this item when that move lands.
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
- [ ] **A French chat corpus?** The chat corpus shipped on 2026-11-21 is English only (Taskmaster-1's written
      dialogs, CC BY 4.0); Tatoeba's sentences stay the French conversational register. Candidates, none cleared,
      none downloaded: CoMeRe (Ortolang, chats and forums; licence per sub-corpus, unchecked; pseudonymised user
      names), 88milSMS (Montpellier, anonymised SMS; licence unchecked; private messages), the Claire French
      Dialogue Dataset (OpenLLM-France; mostly CC BY-NC-SA, transcribed speech, not typed). Never Enron or any
      corpus holding personal data. Kept meanwhile: no French chat corpus.
  1. **(recommended) Check CoMeRe's per-corpus licences** and import, as a count table, a sub-corpus under a free
     licence whose user names are already pseudonymised ([CODE]).
  2. Keep Tatoeba as the French conversational register.
- [ ] **Key-combination parity KCD-1 to KCD-8:** decided 2026-11-21: the recommended option for each, except KCD-7
      where Linux admits a pair or chord across two keyboards; implementation pending integration.
- [ ] **Tap-hold and hotstring cascade parity THD-1 to THD-4, HCD-1, HCD-2, HCD-4, HCD-5:** decided 2026-11-21: a
      pair's tap lifts the layer then restores it, a pair's tap takes the strict threshold, a layer key cancels a
      layer-hold pair's tap, the macOS thumb Backspace follows BackSpaceLogic, an expired winner fires nothing, a bare
      `:` or `;` ends a trigger everywhere, `@` tags wait the dynamic delay, and a tag follows the typed case per
      letter; implementation pending integration.
- [ ] **Identity gate false positive (open question of the 2026-11-15 hand-off).** The identity gate's false
      positive on every PDF's root trailer key in containers whose home is the root account's (left unchanged). The
      hand-off's other questions (layout name casing, dead-key marker style, ISO ticks on split and ortholinear
      boards) were validated as built by the maintainer on 2026-11-21.
- [ ] **Accessibility choices of the second pass (decided by the agent on 2026-11-17, to review by the
      maintainer).** The legacy `/ergopti-plus-old` page is kept and fixed, not retired, since the new Ergopti+ page
      links to it (« Ancienne version de cette page »); the system's « increase contrast » (`prefers-contrast:
more`, macOS and WebKit) does not switch the Studio frames to the black-and-yellow high-contrast theme, which
      stays the site setting's (the site itself has no such rule); the heatmap table lists keys by value, largest
      first, not in board order. Approve or change.
- [ ] **The locale's neutral value.** The manifest declares `script.locale` default `fr`, but every driver reads an
      absent locale row as the system language, and the sparse writer deletes a chosen `fr` as neutral. On Windows,
      whose full save writes the locale through `_ConfigSparseUpdates` (`settings/engine/io.ahk`), a French choice
      on another system language therefore reads as that language after the next reload (read in source, not
      replayed). The Lua drivers keep the native locale when the row is absent until this is settled: (a) no
      neutral value for the locale (always written, never deleted), then an absent row clears the native value as
      the other `[script]` rows do; (b) absence means `fr` on every OS (no system-language detection).
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
- [ ] **Parity decisions THD-1 to THD-4 and HCD-1, HCD-2, HCD-4, HCD-5.** Tap-holds
      ([report](docs/audits/platform-parity/2026-11-10-tap-holds/report.md)): THD-1 the pair tap and the layer, THD-2
      the lone window, THD-3 layer-hold pair activity, THD-4 the macOS thumb Backspace under modifiers. Hotstring
      cascade ([report](docs/audits/platform-parity/2026-11-11-hotstring-cascade/report.md)): HCD-1 an expired best
      candidate (macOS falls to a lower rule), HCD-2 a bare `:` or `;` ends a trigger on macOS only, HCD-4 the delay
      on `@` tags, HCD-5 an uppercase one-letter tag (privacy). Each report names the default kept meanwhile.
