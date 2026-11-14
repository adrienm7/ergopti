<!-- docs/audits/layout-analysers/report.md -->

# Study of the public keyboard layout analysers

Written on 2026-11-14 (Paris time) for the TODO section « Ergopti Studio inside
Ergopti+ ». It reviews the public layout analysers and generators, compares
their metrics, corpora and interfaces, and derives the metrics, the default
weights and the layout library of the shared engine
(`static/ergopti_plus/_shared/ui/layout_analysis/`, specified in
[docs/design/layout-analysis.md](../../design/layout-analysis.md)).

## Method and limits

Every claim comes from the source code of the tool, cloned from GitHub at the
commit named in its section, or from the tool's own documentation in its
repository. The live sites patorjk.com, klanext.keyboard-design.com, ergol.org,
mkweb.bcgsc.ca (carpalx), workmanlayout.org, semilin.github.io and
docs.google.com could not be reached from the session that wrote this study, so
nothing here was checked on a live page. KLAnext is closed source: what this
study says about it comes from the screenshots kept in the Ergo-L repository.
Points that could not be confirmed in a primary source are marked
**unverified**.

| Tool                      | Source read                                                                             | Revision           |
| ------------------------- | --------------------------------------------------------------------------------------- | ------------------ |
| KLA                       | https://github.com/patorjk/keyboard-layout-analyzer                                     | 7ef2fe6 (2019-12)  |
| KLA, SteveP fork          | https://github.com/stevep99/keyboard-layout-analyzer                                    | 945fe9f (2021-05)  |
| KLAnext                   | screenshots in https://github.com/Nuclear-Squid/ergol                                   | closed source      |
| Ergo-L analyser           | https://github.com/Nuclear-Squid/ergol, `code/layout-analyzer.js`                       | 03c6c7c (2026-09)  |
| Kalamine                  | https://github.com/OneDeadKey/kalamine, PyPI 0.40                                       | a9724bf (2026-04)  |
| x-keyboard                | https://github.com/OneDeadKey/x-keyboard                                                | 554fa34            |
| genkey                    | https://github.com/semilin/genkey                                                       | f1f4173 (2024-07)  |
| Oxeylyzer                 | https://github.com/O-X-E-Y/oxeylyzer (and its `data-files` branch)                      | 5a85ca0 (2026-11)  |
| cmini                     | https://github.com/Apsu/cmini                                                           | 0db088e (2026-08)  |
| Keysolve 2                | https://github.com/GalileoBlues/Keysolve2, https://github.com/GalileoBlues/keysolve-web | 2025-06            |
| trialyzer                 | https://github.com/samuelxyz/trialyzer                                                  | 1e70d55 (2023-06)  |
| keymui / keymeow          | https://github.com/semilin/keymui, https://github.com/semilin/km_metrics                | 2024-12            |
| keyboard_layout_optimizer | https://github.com/dariogoetz/keyboard_layout_optimizer                                 | 8c8ec9f (2026-04)  |
| carpalx                   | re-implementations https://github.com/dmtrs/carpalx.js and jackhumbert/typing_model     | site unreachable   |
| keygen (xsznix)           | https://github.com/xsznix/keygen                                                        | 37ae949 (2024-09)  |
| Colemak Mod-DH            | https://github.com/ColemakMods/mod-dh, `gh-pages` branch                                | 1d23c82 (2026-10)  |
| Keyboard Layouts Doc      | Markdown port https://github.com/aoi-buh/Keyboard-Layouts-Doc                           | aad1ded (2024-12)  |
| bepo.fr tools             | https://bepo.fr/wiki/Outils                                                             | fetched 2026-11-14 |

## 1. Keyboard Layout Analyzer (KLA)

- **Links.** https://patorjk.com/keyboard-layout-analyzer, source
  https://github.com/patorjk/keyboard-layout-analyzer (MIT). Unmaintained since
  2019 (AngularJS 1.2); the README itself says the minified build is broken.
- **Model.** A simulation, not n-gram tables: `js/analyzer.js` (`examine`) walks
  the text character by character, finds the character on one of four levels
  (base, Shift, AltGr, Shift+AltGr; the first match wins), presses the Shift of
  the opposite hand, and moves fingers. No dead keys: an accented letter that
  needs one is dropped and listed as an error. ’ “ ” – fall back to ' " -.
