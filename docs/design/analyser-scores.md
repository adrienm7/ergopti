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

**Access weights.** Ergopti's own score costs the way a character is reached
by three weights the user edits (`modifier_usage` 0.5, `altgr_usage` 2,
`dead_key_usage` 2; [layout-analysis.md](layout-analysis.md#ways-of-typing),
« Access weights »), which also choose the way of typing of a character that
has several. The scorers of this page model other tools, so they type
(`keyNgrams`) by the default access weights whatever the user's: an edit of
them changes no number on this page.

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
  matrix order. A line break is Enter and a tab is Tab, read from the break
  tables of `ngramsFromText`; a table without them (a count table, a word
  list) gets each run's end and the next run's start joined through Enter in
  proportion. A character KLA skips joins its neighbours (from the trigrams).
- **Fidelity: exact.** Vectors (KLA's own code run on the same text): `the` on
  QWERTY 54.3077; KLA's _Alice_ chapter 1 preset, line breaks kept: QWERTY
  53.0568, AZERTY 49.5354 (4 decimals), the same from the engine's tables
  with their break tables (before them, 0.04 to 0.05 points lower).

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
  _Alice_: QWERTY 46.5481, AZERTY 38.9089 (line breaks kept or from the break
  tables).

### KLAnext (reconstructed)

- **Source.** https://klanext.keyboard-design.com (Ian Douglas), version 0.06,
  closed source, no licence published; nothing of it is used but its own
  numbers: its « Summary » table (Overall, Distance, Same Finger, Same Hand)
  and its per-finger tables, read on its site for texts written to isolate
  each term (`the`, `ee`, `th⏎⏎e`, `e␣`, one character at a time…) and for 14
  of its preset texts (2026-11-18). Its layout names map to our library in
  `tools/dev/analyser-reference/klanext.json`.
- **Formula.** Lower is better, Overall = Distance + Same Finger + Same Hand,
  each over N, the characters of the text: Enter, Tab and the characters it
  cannot type included (they type nothing but count; one it cannot type joins
  its neighbours), CR dropped. KLA's typing simulation (fingers go home, the
  Shift of the other hand, a released Shift is the previous press), with
  finger weights pinky 3.67, ring 2.9, middle 2.0, index 1.85, thumb 1.0 and
  the left hand (thumb included) ×1.1:
  - Distance = 0.44 · Σ weight · (px moved + 21.05 px per press) / N (50 px =
    1.9 cm: 11.58 per weighted cm, 0.8 cm per press);
  - Same Finger = 492 · Σ weight · presses on the finger of the previous press
    (repeats included) / N;
  - Same Hand = 68.2 · (Σ hand weight · presses on the hand of the previous
    press / N)², thumbs counted with their hand, repeats included: the square
    is what the published code rows (Same Hand 18 to 24) needed.
  - KLAnext's layout files type Space with the right thumb on QWERTY, Colemak
    and Workman (the left on the others), and its Dvorak fingers the number row
    6, 8, 9, 0 with left index, right index, middle and ring (model
    `layout_fingering`, by library id). It maps no typographic character to a
    plain one (’ is not ').
- **Line breaks.** Enter and Tab come from the break tables of
  `ngramsFromText`, so blank lines (Enter repeats) and indentation tabs are
  typed as KLAnext types them. A table without them (a count table, a word
  list) gets its runs joined through Enter in proportion, as for KLA.
- **Fidelity: exact.** The three constants and every rule were read from
  KLAnext's output on hand-made texts; on 14 presets × 9 layouts (126 points:
  prose, chained English, « Proglish » and code bigrams, pangrams, Spanish
  UDHR), every column is within 0.005 of the site's 2-decimal number once the
  keys KLAnext's own layout files place differently are applied (its
  Capewell, UCIEA and MTGAP put brackets and a few signs on other keys, its
  Workman swaps `;` and `'`; listed in the reference file). With our
  library's layouts as they are, the Overall gap is 0.18 % on average, 2.5 %
  at most (code presets on those four layouts; our Dvorak is the ANSI one
  since 2026-11-18, 0.19 % on average before). Before this
  reconstruction (bigram denominators, a linear Same Hand fitted on two
  rows, no Enter repeats): 4.96 % on average, 10.9 % at most. Gate: 11 of
  KLAnext's own values on short texts (Enter repeats, Tab, Shift, Space
  thumb, a character it cannot type, CR LF, Dvorak's number row), within the
  0.005 of its rounding. `tools/dev/verify-analyser-scores.cjs` re-measures
  the presets (it downloads them; their licence is unknown, so they are never
  stored here).

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
  library's Graphite. Measured against a200 itself (its `src/analyzer.py`,
  AVG mode, on the data its `src/gendata.py` builds from each text's words,
  its word-list model) on _Alice_, _Sherlock Holmes_, English Wikipedia,
  Python code and _Germinal_ with 10 of its layout files (50 points): every
  statistic within 1e-13 point. a200 completes a layout with its template
  (QWERTY's characters on QWERTY's fingers, out of its row use), which a
  library layout cannot hold beside the file's own keys: the template's
  punctuation the files do not place (`[ ] \ / ; ' < >` and their Shift
  forms) leaves the texts of this check. In the Studio our scorer reads the
  corpus's own trigrams instead of that word-list model. Gate: a200's own
  output on its data for a two-sentence text, on QWERTY, to 1e-9.

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
  fewer than 10 times in the corpus are dropped (`triads_min_freq = 10` of its
  `carpalx.conf`, a count, whatever the corpus's size: a text where no triad
  reaches it scores 0). Its own finger map and 4-row ANSI grid, whatever the
  board; IntlBackslash, which carpalx lacks, is our extension at KeyZ's
  effort.
