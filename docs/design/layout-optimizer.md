<!-- docs/design/layout-optimizer.md -->

# Layout optimizer

The « Optimiser » tab of Ergopti Studio generates a keyboard layout for a
corpus: it searches key arrangements and keeps the one the layout analysis
engine ([layout-analysis.md](layout-analysis.md)) scores best. The optimizer
measures nothing itself: the score of an arrangement is always
`LAYOUT_ANALYSIS.analyse(layout, tables, options).score.total`, with the
user's weights, keyboard and keyboard format. A metric added to the engine
or a weight changed in `score_weights.json` reaches the optimizer with no
change here.

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
letters before it shuffles the rest.

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
  walks about 15 % of the trigrams, which bounds the gain;
- Web Workers, one share of the restarts each (up to 8, one thread left to the
  page), so the Studio stays responsive and a run uses every core;
- the « 99 % of the n-grams » accuracy (`searchTables`), which keeps the most
  frequent bigrams and trigrams making 99 % of each table's count (about
  twice as fast); the final score is always the whole corpus's.

**Honesty.** The score shown at the end is the engine's score of the returned
layout on the whole corpus, with the same options: the number the Comparer
shows for it.

## Page

Pick the language and corpus (the built-in corpora of the Comparer, or « your
own text »: pasted, or a file the Comparer's reader opens — text, HTML,
.docx, .odt, PDF — counted on the device; a text needs 200 to 5 000 000
characters and a file at most 50 MB, each refusal said under the box), the
start layout (the library, and the layouts open in « Éditer »), « this
layout » or « a random arrangement of its keys », the keyboard; the
switches, each explained; keys kept in place (click them on the start
layout's board); letters kept at their QWERTY place (click them on the QWERTY
board, or the presets « Ctrl Z X C V » and « Ctrl A S »); zones (choose a
character, then click the keys it may sit on, on the start layout's board; its
start key outlined, every zone summed up under the board); the weights (the
engine's defaults, editable); the budget (seconds, swaps per restart,
restarts, seed, accuracy). « Optimize » shows the best layout so far (changed
keys outlined), its score against the start, and the main metrics against the
start; « Stop » keeps the best found. « Open in the editor » hands the layout
to « Éditer », which opens it in a new tab (`LAYOUT_ANALYSIS_FILES
.handOffToEditor`, editor `openLayout`); « Compare with other layouts » hands
it to « Comparer » the way the editor does.

Where a worker cannot start (a page a host inlines, without a script URL),
the same runner runs on the page in 40 ms slices.

## Example

Start AZERTY, corpus « Du côté de chez Swann », default switches (letters
only), keyboard ISO, format TKL, default weights, 1 restart of 3 000 swaps on
99 % of the n-grams: 14 s in Node, score −87.9 → +14.0 (Ergo-L 11.8, Ergopti
24.6 on the same corpus and options, with their own punctuation and digits).

## Follow-ups

- Faster incremental scoring: a trial still compiles the whole layout and
  re-measures the layout-level metrics (shortcuts, digits, coverage), about
  1 ms; caching each entry's last key pattern would halve the walk.
- Incremental scoring with context choices: the engine now types each
  character the way that costs least in its context
  ([layout-analysis.md](layout-analysis.md#ways-of-typing)), and
  `scoreSession` keeps its partial walk only while the current layout and the
  trial type every corpus character one way, with no chord. From AZERTY (the
  default start) nothing changes; from a layout with choices each trial walks
  the whole stream, exact but slow (Swann: Ergopti 95 → 17, Ergo-L 130 → 18
  trials per second). The exact partial walk re-walks the n-grams of the
  characters whose ways changed and of the multi-way characters whose
  shares of ways changed, and re-plans only their contexts.
- The app: mount `LAYOUT_OPTIMIZER_PAGE` in the Studio window of ErgoptiPlus
  (Windows, macOS, Linux), with the keystats corpus « My typing ».
- Saving the page's choices per viewer (localStorage), as the Comparer does.
