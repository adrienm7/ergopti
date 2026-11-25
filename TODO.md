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
- [ ] **[macOS] Check `dev.178` on the Mac** (then move what stays open to TODO-tests-macos.md with its field
      point): no hammer icon in the menu bar, rounded icon in Quick Look, Accessibility guidance names
      ErgoptiPlus.app, the Tap-Holds submenu is greyed except « Réessayer l'installation… » while the runtime is not
      installed, AltGr and Shift+AltGr are emulated once a layout is chosen, the update window keeps a right margin beside its progress bar and its button row (fixed 2026-11-24), no « Aggregate cache recovery failed »
      or `%s` in the log.
- [ ] **[Maintainer] Questions left open:** keystats day-by-day aggregate publication shipped, review welcome. The
      Tap-Holds dot is settled (maintainer, 2026-11-24): 🔴 whenever the owned runtime is missing, refused or failed,
      even with the switch off; the warning keeps the shared yellow 🟡 (no orange).

## Open since the 2026-11-17 pass

- [ ] **Exact-count ceilings in tests (maintainer: « ces tests avec seuil magic value c'est vraiment mauvais »).**
      Replace exact operation counts and similar magic thresholds with budgets that mean something (time, order of
      magnitude, or a named single source), one ratchet at a time. Done from 2026-11-17 to 2026-11-22: the startup
      smoke names the owners of the boot's repeated work (`BOOT_WORK_OWNERS`), the Studio speed checks time the
      analysers against a reference table walk (`tools/test/lib/table-walk-speed.cjs`), row counts read their
      declaration, count ratchets compare named ledgers (`tools/test/lib/known-debt.cjs`) and the TOML cost tests
      compare two input sizes. Left, each needing a measurement or a design first:
  - `unit/ai/api/test_post_save_owner.ahk` still caps one API save at 400 registry deep compares for the owners
    its `_WAPO_GUARD_COMPARE_OWNERS` table does not name yet. Since 2026-11-24 the two anonymous transition guards
    (104 of the 152 compares measured 2026-11-22) are bounded by their traced unit instead,
    `ConfigTransitionGuardCompareBudget`: two per guard at its admission and first unproven check, two per guard
    and durable effect, none per journal read. Left: `check_write:ConfigMigrateBoot<ConfigSchemaCanPrepareWrite`
    (29, one per write-entry admission, `_ConfigSchemaEntryAdmitted` and `ConfigFullStateCanPersist`) and 19
    other compares, read from the `# api-save registry compares` lines of CI run 45495877427 (identical over its
    four single-save modes, doubled by the two-save ones): `check_write:ConfigMigrateBoot<Func.Prototype.Call` 1,
    `ClassifyImage<ConfigMigrateBoot` 2 per capture request and 1 per `prepare_owned` and `settle_owned`,
    `capture_*:ConfigMigrateBoot<_ConfigTransitionGuardedProductionPort` 1 (recovery) and 2 (transition),
    `prepare_owned:…<ConfigSchemaPrepareOwnedSource` 2, `settle_owned:…<ConfigSchemaSettleOwnedSource` 5 and
    `settle_owned:FinalAdmission<Func.Prototype.Call` 2. Left: count the `ConfigMigrateBoot` calls of each request
    apart from the reads, prove each owner's compares per call on a Windows run, then drop the ceiling.
  - The two Studio speed bounds (120 and 5000 table walks) rest on ratios measured with every core busy; read the
    ratio each test prints on a quiet PC and on CI, and set each bound to twice the highest.
  - Kept on purpose: order-of-magnitude bounds that state their reason (the Linux e2e 3000 tray rows against the
    former 103 058), loop-progress bounds a test chooses for its own loop, frozen historical references, corpus
    floors and non-vacuity floors.
- [ ] **The target's own paste can still lose to Windows' clipboard readers.** Since 7de36977ab (2026-11-22) the
      paste transport's leases (`CB_IsBusy`, the plain CAS and its authentication, the restore retry) outwait a
      reader of another process for `CB_PASTE_READER_WAIT_MS` (100 ms), a refused SendInstant publication is logged
      with the holder, and the payload carries the clipboard-history and cloud exclusion formats
      (`test_clipboard_reader_wait.ahk`); the TextSend payload (`CB_WriteTextWithReceipt`, LLM and diagnostics)
      carries them too since 2026-11-24 (`_CB_WriteTransientText`). Left: the application's own single
      `OpenClipboard` after Ctrl+V. explorer.exe, `cbdhsvc` and msrdc.exe (WSLg) still open the clipboard after
      writes, with or without the exclusion formats, and msrdc renders every delayed text format, so neither the
      formats nor a delayed-rendering receipt can prove the paste (a single open 0-140 ms after a write failed about
      1 time in 60-120), so that open stays the target application's own and no driver code can win it. The
      `gesture-transform-native-render-focus` and `wrap-native-render-focus` fixtures, which failed that way now
      and then (sends=1, Edit empty), paste through a known reader since 2026-11-25
      (`tests/fixtures/known_reader_paste_body.ahk`, A_Clipboard's retried open on the Edits' Ctrl+V); left: read
      their `known_reader_pastes=1` observation in the next Windows CI runs. macOS and Linux have no clipboard lock, so the race does not exist there; since
      2026-11-24 their paste payloads carry the clipboard-manager hints (`x-kde-passwordManagerHint` through the
      Linux multi-format owner, `test_clipboard_transient_hint.lua`; `org.nspasteboard.TransientType` and
      `ConcealedType` on macOS, `test_transient_markers.lua`), and the managers' own reading is a field check
      (`clipboard_manager_hint`).

## Full accessibility (maintainer request, 2026-11-16, very important)

The goal is a totally accessible project: the site (ergopti.fr), Ergopti Studio (editor, Comparer, Optimiser,
benchmarks) on the site and inside the app, and Ergopti+ itself (menus, windows, dialogs, tooltips, onboarding) on
Windows, macOS and Linux. Target WCAG 2.2 level AAA everywhere (maintainer, 2026-11-23: the latest WCAG, AAA on the
site, Ergopti+ and every app window); every new page or window is held to it from now on.

- [ ] **[CODE] AAA findings down to zero (maintainer, 2026-11-23).** axe-core's AAA rules (`wcag2aaa`,
      `wcag21aaa`, `wcag22aaa`, one list in `tools/test/lib/wcag-tags.cjs`) run in the site, Studio and app-window
      gates: any new finding fails CI. `color-contrast-enhanced` is at zero in both baselines since 2026-11-24
      (thirteenth pass of the [audit](docs/audits/accessibility/README.md)). The 44 px targets of 2.5.5, which axe's
      `target-size` (24 px) does not check, are measured by both gates themselves (`tools/test/lib/target-size.cjs`,
      rule `target-size-enhanced`, counted once per kind of target). Left: lower those rows to zero (220 kinds on the
      site and in its frames, 391 in the app windows' states; the public statement `/accessibilite`, which names AAA
      as the target, lists them among its known gaps until then). The tool survey and every AAA criterion no tool
      measures, with its check, are in [aaa-criteria.md](docs/audits/accessibility/aaa-criteria.md); those checks
      belong to the manual audit below. HTML_CodeSniffer's AAA errors (its own ratchet, fifteenth pass of the audit)
      now measure what axe skipped: the contrast it read as « NaN:1 » is measured through the browser's colours, and
      the real failures it then found (one-letter key chips, the typing dashboard's errors, chips and badges, the
      diagnostics' « checking ») hold 7:1. Left there, each a limit of the tool rather than of the page: contrast it
      cannot measure (SVG key labels over their key shapes, translucent layers over a gradient or an image), a
      release body's headings read at their level through `aria-level` (G141) and the model browser's row groups
      (`scope="rowgroup"`, H43).

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
      and the wizard, as the Windows and the inline hosts deliver them). The tray menus take the reading font too (maintainer decision
      2026-11-24): macOS restyles the titles in faces the launcher registers for the session, Windows owner-draws
      the rows, Linux cannot (dbusmenu carries no font) and its row says so; proof `test_reading_font_titles.lua`,
      `MenuFontRegistrationTests`, `test_menu_font.ahk`, `test-menu-font-faces.cjs`. Left: a look at
      the dyslexia font in a real window and tray menu on each OS (TODO-tests). The Studio's own strings are measured
      now (`npm run test:studio-plain-language`, WCAG 3.1.5 on the 21 locales' catalogue): English and French have no
      sentence of 30 words or more; left, the 315 rows the other 17 spaced locales still pin in
      `tools/test/studio-plain-language-baseline.json`, and a review of Japanese and Chinese, which a word count
      cannot measure.
- [ ] **Blind and low-vision users.** The Optimiser's result boards have a table view of their own (each key's
      place, what it types on both layouts, whether it changed). Heading order and landmarks are a gate
      (`tools/test/lib/heading-landmarks.cjs`: one h1, no skipped level, one main, every other landmark named): the
      three Studio pages in the Studio keyboard walk, which they pass, and the 21 app windows in their scan's
      ratchet, which they all pass since the apps dashboard's tabs became tab panels with their own headings
      ([tenth pass](docs/audits/accessibility/README.md#tenth-pass-semantic-markup-and-keyboard-operability-of-the-app-windows-2026-11-19-paris-time)).
      Left: screen-reader runs.
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

## Ergopti Studio

Design: [layout-editor.md](docs/design/layout-editor.md), [layout-analysis.md](docs/design/layout-analysis.md),
[analyser-scores.md](docs/design/analyser-scores.md), [layout-optimizer.md](docs/design/layout-optimizer.md); the
analyser study is [docs/audits/layout-analysers/report.md](docs/audits/layout-analysers/report.md) (its section 15
waits for the maintainer's review).

- [ ] **Layout formats, what is left (2026-11-19).** The ErgoDox model is complete (maintainer, « Complete the
      model »): 73 of the 91 files left out for its keys came in, the library holds 791 layouts
      (`docs/audits/layout-analysers/report.md` section 13, « Every ErgoDox key »). To review by the maintainer: the
      board-only codes and the Shift keys read as QMK's mod-tap (`docs/design/layout-analysis.md`, « ErgoDox keys »;
      the thumb rule was settled on 2026-11-21, « The left thumb types on one key »). Still in `not_imported`:
      KLAnext's VCKB and VCKB2 type a letter (d, l) on the ErgoDox's right 2-unit outer thumb key, the board's AltGr (a mod-tap code there, as the Shift keys' tapped characters
      have, would read it; each would still lack its « u », on the left thumb's second key).
- [ ] **[LATER] Layout library credits, what is left.** The credits were read on their authors' pages on 2026-11-17
      (`checked` and `evidence` in `layout_credits.json`). Still « knowledge »: QWERTY (US patent 207,559 is Sholes's,
      but its text names no letter order: read its drawings or another primary source) and KOY (neo-layout.org names
      no author, adnw.de has no page for it). The 53 « collection » credits come from KLA's « author » field, which
      can name the person who submitted the layout: check each against its author's page, first the doubtful ones
      (Klausler « Kaimakides »: deskthority's « Keyboard layouts » page names neither; CarpalxQ and QWERTY Wide Mod
      « Dave Ferree »: the CarpalxQ post, « jumpedthesynapse » 2007-07, names no author and credits Martin Krzywinski
      for « 75-85% of this layout »; Arensito, KLA's « Dave Ferree », at Håkon Hallingstad's pvv.ntnu.no page,
      which answered 502 on 2026-11-24). Neo 2 is credited from neo-layout.org's history since 2026-11-24.
- [ ] **[LATER] More Leipzig languages.** Google Books' French, English, German, Spanish and Italian 1-grams ship
      (`static/corpus/frequency/google_books`, pinned in `static/corpus/count_table_sources.json`). Left: Portuguese
      and Dutch (Leipzig `por_wikipedia_2021_1M` and `nld_wikipedia_2021_1M`, Google Books has no Dutch export) need
      a `layout_optimizer.language.<code>` string in the 21 locales and a library layout of the language before their
      corpus can be listed; then add each to `count_table_sources.json`, its register entry and corpus with a
      `title_key`, and run `tools/build/import-count-tables.cjs`.
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
      Mod3 on Caps Lock as its fifth level and lists Mod4 (`custom_modifier_not_in_xkb`); the Neo XKB export
      writes Mod3 and leaves Mod4 out since 2026-11-24 (Neo's dead key held only on Mod3+Mod4, `dead_belowdot`,
      refused it as `unbound_stateful_actions`: it is now listed in `unreachable_actions`); the Neo KLC export is
      still refused, « Caps Lock changes the roya column » (`buildModel` of
      `tools/codegen/lib/windows-keyboard-layout.cjs`): Mod3 takes the Roya bit on Caps Lock's scan code, but its layers
      list no `caps_lock` as optional, so Caps Lock with Mod3 falls back to the base key map, which a KLC column
      cannot hold. Listing `caps_lock` optional on the five level layers (as Neo behaves) passes that check and
      stops at the next one: « Backquote: Caps Lock types neither the base nor the Shift characters (SGCAP is not
      generated) ». The DLL package builds since 2026-11-24 (a chained dead key with an empty terminator typed
      `undefined`), without Mod3 and Mod4 (`no_windows_column`): `tools/lib/kbd-dll/source.cjs` gives a custom
      modifier no Roya, Loya or Kana bit as the KLC export does, and Mod4's AltGr, an E0 key, could not hold one. The real-machine check (a user
      tap-hold or remap on Caps Lock or AltGr against the held levels) is in the three TODO-tests files.
- [ ] **[RELEASE] Windows export step in native Lua.** The restricted host `windows/native/ergopti_lua_export.c`
      (pinned Lua 5.4.6, built by `tools/build/build_windows_lua_export.ps1` in package-windows) is done. Left: once a
      dev run builds « Windows / Build », commit its artifact `windows-lua-export-*` (`ergopti_lua_export.exe` and
      its `.json`) into `windows/vendor` with their `required` entries in `tools/build/windows_bundle_manifest.json`;
      then `test-windows-lua-export-identity.cjs` checks them and the Windows lane runs the byte-equality proof.

- [ ] **Other analysers, what is left (2026-11-24).** genkey and Oxeylyzer were rerun on their text corpora on
      2026-11-24 (`verify-analyser-scores.cjs --genkey`, `--oxeylyzer`: Score within 0.005 % and 0.0003 on average,
      docs/design/analyser-scores.md); both stay `close` for the word lists and the 12 count-table corpora (the
      trigrams' chain, no text to count from). keycraft (BSD-3, Go, its score scaled on its own layout set) needs its
      own run to be checked; shirolyzer's score is undocumented.
- [ ] **Layouts Wiki playground ideas, what is left (2026-11-25).** Done: the Comparer's « Pareto » and « Trace » tabs,
      their links, the movement table and the « Corpus words » drill-down (trace, worst n-grams, editor panel)
      (`docs/audits/layout-analysers/layouts-wiki-playground.md`, ranked shortlist). Left, in order: (2) corpus blends (done: up to three corpora by weight,
      built-in or the user's own texts and « Ma frappe », `E.blendNgrams`, kept with the conveniences, carried in the
      share link when every part is built-in); (3) magic and repeat keys: designed
      (`docs/design/magic-and-repeat-keys.md`), waiting for the maintainer's choice under « Maintainer decisions pending
      »; (4) saved layout versions in the editor beside undo (done: the editor's « Versions » tool, named snapshots kept
      in the workspace, compared key by key and restored as one undoable step); (5) task help (done: the Comparer's « Help » tab, the
      editor's « Help » tool and the Optimiser's folded help); (6) the movement cells' percentiles (done: « Place among the library » in « One layout »
      measures the library on request, one layout per slice, then every movement and rhythm cell carries its chip); (8)
      Kawalyzer's « Clever Keys » (context outputs) with item (3). Also done: the library grid's Boolean filter as the
      Comparer's « Values query » (`E.compileQuery`).

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
      do not restart a finished campaign without source drift or a new hypothesis. The
      [2026-11-19 census](docs/audits/platform-parity/2026-11-19-census/report.md) (`b90ad8de`: 190 areas, 108
      drifted, 69 never campaigned; 316 units, 99 never campaigned) ranks what is left. Its nine proposed campaigns
      and the timing engines are taken, each report under
      [docs/audits/platform-parity/](docs/audits/platform-parity/) naming its fixes and proof: secure-field
      detection, logger engines, managed Ollama runtime, tray adapters, update and download windows, pickers and
      prompts, metrics views, small native units, layout tool pages (the census report's ninth section) and timing
      engines. Every finding they opened is fixed or decided (`docs/memory/maintainer-decisions.md`). Left:
  - SFC-06 (Credential Manager inside `explorer.exe`): field path only, no fix possible by process name;
  - the Linux note's folder and dated choice (`platform_reason.take_note_settings_are_windows`, `not_yet`);
  - OLL-06, one Ollama readiness bound once the cold start is measured on a quiet PC (field checks); the unpacked
    sizes of `ollama_release.json` are provisional (three times the archive): run
    `node tools/build/pin-ollama-release.cjs --archives <folder> --write` in CI on the five pinned archives and
    commit its values, then keep its `--check` in the job that downloads them;
  - boot profilers, phase stats and perf counters, taken on 2026-11-24
    ([report](docs/audits/platform-parity/2026-11-24-boot-profilers/report.md)): BPF-01 (the Linux boot total,
    budget and snapshot count the load phase, spawn to ready as on Windows), BPF-02 and BPF-03 (macOS names a stage
    left open and writes one boot summary), BPF-04 on macOS (a second `begin()` or `complete()` raises, as on Linux)
    and BPF-05 (Windows logs the boot's process CPU) fixed, and BPF-04 on Windows since 2026-11-25 (a second
    `BootProfile_Begin()` or a second recorded completion throws, `test_boot_profiler_single_owner.ahk`, first verified by the next Windows CI run).
    Left: the Swift logger retention replay runs in macOS CI only;
  - the census's re-campaigns for drift: `shared/layouts` (with S29), `shared/core`, `shared/ui/layout_editor` and
    the `ai` areas, then the remaining never-campaigned units of its table in rank order.
- [ ] **[RELEASE] Windows/Linux feed-only update fallback.** Built: the Versions window's feed-only list installs the
      channel's newest release through its required detached signature on both (`feed-only-install` tests, throwaway
      key in `feed_install_vectors.json`); without a key every feed row keeps the no-details refusal. Left, at release
      time once `public_key_spki_base64` is provisioned: the step-4 check of
      [update-signing](docs/tooling/update-signing.md) (a real feed-only install on Windows and Linux, the log saying
      the signature verified, an older row refused), then enforcement `required`.

## Carried over from the 1.0.9 requests

- [ ] **Slowness, Windows boot.** The passes of 17 to 22 November cut the configuration, AI catalogue, JSON,
      InputHook table and logger redaction stages (`tools/dev/bench-ahk-startup.cjs`; each pass's figures are in
      `git log -p -- TODO.md`). The tray menu is built before readiness by decision (« Windows boot: keyboard before
      tray » in `docs/memory/maintainer-decisions.md`). Measured and left, largest first: the script parse, linear in
      code volume (about 0.18 ms per KB, 11.9 MB over 577 files; dead code is about 46 KB, so only a smaller include
      graph or a worker helps); hotstring registration, about 0.5 ms per cached row with its case variants and no
      single hotspot (« Trimming per-row work in the Windows hotstring registrars » in
      `docs/memory/rejected_proposals.md`); the two `.keylayout` parses, about 130 ms, interpreter cost per tag and
      attribute; each additional personal hotstring file, a full `TOML_ParseDocument` at discovery (60-120 ms for
      37 KB, kept for the menu's metadata questions) and about 140 ms of registration; the boot full save just after
      the ready line (`_SaveFullConfigDeferred`, about 990 Mcycles, measured once); the AI catalogue (deferring it
      means a lazy accessor for its 184 readers). The PC timings and the macOS field points `rerun_2026_11_02` and
      `main_thread_holds` are in the TODO-tests files.
- [ ] **[RELEASE] Before publishing.** On a quiet PC with no resident driver: the whole AHK suite,
      `npm run test:ahk-tray-rows-read-as-text`, every live check including `quit-over-a-log-flush`, the JS, macOS and
      Linux suites, and a Windows field report with a driver.

## Remaining code work

### Windows

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
  ([steps](docs/tooling/signpath-foundation-application.md)). Update assets: the key pair, the
  `UPDATE_SIGNING_KEY` secret and the public key are in place (2026-11-24); cut one `off` release and check both
  `.sig` files, then set `enforcement` to `required` alone in a commit ([steps](docs/tooling/update-signing.md)). The relay exe and the vendor binaries stay unsigned
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
      regeneration itself stays synchronous, see the rejected proposals).
- [ ] **One folder name for Ergopti on the three OS.** Remove the boot migration only once the maintainer's
      machines pass the checks of the TODO-tests files
      ([handoff](docs/tooling/one-folder-name-handoff.md)).
- [ ] **Item 31, owned Karabiner runtime** ([ADR 011](static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md),
      [handoff](docs/tooling/next-release-handoff.md)). After the maintainer's WP9 pass (`owned_runtime_wp9` in
      TODO-tests-macos.md), delete the shared mode and set the three macOS `follow_up` rows of
      `_shared/core/network/data/owned_runtimes.json` to done. [BLOCKED] on that pass.