- **Triads from the tables.** Each trigram (a y b) around a letter y gives the
  triads (x y z) of x, the letter before y in its line, and z, the letter
  after: a or b itself when it is a letter, else the letters reached by the
  trigrams' second-order chain through the deleted characters (backward from
  a y, forward from y b, 12 characters at most), x and z independent given a
  y b. The chain's bigram counts the runs that end there, so a line's end
  stops it. Exact for letters-only text and when each context has one
  continuation.
- **Fidelity: close.** Exact for letters-only text: on its `books.txt` with the
  non-letters removed, our scorer gives the published table (QWERTY 3.000,
  Dvorak 2.098, Colemak 1.842, Workman 1.993, QGMLWY 1.670, and their base,
  penalty and path parts). Measured against carpalx itself (Perl, 95f46d0,
  its default `carpalx.conf`, `reporteffort`) on _Alice_, _Sherlock Holmes_,
  English Wikipedia, Python code and _Germinal_ with 10 of its keyboard files
  (50 points): 0.31 % on average, 1.2 % at most (code). Before (the threshold
  scaled to the corpus's size, so _Alice_ kept the triads carpalx drops, and
  the triads across a deleted run estimated without the isolated letters, a
  or I): 1.2 % on average, 4.2 % at most. Gate: hand-computed triads (`the`,
  `and`, `tbt`, ten lines each) and carpalx's own output (`reporteffort`,
  printed to 9 decimals by a local copy): `The cat, the hat.` and `Zebras
quiz, jumping!` on ten and twelve lines (across spaces and punctuation), ten
  `the` and three `dog` on QWERTY 3.463054595 (`dog` under the threshold).

### keygen

- **Source.** https://github.com/xsznix/keygen (Xuming Zeng), `src/penalty.rs`,
  revision 37ae949 (2024-09-09). Licence: MIT (stated in the README; no
  licence file).
