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
      Windows `TEST_NATIVE_SETTLE_TIMEOUT_MS` waits (15 AHK tests), the Ubuntu APT and Playwright download retries,
      and the keyring proof readiness wait. A macOS Apple-silicon job « not acquired by Runner » is GitHub capacity:
      rerun the failed jobs, do not move it to Intel.
- [ ] **[Windows] Short waits left after the flaky-test pass:** child fixtures that cannot read the test constant
      (`tests/fixtures/user_command_lifecycle_owner_body.ahk:137`, `worker_live_foreground_body.ahk:71`) and the named
      per-file limits (`SRTOW_*`, `_UER_NATIVE_WAIT_MS`, `_TDCR_NATIVE_WAIT_MS`, `CALO_READER_WAIT_MS`,
      `CRH_OPEN_WAIT_MS`, `PWRS_CAPTURE_TIMEOUT_MS`). Production `SR_TREE_TERMINATION_CONFIRM_BUDGET_MS` (500 ms) is
      kept on purpose; revisit only if a forced-termination test flakes alone. Linux hardware lane
      `tests/hardware/http_empty_headers.lua` keeps 3 s per request and 20 s in its Python harness.
- [ ] **[macOS] Owned runtime artifact.** The admin-shell helper changes of 2026-11-23 (stale runtime retirement
      before install, refusal note `refused-<case>:<file>:<line>`) only reach users once the maintainer rebuilds
      and republishes the runtime (`16.3.0-ergopti.7`); `vendor/remap-runtime/manifest.json` is theirs to move.
- [ ] **[macOS] Check `dev.178` on the Mac** (then move what stays open to TODO-tests-macos.md with its field
      point): no hammer icon in the menu bar, rounded icon in Quick Look, Accessibility guidance names
      ErgoptiPlus.app, the Tap-Holds submenu is greyed except « Réessayer l'installation… » while the runtime is not
      installed, AltGr and Shift+AltGr are emulated once a layout is chosen, the update window keeps a right margin beside its progress bar and its button row (fixed 2026-11-24), no « Aggregate cache recovery failed »
      or `%s` in the log.
- [ ] **[Maintainer] Questions left open:** the Tap-Holds warning dot stays the shared yellow 🟡 (orange asked
      once, not confirmed); keystats day-by-day aggregate publication shipped, review welcome.

## Open since the 2026-11-17 pass

