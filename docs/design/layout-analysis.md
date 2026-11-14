<!-- docs/design/layout-analysis.md -->

# Layout analysis engine

One engine measures a keyboard layout on character n-gram counts, for the
`/studio` page of the site and the Ergopti Studio window of Ergopti+ (Windows,
macOS and Linux: the window is the same shared WebView page on every system, so
no system lacks it). The study it is built from, with the sources of each
definition and of the default weights, is
[docs/audits/layout-analysers/report.md](../audits/layout-analysers/report.md).

## Files

| File                                                                           | Role                                                                                                      |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| `static/ergopti_plus/_shared/ui/layout_analysis/analysis_engine.js`            | The engine: classic script, global `LAYOUT_ANALYSIS`, no DOM, no fetch.                                   |
| `static/ergopti_plus/_shared/ui/layout_analysis/_generated/analysis_data.js`   | Generated global `LAYOUT_ANALYSIS_DATA`; load it first. `npm run codegen:layout-analysis-data:js`.        |
| `static/ergopti_plus/_shared/layouts/data/analysis/analysis_model.json`        | Fingers, home keys, lateral and outer keys, keyboards, ideal finger load, form factors, shortcut letters… |
| `static/ergopti_plus/_shared/layouts/data/analysis/score_weights.json`         | The default weights of the global score (one source).                                                     |
| `static/ergopti_plus/_shared/layouts/data/analysis/layout_library.json`        | The alphabetic blocks of the imported layouts, with their source.                                         |
| `static/ergopti_plus/_shared/layouts/data/analysis/sources.json`               | The references behind every metric and sourced value, shown by the « i » popovers.                        |
| `static/ergopti_plus/_shared/tests/corpus/layout_analysis/metric_vectors.json` | Hand-computed reference vectors; `npm run test:layout-analysis-engine`.                                   |

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
  a string or `{dead: "<next state>"}` (chains). `command` maps a code to the
  letter its Ctrl/Cmd shortcut uses when it differs from the base layer.
  `fingering` is `standard` or `angle`.
- `layoutFromComposerSource(source, codes)` → the same shape from a layout
  composer source (`LayoutComposer.parseSource` of a `.keylayout`, or
  `referenceSource`): the way the Studio analyses the layout being edited (its
  compiled `.keylayout`).
- `defaultIdealLoad()` → a copy of `ideal_finger_load`; `idealLoad(load)` →
  `load` checked (the eight fingers, finite shares ≥ 0, summing to 100 within
  0.05).
- `analyse(layout, ngrams, {keyboard?, weights?, idealLoad?})` → one result
  (`idealLoad` replaces the default target of `finger_imbalance`):

  ```js
  {
    layout: {id, name, origin, source, language},
    keyboard: 'iso',                 // iso | iso_angle | ansi | ortho
    metrics: {sfb: 0.97, ...},       // every metric below, by id
    fingers: {lp, lr, lm, li, lt, rt, ri, rm, rr, rp},  // % of all presses
    hands: {left, right},            // % of the presses, thumbs apart
    rows: {number, top, home, bottom},
    trigramClasses: {roll3_in, roll3_out, alternation, redirect, roll_mixed, same_finger},
    keys: {KeyE: {presses, sfb, sfs, lsb, scissors, redirect, sfbWith: [[code, %], ...]}, ...},
    coverage: {typed, unsupported, unsupportedChars: {char: count}, bigrams, trigrams},
    score: {total, contributions: {metric: points}, weights}
  }
  ```

  `keys` feeds the Studio's live heatmap: each key's share of the presses and
  the share of the bigrams (`sfb`, `lsb`, `scissors`) or trigrams (`sfs`,
  `redirect`) it takes part in, with its three worst same-finger partners.

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

**Shares.** A bigram or trigram metric is a share of the key bigrams or
trigrams **without a thumb key**; a row metric a share of the non-thumb,
non-modifier presses; finger load a share of every press; a « per character »
metric a share of the typed characters.

## Metrics

