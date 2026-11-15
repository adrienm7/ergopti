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
| `static/ergopti_plus/_shared/layouts/data/analysis/layout_library.json`        | The alphabetic blocks of the imported layouts, with their source.                                                           |
| `static/ergopti_plus/_shared/layouts/data/analysis/sources.json`               | The references behind every metric and sourced value, shown by the « i » popovers.                                          |
| `static/ergopti_plus/_shared/tests/corpus/layout_analysis/metric_vectors.json` | Hand-computed reference vectors; `npm run test:layout-analysis-engine`.                                                     |

Key geometry comes from `_shared/layouts/data/keycodes/physical_keys.json`; the
registry layouts and the reference QWERTY and AZERTY join the library through
the layout composer's reader (`tools/lib/layout-composer.cjs`), converted by
the engine's own `layoutFromComposerSource`.

A page loads, from the `_shared/ui/<page>/` folder:

```html
<script src="../layout_analysis/_generated/analysis_data.js"></script>
<script src="../layout_analysis/analysis_engine.js"></script>
```

## API

All functions are on `LAYOUT_ANALYSIS`. Every invalid input throws.

- `ngramsFromText(text)` → `{chars, bigrams, trigrams}`: counts of 1-, 2- and
  3-character tokens (Unicode code points, case and spaces kept). Line breaks
  and tabs cut the text: no n-gram spans them and they are not counted.
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
- `analyse(layout, ngrams, {keyboard?, weights?, idealLoad?, shortcuts?, formWeights?, profile?, keyGroups?})` → one
  result (`idealLoad` replaces the default target of `finger_imbalance`,
  `shortcuts` the table of `shortcut_left`, `formWeights` the weights of
  `compact_fit`;
  `keyGroups: true` counts every key's worst groups for every event, below):

  ```js
  {
    layout: {id, name, origin, source, language},
    keyboard: 'iso',                 // iso | iso_angle | ansi | ortho
    metrics: {sfb: 0.97, ...},       // every metric below, by id
    fingers: {lp, lr, lm, li, lt, rt, ri, rm, rr, rp},  // % of all presses
    hands: {left, right},            // % of the presses, thumbs apart
    rows: {number, top, home, bottom},
    trigramClasses: {roll3_in, roll3_out, alternation, redirect, roll_mixed, same_finger},
    keys: {KeyE: {presses, sfb, sfs, lsb, scissors, redirect, cost: {metric: part},
                  worst: {event: [[[codes], %], ...]}}, ...},
    coverage: {typed, unsupported, unsupportedChars: {char: count}, bigrams, trigrams},
    score: {total, contributions: {metric: points}, weights}
  }
  ```

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

- `keyScoreCost(result, weights?)` → `{code: points}`: what each key costs the
  global score, Σ weight × `cost` over `KEY_COST_METRICS`; the keys' points add
  up to those metrics' part of the score.

- `score(result, weights?)` → `{total, contributions, weights}`; the given
  weights override the defaults metric by metric.
- `defaultWeights()` → a copy of `score_weights.json` (the « restore defaults »
  action).
- `compare(layouts, ngrams, options)` → the results ranked best first, each
  with `rank`.
- `rescore(results, weights)` → the same results re-scored and re-ranked with
  new weights, without re-analysis (live weight editing).
- `METRICS` → `{id: {unit, better, of}}`; `better` is `lower`, `higher` or
  `none` (shown, not scored).

### Keystats input

The app passes the sums of the keystats tables over the chosen dates and apps
as plain counts (`ngram_chars`, `ngram_bigrams`, `ngram_trigrams`, column `c`
summed per `token`): `{chars: {token: n}, bigrams: {...}, trigrams: {...}}`.
No text leaves the machine and none is needed. Worker T owns that bridge.

## Model

**Keystrokes.** Each character becomes the cheapest key sequence that types it:
a key on a layer, or a dead key (itself on a layer, possibly chained) followed
by the key of the character it composes with. A press costs 1 and each held
modifier 0.5. A typographic character the layout lacks is typed as its plain
form (« » “ ” „ → ", ’ ‘ → ', – — → -, … → ..., no-break spaces → space; the
Kalamine rule), but does not count as covered. A character with no sequence is
**unsupported**.

**What is cached.** A corpus, a pasted text or the keystats store is reduced
once to layout-independent counts: characters, character bigrams and character
trigrams (no text, no word list). The distance-2 character pairs that the
same-finger skipgram metric needs are the first and last characters of those
trigrams, so they need no table of their own. Whether a pair is an SFB, a
skipgram, a roll, an alternation or a redirect depends on the layout: that
classification happens when a layout is scored, by mapping the cached n-grams
onto its keys.

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

**Boards.** Besides the row-staggered `iso`, `iso_angle`, `ansi` and
`ortho`, the keyboards include `corne`, `planck`, `ergodox`, `moonlander` and
`kinesis_advantage` (`board_geometries.json`).

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

| Id                 | Unit | Better | Definition                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------ | ---- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sfb`              | %    | lower  | Same-finger bigram: two consecutive keys on one finger, different keys.                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `repeat`           | %    | none   | The same key twice.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `sfs`              | %    | lower  | Same-finger skipgram: first and third key of a trigram on one finger, different keys.                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `lsb`              | %    | lower  | Lateral stretch bigram: one hand, adjacent fingers, one key lateral (index inner column Digit5/T/G/B, Digit6/Y/H/N; pinky outer keys Backquote, IntlBackslash, Minus, Equal, brackets, Quote, Backslash).                                                                                                                                                                                                                                                                                                |
| `scissors`         | %    | lower  | Full scissor: one hand, adjacent fingers, the longer finger two or more rows below the shorter one (lengths: middle > ring > index > pinky).                                                                                                                                                                                                                                                                                                                                                             |
| `half_scissors`    | %    | lower  | Half scissor: the same, one row apart.                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `roll_in`          | %    | higher | Two-key inward roll: one hand, different fingers, toward the index.                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `roll_out`         | %    | higher | Two-key outward roll: toward the pinky.                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `hand_change`      | %    | none   | Two keys on different hands.                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `roll3_in`         | %    | higher | Three-key inward roll: one hand, no repeated finger, the order rising on both moves.                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `roll3_out`        | %    | higher | Three-key outward roll: falling on both moves.                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `alternation`      | %    | higher | Trigram whose hand changes on both moves (left-right-left), no repeated finger.                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `redirect`         | %    | lower  | One hand, no repeated consecutive finger, the direction changes.                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `redirect_bad`     | %    | lower  | A redirect without the index (counted in `redirect` too).                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `home_row`         | %    | higher | Presses on the home row.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `top_row`          | %    | none   | Presses on the top row.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `bottom_row`       | %    | none   | Presses on the bottom row.                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `number_row`       | %    | none   | Presses on the number row.                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `distance`         | mm   | lower  | Mean distance per typed character from each pressed key's finger home key to the key (modifiers included), with 19.05 mm per key unit; a wide modifier is pressed at its end nearest the hand.                                                                                                                                                                                                                                                                                                           |
| `finger_imbalance` | %    | lower  | Half the sum over the eight fingers of the gap between their share of the non-thumb presses and the ideal load (`ideal_finger_load`).                                                                                                                                                                                                                                                                                                                                                                    |
| `hand_imbalance`   | %    | lower  | Gap between the left and right hands' shares of the non-thumb presses.                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `pinky_load`       | %    | lower  | Both pinkies' share of the non-thumb presses.                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `modifier_usage`   | %    | lower  | Characters typed with Shift or AltGr held.                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `dead_key_usage`   | %    | lower  | Characters typed through a dead key.                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `outer_column`     | %    | lower  | Non-thumb presses on the 7th right-hand column (Equal, BracketRight, Backslash).                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `unsupported`      | %    | lower  | Characters of the corpus the layout cannot type.                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `compact_fit`      | %    | higher | Mean, weighted by the form factors' weights, of the share of the corpus's characters still typed on each compact form factor (`form_factors`: the missing keys of each). A form factor marked `per_keyboard_format` (ISO and ANSI 60–100 %) is measured on the chosen keyboard format (`keyboard_formats`: 100 %, TKL, 75 %, 65 %, 60 %, the editor's and the Comparer's « Format »), each lacking the `keyboard_blocks` it hides; with no format chosen, its weight is shared equally over the formats. |
| `char_coverage`    | %    | higher | Share of `reference_characters` the layout types, substitutes excluded.                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `direct_digits`    | %    | higher | Ten points per digit on the base layer.                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `shortcut_left`    | %    | higher | Σ usefulness × ease of the key of each shortcut letter (`shortcut_letters`, `shortcut_key_ease`; 0 on the right hand) over Σ usefulness. The Command layer wins over the base.                                                                                                                                                                                                                                                                                                                           |

## Global score

`contribution(m) = sign(m) × weight(m) × value(m)`, with `sign = +1` when higher
is better and `−1` when lower is better; `total = Σ contributions`. Every weight
is a finite number ≥ 0, in points per percentage point (or per millimetre).
The defaults and their justification are in the study, section « Default
weights ». A weight of 0 removes a metric from the score; the Studio shows each
contribution beside the metric.

## Credits

Every library layout names its authors (`authors`, with `year`, `url` and
`licence` when known) or, failing that, the collection it was taken from
(`source`). A registry layout takes them from its `meta.toml`; the others from
`_shared/layouts/data/analysis/layout_credits.json`, whose `basis` says whether
the layout's own file or site states the credit (`source`) or it is the
generally known author still to be checked (`knowledge`). The « Comparer »
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
`ngramsFromText` and writes only the tables. Each corpus gets its own file,
`_generated/corpus_<id>.js`, loaded when the corpus is chosen, with the
licence and attribution in its header. `LAYOUT_ANALYSIS_DATA.corpora` lists
the corpora with their licence, attribution, source and size, and the page
shows them under the corpus picker.

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
  quatre-vingts jours_ (Verne) and _Pride and Prejudice_ (Austen); in German
  _Effi Briest_ (Fontane) and _Die Verwandlung_ (Kafka), in Spanish _Don
  Quijote_ (Cervantes) and _Marianela_ (Pérez Galdós), in Italian _Le avventure
  di Pinocchio_ (Collodi) and _Ricordi d'infanzia e di scuola_ (De Amicis), all
  in the public domain. `tools/build/import-corpus-texts.cjs` rebuilds each from
  the ebook pinned by SHA-256 in `static/corpus/text_sources.json`, with one
  stripping rule (the work between the START and END markers, LF line ends,
  blank edges and a closing « End of Project Gutenberg » line removed,
  indentation kept), which reproduces the French and English books byte for
  byte. No Wikisource text is in yet. No e-mail or chat corpus either; the
  candidates are not cleared: the Enron mails hold personal data, the Ubuntu
  IRC logs' licence is still to be checked, and Wikipedia talk pages (CC BY-SA)
  sign every message with a user name.
- Tatoeba: the first 30,000 French and English sentences of the « detailed »
  exports, CC BY 2.0 FR. Each line keeps its sentence id and author, as the
  licence asks. Their `format` is `tsv`, and `tsv_text_column` picks the
  sentence.

- Count tables (`format` `count_table`, « ergopti-count-table » version 1),
  from the Leipzig Corpora Collection (shipped under CC BY 4.0 by the
  maintainer's choice, Ergopti being non-commercial): a million sentences each
  of French Wikipedia 2021, French news 2024 and English Wikipedia 2016,
  counted as text, so bigrams and trigrams cross words; and Lexique 4.10's
  word forms weighted by their frequency per million (CC BY-SA 4.0), counted
  by the word-list rule, so their n-grams stay inside words and the page
  shows the word-list caveat. A table holds `chars`, `bigrams` and `trigrams`
  with their counts, how it was counted (`counted_as`: `text` or
  `word_list`), the count each table kept from (`pruned_below`) and what that
  pruning changed (`prune_check`); the reader refuses another format, an
  n-gram of the wrong length or a count under its floor.
  `tools/build/import-count-tables.cjs` rebuilds them from the archives pinned
  by SHA-256 in `static/corpus/count_table_sources.json`, with the engine's
  own counting rules. It drops the n-grams rarer than the register's
  `prune_ratio` of their table (5e-8) and refuses a table when any metric of
  QWERTY, AZERTY, BÉPO, Ergopti, Dvorak, Colemak or Ergo-L measured on the
  pruned counts differs from the full counts by more than 0.05 (percentage
  points for shares); the largest change, recorded in `prune_check`, is
  0.037. Norvig's counts are not imported: their host is not reachable from
  the build environment.

`static/corpus/frequency/` holds the downloaded frequency lists and count
tables, which the register covers like the texts.

The study (`docs/audits/layout-analysers/report.md`, section 18) lists what
is refused, and why.

## Layout file formats

`_shared/ui/layout_analysis/layout_formats.js` (global `LAYOUT_FORMATS`) reads a
layout file into the engine's shape and reports, item by item, what it could not
map (`{format, layout, unmapped: [{what, detail}]}`); a file it cannot read at
all is refused with a stable code (`format_unknown`, `format_invalid`,
`format_unsupported_board`).

| Reader                                       | Format                                                 | Notes                                                                                                                                           |
| -------------------------------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `fromKla(json)`                              | Keyboard Layout Analyzer JSON (KLA, KLAnext and forks) | `standard` (ANSI), `european` (ISO) and `ergodox` boards, key indexes from KLA's QWERTY key sets; no dead keys exist in the format.             |
| `fromKalamineToml(doc)`                      | Kalamine TOML (parsed)                                 | ISO, ANSI and ERGO drawings; `full`, or `base` (with the 1dk column) and `altgr`; `[spacebar]`; a blank level takes the case Kalamine gives it. |
| `fromKalamineJson(json)`                     | Kalamine / x-keyboard JSON                             | `keymap` and `deadkeys`.                                                                                                                        |
| `fromXkb(text, variant?)`                    | XKB symbols                                            | four levels; `dead_*` keysyms; `include` lines and levels beyond four are reported.                                                             |
| `fromKlc(text, scancodes)`                   | Windows KLC                                            | SHIFTSTATE columns 0, 1, 6, 7; `DEADKEY` tables; ligatures reported.                                                                            |
| `fromKeylayout(text, id, convention, tools)` | macOS .keylayout                                       | through the layout composer's reader; its refusals become `format_invalid`.                                                                     |
| `fromRows(input)`                            | Oxeylyzer DOF, cmini JSON, plain rows                  | base layer, upper case on Shift.                                                                                                                |
| `read(name, text, tools)`                    | any of the above                                       | recognised by content and extension.                                                                                                            |

The standard accents (grave, acute, circumflex, tilde, diaeresis, cedilla…) a
format names without a table compose by Unicode normalisation: the letter
followed by the accent's combining mark, normalised to one character. Writers:
`toSource(layout)` gives an Ergopti layout source the source model validates;
`toKla(layout, fingering)` a KLA JSON on the european board; `toKalamineToml`
a Kalamine ISO `full` drawing, listing what Kalamine cannot hold (another dead
key, several characters on one key). `tools/test/test-layout-formats.cjs` holds
the readers to the repository's own files of Ergopti 1DK v2.1.2 (its Kalamine
TOML, JSON, KLC, XKB and .keylayout) and Ergopti's published KLA files. The
« Comparer » page adds an imported layout to the comparison and shows that
report.

## Comparer page

`_shared/ui/layout_analysis/index.html` is the « Comparer » tab: corpus
(built-in, pasted text, or a .txt, .md, .csv, .html, .docx or .odt file read in
the page), keyboard, layout selection, the global score chart, the sortable
ranking, each layout's contributions, finger load and metrics, and the weights
editor with « restore the defaults ». The site embeds it like the editor
(`?lang=<code>`); the app's Studio window loads the same page. A link may add
`corpus=<built-in id>`, `keyboard=<id>` and `format=<id>`: the page opens on them over the
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
adds or replaces a corpus, listed first and selected when `default` is true, and
`addLayouts([layout, ...])` adds or replaces layouts, ticked, and `setFormat(id)`
chooses the keyboard format (the app's Studio passes the editor's « Format »). The
editor and the Comparer store that format once for both (`corpus_files.js`
`saveFormat`), so the site's two framed pages share it too; on the site the
editor's « Compare with other layouts » keeps the layout in the tab's storage
(`handOff`), the Studio opens « Comparer », and the Comparer ranks it
(`takeHandoff`).
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
  load. The rank is « N of library + 1 ».
- The panel reads the weights, ideal finger load, shortcut table and form
  factor weights the Comparer saved (key
  `LAYOUT_ANALYSIS_FILES.SETTINGS_KEY`), so both pages score alike.
- Corpus and keyboard are its own choices. « Ma frappe » arrives through the
  app's `studio-ngrams` event and becomes the default corpus.
- It lists the main metrics with « i » buttons and the change the last edit
  made (green better, red worse), then the finger load.
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

The library (115 layouts) on a 2.5 MB French corpus takes about 0.3 s from
prepared tables in Node; the gate holds it under 1.5 s. A page computes the
tables of a corpus once (`prepareNgrams`) and keeps them under `hashText` of
the text; built-in corpora can ship their tables pre-computed.

## Decided by the agent, to review by the maintainer

The maintainer settled the space bar thumb, Digit6, the weights, the ideal
finger load and the shortcut letters on 2026-11-14. Still to review: the ISO
key left of Z, the shortcut key ease, the reference character set, the scissor rule (the Keyboard Layouts Doc's « the finger that
prefers being higher is not ») and the default weights; see the study's last
section.
