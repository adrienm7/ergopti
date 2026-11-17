<!-- docs/design/layout-analysis.md -->

# Layout analysis engine

One engine measures a keyboard layout on character n-gram counts, for the
`/studio` page of the site and the Ergopti Studio window of Ergopti+ (Windows,
macOS and Linux: the window is the same shared WebView page on every system, so
no system lacks it). The study it is built from, with the sources of each
definition and of the default weights, is
[docs/audits/layout-analysers/report.md](../audits/layout-analysers/report.md).

## Files

| File                                                                           | Role                                                                                                                        |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| `static/ergopti_plus/_shared/ui/layout_analysis/analysis_engine.js`            | The engine: classic script, global `LAYOUT_ANALYSIS`, no DOM, no fetch.                                                     |
| `static/ergopti_plus/_shared/ui/layout_analysis/_generated/analysis_data.js`   | Generated global `LAYOUT_ANALYSIS_DATA`; load it first. `npm run codegen:layout-analysis-data:js`.                          |
| `static/ergopti_plus/_shared/layouts/data/analysis/analysis_model.json`        | Fingers, home keys, lateral and outer keys, keyboards, keyboard formats, ideal finger load, form factors, shortcut letters… |
| `static/ergopti_plus/_shared/layouts/data/analysis/score_weights.json`         | The default weights of the global score (one source).                                                                       |
| `static/ergopti_plus/_shared/layouts/data/analysis/layout_library.json`        | The imported layouts (alphabetic blocks, or whole layouts), their source, and the files left out with the reason.           |
| `static/ergopti_plus/_shared/layouts/data/analysis/sources.json`               | The references behind every metric and sourced value, shown by the « i » popovers.                                          |
| `static/ergopti_plus/_shared/tests/corpus/layout_analysis/metric_vectors.json` | Hand-computed reference vectors; `npm run test:layout-analysis-engine`.                                                     |

Key geometry comes from `_shared/layouts/data/keycodes/physical_keys.json`; the
registry layouts and the reference QWERTY and AZERTY join the library through
the layout composer's reader (`tools/lib/layout-composer.cjs`), converted by
the engine's own `layoutFromComposerSource`.

The library imports four collections (`sources` in `layout_library.json`):
Oxeylyzer's, cmini's and genkey's layouts as alphabetic blocks (`keys`, base
characters of the three letter rows), which the codegen completes with the US
number row and Shift pairs (`tools/build/import-genkey-layouts.cjs <genkey
checkout>` re-encodes genkey's files through the Studio's `fromGenkey`, and
lists its generation template, a file with a key off the three rows and each
duplicate in `not_imported`), and Keyboard Layout Analyzer's built-in layouts as whole
layouts (`rows`, every key and level its file states), taken as they are.
`tools/build/import-kla-layouts.cjs <KLA checkout>` re-encodes KLA's files
through the Studio's own reader (`fromKla`). A file is left out, and listed in
`not_imported` with its reason, when it has characters on keys the library's
keyboards have no code for (ErgoDox thumbs and outer columns, TypeMatrix's
middle column, a modifier key), places a letter twice, or has the same letters
on the same keys and the same digits as a layout already in the library
(`same_as`); a duplicate only credits that layout when it has no credit. The
codegen refuses a `same_as` the library does not hold.

A page loads, from the `_shared/ui/<page>/` folder:

```html
<script src="../layout_analysis/_generated/analysis_data.js"></script>
<script src="../layout_analysis/analysis_engine.js"></script>
```

## API

All functions are on `LAYOUT_ANALYSIS`. Every invalid input throws.

- `ngramsFromText(text)` → `{chars, bigrams, trigrams, breaks}`: counts of 1-,
  2- and 3-character tokens (Unicode code points, case and spaces kept). Line
  breaks and tabs cut the text: no n-gram of the main tables spans them and
  they are not counted there. `breaks` holds, apart, the n-grams of the whole
  text that contain a line break (CR LF and CR read as LF) or a tab, for the
  analysers that type Enter and Tab (KLA, KLAnext); our own metrics never read
  it. Main tables and `breaks` together count every n-gram of the text.
- `prepareNgrams(ngrams)` → the tables as arrays, cached per object. Call it
  once per corpus and pass the result to every analysis: this is what makes a
  comparison instant.
