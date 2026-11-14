<!-- docs/design/analyser-scores.md -->

# Scores of the other layout analysers

Beside Ergopti's own global score, Ergopti Studio (« Comparer » and the
« Éditer » side panel, on the site and in Ergopti+ on Windows, macOS and Linux:
the same shared page everywhere) shows each layout's score as the major public
layout analysers compute it. This page records, per analyser, the formula, the
default constants, the corpus and geometry it assumes, the revision read, its
licence, how faithful our reproduction is and the vector that proves it.

The study the engine came from is
[docs/audits/layout-analysers/report.md](../audits/layout-analysers/report.md);
the engine itself is [layout-analysis.md](layout-analysis.md).

## Files

| File                                                                             | Role                                                                  |
| -------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `static/ergopti_plus/_shared/ui/layout_analysis/analyser_scores.js`              | The scorers: classic script, global `LAYOUT_ANALYSER_SCORES`, no DOM. |
| `static/ergopti_plus/_shared/layouts/data/analysis/analyser_models.json`         | Every constant, per analyser, with its source, revision and licence.  |
| `static/ergopti_plus/_shared/tests/corpus/layout_analysis/analyser_vectors.json` | Reference vectors; `npm run test:analyser-scores`.                    |
| `static/ergopti_plus/_shared/tests/corpus/layout_analysis/analysers/`            | Fixtures: KLA's Alice preset, Ergo-L's corpus tables and two keymaps. |

The codegen (`npm run codegen:layout-analysis-data:js`) copies
`analyser_models.json` into `LAYOUT_ANALYSIS_DATA.analysers`, checking that
every entry names its source, revision, licence, fidelity and direction.

## Basis