### All drivers

- [ ] **Structure plan, phase 2** ([plan](docs/design/structure-plan.md), resume point
      [docs/plans/structure-migration-resume.md](docs/plans/structure-migration-resume.md)). S01 to S26 are on dev.
      Left: S27 (install) to S38, one step per commit with `tools/audit/structure/run-phase2.cjs`, two or three per
      push after a CI proof.
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
      collector, and follows it in the shared progress window (`_shared/ui/field_report/`; hosts
      `macos/diagnostics/ui/field_check/field_report_window.lua` over `field_report_progress.lua`,
      `linux/diagnostics/ui/field_check/field_report.lua`, `FieldReportWindow` in `field_report.ahk`): each step as it
      goes, Stop and the close box cancelling the run, then one report
      (`_shared/diagnostics/engine/field_check/field_report.lua`), its folder in Finder, Explorer or the file manager,
      the report on the clipboard and « Create a GitHub issue » (the shared runner's `report_field_run` on macOS and
      Linux, `HealthCheck_ReportFieldRun` on Windows: the bug form with the version, OS, driver and the run's evidence
      line, the redacted report on the clipboard); without a window the report opens in the one-click dialog. The
      real windows are the « Field report progress window » lines of the three TODO-tests files. The report holds the
      verdict counts, each step with its TODO-tests field points, the steps not run here with their reason (guided: a
      person; reload, AI downloads, diagnostics, signed install: the collector), the Tests rows run separately and the
      folder of the result files to attach to an issue. An installed Mac app or Windows driver starts its session on demand on `folder.macos`
      or `folder.windows` of the shared protocol. Left:
  - **Field points still without an automatic driver step.** Linux: done. The collector's four probe steps are now
    the daemon's field run step `field_setup` (check `setup`, `linux/diagnostics/engine/field_check/setup_check.lua`:
    `/dev/uinput` writable, an evdev node readable, the systemd user unit enabled, a polkit agent running, the
    compositor focus source ready), so the in-app run and the collector both decide `physical_acceptance` and
    `wayland_focus` by it. Windows: `TODO-tests-windows.md`
    carries no `field-point` ids and no `field_todo_coverage.json`, so its report would name steps only. macOS: every
    literal step has its `field_check.step.*` label; the ids built at run time (`host_<name>`, `server_<id>`,
    `tap_<name>`, `idle_timer_<n>`, `memory_region_<n>`, `menu_slowest_<n>`, `app_crash_<process>`) keep their code,
    whose suffix names the subject.