| Id                 | Unit | Better | Definition                                                                                                                                                                                                |
| ------------------ | ---- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sfb`              | %    | lower  | Same-finger bigram: two consecutive keys on one finger, different keys.                                                                                                                                   |
| `repeat`           | %    | none   | The same key twice.                                                                                                                                                                                       |
| `sfs`              | %    | lower  | Same-finger skipgram: first and third key of a trigram on one finger, different keys.                                                                                                                     |
| `lsb`              | %    | lower  | Lateral stretch bigram: one hand, adjacent fingers, one key lateral (index inner column Digit5/T/G/B, Digit6/Y/H/N; pinky outer keys Backquote, IntlBackslash, Minus, Equal, brackets, Quote, Backslash). |
| `scissors`         | %    | lower  | Full scissor: one hand, adjacent fingers, the longer finger two or more rows below the shorter one (lengths: middle > ring > index > pinky).                                                              |
| `half_scissors`    | %    | lower  | Half scissor: the same, one row apart.                                                                                                                                                                    |
| `roll_in`          | %    | higher | Two-key inward roll: one hand, different fingers, toward the index.                                                                                                                                       |
| `roll_out`         | %    | higher | Two-key outward roll: toward the pinky.                                                                                                                                                                   |
| `hand_change`      | %    | none   | Two keys on different hands.                                                                                                                                                                              |
| `roll3_in`         | %    | higher | Three-key inward roll: one hand, no repeated finger, the order rising on both moves.                                                                                                                      |
| `roll3_out`        | %    | higher | Three-key outward roll: falling on both moves.                                                                                                                                                            |
| `alternation`      | %    | higher | Trigram whose hand changes on both moves (left-right-left), no repeated finger.                                                                                                                           |
| `redirect`         | %    | lower  | One hand, no repeated consecutive finger, the direction changes.                                                                                                                                          |
| `redirect_bad`     | %    | lower  | A redirect without the index (counted in `redirect` too).                                                                                                                                                 |
| `home_row`         | %    | higher | Presses on the home row.                                                                                                                                                                                  |
| `top_row`          | %    | none   | Presses on the top row.                                                                                                                                                                                   |
| `bottom_row`       | %    | none   | Presses on the bottom row.                                                                                                                                                                                |
| `number_row`       | %    | none   | Presses on the number row.                                                                                                                                                                                |
| `distance`         | mm   | lower  | Mean distance per typed character from each pressed key's finger home key to the key (modifiers included), with 19.05 mm per key unit; a wide modifier is pressed at its end nearest the hand.            |
| `finger_imbalance` | %    | lower  | Half the sum over the eight fingers of the gap between their share of the non-thumb presses and the ideal load (`ideal_finger_load`).                                                                     |
| `hand_imbalance`   | %    | lower  | Gap between the left and right hands' shares of the non-thumb presses.                                                                                                                                    |
| `pinky_load`       | %    | lower  | Both pinkies' share of the non-thumb presses.                                                                                                                                                             |
| `modifier_usage`   | %    | lower  | Characters typed with Shift or AltGr held.                                                                                                                                                                |
| `dead_key_usage`   | %    | lower  | Characters typed through a dead key.                                                                                                                                                                      |
| `outer_column`     | %    | lower  | Non-thumb presses on the 7th right-hand column (Equal, BracketRight, Backslash).                                                                                                                          |
| `unsupported`      | %    | lower  | Characters of the corpus the layout cannot type.                                                                                                                                                          |
| `compact_fit`      | %    | higher | Mean, weighted by the form factors' weights, of the share of the corpus's characters still typed on each compact form factor (`form_factors`: the missing keys of each).                                  |
| `char_coverage`    | %    | higher | Share of `reference_characters` the layout types, substitutes excluded.                                                                                                                                   |
| `direct_digits`    | %    | higher | Ten points per digit on the base layer.                                                                                                                                                                   |
| `shortcut_left`    | %    | higher | Σ usefulness × ease of the key of each shortcut letter (`shortcut_letters`, `shortcut_key_ease`; 0 on the right hand) over Σ usefulness. The Command layer wins over the base.                            |

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
(`?lang=<code>`); the app's Studio window loads the same page. A host may
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
`addLayouts([layout, ...])` adds or replaces layouts, ticked. The page also
listens for the app's `studio-ngrams` DOM event (`detail` = the keystats tables)
and turns it into the « My typing » corpus (`my_typing`), the default in the
app. A host `store` (`{list(), save(layout), remove(id)}`, each returning a
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
50 %, index ≥ middle ≥ ring ≥ pinky, pinkies under 8 %).

Weights, ideal finger load, selection, corpus and keyboard are remembered in `localStorage` when
the browser allows it; nothing is sent anywhere.

## Editor analysis panel

`_shared/ui/layout_analysis/analysis_panel.js` (global `LAYOUT_ANALYSIS_PANEL`)
is the live analysis beside the « Éditer » board. `create()` returns
`{node, update(doc), addSection(draw)}`. The editor page appends `node` to its
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
- The panel reads the weights and ideal finger load the Comparer saved (key
  `LAYOUT_ANALYSIS_FILES.SETTINGS_KEY`), so both pages score alike.
- Corpus and keyboard are its own choices. « Ma frappe » arrives through the
  app's `studio-ngrams` event and becomes the default corpus.
- It lists the main metrics with « i » buttons and the change the last edit
  made (green better, red worse), then the finger load.
- `addSection(draw)` adds a view drawn after each analysis with
  `(container, {layout, tables, keyboard, result})`. Other analysers' scores
  use it.

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