- **Formula.** Penalty per character of the corpus, lower is better: a base
  cost per key and penalties on the last key given up to three previous ones
  (same finger 5 + 5 per centre-column key, long jumps 1 / 10 / 5, pinky-ring
  twist 10, roll reversal 20, twist 10, long-jump sandwich 3, rolls out +0.125
  and in −0.125, same hand and alternating hand over four keys 0.5). Runs reset
  on a character outside keygen's own set; Space is the right thumb. A
  character on two keys takes the last one keygen writes in its map: the base
  layer, then the Shift layer, each in key order (Xpert's two `e`, the `w`
  keygen's own Capewell repeats). The length is the file's: every character,
  line break and tab (the break tables of `ngramsFromText`; a table without
  them counts one break per cut).
- **Fidelity: close.** The four-key runs are estimated from the trigrams
  (Markov, each end independent given the middle bigram), the only
  approximation left. Measured against keygen itself (built from 37ae949,
  `run-ref` for its own layouts, `refine` with a layout file for ours, its
  first printed score), on _Alice_, _Sherlock Holmes_, English Wikipedia,
  Python code and _Germinal_ with non-ASCII characters turned into `#` (keygen
  slices its text by character index as bytes, so it reads ASCII only; `#` is
  outside its set and cuts the run there): its 7 layouts 0.11 % on average,
  0.34 % at most (35 points); 10 library layouts 0.09 %, 0.32 % at most (50
  points). Before (one break per cut, so blank lines were missing from the
  length; the first key of a repeated character): 0.43 %, 0.93 % at most.
  Gate: hand-computed (`the` 1.8333) and keygen's own output on short texts:
  `The quick brown fox.` on QWERTY 2.64375, blank lines on Colemak, a run cut
  by `[ ]` on QWERTY, `see the eel` on Xpert (its two `e`).

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
- **Skipgrams.** genkey counts a pair of characters g apart (g = 1 to 9,
  every character between them kept, the count reset at a line end) with the
  weight 1/2^(g−1). The tables hold the gap of 1 (the trigrams); the longer
  gaps are carried forward by the trigrams' second-order chain, P(c | ab) =
  trigram(abc) / bigram(ab), computed once per corpus. The bigram also counts
  the runs that end after b, so a run's end stops the chain as genkey's reset
  does; the chain is exact when each pair of characters has one continuation.
- **Fidelity: close.** Measured against genkey itself (built from f1f4173, its
  default config, `load` then `rank`), on its 28 layout files whose finger
  matrix is its column fingering, over _Alice_, _Sherlock Holmes_, English
  Wikipedia, Python code and _Germinal_ (140 points): 1.4 % on average, 9.9 %
  at most (code). An own transcription of the formula fed with genkey's exact
  skipgrams gives its output to 9 decimals, so the skipgram chain is the whole
  gap. Before (skip-1 scaled by 1.5486, the ratio of all skipgrams to skip-1
  on genkey's default corpus): 5.5 % on average, 20.5 % at most. Gate:
  hand-computed (`ge` 65) and genkey's own output (`rank`, printed to 9
  decimals by a local build) on short texts where the chain is exact: `ded`
  on QWERTY 341.666666667 (342.581 with the old scale), `The Lazy Dog` on
  Colemak, `minimum: "on-off" aloud` on Workman (case, substitutions), three
  lines on QWERTY (the reset at each line end).

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
  punctuation kept; a capital or a Shift form writes a Shift token unless the
  last kept character was shifted too (a dropped character does not release
  Shift); everything else (space, accents, line breaks) is a gap no n-gram
  spans, though a skipgram spans one character, and one spans the Shift
  token (x, Shift, y). No layout types the Shift token: the n-grams through
  it count in the totals and score nothing. Its 3 × 10 letter block,
  traditional fingering; on the row-staggered board, or its own ortho grid when
  the keyboard is `ortho` (its default layouts).
- **Fidelity: close.** Measured against the real REPL (built from 5a85ca0, its
  default weights, `analyze` on its ortho layouts) on four of our texts
  (_Alice_, _Sherlock Holmes_, English Wikipedia, Python code) and _Swann_
  (French), 18 layouts whose letter block our library shares: Score within
  0.0044 on average, 0.012 at most (72 points of the four English texts and
  code; _Swann_ within 0.010). Two approximations remain, both measured by
  feeding the scorer exact token tables built from the text: the tables hold
  no skip-2 or skip-3 grams, so skip-1 stands for them (about 0.002), and
  Oxeylyzer stores each count as a share of its table and reads it back
  truncated, often one lower (about 0.001; reproduced exactly on short texts).
  The Shift token after a dropped character (a capital starting a word) was
  missing from the totals and the skipgrams through Shift were missing; with
  them the gap went from 0.0057 on average (0.028 at most, Canary) to 0.0044.
  Gate: hand-computed from the source (`the` 0.1333, `decided` −6.3314 on
  the staggered board, −6.0214 on ortho) and the REPL's own output on short
  texts with capitals (`dEd` −2.28, `A Dog ran` 0.174, `sat. A Dog` −0.2).
  Our library's Halmak is not Oxeylyzer's (an ANSI board, 11 columns).

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
- **Whole text.** The tool reads the text as it is: Enter is typed (its key
  cost, its finger), and an n-gram from a line break to another character is
  left out but counted as found, before any key lookup. The break tables of
  `ngramsFromText` give those n-grams; a table without them has none. A
  character of a higher layer is pressed as its base-layer key (the key the
  tool resolves it to, with that key's base symbol), and the key trigrams of
  a character trigram and its modifier expansions are summed before they are
  costed: irregularity, (1 + w·c₁)(1 + w·c₂) − 1 per key trigram, is not
  linear in the weight w.
- **Fidelity: exact** for base and Shift layers. Measured against its own
  `evaluate` (built from 8c8ec9f, its default evaluation) with each library
  layout written into its `standard_qwerty_iso.yml` (QWERTY, AZERTY, QWERTZ,
  Dvorak, Colemak, Workman, Canary, Ergopti), on _Alice_, _Sherlock Holmes_,
  English Wikipedia, Python code and _Germinal_ (40 points): within 1e-6 %
  on every point. Before (no line breaks typed, the n-grams after a line
  break counted as not found when they held a character it cannot type, the
  modifier expansions costed one by one, a higher-layer key named by its own
  symbol): 5.5 % on average, 16 % at most; on its default German-English
  corpus our QWERTY UK gave 539.4 for its 542.6. Gate: its own output on
  `the` (270.797), `The` (576.958), `Hello, World.` (2 656.977) on its
  QWERTY and on four short texts (blank lines, a curly quote after a line
  break, mixed case, a tab), to 1e-9. AltGr is our adaptation (held
  AltRight): the tool models Neo layers, not AltGr; Ergo-L and Bépo, with a
  dead key among the keys its layout string permutes, could not be written
  into its file.

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
  repository). Measured against cmini's own `util/analyzer.py` on the corpus
  its `scripts/data.py` builds from each text, on _Alice_, _Sherlock Holmes_,
  English Wikipedia, Python code and _Germinal_ with 13 of its layout files
  (65 points; its Canary has another fingering): every statistic within
  1e-14 point. Gate: hand-computed tables and cmini's own output on a
  two-sentence text on QWERTY, to 1e-9.

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

## Checking against the real tools

`node tools/dev/verify-analyser-scores.cjs [--verbose]` (maintainer tool, needs
the network; never in CI) downloads KLAnext's presets and prints, per preset
and layout, the gap to KLAnext's numbers recorded in
`tools/dev/analyser-reference/klanext.json`, with our library's layouts and
with KLAnext's own layout definitions. With `--oxeylyzer=<exe>
--oxeylyzer-data=<its data folder>` it also runs a local Oxeylyzer build on our
corpus texts; with `--genkey=<exe> --genkey-data=<its source folder>` and
`--keygen=<exe> --keygen-data=<its source folder>`, local builds of genkey and
keygen; with `--perl=<exe> --carpalx-data=<its source folder>` (and
`--carpalx-perl5lib` for the Perl modules it needs), carpalx itself; with
`--klo=<evaluate exe> --klo-data=<its source folder>`, Keyboard Layout
Optimizer (KLO in the table). Measured on 2026-11-18:

| Analyser  | Points | Mean gap                                | Largest      |
| --------- | ------ | --------------------------------------- | ------------ |
| KLAnext   | 126    | 0.0024 (its definitions), 0.18 % (ours) | 0.005, 2.5 % |
| Oxeylyzer | 72     | 0.0044                                  | 0.012        |
| genkey    | 140    | 1.4 % (5.5 % before)                    | 9.9 %        |
| keygen    | 85     | 0.11 % (its), 0.09 % (ours)             | 0.34 %       |
| carpalx   | 50     | 0.31 % (1.2 % before)                   | 1.2 %        |
| KLO       | 40     | < 1e-6 % (5.5 % before)                 | < 1e-6 %     |

cmini and a200 (Python, `--python=<exe>` with `--cmini-data=<its folder>` or
`--a200-data=<its app folder>`) needed no change: every statistic within
1e-13 point of their own code on 65 and 50 points.

## Not covered

Listed by the search for this work, not reproduced (no score, or a score made
of the user's own timings): Keysolve 2 (percentiles against a bundled table),
trialyzer (the user's typing times), keymui / keymeow (metrics, no score),
mw8/white_keyboard_layout, engram, kuehlmak, Oxeylyzer 2 and the newer
analysers with a few stars (mana, keycraft, chogalyzer, stronglytyped). KLA's
`ergodox` and `matrix` boards are not modelled.

## In the Studio

`_shared/ui/layout_analysis/analyser_tab.js` (global `LAYOUT_ANALYSER_TAB`)
draws the « Autres analyseurs » view of the Comparer, on the site
(`layout_analysis/index.html`) and in the app's Studio window
(`layout_editor_window/index.html`), which load it after
`analyser_scores.js`. The Comparer's mount attaches it to its
`#la-analysers` section when the page loads it. It follows each comparison
through `LAYOUT_ANALYSIS_COMPARER.onResults` (the compared layout objects, so
a layout edited in « Éditer » is scored as edited), and scores only once the
view is visible, one layout per idle slice. A change of the user's finger model
(`LAYOUT_ANALYSIS_FINGERING.onChange`) re-scores. Each analyser has two
columns, official and yours, and an « i » button (`analyser.<id>` of
`sources.json`); an analyser without a score shows its headline statistics.
The « Éditer » panel (`analysis_panel.js`) shows the same scores for the
edited layout: each analyser's official score with the analysis, then the
score with the user's finger model on the next tick (`score` per analyser
and fingering, so the first half paints before the second is computed).