### Linux

- [ ] **[FIELD] Arch Linux, KDE Plasma 6 Wayland: « rien ne marche à part le tray » (Discord report, 2026-11-25).**
      User system: Arch, Plasma 6.8.3, Frameworks 6.32, Qt 6.12, kernel 7.3.5, ThinkPad X270 (HD 520), AppImage and
      the GitHub install, stable v1.0.9. Fixed on `fix/linux-arch-core-inactive-v2`: the AppImage carries its own
      LuaJIT lgi (their `lua-lgi` is a Lua 5.4 build); a tray launch of the AppImage now runs `install/launch.sh`,
      which asks once (pkexec) to create the `input` and `uinput` groups, install the uinput udev rule and load the
      module (AppRun used to skip it); each missing part stays as a 🔴 row at the top of the tray and as a notice that
      stays up (KDE dropped the timed one). Ask the user to rerun on the next dev prerelease, in this order. (a)
      Download the new `ErgoptiPlus-x86_64.AppImage`, make it executable, quit any running Ergopti+ and launch it
      from the file manager; one administrator prompt is expected: accept it. (b) If the tray then shows « Accès au
      clavier indisponible », log out and back in (group membership applies to new sessions), then relaunch. (c)
      Check that `adn ` typed in a text editor gives `ADN`, that Réglages and Statistiques open and that the tray has
      no 🔴 row; if one remains, click it and copy its text. (d) Send the logs folder `~/.local/state/ergopti/logs/`
      as a zip (each `[diagnosis] code=` line names a problem), the output of `id`, `ls -l /dev/uinput`,
      `lsmod | grep uinput` and `ls /etc/udev/rules.d/`, and the field report: tray « Débogage » › « Lancer le field
      report (tous les tests) », then « Copier » in its window. Its files are in `$XDG_RUNTIME_DIR/ergopti/field-run/`
      (`/run/user/<uid>/…`), which logout clears: copy them first. (e) For the GitHub install on the same machine,
      `pacman -Q lua51-lgi webkit2gtk-4.1 libayatana-appindicator` must list all three packages. Unproved here: the
      pkexec prompt under KDE's polkit agent, `sg` acquiring the new groups in the same session, and KWin Wayland's
      layout read (a failure shows « Disposition clavier non lue »).
