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
| `_shared/ui/layout_optimizer/optimizer_runner.js` | Runs a share of the restarts in slices, or scores the library after a run, and posts its messages.   |
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
| `thumbKeys`              | `null`  | A keyboard id whose thumb keys (NonConvert, Convert, KanaMode) become places.             |

**Thumb keys** (decided by the agent on 2026-11-19, to review by the
maintainer). The analysis model's thumb keys
([layout-analysis.md](layout-analysis.md#model)) are places only when
`thumbKeys` names a keyboard that has them (a split board, JIS); the empty
ones join as holes, so a letter may move there. A keyboard without thumb keys
is refused (`thumb_keys_absent`). With `null`, the default, nothing moves onto
a thumb key and a start layout's thumb characters stay where they are, as a
pinned key's. The page offers no switch for it yet: the option is the core's.

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
  second, with the same results. The plan from the current plan then
  moved to ids and typed arrays (`planContext`,
  [layout-analysis.md](layout-analysis.md#performance)): a trial writes
  its plan into the buffers of the plan before the current one and
  allocates almost nothing; the layout-level metrics stopped copying
  (simplicity's accent rule is carried over from the current compile, and
  counted again only for the characters a trial compiled again), compact
  forms follow the dead-key rules on ids, and a partial compile finishes
  from the ways before it. Measured (Swann, 99 %, 600 swaps from the start
  layout, each run its own Node process, median of 3 runs alternating old
  and new on one heavily loaded PC, against 12a3d5e460), trials per second
  of wall time (of CPU time): Ergopti 56.8 → 110.4 (81.8 → 138.0), Ergo-L
  39.4 → 92.5 (61.1 → 128.2), bépo 35.3 → 57.0 (49.6 → 94.9), AZERTY
  145 → 207 (163 → 228), QWERTY 160 → 193 (186 → 256), every run ending on
  the same best score. A trial then stopped copying the session's maps
  (the core's ways, dead states and texts, the finished ways and best
  ways, the plan's filtered ways: about 1,769 entries each on bépo): each
  role has two spare maps (`spareMaps`), and the one a trial gets is made
  equal to the current map by writing back only the keys the trial before
  changed (about 120 characters per letter swap on bépo); the partial
  compile lists the rules of the touched outputs from the rule graph
  instead of testing all 2,181. Measured (Swann, 99 %, 1,500 swaps from
  the start layout, the old and new engines in one Node process stepped
  in turn 20 iterations at a time, so that the load falls on both alike,
  on one heavily loaded PC, against f32cb8f6b2), speed-up of the median
  run: bépo ×1.28 (5 runs, ×1.19–×1.37), Ergopti ×1.12 (3 runs,
  ×1.07–×1.19), Ergo-L ×1.18 (3 runs, ×1.15–×1.23), every trial's score
  bit-identical to the old engine's (`Object.is`, seeds 7 and 3); at the
  rates above, about bépo 73, Ergopti 124, Ergo-L 110 trials per second.
  The compile and finish fell from about 40 % to 31 % of a bépo trial;
  the joins themselves are few (about 150 per swap, nearly all kept), so
  what is left of them is a per-character cost: about 120 lists compiled,
  finished and planned again per swap. On Ergo-L, the plan (20 %) and the
  context walk (20 %, two thirds of it the corpus trigrams of the swapped
  characters that hold no multi-way token) are left. A profile of the
  search then showed where a bépo trial's per-character cost went: about a
  sixth of it was the weak table that kept each joined way's time (a
  WeakMap set per kept way, about 150 per swap, each entry held until a
  full collection). The time now sits on the way under a symbol, a
  compile's list versions in a Map, and a trial writes no weak-table entry
  (the gate counts them). The rule graph keeps the closure of each set of
  touched symbols (the lists to compile again and the rule order), the
  compact forms' reach answers from the rules' ids instead of a set of
  about 1,800 characters, a plan writes its spare ways only for the
  table's tokens (the accented letters no n-gram holds keep an earlier
  compile's lists there, which nothing reads), and a few hot loops lost
  their copies (the stream counters' `Object.assign`, the shortcut
  letters' plain objects, array-literal destructuring, `Object.entries`
  of the rows). Measured the same way (Swann, 99 %, 1,500 swaps, the two
  engines in one Node process stepped in turn, on a loaded PC, against
  761a60ccf6), trials per second of the old and new engine and the
  speed-up: bépo ×1.33 (median of 5 runs, ×1.26–×1.41; 117–134 → 147–179),
  Ergopti ×1.21 (2 runs, ×1.20–×1.21; 204–247 → 245–300), Ergo-L ×1.12
  (2 runs, ×1.11–×1.13; 200–214 → 226–239), every trial's score
  bit-identical (`Object.is`, seeds 7 and 3); at the 2026-11-17 rates,
  about bépo 97, Ergopti 150, Ergo-L 123 trials per second, inside the
  95–130 aimed at for the layouts with choices;
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
   Under them, the library card ([Existing layouts](#existing-layouts)).

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
the catalogue macOS and Linux seed, and from the whole catalogue the Windows
host sends with the editor's source (`LayoutManager_EditorStrings`).

## Existing layouts

Once a run ends (or is stopped), the page asks whether an existing layout
already does the job: « for your use case, layout X would do; the optimized
one is only so much better ». A worker of its own (`{type: 'library'}`, or
the runner's slices on a page without workers) scores every library layout
(`LAYOUT_ANALYSIS.libraryLayouts()`) with `analyse()` on the run's whole
corpus and its analysis options (the Comparer's score settings, keyboard,
format, fingering), a few layouts per 40 ms slice
(`LAYOUT_OPTIMIZER_RUNNER.scoreLibrary`), and measures how alike each one is
to the optimized layout (`LAYOUT_ANALYSIS.layoutSimilarity`,
[layout-analysis.md](layout-analysis.md#api)). The library is never scored
in one go on the page: it takes about 2 s in Node, and a layout with many
dead keys (bépo) about 0.3 s on its own.

**Measure.** Both candidates are kept, and the weighted one is read first:
the share of the characters typed, each counted by its occurrences in the
corpus (spaces aside), that sit on the same keys at the same levels, a dead
key and the key after it both alike. Weighted, because moving « e » changes
a typist's habits far more than moving « § »; the unweighted share (each
distinct corpus character once) and the share on the same finger and row
(a letter moved between the index's two columns) are written beside it.

**Comparison.** `LAYOUT_OPTIMIZER_RUNNER.librarySummary(entries, score,
{smallGap, closest})` lists the five most alike layouts (`LIBRARY_CLOSEST`)
and the best-scoring existing layout (every complete layout before an
incomplete one, as the Comparer ranks), each with its gap: the optimized
layout's score minus its own, in the score's points. A ratio of scores
would mean nothing, since the score has no zero (AZERTY is about −88). The
verdict reads the best existing layout's gap:

| Verdict           | When                          | Says                                                                    |
| ----------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `small_gap`       | 0 ≤ gap ≤ `similar_score_gap` | That layout would do the job; the optimized one is only so much better. |
| `optimized_ahead` | gap > `similar_score_gap`     | The optimized layout leads the best existing one by that much.          |
| `existing_better` | gap < 0                       | An existing layout scores more; a longer run may close the gap.         |

`similar_score_gap` (`analysis_model.json`, read by
`LAYOUT_ANALYSIS.similarScoreGap()`, checked by the codegen) is 2 points by
default: 0.2 % of SFB at its weight 10, about the gap between Ergopti+ and
Ergopti on the Nemolivier anthology (decided by the agent on 2026-11-19, to
review by the maintainer, `TODO.md`).

**Card.** A card under the result: the verdict with a mark (≈, ▲, ★) and a
coloured edge; the best existing layout with a ring gauge of its
similarity, its score, its gap (▲ above, ▼ below the optimized layout, in
words) and its other two similarities; the alike layouts as bars on one
track (same key solid, same finger and row hatched behind it), each with
its gap; buttons « Comparer » and « Éditer » whose accessible names carry
the layout's name (`LAYOUT_ANALYSIS_FILES.handOff` and `handOffToEditor`,
or the host's `openComparer` and `openEditor` in the app). A library layout
handed to the Comparer replaces its own entry there and is ticked, so the
Comparer needs no new hook. Every visual repeats its number in text; the
bars and the gauge are hidden from assistive technology, and forced-colours
modes draw them in the system's colours. `LAYOUT_OPTIMIZER_PAGE.libraryCard`
builds the card from a summary, so the page gate renders it without a
browser.

## Example

Start AZERTY, corpus « Du côté de chez Swann », default switches (letters
only), keyboard ISO, format TKL, default weights, 1 restart of 3 000 swaps on
99 % of the n-grams: 14 s in Node, score −87.9 → +14.0 (Ergo-L 11.8, Ergopti
24.6 on the same corpus and options, with their own punctuation and digits).

## Follow-ups

- Faster trials, past the 95–130 per second reached on the layouts with
  choices: a bépo trial is now about a fifth compile and finish (the ~120
  lists a letter swap compiles again, their spare-map writes and the
  accent rule), a fifth plan, a sixth context walk (its rest trigrams of
  the swapped characters) and a tenth the metrics. Tried without gain:
  keeping each pair's side costs across trials, summing the walk's rest
  n-grams per key n-gram before the visitor, refusing a chain on its cost
  before building it (a full list refuses about one chain in a hundred
  trials), keeping the compact forms' reach per set of the cells'
  characters (a search hits it about once in six: the forms' missing
  keys hold several movable letters), and skipping a rest trigram whose
  key triple a trial leaves alone (about one in a hundred).