- [ ] **Exact-count ceilings in tests (maintainer: « ces tests avec seuil magic value c'est vraiment mauvais »).**
      Replace exact operation counts and similar magic thresholds with budgets that mean something (time, order of
      magnitude, or a named single source), one ratchet at a time. Done from 2026-11-17 to 2026-11-22: the startup
      smoke names the owners of the boot's repeated work (`BOOT_WORK_OWNERS`), the Studio speed checks time the
      analysers against a reference table walk (`tools/test/lib/table-walk-speed.cjs`), row counts read their
      declaration, count ratchets compare named ledgers (`tools/test/lib/known-debt.cjs`) and the TOML cost tests
      compare two input sizes. Left, each needing a measurement or a design first:
  - `unit/ai/api/test_post_save_owner.ahk` still caps one API save at 400 registry deep compares. Measured
    2026-11-22 by owner (`ConfigMigrateDeepCompareOwnersTake`): 152 per save, of which the anonymous transition
    guards `capture_recovery:<Func.Prototype.Call` 56 and `capture_transition:<Func.Prototype.Call` 48, and
    `check_write:ConfigMigrateBoot<ConfigSchemaCanPrepareWrite` 29. An owner table like `BOOT_WORK_OWNERS` needs the
    unit those guards repeat per traced in `settings/engine/migration/migrate.ahk` first; naming them « each »
    without it would let the former 1 665-compare journal re-read back in.
  - `test-driver-tree-parity.cjs` (shared 66, union 87, tests 18/75, canonical 9) and
    `test-port-vector-traceability.cjs` (73) are floors and ceilings that the structure phase 2 runner rewrites with
    `--update-baseline --allow-rise`; listing the directories instead means changing that runner with them.
  - The two Studio speed bounds (120 and 5000 table walks) rest on ratios measured with every core busy; read the
    ratio each test prints on a quiet PC and on CI, and set each bound to twice the highest.
  - Kept on purpose: order-of-magnitude bounds that state their reason (the Linux e2e 3000 tray rows against the
    former 103 058), loop-progress bounds a test chooses for its own loop, frozen historical references, corpus
    floors and non-vacuity floors.
- [ ] **The target's own paste can still lose to Windows' clipboard readers.** Since 7de36977ab (2026-11-22) the
      paste transport's leases (`CB_IsBusy`, the plain CAS and its authentication, the restore retry) outwait a
      reader of another process for `CB_PASTE_READER_WAIT_MS` (100 ms), a refused SendInstant publication is logged
      with the holder, and the payload carries the clipboard-history and cloud exclusion formats
      (`test_clipboard_reader_wait.ahk`). Left: the application's own single `OpenClipboard` after Ctrl+V.
      explorer.exe, `cbdhsvc` and msrdc.exe (WSLg) still open the clipboard after writes, with or without the
      exclusion formats, and msrdc renders every delayed text format, so neither the formats nor a delayed-rendering
      receipt can prove the paste (a single open 0-140 ms after a write failed about 1 time in 60-120). The
      `gesture-transform-native-render-focus` and `wrap-native-render-focus` current modes still fail that way now
      and then (sends=1, Edit empty); make such fixtures hold a known reader instead of depending on the desktop's.
      The TextSend payload (`CB_WriteTextWithReceipt`, LLM and diagnostics) is still published through
      `A_Clipboard`, without the exclusion formats. macOS and Linux have no clipboard lock, so the race does not
      exist there; their transient hints (`org.nspasteboard.TransientType`, `x-kde-passwordManagerHint`) are not
      set yet.

## Full accessibility (maintainer request, 2026-11-16, very important)

The goal is a totally accessible project: the site (ergopti.fr), Ergopti Studio (editor, Comparer, Optimiser,
benchmarks) on the site and inside the app, and Ergopti+ itself (menus, windows, dialogs, tooltips, onboarding) on
Windows, macOS and Linux. Target WCAG 2.2 level AAA everywhere (maintainer, 2026-11-23: the latest WCAG, AAA on the
site, Ergopti+ and every app window); every new page or window is held to it from now on.

- [ ] **[CODE] AAA measured in CI, red below perfect (maintainer, 2026-11-23).** Survey the tools that measure
      accessibility (axe-core's `wcag2aaa`/`wcag22aaa` tags beside the AA ones, Pa11y with HTML_CodeSniffer's
      WCAG2AAA standard, IBM Equal Access, Lighthouse) and wire the ones that cover the AAA criteria into the site,
      Studio and app-window gates, with a zero baseline: any finding fails CI. List the AAA criteria no tool can
      measure (e.g. sign language, extended audio description, reading level) with how each is checked instead.

The site and the Studio pages are scanned by axe-core in CI (tools/test/browser/site-accessibility.playwright.cjs,
ratchet baseline beside it, findings in [docs/audits/accessibility/](docs/audits/accessibility/README.md)); lower the
baseline as violations go.

- [ ] **Manual audit.** A checklist per page and per native window (keyboard walk, NVDA, JAWS, Narrator, VoiceOver,
      Orca, 400 % zoom and 320 px reflow), recorded in docs/audits/accessibility/. The axe scan covers the app's own
      WebView windows since the fifth pass (21 windows, `npm run test:browser:app-accessibility`, fake host and
      fixture data); left there: the layout manager's 35 contrast nodes (its files were being changed elsewhere).
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
      `test_reading_preferences.ahk`. Left: the names of five one-unit keys of the editor's navigation block, still
      cut by a pixel or two under the 1.4.12 spacing (`PENDING_FRAME_ELEMENTS` in `site-reading.cjs`); a font
      change reaches only the windows opened after it; a look at the dyslexia font in a real window on each OS; the
      plain-language review of the Studio's own strings (the 21 locales' catalogue, not measured).
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
      `<kbd-output>` became `<samp class="kbd-output">` and the 4 `<image-block>` a `<figure>`, and the 87 left
      are justified in the same list. Left: those 87 — the 42 empty spacers (`tiny-space`…, a CSS margin would
      do), the page blocks (`bloc-page`, `bloc-main`, `bloc-introduction`, `bloc-fin`), the keyboard drawings'
      `keyboard`, `keyboard-row` and `keyboard-key`, the controls' wrappers and the brand names.
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
      Left: the macOS and Linux native windows; the typing heatmaps' key popups and the apps table's column
      explanations are still hover only (the same counts are in the tables).
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