- [ ] **[CODE] Windows and macOS silent-failure findings (audit of 2026-11-25), being fixed.** Windows on
      `fix/windows-silent-component-failures`: an error without WebView2 now stays on screen in a message box naming
      the errors file, the diagnostic is delivered as an HTML page in the browser, and a 🔴 tray row shows a failed
      `ergopti_nav_owner.dll`; none of it has run on Windows yet. The managed download failure was already a modal
      box. macOS on `fix/macos-silent-component-failures`: a red dot on the Hotstrings title while the keymap event
      tap cannot restart (`hotstrings/engine/expander/init.lua:2905-2945`), and an alert plus the HTML fallback when
      `hs.webview.new` fails (`menu/ui/builder/builder.lua:843`).
- [ ] **[CODE] Windows and macOS silent-failure findings (audit of 2026-11-25).** Windows: a runtime error without
      WebView2 is only a TrayTip (`diagnostics/ui/error_dialog.ahk:362-375`) and a managed download failure only a
      transient notice (`ui/download_window/init.ahk:78-82`): fall back to `Ui_MsgBox` naming the errors file;
      `HealthCheck_FormatPlain` (`diagnostics/ui/healthcheck/core.ahk:527`) has no caller although comments call it the
      WebView2-less fallback; no tray status row exists for a removed keyboard hook or a failed `ergopti_nav_owner.dll`
      (`ai/adapters/nav_event_owner.ahk:4971`). macOS: a keymap event tap that keeps failing to restart only logs an
      ERROR per second (`hotstrings/engine/expander/init.lua:2905-2945`) with no 🔴 title dot; a failed `hs.webview.new`
      leaves a menu click without effect (`menu/ui/builder/builder.lua:843`). Linux now has `component_status` for
      the same class.

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
      `configuration.ahk`, the pasted-report bound and the login-redirect budget of `issue_link.ahk`, and their
      tests (`report-readable`, `report-budget`, `report-body-budget`, `issue-link-corpus`, `test_configuration`)
      were reviewed from source against the Lua originals on 2026-11-24 (one divergence fixed: an exponent lost its
      second digit, `exponent-keeps-two-digits`), but no AutoHotkey ran: close on a green Windows run of them.

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
  - Linux: desktop-webview's COSMIC toplevel fake, « the worker kept running after the compositor finished » (run
    45119239568): its exit wait counted serve calls, which return at once on the closed socket; it is bounded in
    wall-clock time since 2026-11-24 (`tests/hardware/lib/child_exit.lua`); close once desktop-webview stays green;
  - Windows: the `config` group, including the config-transition timer custody (bound 2048,
    `test-windows-config-timer-custody-bound.cjs`) and one `run_llm_model_browser` watchdog on
    `model-browser-native-json` (43347126427, not reproduced; all four `config-*` groups, the bound check and
    `run_llm_model_browser.ahk` passed three times in a row locally on 2026-11-18, so only hosted runs are left).

