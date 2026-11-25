<!-- docs/audits/layout-analysers/layouts-wiki-playground.md -->

# Layouts Wiki playground against Ergopti Studio

Written on 2026-11-25 (Paris time) at the maintainer's request (« Améliore notre
analyseur de disposition avec les bonnes idées de celui-ci »). It revisits the
Layouts Wiki playground (https://layouts.wiki/playground/, by xsznix), first seen
briefly in the UX study ([ux-study.md](ux-study.md), section 1.7), now that it
has a dockable workspace and a long built-in documentation. It lists what the
playground offers, what Ergopti Studio already has, and ranks the gaps.

## Method and limits

- The page was opened in headless Chromium (Playwright, 1600 × 1200 CSS px) on
  2026-11-25 between 00:30 and 01:00 Paris time, in five page visits: the
  default workspace, each pane type added once (Layouts, Edit, Inspector,
  Versions, Metrics, Ranking, Pareto, Trace, Try Out, Keystrokes, Words,
  Corpus, Docs), and the 21 topics of its Docs pane read once. No scraping
  loop, no account, no layout saved.
- The site publishes no licence. Nothing of its code, text or images was
  copied into Ergopti: the ideas below are described in our own words, and
  every feature taken from it is reimplemented in Ergopti's architecture and
  credited as an « idea seen in the Layouts Wiki playground ».
- Screenshots stayed in the session scratchpad; they are not committed.
- The playground lists Ergopti among its 2026 layouts (Reddit English,
  letters and « ' , . »: SFB 1.44 %, SFS 4.97 %, alternation 37.6 %, rolls
  47.5 %, redirects 6.5 %). Its alphabet keeps only those characters, so it
  does not see the accents and dead keys that Ergopti is built for.

## What the playground is

- **Frame.** A header with three pickers: « Main » (the layout studied),
  « Comp » (an optional comparison) and the corpus (source and alphabet). The
  rest is a workspace of panes, docked in two columns, each pane a tab that can
  be added, moved, maximised and closed; a browser tab keeps its own workspace.
  Panes that show one layout follow Main or Comp, or are pinned to a layout.
- **Metrics.** Two built-in views. « Movement »: same finger (same key,
  different key), row change (concordant, discordant), lateral stretch, each
  over bigrams and skipgrams. « Trigram rhythm »: alternation (with its SFS
  share), rolls (in, out), redirects (with SFS, weak, weak + SFS), each with
  and without thumbs. Every value carries its percentile among the published
  layouts on that corpus (P5 … P94) on a two-colour ground. A metric is a
  query in a small language over key windows (`bi.sf.freq * 100`, filters on
  fingers, rows, distances, held keys); views, metrics and layout costs are
  user-editable TOML documents with saved versions.
- **Layouts.** A sortable, resizable grid of about 300 layouts (author, year,
  SFB, SFS, alternation, rolls, redirects, weak redirects), a text search and a
  Boolean query (« year >= 2020 & !has_magic »), user metric columns, and a
  filter that hides layouts unable to type the corpus.
- **Ranking.** One metric (any query) over the library: a smoothed
  distribution curve with the studied layout marked, the visible range
  snapped to P0/P10/P25 and P75/P90/P100, and the exact values in a table.
- **Pareto.** Several metrics, each told « higher » or « lower is better »; a
  layout is on the frontier when no other is at least as good on all of them
  and better on one. A chart (X, Y and an optional colour metric) or a table,
  « frontier only », and Main, Comp or a pinned layout always shown as a
  reference without joining the population.
- **Trace.** Example texts typed on Main, Comp, both or their difference: each
  character over the key that types it, coloured by finger, with an alternate
  fingering outlined.
- **Keystrokes, Words, Corpus.** A drill-down: an n-gram query lists the
  matching key sequences with frequency and share; one sequence opens the words
  it occurs in; one word opens the corpus lines.
- **Inspector.** Every layer drawn with finger colours, home marks, layer
  activators and the key sets they accept (« Shift held by the other hand »).
- **Modelling.** Holds and one-shots of layers (Shift, AltGr, any layer), the
  hand rule of Shift as a key set, combos (chords), tap and hold keys, magic
  keys (rules that change a key's output after a context, swaps and cycles),
  repeat and skip-repeat keys, alternate fingerings, ortho, column-stagger and
  ANSI boards, user corpora and corpus blends.
- **Try Out.** A typing test on the layout, with a key calibration.
- **Docs.** 21 topics inside the app, from the tasks (compare, rank, Pareto,
  edit) to the reference of every format and query field.

## Feature table

Legend: ● full, ◐ partial, ○ absent.

| Their feature                                            | Ergopti Studio today (where)                                                                       | Gap                                                              | Value for Ergopti users                                                                         | Cost         |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------ |
| Main and Comp layouts kept across the views              | ◐ Comparer « Une disposition » (details and versus), editor « Comparer avec »                      | The pair is chosen in one tab, not in a frame every view follows | Medium: one place to set what is compared                                                       | Medium       |
| Percentile of each value against the library             | ● Comparer table and editor panel (`E.percentiles`, ux-study item 9)                               | —                                                                | —                                                                                               | —            |
| Sortable library grid with any metric column             | ● Comparer ranking (columns, filters, family folding, CSV); since 2026-11-25 a values query        | Closed (« Values query »: comparisons, & \| !, parentheses)      | Low: our filters cover name, family, origin, language, completeness, score                      | Medium       |
| Ranking of the library on one metric with a distribution | ● since 2026-11-25: the Pareto tab's spread, its quantiles P0 to P100 marked and listed            | Closed (a smoothed curve above the strip, `densityCurve()`)      | Medium: « where does my layout stand on SFB » at a glance                                       | Low          |
| Pareto frontier over chosen metrics                      | ● since 2026-11-25: Comparer « Pareto »                                                            | Closed                                                           | High: shows the layouts no other beats on two criteria, with no weights involved                | Low          |
| Trace of an example text                                 | ● since 2026-11-25: Comparer « Trace »                                                             | Closed                                                           | High: explains where a layout's cost comes from on a sentence the user chooses (accents, AltGr) | Medium       |
| N-gram explorer with drill-down to words and corpus      | ◐ worst n-grams, key pair matrix, word efforts (Comparer)                                          | No « this pair: which words » drill-down                         | Medium: tells which words make a bad pair frequent                                              | Medium       |
| Main minus Comp differences in every view                | ● since 2026-11-25: a Principal − Comparison table on every frame tab, the trace, the movements    | Closed                                                           | Medium                                                                                          | Low per view |
| Holds of Shift and AltGr with a hand rule                | ● Shift by the other hand's pinky, AltGr and custom levels held (« Levels », Neo's Mod3 and Mod4)  | —                                                                | —                                                                                               | —            |
| Dead keys, one dead key (1DK)                            | ● dead keys and chains, `dead:<state>` (Ergo-L's 1dk twice)                                        | —                                                                | —                                                                                               | —            |
| Magic keys (context rules) and repeat keys               | ○ (read nowhere; Kawalyzer and chogalyzer model them too)                                          | Missing in the engine, the formats and the drivers               | Medium: growing in the English community, absent from Ergopti's own design                      | High         |
| Combos (chords) and tap-hold in the analysis             | ◐ multi-character outputs and chords as ways of typing; tap-hold edited but not analysed as a hold | Tap-hold layers in the analysis                                  | Low                                                                                             | High         |
| User metrics as queries, editable metric views           | ● since 2026-11-25: « Your metrics » (`windowMetrics()`), queries over pairs, skipgrams, trigrams  | No editable metric views as files (a list kept in the browser)   | Low for most users, high for designers                                                          | High         |
| Saved versions of a layout with a branch graph           | ● since 2026-11-25: editor « Versions » (named snapshots beside undo, diff, restore)               | No branch graph (a flat list, oldest first)                      | Medium                                                                                          | Medium       |
| Corpus blends with weights                               | ● since 2026-11-25: « Blend corpora » (built-in and own texts, kept, linked when built-in)         | Closed                                                           | Medium: French and English or prose and code in one score                                       | Medium       |
| Dockable panes, several views side by side               | ○ (tabs)                                                                                           | Missing                                                          | Low: our tabs are keyboard-simple; panes are hard to make accessible                            | High         |
| Share link with the state                                | ● since 2026-11-25: the tab, Pareto values and trace text too                                      | Closed                                                           | Medium: a link to a Pareto or a trace opens on it                                               | Low          |
| In-app documentation                                     | ● since 2026-11-25: « Help » in the Comparer, the editor and the Optimiser, an « i » per metric    | Closed (the query language in Help, its names under the metrics) | Medium                                                                                          | Medium       |
| Typing test                                              | ● « Essayer »                                                                                      | —                                                                | —                                                                                               | —            |

## Ranked shortlist

1. **Pareto tab in the Comparer** (done, 2026-11-25). Two metrics chosen
   among the engine's scored metrics and the mark, each with its direction from
   the engine; the frontier computed over the filtered layouts; a scatter plot
   with the frontier joined, the detailed layout ringed, and a table that is
   the full alternative (values, Pareto layer, « beaten by »). Engine
   `pareto()`, tab `pareto` of `comparer_page.js`.
2. **Trace of an example text** (done, 2026-11-25). A text typed on the
   detailed layout, and on the versus layout when one is chosen: each character
   with its keys, modifiers, dead keys and finger, then every key pair and
   triple with the events it raises (SFB, lateral stretch, scissors, rolls,
   redirects…), counted per layout with their difference. Engine
   `traceText()`, whose counts equal `analyse()` on the same text; tab `trace`.
3. **Distribution of one metric** (done, 2026-11-25). In the Pareto tab: the
   compared layouts' values of the horizontal metric as a strip, the detailed
   layout placed and its rank said in words (« better than 6 of the other 7 »),
   the table under it giving every value.
4. **Share link carries the tab and its settings** (done, 2026-11-25): the tab
   shown (`tab`), the Pareto values (`px`, `py`), the trace text (`text`) and
   its two layouts (`details`, `versus`).
5. **N-gram to words drill-down** (done in the trace, 2026-11-25): each
   penalised pair or triple opens the corpus words that type its keys in a
   row (`wordsWithKeys()`). Left: the same on the worst n-gram rows.
6. **Movement table** (done, 2026-11-25): each pair class over adjacent pairs
   and over skipgrams, with the compared layout and the difference
   (`movementTable()`, « One layout »), shown and never scored.
7. **Corpus blends**: a weighted mix of built-in corpora. Left in TODO.md.
8. **Magic and repeat keys**: an engine model, a source format and the drivers'
   emulation. Left in TODO.md (a design first: Ergopti's own drivers would
   need to emulate them, `cross-driver-parity`).
9. **Saved layout versions** and **in-app task help**: left in TODO.md.

## Kawalyzer, from its description

Kawalyzer (named in the maintainer's Discord excerpt, not opened in this
session) advertises full support of one dead key (1DK), magic and repeat
keys, « Clever Keys » and drag and drop. Ergopti already models 1DK (Ergo-L's
dead key twice, `dead:<state>`) and drag-and-drop swaps; magic, repeat and
Clever Keys (context-dependent outputs) are the same gap as item 8, left in
TODO.md with a design first.

The scoring is untouched: the views read the engine's metrics and the score
settings as they are (QWERTY index 100, the decided weights and thresholds).