- [ ] **[CODE] One layout score with 0 as the theoretical worst (maintainer, 2026-11-23).** Points with no zero read
      as nothing (« what is a point? »). Every layout gets a mark where 0 is the worst layout possible on the corpus
      and the settings, and higher is better with no ceiling, so ratios read plainly (« 23 % more than QWERTY »).
      QWERTY, common to every language, is the reference named beside the mark; AZERTY is French only. The worst
      bound comes from the score's own costs (the Optimiser run to maximise them, or a proven upper bound), not a
      library layout. The Comparer, the Optimiser (its « an existing layout would do the job » gap in %) and the
      site follow it ([decision](docs/memory/maintainer-decisions.md)).
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

- [ ] **Ideas from the other analysers, weights to decide (2026-11-19).** `pinky_ring` (pinky–ring pairs on any
      row), the penalty floors (`floors` of `score_weights.json`) and the ranking's « Difference to QWERTY / AZERTY »
      view are in the engine and the Comparer, at weight or floor 0 (docs/design/layout-analysis.md, « Metrics » and
      « Global score »); `sfb_distance` was weighed by the maintainer on 2026-11-19, and the graded costs (SFB by
      rows, `row_jump` as the same-hand skipgram by fingers and rows, travel by finger, the alternation switch and
      the same-hand run scale `hand_run`) were decided on 2026-11-21 and ship with the agent's scale
      (docs/audits/layout-analysers/graded-costs-ranking.md: one-row jumps make `row_jump` the largest new term,
      about 16 points per layout). Pending decisions: whether `pinky_ring` gets a weight once it is seen to rank
      layouts differently from `half_scissors`; any non-zero floor (Cyanophage: SFB 0.3 %, hand balance 1 point).
      The Comparer's score settings edit each floor and grade with its help, and its export file
      (`ergopti-score-settings`, version 3) requires them.
- [ ] **Longer skipgrams (2026-11-19).** genkey's gaps 1 to 9 and Oxeylyzer's 1 to 3 need skipgram tables in the
      corpus format. Measured: gaps 2–3 add 1.26 MB to the 9.2 MB of corpus files (about +40 % per text corpus,
      57 KB on Don Quichotte's 148 KB), gaps 2–9 5.93 MB (about +185 %); the 12 count-table corpora have no text to
      count them from, and a character pair at gap g is a key pair at gap g only when no character between takes
      two keys, so the key stream would no longer be exact (docs/design/analyser-scores.md, « Taken into the
      Ergopti score »).
- [ ] **Other analysers, what is left (2026-11-19).** genkey (1.3 % mean, 8.3 % max on code) and Oxeylyzer (trigram
      shares within 0.07–0.29 point) stay « close » until the corpus tables carry skipgrams of gap 2 to 9 and
      Oxeylyzer's token totals exactly (its saved counts lose one at a rate set by its exact total's bits).
      keycraft (BSD-3, Go, its score scaled on its own layout set) needs a Go toolchain to be checked; shirolyzer's
      score is undocumented.

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