## Maintainer decisions pending

Each question names the default kept meanwhile; an answer moves into the item or into
[maintainer decisions](docs/memory/maintainer-decisions.md).

- [ ] **What HTML_CodeSniffer's ratchet counts (decided by the agent on 2026-11-25, to review by the maintainer).**
      Its errors on an element the page does not render (inside a `hidden` screen, a closed dialog, a folded panel)
      are listed in the gates' reports, not counted: it judges such markup as if shown (an empty heading a script
      fills when its screen opens), axe skips it, and the state that shows the screen is scanned with it rendered.
      A contrast error on SVG text is counted as `.Unmeasured`: its glyphs are painted over sibling shapes the tool
      never sees. Kept meanwhile: both, proved by the app windows gate's self-check. The other choice is to count
      them and add a fixture state per hidden screen and a pixel check for SVG labels.

- [ ] **44 px targets in the app windows and the site (decided by the agent on 2026-11-25, to review by the
      maintainer).** The `target-size-enhanced` rows (WCAG 2.5.5, 220 kinds on the site, 391 in the app windows) are
      nearly all ordinary buttons, lists and fields 20 to 36 px tall. Zero means a 44 px minimum height and width for
      every control, which changes the look of every window and can overflow the windows of a fixed size
      (`apps.manifest.json`) on each OS. Kept meanwhile: the sizes as they are, held by the ratchet. Choose:
  1. **(recommended) A 44 px minimum in `theme.css` for every app window and in the site's stylesheet**, then the
     fixed window sizes raised where a window overflows, with a look at each window on the three OS.
  2. Raise the size one window at a time as each is next reworked.
