<!-- docs/audits/layout-analysers/ux-study.md -->

# UX study of the keyboard layout analysers

Written on 2026-11-19 (Paris time). This study complements the metrics and
scoring study ([report.md](report.md)). It looks only at the interface and the
workflow of each tool: how a layout is entered, which corpus is used, how the
results are shown, how the weights are tuned, how layouts are compared and how a
result is shared. It ends with a prioritised list of changes for Ergopti Studio
(Éditer, Comparer, Optimiser).

## Method and limits

- Each tool was opened in Microsoft Edge (Playwright, 1440 × 900 CSS px,
  light system theme) on 2026-11-19 between 01:00 and 01:25 Paris time, and
  used the way a visitor would: load a layout, change a key, run the analysis,
  open every result tab, import, share.
- Ergopti Studio was served from the working tree (branch
  `fix/windows-pc-2026-11-17`, commit `ff3ae37f98`) on `127.0.0.1:8820`. The page
  was `_shared/ui/layout_editor_window/index.html` with a fake host. The host
  answered `composer_open` from `static/layouts/registry`, `studio_corpus` by
  loading the generated corpus script, and the store and workspace messages
  with success. It was launched with `initData` (French strings, `studio_store`,
  `studio_workspace`) and with `sourceData` without text, so the Studio opened
  on its copy of Ergopti. The server was stopped afterwards.
- The timings are wall-clock times from one run on the maintainer's PC with
  other work running. They give orders of magnitude, not benchmarks.
- The accessibility notes come from looking at the pages and their controls.
  No axe-core scan was run on the competitors. Ergopti's pages already have
  CI scans (`tools/test/browser/site-accessibility.playwright.cjs`,
  `studio-keyboard.playwright.cjs`).
- The screenshots are not committed (64 PNG files, about 11 MB). They were saved
  in the session scratchpad,
  `C:/Users/admin/AppData/Local/Temp/claude/ffc41302772b147a/c6d7c23c-7ba7-4086-91b0-53d453d6f7d3/scratchpad/ux-study/`,
  which can be cleared. The file names below refer to that folder.
- Not opened: keymui and Oxeylyzer's desktop app (their README lists the
  features), a200 (a command-line tool; its repository was unreachable, so the
  description comes from its README excerpt), and Keysolve web (its GitHub Pages
  site returns 404). An "a200 screenshot" tool was searched for under that
  name; the only a200 found is ClemenPine's command-line analyser.

## 1. The tools

### 1.1 KLAnext (klanext.keyboard-design.com, v0.06)

Screenshots: `klanext-01-compare.png` to `klanext-08-misc.png`.

- **Layout input.** There are 12 layout slots with a pager (1 to 12). Each slot
  has a clickable, draggable keyboard (drag to swap, click to edit a key), an
  ANSI and a non-ANSI preset drop-down, Import and Export (a JSON text pasted
  into a modal), and a name field. "Generate image" renders the keyboard as a
  picture.
- **Corpus.** About 90 built-in texts in a grouped list box ("Quick tests",
  "Serious tests (slow)", Shakespeare's monkeys, code books, dictionaries,
  UDHR in 20 languages, random text). The size of each text is in its label
  ("(1M)"). Any text can be pasted into the large text area.
- **Results.** A trophy headline ("Best layout for … is …"), a sortable
  ranking table with "+Effort" (percentage behind the first), tabs Distance,
  Finger Usage (bar chart plus table), Consecutive Finger & Hand, Row Usage,
  Heat Maps (a grid of small keyboards with a heat blur) and Miscellaneous
  (character frequency table).
- **Weights.** None in the interface; the weighting is explained in one
  sentence (40 % distance, 40 % SFB, 20 % hand alternation).
- **Comparison.** The 12 slots are always compared together.
- **Sharing and export.** Export as JSON text; image of a keyboard.
- **Speed.** "Compare Layouts" on the default 12k-character text with 12
  layouts took 3.9 s to show the results.
- **Accessibility.** Canvas charts with no text alternative. The colour-only
  heat blur has no scale. A modal backdrop stayed over the page after the
  Import modal was closed and the route changed, which blocked every click
  until a reload.
- **Pleasant detail.** Each corpus option shows its size. The "Character
  Compatibility checker" field lists the keys that clash for a set of
  characters.

### 1.2 Keyboard Layout Analyzer (patorjk.com)

Screenshots: `kla-01-main.png` to `kla-04-results.png`.

- **Layout input.** 5 slots with a pager. Click or drag on the keyboard. A
  "Key Editor" popover sets the primary, Shift, AltGr and Shift+AltGr
  characters, the finger and the finger's home key, with an "i" next to each
  field. There are about 120 presets, Import and Export as JSON text, and
  "Submit Layout".
- **Corpus.** Three presets and a pasted text.
- **Results.** A ranking with the winner, tabs Distance, Finger Usage, Row
  Usage, Heat Maps, Miscellaneous and "Personalized" (a layout the tool derives
  from the text).