- [ ] **[CODE] Parity audit continuation.** Take one bounded module at a time across Windows, macOS, Linux and shared;
      do not restart a finished campaign without source drift or a new hypothesis. The nine campaigns of the
      [2026-11-19 census](docs/audits/platform-parity/2026-11-19-census/report.md#proposed-order-for-the-next-campaigns)
      are taken and their findings fixed (secure fields, logger engines, managed Ollama, tray adapters, update and
      download windows, pickers and prompts, metrics views, small native units, layout tool pages; each report is
      under [docs/audits/platform-parity/](docs/audits/platform-parity/)). Left:
  - the re-campaigns for drift the census lists: `shared/layouts` (with S29), `shared/core`,
    `shared/ui/layout_editor` and the `ai` areas; the logger's boot profilers, perf counters and keystroke
    integrity, read only where they reach a sink;
  - the Linux note's folder and dated choice (`platform_reason.take_note_settings_are_windows`, `not_yet`);
  - the unpacked sizes of `ollama_release.json` are provisional (three times the archive, 4db0e861c9): run
    `node tools/build/pin-ollama-release.cjs --archives <folder> --write` in CI on the five pinned archives, commit
    its values, then keep its `--check` in the job that downloads them. OLL-06 (one readiness bound) waits for the
    cold-start field checks of TODO-tests-windows.md and TODO-tests-linux.md.
- [ ] **[RELEASE] Windows/Linux feed-only update fallback.** Built: the Versions window's feed-only list installs the
      channel's newest release through its required detached signature on both (`feed-only-install` tests, throwaway
      key in `feed_install_vectors.json`); without a key every feed row keeps the no-details refusal. Left, at release
      time once `public_key_spki_base64` is provisioned: the step-4 check of
      [update-signing](docs/tooling/update-signing.md) (a real feed-only install on Windows and Linux, the log saying
      the signature verified, an older row refused), then enforcement `required`.
- [ ] **[CI] Prove the number-row cohort's shared-fixture selection on macOS.** The XCTest process left HIToolbox's
      current layout (`AppleCurrentKeyboardLayoutInputSourceID`) on the old source 3 times in about 5,900 steps when
      it selected itself (runs 44025301586, 44029045918). Since 9a5867cc49 (image accepted by the maintainer on
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
mutation (see « Open since the 2026-11-17 pass »). Target, red in CI otherwise: 100 % of lines covered and 100 % of
mutants killed, an equivalent mutant being allowed only in a reviewed list that says why.

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

- [ ] **Row jumps' shipped scale (review note).** Decided 2026-11-21 and on dev since 732f924251: `row_jump` counts
      same-hand bigrams on different fingers only and weighs half the SFB weight (`sfb` 5, `row_jump` 2.5)
      ([decision](docs/memory/maintainer-decisions.md), « Layout score: graded costs »). Kept meanwhile: the agent's
      starting scale. Review it against `docs/audits/layout-analysers/graded-costs-ranking.md`.
- [ ] **Identity gate false positive (open question of the 2026-11-15 hand-off).** The identity gate flags every
      PDF's root trailer key in containers whose home is the root account's. Kept meanwhile: unchanged.
- [ ] **A French chat corpus?** The chat corpus shipped on 2026-11-21 is English only (Taskmaster-1's written
      dialogs, CC BY 4.0); Tatoeba's sentences stay the French conversational register. Candidates, none cleared,
      none downloaded: CoMeRe (Ortolang, chats and forums; licence per sub-corpus, unchecked; pseudonymised user
      names), 88milSMS (Montpellier, anonymised SMS; licence unchecked; private messages), the Claire French
      Dialogue Dataset (OpenLLM-France; mostly CC BY-NC-SA, transcribed speech, not typed). Never Enron or any
      corpus holding personal data. Kept meanwhile: no French chat corpus.
  1. **(recommended) Check CoMeRe's per-corpus licences** and import, as a count table, a sub-corpus under a free
     licence whose user names are already pseudonymised ([CODE]).
  2. Keep Tatoeba as the French conversational register.