- [ ] **Bug link login-redirect budget (decided by the agent on 2026-11-24, to review by the maintainer).** Measured
      anonymously on github.com (`tools/dev/measure-issue-url-limits.cjs`): `/issues/new` answers 500 from about
      6,460 bytes and `/login` from about 6,500, so a 4,000-byte link dense in `%XX` failed after the signed-out
      redirect encoded it again (6,670 bytes). Kept meanwhile: `max_url_bytes` 4,000 and a second budget,
      `max_redirect_bytes` 5,000 on the re-encoded redirect, which leaves about 1,500 bytes for a browser's own
      headers and cookies; a typical report's prefill is now cut a little earlier. Choose another redirect budget
      after a measurement from a signed-in and a signed-out browser, or raise `max_url_bytes` (letter-dense links
      reached 6,440 bytes) if a signed-in browser serves it.
- [ ] **Magic and repeat keys in the Studio's analysis (asked by the agent on 2026-11-25, to review by the
      maintainer).** The maintainer wants every idea of the Layouts Wiki playground and Kawalyzer, which analyse
      repeat, skip-repeat and magic (« Clever Keys ») keys; the decision of 2026-11-21 says « Studio shows layouts,
      not the magic key » (the ★ of Ergopti+). The design is written (`docs/design/magic-and-repeat-keys.md`: a
      layout's own repeat and magic keys, output-context rules of at most two characters, analysed as
      context-dependent ways of typing, emulated by the three drivers, kept apart from ★). Kept meanwhile: nothing
      built. Choose: (1) build it as designed, the analysis first; (2) analysis only, no driver emulation (the
      Studio then rates keys no Ergopti driver can type); (3) not now.