- **Weights.** None. The score formula is stated (33 / 33 / 34 %).
- **Sharing.** "Get URL to Share Results" builds a link that carries the
  layouts and the result.
- **Speed.** 2.2 s for 6 layouts on the Alice text.
- **Pleasant detail.** The per-key finger and home-position editor is fast to
  understand.

### 1.3 Spray's KLA fork (nsuspray.github.io/keyboard-layout-analyzer)

Screenshots: `spray-01.png`, `spray-02-layouts.png`.

- **Layout input.** As KLA, plus keyboard forms (ANSI, ISO, ISO split-space,
  Matrix, Ergodox), quick buttons for QWERTY, AZERTY, Dvorak, Colemak and
  Colemak-DH, rotate and shift arrows, and Copy, Paste and Export.
- **Corpus.** About 20 presets in groups, a text area, "Enrich" buttons (EN,
  RU), a punctuation simplifier, an option to keep control keys, and
  auto-indent emulation (none, basic, IDE) for code.
- **Weights.** All of them on one page: a ratio of the five factors, hand
  approach angles, per-finger effort vertically and horizontally, a balancing
  method, and a "Similarity" factor (transition effort from QWERTY by layer,
  row, finger and hand). Presets (Spray, SteveP, PAT or JK) fill everything at
  once.
- **Pleasant detail.** The "Similarity" factor scores how hard the switch from
  QWERTY is, next to ergonomics ("Ergonomics vs Difficulty").

### 1.4 Ergo-L analyser (ergol.org/stats)

Screenshots: `ergol-01-stats.png`, `ergol-02-stats-full.png`.

- **Layout input.** One `x-keyboard` web component and four small selects:
  layout (grouped en, fr, fr.contrib, fr.nonfree), layers (Typo, Typo+Symboles,
  Symboles), geometry (ISO, ANSI, 60 %, 1DFH) and corpus (en, en+fr, fr). There
  is no editing and no import.
- **Corpus.** Three choices.
- **Results.** Every view is on one page, with no tabs and no button: finger
  load as stacked bars (one colour per layer), SFU and SKU per finger, then
  four "top" columns (SFU, LSB, scissors, wide scissors; SKU and rolls;
  trigrams SKS, SFS, redirects, bad redirects), each with "show more".
- **Weights.** None by design: an "Évaluation" section says there is no global
  score and names the five criteria to read. A "Mise en garde" quotes
  Goodhart's law.
- **Speed.** The page is ready in 1.8 s and redraws as soon as a select
  changes.
- **Pleasant detail.** The "zone de saisie" above the keyboard lets the visitor
  type and see each key light up on the chosen layout.

### 1.5 Cyanophage (cyanophage.github.io)

Screenshots: `cyanophage-01-playground.png` to `cyanophage-09-table.png`.

- **Layout input.** A compact 3 × 11 board plus thumbs. Drag a key onto another
  to swap them; "Edit" makes the keys text fields. "import" takes one line of
  characters. The layout, the mode, the language and the thumb are in the URL
  (`?layout=qwertyuiop-asdf…&mode=ergo&lan=english&thumb=l`), and the URL
  changes on every swap.
- **Corpus.** 14 languages in a drop-down, and "corpus" to paste your own text.
- **Results.** One dark dashboard, all visible without scrolling at 1440 ×
  900: finger usage, finger distance, column and row usage, SFB, skip
  bigrams, lateral stretch and scissors (each with its total and a sortable top
  11 with bars), a finger-to-finger matrix, same-hand strings, same-hand count,
  "Hard Words" and trigram stats.
- **Comparison.** The index page has a card per layout and "Sort by SFB /
  Effort / Skip Bigrams / Lat Stretch", a "table" page (19 metric columns for
  every layout) and "Compare Selected".
- **Speed.** Ready in 1.5 s. A drag swap updated every number in under 0.4 s.
- **Accessibility.** Drag only, no labels on the key fields, a dark theme
  only, 10–11 px text.
- **Pleasant detail.** The live URL is the save file: copying the address bar
  shares the exact state.

### 1.6 Oxey's Layout Playground (oxey.dev/playground) and Oxeylyzer

Screenshots: `oxey-01-playground.png`, `oxey-02-playground-full.png`.

- **Layout input.** A 3 × 10 board plus a thumb row, drag-and-drop swaps, and
  right-click to exclude a key from the analysis. There is a "search layout…"
  field.
- **Corpus.** 37 languages and variants (English, French, French Qu, Toki
  Pona, Korean, e200, 450k…).
- **Results.** Two text panels: finger usage, hand and centre-column usage,
  home-key usage, SFB per finger, then SFB, DSFB, LSB, rolls, alternates,
  redirects, bad redirects and invalid.
- **Speed.** About 3.9 s to load (the analyser is compiled to WebAssembly),
  then instant on each swap.
- **Oxeylyzer desktop (Tauri, from its README).** Analyze (a heatmap; click a
  bigram to highlight its keys; disable keys on the fly), Compare (two layouts
  in a diff view), Generate (iteration count, pinned keys, results streaming
  in, each one saved directly), Edit (raw DOF JSON, rename, swap, fork under a
  new name), Language (switch and load corpora) and Config (every weight in a
  form, presets saved and loaded).