- `hashText(text)` → FNV-1a 32-bit hex, the cache key of a corpus's tables.
- `libraryLayouts()` → the library (registry, reference and imported layouts).
- `layoutFromRows({id, name, rows, dead?, command?, fingering?})` → a checked
  layout. `rows` maps a KeyboardEvent.code to four cells
  `[base, shift, altgr, shift_altgr]`; a cell is a string, `null` or
  `{dead: "<state>"}`. `dead` maps a state to `{typed: output}`, where output is
  a string or `{dead: "<next state>"}` (chains). A key `dead:<state>` stands for the
  dead key that enters `<state>` pressed in this state (Ergo-L's 1dk twice). `command` maps a code to the
  letter its Ctrl/Cmd shortcut uses when it differs from the base layer.
  `fingering` is `standard` or `angle`.
- `layoutFromComposerSource(source, codes)` → the same shape from a layout
  composer source (`LayoutComposer.parseSource` of a `.keylayout`, or
  `referenceSource`): the way the Studio analyses the layout being edited (its
  compiled `.keylayout`).
- `defaultIdealLoad()` → a copy of `ideal_finger_load`; `idealLoad(load)` →
  `load` checked (the eight fingers, finite shares ≥ 0, summing to 100 within
  0.05, each hand keeping index ≥ middle ≥ ring ≥ pinky in the order
  `model.ideal_finger_load_hands` gives); a refusal is an `AnalysisError` with
  a stable `code` (`ideal_load_fingers`, `ideal_load_share`, `ideal_load_sum`,
  `ideal_load_order`) and the `values` its message names.
- `defaultShortcuts()` → a copy of `{letters: shortcut_letters, ease:
shortcut_key_ease}`; `shortcuts(table)` → `table` checked (the model's
  letters and keys, no others; usefulness 0 to 10, ease 0 to 1), refused as
  `shortcuts_not_object`, `shortcut_letter_unknown`, `shortcut_letter_value`,
  `shortcut_key_unknown` or `shortcut_key_value`.
- `defaultFormFactorWeights()` → each `form_factors` weight;
  `formFactorWeights(weights)` → `weights` checked (every form factor, no
  other, each ≥ 0, not all zero), refused as `form_weights_not_object`,
  `form_factor_unknown`, `form_factor_weight` or `form_weights_zero`.
- `analyse(layout, ngrams, {keyboard?, weights?, idealLoad?, shortcuts?, formWeights?, profile?, keyGroups?, typing?})` → one
  result (`idealLoad` replaces the default target of `finger_imbalance`,
  `shortcuts` the table of `shortcut_left`, `formWeights` the weights of
  `compact_fit`;
  `keyGroups: true` counts every key's worst groups for every event, below;
  `typing: 'fixed'` types every character its cheapest way out of context, the
  path the best one is compared with, `'best'` (the default) is described in
  [Ways of typing](#ways-of-typing)):

  ```js
  {
    layout: {id, name, origin, source, language},
    keyboard: 'iso',                 // iso | iso_angle | ansi | ortho
    metrics: {sfb: 0.97, ...},       // every metric below, by id
    fingers: {lp, lr, lm, li, lt, rt, ri, rm, rr, rp},  // % of all presses
    fingerShares: {lp, lr, lm, li, ri, rm, rr, rp},     // % of the non-thumb presses
    idealLoad: {lp, ..., rp},        // the ideal load finger_imbalance used
    hands: {left, right},            // % of the presses, thumbs apart
    rows: {number, top, home, bottom},
    trigramClasses: {roll3_in, roll3_out, alternation, redirect, roll_mixed, same_finger},
    keys: {KeyE: {presses, sfb, sfs, lsb, scissors, redirect, cost: {metric: part},
                  worst: {event: [[[codes], %], ...]}}, ...},
    coverage: {typed, unsupported, unsupportedChars: {char: count}, bigrams, trigrams,
               missingKeys, missingRequired: [char, ...]},
    incomplete: false,               // a required character missing (below)
    typing: {mode, cost, alternatives, changed, paths, chords},  // Ways of typing
    simplicity: {accents, pairs, digits},  // each {value, measured} or null
    score: {total, contributions: {metric: points}, weights}
  }
  ```

  `typing.cost` is the points the keystroke metrics take along the path typed
  (what the choice minimises), `alternatives` the corpus characters with
  several ways, `changed` the % of the typed characters typed otherwise than
  their cheapest way alone, `paths` each such character's ways
  (`{kind: direct|shift|altgr|dead|chord|substitution, steps: [[code, level]],
count}`), `chords` the multi-character outputs used with their counts.

  `keys` feeds the Studio's live heatmaps: each key's share of the presses and
  the share of the bigrams (`sfb`, `lsb`, `scissors` full and half) or trigrams
  (`sfs`, `redirect`) it takes part in. `cost` holds, for each metric of `KEY_COST_METRICS`
  (the events `KEY_EVENTS` = `sfb`, `sfs`, `lsb`, `scissors`, `half_scissors`,
  `redirect`, `redirect_bad`, then `distance`, `finger_imbalance`,
  `pinky_load`, `outer_column`), the part of that metric's value the key
  causes: each event is shared equally between the keys it involves (two for
  a pair or a skipgram, three for a redirect), the distance is the key's
  reach times its presses, and `finger_imbalance` goes to the keys of the
  fingers above their ideal load, in proportion to their presses; the keys'
  parts add up to the metric (pinned by `test-layout-analysis-engine.cjs`).
  `worst` lists, for each event, the key's three heaviest groups: the other
  key of a pair, or the two others of a redirect, with the share of the
  bigrams or trigrams. The SFB groups are always counted; the others only
  with `keyGroups: true`, because counting them for the whole library costs
  about 40 % of a ranking (one layout, as the editor asks, costs nothing
  visible).

  The events shown but not scored (`KEY_INFO_METRICS`: `row_jump`) are shared
  over their keys the same way, in `cost` and `worst`, but stay out of
  `KEY_COST_METRICS` and of the points a key costs.

- `bigramMatrix(layout, ngrams, {keyboard?, profile?, weights?, typing?})` →
  `{keyboard, bigrams, keys, pairs}`: every key pair the layout makes, the key
  bigrams of the stream `analyse()` types (its chosen ways) without a thumb
  key (the ones every bigram metric is a share of). `keys` lists the keys of a
  pair, the busiest first;
  each pair `{keys: [first, second], count, share, events, points}` gives its
  share of the bigrams (%), the counters the engine's one visitor raises for
  it (`sfb`, `lsb`, `scissors`, `half_scissors`, `row_jump`, `roll_in`,
  `roll_out`, `hand_change`, `repeat`) and its score points, Σ sign × weight ×
  share over those metrics. The pairs add up to `analyse()`'s bigram metrics
  and their part of the score (pinned by `test-layout-analysis-engine.cjs`).
- `countWords(text, n?, into?)`, `wordTable(counts)`, `wordsFromText(text)`:
  the word table of a text. A word is a run of letters and combining marks
  (Unicode L and M) folded to lower case; an apostrophe, a hyphen, a digit or
  a space ends it, and a one-character word is dropped (no key pair to
  measure). The table keeps the `WORD_TABLE_SIZE` (1,000) most frequent words.
- `wordEfforts(layout, words, {keyboard?, profile?, weights?, typing?})` →
  `{words, unsupported, mean}`: each word typed alone, as `analyse()` types a
  text, and its **effort**: the points the score would take off a text made of
  that word only, Σ weight × value over `WORD_EFFORT_METRICS` (`sfb`, `sfs`,
  `lsb`, `scissors`, `half_scissors`, `redirect`, `redirect_bad` as shares of
  the word's own key bigrams or trigrams, and `distance` in mm per character).
  The loads (finger, pinky, outer column) belong to a whole text and are left
  out. `words` is hardest first, each `{word, count, effort, parts}`;
  a word with a character the layout cannot type goes to `unsupported`;
  `mean` is the effort averaged over the occurrences.
  `effortDistribution(words, bins)` spreads those occurrences over equal
  ranges of effort from 0 to the hardest word's.

- `keyScoreCost(result, weights?)` → `{code: points}`: what each key costs the
  global score, Σ weight × `cost` over `KEY_COST_METRICS`; the keys' points add
  up to those metrics' part of the score.

- `score(result, weights?)` → `{total, contributions, weights}`; the given
  weights override the defaults metric by metric.
- `defaultWeights()` → a copy of `score_weights.json` (the « restore defaults »
  action).
- `compare(layouts, ngrams, options)` → the results ranked best first, each
  with `rank`: every complete layout before every incomplete one, each group
  by score (`rankOrder`, below).
- `rank(results)` → the same ranking of results analysed apart (the
  Comparer's text modes analyse some layouts on another table); `rankOrder(a,
b)` → its order, negative when `a` ranks first; a result without a boolean
  `incomplete` is refused.
- `rescore(results, weights)` → the same results re-scored and re-ranked with
  new weights, without re-analysis (live weight editing).
- `diff(a, b)` → `{metrics: {id: {a, b, delta, verdict}}, score: {a, b, delta,
verdict}}`: two results side by side, `delta = a − b`, `verdict` `better` or
  `worse` for `a` by the metric's `better`, `same` when equal, `none` for a
  metric shown but not scored. The Comparer's « Compare with » column.
- `scoreSession(layout, ngrams, options)` → `{total, trial(layout) → {total,
changed, walk, compile, compiled, commit()}}`: the global score of layouts
  that change a little at a time (the layout optimizer), equal to
  `analyse(...).score.total` within float rounding. A trial compiles only the
  ways its changed cells and dead-key rules reach (below, Performance) and
  re-walks only the n-grams of the characters whose key sequence changed,
  through the same visitor as `analyse()`; `commit`
  makes the trial's layout the one the next trials are measured from. A
  layout on another board is refused. See
  [layout-optimizer.md](layout-optimizer.md). The partial walk holds only
  while the current layout and the trial each type every corpus character
  one way (no character with several ways, no chord); otherwise the trial
  walks the whole stream again, exact but at the cost of an analysis
  (below, Performance).
- `compileWays(layout, board, missing)` → `{ways, texts, best, distinct}`:
  each character's ways best first, the multi-character outputs' ways, the
  cheapest way of each (`compileLayout` returns that map), and the number of
  distinct characters typed.
- `typingPlan(layout, ngrams, options)` → `{board, chords, ways,
choose(before, token, after)}`: how a corpus is typed, so a text can be
  typed exactly as the tables are (the gate's reference stream).
- `typingRows(result, layout, limit?)` → the « typed via » rows the pages
  show: each concerned character with its ways written with the layout's own
  characters (« AltGr+o », a dead key as `[state]`) and their shares.
- `metricDigits(id)` → the decimals a page shows a metric with.
- `METRICS` → `{id: {unit, better, of}}`; `better` is `lower`, `higher` or
  `none` (shown, not scored); `unit` is `%`, `mm` or `chars` (a count).

### Keystats input

The app passes the sums of the keystats tables over the chosen dates and apps
as plain counts (`ngram_chars`, `ngram_bigrams`, `ngram_trigrams`, column `c`
summed per `token`): `{chars: {token: n}, bigrams: {...}, trigrams: {...}}`.
No text leaves the machine and none is needed. Worker T owns that bridge.
Since schema 2 of `_shared/metrics/data/studio_ngrams.json` the payload holds
two texts: the top-level tables are the keys typed (each count minus its
hotstring, AI and other synthetic sources), and `final` the same tables with
every source counted, the text the user wanted (« Text modes », below).

## Model

**Keystrokes.** A character is typed by a key on a layer, by a dead key (itself
on a layer, possibly chained) followed by the key of the character it composes
with, or as part of a key or dead-key rule that types several characters at
once. When a layout offers several ways, each occurrence is typed the way that
costs least in its context ([Ways of typing](#ways-of-typing)); out of context
the cheapest is the one with the fewest presses, a press costing 1 and each
held modifier 0.5. A typographic character the layout lacks is typed as its
plain form (« » “ ” „ → ", ’ ‘ → ', – — → -, … → ..., no-break spaces → space;
the Kalamine rule), but does not count as covered. A character with no way is
**unsupported**.

**Incomplete layouts** (maintainer, 2026-11-17). A layout that cannot type one
of the model's `required_characters` on the chosen keyboard (the space, each
letter a–z and each letter A–Z, every case checked on its own: « a » without a
way to type « A » is missing « A ») is **incomplete**: `result.incomplete`,
with `coverage.missingRequired` in the model's order. It ranks after every
complete layout, whatever its score, in the Comparer's chart and table and in
the editor panel's rank, and says what it lacks. The proportional `unsupported`
penalty alone let an unusable layout rank well (Ergopti without k, w and z lost
2 points). Any way counts (a dead key, a chord, another level); a typographic
substitute does not. Accented letters, digits, punctuation and symbols only
take the `unsupported` penalty, so the English layouts stay ranked normally on
a French corpus. The set is layout data, not corpus data: a letter the corpus
never uses is still required. On a board that lacks keys, the characters on
them are missing too (Ergopti has no « z » on a Corne).

**What is cached.** A corpus, a pasted text or the keystats store is reduced
once to layout-independent counts: characters, character bigrams and character
trigrams (no text). The distance-2 character pairs that the
same-finger skipgram metric needs are the first and last characters of those
trigrams, so they need no table of their own. Whether a pair is an SFB, a
skipgram, a roll, an alternation or a redirect depends on the layout: that
classification happens when a layout is scored, by mapping the cached n-grams
onto its keys. Every built-in corpus also ships its word table (`wordsFromText`,
the 1,000 most frequent words, a few kilobytes) for the effort per word; a
count table brings the one its importer counted from the same sentences or
list; a pasted text gets one the same way, and the keystats send none.

**Key n-grams.** The key bigrams and trigrams are those of the stream of
expanded keystrokes. They are rebuilt exactly from the character tables: the
pairs inside a character's sequence come from its unigram count, the pair
across two characters from their bigram, and the trigrams across three
characters from their trigram. An unsupported character drops the n-grams it is
in. Modifiers are held, not pressed in the stream: they count in finger load,
distance and `modifier_usage`, not in bigrams or trigrams.

**Keyboards.** `iso`, `ansi` and `ortho` (ISO geometry with the row stagger
removed), `iso_angle` (the angle-mod fingering: Z by the ring finger, X by the
middle, C by the index). An angle-mod library layout analysed on `iso` uses
`iso_angle`. Fingers: `lp lr lm li lt rt ri rm rr rp`. The space bar is
pressed by the left thumb and Digit6 by the right index (maintainer,
2026-11-14). Shift is pressed by the pinky of the other hand (ShiftRight for a
left-hand key), AltGr by the right thumb. The **order** of a finger runs from the pinky (0) to the index (3);
moving to a higher order is **inward**.

**Boards.** Besides the row-staggered `iso`, `iso_angle`, `ansi`, `jis`, `abnt`
and `ortho`, the keyboards include `corne`, `planck`, `ergodox`, `moonlander` and
`kinesis_advantage` (`board_geometries.json`).

- `jis` (Japanese 106/109 keys) and `abnt` (Brazilian ABNT 2) take their positions from
  `_shared/layouts/data/keycodes/keyboard_forms.json`, the ISO board with the keys each
  moves or adds, and the standard fingering with their own keys (`extra_fingers`: Yen and
  Ro on the right pinky). JIS has no ISO key left of Z. The Comparer ticks the ISO
  variant of a family for them (`layout_geometry`). Adding them changed no ISO or ANSI
  result (`library_golden.json` unchanged).

- Each board records the centre of each key in key units, its logical row,
  its default finger and each finger's home key.
- The row is the key's rank in its column, so a column stagger keeps its real
  height for distances while rows and scissors count along the column.
- They were imported from QMK's layout files and default keymaps, with
  ShiftRight and AltGr placed on free keys where the keymap has none.
- A key code a layout uses but the board lacks (a 36-key board's number row)
  is listed in `result.coverage.missingKeys`, and its characters count as
  unsupported.
- A profile's base fingering applies to the row-staggered boards only.

**Fingering profiles.** `keyboard(id, profile)` and `analyse(…, {profile})`
take a user model of the hand: `{id, name, base: 'standard'|'angle',
fingers: {code: finger}, home: {finger: code}}`. The base fingering and the
model's home keys are the defaults, so an empty profile gives the default
numbers.

- Every metric follows the profile: the finger and hand of each key, the
  distance from each finger's own home key, the rows relative to each
  finger's home row (a staggered index still counts as home), and the
  lateral keys.
- A lateral key is an index key at least 0.75 key toward the centre of the
  index's home column, or a pinky key that far outward of the pinky's, on
  the column grid with the stagger removed. On the default boards this rule
  reproduces exactly the list it replaced.
- A home key must be pressed by its own finger, except the space bar, on
  which both thumbs rest (`shared_home_keys`).
- `fingeringProfile(profile)` checks a profile and throws on an unknown base,
  finger or key.

**Shares.** A bigram or trigram metric is a share of the key bigrams or
trigrams **without a thumb key**; a row metric a share of the non-thumb,
non-modifier presses; finger load a share of every press; a « per character »
metric a share of the typed characters.

## Metrics

| Id                 | Unit  | Better | Definition                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------ | ----- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sfb`              | %     | lower  | Same-finger bigram: two consecutive keys on one finger, different keys.                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `repeat`           | %     | none   | The same key twice.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `sfs`              | %     | lower  | Same-finger skipgram: first and third key of a trigram on one finger, different keys.                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `lsb`              | %     | lower  | Lateral stretch bigram: one hand, adjacent fingers, one key lateral (index inner column Digit5/T/G/B, Digit6/Y/H/N; pinky outer keys Backquote, IntlBackslash, Minus, Equal, brackets, Quote, Backslash).                                                                                                                                                                                                                                                                                                |
| `scissors`         | %     | lower  | Full scissor: one hand, adjacent fingers, the longer finger two or more rows below the shorter one (lengths: middle > ring > index > pinky).                                                                                                                                                                                                                                                                                                                                                             |
| `half_scissors`    | %     | lower  | Half scissor: the same, one row apart.                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `row_jump`         | %     | none   | Row jump: two consecutive keys of one hand at least two logical rows apart (top and bottom row, number and home row), whatever the fingers (it may also be an SFB or a scissor); informative, not in the global score.                                                                                                                                                                                                                                                                                   |
| `roll_in`          | %     | higher | Two-key inward roll: one hand, different fingers, toward the index.                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `roll_out`         | %     | higher | Two-key outward roll: toward the pinky.                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `hand_change`      | %     | none   | Two keys on different hands.                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `roll3_in`         | %     | higher | Three-key inward roll: one hand, no repeated finger, the order rising on both moves.                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `roll3_out`        | %     | higher | Three-key outward roll: falling on both moves.                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `alternation`      | %     | higher | Trigram whose hand changes on both moves (left-right-left), no repeated finger.                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `redirect`         | %     | lower  | One hand, no repeated consecutive finger, the direction changes.                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `redirect_bad`     | %     | lower  | A redirect without the index (counted in `redirect` too).                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `home_row`         | %     | higher | Presses on the home row.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `top_row`          | %     | none   | Presses on the top row.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `bottom_row`       | %     | none   | Presses on the bottom row.                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `number_row`       | %     | none   | Presses on the number row.                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `distance`         | mm    | lower  | Mean distance per typed character from each pressed key's finger home key to the key (modifiers included), with 19.05 mm per key unit; a wide modifier is pressed at its end nearest the hand.                                                                                                                                                                                                                                                                                                           |
| `finger_imbalance` | %     | lower  | Half the sum over the eight fingers of the gap between their share of the non-thumb presses and the ideal load (`ideal_finger_load`).                                                                                                                                                                                                                                                                                                                                                                    |
| `hand_imbalance`   | %     | lower  | Gap between the left and right hands' shares of the non-thumb presses.                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `pinky_load`       | %     | lower  | Both pinkies' share of the non-thumb presses.                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `modifier_usage`   | %     | lower  | Characters typed with Shift or AltGr held.                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `dead_key_usage`   | %     | lower  | Characters typed through a dead key.                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `outer_column`     | %     | lower  | Non-thumb presses on the 7th right-hand column (Equal, BracketRight, Backslash).                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `unsupported`      | %     | lower  | Characters of the corpus the layout cannot type.                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `compact_fit`      | %     | higher | Mean, weighted by the form factors' weights, of the share of the corpus's characters still typed on each compact form factor (`form_factors`: the missing keys of each). A form factor marked `per_keyboard_format` (ISO and ANSI 60–100 %) is measured on the chosen keyboard format (`keyboard_formats`: 100 %, TKL, 75 %, 65 %, 60 %, the editor's and the Comparer's « Format »), each lacking the `keyboard_blocks` it hides; with no format chosen, its weight is shared equally over the formats. |
| `char_coverage`    | %     | higher | Share of `reference_characters` the layout types, substitutes excluded.                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `direct_digits`    | %     | higher | Ten points per digit on the base layer.                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `shortcut_left`    | %     | higher | Σ usefulness × ease of the key of each shortcut letter (`shortcut_letters`, `shortcut_key_ease`; 0 on the right hand) over Σ usefulness. The Command layer wins over the base.                                                                                                                                                                                                                                                                                                                           |
| `distinct_chars`   | chars | none   | Distinct characters the layout types by any way (see [Coverage and simplicity bonuses](#coverage-and-simplicity-bonuses)).                                                                                                                                                                                                                                                                                                                                                                               |
| `coverage_bonus`   | %     | higher | `distinct_chars` over the fixed cap `coverage_cap` (1,000), at most 100 %.                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `simplicity`       | %     | higher | Mean of the objective simplicity rules (accents on their base letter's key, paired signs side by side, digits in order).                                                                                                                                                                                                                                                                                                                                                                                 |

## Global score

`contribution(m) = sign(m) × weight(m) × value(m)`, with `sign = +1` when higher
is better and `−1` when lower is better; `total = Σ contributions`. Every weight
is a finite number ≥ 0, in points per percentage point (or per millimetre).
The defaults and their justification are in the study, section « Default
weights ». A weight of 0 removes a metric from the score; the Studio shows each
contribution beside the metric.

## Ways of typing

A layout may type a character in several ways: « . » on two keys, « é » on
its own key, through AltGr and behind a dead key, « où » with one AltGr chord
or two taps. The engine types each occurrence the way a typist would: the one
that costs least where it stands (maintainer, 2026-11-16).

**Ways.** `compileWays` lists every way of each character, best first by the
out-of-context order (fewer presses and held modifiers, then fewer AltGr
presses, fewer keys, lower key indexes, fewer Shift presses, the same order as
before). Two ways on the same keys keep the cheaper one, which no context can
reverse; at most four are kept (`MAX_WAYS`; the library never has more). A
dead key closed by a thumb key (the space bar on any level) types the dead
key's own sign: it stays the way of a character that has no other, and the
fixed path keeps it, but it is never a context alternative. The pair metrics
leave thumb keys out, so such a way would hide an SFB behind an extra press no
typist makes.

**Cost.** The choice minimises the score points the keystroke metrics take,
by the default weights `w` (`score_weights.json`; not the user's, so a way of
typing does not follow the ranking weights and `rescore` stays exact). For a
corpus of `N` characters, `B` bigrams and `T` trigrams, typing one occurrence
costs `cost / N` points with:

- each press of key `k`, held modifiers included:
  `w.distance × reach(k) + 100 × (w.pinky_load [pinky] + w.outer_column [outer
column] − w.home_row [home row, not a modifier])`, thumbs carrying only their
  distance;
- per character: `100 × w.modifier_usage` if a modifier is held,
  `100 × w.dead_key_usage` behind a dead key (times the characters of a
  multi-character output);
- each key pair, times `N / B`: `100 × (w.sfb [SFB] + w.scissors [full] +
w.half_scissors [half] + w.lsb [lateral] − w.roll_in [inward] − w.roll_out
[outward])`, the classification of the `sfb` … `roll_out` metrics;
- each key triple, times `N / T`: `100 × (w.sfs + w.redirect + w.redirect_bad −
w.roll3_in − w.roll3_out − w.alternation)` by the same classification.

`finger_imbalance` and `hand_imbalance` are not sums over keystrokes and take
no part. `result.typing.cost` is that sum over the path typed, in points.

**Choice.** For a character `b` with several ways between `a` and `c`, the
engine picks the way `v` of least

```text
own(v) + across(wa, v) + across(v, wc) + triple(wa, v, wc)
       + Σz P(z | a, b) × triple(wz, wa, v) + Σd P(d | b, c) × triple(v, wc, wd)
```

where `wa`, `wc`, `wz`, `wd` are the neighbours' cheapest ways, `across` the key
pair and triples between two ways (the walk's own step), and
`P(z | a, b) = tri(z, a, b) / bi(a, b)`. At a segment edge the missing side is
left out; a tie keeps the earlier way, so a layout with one way per
character, or whose cheapest way always wins, is typed exactly as before.

**Multi-character outputs.** A two-character output (a cell or a dead-key
rule typing « où ») replaces the two taps of its bigram when its own cost is
less than the taps' (their own costs and the pair between them). Outputs that
would overlap (one ending in the character the other starts with) keep the
one that saves the most; an output repeating its character is not used.
Each chosen output becomes one token of the tables (`tokenTable`); longer
outputs count in `distinct_chars` only.

**Tables, not text.** The corpus is known by its n-gram counts only (the
keystats store holds no text), so the choice is a function of each
character's trigram context, and the walk splits each n-gram over the ways
used. An occurrence's way is read from the trigram it is the middle of (its
bigram at a segment edge), which the tables count exactly. A statistic that
needs a fourth character (a pair of two characters that both have several
ways, a triple whose first or last character has several ways) completes the
trigram table as a second-order Markov chain (each side's share of ways,
independent given the pair or triple). On « Du côté de chez Swann » and the
Nemolivier anthology this moves SFS by at most 0.04 points and alternation by
0.01 against typing the text itself; the gate holds the tables to the text's
own stream, exactly except for those n-grams.

**Guarantee.** Where the characters with several ways stand at least three
places apart, the best path costs no more than the fixed one (the gate's
seeded property test); across the library on the two French corpora it never
does either. The global score may still move the other way by a fraction of
a point, through `finger_imbalance`, which the choice does not see.

## Coverage and simplicity bonuses

Two small bonuses, scored apart from the effort metrics (maintainer,
2026-11-16).

**Coverage.** `distinct_chars` is the number of distinct characters the
layout types by any way (any level, dead keys, the characters of
multi-character outputs; substitutes excluded), shown but not scored.
`coverage_bonus = 100 × min(distinct_chars, coverage_cap) / coverage_cap`,
with the fixed cap `coverage_cap = 1000` (`analysis_model.json`): a fixed cap,
not the best of the layouts compared, so a layout's value never depends on the
others and the optimizer's objective stays stable; 1,000 is past every
layout but bépo (1,771) and Ergo-L (557), Ergopti 480, AZERTY 129, QWERTY 95.
Its weight, 0.05, makes the whole bonus worth 5 points, less than one point
of SFB (weight 10): the gate checks that a toy layout of 1,094 characters with
SFBs ranks below one of 2 characters without. The older `char_coverage` (share
of `reference_characters`) is unchanged.

**Simplicity.** The mean of the rules that have something to measure, each
from 0 to 100 % (`result.simplicity`):

- `accents`: of the accented Latin letters (a letter A–Z with combining marks
  once decomposed) typed only through AltGr or a dead key, the share whose
  last key is the base letter's own key (dead key then e for ê, AltGr+e for
  é). Letters on a key of their own are not measured: they need no mnemonic.
- `pairs`: each pair of `simplicity_pairs` (`() [] {} <> « » “ ” ‘ ’`) the layout
  types: 1 when the closing sign is on the key right of the opening one, on
  the same level; ½ when it is left of it, or both share one key with the
  opening one on the lower level; 0 otherwise.
- `digits`: of the steps 1→2 … 8→9, 9→0, the share where the next digit is on
  the key right of the previous one, on the same level.

« The key right of » is the next key of the same row (a split board's other
half included); every way of each character is tried. Weight 0.03: at most 3
points. Left out as not objective enough: a shifted sign « related » to its
base sign (no rule says which relations count), « consistent layer logic
across letters » (no definition that does not encode one layout's design),
and « few distinct mechanisms » (counting mechanisms penalises a dead key that
adds characters, against the coverage bonus, and has no sourced scale).

## Credits

Every library layout names its authors (`authors`, with `year`, `url` and
`licence` when known) or, failing that, the collection it was taken from
(`source`). A registry layout takes them from its `meta.toml`; the others from
`_shared/layouts/data/analysis/layout_credits.json`, whose `basis` says whether
the author's own page, file or repository states the credit (`source`, with
`checked`, the date it was read, and `evidence`, what it says) or it is the
generally known author still to be checked (`knowledge`); a KLA layout's
credit is the author its file names (`collection`: KLA's « author » field,
which can be the person who submitted the layout). The « Comparer »
shows the credit and the link in each layout's details.

## Other analysers' scores

`_shared/ui/layout_analysis/analyser_scores.js` (global `LAYOUT_ANALYSER_SCORES`,
loaded after the engine) gives each layout's score as KLA, its SteveP fork,
KLAnext, a200, carpalx, keygen, genkey, Oxeylyzer, Keyboard Layout Optimizer,
cmini and the Ergo-L analyser compute it, on the same cached tables; its
formulas, sources, licences and fidelity are in
[analyser-scores.md](analyser-scores.md). The engine's `keyNgrams(layout,
ngrams, {keyboard})` exposes the expanded key stream `analyse` measures
(presses, key bigrams and trigrams as sparse counts), cached per prepared
table, layout object and keyboard.

## Built-in corpora

`static/corpus/register.json` is the licence register of every text under
`static/corpus/original`. For each text it records what it is, its source, its
licence, the attribution it requires, a status and the evidence. The status is
`ship`, `hold` (waits for the maintainer) or `refused`.

`_shared/layouts/data/analysis/corpora.json` lists the built-in corpora by
file. Their licence, attribution and source are read from the register, so the
register is the one source for them. The codegen enforces three rules:

- it refuses a text with no register entry;
- it refuses an entry with no text;
- it refuses a built-in corpus whose status is not `ship`.

The codegen counts the n-grams of each built-in corpus with the engine's own
`ngramsFromText` and writes only the tables (with their `breaks` for a text;
a word list or a count table has none). Each corpus gets its own file,
`_generated/corpus_<id>.js`, loaded when the corpus is chosen, with the
licence and attribution in its header. `LAYOUT_ANALYSIS_DATA.corpora` lists
the corpora with their licence, attribution, source and size, and the page
shows them under the corpus picker. Each entry of `corpora.json` also says
what sort of text it is (`kind`: `literature`, `encyclopedia`, `news`,
`sentences`, `words` for a word list or word frequencies, `code`), which the
Comparer's picker groups and filters by with the `language`; the codegen
refuses another kind, and a `code` corpus is the only one whose language is
`code`. The library's collections (`layout_library.json` `sources`) each carry
the `name` the Comparer's origin filter shows, which the codegen requires.

Shipped as of 2026-11-14:

- _Don Quichotte_ (Furne), _Du côté de chez Swann_, _Don Quixote_ (Ormsby)
  and the Nemolivier anthology: public domain.
- _Autonomie_: CC BY-SA 1.0, re-imported from its ISO-8859-1 original.
- The Hello World programs, with and without letters: MIT.
- The Leipzig French news and Wikipédia samples: CC BY 4.0, by the
  maintainer's choice. `strip_sentence_numbers` removes their line numbers.
- Subtitle word frequencies in French, English, German, Spanish and Italian
  (Hermit Dave's FrequencyWords, from OpenSubtitles2018): CC BY-SA 4.0. Their
  `format` is `word_frequencies`: each « word count » line is counted with a
  space on either side, so their n-grams stay inside words and at word
  boundaries. The page says so under the corpus picker.
- Code: JavaScript (lodash 4.17.21), Python (four modules of rich 13.7.1) and
  Rust (three files of ripgrep 14.1.0), all MIT, each with its licence text at
  the top of the file.

- Project Gutenberg books, without its header and licence footer: _Les
  Misérables_ I (Hugo), _Germinal_ (Zola), _Le Tour du monde en
  quatre-vingts jours_ (Verne), _Madame Bovary_ (Flaubert), _Pride and
  Prejudice_ (Austen), _Alice's Adventures in Wonderland_ (Carroll) and _The
  Adventures of Sherlock Holmes_ (Conan Doyle); in German
  _Effi Briest_ (Fontane) and _Die Verwandlung_ (Kafka), in Spanish _Don
  Quijote_ (Cervantes) and _Marianela_ (Pérez Galdós), in Italian _Le avventure
  di Pinocchio_ (Collodi) and _Ricordi d'infanzia e di scuola_ (De Amicis), all
  in the public domain. `tools/build/import-corpus-texts.cjs` rebuilds each from
  the ebook pinned by SHA-256 in `static/corpus/text_sources.json`, with one
  stripping rule (the work between the START and END markers, LF line ends,
  blank edges and a closing « End of Project Gutenberg » line removed,
  indentation kept), which reproduces the French and English books byte for
  byte. Each register note records why the book is in the public domain in
  the United States (published before 1931) and in the European Union and
  France (author dead more than 70 years). No Wikisource text and no e-mail or
  chat corpus: both wait for the maintainer (TODO.md, « Maintainer decisions
  pending »).
- Tatoeba: the first 30,000 French and English sentences of the « detailed »
  exports, CC BY 2.0 FR. Each line keeps its sentence id and author, as the
  licence asks. Their `format` is `tsv`, and `tsv_text_column` picks the
  sentence.

- Count tables (`format` `count_table`, « ergopti-count-table » version 2),
  from the Leipzig Corpora Collection (shipped under CC BY 4.0 by the
  maintainer's choice, Ergopti being non-commercial): a million sentences each
  of Wikipedia (French 2021, English 2016, German, Spanish and Italian 2021)
  and of news (French, English, German, Spanish and Italian 2024),
  counted as text, so bigrams and trigrams cross words; and Lexique 4.10's
  word forms weighted by their frequency per million (CC BY-SA 4.0), counted
  by the word-list rule, so their n-grams stay inside words and the page
  shows the word-list caveat. A table holds `chars`, `bigrams` and `trigrams`
  with their counts, how it was counted (`counted_as`: `text` or
  `word_list`), the count each table kept from (`pruned_below`) and what that
  pruning changed (`prune_check`), and its word table (`words`: the engine's
  `WORD_TABLE_SIZE`, 1,000, most frequent words of the same sentences or
  list, by its word rule `countWords`, most frequent first); the reader
  refuses another format or version, an n-gram of the wrong length, a count
  under its floor, or a word table that is empty, longer than 1,000, unsorted
  or holds anything but lower-case words of two letters or more. Their
  titles describe rather than name a work, so each has a localized name
  (`title_key`, `layout_analysis.corpus.name.<id>`, in the 21 locales) that
  the Comparer, the analysis panel and the Optimiser show. Each table is
  0.5 to 0.8 MB of JSON, and its generated `corpus_<id>.js` is loaded only
  when its corpus is chosen.
  `tools/build/import-count-tables.cjs` rebuilds them from the archives pinned
  by SHA-256 in `static/corpus/count_table_sources.json` (a tar.gz is read
  in Node: Git for Windows' tar takes « C:\ » for a remote host), with the
  engine's own counting rules. It first repairs the UTF-8 a crawled page decoded as
  CP1252 (the French news sentences hold some 2,600 such apostrophes), so one
  apostrophe is not counted as three rare characters. It drops the n-grams rarer than the register's
  `prune_ratio` of their table (5e-8) and refuses a table when any metric of
  QWERTY, AZERTY, BÉPO, Ergopti, Dvorak, Colemak or Ergo-L measured on the
  pruned counts differs from the full counts by more than 0.05 (percentage
  points for shares); the largest change, recorded in `prune_check`, is
  0.037. Leipzig offers no larger download than a million sentences for
  these corpora, and the tables are bounded by their pruning, not by the
  corpus size. Not imported, waiting for the maintainer (TODO.md, « Maintainer
  decisions pending »): Norvig's counts (derived from the LDC-licensed Google
  Web 1T, no licence for the data) and Tatoeba's full exports as counts
  (CC BY 2.0 FR asks each sentence's author to be credited).
- Google Books Ngram (version 20200217, CC BY 3.0): the French 1-grams,
  counted by the word-list rule (`google_books_1grams`). The six shards
  (3.2 GB) are streamed through curl and gunzip, never stored, each hashed as
  it streams and refused unless its SHA-256 is its pin (`--record-pins` writes
  the first hashes); a shard cut by a reset connection is counted again, up
  to three times. A token weighs its matches from 1950 to 2019, if at least
  `min_count` (100); tagged copies (« livre_NOUN ») and tokens with digits or
  signs are left out, capitals are kept. The other languages wait (TODO.md,
  « More Google Books and Leipzig languages »).

`static/corpus/frequency/` holds the downloaded frequency lists and count
tables, which the register covers like the texts.

Each word table is counted from the same shipped text as its n-grams (the
sentence column of a Tatoeba export, the « word count » lines of a frequency
list, each word as often as the list says), so it carries the same licence and
attribution, written in the generated file's header; a count table's word
table comes from the same archive as its n-grams. `LAYOUT_ANALYSIS_DATA.corpora[].words`
gives how many words each corpus keeps.

The study (`docs/audits/layout-analysers/report.md`, section 18) lists what
is refused, and why.

## Layout file formats

`_shared/ui/layout_analysis/layout_formats.js` (global `LAYOUT_FORMATS`) reads a
layout file into the engine's shape and reports, item by item, what it could not
map (`{format, layout, unmapped: [{what, detail}]}`); a file it cannot read at
all is refused with a stable code (`format_unknown`, `format_invalid`,
`format_unsupported_board`).

| Reader                                       | Format                                                 | Notes                                                                                                                                                                                                                     |
| -------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fromKla(json)`                              | Keyboard Layout Analyzer JSON (KLA, KLAnext and forks) | `standard` (ANSI), `european` (ISO), `ergodox` and KLAnext's `matrix` boards, key indexes from their QWERTY key sets; a key sits at its `id` (KLAnext's order); no dead keys exist in the format.                         |
| `fromKalamineToml(doc)`                      | Kalamine TOML (parsed)                                 | ISO, ANSI and ERGO drawings; `full`, or `base` (with the 1dk column) and `altgr`; `[spacebar]`; a blank level takes the case Kalamine gives it.                                                                           |
| `fromKalamineJson(json)`                     | Kalamine / x-keyboard JSON                             | `keymap` and `deadkeys`.                                                                                                                                                                                                  |
| `fromXkb(text, variant?)`                    | XKB symbols                                            | four levels; `dead_*` keysyms; `include` lines and levels beyond four are reported.                                                                                                                                       |
| `fromKlc(text, scancodes)`                   | Windows KLC                                            | SHIFTSTATE columns 0, 1, 6, 7; `DEADKEY` tables; ligatures reported.                                                                                                                                                      |
| `fromKeylayout(text, id, convention, tools)` | macOS .keylayout                                       | through the layout composer's reader; its refusals become `format_invalid`.                                                                                                                                               |
| `fromDof(json)`                              | Oxeylyzer DOF (libdof)                                 | `ansi`, `iso`, `ortho`, `colstag` boards and a custom board of the ANSI or ISO shape, from the anchor; `main`, `shift` (or libdof's generated one), `altgr`, `shift_altgr`; other layers, magic keys and combos reported. |
| `fromGenkey(text)`                           | genkey layout                                          | name, three key rows (first character of each word, lower case), three finger rows; a file without an extension or a `.txt`.                                                                                              |
| `fromRows(input)`                            | cmini JSON, plain rows                                 | base layer, upper case on Shift; a key off the three rows (a cmini thumb) is reported.                                                                                                                                    |
| `fromKbe(bytes)`                             | KbdEdit .kbe                                           | header checked, then refused (`format_kbe_encrypted`): the body is encrypted with a key only KbdEdit holds (below).                                                                                                       |
| `read(name, text, tools)`                    | any of the above                                       | recognised by content and extension; a file that places no character is refused.                                                                                                                                          |
| `readBytes(name, bytes, tools)`              | any of the above, from a picked file's bytes           | a .kbe by its header, else `decode(bytes)` (UTF-16 by its byte-order mark, else UTF-8) then `read`.                                                                                                                       |

Every refusal has a stable code (`format_unknown`, `format_invalid`,
`format_unsupported_board`, `format_kbe_encrypted`) and every loss a kind
(`key`, `keysym`, `include`, `ligature`, `dead_key_rules`, `dead_key`,
`multi_character`, `layer`, `rule` for a DOF magic key or combo, `special` for
a DOF modifier or layer key on a character key, `character` for one a writer
cannot write); `refusalMessage(error)` and `lossMessage(entry)` turn them
into `layout_analysis.formats.*` locale keys, which the editor and the Comparer
show in the user's language. A malformed file is refused with one of those
codes, never a crash (`tools/test/test-layout-formats.cjs` cuts and overwrites
real files from a fixed seed). `EXTENSIONS` lists the file types the pages'
pickers offer: the site's and the Windows and Linux app's webview pickers take
it as their `accept` list, the macOS app's open panel offers the same list from
the layout defaults (`source.pick_extensions`). A genkey layout has no
extension in genkey's own folder: the pickers offer `.txt`, which the editor's
genkey download writes, and a file opened without an extension is read when
its content is a genkey layout.

KLAnext's boards beyond KLA's are its `matrix` (read), `ergolinear` and
`janiso` (refused with `format_unsupported_board`): the matrix key set is the
key each index of KLAnext's own QWERTY matrix layout types
(`layouts/qwerty.en.matrix.json`, `kb.js` `KB.keyMap.matrix`), its centre
block, thumb, page and arrow keys reported when they carry a character.
KLAnext's layout list (`db.js`) holds no `ergolinear` layout, and `janiso`
waits for the model's JIS keys.

KbdEdit .kbe, reverse-engineered from the committed exports
(`static/layouts/registry/bepo/kbdedit`, `static/ergopti/windows`): a UInt16
length and the ASCII signature « KbdEdit export file », a UInt32 version (5),
a UInt32 field (0x40, 0x7c or 0x7f), a UInt16 length of the rest of the file,
then the body. The body has the byte statistics of random data (7.96 bits per
byte on 4 KB), no zlib, deflate or gzip stream starts at any offset, and the
exports of Ergopti 2.2.0 and 2.2.1, which differ by a few keys, share no
8-byte run: it is encrypted, so neither a reader nor a writer can be built
from the files alone, and decompiling KbdEdit would break this project's
clean-room rule (docs/design/layout-generator-kbdedit-parity.md). The Studio
refuses a .kbe with that reason and points to KbdEdit's .keylayout export; for
KbdEdit, the Studio's .keylayout and KLC downloads are what it imports.

The standard accents (grave, acute, circumflex, tilde, diaeresis, cedilla…) a
format names without a table compose by Unicode normalisation: the letter
followed by the accent's combining mark, normalised to one character. Writers:
`toSource(layout)` gives an Ergopti layout source the source model validates;
`toKla(layout, fingering)` a KLA JSON on the european board; `toKalamineToml`
a Kalamine ISO `full` drawing, listing what Kalamine cannot hold (another dead
key, several characters on one key); `toDof` a DOF on libdof's ISO board
anchored at its top left key, all four levels written; `toGenkey` and
`toCmini` the base characters of the three letter rows with their fingers,
listing a dead key, a repeated character and the levels above the base. A
.keylayout is written by the layout
source compiler from the source `toSource` builds (the editor's macOS
download). `tools/test/test-layout-formats.cjs` holds the readers to the
repository's own files of Ergopti 1DK v2.1.2 (its Kalamine TOML, JSON, KLC,
XKB and .keylayout) and to third-party files (xkeyboard-config's XKB, Colemak
Mod-DH's KLC, libdof's DOF, their sources and licences in
`tools/test/fixtures/layout-formats/third-party/README.md`), and holds import,
export, import to the same layout on every committed KLAnext JSON (ISO and
ErgoDox), on bépo's, Ergopti's and KbdEdit's own .keylayout files and, for
DOF, genkey and cmini, on each of those layouts. A KLC `DEADKEY` result ending
in `@` chains to another dead key. An XKB key's levels are its first keysym
list, after a `type[Group1] = …` assignment or as `symbols[Group1] = [ … ]`;
a keysym named letter then accent (`scircumflex`) composes. The
« Comparer » page adds an imported layout to the comparison and shows that
report.

## Comparer page

Layout of the page, top to bottom (maintainer, 2026-11-18): the title and
« Copy the link »; two cards side by side (stacked on a phone), the corpus and
« Text and keyboard » (text mode, keyboard, format); the folded layout list;
the status; the results; then the score settings folded in one « Réglages du
score » section. While a corpus loads, the status says so and the results carry
`aria-busy`.

**Corpus picker.** The user's own texts come first under their heading (« My
typing » while the app reads it, then the pasted text or file), then one
`optgroup` per language and kind of the built-in texts (« French · Books »,
« English · Encyclopedia »…, code last under « Source code »; `corpora.json`
`kind`, language names from `Intl.DisplayNames` in the page's language). Two
filters, « Language » (`#la-corpus-language`; code is listed whatever the
language) and « Kind of text » (`#la-corpus-kind`), narrow the list; the chosen
corpus always stays listed. Both are saved (`corpusFilter`).

**Layout list.** Besides its text search, « Origin » (`#la-pick-origin`: the
Ergopti layouts, the references, the user's own, or a library collection by
its `layout_library.json` `name`) and « Language » (`#la-pick-language`)
narrow the list, which « Select all shown » follows; saved as `pick`.

**Filters.** « Layouts shown » (`#la-filters-box`, open from 720 px and
whenever a filter is set, folded on a phone, its summary counting the layouts
kept) holds the filters every sub-tab draws from: name, family, origin,
language, completeness (complete, incomplete or both) and a score range, with
« Show every row and the default columns »; saved in `table`.

**Sub-tabs** (`#la-tabs`, the ARIA tabs pattern: arrows, Home and End move;
one panel at a time; the last one the visitor chose is saved as `tab`, a link
naming `details` opens « One layout »). The overview is drawn after every
analysis, another tab when it is shown.

- **Overview**: the global score chart (bars from the weakest shown to the best,
  the gap to the first in brackets; each bar opens the details with a click or
  Enter), the best complete layout shown by the score and by nine metrics as
  tiles, and the sortable ranking (header buttons, units in the headers, its
  columns the viewer's: `#la-table-options`).
- **Fingers and hands**: the finger load against the ideal as a heat table
  (each finger's share, its signed gap to the ideal under it, the cell orange
  above and blue below the ideal, into the neutral surface; the ideal load is
  the first row), the hand balance (both hands in one bar, the middle marked,
  the most balanced first), and a chart per metric.
- **Bigrams**, **Trigrams**, **Rows and distance**, **Coverage and more**: one
  bar chart per metric of `TAB_METRICS` (every engine metric is in exactly one
  tab), its direction in words (« lower is better », « higher is better » or
  « not scored »), the better first and the incomplete layouts last; then the
  tab's sortable table. Trigrams adds the six trigram classes as a stacked bar
  per layout; rows adds the row usage stacked bar (the home row's value
  written) and each finger's travel as a heat table on the blue ramp.
- **Heat maps**: the first 2 to 12 layouts shown side by side
  (`#la-heats-count`, 6 by default), each key coloured by the presses, the
  score or any per-key metric (`#la-heats-metric`), on one scale for all
  (`#la-heats-shared`, the default) or each its own. The space bar's share of
  the presses dwarfs every letter, so the scale is the other keys' and the
  legend's dark end reads « ≥ »; the space bar is drawn at its darkest. Each
  board has its values as a folded table and opens the layout's details.
- **Other analysers**: `analyser_tab.js`, below.
- **One layout**: the details, a list of the compared layouts on top
  (`#la-details-layout`).

Every chart is read as a table by assistive technology (rows of row header and
cell, named by its heading), and every figure has a table: the themed tabs'
sortable tables, the stacked figures' and boards' folded tables. The user's
own layouts take the accent colour in the bars and an accent edge in the tables
and tiles. A stacked figure's parts take the categorical slots of theme.css
« Chart look » in a fixed order (six slots, validated adjacent-pair in light
and dark with the dataviz palette validator); the ramps and the diverging pair
are the heatmap's. At phone width a bar takes the whole width under its label
and the page never scrolls sideways (`layout-editor.playwright.cjs`
`exerciseComparerPicker`, every tab in light and dark).

The details show: « Compare with » (`#la-versus`, another
compared layout: its value and the difference beside every metric and the
score, from `diff`, each with ▲ better, ▼ worse, = equal or « not scored » in
words); the key heatmap in one blue hue from light to dark with its scale
(0 to the largest key's value), board positions in % so it shrinks with the
page, with each finger's share of the non-thumb presses (its ideal load
marked), hands and rows under it and the contributions beside it; every
metric; « Typed via » (the share
of the characters typed otherwise than their cheapest way alone, then the
twelve most frequent characters concerned, each way with its share,
`typingRows`); the simplicity rules, each with its value or « not measured ».
The ranking has a column each for the distinct characters (a count), the
coverage bonus and the simplicity bonus. An incomplete layout keeps its rank
after the complete ones in the chart and the table, carries « incomplete:
lacks … » beside its name (in words, not by colour alone; its bar is faded),
and its details say why it ranks there. The chart colours are tokens of
`style.css` checked with the dataviz palette validator in light and dark.

The other analysers' view (`analyser_tab.js`) shows each analyser's score, or
its rank of the layouts scored so far (`#la-analysers-view`: 1 for its best,
ties shared, the cell on the blue ramp with the rank written); every column
sorts from a header button that says its order in `aria-sort`.

Two folded figures follow the worst pairs (row jumps are among their events
and the heatmap's choices):

- « Key pair matrix » (`#la-matrix`, from `bigramMatrix`): the 32 busiest keys
  on both axes, first key by row and second by column, each cell coloured by
  its share of the pairs (the heatmap's blue ramp) or by its score points
  (gained blue with « + », lost orange with « − », into the neutral surface),
  with a legend and units. It scrolls inside its own focusable box, never the
  page, at phone width; each cell names its pair, share, count, kind and
  points to assistive technology, and the 100 most frequent pairs are a
  sortable table below.
- « Effort per word » (from `wordEfforts` on the corpus's word table): the
  mean per word typed, the share of the occurrences in ten ranges of effort,
  and the 15 hardest words with the metric that costs each most. A corpus
  without a word table (« My typing ») says so.

« Copy the link » (`#la-share`) writes the comparison's address: the framing
page's (the site's `/studio/comparer` or `/ergopti/benchmarks`, which hand
the link parameters on to the frame through `src/lib/js/comparerLink.js`),
or `https://ergopti.fr/studio/comparer` from a page with no web address (the
app), or `LAYOUT_ANALYSIS_HOST.shareUrl`. It names `corpus` (a built-in one),
`keyboard`, `format`, `layouts` (comma-separated ids of the library layouts
ticked), `details` and `versus`. The user's own layouts and texts never go in
it, and the message says so. A link's layouts are shown without replacing
the visitor's saved selection until they tick or untick one.

`_shared/ui/layout_analysis/index.html` is the « Comparer » tab: corpus
(built-in, pasted text, or a .txt, .md, .csv, .html, .docx, .odt or .pdf file (`pdf_text.js`: its text, no library; a locked or scanned PDF refused) read in
the page), keyboard, layout selection, the global score chart, the sortable
ranking, each layout's contributions, finger load and metrics, and the weights
editor with « restore the defaults ». The site embeds it like the editor
(`?lang=<code>`); the app's Studio window loads the same page. A link may add
`corpus=<built-in id>`, `keyboard=<id>`, `format=<id>`, `layouts=<id,id>`,
`details=<id>` and `versus=<id>`: the page opens on them over the
visitor's saved choice without saving them, and names an unknown value in the
console, keeping the saved choice. The site's benchmark page
(`/ergopti/benchmarks`) frames it this way (`fr_nemolivier`, `iso`), so its
results are the Studio's: the shared library, engine and corpora, with no
list or metric of its own. A host may
define, before the page script runs (or pass as `mount`'s `host`):

```js
window.LAYOUT_ANALYSIS_HOST = {
	corpora: [{ id: 'my_typing', title: '…', tables: { chars, bigrams, trigrams } }], // listed first, selected
	layouts: [{ id, name, rows, dead, command }] // the user's own layouts, ticked
};
```

Data that arrives after load (the app's keystats tables, fetched on the user's
request; the user's own layouts) goes through
`window.LAYOUT_ANALYSIS_COMPARER`: `setCorpus({id, title?, tables, default?})`
adds a corpus, listed first and selected when `default` is true, or replaces
the tables of a listed one without changing the chosen corpus (analysed again
only when it is the chosen one), and
`addLayouts([layout, ...])` adds or replaces layouts, ticked, and `setFormat(id)`
chooses the keyboard format (the app's Studio passes the editor's « Format »). The
editor and the Comparer store that format once for both (`corpus_files.js`
`saveFormat`), so the site's two framed pages share it too; on the site the
editor's « Compare with other layouts » keeps the layout in the tab's storage
(`handOff`), the Studio opens « Comparer », and the Comparer ranks it
(`takeHandoff`). The layouts open in « Éditer » are listed as personal
layouts (ids `editor_<layout id>`), ticked when they appear: the editor sends
each tab's analysis layout after its autosave delay (`publishEditorLayouts`),
and the Comparer follows (`onEditorLayouts`: the same page through an event, the
site's other frame through localStorage and its `storage` event).
Until the user ticks or unticks a layout, the ticked layouts follow the
keyboard: the registry, reference and personal layouts, but of a family that
ships one layout per board (registry `geometry`: Ergopti and Ergopti ANSI)
only the one of the keyboard's geometry, ISO for a split or ortholinear board;
the other stays listed, unticked. The page also
listens for the app's `studio-ngrams` DOM event (`detail` = the keystats tables)
and turns it into the « My typing » corpus (`my_typing`), the default in the
app. A host that inlines its pages defines `loadCorpus(id)` (a promise resolved
once `window.LAYOUT_ANALYSIS_CORPORA[id]` is set) instead of letting the page
load `_generated/corpus_<id>.js` by URL. `onResults` listeners get
`(results, tables, {keyboard, layouts})`, where `layouts` maps each id to the
layout object compared. A host `store` (`{list(), save(layout), remove(id)}`, each returning a
promise; the app's data folder, the site's IndexedDB) replaces `localStorage`
for the layouts imported from files.

### Text modes

« Text typed » (`#la-text-mode`, saved as `textMode`; maintainer, 2026-11-17)
chooses which text each layout types:

- **Keys typed** (`typed`, the default, « Ma frappe » as it was): every layout
  types the raw text, the keys the fingers pressed, hotstring abbreviations
  included.
- **Final text** (`final`): every layout types the text after the hotstring
  expansions and the AI completions, the text the user wanted.
- **Final text, keys typed for « + »** (`mixed`): every layout types the final
  text, and each layout ticked « + » in the list (`.la-plus`, saved as `plus`)
  also ranks as « <name>+ » (id `<id>+`), typing the keys typed with the
  Ergopti+ hotstrings: QWERTY against QWERTY+, Optimot against Optimot+, in one
  ranking. The « + » box is its own tick, so a layout can rank with, without or
  beside its « + » twin. Both kinds rank together (`E.rank`, incomplete layouts
  last), and the details, the key pair matrix and the other analysers' scores
  of a « + » layout are measured on the keys typed (`onResults` gives each
  result's tables through `tablesOf`).

Only a corpus of two texts tells them apart: « My typing » since schema 2 of
the keystats payload (keys typed at the top level, the final text under
`final`; [Keystats input](#keystats-input)). A built-in corpus, a pasted text
or a file is one text: the choice and the « + » boxes are greyed with the
reason, and every layout types that text. The raw text of a built-in corpus is
not derived from the Ergopti+ hotstring catalogue, because that is not sound
at n-gram level: an abbreviation replaces whole words and their spaces, and a
character trigram table does not say where a word starts or ends, so the
counts of the abbreviated text cannot be rebuilt from it (only a text could be
rewritten, and the corpora ship as tables). The final text of « My typing »
still counts the abbreviation a hotstring erased: the store keeps each
token's sources, not its erasures. `corpus_files.js` owns the modes
(`TEXT_MODES`) and `plainTables(tables, mode)`, the text the layouts not ticked
« + » type; the editor's panel follows the Comparer's mode for « My typing »
(the « + » layouts are the Comparer's alone).

The Comparer mounts into an element:
`LAYOUT_ANALYSIS_COMPARER.mount(root, {host?, reportHeight?})` fills `root`
from the markup in `comparer_page.js` and returns `{setCorpus, addLayouts,
onResults}`. A second mount throws.

- The site's `index.html` holds only `<main id="layout-analysis">`, which the
  script mounts by itself with `reportHeight`.
- The app's Studio window (`layout_editor_window/index.html`) loads the same
  scripts and mounts the Comparer into its « Comparer » tab.
- Keystats tables sent before the mount are kept and applied when it happens.

« Doigté » (`fingering_editor.js`, global `LAYOUT_ANALYSIS_FINGERING`, styled
by `fingering_editor.css`) edits the fingering profile under the Comparer's
weights and in the layout editor's analysis panel. It draws a key map coloured by
finger, with the home keys marked; the user clicks a key, then picks its
finger or makes it that finger's home key. It also has a base fingering
(standard or angle mod), reset, and JSON export and import.

- Each keyboard model (ISO, ANSI, ortholinear, each split board) has its own
  profile: `current(keyboard)` is the one every analysis on that keyboard
  passes (the Comparer, the editor's panel and the other analysers' scores),
  null for the keyboard's defaults; reset, export and import act on the
  keyboard shown. `onChange(listener)` tells them which keyboard changed.
- What is stored is `{version: 2, profiles: {<keyboard>: profile}}`; the single
  profile of version 1 is not carried over (decided by the agent, to review by
  the maintainer).
- An edit the engine refuses is not applied, and the page shows the reason.
- The profile is kept by the host when it offers `store.loadProfile()` and
  `store.saveProfile(stored)` (promises). Otherwise it goes to
  localStorage, and another page of the same site follows it through the
  `storage` event.

The host `store` contract:

- `list()` resolves to the saved layouts.
- `save(layout)` resolves once the layout is stored.
- `remove(id)` resolves once it is deleted. No control calls it yet.

A layout is the library shape, JSON as given: `{id, name, origin: 'user',
source: <file name>, rows, dead, command, fingering, language, authors, url,
licence}`. Its id is `user_<slug>`, or `user_<slug>_<n>` when that id is
taken. The host stores and returns layouts unchanged and keys them by `id`.

Framed by the site (`/studio/comparer`, owned by the site routes), the page
needs no bridge: it uses relative URLs only, honours `?lang=<code>` (French by
default), makes no request outside the site and posts
`{type: 'ergopti-layout-analysis:height', height}` to its parent on load and on
every resize so the frame fits its content.

Every metric, every weight, the fingering, the ideal finger load and the
shortcut table have an « i » button. Its popover gives a localized explanation
(`layout_analysis.info.<item>`) and links the references of `sources.json`; a
reference not yet re-read is marked « link to verify ». The codegen refuses a
metric without references, an unknown or unused reference, and a repository
document or heading that does not exist. A host that opens links itself (the
app's browser) defines `LAYOUT_ANALYSIS_HOST.openLink(url)`; otherwise links
open in a new tab.

The ideal finger load is editable under the weights: eight targets, their
total shown, analysed again once they sum to 100 %, « restore the defaults ».
The codegen refuses a default that breaks the maintainer's rule (each hand at
50 %, index ≥ middle ≥ ring ≥ pinky, pinkies under 8 %); an edited load keeps
the order, which the engine enforces, while its hand shares and pinkies are the
user's choice.

The shortcut table (each letter's usefulness and each key's ease) and the
compact form factors' weights are editable below it the same way: every change
is checked by the engine as a whole, a refused one marks the inputs and says
why, and each has « restore the defaults ».

Weights, ideal finger load, shortcut table, form factor weights, selection, corpus and keyboard are remembered in `localStorage` when
the browser allows it; nothing is sent anywhere.

`score_settings.js` (global `LAYOUT_ANALYSIS_SCORE_SETTINGS`) is the one
reading of those score settings: `parse(saved)` checks each the way the
Comparer loads them, `analysisOptions(keyboard)` adds the keyboard's
fingering profile, `customised(keyboard)` says which differ from the
defaults, and `onChange(listener)` follows the Comparer's save (`notify()`
on the same page, the `storage` event from another frame) and the fingering
editor. The Comparer, the editor's analysis panel and the optimizer score
with it, so a weight changed in the Comparer changes the optimizer's
objective; no other page keeps weights of its own.

## Editor analysis panel

`_shared/ui/layout_analysis/analysis_panel.js` (global `LAYOUT_ANALYSIS_PANEL`)
is the live analysis beside the « Éditer » board. `create()` returns
`{node, update(doc), onHeat(listener), addSection(draw)}`. The editor page appends `node` to its
board row on every render and calls `update(doc())` afterwards. A page that
does not load the panel's scripts gets no panel.

- The edited source becomes the engine's layout through the same path as the
  registry layouts: `LayoutSourceIO.keylayoutFile(doc, 'iso')`, then
  `LayoutComposer.parseSource`, then `layoutFromComposerSource`
  (`layoutFromEditorDoc`). A document the compiler refuses shows the refusal's
  code instead of a score.
- Each edit is analysed 150 ms after the last change. In Chromium the
  conversion takes about 0.3 ms and the analysis about 5 ms.
- The library is ranked once per corpus, keyboard, weights and ideal finger
  load. The rank is « N of library + 1 », counted by the engine's
  `rankOrder`: an incomplete edited layout ranks after every complete one,
  and the panel says which required characters it lacks. « Rank among » (`#la-panel-rank`,
  saved with the corpus) ranks it instead among the library and imported
  layouts ticked in « Comparer » (its saved selection); with none ticked, a
  note says so and the rank is 1 of 1.
- The finger load is each finger's share of the non-thumb presses
  (`fingerShares`) with a mark at its ideal load (`idealLoad`), the two sides
  of `finger_imbalance`.
- The panel reads the weights, ideal finger load, shortcut table and form
  factor weights the Comparer saved (key
  `LAYOUT_ANALYSIS_FILES.SETTINGS_KEY`), so both pages score alike.
- Corpus and keyboard are its own choices. « Ma frappe » arrives through the
  app's `studio-ngrams` event and becomes the default corpus.
- It lists the main metrics with « i » buttons (the distinct characters, the
  coverage and simplicity bonuses among them) and the change the last edit
  made (green better, red worse), a « typed via » line (the share typed
  otherwise than the cheapest way alone, and the three most frequent
  characters concerned with their ways), then the finger load.
- Then every analyser's score (`LAYOUT_ANALYSER_SCORES.score`, see
  [analyser-scores.md](analyser-scores.md)): the official score is drawn with
  the analysis, the score with the user's finger model on the next tick, so
  the panel paints first. An analysis started since drops the late half.
  Each row has the analyser's « i » button (`analyser.<id>`); an analyser
  without a score shows its headline statistics. About 50 ms per half in
  Node for the 11 analysers.
- `addSection(draw)` adds a view drawn after each analysis with
  `(container, {layout, tables, keyboard, result})`.
- « Key colours » (`#la-panel-heat`, saved with the corpus and keyboard): the
  global score (the default, `keyScoreCost` with the Comparer's weights), the
  presses, or one metric of `KEY_COST_METRICS`. The edited layout is analysed
  with `keyGroups: true`, and `onHeat(listener)` receives after each analysis
  `{metric, values: {code: value}, max, titles: {code: text}}`, or `null` when
  the colours are « None », the panel is folded or the layout cannot be
  analysed. The editor colours its board's keys from green (0) to red (the
  key that costs the most) and adds the title to each key's tooltip: the
  key's part of the metric and its worst pairs or trigrams, written with the
  characters on those keys, or for the global score the points it loses and
  the three metrics that cost the most. Every edit re-analyses and recolours
  (150 ms after the last change), on the site and in the app, which load the
  same panel.

The built-in corpus scripts load through `LAYOUT_ANALYSIS_FILES.builtinTables`,
relative to `corpus_files.js`, from any page folder. The « i » popovers
(`info_popover.js`, `info_popover.css`) are shared by both pages.

## Performance

The library (115 layouts when measured, 165 since the KLA import) on a 2.5 MB
French corpus took about 0.3 s from prepared tables in Node, before the ways
of typing (below); the gate holds it under 13 ms per layout (1.5 s for 115
layouts) on the fastest of up to three runs, one run following the machine's
load and the JIT warming up. A page computes the
tables of a corpus once (`prepareNgrams`) and keeps them under `hashText` of
the text; built-in corpora can ship their tables pre-computed.

The ways of typing cost nothing measurable on a layout whose corpus
characters each have one way (the walk is the plain one); on a layout with
choices only the n-grams holding a character with several ways go through
the choice (`partition`, cached per table), each pair's context costs are
computed once, and the compact form factors use a reachability pass instead of
a full compile. Measured on Nemolivier, Node 22, on a loaded Windows laptop
(minimum of 7, warm), against the engine before (b9ea9b50e8): QWERTY
9.2 → 10.0 ms, AZERTY 8.9 → 9.6 ms, bépo 133 → 99 ms (the reachability pass),
Ergo-L 38 → 60 ms, Ergopti 24 → 49 ms, the library 1.38 → 1.69 s.
`scoreSession` keeps its partial walk for layouts without choices (AZERTY,
the optimizer's default start: about 100 → 94 trials per second on Swann);
a layout with choices is planned from the current plan, re-deciding only the
contexts a changed token reaches, and walks only what changed
([layout-optimizer.md](layout-optimizer.md), « Speed »: Ergopti 22.7 → 35.1,
Ergo-L 16.7 → 23.0, bépo 8.7 → 15.1 trials per second). compileWays skips a
dead-key rule whose prefix and tail lists did not change since its last pass.

The walks then got their speed back without moving any value
(`library_golden.json` pins every metric of every library layout on both
French corpora; the gate compares them). The Node tests run the engine in a vm
context, where each read of a global costs about a thousand times a local one:
the built-ins are locals of the module (of `analyser_scores.js` too). A
prepared table carries its tokens as ids and its counts as typed arrays
(`tableIds`); with whole counts, the pairs and triples of each step are summed
per key n-gram and passed to the visitor once, in the order they first came,
so its integer sums and map orders are those of the n-gram-by-n-gram walk (a
chord table, with fractional counts, is walked entry by entry).
`trigramPoints` (the context choice) and the trigram rule (`tripleKind`) are
memoised per board, forms that take away the same keys share one reachability
pass, and the dead-key compile builds a chained way in full only once `offer`
keeps it. Measured warm, 165 layouts, on a heavily loaded PC: the library
2.5 → 1.0 s of CPU (fastest wall time 3.2 → 1.2 s), QWERTY 12 → 6 ms, bépo
86 → 48 ms, Ergo-L 62 → 30 ms, Ergopti 52 → 28 ms; optimizer trials per second
QWERTY 106 → 142, bépo 19 → 23, Ergo-L 25 → 32, Ergopti 25 → 30.

A trial compiles from the current layout (`compileCoreFrom`): the
characters, dead states and texts of the changed cells and of the changed
states' rules are compiled again, then every output of a rule that reads one
of them, through every chain; the other lists are shared. A list is the best
`MAX_WAYS` of candidates built from strictly cheaper ways, so a list whose
inputs are the same is the same. Two ways on the same keys can come from two
chains (bépo's « crochet, then ê » and « circonflexe-crochet, then e »), and
a whole compile keeps the one it offers first: the session's first compile
notes when each way was offered (pass, rule, prefix, tail), the partial one
gives each offer the time a whole compile would, keeps the earlier of two
such ways, and leaves out what a whole compile would offer after its last
pass. The result is the whole compile's, list for list, labels included (the
property test compares them on every trial; a scratch run over the 165
layouts of the library, 31 000 random swaps, found no difference), and
`analyse()` is unchanged (byte-identical on the library).

The plan from the current plan works on ids (`planContext`): a context
model per partition (`contextModel`: the touchTri and touchBi entries as id
columns, every pair they hold as a pair id, compressed per-pair and
per-token entry lists) and a plan state of typed arrays (skipgram tallies,
picks, edge choices, distributions and shares per pair and per token). A
trial copies the current state into the spare one
and computes again only what a token whose ways changed can reach, with
insertion-ordered id sets in place of string-keyed Sets and Maps, in the
same order as from nothing: the plan is the same to the last bit (the
property test compares each trial's counts per way with `analyse()`'s; a
scratch run of 16,500 random swaps over the library compared every typed
state with a plan made from nothing). Only the last trial's plan stays
whole, so a session refuses to report an earlier trial's plan and scores
an earlier trial again when it is committed. A partial compile names the
characters it compiled again: `finishWaysFrom` takes their lists into the
previous finished maps and carries the accent rule's counts over
(simplicity), and a joined way is filled in only once it may be kept.
`compact_fit` follows the dead-key rules on ids (`reachGraph`). Every
value is unchanged (golden gap 0).

## Decided by the agent, to review by the maintainer

The maintainer settled the space bar thumb, Digit6, the weights, the ideal
finger load and the shortcut letters on 2026-11-14. Still to review: the ISO
key left of Z, the shortcut key ease, the reference character set, the scissor rule (the Keyboard Layouts Doc's « the finger that
prefers being higher is not ») and the default weights; see the study's last
section.

Decided by the agent on 2026-11-17, to review by the maintainer, for the text
modes: the keys typed stay the default mode (today's « Ma frappe »); the « + »
box is a tick of its own beside the layout's, so a « + » twin can rank with
or without its plain layout; a built-in corpus has one text (the hotstring
catalogue is not applied to n-gram tables, above); the editor's panel follows
the Comparer's mode; a « + » name may repeat a library name (« Ergopti » ticked
« + » ranks as « Ergopti+ », the name of the registry's Ergopti+ layout).

Decided by the agent on 2026-11-17, to review by the maintainer: `row_jump`
(two rows or more, any fingers, logical rows) is shown but not scored, since
the study gives it no weight; a word's effort is measured on its lower-case
form with the score's own weights, typed alone (no space around it); a word
table keeps 1,000 words.

Decided by the agent on 2026-11-18, to review by the maintainer, for the
Comparer's sub-tabs: the tab order and names; the overview's nine leader
metrics; the filters folded under 720 px; the heat maps' scale leaving the
space bar out (drawn at its darkest, the legend reading « ≥ »); the stacked
figures writing the home row's share beside the row usage and nothing beside
the trigram classes; the corpus kinds (`literature`, `encyclopedia`, `news`,
`sentences`, `words`, `code`) and the Leipzig sentence samples filed as
encyclopedia or news by their source.