Every scorer is our own code, written from the analyser's published source
code, documentation or published results: no line of an analyser's code is in
the repository, only the numbers (weights, cost grids, key positions) its
formula uses, each credited to its file. Where only results are public
(KLAnext), the formula is reconstructed from them and marked so. A scorer
runs on the corpus's cached, layout-independent n-gram tables
(`LAYOUT_ANALYSIS.prepareNgrams`): it applies the analyser's own character
filter, fingering and geometry to them, never a pass over the text per layout.
Corpus-only derived tables (carpalx's letter triads, Oxeylyzer's tokens,
Ergo-L's lower-cased tables) are cached per prepared table.

**Fidelity** is `exact` when the scorer gives the analyser's own number on the
same input (checked against its output), `close` when one known approximation
remains (stated), `approximate` when the formula itself is reconstructed.

## API

On `LAYOUT_ANALYSER_SCORES`; every invalid input throws.

- `ORDER`: the analyser ids, in display order.
- `analysers()` → `[{id, name, author, url, repository, revision, licence,
fidelity, better, unit, digits, headline}]`; `better` is `higher`, `lower` or
  `none` (an analyser without a score; `headline` names the parts to show
  instead).
- `score(id, layout, ngrams, {keyboard})` → `{id, value, better, fidelity,
unit, parts}`; `value` is `null` for an analyser without a score.
- `score(…, {keyboard, profile, fingering})`: `fingering` is `official` (the
  default) or `custom` (see « Two fingerings »).
- `scoreAll(layout, ngrams, {keyboard, profile})` → `{id: {official, custom}}`,
  sharing the per-layout work between scorers.

`layout` is the engine's library shape; `keyboard` is the engine's (`iso`,
`iso_angle`, `ansi`, `ortho`), mapped to each analyser's own boards below. In
Node, one fingering of `scoreAll` takes about 35 ms per layout on the French _Don Quichotte_
(Keyboard Layout Optimizer is the slowest, about 10 ms); inside a `vm`
context, where global lookups are slower, about 100 ms. The gate holds both
fingerings under 600 ms per layout in a `vm` context.

## Two fingerings

Every analyser is shown twice, side by side (maintainer, 2026-11-14): its
**official** score, with the analyser's own fingering, and its score under the
user's **custom** finger model (the engine's `keyboard(id, profile)`: each
key's finger and each finger's home key). In custom mode each key the model
knows takes its finger from it, and KLA's fingers start from the model's home
keys; keys the model does not know (Enter, Tab, the modifiers of Keyboard
Layout Optimizer's board) keep the analyser's own finger. genkey has no thumb
finger and Ergo-L assigns no thumb key: a key the model gives a thumb leaves
their statistics. Where the user's model is the analyser's own, the two
numbers are equal (QWERTY letters: carpalx, keygen, genkey, Oxeylyzer); they differ
where the analyser's fingering is not the user's (keygen types Space with
the right thumb, the default model with the left; Keyboard Layout Optimizer
fingers the number row one key over; KLAnext weighs the left hand 10 % more).

## How each analyser types a character

All the analysers but Ergo-L and Ergopti's own engine see one key per
character and no dead keys: a character reached through a dead key is
dropped (KLA, KLAnext, Keyboard Layout Optimizer: « not found ») or counted as
unknown (a200, cmini, Oxeylyzer), as the analyser itself would do with a
layout file of its format. Ergo-L follows dead keys and chained dead keys with
its own preference rule.

## The analysers

### KLA (Keyboard Layout Analyzer)

- **Source.** https://github.com/patorjk/keyboard-layout-analyzer,
  `js/analyzer.js` and `common/pat/keyboard/js/kb.js`, revision 7ef2fe6
  (2019-12-27). Licence: MIT (`LICENSE.txt`). Site:
  https://patorjk.com/keyboard-layout-analyzer/.
- **Formula.** A typing simulation: before each character the fingers it does
  not use return home; Shift (the other hand's) and AltGr are pressed when they
  go down; each press is compared with the previous one for same finger and
  same hand. `score = 17·shS + 17·sfS + 33·fingerS + 33·distS` (higher is
  better, out of 100), with `distS = max(0, 4 − cm per press)/4` (50 px =
  1.9 cm, Euclidean between key centres), `fingerS = Σ min(% per finger, 20)·w
/ 260` (w: pinky 0.5, ring 1, middle 4, index 2, thumb 0.5), `sfS = max(0, 10
− % same-finger presses)/10` and `shS = max(0, 50 − % same-hand presses)/50`
  (same-key repeats excluded, thumbs not a hand).
- **Our model.** Every counter depends on two consecutive characters, so the
  simulation is summed over character bigrams, plus each run's first and last
  character (fingers start home, and go home at the end). KLA's own key centres
  (`standard` for `ansi`, `european` otherwise), its fingering (Space on the
  left thumb, the layout's angle mod kept), a character's first key in KLA's
  matrix order. A line break is Enter: tables cut at line breaks
  (`ngramsFromText`) get them back as each run's end and the next run's start
  joined through Enter in proportion; a character KLA skips joins its
  neighbours (from the trigrams).
- **Fidelity: exact.** Vectors (KLA's own code run on the same text): `the` on
  QWERTY 54.3077; KLA's _Alice_ chapter 1 preset, line breaks kept: QWERTY
  53.0568, AZERTY 49.5354 (4 decimals). On the same text cut at its line breaks,
  0.04 to 0.05 points lower.

### KLA, SteveP's fork

- **Source.** https://github.com/stevep99/keyboard-layout-analyzer, revision
  945fe9f (2021-05-01); no licence file in the fork (a fork of the MIT KLA).
  Site: https://stevep99.github.io/keyboard-layout-analyzer/.
- **Formula.** KLA's simulation with a Fitts-style penalty instead of
  distance: each move turned 10° toward its hand (not thumbs), `log2(1 + d /
key size)` per axis, lateral ×2.0, vertical pinky 1.6 / ring 1.3 / middle 1.1
  / index 1.0, thumbs ×1.25. `distS = 100·max(0, 3 − penalty per press)/3`,
  `fingerS = 100·max(0, 3 − 2·(usage + imbalance))` (finger weights 1.6 / 1.3
  / 1.1 / 1.0, thumb 1.0; imbalance against the mirror finger), `sfS =
10·max(0, 10 − % same finger)`; `score = 0.5·distS + 0.2·fingerS +
0.3·sfS`.
- **Fidelity: exact.** Vectors (the fork's own code): `the` on QWERTY 41.3333;
  _Alice_: QWERTY 46.5481, AZERTY 38.9089.

### KLAnext (reconstructed)

- **Source.** https://klanext.keyboard-design.com (Ian Douglas), closed source,
  no licence published; nothing of it is used but its published numbers: the
  result tables in the screenshots of the Ergo-L repository
  (`www/content/articles/analyse_et_optimisation/klanext_*.png`, revision
  03c6c7c). The structure follows Keyboard Layout Optimizer's re-implementation
  of the KLAnext metrics (`config/evaluation/klanext.yml`, GPL-3.0, read only).
- **Formula.** Stated by KLAnext: distance 40 %, same-finger bigrams 40 %, hand
  alternation 20 %, lower is better; observed: Overall = Distance + Same Finger
  - Same Hand. Reconstructed: Distance = 0.4392·Σ fw·hw·(px moved + 21.05 px per
    press) / bigrams; Same Finger = 491.25·Σ fw·hw·same-finger presses (repeats
    included) / bigrams; Same Hand = 29.43·Σ hw·same-hand, different-finger
    bigrams / bigrams; finger weights pinky 3.67, ring 2.9, middle 2.0, index
    1.85, thumb 1.0, left hand ×1.1. The three constants are fitted (the first
    two match Keyboard Layout Optimizer's 0.44 and 490.2; Same Hand is one
    constant fitted on two published rows).
- **Fidelity: approximate.** Checked once, not in the gate: QWERTY ANSI on
  « Chained English Bigrams 7 », published 207.32, ours 207.26 with line breaks
  kept (the text is not kept in the repository: its licence is unknown). On
  tables cut at line breaks the blank lines (Enter repeats) are lost: about 4 %
  lower on that corpus of short lines. Gate: hand-computed (`the` on QWERTY
  ANSI, 174.2699: distance only). Re-fit when the live site is reachable.

### a200 (200-analyzer)

- **Source.** ClemenPine's analyser, whose own repository is gone; final variant
  in https://github.com/Waterdragen/akl-ws, `python/apps/a200/`, revision
  8141890 (2024-03-25). Licence: GPL-3.0 (repository `LICENSE.txt`).
- **Statistics, no score** (its only ranking is a percentile within its own
  layout folder). Trigram classes on raw characters (case kept, space on a
  thumb, Shift ignored): alternates, rolls in/out, one-hand in/out, redirects,
  SFB (a trigram with a same-finger pair), DSFB, SFT, SFR (a repeated
  character), unknown; finger use (space on the thumb) and row use. The default
  « AVG » mode averages every value with the space on the left and on the right
  thumb, ratios included. Fingering: the layout's.
- **Fidelity: exact.** Vector in the gate: hand-computed (`thea`). Checked once,
  not in the gate (the corpus is GPL data of the a200 repository): Graphite on
  its `monkeytype-quotes` corpus reproduces the Graphite README's « A200 » block
  to 2 decimals (alternates 30.47 %, rolls 47.56 %, ratio 0.89, redirects
  6.23 %, …) but SFB 1.03 % for 1.04 % and RR 12.34 % for 12.33 %, from our
  library's Graphite.

### carpalx

- **Source.** Martin Krzywinski's carpalx 0.12, http://mkweb.bcgsc.ca/carpalx/,
  read in the mirror https://github.com/narze/carpalx (95f46d0, 2016-11-27):
  `bin/carpalx`, `etc/effort/*`, `etc/keyboards/*`. Licence: GPL-2.0-or-later
  (header of `bin/carpalx`).
- **Formula.** Mean triad effort, lower is better, QWERTY = 3.000 on its book
  corpus: `e = kb·k1·b1·(1 + k2·b2·(1 + k3·b3)) + kp·k1·p1·(1 + k2·p2·(1 +
k3·p3)) + ks·(ph + 0.3·pr + 0.3·pf)` with base effort per position, penalty
  `1·hand + 1.3088·row + 2.5948·finger`, the hand, row and finger flags of the
  triad, `kb, kp, ks = 0.3555, 0.6423, 0.4268`, `k1, k2, k3 = 1, 0.367, 0.235`.
  Its English mode keeps a-z only (lower case) and deletes everything else, so
  triads join across spaces within a line; identical triplets and triads seen
  fewer than 10 times in 9 151 165 are dropped (the threshold scales with the
  corpus). Its own finger map and 4-row ANSI grid, whatever the board;
  IntlBackslash, which carpalx lacks, is our extension at KeyZ's effort.
- **Fidelity: close.** Exact for letters-only text: on its `books.txt` with the
  non-letters removed, our scorer gives the published table (QWERTY 3.000,
  Dvorak 2.098, Colemak 1.842, Workman 1.993, QGMLWY 1.670, and their base,
  penalty and path parts). From the raw text, a triad across a deleted run is
  estimated from the trigrams (Markov): within 0.006. Gate: hand-computed
  triads (`the` 3.463055, `and` 3.534177, `tbt` 5.744381).

### keygen

- **Source.** https://github.com/xsznix/keygen (Xuming Zeng), `src/penalty.rs`,
  revision 37ae949 (2024-09-09). Licence: MIT (stated in the README; no
  licence file).
- **Formula.** Penalty per character of the corpus, lower is better: a base
  cost per key and penalties on the last key given up to three previous ones
  (same finger 5 + 5 per centre-column key, long jumps 1 / 10 / 5, pinky-ring
  twist 10, roll reversal 20, twist 10, long-jump sandwich 3, rolls out +0.125
  and in −0.125, same hand and alternating hand over four keys 0.5). Runs reset
  on a character outside keygen's own set; Space is the right thumb.
- **Fidelity: close.** The four-key runs are estimated from the trigrams
  (Markov), and a text cut into runs counts one line break per cut in the
  length. On carpalx's `books.short.txt` with keygen's own five layouts, within
  0.3 % of an independent transcription of `penalty.rs`. Gate: hand-computed
  (`the` 1.8333).

### genkey

- **Source.** https://github.com/semilin/genkey (semi), version 1.2, revision
  f1f4173 (2024-07-03), `config.toml`, `layout.go`, `generate.go`, `text.go`.
  Licence: GPL-3.0-or-later.
- **Formula.** `3·finger speed + 1·LSB % + 0.3·|right index % − left index %|`,
  lower is better. Finger speed: `800 · Σ (SFB + 0.5·DSFB)·(1.4·dx² + dy² +
0.02) / speed of the finger / letters` (speeds 1.5 / 3.6 / 4.8 / 5.5 from
  pinky to index); LSB: adjacent fingers two columns or more apart. Corpus:
  lower case, `? : _ "` folded, only `a-z , . / ; - '` kept, anything else
  resets. Its ortho grid and column fingering (the layout's angle mod kept);
  base layer only.
- **Fidelity: approximate.** genkey weights skipgrams up to a gap of 9; the
  tables hold the gap of 1 only, scaled by 1.5486 (the ratio of all skipgrams
  to skip-1 on genkey's default corpus): from +0.8 % to −9 % on three layouts.
  Gate: hand-computed (`ge` 65, `ded` 342.581).

### Oxeylyzer

- **Source.** https://github.com/O-X-E-Y/oxeylyzer, revision 5a85ca0
  (2026-11-12), `config.toml` and `oxeylyzer-core`; corpus configs on its
  `data-files` branch (9cd336c); key geometry from `libdof` 0.25.0. Licence:
  Apache-2.0 (`LICENCE.md`).
- **Formula.** Higher is better; shown as Oxeylyzer does, `total / characters /
100`. Total = trigram classes (inrolls 2.5, outrolls 2.4, onehands 0.9,
  alternates 0.4, alternates-sfs 0.1, redirects −3.4, redirects-sfs −4.2, bad
  redirects −4.9, bad redirects-sfs −5.5) + same-finger pairs `−7·(bigrams +
r·skip1 + r²·skip2 + r³·skip3)` (r = 1/7) times the distance and 5.5 / finger
  weight + stretches `−0.3·…` times the stretch distance + pinky-ring bigrams
  −0.2, with Oxeylyzer's integer truncations. Corpus: a-z and unshifted
  punctuation kept, capitals and Shift forms preceded by a Shift token,
  everything else (space, accents) dropped. Its 3 × 10 letter block,
  traditional fingering; on the row-staggered board, or its own ortho grid when
  the keyboard is `ortho` (its default layouts).
- **Fidelity: close.** The tables hold no skip-2 or skip-3 grams; skip-1 stands
  for them (+0.75 % on QWERTY with Oxeylyzer's default corpus, against −3.9 %
  without them). Gate: hand-computed from the source (`the` 0.1333, `decided`
  −6.3314 on the staggered board, −6.0214 on ortho).

### Keyboard Layout Optimizer (dariogoetz)

- **Source.** https://github.com/dariogoetz/keyboard_layout_optimizer,
  revision 8c8ec9f (2026-04-24), `config/evaluation/default.yml`,
  `config/keyboard/standard.yml`, `layout_evaluation/src/`. Licence:
  GPL-3.0-or-later. Site: https://dariogoetz.github.io/keyboard_layout_optimizer/.
- **Formula.** The sum of 12 weighted metrics, lower is better: finger balance
  (50), hand disbalance (40), modifier usage (100), key costs (20), finger
  repeats (780), movement pattern (100), no hand switch after an unbalancing key
  (36), no hand switch in a trigram (400), irregularity (8.25), secondary
  bigrams (0.1), inward rolls (−2) and outward rolls (−1), each over the
  characters, bigrams or trigrams found, on key n-grams where held modifiers
  are presses of their own. Its ISO board with costs, unbalancing and matrix
  positions; a character takes its cheapest key, Shift of the other hand.
- **Fidelity: exact** for base and Shift layers: its own evaluator run on `the`
  (270.797), `The` (576.958) and `Hello, World.` (2 656.977) on its QWERTY;
  our scorer gives the same to 1e-9. On its default German-English corpus, our
  QWERTY UK gives 539.4 for its 542.6 (every part within 0.5 % but
  irregularity, a square root of products, 12 % lower). AltGr is our
  adaptation (held AltRight): the tool models Neo layers, not AltGr.

### cmini

- **Source.** https://github.com/Apsu/cmini (AKL community Discord bot),
  revision 0db088e (2026-08-23), `util/analyzer.py`, `table.json`. Licence:
  GPL-3.0.
- **Statistics, no score** (`rank` sorts by one statistic). The « view » block:
  SFB over every bigram; alternates, rolls in/out, one-hand in/out, redirects,
  bad redirects (no index), SFS (same and other hand) over every trigram;
  n-grams inside words only (no whitespace), case folded, base-layer characters;
  hand use. The finger-triple table is the rule documented in the code
  (`cminiClass`), checked against all 1 000 entries of `table.json`.
- **Fidelity: exact.** On cmini's `shai` corpus with cmini's own QWERTY (the
  letter block), our scorer gives cmini's cached output to 6 decimals on every
  trigram class (checked once; the corpus is GPL data of the cmini
  repository). Gate: hand-computed tables.

### Ergo-L analyser and Kalamine statistics

- **Source.** https://ergol.org/stats/, `code/layout-analyzer.js` of
  https://github.com/Nuclear-Squid/ergol (03c6c7c, 2026-09-22; WTFPL v2); the
  same analyser in Kalamine, `kalamine/www/mjs/layout-analyzer.js` of
  https://github.com/OneDeadKey/kalamine (a9724bf, 2026-04-19; MIT).
- **Statistics, no score, by design** (the page judges a layout by its worst
  criterion). SFU and SKU, LSB, scissors and extended scissors, inward and
  outward rolls (key bigrams), SFS, SKS, redirects and bad redirects (key
  trigrams), finger and hand load, unsupported characters. Corpus filter:
  lower case, digits, spaces and line breaks dropped and cutting the n-grams.
  Each character's key sequence by Ergo-L's rule: dead keys and chains
  followed, a sequence through the one-dead-key preferred, then fewer keys
  outside the 3 × 10 block, a lower level, fewer keys. Fixed ISO fingering.
- **Fidelity: exact.** Vector (Ergo-L's own code on its en+fr corpus tables and
  keymaps, all fixtures in the gate): Ergo-L SFB 1.144883 %, LSB 5.726244 %,
  scissors 1.191414 %, … to 6 decimals; QWERTY to 4. Finger load within 0.001
  (Ergo-L divides by 100 where its rounded tables sum to slightly less). The
  library's Ergo-L lacks the one-dead-key-on-itself chain (ë), 0.002 %
  unsupported.

## Not covered

Listed by the search for this work, not reproduced (no score, or a score made
of the user's own timings): Keysolve 2 (percentiles against a bundled table),
trialyzer (the user's typing times), keymui / keymeow (metrics, no score),
mw8/white_keyboard_layout, engram, kuehlmak, Oxeylyzer 2 and the newer
analysers with a few stars (mana, keycraft, chogalyzer, stronglytyped). KLA's
`ergodox` and `matrix` boards are not modelled.