### 1.7 Layouts Wiki playground (layouts.wiki/playground)

Screenshots: `layoutswiki-01-layout-page.png` to `layoutswiki-07-compare.png`.

- **Layout input.** A workspace selector, then MAIN and COMP layout pickers
  with type-ahead search over about 300 layouts (author and year in each row),
  and "New layout".
- **Corpus.** One picker in two parts: corpus (Monkeyracer, Reddit, Wordfreq,
  each with a one-line description) and alphabet (letters; letters, comma and
  period; common punctuation; printable US ANSI).
- **Results.** Dockable panels (Browse, Inspect, Metrics) that can be added,
  maximised and closed. The Browse panel is a sortable table (SFB, SFS, Alt,
  Roll, Redir, Weak) with Search and Query modes and a "Hide incompatible
  layouts" filter. Inspect draws every layer with layer activators and
  keysets. Metrics shows "Movement & Rhythm" or "Finger Usage" (editable metric
  views): bigram and skipgram columns, each value with its **percentile among
  all layouts** (P70, P93…) on a green-to-red ground.
- **Speed.** The metric panel showed "Updating…" for more than 10 s on the first
  load; later changes were fast.
- **Accessibility.** React Aria controls (keyboard reachable, named), a
  dark/light/auto theme switch, but dense 11–13 px text.
- **Pleasant detail.** The percentile next to each value answers "is 2.8 %
  good?" without any score.

### 1.8 Alt Alpha (altalpha.timvink.nl)

Screenshots: `altalpha-01.png`, `altalpha-02-try-layout.png`.

- **Results.** A sortable table of 165 layouts with cyanophage's metrics, a
  search field, language and keyboard type selects, a thumb-key filter, layout
  families grouped and expandable ("Family: hanster (8)"), a pin and a star on
  each row, filter, columns and share buttons, and a dark-mode toggle.
- **Weights.** Score presets (Balanced, Low Pinky, Comfort, Custom) with a
  short description of each metric and "How is the score calculated?".
- **Try a layout.** "You can touch type [qwerty] and want to experience typing
  in [gallium v2]": a Monkeytype-style drill (punctuation, numbers, time, word
  counts 10–100, "english 1k") that maps the keys you press to the target
  layout, with words, errors and WPM.
- **Pleasant detail.** Families folded by default keep the table short;
  pinning keeps one's candidates at the top while sorting.

### 1.9 Keyboard Layout Optimizer (Dario Götz)

Screenshots: `dariogoetz-01-evaluator.png` to `dariogoetz-04-layout-database.png`.

- **Layout input.** Preset buttons (noted, mine, bone, neo2, koy, AdNW, qwertz,
  colemak, workman, qwerty, random) and a one-line layout string
  (`k.o,yvgclfzßhaeiudtrnsxqäüöbpwmj`), with keyboard types Standard, Ortho,
  Moonlander, Corne, Lily58 and ANSI.
- **Weights.** Settings tabs Evaluation, Ngrams, Keyboard and Optimization,
  each a YAML editor with comments, line numbers and Save.