- **Metrics.**
  - Distance: Euclidean distance between key centres, 50 px = 1.9 cm
    (`pixelsPerCm = 26.315789`). Before each character every unused finger goes
    back home and that trip counts.
  - Finger usage and row usage per key press, modifiers included.
  - « Consecutive same finger » and « same hand » per key press (not per
    bigram), with an option to ignore same-key repeats.
  - Modifier use, heat map.
- **Score** (`scoreLayouts`): `17·hand + 17·same-finger + 33·finger usage +
33·distance`, higher is better, with `distance = max(0, 4 − cm per press)/4`,
  `finger usage = Σ min(%, 20)·w / 260` (w: pinky 0.5, ring 1, middle 4, index
  2, thumb 0.5), `same finger = max(0, 10 − %)/10`, `same hand = max(0, 50 −
%)/50`.
- **Corpora.** Three English presets (Alice chapter 1, common English words,
  SAT words) or pasted text.
- **UI.** Up to five layouts side by side plus a generated « personalized »
  one; ranking table, charts, heat maps; editable visual keyboard; ANSI, ISO and
  ErgoDox boards; 107 layout files shipped.
- **Strengths.** Visual, comparative, any text, per-key fingering, Shift of the
  opposite hand modelled.
- **Weaknesses.** The score rewards the middle finger (weight 4) and penalises
  every same-hand press, so rolls count against a layout; no SFB as a share of
  bigrams, no skipgrams, scissors, lateral stretches, rolls or redirects; no
  dead keys; English only; unmaintained.
- **SteveP's fork** (https://stevep99.github.io/keyboard-layout-analyzer/)
  replaces distance with a Fitts-style effort (lateral ×2.0; pinky 1.6, ring
  1.3, middle 1.1, index 1.0) and reweights the score: distance 0.5, same finger
  0.3, finger usage 0.2, same hand 0.

## 2. KLAnext

