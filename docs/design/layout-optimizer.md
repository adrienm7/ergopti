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

| File                                              | Role                                                                                                                     |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `_shared/ui/layout_optimizer/optimizer_core.js`   | The search: global `LAYOUT_OPTIMIZER`, pure, no DOM, seeded. Node, a worker or a page load it.                           |
| `_shared/ui/layout_optimizer/optimizer_runner.js` | Runs a share of the restarts in slices, or scores the library after a run, and posts its messages.                       |
| `_shared/ui/layout_optimizer/optimizer_worker.js` | The Web Worker: loads the engine, the core and the runner.                                                               |
| `_shared/ui/layout_optimizer/optimizer_page.js`   | The page (`LAYOUT_OPTIMIZER_PAGE.mount(root)`), framed by the site at `/studio/optimiser`.                               |
| `tools/test/test-layout-optimizer.cjs`            | The core gate: brute-force optimum, honest score, determinism, every constraint switch, time budget, each search method. |
| `tools/test/test-layout-optimizer-page.cjs`       | The page gate: scripts, strings in 21 locales, Studio wiring, a page-thread run.                                         |

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
| `maxChanges`             | `null`  | At most this many units off their start place ([Change penalty](#change-penalty)).        |

**Thumb keys** (decided by the agent on 2026-11-19, to review by the
maintainer). The analysis model's thumb keys
([layout-analysis.md](layout-analysis.md#model)) are places only when
`thumbKeys` names a keyboard that has them (a split board, JIS); the empty
ones join as holes, so a letter may move there. A keyboard without thumb keys
is refused (`thumb_keys_absent`). With `null`, the default, nothing moves onto
a thumb key and a start layout's thumb characters stay where they are, as a
pinned key's. A letter that moves onto a thumb key is scored like any other
(its pairs and trigrams count, a letter beside the space on one thumb is a
thumb SFB); the space never moves, so a search keeps its start's board
(`boardFor`), and the property test of `test-layout-optimizer.cjs` checks the
incremental objective against the full one with letters on the Corne's thumb
keys, the space on its Space key (AZERTY) or on a thumb key (Hands Down Gold).
The page offers no switch for it yet: the option is the core's.

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

A local search over swaps of units, with one of five methods
(`LAYOUT_OPTIMIZER.METHODS`, the `method` setting of `createSearch`, the
« Search method » list of the page). Every method runs inside the same frame:

1. Each restart k draws from its own seed (`restartSeed(seed, k)`, mulberry32)
   and starts from the start layout or from a random valid arrangement (the
   start shuffled by random valid swaps).
2. One iteration is one scored trial, so an iteration budget is the same work
   for every method. Every move is a swap `pickSwap` or `allowed` accepts
   (pins, zones, number row, dead-key layer, thumb keys) within the change
   limit; the objective is the engine's score less the change penalty; the
   incremental scorer follows the arrangement the method stands on
   (`accept`).
3. Scores are cached per arrangement (annealing revisits them).
4. The best arrangement of all restarts wins, never worse than the start (the
   start is the first best); ties go to the lowest restart, so splitting the
   restarts between workers never changes the winner (`bestOf`).

The methods (`begin(run)` / `iterate(run, fraction)` in `createSearch`):

| Method            | Idea                                                                                                                                                                                                                                                                       | Settings                                         |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `late_acceptance` | Late-acceptance hill climbing (Burke and Bykov): a random valid swap is kept when the result is no worse than the current arrangement or than the current one L trials ago. **Default.**                                                                                   | L = 50 (`LATE_ACCEPTANCE_HISTORY`)               |
| `annealing`       | Simulated annealing: 24 random swaps measure the mean worsening, T₀ = mean / ln 2 accepts it half of the time; a swap is kept when better, or with probability e^(Δ/T); T falls geometrically to T₀/1000 following the iterations, or the clock when a time budget is set. | `CALIBRATION_SWAPS`, `FINAL_TEMPERATURE_RATIO`   |
| `hill_climbing`   | Best-improvement hill climbing: every valid swap is scored (in an order the seed shuffles) and the best gain made; at a local optimum the restart's best optimum gets 3 random swaps (a kick) and the climb starts again (an iterated local search).                       | `HILL_KICK_SWAPS` = 3                            |
| `genetic`         | Steady-state genetic algorithm: a population seeded with mutants of the start (1–8 swaps) or random arrangements; each trial breeds one child (tournament of 3, cycle crossover with probability 0.7, then 1 + geometric swaps); it replaces the worst when better.        | population 12, `GENETIC_*`                       |
| `tabu`            | Tabu search on a candidate list: 24 random valid swaps are scored, the best one not tabu (or beating the best found) is made even when it loses, and its two units are tabu for a quarter of the movable units (3–12 moves).                                               | `TABU_CANDIDATES` = 24, `TABU_TENURE_MIN`/`_MAX` |

The genetic algorithm's crossover is the cycle crossover (`cycleCrossover`):
each cycle of the two parents' permutations comes whole from one of them,
so every unit sits on a place one parent gives it. Every constraint of a
place on its unit (`allowed`) then holds without repair, the fixed units stay
put, and a child over the change limit is replaced by a copy of its first
parent before its mutation. PMX and OX put units on places neither parent
gave them and would need a repair step for the zones and the number row.
Elitism is the steady state itself: only the worst individual is ever
replaced. The genetic population (12) won a short tuning run against 24 and
48 (AZERTY, Nemolivier, 3,000 trials, 3 seeds: median −15.5 against −22.6 at
48); late acceptance's L = 50 and tabu's 24 candidates tied with 20 and 48.

**Determinism.** With the same start, options, corpus, seed, method and an
iteration budget, the result is the same everywhere. A time budget makes the
annealing's cooling follow the clock, so a run stopped by time depends on the
machine's speed. The annealing code moved behind the method interface
unchanged: its results are bit-identical to the annealing-only search (the
gate pins its annealing checks to `method: 'annealing'`).

### Survey

What published optimizers use (sources read in 2026-11; the analysers'
report, [docs/audits/layout-analysers/report.md](../audits/layout-analysers/report.md),
lists them):

| Optimizer                            | Method                                                                                                                                                                             | Parameters                                                                                                                                                                                                                                                     |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Carpalx                              | Simulated annealing, 1 or 2 key swaps per move                                                                                                                                     | T = T₀·e^(−ik/N), acceptance p₀·e^(−ΔE/T); T₀ 10, k 10, p₀ 1, N 10,000                                                                                                                                                                                         |
| keygen (xsznix)                      | Carpalx's annealing, then exhaustive steepest descent over k swaps                                                                                                                 | T₀ 1.5, k 10, N 15,000                                                                                                                                                                                                                                         |
| dariogoetz Keyboard Layout Optimizer | Simulated annealing (argmin) and a genetic algorithm (genevo)                                                                                                                      | SA: T₀ from the cost spread of random neighbours, ×0.998 per iteration, stop after 5,000 without acceptance. GA: population 1,000, mutation 0.01, crossover disabled (PMX and cycle crossover commented out); its README says annealing gives the best layouts |
| Oxeylyzer                            | Random restarts, each a steepest ascent over all swaps (its swaps are scored very cheaply); newer engines add annealing, late acceptance, iterated local search and depth-2 search | 500–1,000 restarts; LAHC history 100                                                                                                                                                                                                                           |
| genkey                               | First-improvement hill climbing from 1,000 random layouts, then 1, 2, 3 simultaneous swaps on the best 100                                                                         | 500 failures in a row per climb                                                                                                                                                                                                                                |
| Cyanophage's optimiser               | Steepest descent over all key and column swaps, a kick of shrinking size at each optimum, visited optima remembered                                                                | 20 rounds                                                                                                                                                                                                                                                      |
| AdNW `opt`                           | Random start, swaps until no gain, many restarts                                                                                                                                   | about 10,000 restarts                                                                                                                                                                                                                                          |
| Halmak                               | Genetic algorithm with mutation only, elitism                                                                                                                                      | population 12, tournament of 3                                                                                                                                                                                                                                 |

No tool gives evidence for a crossover, and none uses tabu search. The
expensive objective (100–700 trials per second here, against millions for
Oxeylyzer's cached swaps) favours a method that learns from every trial over
one that scans whole neighbourhoods.

### Benchmark

Measured on 2026-11-19 at night, Paris time, by
`bench.cjs`, `aggregate.cjs` and `pivot.cjs` (the session's scratchpad,
`optbench`): every method, 5 seeds, one restart from the start layout
(letters only, the default switches), 5,000 trials, the search on 99 % of
the n-grams and the final score on the whole corpus; starts AZERTY, QWERTY,
Ergopti and bépo; corpora Nemolivier (N) and Don Quichotte (DQ); 200 runs, 3
at a time, on a PC already at 94 % CPU from other work (8 threads), so each
process got about half a core: the CPU-time columns are the fair ones. The
equal CPU budget of a case is the annealing runs' median CPU time; a
method's score there is its search's best when it had spent that much CPU.

| Case           | azerty N | qwerty N | ergopti N | bepo N | azerty DQ | qwerty DQ | ergopti DQ | bepo DQ |
| -------------- | -------: | -------: | --------: | -----: | --------: | --------: | ---------: | ------: |
| Start score    |   −142.2 |   −144.5 |      −3.6 |  −34.1 |    −136.3 |    −140.8 |       +3.4 |   −30.5 |
| CPU budget (s) |      9.1 |      8.3 |      19.2 |   28.0 |       8.9 |       8.2 |       15.6 |    28.2 |

Median at equal CPU (the decision):

| Method          | azerty N | qwerty N | ergopti N |   bepo N | azerty DQ | qwerty DQ | ergopti DQ |  bepo DQ |
| --------------- | -------: | -------: | --------: | -------: | --------: | --------: | ---------: | -------: |
| late_acceptance | **−9.1** | **−0.4** | **+11.9** | **+1.6** |      −9.2 |     −6.44 |  **+18.2** |     +4.5 |
| annealing       |    −15.2 |     −7.6 |      +6.6 |     +1.0 |  **−5.3** | **−6.36** |       +8.4 | **+6.3** |
| hill_climbing   |    −13.6 |     −9.1 |     +11.4 |     +0.8 |     −15.1 |     −15.4 |      +18.0 |     +1.6 |
| genetic         |    −17.1 |     −7.6 |      +8.4 |     −3.6 |     −14.0 |     −10.4 |      +16.4 |     +0.3 |
| tabu            |    −22.6 |    −18.4 |      +5.5 |     −6.0 |     −23.8 |     −24.2 |      +12.4 |     −7.1 |

Best seed at equal CPU:

| Method          | azerty N | qwerty N | ergopti N |   bepo N | azerty DQ | qwerty DQ | ergopti DQ |  bepo DQ |
| --------------- | -------: | -------: | --------: | -------: | --------: | --------: | ---------: | -------: |
| late_acceptance | **−1.4** | **+1.2** | **+14.0** | **+4.7** |      −5.5 |  **−2.0** |  **+21.2** |     +6.1 |
| annealing       |     −9.6 |     −5.4 |     +10.7 |     +2.9 |  **−3.2** |      −3.6 |      +16.2 | **+9.1** |
| hill_climbing   |    −11.8 |     −8.1 |     +11.4 |     +0.8 |     −15.1 |     −14.7 |      +18.0 |     +1.6 |
| genetic         |     −6.3 |     −5.5 |     +10.3 |     +0.9 |      −4.2 |      −6.9 |      +17.0 |     +2.4 |
| tabu            |    −13.0 |    −13.2 |      +6.6 |     −5.5 |     −18.5 |     −10.1 |      +13.9 |     −2.0 |

Spread between seeds at equal CPU (best − worst):

| Method          | azerty N | qwerty N | ergopti N | bepo N | azerty DQ | qwerty DQ | ergopti DQ | bepo DQ |
| --------------- | -------: | -------: | --------: | -----: | --------: | --------: | ---------: | ------: |
| late_acceptance |     12.5 |      7.5 |       3.1 |    5.1 |      10.9 |       5.5 |        6.8 |     3.9 |
| annealing       |      8.3 |     10.2 |       7.4 |   10.9 |       9.8 |       9.7 |       11.7 |     9.1 |
| hill_climbing   |      1.8 |      2.1 |       0.0 |    0.0 |       1.5 |       1.7 |        0.2 |     0.0 |
| genetic         |     15.8 |      5.4 |       2.7 |    6.9 |      17.5 |      10.2 |        1.8 |     7.6 |
| tabu            |     15.3 |     13.0 |       6.2 |    7.2 |      11.9 |      16.4 |        3.9 |     7.3 |

Median final score at 5,000 trials, on the whole corpus (equal trial count):

| Method          | azerty N | qwerty N | ergopti N |   bepo N | azerty DQ | qwerty DQ | ergopti DQ |  bepo DQ |
| --------------- | -------: | -------: | --------: | -------: | --------: | --------: | ---------: | -------: |
| late_acceptance | **−8.9** | **−2.3** | **+10.3** |     −0.4 |     −11.0 |      −8.2 |  **+17.0** |     +2.8 |
| annealing       |    −13.5 |     −9.5 |      +5.8 |     −1.3 |  **−7.0** |  **−8.0** |       +6.8 | **+4.5** |
| hill_climbing   |    −14.6 |     −9.6 |      +9.9 |     −1.0 |     −17.4 |     −16.4 |      +16.8 |     +0.0 |
| genetic         |    −15.5 |     −6.5 |      +9.7 | **+1.8** |     −14.1 |      −9.6 |      +16.3 |     +2.6 |
| tabu            |    −25.2 |    −20.5 |      +4.1 |     −7.7 |     −25.8 |     −26.3 |      +11.0 |     −8.7 |

Convergence, the median at ¼, ½ and all of the CPU budget:

| Method          | azerty N              | ergopti N            | bepo N               | bepo DQ              |
| --------------- | --------------------- | -------------------- | -------------------- | -------------------- |
| late_acceptance | −43.6 / −17.5 / −9.1  | +9.4 / +11.8 / +11.9 | −8.5 / −0.3 / +1.6   | −5.8 / +3.1 / +4.5   |
| annealing       | −63.1 / −35.1 / −15.2 | −3.6 / −3.6 / +6.6   | −34.1 / −31.7 / +1.0 | −30.5 / −11.8 / +6.3 |
| hill_climbing   | −70.4 / −44.9 / −13.6 | +4.9 / +8.5 / +11.4  | −16.8 / −4.7 / +0.8  | −10.2 / −3.1 / +1.6  |
| genetic         | −41.6 / −25.9 / −17.1 | +3.6 / +6.7 / +8.4   | −22.8 / −13.8 / −3.6 | −22.1 / −2.8 / +0.3  |
| tabu            | −22.6 / −22.6 / −22.6 | +5.5 / +5.5 / +5.5   | −6.0 / −6.0 / −6.0   | −7.1 / −7.1 / −7.1   |

Trials per second of CPU time (of wall time):

| Method          | azerty N  | qwerty N  | ergopti N | bepo N    | azerty DQ | qwerty DQ | ergopti DQ | bepo DQ   |
| --------------- | --------- | --------- | --------- | --------- | --------- | --------- | ---------- | --------- |
| late_acceptance | 590 (305) | 681 (326) | 388 (199) | 207 (115) | 624 (296) | 734 (369) | 465 (254)  | 214 (114) |
| annealing       | 549 (271) | 604 (302) | 260 (137) | 178 (104) | 560 (311) | 613 (335) | 321 (170)  | 177 (103) |
| hill_climbing   | 503 (255) | 586 (312) | 257 (141) | 188 (98)  | 557 (285) | 584 (314) | 321 (173)  | 184 (106) |
| genetic         | 263 (128) | 317 (160) | 116 (62)  | 61 (33)   | 282 (134) | 326 (159) | 139 (75)   | 60 (37)   |
| tabu            | 503 (258) | 597 (288) | 245 (125) | 179 (99)  | 528 (274) | 595 (302) | 318 (166)  | 180 (104) |

What the runs show:

- **Late acceptance** has the best median at equal CPU in 5 of the 8 cases
  and the best sum of ranks (11, against annealing 20, hill climbing 24,
  genetic 26, tabu 39). From a good start (Ergopti, bépo) it keeps the
  start's quality and improves at once, where annealing's first, hot half
  wrecks the start (its median is still the start's score at half of the
  budget on Ergopti). Its trials are also the cheapest: it stays near the
  arrangement the incremental scorer holds.
- **Annealing** wins the other three cases, all on Don Quichotte (AZERTY,
  bépo, and QWERTY by 0.08 point), and has the widest spread between seeds
  on the good starts.
- **Hill climbing** is nearly the same for every seed (a scan's best gain
  does not depend on the order) and good from a good start, poor from
  AZERTY or QWERTY: one step scores the whole neighbourhood (about 400 swaps
  on letters only).
- **The genetic algorithm** gains the most per trial (best on bépo N at an
  equal trial count) but its children are far from the arrangement the
  incremental scorer holds, so a trial costs 2–3 times as much: it loses at
  equal CPU.
- **Tabu search** on a candidate list stalls: forced to make the best of 24
  random swaps, it drifts below its best (a probe on AZERTY: current −67,
  best −29) and rarely climbs back. A whole-neighbourhood tabu search would
  cost hill climbing's scans.

**Default** (decided by the agent on 2026-11-20, to review by the
maintainer): late acceptance, the best by median score at equal CPU in the
most cases. No method wins everywhere, so the choice follows the most common
case, the page's defaults (letters only) on a French corpus: late acceptance
wins all four starts on Nemolivier and both Ergopti cases, and loses to
annealing on Don Quichotte from AZERTY, bépo and QWERTY (there by 0.08
point). Annealing stays one choice away in the list. The page lists the
methods best first.

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

## Change penalty

« The best layout derived from AZERTY with the fewest changes »: the search
may pay for leaving its start layout. `LAYOUT_OPTIMIZER.changeCost(engine, p,
tables)` weighs each corpus character by its occurrences, the space left out
(`LAYOUT_ANALYSIS.similarityWeights`, the weighting of `layoutSimilarity`), so
moving « e » costs far more than moving « § ». A character is typed by the
units on its way in the start layout: its own cell, else the dead key of its
rule and the letter typed after it (and the dead-key layer's place when that
layer moves), else, for a typographic character the start lacks, the ways of
its plain form (the engine's `substitutions()`: « … » as « ... »). It has
changed when any of those units has left its home, the slot the start gives
it (the QWERTY pins and zones count). The share changed, in %, is 100 −
`layoutSimilarity`'s weighted same-key share for the arrangements a search
makes (property test on AZERTY and bépo, gap 0). Two cases differ a little:
a character typed several ways (Ergopti's « ù »: AltGr+R, or the circumflex
then « w ») is placed on its first way where the engine takes its cheapest,
and a character reached only through a chain of dead keys (Ergo-L's « ¨ »)
is left out, as one the start does not type (gap under 1 point of % on
Ergopti after 300 random swaps).

**Objective.** With `changeWeight` w (score points per % moved; a search
setting with `changeCost`), the search maximises score − w × share. A tracker
(`changeCost(...).tracker`) follows the arrangement the search stands on: a
swap of units a and b walks only the characters whose way holds a or b, and
`trial(a, b)` equals the full recompute `moved()` after every swap (property
test: 400 random swaps on AZERTY, bépo with AltGr, Ergopti with its dead-key
layer, gap 0). With w = 0 and no limit the search follows no change at all:
every draw and score is the one without a penalty, to the bit. The result
says what it changes (`change`: the share, the units moved, each with its
share); a runner's `done` result has `engineScore`, the engine's score on the
whole corpus, and `score`, that less the penalty, which `bestOf` compares.

**Hard limit.** `maxChanges` N keeps every arrangement within N changed units
(a letter and its capital are one unit; a hole is none): `pickSwap` refuses a
swap that would pass it, a random start shuffles within it, and pins or zones
that already pass it are refused (`change_limit_start`).

**Defaults** (`score_weights.json` `change_penalty`, read by
`LAYOUT_ANALYSIS.changePenalty()`, checked by the codegen): presets « few
changes » 3, « balanced » 1 and « free » 0, the slider up to 5, a limit of
6 when the reader switches it on, « free » chosen first (maintainer, `docs/memory/maintainer-decisions.md`,
« The Optimiser's change penalty starts free, at 0 »). Measured on AZERTY, the first 60 000 characters of
6 when the reader switches it on, « free » chosen first (decided by the agent on 2026-11-19, validated by the
maintainer on 2026-11-21). Measured on AZERTY, the first 60 000 characters of
Nemolivier, 3 000 swaps, seed 1: weight 0 moves 92 % of the typed characters
for +102 points, 1 moves 71 % for +95, 3 moves 8 % for +36.

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
   « Réglages du score », the app's window unfolds it), the search method
   (a list, best first, the default marked, the chosen method's short
   explanation under it and an « i » that says how it searches), the budget folded
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

**Changes from the start** (step 2, [Change penalty](#change-penalty)): the
presets as radio buttons (their weight in their name), a slider of the weight
whose value is said in words (an `<output>` and the slider's
`aria-valuetext`), a value of the reader's own ticking no preset, and « at most
N changed characters » with its count. While the run goes, the result's « What
it changes » says the best layout's score gain, the characters it moves, their
weighted share (a `<meter>`, its number in text) and, with a weight, the
penalty it pays, and lists the moved characters most typed first, each with
its share and a bar hidden from assistive technology. With a weight, the
chart and the shelf follow the search's objective (the score less the
penalty); the tiles and the metrics say the engine's score.

**Use it on your computer.** Under the result, « Download » in a format of
« Éditer » (`LAYOUT_ANALYSIS_FILES.EDITOR_DOWNLOADS`, the list its export tool
offers from and refuses to leave, in its own words), « Install on the system »
and « Emulate without installing ». None of them is the optimizer's own: each
hands the layout to « Éditer » with an intent (`{action, format?}`), which
opens it in a new tab on its « Export » tool and runs the same code as its own
controls (`openLayout(layout, intent)`): the download of that format (said
when the host cannot make it), or the install or emulation after the same
confirmation, through the window's host actions (`composer_save`,
`composer_emulate`). On the site the hand-off goes through the tab's storage
(`handOffToEditor(layout, intent)`, `takeEditorIntent`) and only downloads:
installing and emulating say they need the app. In the app (`exportLayout`
and `emulates` of the host), installing is a layout DLL on Windows, a
`.keylayout` on macOS and the XKB files on Linux; emulating is offered where
the driver's layout emulation runs (`initData` `emulate`), and said otherwise.

The page keeps the reader's choices (corpus, start, keyboard, switches, pins,
QWERTY letters and what of them stays, zones, the open sub-tab, search method, budget) and their last text in this browser's storage
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
layout's score minus its own, in the score's points, and `percent`, how
much higher the higher of the two marks is (`LAYOUT_ANALYSIS.markGap`: the
mark has a zero, the worst layout possible, so its gaps read as ratios;
[layout-analysis.md](layout-analysis.md#mark)). Every entry carries its
`mark` and `zero`; entries on two zeros are refused, and the optimized
layout's mark is its total less that zero. The card writes the gap in %
with the points beside it. The verdict reads the best existing layout's
gap in points, against the small gap the maintainer confirmed in points:

| Verdict           | When                          | Says                                                                    |
| ----------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `small_gap`       | 0 ≤ gap ≤ `similar_score_gap` | That layout would do the job; the optimized one is only so much better. |
| `optimized_ahead` | gap > `similar_score_gap`     | The optimized layout leads the best existing one by that much.          |
| `existing_better` | gap < 0                       | An existing layout scores more; a longer run may close the gap.         |

`similar_score_gap` (`analysis_model.json`, read by
`LAYOUT_ANALYSIS.similarScoreGap()`, checked by the codegen) is 2 points
(confirmed by the maintainer on 2026-11-19): about one 1 u SFB in 500
bigrams (0.2 % at 5 flat and 0.26 per millimetre of its travel), and about
the gap between Ergopti+ and Ergopti on the Nemolivier anthology (1.7
points).

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
only), keyboard ISO, format TKL, default weights, 1 annealing restart of 3 000 swaps on
99 % of the n-grams: 14 s in Node, score −87.9 → +14.0 (Ergo-L 11.8, Ergopti
24.6 on the same corpus and options, with their own punctuation and digits).
These are totals, measured before the mark; the page's tiles, chart and shelf
now show marks (total − the run's zero, its start's), the gains staying in
points.

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