- **Results.** A text report per metric ("14.86 Finger Balance | Finger loads
  …"), with Evaluate, Optimize (in the browser) and "Publish".
- **Database.** keyboard-layout-optimizer.fly.dev lists the published layouts
  with their cost, sortable, with "only show best in family". The page took
  more than 30 s to finish loading.
- **Pleasant detail.** "Publish" turns a found layout into a shared row of a
  community table.

### 1.10 Keyboard-design.com tools and Keyboard Layout Try Out

Screenshots: `keyboarddesign-02-illdb.png`, `tryout-01.png`.

- The Internet Letter Layout DB is a large sortable, searchable table of
  layouts, each named `name.language.format`, each with a KLA JSON and an
  image. The tools page also lists the "most similar to QWERTY / Dvorak /
  Colemak / Canary" pages.
- Keyboard Layout Try Out converts a word list (200 to 10,000 words) from the
  current layout to a layout to try, with options to omit words typed the same
  way on both layouts, then a typing drill.

### 1.11 keymui, a200 and genkey (from their READMEs)

- keymui (semilin): a desktop GUI in Rust and Iced. Metrics are imported from
  km_metrics, any metric has n-stroke lists, and layout development is a tree.
  A web version is on its roadmap.
- a200 (ClemenPine): a command line (`./a200 view colemak semimak`, sort by a
  metric with percentage weights, filter by cut-offs, corpora from `data/`,
  themes, saved configs). The output is coloured terminal tables.
- genkey (semilin): a REPL with `analyze`, `rank`, `generate`, `improve`
  (better swaps for a given layout) and `heatmap` (PNG).

## 2. Ergopti Studio today

Screenshots: `ergopti-01-edit.png` to `ergopti-15-171-layouts.png`.

- **Éditer.** Layout tabs ("Mon Ergopti", +, "Tous les onglets sont enregistrés
  sur cet appareil", Importer…), a toolbar (Nouvelle, Ouvrir…, Enregistrer,
  Annuler, Rétablir, Fermer), layer buttons (Base, Maj, AltGr, Maj + AltGr,
  Verr. Maj, Maj + Verr. Maj, Ctrl, Raccourcis, Gérer les couches…), a system
  scope, the keyboard form (ISO, ANSI, JIS, ABNT) and size (100 % to 60 %).
  The full-size keyboard is coloured by score. Drag swaps keys, Ctrl+drag
  copies, a "Échanger avec la touche" select does it without dragging (WCAG
  2.5.7), and Ctrl+C and Ctrl+V copy a key. The key panel has the Unicode
  palette, a character magnifier, key properties, physical remapping,
  shortcuts and tap-hold. Below are « Essayer », the analysis panel (corpus,
  keyboard, key colours, rank among the library, 20 metrics with their change
  since the last analysis, the fingering, eleven other analysers' scores) and
  tools (details, layers, modifiers, dead keys, fill from a layout, navigation
  layer, Windows options, export, stickers).
- **Comparer.** "Copier le lien", corpus (language, text type, about 45
  corpora with size, licence and source), text typed (keys, final text,
  final text with « + » layouts), keyboard and size, the layout list with
  filters (name, family, origin, language, completeness, score range), then
  tabs Vue d'ensemble, Doigts et mains, Bigrammes, Trigrammes, Rangées et
  distance, Cartes de chaleur, Couverture et autres, Autres analyseurs and Une
  disposition, and the score settings at the bottom.
- **Optimiser.** Three numbered cards (1 Corpus et départ, 2 Ce qui peut
  bouger, 3 Lancer la recherche), pinned keys, Ctrl shortcuts and zones on a
  keyboard, a score settings summary with "Les modifier dans Comparer", budget
  and seed, a live best layout against the start (changed keys dotted) and a
  table of metrics with their changes, then "Ouvrir dans l'éditeur" and
  "Comparer avec d'autres dispositions".
- **Measured speed.** The window was ready with its analysis in 3.6 s. A drag
  swap changed the score in 0.84 s on Don Quichotte (1,949,220 characters).
  The Comparer analysed 7 layouts in 113 ms and 171 layouts in 1,033 ms (its
  own count), 2.3 s from the click to the redraw. The Optimiser evaluated
  22,447 layouts in 23 s from AZERTY on Swann, about 1,000 per second.

### Defects seen during the study

These are bugs in the current page, not design choices. Each one is also an
item of section 6.

1. On the first render, the analysis panel compares the layout with an empty
   one. Every metric shows its full value as a change ("+1,00 ▼" on SFB,
   "−100,00 ▲" on unsupported characters, "+480" distinct characters)
   (`ergopti-01-edit-full.png`). `state.previous` in `analysis_panel.js` holds
   the metrics of the empty board drawn before the Ergopti copy arrived.
2. The "Tapé via" table shows raw dead-key identifiers to the user:
   `touche morte [s1_circumflex] ★`, `[s1_circumflex] [s1_circumflex] d`.
   This appears in the editor panel and in Comparer › Une disposition.
3. Comparer › Une disposition › Toutes les mesures: the "Raccourcis à la main
   gauche" row has two "i" buttons.
4. The editor has no keyboard shortcut for Undo and Redo. Only the buttons
   work; `editor_page.js` handles only Ctrl/Cmd+C and V on a focused key.
5. In the editor, "Importer…" (tabs) accepts `.toml,.keylayout,.zip`, while
   "Ouvrir…" accepts all ten `LAYOUT_FORMATS.EXTENSIONS`. A KLA JSON or a
   Kalamine TOML can be opened but not imported as tabs.
6. A layout imported in the Comparer cannot be removed or renamed. The host
   offers `studio_layout_remove`, but no page code calls `HOST.store.remove`,
   so the "Mes dispositions" list only grows.
7. "Copier le lien" leaves out every personal layout, the edited one included
   (`SHAREABLE_ORIGINS`). A link to "my layout against Ergo-L" opens without
   "my layout".

## 3. Feature table

Legend: ● full, ◐ partial, ○ absent, — not applicable.

| Feature                           | Ergopti Studio    | KLAnext   | KLA   | Spray | Ergo-L | Cyanophage | Oxey PG  | Layouts Wiki | Alt Alpha | Götz |
| --------------------------------- | ----------------- | --------- | ----- | ----- | ------ | ---------- | -------- | ------------ | --------- | ---- |
| Edit keys on a board              | ●                 | ●         | ●     | ●     | ○      | ●          | ●        | ◐            | ○         | ◐    |
| Drag-and-drop swap                | ●                 | ●         | ●     | ●     | ○      | ●          | ●        | ○            | ○         | ○    |
| Swap without dragging             | ●                 | ◐         | ◐     | ◐     | —      | ○          | ○        | —            | —         | ◐    |
| Four levels and dead keys         | ●                 | ◐         | ◐     | ◐     | ●      | ○          | ○        | ●            | ○         | ◐    |
| Undo and redo                     | ◐ (buttons)       | ○         | ○     | ○     | —      | ○          | ○        | ?            | —         | ○    |
| Import layout files               | ● (10 formats)    | ◐         | ◐     | ◐     | ○      | ◐          | ○        | ?            | ○         | ◐    |
| Paste a layout as text            | ○                 | ●         | ●     | ●     | ○      | ●          | ○        | ?            | ○         | ●    |
| Built-in corpora                  | ● (~45)           | ● (~90)   | ◐     | ●     | ◐      | ● (14)     | ● (37)   | ◐            | ●         | ◐    |
| Own text or file as corpus        | ●                 | ●         | ●     | ●     | ○      | ●          | ○        | ○            | ○         | ?    |
| Own typing as corpus              | ●                 | ○         | ○     | ○     | ○      | ○          | ○        | ○            | ○         | ○    |
| Heatmaps                          | ●                 | ●         | ●     | ●     | ◐      | ◐          | ◐        | ●            | ○         | ○    |
| Top n-gram lists                  | ◐ (folded)        | ○         | ○     | ○     | ●      | ●          | ○        | ○            | ○         | ◐    |
| Percentile against a library      | ○                 | ○         | ○     | ○     | ○      | ○          | ○        | ●            | ○         | ○    |
| Tunable weights                   | ●                 | ○         | ○     | ●     | —      | ○          | ○        | ◐            | ◐         | ●    |
| Weight presets                    | ○                 | ○         | ○     | ●     | —      | ○          | ○        | ○            | ●         | ○    |
| Many layouts ranked               | ● (171)           | ◐ (12)    | ◐ (5) | ◐     | ○      | ●          | ○        | ●            | ●         | ●    |
| Families, pins                    | ◐ (family filter) | ○         | ○     | ○     | ○      | ○          | ○        | ○            | ●         | ◐    |
| Two layouts head to head          | ●                 | ○         | ○     | ○     | ○      | ◐          | ○        | ●            | ○         | ○    |
| Other analysers' scores           | ●                 | ○         | ○     | ○     | ○      | ○          | ○        | ○            | ○         | ○    |
| Optimiser in the browser          | ●                 | ○         | ○     | ○     | ○      | ○          | ○        | ○            | ○         | ●    |
| Share link with the layouts       | ◐ (library only)  | ○         | ●     | ○     | ?      | ●          | ○        | ?            | ●         | ◐    |
| Image or CSV export               | ○                 | ● (image) | ○     | ○     | ○      | ○          | ○        | ?            | ○         | ○    |
| Export to OS layout files         | ●                 | ○         | ○     | ○     | ○      | ○          | ○        | ○            | ○         | ○    |
| Typing drill on the target layout | ◐ (Essayer)       | ○         | ○     | ○     | ◐      | ○          | ○        | ○            | ●         | ○    |
| Live update without a button      | ●                 | ○         | ○     | ○     | ●      | ●          | ●        | ●            | ●         | ○    |
| Dark theme                        | ●                 | ○         | ○     | ○     | ○      | ● (only)   | ● (only) | ●            | ●         | ○    |
| 21 locales                        | ●                 | ○         | ○     | ○     | ○ (fr) | ○          | ○        | ○            | ○         | ○    |

"?" means not checked in this session.

## 4. What each tool does better than Ergopti Studio

- **Cyanophage.** The whole result fits on one screen next to the board, so a
  swap and its effect are seen together. The URL is the state, layout
  included. Every metric shows its worst n-grams at once.
- **Layouts Wiki.** A percentile against every known layout makes each number
  meaningful without a score. Its MAIN and COMP pickers keep the comparison
  frame at the top of the page, and its corpus picker describes each corpus in
  one line.
- **Alt Alpha.** Weight presets with plain names, families folded in the
  ranking, pins, and a typing drill that maps the visitor's current layout to
  the target one.
- **Ergo-L.** No-button live redraw, layered stacked bars (the share of each
  finger's load that comes from Shift or AltGr) and a clear statement of what
  the numbers do not say.
- **Oxeylyzer GUI.** Clicking a bigram highlights its keys, keys can be
  excluded on the fly, the generator streams its results and each one can be
  saved, and a layout can be forked under a new name.
- **KLA and KLAnext.** A one-click "image of this keyboard", and a paste-in
  JSON import and export with no file involved.
- **Spray's fork.** A "difficulty from QWERTY" factor next to ergonomics.
- **Götz.** "Publish" turns a result into a community row; "best in family"
  filters near-duplicates.

## 5. Import formats and layout editing against the competitors

### Import formats

| Format                                   | Ergopti Studio           | Competitors that read it      | Gap                                              |
| ---------------------------------------- | ------------------------ | ----------------------------- | ------------------------------------------------ |
| Ergopti TOML source                      | ● read, write            | —                             | —                                                |
| macOS `.keylayout`                       | ● read, write            | none                          | —                                                |
| Windows KLC                              | ● read, write (app host) | none                          | —                                                |
| XKB symbols                              | ● read, write (app host) | none                          | —                                                |
| Kalamine TOML and JSON                   | ● read, write            | Ergo-L site (its own layouts) | —                                                |
| KLA and KLAnext JSON                     | ● read, write            | KLA, KLAnext, Spray (paste)   | Paste as text is missing                         |
| Oxeylyzer DOF                            | ● read, write            | Oxeylyzer                     | —                                                |
| genkey layout                            | ● read, write            | genkey                        | —                                                |
| cmini JSON                               | ● read, write            | cmini                         | —                                                |
| Plain rows of characters (`.txt`)        | ● read                   | cyanophage, Götz (one line)   | Only as a file; a pasted line or URL is not read |
| KbdEdit `.kbe`                           | refused (encrypted)      | none                          | — (maintainer decision)                          |
| Cyanophage URL (`?layout=…`)             | ○                        | cyanophage                    | Not read                                         |
| Götz one-line string (32 characters)     | ○                        | Götz                          | Not read (its key order is not the rows order)   |
| a200 / Keysolve JSON                     | ○                        | a200, Keysolve                | Not read (close to cmini; check the schema)      |
| keyboard-layout-editor (KLE) raw data    | ○                        | KLE, Keyboard-design.com      | Not read (legends only, no levels: lossy)        |
| QMK `keymap.json`, ZMK `.keymap`, kanata | ○                        | none of the analysers         | Not read (firmware keymaps)                      |
| Layouts Wiki export                      | ?                        | Layouts Wiki                  | Not checked                                      |

Ergopti already reads more formats than any other tool. What it lacks is the
quick paths: pasting a JSON or a line of characters, a URL from another tool,
and dropping a file on the page.

### Layout editing

| Capability                                      | Ergopti Studio                            | Best competitor                   |
| ----------------------------------------------- | ----------------------------------------- | --------------------------------- |
| Rename                                          | ● name field in Détails                   | Oxeylyzer (rename in the list)    |
| Rename from the tab                             | ○                                         | Layouts Wiki (workspace names)    |
| Duplicate the open layout                       | ○ (only "Nouvelle" from a library layout) | Oxeylyzer "fork under a new name" |
| Edit a library layout from the Comparer         | ○                                         | cyanophage "Edit" on each card    |
| Remove or rename an imported Comparer layout    | ○ (defect 6)                              | KLA slots (overwrite)             |
| Undo and redo shortcuts                         | ○ (defect 4)                              | none of the tools tested          |
| Swap by drag, copy by Ctrl+drag, swap by select | ●                                         | ours is the most complete         |
| Exclude a key from the analysis                 | ○                                         | Oxey playground (right-click)     |
| Pin keys before optimising                      | ● (Optimiser)                             | Oxeylyzer                         |
| Best single swaps for this layout               | ○                                         | genkey `improve`                  |

## 6. Prioritised improvements for Ergopti Studio

These items leave out the work already planned: the corpus picker merge, the
tabs on top with Accueil, the icons and colours on tabs, the layout list search
with letter groups, number formatting with NBSP and units, the compact headers
with tooltips, the score settings sections, the import and export of score
settings, and the similarity card in the Optimiser. Each item gives the page
area, the change and why. P1 items are defects or blockers of the core
"edit, see, compare" loop. P2 items are the competitors' best ideas. P3
items are polish.

### P1: fix and unblock

1. **Éditer › Analyse de la disposition: no change column against an empty
   layout.** Reset `state.previous` when the layout changes identity (open,
   `startFrom`, tab switch), not only when the corpus or keyboard changes. Do
   not show changes until a second analysis of the same layout. Why: on first
   open every metric shows a false change (defect 1). Add a regression test
   that mounts the panel on an empty board, then a layout, and expects no
   change cell.
2. **Éditer and Comparer › "Tapé via": readable dead-key names.** Format the
   dead-key steps with the shared `KEY_LEGEND` formatter (bare accent plus its
   locale name), never the source id `[s1_circumflex]`. Why: raw identifiers
   reach the user (defect 2), against the shared legend decision.
3. **Comparer › Toutes les mesures: one "i" per row.** Remove the second info
   button of `left_hand_shortcuts`, and add a gate that counts one
   `INFO.button` per metric row. Why: defect 3, and a duplicate control for
   screen-reader users.
4. **Éditer › toolbar: Ctrl/Cmd+Z and Ctrl/Cmd+Y (and Cmd+Shift+Z) for Undo
   and Redo.** Handle them on the editor root when the focus is not in a text
   field (a text field keeps its own undo). Show the shortcut in the buttons'
   accessible name and title. Why: defect 4; every editor has them, and a
   swap-heavy workflow needs them.
5. **Comparer › Dispositions › Mes dispositions: Rename, Duplicate and
   Remove.** Add a row menu or three buttons on personal layouts that call
   `HOST.store.save` and `HOST.store.remove` (already offered by the host on
   the three OS and by the site's IndexedDB store). Removing offers « Annuler »
   through `undo_offer.js`. Why: defect 6; imported layouts pile up forever.
6. **Éditer › "Importer…": accept the same formats as "Ouvrir…".** Use
   `LAYOUT_FORMATS.EXTENSIONS` plus `.zip` for `le-tabs-import-file`, and
   convert non-TOML files through the same reader as "Ouvrir…". Why: defect 5;
   two pickers with different rules confuse users.
7. **Éditer › above the board: a sticky score chip.** Show "Score 27,4 · rang 3
   sur 171" and the change of the last edit ("−2,0 après é ↔ a") in a small
   bar that stays visible while the page scrolls. It opens the analysis panel
   on click. Why: after a swap, the result is about 600 px below the board;
   cyanophage and the Oxey playground show the effect next to the keys.
8. **Comparer › "Copier le lien": carry personal layouts.** Encode each
   personal layout chosen for the link (its four levels and dead keys, as the
   KLA JSON writer already does) compressed in the URL fragment
   (`#l=<base64url>`), so it never reaches a server. Read it back as a
   personal layout marked "from a link". Keep the current query for library
   layouts and warn when the link passes 8 KB. Why: defect 7; a share link
   without the shared layout defeats its purpose (cyanophage and KLA put the
   layout in the URL).

### P2: adopt the competitors' best ideas

9. **Comparer › tables and Éditer › analysis panel: percentile against the
   library.** Next to each metric value, show "P70" (share of the library's
   complete layouts that do better), computed from the 171-layout analysis
   the panel already runs ("Classer parmi toutes les dispositions"). Use the
   existing green-to-red scale, with the number spelled out for colour-blind
   users. Why: Layouts Wiki's best idea; it answers "is 0.73 % SFB good?"
   without the global score.
10. **Comparer › Vue d'ensemble: worst n-grams visible.** Under the score bars,
    show for the detailed layout the top 8 SFB, SFS, LSB, scissors and
    redirect n-grams with their share and a "Voir plus" link (today folded in
    Une disposition › Pires paires et trigrammes). Why: Ergo-L and cyanophage
    lead with them; they tell the designer what to fix.
11. **Éditer and Comparer › n-gram lists: highlight the keys.** Hovering or
    focusing an n-gram row outlines its keys on the board or heatmap (same
    finger in one colour, the motion as an arrow). Why: Oxeylyzer GUI; it turns
    a list into a location on the board.
12. **Éditer › analysis panel: "Meilleurs échanges" (best swaps).** A button
    runs the optimiser core in its Worker for the 10 single swaps (and 10
    three-key cycles) that most improve the score under the current settings
    and pins. Show them as "é ↔ a +1,8". A click applies one, with Undo. Why:
    genkey `improve`; the shortest path from "my layout" to "a better layout",
    with the search machinery already in place.
13. **Comparer › Réglages du score: named presets.** Offer built-in presets
    ("Équilibré", "Auriculaires ménagés", "Roulements", "Code") and user
    presets saved under a name. This builds on the planned import and export
    of score settings, which gives the file format. Why: Alt Alpha and Spray;
    the 40-odd weights are hard to tune one by one.
14. **Comparer › Classement: families folded and pinned rows.** Group the
    variants of one family (the family filter data already exists) into one
    row with its best member, expandable. Add a pin toggle per row that keeps
    the row at the top under any sort, saved in the page's local preferences.
    Why: Alt Alpha and Götz's "best in family"; 171 rows of variants bury the alternatives (the library holds 6 Tarmak and about 15 Colemak variants).
15. **Éditer and Comparer: paste or drop a layout.** Add a "Coller une
    disposition" text area (in the Importer… dialog and the Comparer's
    "Ajouter une disposition") that reads KLA JSON, a cmini or DOF JSON,
    Kalamine TOML, a line or rows of characters, and a cyanophage URL. Accept
    a file dropped anywhere on the Studio, with the same reader and the same
    loss report. Why: KLA, KLAnext and cyanophage import by paste; downloading
    a file first is the slow path today.
16. **Comparer › each heatmap and table: image and CSV export.** Add
    "Télécharger l'image (PNG/SVG)" on each heatmap card and keyboard (serialise
    the SVG or DOM keyboard, through the host's `saveFile` in the app), and
    "Télécharger le tableau (CSV)" on Classement with the visible columns. Why:
    KLAnext's "Generate image" is how layouts reach Reddit and Discord; CSV
    lets users chart their own comparisons.
17. **Optimiser › Lancer la recherche: progress chart and a results shelf.**
    Draw the best score over time (a small sparkline with the evaluations per
    second), and keep the 5 best distinct layouts found, each with "Ouvrir
    dans l'éditeur" and "Ajouter au Comparer". Why: Oxeylyzer streams its
    results; today only the current best is kept and it is hard to tell
    whether the search is still improving.
18. **Optimiser › Corpus et départ: start from the open layout.** When the
    Optimiser is opened from the Studio, preselect the active editor tab as
    the starting layout (today the default was AZERTY while "Mon Ergopti" was
    open). Add "Optimiser cette disposition" in the editor's analysis panel.
    Why: the expected flow is edit, then improve; the Comparer already lists
    the editor's tabs (`editor_…` ids).
19. **Comparer › Classement and heatmaps: "Modifier" on a library layout.**
    Open the layout as a new editor tab named "<name> (copie)". Why:
    cyanophage's per-card "Edit" and KLA's preset-then-edit; today the user
    has to find the same layout again in « Nouvelle ».
20. **Éditer › layout tabs: Duplicate and rename in place.** A double-click
    (or F2) on a tab renames it, and its context menu (and a keyboard-reachable
    "…" button) offers Dupliquer, Renommer, Fermer. Why: Oxeylyzer's fork;
    trying a variant without losing the original is the most common move.

### P3: polish

21. **Comparer › page layout: results within the first screen.** After the
    first analysis, collapse the Corpus, Texte et clavier and Dispositions
    cards into one summary line ("Don Quichotte · ISO TKL · 7 dispositions ·
    Modifier") and make the result tab bar sticky under the Studio tabs. Why:
    at 1440 × 900 the results begin about 690 px down; cyanophage and Ergo-L
    put results first. This complements the planned compact headers.
22. **Comparer › analysis off the page thread.** Run `LAYOUT_ANALYSIS` for the
    Comparer in a Worker (the Optimiser already uses one) and keep the
    previous results visible with a "Mise à jour…" mark. Why: 171 layouts
    took 1.0 s of engine time and 2.3 s from click to redraw. A long task of
    that length blocks typing in the filter fields. Measure the long tasks
    first.
23. **Éditer › « Essayer »: a guided drill.** Add an optional word drill
    (Lexique or subtitle words, 25, 50 or 100 words) with WPM and errors, the
    keys pressed mapped to the edited layout as « Essayer » already does. Why:
    Alt Alpha's "Try a layout"; it tells a user how a layout feels before
    installing it.
24. **Éditer › analysis panel: exclude a key.** A key menu entry "Ignorer
    dans l'analyse" removes that key's characters from the metrics (shown as a
    struck-through key and a note in the panel). Why: the Oxey playground;
    useful to judge the alpha block without the punctuation the designer has
    not placed yet.
25. **Comparer › Doigts et mains: layer share in the finger bars.** Stack each
    finger's bar by level (base, Shift, AltGr, dead-key second press). Why:
    Ergo-L's stacked bars show at once that a layout loads a pinky through
    Shift or AltGr.

## 7. Top 15, one line each

1. Analysis panel: stop showing changes against the empty board on first open.
2. "Tapé via": show dead keys with the shared legend, not `[s1_circumflex]`.
3. Toutes les mesures: one "i" per row (left-hand shortcuts has two).
4. Editor: Ctrl/Cmd+Z and Ctrl/Cmd+Y for Undo and Redo.
5. Comparer: rename, duplicate and remove personal layouts (`HOST.store.remove`).
6. Editor "Importer…": accept every format "Ouvrir…" accepts.
7. Editor: sticky score chip with the last edit's change above the board.
8. "Copier le lien": carry personal layouts in the URL fragment.
9. Percentile against the library next to each metric.
10. Worst n-grams visible on Vue d'ensemble, and keys highlighted on hover.
11. "Meilleurs échanges": the 10 best single swaps from the optimiser core.
12. Named score presets built on the planned settings import and export.
13. Ranking: families folded to their best member, and pinned rows.
14. Paste or drop a layout (KLA JSON, rows, cyanophage URL) in the editor and the Comparer.
15. PNG/SVG export of keyboards and heatmaps, CSV export of the ranking.

## Sources

- KLAnext: <https://klanext.keyboard-design.com/>
- Keyboard Layout Analyzer: <https://patorjk.com/keyboard-layout-analyzer/>
- Spray's fork: <https://nsuspray.github.io/keyboard-layout-analyzer/>
- Ergo-L analyser: <https://ergol.org/stats/>
- Cyanophage: <https://cyanophage.github.io/> and
  <https://cyanophage.github.io/playground.html>
- Oxey's Layout Playground and Oxeylyzer: <https://oxey.dev/playground>,
  <https://oxey.dev/oxeylyzer/>
- Layouts Wiki playground: <https://layouts.wiki/playground/>
- Alt Alpha: <https://altalpha.timvink.nl/>
- Keyboard Layout Optimizer: <https://dariogoetz.github.io/keyboard_layout_optimizer/>,
  <https://keyboard-layout-optimizer.fly.dev/>
- Keyboard-design.com tools and ILLDB: <https://keyboard-design.com/tools.html>,
  <https://keyboard-design.com/internet-letter-layout-db.html>
- Keyboard Layout Try Out: <https://keyboard-layout-try-out.pages.dev/>
- keymui: <https://github.com/semilin/keymui>; a200:
  <https://github.com/ClemenPine/a200>; genkey: <https://github.com/semilin/genkey>
