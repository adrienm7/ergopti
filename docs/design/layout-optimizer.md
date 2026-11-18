<!-- docs/design/layout-optimizer.md -->

# Layout optimizer

The « Optimiser » tab of Ergopti Studio generates a keyboard layout for a
corpus: it searches key arrangements and keeps the one the layout analysis
engine ([layout-analysis.md](layout-analysis.md)) scores best. The optimizer
measures nothing itself: the score of an arrangement is always
`LAYOUT_ANALYSIS.analyse(layout, tables, options).score.total`, with the
Comparer's score settings (weights, ideal finger load, shortcut table,
compact keyboards' weights and the keyboard's fingering profile, read by
`_shared/ui/layout_analysis/score_settings.js`), the keyboard and the
keyboard format. A metric added to the engine, a weight changed in
`score_weights.json` or a setting changed in the Comparer reaches the
optimizer with no change here.

## Files

| File                                              | Role                                                                                                 |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `_shared/ui/layout_optimizer/optimizer_core.js`   | The search: global `LAYOUT_OPTIMIZER`, pure, no DOM, seeded. Node, a worker or a page load it.       |
| `_shared/ui/layout_optimizer/optimizer_runner.js` | Runs a share of the restarts in slices and posts `progress`, `done` or `error` messages.             |
| `_shared/ui/layout_optimizer/optimizer_worker.js` | The Web Worker: loads the engine, the core and the runner.                                           |
| `_shared/ui/layout_optimizer/optimizer_page.js`   | The page (`LAYOUT_OPTIMIZER_PAGE.mount(root)`), framed by the site at `/studio/optimiser`.           |
| `tools/test/test-layout-optimizer.cjs`            | The core gate: brute-force optimum, honest score, determinism, every constraint switch, time budget. |
| `tools/test/test-layout-optimizer-page.cjs`       | The page gate: scripts, strings in 21 locales, Studio wiring, a page-thread run.                     |

## Model

**Places and units.** A _place_ (slot) is one level pair of a key: base and
Shift of a key (`key`), its AltGr and Shift+AltGr (`altgr`), or the layer of
a dead key behind a letter (`dead`). A _unit_ is the pair of cells a place
holds in the start layout. A move swaps two units, so a letter always keeps
its capital on Shift (`e`/`E` moves as one), and the set of characters never
changes: no character is lost or duplicated. The places are the keys of the
start layout's typing area (`LAYOUT_ANALYSIS.typingCodes`); keys the start
leaves empty are not added.

**Kinds.** Each unit has the first kind of: `space` (never moves), `digit`,
`letter`, `dead` (a dead key), `punctuation` (`, . ; : ! ? ' " - ’ « » … – —`),
`symbol`, `empty` (a hole, free to go anywhere).

**Constraints** (`LAYOUT_OPTIMIZER.DEFAULT_OPTIONS`), each a real switch of
the move set and each unit-tested:

| Option                   | Default | Effect                                                                                    |
| ------------------------ | ------- | ----------------------------------------------------------------------------------------- |
| `moveDigits`             | off     | Digit units may move.                                                                     |
| `digitsOutsideNumberRow` | off     | A digit may leave the number row (`Backquote`, `Digit0`–`Digit9`, `Minus`, `Equal`).      |
| `lettersOnNumberRow`     | off     | A letter may go to the number row.                                                        |
| `movePunctuation`        | off     | Punctuation units may move.                                                               |
| `moveSymbols`            | off     | Symbol and dead-key units may move.                                                       |
| `altgr`                  | off     | The AltGr level pairs become places; units move between base and AltGr levels.            |
| `deadKeyLayer`           | off     | The layer of a dead key becomes places (`deadState`, by default the one with most rules). |
| `pinnedCodes`            | `[]`    | Keys whose units never move.                                                              |
| `qwertyPins`             | `[]`    | Letters placed on their QWERTY key first, then fixed (presets `z x c v` and `a s`).       |
| `qwertyShortcuts`        | `[]`    | Letters whose Ctrl/Cmd shortcut stays on their QWERTY key (`command`); the letter moves.  |
| `zones`                  | `{}`    | Character → the only codes its unit may sit on.                                           |

A unit may always stay where the start had it, unless a zone leaves that key
out: a zoned character never leaves its zone, and one that starts outside it
is first moved onto the first key of the zone whose unit may take its place
(`zone_unreachable` when none can, or when its key is pinned; `zone_missing`
for a character the start lacks). With the dead key's layer on,
one place follows each letter of the base level (« dead key, then e »); the
place follows its letter, so every rule stays reachable whatever moves, and
those letters stay on base places. A dead key never goes behind a dead key.
A QWERTY pin that would move a fixed key, or a letter the start lacks, is
refused (`pin_conflict`, `pin_missing`); a random start places the pinned
letters before it shuffles the rest. A kept QWERTY shortcut writes the
start layout's `command` map (QWERTY's key → the letter, another key's
entry for that letter dropped), which no swap changes: the engine's
`shortcut_left` scores the shortcut where it is kept, and « Open in the
editor » carries it as the source's `command` layer (`required = ["meta"]`,
`LAYOUT_FORMATS.toSource`), which the macOS `.keylayout` and Linux XKB
exports compile; Windows' KLC compiles no Ctrl level. A letter or a QWERTY
key the start lacks is refused (`shortcut_missing`).