- [ ] **Analyser fidelity per corpus kind (decided by the agent on 2026-11-24, to review by the maintainer).**
      Rerun on 2026-11-24, genkey matches itself on the text corpora within its printed rounding and Oxeylyzer within
      0.0007, but `fidelity` (`analyser_models.json`) is one value per analyser and no page shows it. Kept meanwhile:
      both stay `close` (the word lists and count tables keep the trigrams' chain), the text-corpus result stated in
      docs/design/analyser-scores.md. The other choice is a `fidelity` per corpus kind, with genkey `exact` on texts.
- [ ] **[macOS] The same silent withholding on an unreadable AX focus (found by the agent on 2026-11-25).** When
      `AXFocusedUIElement` cannot be read, `hotstrings/engine/expander/utils.lua` leaves the secure-field cache
      unclassified and `expander/init.lua` withholds every hotstring in that application with a debug line only.
      Give it the Linux treatment (a window-mode admission outside a known secure field and password apps, and a
      red menu row for a lasting reason), checked on a real Mac.

## Backlog, far future: 100 % coverage and mutation gates (maintainer request, 2026-11-23, deferred 2026-11-24)

Not now (maintainer, 2026-11-24): « une todo lointaine, backlog ». A huge piece of work for later: measure line
coverage everywhere (every language, every driver), then make CI red below 100 % coverage and below 100 % killed
mutants. The per-file coverage ratchets kept on 2026-11-24 (Lua, JavaScript, Python) only stop a file from dropping;
no agent starts the items below without a new request.

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