- **Links.** https://klanext.keyboard-design.com (Ian Douglas). A non-free fork
  of KLAtest (Shena'Fu), itself a KLA fork; source not public. The public
  `iandoug/keyboard-layout-analyzer` repository is an unrelated 2016 KLA fork.
- **Score** (screenshot caption in the Ergo-L repository,
  `www/content/articles/analyse_et_optimisation/klanext_score.png`): « distance
  your fingers moved (40 %), Same Finger Bigrams (40 %) and hand alternation (20
  %) », lower is better; an « +Effort » column gives the gap to the best layout.
  Finger usage is out of the score. The normalisation of each component is
  **unverified**.
- **Corpora.** « Chained English Bigrams 7 (1MB) » and « KLA Introduction » seen
  in screenshots; full list **unverified**. Ergopti's site already ships the
  KLAnext JSON files and the chained-bigram corpora
  (`static/layouts/kla_iso/`, `static/corpus/original/en/`).
- **Boards.** standard, european, ergodox, matrix; layout files named
  `name.lang.board`.
- **Strengths.** Larger corpora than KLA, a single readable overall score.
- **Weaknesses** (Ergo-L's critique, same article): the score penalises rolls,
  ignores lateral stretches, scissors and finger load, and is more sensitive to
  the board than to the layout (Bépo on ErgoDox beats Sturdy on ANSI in
  English). Every selected layout re-processes the corpus, which is slow — the
  maintainer's main complaint (TODO « Instant analysis »).

## 3. The Ergo-L site analyser (ergol.org/stats)

- **Links.** https://ergol.org/stats/, source `code/layout-analyzer.js` in
  https://github.com/Nuclear-Squid/ergol; glossary
  `www/content/ressources/glossaire.md`; method article
  `www/content/articles/analyse_et_optimisation/index.md`. The same analyser is
  in Kalamine (`kalamine/www/mjs/layout-analyzer.js`).
- **Pipeline.**
  1. The corpus (`corpus/chardict.py`) is lower-cased; digits, space, tab and
     line breaks are not counted and cut the n-grams, so no bigram crosses a
     word boundary. Frequencies are stored as percentages, rounded (the tail is
     lost).
  2. Each character becomes the cheapest key sequence of the Kalamine layout,
     dead keys and chained dead keys included (prefer no 1dk, then fewer keys
     outside the 3×10 block, then a lower level, then fewer keys).
     Typographic characters fall back to plain ones (« » “ ” → ", ’ → ', – —
     → -, … → ...).
  3. Key bigrams and trigrams are taken over the expanded key stream, so a dead
     key adds its own bigrams. Shift and AltGr are not counted as presses.
- **Metrics** (exact, `getDigramType`, `getTrigramType`): SKB (same key), SFB
  (same finger, other key); scissor (same hand, two rows apart, or one row for
  ring and pinky unless the pinky is on the home row), « extended » when a key is
  an extension key (inner index column or outside the 3×10 block); LSB (same
  hand, touches an extension key, not a scissor); every other same-hand bigram
  is an inward or outward roll. Trigrams: SKS/SFS (first and third key on one
  finger), redirect (one hand, direction change) and bad redirect (no index).
  Finger load split into good / meh / bad keys; a warning when the unsupported
  characters reach 0.5 %. Hand change is computed but not shown.
- **Score.** None, on purpose (`www/content/stats.html`): five criteria (heat
  map, finger load, SFU, scissors and LSB, bad redirects), a layout being judged
  by its worst one; the page cites Goodhart's law.
- **Corpora.** _Don Quixote_ in English (Ormsby) and French (Furne), and their
  concatenation (default). No text of one's own.
- **UI.** x-keyboard emulator, selectors for layout (22 Kalamine layouts),
  layers, geometry and corpus, state in the URL; collapsible tables listing every
  offending n-gram with its frequency.
- **Strengths.** The only public analyser with exact dead-key handling; lists
  every bad n-gram; French corpora; no misleading single number.
- **Weaknesses.** Fixed corpora, lower-cased with spaces and digits removed
  (capitals, Shift, digits and word boundaries are never measured); one ISO
  fingering whatever the geometry selected; coarse LSB and roll definitions;
  unsupported characters stay in the denominators; no custom text.

## 4. Kalamine

- **Links.** https://github.com/OneDeadKey/kalamine (MIT, Fabien Cazenave),
  https://pypi.org/project/kalamine/ (0.40, 2026-04-19), format guide
  `docs/README.md`, KLC and XKB notes `docs/klc.md`, `docs/xkb.md`.
- **Format.** One TOML (or YAML) file: metadata (`name`, `name8`, `locale`,
  `variant`, `description`, `author`, `url`, `license`, `version`, `geometry`,
  `extends`, `[spacebar]`) and ASCII-art blocks read at fixed character columns:
  `base` (Base, Shift and the 1dk column), `altgr` (AltGr), or `full` (base and
  AltGr, which silently drops the 1dk layer). One code point per level, six
  levels at most. Twenty built-in dead keys with fixed tables
  (`data/dead_keys.yaml`) and one custom dead key, `**` (the 1dk); chains start
  only from the 1dk. Geometries ANSI, ISO, ABNT, JIS, ALT and ERGO
  (`data/geometry.yaml`), `--angle-mod`, `--qwerty-shortcuts` (AHK and KLC
  only). Only the alphanumeric block and the space bar can be remapped.
- **Generators** (`kalamine/generators/`): KLC for MSKLC (UTF-16LE, CRLF; no
  chained dead keys, no AltGr+Space; arbitrary `OEM_1..9` virtual keys), AHK
  (AutoHotkey v1.1 only), macOS `.keylayout` (single file, no bundle, no icon,
  chains only from the 1dk), XKB symbols and a standalone keymap (the 1dk is a
  Level3/Level5 latch and standard dead keys use the system Compose tables, so
  Linux results can differ from Windows and macOS), web JSON and SVG for
  x-keyboard. `wkalamine` builds signed MSKLC installers; `xkalamine` installs
  on Linux (`~/.config/xkb` on Wayland, `/usr/share/X11/xkb` as root).
  `kalamine watch` serves a live emulator and the analyser.
- **Statistics.** The analyser described in section 3 (same code).
- **Compared with Ergopti's layout source** (`docs/design/layout-source-format.md`):
  Ergopti's TOML is a structured record per physical key (KeyboardEvent.code)
  and per layer, with named modifiers, any number of layers, named dead keys with
  their own rule tables and chains from any dead key, multi-character outputs,
  per-OS key overrides and an ANSI derivation rule; it is validated by a schema
  with stable error codes and compiled to `.keylayout`, XKB and KLC by one
  generator, with a per-target report of what each target leaves out. Kalamine's
  picture-like source is quicker to read and edit by hand and gives seven outputs
  from one file, but it is capped at six levels, breaks on a misaligned column,
  allows one custom dead key, and lets the Linux behaviour drift from the other
  systems. Ergopti keeps its source; the Studio can import a Kalamine JSON later
  if the maintainer wants it (not in this scope).

## 5. genkey (semilin)

- **Links.** https://github.com/semilin/genkey (GPL-3.0, Go), docs in
  https://github.com/semilin/semilin.github.io (`src/genkey/docs.org`). Last
  major version; the author points to Oxeylyzer.
- **Metrics** (`layout.go`). Weighted distance `1.4·dx² + dy²`; SFB and DSFB
  summed per finger and per key pair; skipgrams up to a gap of 10 weighted
  `1/2^(gap−1)`; **finger speed** `800/Total · Σ (1.0·SFB + 0.5·DSFB)·(d_w +
2·0.01) / KPS_f` with `KPS = [1.5, 3.6, 4.8, 5.5, 5.5, 4.8, 3.6, 1.5]` (pinky
  to pinky); LSB = adjacent fingers (index–middle, pinky–ring) at ≥ 2 columns;
  index balance. Trigram classes onehand, redirect, alternate, roll (no bad
  redirect, no scissors).
- **Score.** `3·fspeed + 1·LSB % + 0.3·|index imbalance|`, lower is better;
  trigram weights 0 by default.
- **Corpus.** shai-iweb (524.7 M characters), ASCII letters and `,./;'-`.
- **Strengths / weaknesses.** Fast, introduced finger speed; 30-key matrix only,
  no layers, thumbs, scissors or bad redirects, English, unmaintained.

## 6. Oxeylyzer

- **Links.** https://github.com/O-X-E-Y/oxeylyzer (Apache-2.0, Rust; REPL and
  Tauri desktop app, active in 2026). Layouts in DOF JSON (`libdof`), with key
  geometry and thumbs.
- **Default weights** (`config.toml`, higher is better): `sfbs −7`, `sfs −1`,
  `stretches −0.3`, `pinky_ring_bigrams −0.2`, `inrolls 2.5`, `outrolls 2.4`,
  `onehands 0.9`, `alternates 0.4`, `alternates_sfs 0.1`, `redirects −3.4`,
  `redirects_sfs −4.2`, `bad_redirects −4.9`, `bad_redirects_sfs −5.5`; finger
  weights 1.4 / 3.6 / 4.8 / 5.5 / 3.3 (pinky to thumb). `lateral_penalty` is
  parsed but never used.
- **Definitions.** Same-finger weighted bigram `(bigram + r·skip1 + r²·skip2 +
r³·skip3)` with `r = 1/7`, times the distance scaled by `5.5/finger weight`;
  « stretches » replace scissors and LSB in the score (a geometric overlap
  model); scissors (adjacent fingers, |dy| > 1.9, index below middle excluded)
  and LSB (middle–index, |dx| ≥ 1.5) as statistics only. Trigrams: thumb
  (ignored), alternate (or alternate-SFS), same-finger, redirect / bad redirect
  (no index) and their SFS variants, onehand, inroll / outroll.
- **Corpora.** 13 language data files (english, german, french configs with an
  accent key, shai: 450 M characters…).
- **Library.** 815 `.dof` layouts in about 60 language folders on the
  `data-files` branch (146 English, 30 French).
- **Strengths / weaknesses.** Fast incremental scoring, many languages, real
  geometry, GUI; base layer only (no layers, modifiers or dead keys), README
  partly outdated, hand-tuned weights.

## 7. cmini

- **Links.** https://github.com/Apsu/cmini (GPL-3.0, Python Discord bot), ports
  cmini-rs and jmini.
- **Metrics** (`util/analyzer.py`, `table.json`): SFB (spaces and repeats
  excluded, % of all bigrams); trigram classes from a table of 1 025 finger
  triples (roll in/out, alternate, onehand in/out, redirect, bad redirect = no
  index, SFS from trigrams…); finger speed ported from genkey. No score.
- **Corpora.** 19 (shai 436 M characters, french 106 M, monkeyracer…), chosen
  per user.
- **Library.** 4 121 user-submitted JSON layouts (30-key centric, with the
  Discord user id of the submitter); licence of the data unclear.
- **Strengths / weaknesses.** Community reference for the vocabulary; Discord
  only, no layers, accents mostly absent.

## 8. Other analysers and generators

- **Keysolve / Keysolve 2** (ClemenPine, GPL-3.0, web): SFB/SFS, LSB/LSS
  (adjacent fingers, two columns), HSB/FSB (one or two rows, the lower key typed
  by a middle or ring finger), trigram classes; monkeyracer corpus; 212 layouts;
  no combined score; drag-swap on a heat map.
- **trialyzer** (MIT, Python): weights each trigram by the user's own measured
  typing time, no chosen weights; finds 2-1 rolls faster than alternation and
  same-finger skipgrams faster than SFBs but « not twice as fast »; scissor =
  neighbouring fingers ≥ 2u apart.
- **keymui / keymeow / km_metrics** (GPL-3.0): metrics as data (sfb, sfs,
  sfb/sfs distance, lsb = adjacent fingers with x-distance ≥ 2, alt, inroll,
  outroll, same-row roll, redirect, onehand, skip-alternate…), several boards,
  chords; no score.
- **keyboard_layout_optimizer** (Dario Götz, GPL-3.0, Rust, Neo/Bone/AdNW
  lineage after ArneBab's evolve scripts): the only mature open tool with layers,
  modifiers and thumbs. Default weights: finger_repeats 780 (SFB with
  distance), no_handswitch_in_trigram 400, movement_pattern 100,
  modifier_usage 100, finger_balance 50 (intended loads pinky 1.0, ring 1.6,
  middle 2.0, index 2.0), hand_disbalance 40, key_costs 20, inward rolls −2,
  outward rolls −1. Corpus Leipzig German 60 % / English 40 %. Simulated
  annealing.
- **carpalx** (Martin Krzywinski): triad effort `e = k_b·b + k_p·p + k_s·s`
  (base key effort, hand/row/finger penalties, stroke path), parameters
  0.3555 / 0.6423 / 0.4268 in carpalx.js; Gutenberg books; letters only, ANSI.
- **keygen** (xsznix, MIT): base key penalty grid plus sequence penalties on
  4-grams (same finger 5, long jump 10, pinky/ring twist 10, roll reversal 20,
  inward roll −0.125…).
- **Colemak Mod-DH site** (SteveP): Fitts-style effort `P_f + √((P_f·F_y)² +
(2·F_x)²)`, finger factors 1.0 / 1.1 / 1.3 / 1.6, bigram penalties (same
  finger 2.5 / 3.0 / 4.0 by row distance, pinky–ring 0.5 / 1.0 / 1.5); French
  among its frequency tables.
- **Workman**: a key effort grid avoiding the centre columns.
- **Keyboard Layouts Doc** (Ec0vid, Markdown port GPL-3.0): the community
  definitions this engine follows — SFB, SFS, LSB (adjacent fingers ≥ 2u),
  full and half scissors (« the finger that prefers being higher is not »),
  alternate, roll, onehand, redirect, weak redirect (no index).
- **French tools** (https://bepo.fr/wiki/Outils): Klay, KeyboardEvaluator and
  Nicolas Brodu's comparator, mostly behind dead links; the bépo method is
  corpus → symbol and digram statistics → key accessibility costs → global
  cost. xlamorlette/optimiseur-clavier only optimises the left/right split.
- **Not found:** a200, « Pinelyzer », playground.colemak.com.

## 9. Comparison

| Capability                           | KLA                | KLAnext  | Ergo-L / Kalamine | genkey | Oxeylyzer | cmini | dariogoetz | **Ergopti engine** |
| ------------------------------------ | ------------------ | -------- | ----------------- | ------ | --------- | ----- | ---------- | ------------------ |
| Runs in the browser, no server       | yes                | no       | yes               | no     | no (app)  | no    | yes (WASM) | yes                |
| User's own text                      | yes                | yes      | no                | yes    | yes       | no    | yes        | yes, and keystats  |
| Pre-computed n-gram tables (instant) | no                 | no       | yes               | yes    | yes       | yes   | yes        | yes                |
| Dead keys and chained dead keys      | no                 | no       | yes               | no     | no        | no    | partly     | yes                |
| Shift / AltGr counted                | yes                | yes      | no                | no     | no        | no    | yes        | yes                |
| Capitals, digits, word boundaries    | yes                | yes      | no                | no     | partly    | no    | yes        | yes                |
| SFB / SFS                            | per press          | SFB      | yes               | yes    | yes       | yes   | yes        | yes                |
| LSB, full and half scissors          | no                 | no       | yes (coarse)      | LSB    | stats     | no    | partly     | yes                |
| 2- and 3-key rolls, alternation      | no                 | no       | 2-key             | yes    | yes       | yes   | yes        | yes                |
| Redirects and bad redirects          | no                 | no       | yes               | no bad | yes       | yes   | yes        | yes                |
| Distance                             | yes                | yes      | no                | yes    | yes       | no    | partly     | yes                |
| ISO / ANSI / ortho / angle fingering | ANSI, ISO, ErgoDox | 4 boards | display only      | yes    | yes       | yes   | yes        | yes                |
| Coverage, compact boards, shortcuts  | no                 | no       | warning only      | no     | no        | no    | no         | yes                |
| One global score, editable weights   | fixed              | fixed    | none              | yes    | yes       | none  | yes        | yes, contributions |
| Layout library                       | 107                | many     | 22                | 30     | 815       | 4 121 | some       | 115                |

## 10. What the Ergopti engine takes and adds

Every metric is defined exactly in
[docs/design/layout-analysis.md](../../design/layout-analysis.md); the choices
below are where the tools disagree.

1. **Exact keystrokes from n-gram tables** (from Ergo-L/Kalamine): each
   character becomes its cheapest key sequence (dead keys included), and the key
   bigrams and trigrams are rebuilt exactly from the character uni-, bi- and
   trigrams, so a corpus or the keystats store is reduced once and every layout
   is scored on the tables (no text pass per layout: KLAnext's slowness).
2. **Capitals, digits, spaces and word boundaries kept** (from KLA, against
   Ergo-L's lower-casing): Shift and AltGr are pressed by the other hand's pinky
   or a thumb and count in finger load, distance and the modifier metric; the
   bigram and trigram percentages are shares of the key n-grams **without a
   thumb key** (cmini, Oxeylyzer), so they stay comparable across corpora with
   and without spaces.
3. **Definitions** follow the Keyboard Layouts Doc: SFB (same finger, other
   key), repeats apart; SFS from trigrams (cmini, Keysolve); LSB = adjacent
   fingers of one hand with a lateral key (index inner column, pinky outer
   columns); full and half scissors only when the longer finger is the lower one;
   inward means toward the index; bad redirect = no index (Ergo-L, Oxeylyzer,
   cmini).
4. **Added by the maintainer's requirements** (TODO, 2026-11-14): character
   coverage, compact-keyboard fitness (ISO and ANSI 60–100 %, 40 %, 3 × 10),
   direct-access digits, the 7th right-hand column, and the left-hand shortcut
   letters (the Command layer of a registry layout is read for it).
5. **A global score with visible contributions** (KLA, KLAnext, genkey,
   Oxeylyzer and dariogoetz have one; Ergo-L refuses one): the engine gives the
   score **and** every metric with its contribution, so Ergo-L's « judge by the
   worst criterion » stays possible on the same page.

## 11. Default weights

The weights are stored once in
`static/ergopti_plus/_shared/layouts/data/analysis/score_weights.json`. A weight
is the number of score points one unit of the metric is worth (one percentage
point, or one millimetre); the metric's direction gives the sign. Their
magnitudes are set so that the typical spread of each metric between good and
bad layouts on the reference corpora weighs as the tools above weigh it.

| Metric           | Weight | Why                                                                                                                                                   |
| ---------------- | -----: | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| sfb              |     10 | The worst event for every tool: KLAnext 40 %, genkey's finger speed, Oxeylyzer −7 against +2.5 for an inward roll, dariogoetz's largest weight (780). |
| sfs              |      3 | A skipgram is lighter: genkey 0.5 × SFB, Oxeylyzer 1/7, trialyzer « faster but not twice as fast »; 0.3 × SFB sits between.                           |
| lsb              |      2 | Ergo-L's criterion 4; Oxeylyzer folds it in « stretches » (−0.3 per scaled unit); genkey 1 per %.                                                     |
| scissors         |      3 | Full scissors as bad as a skipgram (Ergo-L criterion 4, keygen's long jump 10 against same finger 5).                                                 |
| half_scissors    |      1 | One row only: a third of a full scissor.                                                                                                              |
| redirect         |    1.5 | Oxeylyzer −3.4 against +2.5 for an inward roll (×1.4); here 1.5 against 1.                                                                            |
| redirect_bad     |      3 | Added to the redirect, 4.5 in all: Oxeylyzer −4.9 (×2 a roll) and Ergo-L's criterion 5.                                                               |
| roll_in          |      1 | The reference reward; inward preferred (Oxeylyzer 2.5 / 2.4, dariogoetz −2 / −1).                                                                     |
| roll_out         |    0.5 | Half an inward roll (dariogoetz).                                                                                                                     |
| roll3_in         |      1 | As the 2-key roll it extends (Oxeylyzer onehands 0.9).                                                                                                |
| roll3_out        |    0.5 | As the outward roll.                                                                                                                                  |
| alternation      |    0.3 | Oxeylyzer 0.4 against 2.5 for a roll; trialyzer measured 2-1 rolls faster than alternation.                                                           |
| home_row         |    0.3 | Ergo-L's criterion 1 (heat map on comfortable keys); KLA and carpalx base efforts.                                                                    |
| distance         |      1 | Per mm per character: KLA 33 % and KLAnext 40 % weigh it heavily, Ergo-L not at all; 1 point per mm keeps it a tie-breaker between modern layouts.    |
| finger_imbalance |    0.4 | dariogoetz finger_balance 50 against finger_repeats 780; Ergo-L criterion 2.                                                                          |
| hand_imbalance   |    0.2 | dariogoetz hand_disbalance 40.                                                                                                                        |
| pinky_load       |    0.3 | Ergo-L criterion 2 (spare the pinkies); genkey/Oxeylyzer finger weights make the pinky the weakest finger.                                            |
| modifier_usage   |    0.5 | dariogoetz modifier_usage 100; KLA counts Shift presses.                                                                                              |
| dead_key_usage   |    0.5 | A dead key is already an extra keystroke in every n-gram metric (Ergo-L); this small extra keeps two equal layouts apart.                             |
| outer_column     |      1 | Maintainer: the 7th right-hand column is penalised twice (distance and compact fitness), and shown on its own.                                        |
| unsupported      |      5 | A character the layout cannot type removes its n-grams from every other metric, which would flatter the layout; Ergo-L warns at 0.5 %.                |
| compact_fit      |    0.1 | Maintainer requirement; 1 point per 10 % of characters lost on a compact board.                                                                       |
| char_coverage    |    0.1 | Maintainer requirement (Bépo and Optimot gain); 1 point per 10 % of the reference set.                                                                |
| direct_digits    |   0.03 | Maintainer: « a small bonus »: 3 points for ten direct digits.                                                                                        |
| shortcut_left    |   0.15 | Maintainer: about 5–10 % of the score; measured 5.6 % of Ergopti's absolute contributions on the French reference corpus, 6.4 % on English.           |

These weights are **decided by the agent, to review by the maintainer**. The
Studio lets every user change each weight and restore the defaults; the score
of every layout is recomputed without re-analysing (`LAYOUT_ANALYSIS.rescore`).

## 12. First results

Measured with the engine on an ISO board, the whole library (115 layouts) in
about 0.3 s per corpus. French: `static/corpus/original/fr/corpus_nemolivier.txt`
(2.5 MB); English: `static/corpus/original/en/Chained English Bigrams 9.txt`
(2.9 MB). A layout of the imported library has only its alphabetic block (no
accents): its `unsupported` share shows what it cannot type.

French corpus (best eight and the reference layouts):

| Rank | Layout        | Score |  SFB |  SFS |  LSB | Scissors | Bad redirects | Inward rolls | Alternation | Home row | mm/char | Unsupported |
| ---: | ------------- | ----: | ---: | ---: | ---: | -------: | ------------: | -----------: | ----------: | -------: | ------: | ----------: |
|    1 | Ergopti+ ANSI |  20.4 | 0.97 | 6.23 | 1.31 |     0.31 |          0.45 |        14.89 |       39.84 |    66.62 |     8.9 |        0.00 |
|    2 | beo           |  19.2 | 0.77 | 5.48 | 1.57 |     0.90 |          0.68 |        13.26 |       39.69 |    63.95 |     7.4 |        0.73 |
|    3 | Ergopti+      |  18.7 | 1.02 | 6.21 | 1.43 |     0.24 |          0.46 |        14.81 |       39.84 |    65.36 |     9.1 |        0.00 |
|    4 | Ergopti       |  16.8 | 1.36 | 6.44 | 1.29 |     0.25 |          0.42 |        14.89 |       39.64 |    65.43 |     8.4 |        0.00 |
|    6 | Ergo-L        |  11.7 | 1.79 | 6.09 | 1.46 |     0.19 |          1.89 |        19.65 |       28.97 |    70.21 |     8.2 |        0.01 |
|   11 | bépo          | −10.1 | 2.88 | 7.72 | 0.85 |     0.08 |          0.68 |        15.65 |       38.91 |    71.18 |     8.9 |        0.00 |
|  109 | QWERTY (US)   | −85.3 | 7.40 | 8.70 | 5.33 |     0.54 |          1.06 |        17.14 |       29.18 |    29.80 |    13.6 |        2.21 |
|  110 | AZERTY (FR)   | −87.8 | 7.60 | 7.97 | 4.40 |     1.47 |          1.03 |        18.07 |       28.00 |    23.77 |    15.3 |        0.04 |

English corpus: Graphite (9.5), Gallium (9.4), Gallium Colstag (9.4), Maya,
Nerbs, Hands Down Neu, Heart and AdNW lead; Colemak-DH −6.1, Ergopti+ −7.8,
Ergo-L −10.6, Dvorak −13.8, Bépo −29.9, QWERTY −89.6, AZERTY −102.8. The SFB
of QWERTY (7.0 %), Colemak-DH (1.9 %) and Dvorak (3.2 %) on this synthetic
corpus are of the order the Keyboard Layouts Doc gives (QWERTY ~6 %, Dvorak
2.5 %, Colemak 1.5 %), the difference coming from its chained bigrams (« e, »
alone is 0.2 % of Colemak-DH's bigrams).

## 13. Layout library

`static/ergopti_plus/_shared/layouts/data/analysis/layout_library.json` holds
107 alphabetic blocks: 72 from the Oxeylyzer layout set (Apache-2.0
repository; the `data-files` branch has no licence file of its own) and, for 35
classics that set lacks (Graphite, Gallium, Minimak, Asset, Capewell, BEAKL,
Hands Down Neu…), from cmini (GPL-3.0 repository, user-submitted data; the
Discord user ids were not imported). The codegen adds the six registry layouts
and the reference QWERTY and AZERTY with all their layers and dead keys: 115
layouts. Each entry names its `source` and `source_path`.

**Decided by the agent, to review by the maintainer:** whether keeping the 35
cmini blocks is acceptable (a layout's key arrangement is a short factual list
published by its author, but the collection's licence does not say so); if
not, deleting them from the JSON and regenerating leaves 80 layouts. A further
step can complete the French library layouts (Optimot, Béopy, Ergo-L variants…)
with their real layers and dead keys by adding them to the registry.

## 14. Decided by the agent, to review by the maintainer

- The default fingering: Digit6 is typed by the right index; the ISO key left of
  Z and Z by the left pinky; the space bar by the right thumb (thumbs are left
  out of every bigram and trigram metric, so this only moves load between the
  two thumbs). An angle-mod layout of the library uses the angle fingering on an
  ISO board.
- The ideal finger load of `finger_imbalance` (pinky 8, ring 11, middle 15,
  index 16 % per hand), from dariogoetz's intended loads with the pinkies
  lowered (Ergo-L criterion 2).
- The usefulness table of the shortcut letters and the ease of each left-hand
  key, both in `analysis_model.json`.
- The reference character set of `char_coverage` (ASCII, French letters and
  typography, a few European letters).
- The weights above.