## Search

Simulated annealing over swaps, the metaheuristic of most published layout
optimizers (Carpalx, dariogoetz's Keyboard Layout Optimizer, Oxeylyzer):

1. Each restart k draws from its own seed (`restartSeed(seed, k)`, mulberry32),
   starts from the start layout or from a random valid arrangement (the start
   shuffled by random valid swaps), and measures 24 random swaps: the mean
   worsening sets the first temperature T₀ = mean / ln 2, which accepts an
   average worsening half of the time.
2. Each iteration swaps two movable units that may trade places, scores the
   layout and keeps it when it is better, or with probability e^(Δ/T). The
   temperature falls geometrically to T₀/1000, following the iterations, or
   the clock when a time budget is set (whichever is further along).
3. Scores are cached per arrangement (annealing revisits them).
4. The best arrangement of all restarts wins; ties go to the lowest restart,
   so splitting the restarts between workers never changes the winner
   (`bestOf`).

**Determinism.** With the same start, options, corpus, seed and an iteration
budget, the result is the same everywhere. A time budget makes the cooling
follow the clock, so a run stopped by time depends on the machine's speed.

**Speed.** One analysis costs about 5–12 ms on a 1 MB corpus (Node, Windows
laptop), most of it in the key-stream walk and the compact-form reachability
of `compact_fit`. The optimizer scores through the engine's public API only;
it gains its speed from:

- incremental scoring (`LAYOUT_OPTIMIZER.incrementalObjective`, the engine's
  `LAYOUT_ANALYSIS.scoreSession`): the session holds the stream counters of
  the arrangement the search stands on; a trial compiles the new layout,
  compares each corpus character's key sequence with the current one, and
  takes out and puts back only the uni-, bi- and trigrams holding a changed
  character, through `analyse()`'s own visitor. Each key bigram's and key
  trigram's effect (the counters it raises) is probed once from that visitor
  and then added to a typed array. A compact form factor is measured again
  only when the cells on the keys it keeps, or the dead-key rules, changed.
  The search tells the objective the arrangement it keeps (`accept`); a
  trial is correct from any arrangement, `accept` only keeps the next ones
  small. Equal to the full score within 1e-9 (property test: 480 random
  swaps of any cells and dead-key rules on four layouts, boards and formats,
  largest gap 6e-14; `analyse()` itself is byte-identical before and after
  the refactor on the whole library). Measured (Node, « Swann », AZERTY,
  99 % of the n-grams, 2 000 swaps, a loaded Ryzen 5 3500U): 94 → 288
  layouts per second per worker (×3). A swap of a frequent letter still
  walks about 15 % of the trigrams, which bounds the gain.
  A layout that offers a choice of ways (several ways for a character,
  [layout-analysis.md](layout-analysis.md#ways-of-typing)) is planned from
  the current plan (`planTyping`'s previous): only the choices whose
  context — the trigram around an occurrence, and the tokens before and
  after it, through the skipgram tallies — holds a token whose ways changed
  are made again, by the same code in the same order as from nothing (the
  plan is the same to the last bit), and the trial walks only the tokens,
  pairs and triples whose ways, choice or shares of ways actually changed.
  A trial that changes the chords or the set of multi-way tokens walks the
  whole stream. Measured in the optimizer's own annealing (Swann, 99 % of
  the n-grams, 120 swaps, interleaved on one loaded laptop, against the
  whole-stream walk of 6a3858f2a6): Ergo-L 16.7 → 23.0, Ergopti 22.7 →
  35.1, bépo 8.7 → 15.1, AZERTY 110 → 116 trials per second, with the
  same results. The trial's layout is then compiled in part
  (`compileCoreFrom`, [layout-analysis.md](layout-analysis.md#performance)):
  only the ways the swapped cells or dead-key rules reach, to the same lists
  as a whole compile; the layouts the search scores share one dead-key table
  when its layer stays put, so the engine sees at once that no rule changed.
  Measured the same way (Swann, 99 %, 300 swaps, median of 3 interleaved
  runs on one loaded laptop, against b1b4f80799): bépo 13.2 → 27.7,
  Ergopti 39.6 → 46.3, Ergo-L 26.3 → 32.4, AZERTY 107 → 134 trials per
  second, with the same results. What is left
  on the layouts with choices is the plan (`planTyping`, about 40 % of a
  trial on Ergo-L), the context walk (15 %) and the layout-level metrics
  (13 %, `simplicity` half of it);
- Web Workers, one share of the restarts each (up to 8, one thread left to the
  page), so the Studio stays responsive and a run uses every core;
- the « 99 % of the n-grams » accuracy (`searchTables`), which keeps the most
  frequent bigrams and trigrams making 99 % of each table's count (about
  twice as fast); the final score is always the whole corpus's.

**Honesty.** The score shown at the end is the engine's score of the returned
layout on the whole corpus, with the same options: the number the Comparer
shows for it.

## Page

Four numbered step cards; on a wide screen the run card stays beside the
first two (sticky), on a phone everything is one column:

1. **Corpus and start**: language, corpus (the built-in corpora of the
   Comparer, or « your own text »: pasted, or a file the Comparer's reader
   opens — text, HTML, .docx, .odt, PDF — counted on the device; a text needs
   200 to 5 000 000 characters and a file at most 50 MB, each refusal said
   under the box), start layout (the library, and the layouts open in
   « Éditer »), keyboard, « this layout » or « a random arrangement of its
   keys ».
2. **What may move**: the switches, each explained, in a grid; then one
   segmented sub-tab at a time: keys kept in place (click them on the start
   layout's board), Ctrl shortcuts (letters on the QWERTY board or the presets
   « Ctrl Z X C V » and « Ctrl A S », and whether the letter itself stays on
   its QWERTY key or only its Ctrl/Cmd shortcut does), zones (choose a
   character, then click the keys it may sit on; its start key outlined,
   every zone summed up under the board).
3. **Run**: the score settings the run uses, each « default » or « your
   own » (the Comparer's, never a copy: « Change them in Compare » opens its
   « Réglages du score », the app's window unfolds it), the budget folded
   (seconds, swaps per restart, restarts, seed, accuracy), « Optimize » and
   « Stop », the progress and the status.
4. **Result**: the start, best and gain as three tiles; the start and the
   best layout side by side, each changed key outlined in dashes on both,
   and how many changed; the main metrics against the start in two tables
   side by side. « Stop » keeps the best found. « Open in the editor » hands
   the layout to « Éditer », which opens it in a new tab
   (`LAYOUT_ANALYSIS_FILES.handOffToEditor`, editor `openLayout`); « Compare
   with other layouts » hands it to « Comparer » the way the editor does.

The page keeps the reader's choices (corpus, start, keyboard, switches, pins,
QWERTY letters and what of them stays, zones, the open sub-tab, budget) and their last text in this browser's storage
(`ergopti.layout_optimizer.v1`, `ergopti.layout_optimizer.text.v1`), and puts
them back on the next visit, skipping a value it no longer knows; a browser
that refuses storage, or a text over the quota, gets the same page unsaved.

Where a worker cannot start (a page a host inlines, without a script URL),
the same runner runs on the page in 40 ms slices.

Numbers are written in the language of the page's strings (`_i18n_locale`),
else the page's declared language (`<html lang>`); a page that declares
none, or a malformed tag, writes them in French, the locale `i18n.js` loads
when none is set, never the browser's own, and says so once in the console
(`toLocaleString('')` throws). A run that fails at any stage (reading the
choices, loading the corpus, measuring the start, starting the runners,
showing a result) logs the error, says which stage failed in the reader's
language (`layout_optimizer.error.stage.<stage>`, or the error's own code)
and offers « Try again »; a refused constraint or a missing text is said
without it.

**In Ergopti+.** The Studio window of the app
(`_shared/ui/layout_editor_window`, on Windows, macOS and Linux) has a third
tab, « Optimiser », that mounts the page the first time it opens, with the
window as host: « Open in the editor » opens the layout in a new tab of its
« Éditer » (`openLayout`) and « Compare with other layouts » adds it in its
« Comparer ». The keystats n-grams the window reads (`studio-ngrams`) become
the corpus « My typing », listed first and chosen, even when they arrive
before the tab opens. macOS and Linux inline the scripts (and their document
CSP forbids workers), so the search runs on the page; Windows serves them
from its virtual host, so workers start there. The tab reads its strings from
the catalogue macOS and Linux seed, and from the `layout_optimizer.*` keys the
Windows host sends with the editor's (`LayoutManager_EditorStrings`).

## Example

Start AZERTY, corpus « Du côté de chez Swann », default switches (letters
only), keyboard ISO, format TKL, default weights, 1 restart of 3 000 swaps on
99 % of the n-grams: 14 s in Node, score −87.9 → +14.0 (Ergo-L 11.8, Ergopti
24.6 on the same corpus and options, with their own punctuation and digits).

## Follow-ups

- Faster incremental scoring: a trial still re-measures the layout-level
  metrics (shortcuts, digits, coverage), about 1 ms; caching each entry's
  last key pattern would halve the walk.
- Faster planning: on a layout with choices, `planTyping` from the current
  plan is about 40 % of a trial (Ergo-L), and `simplicity` walks every way
  of every character each trial; both bound the 95–130 trials per second
  aimed at.
