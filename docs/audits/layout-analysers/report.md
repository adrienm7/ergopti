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
| Cyanophage optimiser      | https://github.com/cyanophage/cyanophage.github.io (no licence file)                    | b02780b (2026-06)  |

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
- **Not found:** « Pinelyzer », playground.colemak.com. a200 was found later
  (ClemenPine's final variant in https://github.com/Waterdragen/akl-ws,
  GPL-3.0) and is reproduced (docs/design/analyser-scores.md).

### Found by the search of 2026-11-19

A second search (GitHub API and repository metadata, crates.io, npm, web
search; Reddit could not be searched from the session, so a tool known only
there may be missing) found these. Licence is the repository's licence file;
« none » means none is published (all rights reserved). Activity is the last
push.

| Tool                                                                                                     | Licence, language, activity     | What it measures                                                                                                                                                                                                                                                                                                                                                                            | Score                                                                                          |
| -------------------------------------------------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| **Cyanophage playground and optimiser**, https://cyanophage.github.io, `cyanophage/cyanophage.github.io` | none, JavaScript, 2026-06       | Playground: SFB and SFB of two rows, SFS, LSB, scissors, wide and pinky–ring scissors, pinky off home, finger, row and column use, travel distance, trigram classes (alternation, rolls, redirects, weak redirects), same-hand runs; word lists in 15 languages (French included). Optimiser: the eleven terms of its score.                                                                | Optimiser only: `Σ max(0, (metric − floor) · weight)`, lower is better. **Reproduced, exact.** |
| **Alt Alpha Ranker**, altalpha.timvink.nl, `timvink/alt_alpha_ranker`                                    | none, 2026-11                   | Cyanophage's figures (SFB, SFS, LSB, scissors, inward rolls, alternation, redirects, pinky) of many layouts.                                                                                                                                                                                                                                                                                | Each metric normalised against QWERTY, `100 · Σ w·norm / Σ w`, presets.                        |
| **LayerBench**, https://layerbench.github.io, `rafaelromao/layerbench`                                   | MIT, TypeScript, 2026-11, web   | Simulates ZMK keymaps (layers, combos, adaptive and repeat keys, caps word); the Keyboard Layouts Doc metrics plus effort (cyanophage's key costs and thumbs).                                                                                                                                                                                                                              | Two numbers, effort and SFB.                                                                   |
| **keycraft**, `rbscholtus/keycraft`                                                                      | BSD-3-Clause, Go, 2026-11       | 29 metrics after the Keyboard Layouts Doc; Shai, MonkeyRacer and AKL corpora.                                                                                                                                                                                                                                                                                                               | Weighted sum after robust scaling (median, interquartile range) over its own layout set.       |
| **shirolyzer**, `akai-hana/shirolyzer`                                                                   | none, Rust, 2026-11, CLI        | Analyser and generator with context-dependent alternative fingering, YAML geometry, preference tiers for rolls, redirects and scissors; Shai and Douglas corpora.                                                                                                                                                                                                                           | A score with « primary sacrifice » limits.                                                     |
| **GULAG**, `RusDoomer/GULAG` (and its Nim port **kblag**, `greenm01/kblag`, MIT)                         | GPL-3.0, C/OpenCL, 2026-10      | GPU analyse, compare, rank, generate; mono-, bi-, tri-, quad- and skipgrams.                                                                                                                                                                                                                                                                                                                | Weighted sum from a weights file.                                                              |
| **Oxeylyzer 2**, https://o2.oxey.dev                                                                     | none, Rust/web, 2026-03         | The Oxeylyzer model on the web; its trigram weights are not used in its score yet. Oxeylyzer 1 now ships a Tauri desktop app (already reproduced).                                                                                                                                                                                                                                          | As Oxeylyzer.                                                                                  |
| **perky**, `csmclaren/perky` (crates.io)                                                                 | MIT, Rust, 2025-09, CLI         | Exhaustive evaluation by permutation over n-gram tables; many metrics, sort and filter, JSON output.                                                                                                                                                                                                                                                                                        | None (multi-key sort).                                                                         |
| **klayan**, `Lysquid/klayan`                                                                             | MIT, Rust, 2025-08, CLI         | A port of the Ergo-L analyser with nested dead keys, on Kalamine layouts and corpus files.                                                                                                                                                                                                                                                                                                  | None, as Ergo-L.                                                                               |
| **keyboard-layout-battles**, `malfple/keyboard-layout-battles`                                           | MIT, Rust, 2025-11, web         | Human comparisons of two layouts.                                                                                                                                                                                                                                                                                                                                                           | Elo rating, not computed from metrics.                                                         |
| **AdNW `opt`** (Andreas Wettstein), http://509.ch/opt.htm, mirror `christophkroeppl/opt`                 | BSD-2-Clause, C, mirror 2026-09 | The weighted-cost optimiser behind AdNW and KOY.                                                                                                                                                                                                                                                                                                                                            | Weighted cost.                                                                                 |
| **evolve-keyboard-layout** (ArneBab), hg.sr.ht/~arnebab/evolve-keyboard-layout                           | **unverified**, Python          | Neo community optimiser, ancestor of Keyboard Layout Optimizer.                                                                                                                                                                                                                                                                                                                             | Weighted cost.                                                                                 |
| **SteveP's keyboard-layout-analysis-tool**, `stevep99/keyboard-layout-analysis-tool`                     | none, Kotlin, 2024-01           | The engine of colemakmods.github.io/mod-dh/analyze.html: key effort against frequency, SFB and awkward-bigram penalties (section 8, « Colemak Mod-DH site »).                                                                                                                                                                                                                               | Effort.                                                                                        |
| **chogalyzer**, `Lenchog/chogalyzer`                                                                     | none, Rust, 2026-06             | Analyser and generator with magic-key rules; no documentation.                                                                                                                                                                                                                                                                                                                              | **unverified**                                                                                 |
| Smaller or dormant                                                                                       |                                 | keyboard-genetics (`kaievns`, the optimiser behind Halmak, 2016), yak-layout (`wincent`, MIT), keyrita-core (`kayoscode`), d3dat/keyboard-layout-analyzer (MIT, Russian), keynergy / kcli (dormant since 2022), bclnr/kb-layout-evaluation (MIT), matey-jack/keylayout-eval (MIT), kanalyzer, ergoanalyzer, a Vue remake of KLA, Thai, pinyin and Russian tools built on dariogoetz, klopt. | —                                                                                              |

Corrections to the entries above: Keysolve's live repositories are
`GalileoBlues/keysolve-web` (GPL-3.0) and `GalileoBlues/Keysolve2` (a mirror
kept with permission, no licence); Halmak is `kaievns/halmak` (MIT); keygen,
km_metrics and SteveP's KLA fork publish no licence file. No trace was found of
« Pinelyzer », rulyzer, optimak, kloak, KLAtest, Oxidizer, mana, a genkey port
in Rust, or an analyser on Getreuer's site or on layouts.wiki (guides only).

Of these, the Cyanophage optimiser is now reproduced (it has a single score,
a public formula and word lists in French). keycraft could not be built here
(no Go toolchain on this PC) and its score is relative to its own layout set;
shirolyzer's score is undocumented and changes every week: both are TODO, with
a recommendation in section 10.

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
| Layout library                       | 107                | many     | 22                | 30     | 815       | 4 121 | some       | 165                |

### Fidelity of the reproductions shown in the Studio

The Studio shows each analyser's own score beside Ergopti's
(docs/design/analyser-scores.md, `analyser_scores.js`). Each was checked
against the real tool, run locally on our texts (`node
tools/dev/verify-analyser-scores.cjs`, maintainer tool; the texts are the
shippable ones of `static/corpus`: _Alice_, _Sherlock Holmes_, 20 English
Wikipedia articles, the Python source of rich, _Germinal_; no third-party
corpus is stored). A gap is ours minus the tool's, in the tool's own unit;
« before » is the reproduction before the fix of that date. A tolerance is
never chosen: it is the tool's printed rounding, the floating point of two
summation orders, or the named approximation.

| Analyser (how checked)                                                                       | Points    | Metric                                                                      | Mean gap                                                 | Largest gap                       | Source of the gap left                                                                                                  |
| -------------------------------------------------------------------------------------------- | --------- | --------------------------------------------------------------------------- | -------------------------------------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| KLA (its own `analyzer.js`, run on the same texts in an earlier session)                     | 5 vectors | score (parts not printed)                                                   | < 5e-5 (1e-9 on `the`)                                   | < 5e-5                            | its 4-decimal print                                                                                                     |
| SteveP's KLA (its own code)                                                                  | 5 vectors | score                                                                       | < 5e-5                                                   | < 5e-5                            | 4-decimal print                                                                                                         |
| KLAnext (its site, closed source; 14 presets × 9 layouts)                                    | 126       | Overall / Distance / Same Finger / Same Hand                                | 0.0024 / 0.0022 / 0.0024 / 0.0027                        | 0.005 each                        | its 2-decimal print, with its own layout files; with our library's layouts (other keys for brackets): 0.18 % on Overall |
| Oxeylyzer (its REPL, 5a85ca0; 4 texts × 18 layouts)                                          | 72        | Score                                                                       | 0.0032 (0.0044 before 2026-11-19)                        | 0.012                             | skip-2/3 grams taken as skip-1; its truncated saved counts depend on bits of a total the chain only estimates           |
|                                                                                              |           | SFB / finger speed / stretches (points of its %)                            | 0.003 / 0.03 / 0.04 (0.007 / 0.04 / 0.08 before)         | 0.010 / 0.08 / 0.15               | as above                                                                                                                |
|                                                                                              |           | inrolls / outrolls / alternates / redirects / bad redirects                 | 0.07 / 0.07 / 0.09 / 0.02 / 0.002                        | 0.19 / 0.21 / 0.29 / 0.06 / 0.015 | the truncation above (code text: 73 % of its trigrams lose a count at its total)                                        |
| genkey (its build, f1f4173; 5 texts × 28 layouts)                                            | 140       | Score                                                                       | 1.3 % (1.4 % before 2026-11-19, 5.5 % before 2026-11-18) | 8.3 % (9.9 %)                     | skipgrams of gap 2 to 9 carried by the trigrams' chain (exact skipgrams give its output to 9 decimals)                  |
|                                                                                              |           | finger speed per finger                                                     | 0.05–0.11                                                | 1.6 (pinkies)                     | same                                                                                                                    |
|                                                                                              |           | index use / SFB / LSB (points)                                              | 0.02 / 0.0002 / 0.002 (index 0.05, max 2.4 before)       | 0.05 / 0.0005 / 0.005             | its printed rounding (1, 3 and 2 decimals)                                                                              |
| keygen (its build, 37ae949; 5 texts × 17 layouts; 4 short texts to 1e-9 in the gate)         | 85        | penalty per character (it prints no part)                                   | 0.11 % (its layouts), 0.09 % (ours)                      | 0.34 %                            | its four-key runs estimated from trigrams                                                                               |
| carpalx (Perl 0.12, its `carpalx.conf`; 5 texts × 10 keyboards)                              | 50        | effort / base / penalty / path                                              | 0.007 / 0.003 / 0.003 / 0.002 (0.31 % on effort)         | 0.028 / 0.007 / 0.027 / 0.008     | letter triads across a deleted run, carried by the trigrams' chain                                                      |
| Keyboard Layout Optimizer (its `evaluate`, 8c8ec9f; 5 texts × 8 layouts)                     | 40        | total cost and each of its 12 weighted metrics                              | < 1e-9                                                   | < 1e-9                            | floating point                                                                                                          |
| cmini (its `util/analyzer.py`; 5 texts × 13 layouts)                                         | 65        | SFB, alternation, rolls, one-hands, redirects, bad redirects, SFS, hand use | < 1e-14                                                  | 7e-15                             | floating point                                                                                                          |
| a200 (its `src/analyzer.py`, AVG mode; 5 texts × 10 layouts)                                 | 50        | its 16 statistics                                                           | < 1e-14                                                  | 1.4e-14                           | floating point                                                                                                          |
| Ergo-L analyser and Kalamine statistics (its own `layout-analyzer.js` on its en+fr tables)   | 2 vectors | SFB, SKB, LSB, scissors, rolls, SFS, SKS, redirects, finger and hand load   | < 1e-6 (Ergo-L), < 1e-4 (QWERTY)                         | 0.001 (load)                      | its 6- and 4-decimal output; its rounded tables sum to slightly less than 100                                           |
| **Cyanophage optimiser** (its own `optimiser.js` and `worker.js`; 6 word lists × 10 layouts) | 60        | score                                                                       | 0.79 %                                                   | 3.7 % (code)                      | a slip of its worker (a bigram with a character the layout lacks reads the previous bigram's key); without it 1e-9      |
|                                                                                              |           | SFB, pSFB, rSFB, pinky–ring scissors, SFS, effort, vowels, hand balance     | < 1e-9                                                   | < 1e-9                            | floating point                                                                                                          |
|                                                                                              |           | scissors / wide scissors / LSB (points of its %)                            | 0.09 / 0.09 / 0.21                                       | 0.55 / 0.73 / 1.10                | the same slip                                                                                                           |

Kalamine's statistics are the Ergo-L analyser's code (section 4); its Python
package computes none, so the Ergo-L check covers both. Not reproduced:
keycraft (Go, its score scales each metric against its own layout set: no Go
toolchain here), shirolyzer (undocumented score), LayerBench (ZMK keymap
simulation, two numbers), Keysolve 2 and trialyzer (no score of their own,
section 8 and docs/design/analyser-scores.md « Not covered »).

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

### Where Ergopti does better, tool by tool

- **KLA**: speed (115 layouts in about 0.3 s from cached tables instead of a
  simulation of the whole text per layout), dead keys, AltGr layers, skipgrams,
  scissors, lateral stretches, rolls and redirects (KLA has none), a score that
  rewards rolls instead of penalising every same-hand press, French corpora, and
  the installable layout (the editor compiles it for Windows, macOS and Linux).
- **KLAnext**: instant ranking (KLAnext re-reads the corpus for every selected
  layout), open source, the score's every contribution shown and every weight
  editable, lateral stretches, scissors and finger load in the score (KLAnext
  ignores them), the user's own text analysed in the page and, in the app, the
  user's own typing; and again the generated installable layout, where KLAnext
  only produces JSON.
- **Ergo-L analyser and Kalamine**: any text (Ergo-L offers two books), capitals,
  digits, Shift and AltGr counted (Ergo-L lower-cases the corpus and drops
  digits), a real fingering per keyboard (ISO, ANSI, ortholinear, angle mod;
  Ergo-L's geometry selector changes only the drawing), the distance metric,
  3-key rolls and alternation (computed but hidden there), adjacency-based LSB
  and scissor definitions, unsupported characters kept out of the shares instead
  of diluting them, a global score for those who want one beside every raw
  metric, and a layout source without Kalamine's six-level and one-custom-dead-key
  limits.
- **genkey, Oxeylyzer, cmini, Keysolve**: every layer and dead key (they measure
  the 30-key base layer only), French and accented text, Shift and AltGr cost,
  coverage and compact-keyboard fitness, shortcut placement, in the browser and
  in the app with no install; Oxeylyzer's and genkey's distance-weighted finger
  speed is the one model this engine does not reproduce in its own score (it
  reports SFB and distance separately; the Studio shows genkey's and
  Oxeylyzer's own scores beside it).
- **dariogoetz's optimiser**: the same layer and modifier coverage, with far
  fewer and documented weights, each contribution shown; no optimiser yet (a
  possible next step: swap search on the same engine).

### Ideas from the other analysers that our score lacks (2026-11-19)

Read while reproducing each tool exactly. None is in Ergopti's score yet: each
adds a metric (the Comparer lists its metrics by id, in `comparer_page.js`,
which another work stream owns) or moves the default weights, which section 11
leaves to the maintainer. Each is a TODO item with this recommendation.

1. **Distance-weighted same-finger cost** (genkey's finger speed, Oxeylyzer's
   SFB × distance × 5.5 / finger weight, Keyboard Layout Optimizer's
   `finger_repeats`, all three exact in the Studio). Ergopti counts an SFB
   the same whether the finger moves one row or two, and from home or not.
   **Recommended**: an `sfb_distance` metric, Σ (SFB + 0.5 · SFS) · key
   distance in mm / finger strength (the engine already has both), shown
   beside `sfb`; move part of `sfb`'s weight to it once the maintainer has
   compared the two rankings. The clearest win of the list.
2. **Finger-specific SFB weight** (Cyanophage's extra 0.7 for pinky and 0.3
   for ring SFBs, Oxeylyzer's finger weights). A pinky SFB is worse than an
   index one. Recommended inside item 1 (the finger strength term), not as a
   separate metric.
3. **Pinky–ring bigrams on any row difference** (Cyanophage's PRScissor,
   Oxeylyzer's pinky_ring_bigrams, keygen's pinky–ring twist). Ergopti's half
   scissors count only the one-row jumps where the longer finger is lower.
   Recommended as a statistic first (no weight), to see whether it ranks
   layouts differently from `half_scissors`.
4. **Floors per term** (Cyanophage: an SFB share under 0.3 %, a hand imbalance
   under 1 point cost nothing). It keeps tiny differences between good layouts
   from deciding the rank. Recommended as an optional floor per weight in
   `score_weights.json`, default 0 (today's behaviour), shown in the score
   settings.
5. **Scores relative to a reference** (keycraft: each metric scaled by the
   median and interquartile range of its layout set; Alt Alpha Ranker: each
   metric against QWERTY). It makes weights comparable across metrics of
   different spreads. Recommended as a second view of the ranking (« relative
   to QWERTY »), not a replacement of the weights.
6. **Longer skipgrams with a decay** (genkey: gaps 1 to 9 weighted 1/2^(g−1);
   Oxeylyzer: gaps 1 to 3 weighted (1/7)^g). Ergopti's SFS is gap 1 only. It
   needs skipgram tables in the corpus format (the engine has uni-, bi- and
   trigrams), which would also make genkey's and Oxeylyzer's scores exact.
   Recommended once the corpus format is next revised.
7. **Rejected**: Cyanophage's « vowels on one hand » (a design preference, not
   a cost), carpalx's and Cyanophage's drop of rare triads (it discards data
   to save time the tables do not need), KLA's per-press same-hand penalty
   (it penalises rolls).

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
| altgr_usage      |      2 | The AltGr layer on top of modifier_usage (2.5 in all): a thumb chord, as dear as a dead key (agent, 2026-11-18).                                      |
| dead_key_usage   |      2 | The extra press of a dead-key sequence, above an off-centre direct key, below an SFB (agent, 2026-11-18; was 0.5).                                    |
| outer_column     |      1 | Maintainer: the 7th right-hand column is penalised twice (distance and compact fitness), and shown on its own.                                        |
| unsupported      |      5 | A character the layout cannot type removes its n-grams from every other metric, which would flatter the layout; Ergo-L warns at 0.5 %.                |
| compact_fit      |    0.1 | Maintainer requirement; 1 point per 10 % of characters lost on a compact board.                                                                       |
| char_coverage    |    0.1 | Maintainer requirement (Bépo and Optimot gain); 1 point per 10 % of the reference set.                                                                |
| direct_digits    |   0.03 | Maintainer: « a small bonus »: 3 points for ten direct digits.                                                                                        |
| shortcut_left    |   0.15 | Maintainer: about 5–10 % of the score; with the A–Z table (section 17), 5.6–5.7 % of Ergopti's absolute contributions in French, 5.1 % in English.    |

These weights are **decided by the agent, to review by the maintainer**. The
Studio lets every user change each weight and restore the defaults; the score
of every layout is recomputed without re-analysing (`LAYOUT_ANALYSIS.rescore`).

## 12. First results

Measured with the engine on an ISO board, the whole library (115 layouts) in
about 0.3 s per corpus. French: `static/corpus/original/fr/corpus_nemolivier.txt`
(2.5 MB); English: `static/corpus/original/en/don_quixote_ormsby.txt`
(2.2 MB; it replaced a synthetic text deleted with the corpora of unknown
licence). A layout of the imported library has only its alphabetic block (no
accents): its `unsupported` share shows what it cannot type. The keys
outside the block keep QWERTY's characters the block did not place, and the
QWERTY characters the block displaced (Dvorak's / and ?) take the free cells
of those keys, then of the number row; what finds no cell stays unsupported.

French corpus (best eight and the reference layouts), with the model of
2026-11-14 (space bar on the left thumb, sections 16 and 17):

| Rank | Layout        | Score |  SFB |  SFS |  LSB | Scissors | Bad redirects | Inward rolls | Alternation | Home row | mm/char | Unsupported |
| ---: | ------------- | ----: | ---: | ---: | ---: | -------: | ------------: | -----------: | ----------: | -------: | ------: | ----------: |
|    1 | Ergopti+ ANSI |  20.7 | 0.94 | 6.24 | 1.17 |     0.31 |          0.41 |        14.78 |       40.13 |    66.55 |     8.8 |        0.00 |
|    2 | Ergopti+      |  19.0 | 0.98 | 6.21 | 1.29 |     0.24 |          0.42 |        14.70 |       40.13 |    65.51 |     8.9 |        0.00 |
|    3 | beo           |  18.2 | 0.77 | 5.48 | 1.57 |     0.90 |          0.68 |        13.26 |       39.69 |    63.95 |     7.4 |        0.73 |
|    4 | Ergopti       |  17.0 | 1.33 | 6.45 | 1.15 |     0.24 |          0.38 |        14.78 |       39.92 |    65.58 |     8.3 |        0.00 |
|    5 | Ergopti ANSI  |  16.5 | 1.33 | 6.45 | 1.15 |     0.32 |          0.38 |        14.78 |       39.92 |    66.20 |     8.4 |        0.00 |
|    6 | Optimot       |  10.2 | 1.07 | 6.80 | 1.89 |     0.18 |          0.42 |        15.19 |       40.80 |    66.39 |     7.3 |        0.85 |
|    7 | Ergo-L        |   8.0 | 1.79 | 6.09 | 1.46 |     0.18 |          1.89 |        19.63 |       28.97 |    70.15 |     8.1 |        0.01 |
|    8 | Hands Down    |   6.0 | 1.17 | 4.93 | 1.42 |     0.96 |          0.52 |        14.88 |       36.42 |    64.64 |     7.3 |        2.21 |
|   11 | bépo          |  −9.7 | 2.88 | 7.72 | 0.85 |     0.08 |          0.68 |        15.65 |       38.91 |    71.18 |     8.9 |        0.00 |
|  109 | AZERTY (FR)   | −90.5 | 7.60 | 7.97 | 4.40 |     1.47 |          1.03 |        18.07 |       28.00 |    23.77 |    15.3 |        0.04 |
|  110 | QWERTY (US)   | −94.4 | 7.40 | 8.70 | 5.33 |     0.54 |          1.06 |        17.14 |       29.18 |    29.80 |    13.6 |        2.21 |

English corpus (_Don Quixote_, Ormsby, 2.2 MB): APTv3 and APT (24.9), Maya,
Graphite, Nerbs, Gallium Colstag, Gallium and Noctum lead; Ergopti+ 11.3
(53rd), Ergo-L −1.3, Dvorak −3.8, Colemak-DH −4.8, Bépo −24.5, QWERTY −86.5,
AZERTY −91.2. The SFB of QWERTY (5.8 %), Colemak-DH (1.7 %) and Dvorak (2.7 %)
are of the order the Keyboard Layouts Doc gives (QWERTY ~6 %, Dvorak 2.5 %,
Colemak 1.5 %).

## 13. Layout library

`static/ergopti_plus/_shared/layouts/data/analysis/layout_library.json` holds
104 alphabetic blocks: 72 from the Oxeylyzer layout set (Apache-2.0
repository; the `data-files` branch has no licence file of its own) and, for 32
classics that set lacks (Graphite, Minimak, Asset, Capewell, BEAKL, Hands Down
Neu…), from cmini (GPL-3.0 repository, user-submitted data; the Discord user
ids were not imported); cmini's APT, Gallium and Hands Down Reference were
dropped on 2026-11-17 as the same keys as Oxeylyzer's APTv3, Gallium Colstag
and Hands Down. It also holds 53 whole layouts (every key and level) from
Keyboard Layout Analyzer's 107 built-in files (MIT repository,
patorjk/keyboard-layout-analyzer at c4f2f9bb43), re-encoded through the
Studio's KLA reader by `tools/build/import-kla-layouts.cjs`: 35 files repeat a
layout already there, 16 have characters on keys the library's keyboards have
no code for (12 ErgoDox files, TypeMatrix, AOEYK, the full Arensito and the
ANSI copy of BvoFRak 1.0, whose ISO copy is imported), one places letters
twice (Ina) and two
are left out by judgement (an older Neo 2 file without umlauts, a second copy
of Programmer Dvorak); `not_imported` lists each with its reason. The codegen
adds the six registry layouts and the reference QWERTY and AZERTY with all
their layers and dead keys: 165 layouts. Each entry names its `source` and
`source_path`.

On 2026-11-18 eleven entries were re-encoded from their official files, every
key, level and two-key dead-key composition compared by a script: Optimot from
optimot.fr's 1.8.0 Linux driver (XKB and XCompose; CC BY-NC-SA, so only the
arrangement is re-encoded); Neo 2, Bone, KOY, AdNW, Noted, German QWERTZ, the
Spanish QWERTY and the Spanish Dvorak from xkeyboard-config's `symbols/de` and
`symbols/es` (f4d3ed8b) with the libX11 en_US.UTF-8 Compose table (and
dl.neo-layout.org's XCompose for the Neo family); Mine from
dl.neo-layout.org/mine_2.39 (the library held its block from before April
2022); Engram-es from its README in the Engram repository. These entries state
their dead keys as cells and their compositions as `dead_rules`; sequences of
three keys or more are left out, and the Neo family keeps its levels 1, 2, 3 and
5 (Mod3 as AltGr) without level 4. KLA's AdNW became a duplicate of the official
one. Ergo-L and bépo already matched their official files (the Kalamine TOML of
ergol-v1.0.2; bépo 1.1rc2's KLC and XKB). BEO and Morgenstern have no official
source that could be found and stay letter blocks.

On 2026-11-19 the library took more collections (section 13 of
`tools/test/test-layout-analysis-engine.cjs` holds their key cells, a count
that may only grow and a checked credit for each):

- **Hands Down** (R. Alan Reiser, github.com/moutis/HandsDown at e8f532f62c,
  GPL-3.0, read through the Studio's KLA reader): Alt, Extreme, XKCD and
  Reiser's Hands On, Heads Up and Notarise, and the « sym » (angle) files of
  Alt, Polyglot, Reference and Hands On, ten layouts. Its Reference is
  Oxeylyzer's `hands_down`. Every thumb-alpha variant (Gold T, Silver N,
  Bronze H, Platinum L, Titanium, Rhodium, Promethium, Mithril, Unobtanium and
  the Vibranium files R, Chromium and Cesium C, Dash and Alt-ex E, Alt-tx T,
  Alt-nx N, Élan . and ,) is left out: the author's site states « Thumbs up
  variations require dedicated thumb keys », and the model's only typing
  thumb key is the space bar. Adding one (AltLeft) would change the typing
  area of the optimizer, the KLA export and every board geometry, so it was
  not done here. The matrix, ortho and ErgoDox copies that put letters on
  combos or outer columns, and Neu's JIS and ErgoDox files, are listed with
  their reason; Neu stays cmini's.
- **KLAnext** (klanext.keyboard-design.com, version 0.06; no licence
  published, user-submitted files): its `db.js` lists 723 layout files, of
  which 711 answered (read as data, never run, through the Studio's KLA
  reader). 434 layouts are new (430 English, Navarre's 1907 and 2023 French
  layouts, two Dutch); the files' own fingers put 66 of them on the angle
  fingering (ring and middle on the first bottom keys). 142 repeat a library
  layout, the others place letters off the library's keys or on two keys, or
  could not be read; `not_imported` lists each. Its ISO QWERTY, whose N and
  M are swapped, is left out by judgement. Each is credited to the author its
  file names (basis « collection »); its corpus texts are not stored.
- **bépo and the French layouts of xkeyboard-config** (`symbols/fr` at
  f4d3ed8b, MIT, read with the libX11 Compose table as on 2026-11-18): the
  AFNOR AZERTY (NF Z71-300), the legacy fr-latin9 AZERTY, the Macintosh and
  US-symbol AZERTYs, the French US with dead keys, Francis Leboutte's
  Dvorak-fr (X11 licence in the file; the debian-legal thread above is about
  this layout, to review by the maintainer) and the ISO (angle) Ergo-L, whose
  1DK the XKB file types through ISO_Level5 and is taken from the registry's
  Ergo-L (its ë, 1DK twice, is a chain the library cannot state). bépo 1.0rc2
  (`bepo`, and `bepo_latin9` restricted to Latin-9), bépo AFNOR (`bepo_afnor`) share the registry
  bépo 1.1rc2's letters and digits and differ only on other levels, so the
  shared duplicate rule holds them once; the AZERTY variants (oss, olpc,
  Occitan) are AZERTY's letters. Breton is left out: its c'h and ch keys are
  keysyms without a Unicode value. No ergonomic-board bépo (TypeMatrix,
  ErgoDox) fits the library's keyboards. BvoFRak was already held (KLA).

**Basis for re-encoding** (TODO « Read every common layout format »): the
maintainer recalls a public discussion holding that a key arrangement is not
protected by copyright, only its implementation, and points to _SAS Institute
v World Programming_. The sources below were found by a web search on
2026-11-14; the session could not open the pages themselves, so each is graded
and must be re-read before it is quoted elsewhere. **Not legal advice.**

| Source                                                                                                                                                                                                    | What it says                                                                                                                                                                                                                                                                                                                                        | Weight for a layout                                                                                                                  |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| debian-legal thread « The copyright of a keyboard mapping and its implementation » (Josselin Mouette, March 2009), https://lists.debian.org/debian-legal/2009/03/msg00053.html and replies msg00054–00069 | About Francis Leboutte's French Dvorak: Mouette argues that under European law copyright on a mapping does not reach an independent implementation; one reply finds a mapping « doesn't appear to be covered by copyright »; another advises caution. The likeliest match for the discussion the maintainer recalls (seen through search snippets). | Opinions, not authority; shows the doubt is old and real.                                                                            |
| freedesktop bug 15407 (2008), https://bugs.freedesktop.org/show_bug.cgi?id=15407                                                                                                                          | The same dispute in xkeyboard-config: the author claims an original work, the packager answers that layouts are not subject to copyright.                                                                                                                                                                                                           | A real case of an author asserting rights.                                                                                           |
| CJEU, C-406/10, _SAS Institute v World Programming_, Grand Chamber, 2 May 2012, ECLI:EU:C:2012:259                                                                                                        | The functionality of a program, its programming language and its data file formats are not a form of expression protected by the Software Directive; protecting them would monopolise ideas. It leaves open protection of other material as a work if it is its author's own intellectual creation.                                                 | Limits protection of the implementation side; does not settle whether a layout is itself a « work ».                                 |
| Database Directive 96/9/EC, art. 7; CJEU C-203/02 _British Horseracing Board v William Hill_ (9 November 2004)                                                                                            | The sui generis right needs a substantial investment in obtaining, verifying or presenting contents, not in creating them.                                                                                                                                                                                                                          | A single layout is no database; copying a whole collection wholesale is the residual risk, hence one arrangement at a time.          |
| 17 U.S.C. §102(b); _Lotus v. Borland_, 49 F.3d 807 (1st Cir. 1995)                                                                                                                                        | No protection for a « system » or « method of operation »; a menu command hierarchy is an uncopyrightable method of operation.                                                                                                                                                                                                                      | Strong analogy in the United States, binding in one circuit.                                                                         |
| US Copyright Office Review Board, « AEIOU Keyboard » (30 November 2017), https://www.copyright.gov/rulings-filings/review-board/docs/aeiou.pdf                                                            | Registration of a key arrangement refused for lack of « the authorship necessary to support copyright claims ».                                                                                                                                                                                                                                     | The most direct statement found; an agency decision, not a court ruling.                                                             |
| Project statements                                                                                                                                                                                        | Bépo is distributed under CC-BY-SA and GFDL (Ergodis leaflet, 2014); the Dvorak patent US 2,040,248 (1936) has long expired; Colemak is described as public domain by secondary sources only; Workman states no licence for the layout; Kalamine's MIT licence covers the tool, not the layouts.                                                    | The projects license their files; none shows a right over the arrangement. Crediting authors and naming their licence costs nothing. |

Limits: no court has ruled on a keyboard layout as such; an author could argue
in the European Union that an arrangement is an original creation; the layout's
name can be a trademark. The library therefore:

- re-encodes each arrangement in Ergopti's own format (what each key types, by
  KeyboardEvent.code), never copies a file of another tool;
- takes only the arrangement (no comment, no metadata, and no Discord user id
  from cmini);
- names the source file of every layout (`source`, `source_path`), the
  layout's name and its authors (`layout_credits.json`: read on the author's
  own page where one was found, else as the collection's file states them);
- removes a layout on a credible request from its author.

A further step can complete the French library layouts (Optimot, Béopy, the
Ergo-L variants…) with their real layers and dead keys by adding them to the
registry.

## 14. Layout file formats in use

The Studio's importers (TODO « Read every common layout format ») meet these
formats; each maps to the engine's rows (base, Shift, AltGr, Shift+AltGr and
dead keys per physical key).

| Format                  | Used by                                 | Content                                                                                      | Maps to the Ergopti source                          |
| ----------------------- | --------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| KLA JSON                | KLA, SteveP's KLA, KLAtest, KLAnext     | `label`, `author`, `fingerStart`, `keyboardType`, `keys[]` with four char codes and a finger | four layers by key index of the board; no dead keys |
| Kalamine TOML / YAML    | Kalamine, Ergo-L and its family         | ASCII-art `base` / `altgr` / `full` blocks, 1dk, 20 named dead keys                          | layers by XKB key name; dead-key tables             |
| Kalamine JSON           | x-keyboard, ergol.org                   | `keymap` (code → 2–4 strings), `deadkeys`                                                    | direct (KeyboardEvent.code)                         |
| DOF JSON                | Oxeylyzer                               | `layers.main` rows of characters, `board`, `fingering`, optional geometry                    | base layer only                                     |
| cmini JSON              | cmini, Keysolve                         | `keys: {char: {row, col, finger}}`, `board`                                                  | base layer only                                     |
| genkey / trialyzer text | genkey, trialyzer                       | three rows of characters (and a finger map)                                                  | base layer only                                     |
| macOS `.keylayout`      | Ergopti registry, Ukelele, Kalamine     | XML key maps per modifier set, actions and states                                            | already read (`layout_composer`)                    |
| XKB symbols             | Linux, Kalamine, Ergopti's XKB export   | `key <AC01> { [ a, A, ae, AE ] }`, `dead_*` keysyms                                          | four levels; dead keys through Compose              |
| KLC                     | MSKLC, KbdEdit, Kalamine, Ergopti's KLC | per scan code columns, `DEADKEY` tables                                                      | four columns; dead-key tables                       |

## 15. Decided by the agent, to review by the maintainer

Settled by the maintainer on 2026-11-14:

- Digit6 is typed by the right index.
- The space bar is typed by the **left** thumb (AltGr stays on the right
  thumb). Thumbs are left out of every bigram and trigram metric, so this only
  moves load between the two thumbs.
- The default weights stay as in section 11.
- The cmini layouts stay in the library, credited to their submitters.
- The credits recorded from knowledge (`basis: knowledge`) are shown, to be
  verified later.
- The ideal finger load and the shortcut table were changed as sections 16
  and 17 describe.

Still decided by the agent:

- The ISO key left of Z and Z are typed by the left pinky. An angle-mod layout
  of the library uses the angle fingering on an ISO board.
- The reference character set of `char_coverage` (ASCII, French letters and
  typography, a few European letters).
- The ease of each left-hand key for `shortcut_left` (`shortcut_key_ease`).

## 16. Ideal finger load

`finger_imbalance` compares each finger's share of the non-thumb presses with a
target, `ideal_finger_load` in `analysis_model.json`. The maintainer asked for
pinkies under 8 % (ideally 6–7 %) and the order index ≥ middle ≥ ring ≥ pinky
on each hand. Two of the studied tools publish a per-finger target or
strength; each is scaled to one hand's 50 %:

| Basis                                                               | Pinky | Ring | Middle | Index |
| ------------------------------------------------------------------- | ----: | ---: | -----: | ----: |
| dariogoetz `finger_balance` intended loads 1.0 / 1.6 / 2.0 / 2.0    |   7.6 | 12.1 |   15.2 |  15.2 |
| genkey finger speeds (KPS) 1.5 / 3.6 / 4.8 / 5.5                    |   4.9 | 11.7 |   15.6 |  17.9 |
| Mean of the two                                                     |   6.2 | 11.9 |   15.4 |  16.5 |
| **Ergopti default**: the mean rounded to 0.5, the hand kept at 50 % |   6.5 | 11.5 |   15.5 |  16.5 |

Oxeylyzer's finger weights (1.4 / 3.6 / 4.8 / 5.5, pinky to index) give almost
the same split as genkey's. Ergo-L's criterion 2 (spare the pinkies) gives no
number. The default pinky, 6.5 %, is inside the maintainer's range. The index
is the strongest finger in both sources but also covers two columns, so it
gets only 1 % more than the middle finger.

The codegen refuses a model that breaks the rule (a hand not at 50 %, a finger
above a stronger one, a pinky at 8 % or more). In the Studio, everyone can edit
the eight targets and restore the defaults. The engine takes them through
`analyse(…, {idealLoad})` and refuses targets that do not sum to 100 %.

## 17. Shortcut letters

`shortcut_left` rewards layouts that put the most used Ctrl/Cmd shortcuts on
easy left-hand keys, so the right hand can stay on the mouse. Every letter A–Z
has a usefulness from 1 to 10, `shortcut_letters` in `analysis_model.json`.
The scores are an editorial estimate: no published study counts shortcut use.
They are ordered by how universal each shortcut is across the vendor shortcut
lists cited in the Studio (Windows, macOS, Word, Google Docs, Chrome, VS Code).
Those pages could not be fetched from this session, so the citations are
marked « to verify ».

| Score | Letters       | Shortcuts                                                                                           |
| ----: | ------------- | --------------------------------------------------------------------------------------------------- |
|    10 | C, V, X, Z    | Copy, paste, cut, undo: the same in every application and system.                                   |
|     8 | A, S          | Select all, save.                                                                                   |
|     6 | F, Y, T, W    | Find; redo (Windows; Shift+Cmd+Z on macOS); new tab; close tab or window.                           |
|     5 | B, I, U       | Bold, italic, underline in every rich-text editor (the maintainer wants them on the left).          |
|     4 | K, N, O, P, R | Insert link / VS Code chord and command palette; new; open; print or quick open; reload.            |
|     3 | L, Q, H, D    | Address bar or select line; quit (macOS); replace (Windows) or hide (macOS); bookmark or duplicate. |
|     2 | E, G          | Search bar or centre; find next or go to line.                                                      |
|     1 | J, M          | Downloads or join lines; minimise.                                                                  |

With this table, Ergopti scores 53.8 %. It already has B, I and U on the left,
but S (save) and F (find) are on the right. The weight stays at 0.15: on the
French reference corpora `shortcut_left` is 5.6–5.7 % of Ergopti's absolute
contributions, and 5.1 % on English. Both are inside the maintainer's 5–10 %.

## 18. Corpus licences

On 2026-11-14 the maintainer asked for every corpus in `static/corpus` to be
usable in the analyser, with its attribution shown, and then set the rule:
keep only the texts whose licence is clearly compatible and recorded, and
delete the others. The register `static/corpus/register.json` keeps the
source, licence, attribution, status and evidence of each text, and the
codegen refuses to ship a text it does not clear.

| Status  | Texts                                                                                                                                                                                                                                                                                  |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ship    | _Don Quichotte_ (Furne), _Don Quixote_ (Ormsby), _Du côté de chez Swann_, the Nemolivier anthology (public domain); _Autonomie_ (CC BY-SA 1.0); the two Hello World files (MIT); the two Leipzig samples (CC BY 4.0, the maintainer's choice)                                          |
| added   | Subtitle word frequencies in five languages (FrequencyWords, CC BY-SA 4.0); JavaScript (lodash), Python (rich) and Rust (ripgrep) code, all MIT; Hugo, Zola, Verne and Austen from Project Gutenberg (public domain); 30,000 Tatoeba sentences in French and in English (CC BY 2.0 FR) |
| refused | Marked for deletion by the maintainer: the 2003 e-mails, `romans.txt`, _Python for Everybody_, the GLM project, the eight KLAnext-style texts and Auxlang X                                                                                                                            |

Notes:

- _Autonomie_: the copy in the repository had lost every accent (9,945
  U+FFFD characters). It was re-imported from the ISO-8859-1 original in the
  bépo corpus archive. Its n-gram tables are shipped in their own file,
  marked CC BY-SA 1.0 with the required credit.
- The Hello World files are a 2004 snapshot of a collection placed under MIT
  in 2017.
- Leipzig: the maintainer chose CC BY 4.0. The licence page could not be read
  from the build container, and third parties cite recent releases as CC BY
  4.0 and older ones as CC BY-NC 4.0. The Wikipédia sample also credits
  Wikipédia's contributors.
- The e-mails come from the bépo corpus archive (source confirmed), but no
  licence is granted and they hold personal data.
- Leipzig's licence page could still not be read: wortschatz.uni-leipzig.de
  answers with an anti-bot challenge (Anubis) that asks automated clients to
  stay out, so the maintainer has to read it.
- KLAnext's « Copyright » section licenses « all images used and generated
  by this app » under CC BY 4.0, and says nothing of its corpus texts.
- Sources reachable from the build container on 2026-11-14 were
  raw.githubusercontent.com, gitlab.com, bepo.fr and storage.googleapis.com.
  The maintainer then opened gutenberg.org, Wikipedia, Wikisource, Tatoeba,
  Leipzig and KLAnext; norvig.com and lexique.org still did not answer. The Google Books Ngram files are reachable, but their
  one-gram shards (several GB per language) are too large to process here.
