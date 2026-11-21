<!-- docs/audits/layout-analysers/graded-costs-ranking.md -->

# Graded costs: the proposed scale and its ranking impact

Written on 2026-11-21 (Paris time) for the maintainer's decisions of the same
day (docs/memory/maintainer-decisions.md, « Layout score: graded costs »):
the Studio's single weights become graded costs, the alternation reward gets
a switch and same-hand runs a progressive scale; a starting scale is
proposed from the known analysers, every value is editable in the Comparer's
score settings, and the scale ships as the default once this report exists.
The engine side is specified in
[docs/design/layout-analysis.md](../../design/layout-analysis.md#graded-costs).
This is the second version of the report: the first read a « skipgram » as a
cross-hand trigram, which the maintainer corrected the same day (a same-hand
bigram on two fingers and different rows, now `row_jump`).

## The proposed scale

Each factor multiplies its metric's weight (`score_weights.json` « grades »).
No existing weight changes; `row_jump` weighs half of `sfb` (maintainer) and
`hand_run` is new.

| Metric              | Grade                                           |                   Value | Why                                                                                                                                                                                                                                                             |
| ------------------- | ----------------------------------------------- | ----------------------: | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sfb` (5)           | `same_row` / `one_row`                          |                   1 / 1 | A lateral move of the index or the pinky is 1 u, as long as a one-row move; one row is the reference.                                                                                                                                                           |
| `sfb`               | `two_rows`                                      |                       2 | With `sfb_distance` 0.26 on top, a two-row SFB (about 38 mm) costs 10 + 10 = 20 points per %, twice a one-row one (5 + 5 = 10): Oxeylyzer's linear distance gives twice too, genkey's quadratic `dy²` about four times; the flat model gave 1.5 times.          |
| `row_jump` (2.5)    | `adjacent` / `one_apart` / `index_pinky`        |           1 / 0.5 / 0.1 | The maintainer's order: adjacent fingers, then the 1st and 3rd fingers, index and pinky barely counted. Keysolve's half- and full-scissor bigrams and Cyanophage's scissors make adjacent fingers the worst stretch.                                            |
| `row_jump`          | `one_row` / `two_rows`                          |                 0.5 / 1 | Two rows cost more than one (maintainer); two rows on adjacent fingers keep half the SFB weight (2.5 per %, the earlier decision), one row half of that, so even the worst row jump (2.5) stays far under a one-row SFB (about 10).                             |
| `distance` (1)      | `index` / `middle` / `ring` / `pinky` / `thumb` | 1 / 1.1 / 1.3 / 1.7 / 1 | genkey's and Oxeylyzer's finger speeds (index 5.5, middle 4.8: 1.15); Cyanophage's ring and pinky factors (genkey and Oxeylyzer give 1.53 and 3.7, kept lower since `pinky_load` already weighs the pinkies' presses); a thumb travels little, from a rest key. |
| `alternation` (0.3) | `rewarded`                                      |                    true | The reward stays on, as before (maintainer: default on, the existing weight).                                                                                                                                                                                   |
| `hand_run` (0.1)    | `length_1` … `length_6`                         |        1, 1, 2, 3, 4, 5 | The maintainer's example: an alternation ×1, three same-hand keys ×2, four ×3. Two keys stay ×1: a two-key roll is rewarded by `roll_in` and `roll_out`, and every analyser counts it as good.                                                                  |
| `hand_run`          | `growth`                                        |                       1 | Linear beyond six keys, as in the maintainer's example: ten keys weigh 9.                                                                                                                                                                                       |

`hand_run` 0.1 point per %: its value spans 6 % (Ergopti+) to about 45 %
(AZERTY, QWERTY) on the default corpus, so it moves good layouts by a few
points; a text whose every keystroke weighs twice an alternation's (100 %)
loses 10 points, about a 1 % share of one-row SFBs. The Keyboard Layout
Optimizer penalises a trigram without a hand change (`no_handswitch_in_trigram`
400 against `finger_repeats` 780) and carpalx its hand runs, while Oxeylyzer
rewards one-hand trigrams that roll: the weight sits between them, and the
runs of three keys or fewer, which the roll metrics already rate, weigh little.

The flat model, the single weights of before 2026-11-21, is every factor at
1, the alternation rewarded and `row_jump` and `hand_run` at 0
(`LAYOUT_ANALYSIS.flatGrades()`). It gives the former scores to the last bit
(the engine test, section 16b, and the 783 layouts of `fr_don_quichotte`
compared with the engine of `bc92b83ce7`).

## Method

`node tools/dev/rank-graded-costs.cjs --all` ranks the 783 layouts of the
library twice on each corpus, on the Comparer's default board (ISO) and
format, each model in an engine whose defaults it is (so the ways of typing
follow it, as they do once shipped): the flat model, then the proposed scale
(before the switch, given with `--candidate=<file>`; after it, the shipped
defaults, so the command gives these tables again). The corpora are the
Comparer's default (`fr_don_quichotte`) and the largest French and English
texts of the other kinds (`fr_wikipedia_1m`, `en_don_quixote`,
`en_wikipedia_1m`). The sections below « Results » are its output, unedited.

## Summary

- The ranking keeps its shape: Spearman's rank correlation is 0.990 to 0.992
  on every corpus, and 20 to 29 of the flat top 30 stay in the graded top 30.
- Every score drops by about 24 points, most of it shared by every layout:
  the row jumps take about 16 points (one-row jumps on two fingers are
  frequent), same-hand runs 2.4 to 3.0, the two-row SFBs 2.6 to 2.9 and the
  finger travel 1.7 to 2.1 on average over the complete layouts. A score is
  read against another, so the common drop changes no comparison; the row
  jumps are the largest new term, and their weight is the first to review.
- Ergopti on the French corpora: Ergopti+ moves from 4th to 1st on
  `fr_don_quichotte` (Ergopti+ ANSI 5th to 3rd, Ergopti 7th and Ergopti ANSI
  8th unchanged) and from 6th to 4th on `fr_wikipedia_1m` (Ergopti 8th,
  unchanged). On the English corpora, Ergopti's layouts lose 4 to 18 places
  (around 225th and 235th).
- The largest moves: layouts with few row changes on two fingers or short
  same-hand runs climb (UCIEA, Workwoman, Hands On, BuTeck, Balance-12),
  layouts that keep a hand on long runs or change rows on adjacent fingers
  fall (RL Eai, 16 Maks, RTNA, Seht Drai, and Ergo-L on English, the
  « vacances » case).
- « vacances » on Ergo-L, typed by the left hand alone, weighs hundreds of %
  in `hand_run` where Ergopti's alternation weighs 0 (the engine test,
  section 16b).

## Results

### fr_don_quichotte

Spearman rank correlation 0.9905; 27 of the flat top 30 stay in the graded top 30.

Mean change of each graded metric's points over the 686 complete layouts: sfb -2.88, row_jump -16.47, distance -1.77, hand_run -2.94.

| Graded rank | Layout                         | Graded score | Flat rank | Flat score | Move |
| ----------: | ------------------------------ | -----------: | --------: | ---------: | :--: |
|           1 | Ergopti+                       |         -6.8 |         4 |        6.7 |  +3  |
|           2 | Erglace (JF)                   |         -7.1 |         1 |        8.4 |  −1  |
|           3 | Ergopti+ ANSI                  |         -7.9 |         5 |        5.7 |  +2  |
|           4 | Erglace                        |         -8.7 |         3 |        6.8 |  −1  |
|           5 | Erglace (Nuke)                 |         -9.8 |         6 |        5.6 |  +1  |
|           6 | Ergaie                         |        -10.5 |         2 |        7.3 |  −4  |
|           7 | Ergopti                        |        -11.4 |         7 |        2.7 |  =   |
|           8 | Ergopti ANSI                   |        -12.7 |         8 |        1.6 |  =   |
|           9 | Optimot                        |        -13.6 |        10 |       -1.0 |  +1  |
|          10 | BEO                            |        -15.7 |         9 |        1.3 |  −1  |
|          11 | Optimot (ErgoDox)              |        -19.1 |        15 |       -6.3 |  +4  |
|          12 | Béopy 1DFH                     |        -21.8 |        13 |       -6.1 |  +1  |
|          13 | BvoFRak 1.0 FR                 |        -23.6 |        16 |       -8.1 |  +3  |
|          14 | Ergo-L                         |        -25.3 |        11 |       -3.8 |  −3  |
|          15 | NSTR                           |        -25.3 |        17 |       -9.4 |  +2  |
|          16 | Ergo-L (ISO variant)           |        -25.3 |        12 |       -3.8 |  −4  |
|          17 | Hands Down Reference (ErgoDox) |        -29.7 |        20 |      -14.2 |  +3  |
|          18 | Hands Down Reference           |        -29.8 |        18 |      -11.9 |  =   |
|          19 | Colemak French Touch           |        -30.5 |        14 |       -6.1 |  −5  |
|          20 | Inrolly2                       |        -33.5 |        21 |      -15.8 |  +1  |
|          21 | Hiyou Satan                    |        -33.6 |        23 |      -17.6 |  +2  |
|          22 | Urts                           |        -33.9 |        19 |      -13.2 |  −3  |
|          23 | Hands Up                       |        -35.7 |        22 |      -16.7 |  −1  |
|          24 | Béopy                          |        -37.7 |        32 |      -24.2 |  +8  |
|          25 | HIEAMTSRN                      |        -38.3 |        35 |      -25.3 | +10  |
|          26 | Hiyou (KLAnext)                |        -40.2 |        24 |      -22.3 |  −2  |
|          27 | Pietergen 2                    |        -40.3 |        26 |      -22.4 |  −1  |
|          28 | Eureka Plus                    |        -41.3 |        25 |      -22.4 |  −3  |
|          29 | Balance Twelve                 |        -42.0 |        40 |      -27.5 | +11  |
|          30 | Embizone                       |        -42.2 |        30 |      -23.7 |  =   |

Ergopti's layouts:

| Layout        | Graded rank | Graded score | Flat rank | Flat score | Move |
| ------------- | ----------: | -----------: | --------: | ---------: | :--: |
| Ergopti+      |           1 |         -6.8 |         4 |        6.7 |  +3  |
| Ergopti+ ANSI |           3 |         -7.9 |         5 |        5.7 |  +2  |
| Ergopti       |           7 |        -11.4 |         7 |        2.7 |  =   |
| Ergopti ANSI  |           8 |        -12.7 |         8 |        1.6 |  =   |

Largest moves up: Ough (+111), Workwoman (+105), Ali Kian (+100), Karrenbauer Oulasvirta Mod Ian (+100), UCIEA (+96), Uciea Keyboard (+96), Bubbletea (+90), Hands On (+90).

Largest moves down: RL Eai (−143), 16 Maks (−132), Hinsty (−101), RTNA (−99), Ants (−99), Xenia (−94), Real 2 (−93), Arensito (−93).

### fr_wikipedia_1m

Spearman rank correlation 0.9900; 29 of the flat top 30 stay in the graded top 30.

Mean change of each graded metric's points over the 686 complete layouts: sfb -2.93, row_jump -15.74, distance -1.97, hand_run -3.01.

| Graded rank | Layout                         | Graded score | Flat rank | Flat score | Move |
| ----------: | ------------------------------ | -----------: | --------: | ---------: | :--: |
|           1 | Erglace                        |        -14.0 |         1 |        0.8 |  =   |
|           2 | Ergaie                         |        -16.5 |         2 |        0.3 |  =   |
|           3 | Erglace (JF)                   |        -16.7 |         3 |       -1.9 |  =   |
|           4 | Ergopti+                       |        -17.1 |         6 |       -4.1 |  +2  |
|           5 | Ergopti+ ANSI                  |        -17.9 |         7 |       -4.9 |  +2  |
|           6 | BEO                            |        -18.0 |         4 |       -2.4 |  −2  |
|           7 | Erglace (Nuke)                 |        -18.8 |         5 |       -3.8 |  −2  |
|           8 | Ergopti                        |        -19.3 |         8 |       -5.7 |  =   |
|           9 | Ergopti ANSI                   |        -20.2 |         9 |       -6.5 |  =   |
|          10 | NSTR                           |        -27.3 |        14 |      -12.1 |  +4  |
|          11 | Optimot                        |        -28.9 |        17 |      -15.9 |  +6  |
|          12 | Ergo-L (ISO variant)           |        -29.0 |        10 |       -7.4 |  −2  |
|          13 | Urts                           |        -29.0 |        12 |       -9.1 |  −1  |
|          14 | Ergo-L                         |        -29.2 |        11 |       -7.6 |  −3  |
|          15 | BvoFRak 1.0 FR                 |        -31.1 |        16 |      -14.8 |  +1  |
|          16 | Béopy 1DFH                     |        -31.3 |        15 |      -14.5 |  −1  |
|          17 | Hands Down Reference (ErgoDox) |        -31.6 |        19 |      -17.2 |  +2  |
|          18 | Hands Down Reference           |        -32.4 |        18 |      -16.5 |  =   |
|          19 | Colemak French Touch           |        -33.6 |        13 |      -10.4 |  −6  |
|          20 | Inrolly2                       |        -34.3 |        20 |      -17.8 |  =   |
|          21 | Hiyou Satan                    |        -34.4 |        23 |      -19.6 |  +2  |
|          22 | Optimot (ErgoDox)              |        -34.7 |        25 |      -21.8 |  +3  |
|          23 | Hands Up                       |        -35.1 |        21 |      -18.5 |  −2  |
|          24 | Pietergen 2                    |        -35.2 |        22 |      -18.7 |  −2  |
|          25 | HIEAMTSRN                      |        -37.4 |        28 |      -24.0 |  +3  |
|          26 | Helium                         |        -39.0 |        24 |      -20.8 |  −2  |
|          27 | Oneproduct (KLAnext)           |        -40.2 |        33 |      -25.4 |  +6  |
|          28 | Embizone                       |        -40.6 |        30 |      -24.3 |  +2  |
|          29 | Hands Down Extreme             |        -40.6 |        26 |      -21.8 |  −3  |
|          30 | F You                          |        -41.1 |        27 |      -23.9 |  −3  |

Ergopti's layouts:

| Layout        | Graded rank | Graded score | Flat rank | Flat score | Move |
| ------------- | ----------: | -----------: | --------: | ---------: | :--: |
| Ergopti+      |           4 |        -17.1 |         6 |       -4.1 |  +2  |
| Ergopti+ ANSI |           5 |        -17.9 |         7 |       -4.9 |  +2  |
| Ergopti       |           8 |        -19.3 |         8 |       -5.7 |  =   |
| Ergopti ANSI  |           9 |        -20.2 |         9 |       -6.5 |  =   |

Largest moves up: X1 Atreus 44 Keys (+122), Qphyx Adapted (+112), Workwoman (+108), X4 (+105), Bubbletea (+100), Hands On (sym) (+98), Hands Down Alt (ortho) (+97), Dangvu (+93).

Largest moves down: 16 Maks (−138), Apthd (−120), RTNA (−113), Hinsty (−112), RL Eai (−110), Lela (−110), Arensito (−106), Vimak Beta (−100).

### en_don_quixote

Spearman rank correlation 0.9921; 23 of the flat top 30 stay in the graded top 30.

Mean change of each graded metric's points over the 686 complete layouts: sfb -2.59, row_jump -16.46, distance -1.69, hand_run -2.36.

| Graded rank | Layout           | Graded score | Flat rank | Flat score | Move |
| ----------: | ---------------- | -----------: | --------: | ---------: | :--: |
|           1 | Optimal Trigram  |         -2.9 |         4 |        9.4 |  +3  |
|           2 | Layoutfluid      |         -4.1 |         2 |        9.6 |  =   |
|           3 | Graphite         |         -4.4 |         5 |        9.3 |  +2  |
|           4 | Gallium Colstag  |         -4.9 |         6 |        9.0 |  +2  |
|           5 | Maya             |         -5.2 |         3 |        9.5 |  −2  |
|           6 | Nerbs            |         -6.5 |         7 |        7.6 |  +1  |
|           7 | Hiyou Satan      |         -7.3 |        17 |        5.3 | +10  |
|           8 | Apt3 Am          |         -7.8 |         9 |        7.3 |  +1  |
|           9 | APTv3            |         -8.3 |        12 |        6.8 |  +3  |
|          10 | Inrolly2         |         -8.6 |        22 |        4.9 | +12  |
|          11 | Phonkie          |         -8.6 |        10 |        7.2 |  −1  |
|          12 | Moyaimak         |         -8.8 |        25 |        4.6 | +13  |
|          13 | Gallium          |         -9.9 |        11 |        7.0 |  −2  |
|          14 | Gallium Angle    |        -10.0 |         8 |        7.4 |  −6  |
|          15 | F You            |        -10.5 |        27 |        4.1 | +12  |
|          16 | Hyperroll        |        -10.8 |        30 |        3.8 | +14  |
|          17 | Hydrogen         |        -11.1 |        20 |        5.0 |  +3  |
|          18 | Zsvmtjrnl Fkhy   |        -11.2 |        18 |        5.1 |  =   |
|          19 | Dvorky           |        -11.3 |        34 |        2.9 | +15  |
|          20 | Xsvmtkrnl Fhy    |        -11.4 |        23 |        4.8 |  +3  |
|          21 | Voxveritas       |        -11.4 |        16 |        5.3 |  −5  |
|          22 | Wreathy          |        -11.6 |        15 |        5.9 |  −7  |
|          23 | HIEAMTSRN        |        -12.2 |        64 |       -1.1 | +41  |
|          24 | S-Roll           |        -12.5 |        19 |        5.1 |  −5  |
|          25 | Rollla (KLAnext) |        -12.9 |        26 |        4.1 |  +1  |
|          26 | Vylet            |        -13.2 |        46 |        1.1 | +20  |
|          27 | Hands Up         |        -13.4 |        56 |       -0.2 | +29  |
|          28 | NSTR             |        -13.5 |        40 |        2.2 | +12  |
|          29 | Minred           |        -14.5 |        63 |       -0.9 | +34  |
|          30 | Saiga            |        -14.6 |        35 |        2.9 |  +5  |

Ergopti's layouts:

| Layout        | Graded rank | Graded score | Flat rank | Flat score | Move |
| ------------- | ----------: | -----------: | --------: | ---------: | :--: |
| Ergopti+      |         223 |        -36.7 |       205 |      -13.8 | −18  |
| Ergopti+ ANSI |         225 |        -37.2 |       210 |      -14.3 | −15  |
| Ergopti       |         229 |        -37.5 |       212 |      -14.4 | −17  |
| Ergopti ANSI  |         234 |        -38.0 |       216 |      -14.9 | −18  |

Largest moves up: Beakl Mod Ctgap (+83), Balance-12 (+79), Uhiea Davison (+79), Balance Twelve (+78), X4 (+78), Mtgap Mod Joey2216 (+75), BuTeck (+72), OISEAU (+72).

Largest moves down: Seht Drai (KLAnext) (−129), Seht Drai (−119), RTNA (−112), Ergo-L (ISO variant) (−101), Beesechurger (−101), Ergo-L (−99), Snorkle (−88), FLAW (−86).

### en_wikipedia_1m

Spearman rank correlation 0.9897; 20 of the flat top 30 stay in the graded top 30.

Mean change of each graded metric's points over the 686 complete layouts: sfb -2.91, row_jump -15.91, distance -2.08, hand_run -2.75.

| Graded rank | Layout               | Graded score | Flat rank | Flat score | Move |
| ----------: | -------------------- | -----------: | --------: | ---------: | :--: |
|           1 | Inrolly2             |        -16.6 |         2 |       -2.6 |  +1  |
|           2 | Gallium Colstag      |        -18.0 |         3 |       -3.2 |  +1  |
|           3 | Graphite             |        -19.0 |         8 |       -3.9 |  +5  |
|           4 | Layoutfluid          |        -19.4 |        11 |       -4.4 |  +7  |
|           5 | Maya                 |        -20.0 |        12 |       -4.7 |  +7  |
|           6 | Nerbs                |        -20.0 |        13 |       -5.1 |  +7  |
|           7 | Carbyne Ian          |        -20.2 |         1 |       -2.3 |  −6  |
|           8 | AdNW                 |        -20.6 |        41 |       -8.0 | +33  |
|           9 | Optimal Trigram      |        -21.1 |        27 |       -7.0 | +18  |
|          10 | Moyaimak             |        -21.5 |        25 |       -6.9 | +15  |
|          11 | F You                |        -21.5 |        24 |       -6.7 | +13  |
|          12 | Oneproduct (KLAnext) |        -21.9 |        35 |       -7.8 | +23  |
|          13 | Hiyou Satan          |        -22.1 |        47 |       -8.3 | +34  |
|          14 | Hyperroll            |        -22.3 |        28 |       -7.0 | +14  |
|          15 | Voxveritas           |        -22.5 |         7 |       -3.6 |  −8  |
|          16 | HIEAMTSRN            |        -22.6 |        73 |       -9.8 | +57  |
|          17 | Dvormax              |        -22.6 |        76 |      -10.0 | +59  |
|          18 | Gallium Angle        |        -22.6 |        15 |       -5.4 |  −3  |
|          19 | Gallium              |        -22.7 |        19 |       -6.0 |  =   |
|          20 | Oneproduct ZXCV      |        -22.7 |        44 |       -8.3 | +24  |
|          21 | Hands Up             |        -22.8 |        40 |       -8.0 | +19  |
|          22 | Rollla (KLAnext)     |        -23.1 |        10 |       -4.2 | −12  |
|          23 | Ruthenium            |        -23.3 |        17 |       -5.6 |  −6  |
|          24 | Adnw English Bigram  |        -23.5 |        92 |      -10.9 | +68  |
|          25 | Nitrogen             |        -23.6 |        71 |       -9.8 | +46  |
|          26 | Sturdy Anglemod      |        -23.9 |         4 |       -3.4 | −22  |
|          27 | Sturdy               |        -23.9 |         5 |       -3.4 | −22  |
|          28 | NSTR                 |        -24.2 |        26 |       -6.9 |  −2  |
|          29 | Fire                 |        -24.9 |        14 |       -5.3 | −15  |
|          30 | Optimal Digram       |        -24.9 |       125 |      -12.8 | +95  |

Ergopti's layouts:

| Layout        | Graded rank | Graded score | Flat rank | Flat score | Move |
| ------------- | ----------: | -----------: | --------: | ---------: | :--: |
| Ergopti+      |         228 |        -41.1 |       224 |      -20.6 |  −4  |
| Ergopti+ ANSI |         231 |        -41.6 |       227 |      -21.1 |  −4  |
| Ergopti       |         236 |        -41.9 |       230 |      -21.2 |  −6  |
| Ergopti ANSI  |         240 |        -42.4 |       235 |      -21.7 |  −5  |

Largest moves up: Noname 30 (+103), Adnw (KLAnext) (+100), S2 Klopt (+99), Adnw Mod Keen (+98), Balance Twelve (+95), Optimal Digram (+95), BuTeck (+92), Balance-12 (+91).

Largest moves down: Seht Drai (KLAnext) (−130), Seht Drai (−121), FLAW (−112), RTNA (−110), Beesechurger (−109), 16 Maks (−94), Lela (−93), APTv4 (−91).

### Every layout score

| Layout                                     | fr_don_quichotte flat → graded | fr_wikipedia_1m flat → graded | en_don_quixote flat → graded | en_wikipedia_1m flat → graded |
| ------------------------------------------ | -----------------------------: | ----------------------------: | ---------------------------: | ----------------------------: |
| Erglace (JF)                               |                     8.4 → -7.1 |                  -1.9 → -16.7 |                 -8.9 → -33.7 |                 -12.3 → -32.6 |
| Ergaie                                     |                    7.3 → -10.5 |                   0.3 → -16.5 |                 -6.4 → -30.5 |                 -12.6 → -32.6 |
| Erglace                                    |                     6.8 → -8.7 |                   0.8 → -14.0 |                -14.3 → -37.5 |                 -15.8 → -34.7 |
| Ergopti+                                   |                     6.7 → -6.8 |                  -4.1 → -17.1 |                -13.8 → -36.7 |                 -20.6 → -41.1 |
| Ergopti+ ANSI                              |                     5.7 → -7.9 |                  -4.9 → -17.9 |                -14.3 → -37.2 |                 -21.1 → -41.6 |
| Erglace (Nuke)                             |                     5.6 → -9.8 |                  -3.8 → -18.8 |                 -9.6 → -33.4 |                 -14.0 → -33.4 |
| Ergopti                                    |                    2.7 → -11.4 |                  -5.7 → -19.3 |                -14.4 → -37.5 |                 -21.2 → -41.9 |
| Ergopti ANSI                               |                    1.6 → -12.7 |                  -6.5 → -20.2 |                -14.9 → -38.0 |                 -21.7 → -42.4 |
| BEO                                        |                    1.3 → -15.7 |                  -2.4 → -18.0 |                -15.7 → -41.3 |                 -23.7 → -46.6 |
| Optimot                                    |                   -1.0 → -13.6 |                 -15.9 → -28.9 |                -35.5 → -54.2 |                 -42.9 → -60.6 |
| Ergo-L                                     |                   -3.8 → -25.3 |                  -7.6 → -29.2 |                -28.2 → -60.5 |                 -23.9 → -53.5 |
| Ergo-L (ISO variant)                       |                   -3.8 → -25.3 |                  -7.4 → -29.0 |                -25.3 → -57.0 |                 -22.5 → -52.0 |
| Béopy 1DFH                                 |                   -6.1 → -21.8 |                 -14.5 → -31.3 |                -39.9 → -60.8 |                 -35.4 → -53.3 |
| Colemak French Touch                       |                   -6.1 → -30.5 |                 -10.4 → -33.6 |                -32.4 → -60.8 |                 -23.1 → -47.8 |
| Optimot (ErgoDox)                          |                   -6.3 → -19.1 |                 -21.8 → -34.7 |                -36.0 → -56.2 |                 -40.9 → -59.1 |
| BvoFRak 1.0 FR                             |                   -8.1 → -23.6 |                 -14.8 → -31.1 |               -88.8 → -109.1 |                 -77.5 → -97.1 |
| NSTR                                       |                   -9.4 → -25.3 |                 -12.1 → -27.3 |                  2.2 → -13.5 |                  -6.9 → -24.2 |
| Hands Down Reference                       |                  -11.9 → -29.8 |                 -16.5 → -32.4 |                -22.9 → -48.9 |                 -23.1 → -46.5 |
| Urts                                       |                  -13.2 → -33.9 |                  -9.1 → -29.0 |                 -3.6 → -27.0 |                  -8.9 → -31.8 |
| Hands Down Reference (ErgoDox)             |                  -14.2 → -29.7 |                 -17.2 → -31.6 |                -26.4 → -53.2 |                 -24.6 → -47.5 |
| Inrolly2                                   |                  -15.8 → -33.5 |                 -17.8 → -34.3 |                   4.9 → -8.6 |                  -2.6 → -16.6 |
| Hands Up                                   |                  -16.7 → -35.7 |                 -18.5 → -35.1 |                 -0.2 → -13.4 |                  -8.0 → -22.8 |
| Hiyou Satan                                |                  -17.6 → -33.6 |                 -19.6 → -34.4 |                   5.3 → -7.3 |                  -8.3 → -22.1 |
| Hiyou (KLAnext)                            |                  -22.3 → -40.2 |                 -30.5 → -46.7 |                 -4.8 → -16.9 |                 -16.5 → -29.8 |
| Eureka Plus                                |                  -22.4 → -41.3 |                 -24.2 → -41.9 |                -57.9 → -82.4 |                 -39.4 → -61.0 |
| Pietergen 2                                |                  -22.4 → -40.3 |                 -18.7 → -35.2 |                -26.7 → -42.1 |                 -20.1 → -35.0 |
| Ev29                                       |                  -22.7 → -47.4 |                 -29.7 → -52.3 |                -21.1 → -41.7 |                 -28.7 → -49.3 |
| Hands Down Extreme                         |                  -22.9 → -44.7 |                 -21.8 → -40.6 |                -21.6 → -50.7 |                 -22.9 → -49.5 |
| Hands Down Neu (cyanophage)                |                  -23.6 → -43.9 |                 -29.2 → -46.5 |                 -7.1 → -22.2 |                 -20.4 → -35.5 |
| Embizone                                   |                  -23.7 → -42.2 |                 -24.3 → -40.6 |                 -1.9 → -17.1 |                 -11.2 → -26.4 |
| Full R2 Rt161 57 5bc1aa                    |                  -23.9 → -48.9 |                 -29.1 → -52.4 |                -30.9 → -56.5 |                 -29.6 → -54.2 |
| Béopy                                      |                  -24.2 → -37.7 |                 -27.8 → -42.0 |                -51.7 → -73.0 |                 -50.3 → -69.0 |
| F You                                      |                  -24.5 → -44.3 |                 -23.9 → -41.1 |                  4.1 → -10.5 |                  -6.7 → -21.5 |
| Haeik                                      |                  -25.2 → -43.0 |                 -32.6 → -48.2 |                -24.2 → -37.4 |                 -31.6 → -45.2 |
| HIEAMTSRN                                  |                  -25.3 → -38.3 |                 -24.0 → -37.4 |                 -1.1 → -12.2 |                  -9.8 → -22.6 |
| Full R2 Rt161 57 47179e                    |                  -25.3 → -50.9 |                 -31.1 → -54.9 |                -31.4 → -57.1 |                 -30.2 → -54.9 |
| Bépolar                                    |                  -25.6 → -42.4 |                 -31.6 → -49.6 |                -59.3 → -82.4 |                 -46.5 → -67.4 |
| Helium                                     |                  -25.9 → -46.1 |                 -20.8 → -39.0 |                -13.2 → -30.2 |                 -17.4 → -34.7 |
| Mtgap Hybrid Vanilla                       |                  -27.2 → -46.3 |                 -33.4 → -52.2 |                -10.7 → -23.6 |                 -17.9 → -33.3 |
| Balance Twelve                             |                  -27.5 → -42.0 |                 -27.9 → -42.4 |                 -7.5 → -18.9 |                 -16.3 → -29.1 |
| Mtgap Optimised Shifted                    |                  -28.0 → -45.7 |                 -33.7 → -51.8 |                 -8.9 → -21.5 |                 -16.3 → -31.7 |
| Hands Down Neu                             |                  -28.1 → -47.9 |                 -31.7 → -48.7 |                 -5.7 → -19.3 |                 -18.6 → -32.4 |
| Rollly                                     |                  -28.4 → -47.3 |                 -29.9 → -49.6 |                  3.6 → -17.3 |                  -9.1 → -30.5 |
| Oneproduct (KLAnext)                       |                  -28.6 → -44.4 |                 -25.4 → -40.2 |                 -0.8 → -15.1 |                  -7.8 → -21.9 |
| Ctgap Ev                                   |                  -28.7 → -51.4 |                 -32.4 → -53.6 |                -12.7 → -28.9 |                 -15.5 → -32.5 |
| Hands Down Hazamod                         |                  -28.8 → -46.1 |                 -24.5 → -41.6 |                -34.1 → -61.8 |                 -24.8 → -50.0 |
| Balance-12                                 |                  -29.0 → -44.5 |                 -26.8 → -41.5 |                -12.8 → -25.2 |                 -15.1 → -28.0 |
| Full R2 Rt162 25 2ec2c1                    |                  -29.3 → -53.6 |                 -33.0 → -56.8 |                -27.2 → -54.7 |                 -27.6 → -53.1 |
| Navarre 2023 (ZHJAYSCPG)                   |                  -29.6 → -44.5 |                 -36.7 → -52.0 |               -77.2 → -102.9 |                -81.8 → -105.7 |
| Ammon134                                   |                  -30.3 → -54.0 |                 -29.8 → -53.1 |                 -2.8 → -25.6 |                 -12.6 → -37.1 |
| Colemak LF                                 |                  -31.0 → -50.9 |                 -30.3 → -51.0 |                -34.7 → -60.6 |                 -31.0 → -56.7 |
| bépo                                       |                  -31.2 → -44.0 |                 -32.8 → -47.3 |                -58.6 → -79.9 |                 -50.5 → -69.6 |
| MTGAP 3.0                                  |                  -31.2 → -49.6 |                 -37.4 → -56.0 |                -11.0 → -24.0 |                 -18.4 → -34.2 |
| Mtgap Mod Joey2216                         |                  -31.4 → -50.8 |                 -36.8 → -55.5 |                -10.5 → -23.0 |                 -19.7 → -34.4 |
| Rollly2                                    |                  -31.6 → -52.9 |                 -32.3 → -53.3 |                 -4.5 → -26.2 |                 -17.0 → -38.5 |
| Bone (KLAnext)                             |                  -31.8 → -57.4 |                 -29.5 → -53.9 |                -15.3 → -41.8 |                 -13.6 → -39.0 |
| Narts 9                                    |                  -31.8 → -54.1 |                 -32.9 → -54.4 |                 -8.4 → -26.5 |                 -15.9 → -35.5 |
| Kilo 37 Vanilla                            |                  -32.1 → -47.5 |                 -40.1 → -54.0 |                -43.1 → -57.7 |                 -35.1 → -47.4 |
| Beakl19bis                                 |                  -32.1 → -52.7 |                 -38.5 → -58.7 |                -15.6 → -29.4 |                 -28.9 → -44.9 |
| Isrt Anglemod                              |                  -32.4 → -49.8 |                 -37.0 → -55.3 |                -10.5 → -32.0 |                 -16.4 → -38.0 |
| Hands Down Reference (sym)                 |                  -32.5 → -49.4 |                 -33.1 → -49.4 |                -51.3 → -80.6 |                 -38.5 → -64.6 |
| Ctgap Final                                |                  -32.9 → -55.9 |                 -30.9 → -53.3 |                 -6.2 → -23.2 |                 -11.4 → -29.3 |
| Gyf Beta                                   |                  -33.0 → -47.4 |                 -41.6 → -55.3 |                -29.0 → -40.9 |                 -37.1 → -50.3 |
| L You                                      |                  -33.0 → -55.7 |                 -28.9 → -48.9 |                 -2.5 → -18.3 |                 -10.6 → -26.3 |
| 14 Maks                                    |                  -33.0 → -55.5 |                 -32.8 → -55.4 |                -49.1 → -73.8 |                 -36.0 → -60.7 |
| CTGAP 3                                    |                  -33.1 → -50.4 |                 -41.5 → -57.7 |                -10.5 → -23.2 |                 -20.9 → -34.3 |
| Hoogendoorn                                |                  -33.2 → -54.9 |                 -24.4 → -44.7 |                -29.0 → -44.8 |                 -22.8 → -39.1 |
| Megamak                                    |                  -33.3 → -56.3 |                 -27.2 → -49.5 |                -14.2 → -37.6 |                 -12.9 → -35.6 |
| Neauwr Bits                                |                  -33.6 → -60.6 |                 -38.8 → -66.0 |                -36.6 → -62.3 |                 -47.9 → -74.7 |
| Crstm                                      |                  -33.7 → -53.4 |                 -30.0 → -50.6 |                 -6.2 → -28.0 |                 -12.0 → -33.9 |
| Beakl Mod Ctgap                            |                  -34.2 → -53.0 |                 -52.2 → -70.7 |                -14.7 → -26.3 |                 -37.4 → -51.3 |
| Snug                                       |                  -34.6 → -56.2 |                 -28.9 → -48.8 |                -12.0 → -34.7 |                  -9.4 → -29.6 |
| Wedlock                                    |                  -35.0 → -57.8 |                 -29.5 → -52.3 |                -10.2 → -27.0 |                 -11.8 → -30.6 |
| Full 157 64 17e2a0                         |                  -35.1 → -61.7 |                 -37.3 → -62.8 |                -28.8 → -57.0 |                 -29.2 → -54.9 |
| HRST                                       |                  -35.1 → -60.1 |                 -30.7 → -54.4 |                  0.1 → -15.8 |                  -9.6 → -27.8 |
| Tesc                                       |                  -35.1 → -55.5 |                 -30.1 → -51.9 |                 -4.6 → -20.7 |                 -10.7 → -28.8 |
| Isrtgap                                    |                  -35.4 → -55.9 |                 -31.9 → -50.5 |                -10.1 → -28.7 |                 -15.4 → -34.0 |
| Blou                                       |                  -35.4 → -60.3 |                 -37.5 → -63.5 |                -15.1 → -34.7 |                 -23.9 → -45.6 |
| AHEI                                       |                  -35.6 → -53.8 |                 -38.5 → -56.1 |                -24.1 → -38.9 |                 -27.3 → -42.5 |
| Paw177                                     |                  -35.7 → -56.5 |                 -35.9 → -57.2 |                 -9.5 → -26.6 |                 -16.6 → -37.5 |
| Crankiest Y                                |                  -35.7 → -55.9 |                 -31.6 → -51.1 |                 -3.2 → -26.9 |                 -11.5 → -34.0 |
| Inrolly                                    |                  -35.8 → -62.9 |                 -41.8 → -70.1 |                  3.9 → -20.3 |                 -14.6 → -41.6 |
| Arts                                       |                  -35.8 → -54.1 |                 -35.4 → -54.1 |                -10.6 → -33.4 |                 -16.1 → -37.8 |
| Hyperroll                                  |                  -35.9 → -60.3 |                 -35.4 → -57.5 |                  3.8 → -10.8 |                  -7.0 → -22.3 |
| Engram                                     |                  -35.9 → -53.0 |                 -29.4 → -46.8 |                -11.4 → -27.0 |                 -17.8 → -34.8 |
| Nerts (KLAnext)                            |                  -36.0 → -56.0 |                 -30.3 → -48.7 |                 -3.0 → -21.7 |                  -9.9 → -28.9 |
| Rtnsg                                      |                  -36.2 → -53.5 |                 -30.5 → -48.1 |                -11.6 → -27.3 |                 -12.2 → -28.4 |
| Debian                                     |                  -36.2 → -61.6 |                 -28.4 → -52.1 |                -14.5 → -36.7 |                 -15.2 → -38.1 |
| Ahei (KLAnext)                             |                  -36.4 → -55.5 |                 -36.0 → -54.2 |                -19.9 → -35.0 |                 -21.5 → -37.0 |
| DTK Eia                                    |                  -36.6 → -64.3 |                 -36.9 → -61.6 |                -21.1 → -41.2 |                 -19.4 → -39.7 |
| Nerts                                      |                  -36.7 → -56.2 |                 -30.8 → -48.6 |                 -4.6 → -19.6 |                 -11.4 → -27.0 |
| APTv4                                      |                  -36.7 → -63.4 |                 -30.1 → -54.9 |                 -7.9 → -33.5 |                 -11.8 → -37.8 |
| S2                                         |                  -37.2 → -52.1 |                 -38.0 → -51.7 |                -28.5 → -42.9 |                 -30.0 → -43.1 |
| Fire (KLAnext)                             |                  -37.2 → -61.7 |                 -30.5 → -53.1 |                 -3.6 → -21.8 |                  -8.3 → -28.1 |
| Poqtea QP                                  |                  -37.4 → -52.7 |                 -32.6 → -47.8 |                -42.8 → -61.0 |                 -35.7 → -54.1 |
| Oneproduct ZXCV                            |                  -37.7 → -52.3 |                 -28.9 → -42.5 |                 -2.2 → -16.4 |                  -8.3 → -22.7 |
| Irst                                       |                  -37.8 → -58.1 |                 -33.1 → -52.9 |                 -4.6 → -25.5 |                 -12.7 → -33.4 |
| Engrammer                                  |                  -37.9 → -55.2 |                 -30.2 → -47.6 |                -11.8 → -27.3 |                 -18.8 → -35.9 |
| Poqtea Tuned                               |                  -38.0 → -52.6 |                 -35.0 → -49.9 |                -46.0 → -64.2 |                 -38.7 → -56.8 |
| Voxveritas                                 |                  -38.2 → -59.7 |                 -33.6 → -54.2 |                  5.3 → -11.4 |                  -3.6 → -22.5 |
| BEAKL-19                                   |                  -38.2 → -61.6 |                 -45.5 → -67.0 |                -24.0 → -40.4 |                 -29.8 → -46.6 |
| Nerps (KLAnext)                            |                  -38.3 → -57.9 |                 -34.0 → -52.0 |                 -4.1 → -22.5 |                 -13.1 → -31.9 |
| Nerps                                      |                  -38.4 → -57.5 |                 -33.7 → -51.1 |                 -5.6 → -20.4 |                 -14.6 → -30.0 |
| Pieter Saeio                               |                  -38.6 → -55.3 |                 -45.2 → -58.9 |                -21.2 → -38.8 |                 -30.5 → -46.8 |
| K U Tea SHRT PNCT                          |                  -38.9 → -55.2 |                 -38.6 → -54.2 |                -53.0 → -74.9 |                 -43.4 → -63.5 |
| Canary Ortho                               |                  -38.9 → -61.7 |                 -35.4 → -57.0 |                -20.7 → -44.9 |                 -15.2 → -37.3 |
| ZXCV Fingers                               |                  -39.3 → -58.5 |                 -37.0 → -55.5 |                -53.3 → -77.2 |                 -42.7 → -66.0 |
| Canary Plusplus                            |                  -39.4 → -58.7 |                 -40.9 → -59.5 |                -20.5 → -38.4 |                 -21.9 → -40.2 |
| Pine V4                                    |                  -39.6 → -59.7 |                 -40.2 → -61.8 |                 -2.8 → -20.6 |                 -10.7 → -29.6 |
| Beakl Opted4                               |                  -39.7 → -59.2 |                 -48.3 → -66.4 |                -14.5 → -29.8 |                 -27.7 → -43.0 |
| Hein                                       |                  -39.7 → -63.4 |                 -38.6 → -63.2 |                -41.2 → -64.4 |                 -43.2 → -68.0 |
| Rollla                                     |                  -39.7 → -60.8 |                 -34.7 → -54.7 |                  2.3 → -14.8 |                  -6.2 → -25.2 |
| Northstar                                  |                  -39.9 → -57.5 |                 -31.1 → -48.4 |                -23.1 → -36.4 |                 -16.2 → -30.9 |
| Pow 123                                    |                  -39.9 → -60.6 |                 -35.1 → -55.0 |                -19.0 → -36.7 |                 -22.1 → -40.5 |
| Heart                                      |                  -40.0 → -61.3 |                 -31.4 → -52.7 |                 -5.3 → -24.1 |                  -6.1 → -26.3 |
| Rollla (KLAnext)                           |                  -40.0 → -61.2 |                 -34.7 → -54.7 |                  4.1 → -12.9 |                  -4.2 → -23.1 |
| ISRT                                       |                  -40.0 → -57.6 |                 -42.5 → -60.9 |                -12.9 → -34.5 |                 -16.9 → -38.6 |
| Heart (KLAnext)                            |                  -40.1 → -61.4 |                 -31.3 → -52.6 |                 -5.0 → -23.8 |                  -6.0 → -26.1 |
| Canary                                     |                  -40.2 → -66.4 |                 -36.7 → -61.7 |                -21.0 → -48.1 |                 -16.4 → -41.7 |
| Dwarf                                      |                  -40.2 → -63.4 |                 -33.7 → -55.4 |                 -5.3 → -29.3 |                 -13.3 → -37.5 |
| Arinh                                      |                  -40.3 → -60.6 |                 -43.0 → -64.8 |                -34.3 → -54.8 |                 -37.4 → -61.1 |
| Oneproduct                                 |                  -40.4 → -58.8 |                 -43.5 → -59.5 |                 -9.8 → -25.0 |                 -20.2 → -34.7 |
| Ctgap                                      |                  -40.5 → -64.0 |                 -34.4 → -56.6 |                -17.0 → -32.0 |                 -11.3 → -28.0 |
| Colemak Cousin                             |                  -40.7 → -58.1 |                 -36.5 → -53.2 |                -47.6 → -69.5 |                 -38.9 → -60.1 |
| Trendei (KLAnext)                          |                  -40.7 → -67.0 |                 -33.2 → -55.4 |                -10.4 → -30.8 |                  -9.8 → -30.1 |
| Aptx                                       |                  -40.7 → -60.5 |                 -32.1 → -50.7 |                  1.0 → -18.4 |                  -7.1 → -26.3 |
| Sertain2                                   |                  -40.9 → -65.1 |                 -33.6 → -57.0 |                 -6.3 → -28.7 |                 -11.5 → -35.4 |
| Canary (KLAnext)                           |                  -40.9 → -67.0 |                 -37.9 → -62.7 |                -21.0 → -48.3 |                 -17.3 → -43.6 |
| Colemak Qix                                |                  -40.9 → -58.2 |                 -34.1 → -52.2 |                -12.1 → -34.0 |                 -16.7 → -39.1 |
| APT                                        |                  -41.0 → -65.9 |                 -33.9 → -57.1 |                 -8.3 → -27.3 |                 -13.6 → -34.6 |
| Hiyou                                      |                  -41.1 → -60.9 |                 -46.6 → -64.2 |                -12.2 → -26.1 |                 -19.4 → -33.2 |
| Octa8 (KLAnext)                            |                  -41.2 → -64.6 |                 -35.9 → -56.6 |                  2.4 → -18.4 |                  -9.1 → -29.3 |
| Athena                                     |                  -41.3 → -61.9 |                 -38.6 → -58.1 |                -32.6 → -55.0 |                 -26.3 → -46.4 |
| Colemak Qi;x                               |                  -41.4 → -59.0 |                 -34.4 → -52.7 |                -12.3 → -34.4 |                 -16.7 → -39.3 |
| Dilbert                                    |                  -41.5 → -69.5 |                 -38.7 → -62.4 |                -23.7 → -47.1 |                 -22.7 → -43.3 |
| Uciea Vanilla Mod Gergely                  |                  -41.6 → -58.9 |                 -34.5 → -49.4 |                 -8.4 → -27.2 |                 -11.6 → -29.5 |
| GG Beakl 19                                |                  -41.7 → -64.4 |                 -48.9 → -69.8 |                -28.0 → -43.2 |                 -32.3 → -48.1 |
| Hands Down Ref (ortho)                     |                  -41.8 → -60.9 |                 -37.0 → -53.6 |                -37.6 → -66.4 |                 -37.9 → -63.0 |
| Adnw Mod Keen                              |                  -41.9 → -58.4 |                 -40.0 → -54.6 |                -11.2 → -24.7 |                 -16.6 → -29.5 |
| Poqtea Klopt                               |                  -41.9 → -58.2 |                 -40.2 → -56.1 |                -48.1 → -67.8 |                 -37.7 → -56.6 |
| Ants                                       |                  -42.0 → -72.6 |                 -35.8 → -64.7 |                -16.1 → -42.0 |                 -26.9 → -54.2 |
| Nerps (cyanophage)                         |                  -42.2 → -62.1 |                 -38.0 → -56.5 |                 -7.0 → -25.4 |                 -16.2 → -34.9 |
| Ctgap 2                                    |                  -42.2 → -65.3 |                 -45.7 → -67.8 |                -14.1 → -28.5 |                 -26.5 → -43.2 |
| Noname 30                                  |                  -42.3 → -59.6 |                 -41.0 → -55.5 |                 -6.2 → -17.8 |                 -14.3 → -26.4 |
| Sertain2 Mod Ian                           |                  -42.5 → -61.4 |                 -29.1 → -46.1 |                -18.4 → -34.7 |                 -15.3 → -31.5 |
| Trendei                                    |                  -42.6 → -69.1 |                 -35.3 → -57.7 |                -11.3 → -31.7 |                 -11.0 → -31.3 |
| Carbyne Ian                                |                  -42.6 → -61.3 |                 -32.5 → -48.5 |                  1.5 → -17.8 |                  -2.3 → -20.2 |
| Hands Down Alt (KLAnext, ErgoDox)          |                  -42.7 → -58.8 |                 -46.5 → -60.6 |                -21.0 → -42.5 |                 -28.5 → -47.5 |
| Poqdea                                     |                  -42.7 → -63.0 |                 -36.2 → -54.7 |                -53.6 → -73.1 |                 -40.6 → -60.0 |
| Crest                                      |                  -42.8 → -60.9 |                 -31.0 → -49.5 |                 -6.5 → -27.7 |                  -7.4 → -27.9 |
| Uciea PCRW                                 |                  -42.9 → -59.1 |                 -34.9 → -48.8 |                -11.7 → -29.6 |                 -13.1 → -29.8 |
| Heartae                                    |                  -42.9 → -64.0 |                 -31.7 → -52.5 |                -16.0 → -34.5 |                 -11.4 → -31.5 |
| Sertain                                    |                  -42.9 → -67.5 |                 -34.7 → -58.3 |                 -6.9 → -29.3 |                 -12.4 → -36.3 |
| Dickens LSF                                |                  -43.0 → -63.9 |                 -45.1 → -65.8 |                -32.0 → -52.8 |                 -34.2 → -54.5 |
| Uciea GCSV                                 |                  -43.1 → -59.8 |                 -33.4 → -48.1 |                 -6.2 → -23.7 |                 -10.5 → -27.2 |
| Ace Vim                                    |                  -43.2 → -59.4 |                 -36.3 → -52.1 |                 -4.2 → -28.0 |                  -9.6 → -32.4 |
| Colemak Pine                               |                  -43.3 → -64.1 |                 -37.5 → -57.3 |                 -7.1 → -28.9 |                 -14.3 → -36.5 |
| Homework                                   |                  -43.3 → -64.1 |                 -44.7 → -64.2 |                 -9.0 → -29.4 |                 -17.9 → -39.2 |
| Beakl421                                   |                  -43.6 → -57.9 |                 -39.2 → -53.8 |                -21.4 → -36.6 |                 -22.7 → -38.4 |
| Hinsty                                     |                  -43.8 → -74.7 |                 -39.8 → -69.8 |                -17.7 → -41.6 |                 -26.1 → -50.9 |
| Colemak Qi (KLAnext)                       |                  -43.9 → -60.7 |                 -35.2 → -53.1 |                -15.3 → -38.3 |                 -16.4 → -39.4 |
| Aptsym2                                    |                  -44.0 → -64.1 |                 -41.5 → -62.5 |                 -5.2 → -29.1 |                  -8.0 → -31.2 |
| Gust                                       |                  -44.1 → -67.4 |                 -36.5 → -59.5 |                 -1.6 → -17.1 |                  -8.8 → -26.7 |
| Northstar (cyanophage, page 2)             |                  -44.1 → -62.0 |                 -37.3 → -54.9 |                -17.6 → -31.0 |                 -14.0 → -28.9 |
| LSNT                                       |                  -44.2 → -65.5 |                 -60.1 → -81.0 |                -22.6 → -36.7 |                 -43.2 → -59.7 |
| Colemak Qi                                 |                  -44.3 → -61.1 |                 -35.9 → -53.9 |                -15.9 → -38.9 |                 -16.7 → -39.8 |
| Burroughs Bower Mod Ian                    |                  -44.5 → -68.1 |                 -43.3 → -67.1 |                -39.7 → -59.3 |                 -37.9 → -59.6 |
| Irstmak                                    |                  -44.6 → -64.6 |                 -50.8 → -72.0 |                -24.1 → -45.4 |                 -27.1 → -48.6 |
| BuTeck                                     |                  -44.6 → -61.5 |                 -44.0 → -58.7 |                 -8.6 → -21.0 |                 -19.1 → -31.5 |
| CMBK Nlhy 2                                |                  -44.7 → -74.4 |                 -37.8 → -65.7 |                -17.4 → -35.8 |                 -17.0 → -37.8 |
| Calemog                                    |                  -44.7 → -64.2 |                 -39.1 → -57.2 |                 -5.9 → -26.0 |                 -12.7 → -32.9 |
| Saiga                                      |                  -44.8 → -68.1 |                 -44.6 → -66.9 |                  2.9 → -14.6 |                 -10.7 → -31.0 |
| Iena                                       |                  -44.9 → -64.8 |                 -46.6 → -66.3 |                -23.6 → -40.3 |                 -31.4 → -49.4 |
| Graphite                                   |                  -44.9 → -61.5 |                 -40.0 → -56.4 |                   9.3 → -4.4 |                  -3.9 → -19.0 |
| Athena Alt                                 |                  -44.9 → -66.2 |                 -40.3 → -60.8 |                -25.8 → -45.8 |                 -25.9 → -46.4 |
| Apthd                                      |                  -45.1 → -74.0 |                 -44.6 → -74.0 |                -21.1 → -43.7 |                 -21.1 → -45.6 |
| Another Method Non Mirrored                |                  -45.8 → -69.5 |                 -55.8 → -77.9 |                -40.6 → -58.7 |                 -33.5 → -51.1 |
| Carbyne                                    |                  -45.8 → -65.0 |                 -35.1 → -51.9 |                  0.1 → -19.9 |                  -6.4 → -25.5 |
| Eureka                                     |                  -45.9 → -65.1 |                 -46.4 → -64.3 |                -59.4 → -83.1 |                 -49.1 → -69.7 |
| Notarise                                   |                  -45.9 → -66.9 |                 -55.3 → -77.2 |                -66.9 → -90.2 |                 -57.0 → -80.8 |
| Layoutissimus                              |                  -46.0 → -65.3 |                 -44.1 → -60.5 |               -79.1 → -102.6 |                 -60.6 → -82.1 |
| Dvormax                                    |                  -46.2 → -61.9 |                 -37.5 → -50.8 |                 -9.5 → -24.0 |                 -10.0 → -22.6 |
| Middlemak                                  |                  -46.3 → -72.3 |                 -45.1 → -72.2 |                -35.7 → -57.8 |                 -33.1 → -57.6 |
| Louda                                      |                  -46.4 → -71.5 |                 -41.7 → -66.3 |                -25.8 → -47.1 |                 -18.1 → -40.5 |
| Apt (KLAnext)                              |                  -46.5 → -68.3 |                 -34.9 → -56.3 |                -20.5 → -39.7 |                 -15.1 → -36.0 |
| X4                                         |                  -46.5 → -59.7 |                 -51.1 → -63.2 |                -43.8 → -55.3 |                 -47.7 → -58.8 |
| Asrt Hrl2                                  |                  -46.7 → -67.4 |                 -47.9 → -67.2 |                -19.1 → -46.1 |                 -26.2 → -51.0 |
| Colemak Mod UK                             |                  -46.7 → -66.7 |                 -47.1 → -68.2 |                -39.7 → -57.1 |                 -36.6 → -55.3 |
| Hands Right                                |                  -46.8 → -61.6 |                 -36.4 → -51.0 |                 -3.2 → -19.3 |                  -9.3 → -25.9 |
| Colemak DHv (genkey)                       |                  -46.8 → -68.0 |                 -50.8 → -71.7 |                -30.6 → -52.3 |                 -30.8 → -52.0 |
| Octa8                                      |                  -46.9 → -68.0 |                 -41.8 → -61.3 |                 -1.6 → -22.0 |                 -10.3 → -30.3 |
| Wreathy                                    |                  -46.9 → -72.7 |                 -40.8 → -65.1 |                  5.9 → -11.6 |                  -9.1 → -27.8 |
| Kyudi                                      |                  -47.3 → -66.5 |                 -40.6 → -56.5 |                -14.2 → -35.0 |                 -17.1 → -34.6 |
| Middlemak NH                               |                  -47.5 → -68.8 |                 -40.8 → -61.4 |                -31.4 → -48.9 |                 -23.4 → -41.7 |
| Kaehi                                      |                  -47.7 → -63.4 |                 -42.2 → -57.3 |                -34.7 → -52.2 |                 -33.3 → -50.5 |
| Layoutfluid                                |                  -47.8 → -64.4 |                 -42.3 → -58.7 |                   9.6 → -4.1 |                  -4.4 → -19.4 |
| Vimak Beta                                 |                  -47.8 → -75.6 |                 -42.3 → -70.5 |                -26.2 → -53.0 |                 -25.4 → -52.9 |
| Mtgap R                                    |                  -47.9 → -70.9 |                 -40.3 → -59.6 |                -12.5 → -30.4 |                 -15.6 → -32.8 |
| Apt3 Am                                    |                  -47.9 → -73.1 |                 -45.3 → -69.7 |                   7.3 → -7.8 |                  -9.0 → -26.8 |
| Uhiea Davison                              |                  -47.9 → -63.1 |                 -50.2 → -63.8 |                -12.5 → -24.7 |                 -22.8 → -36.0 |
| Dvarf                                      |                  -48.0 → -72.6 |                 -45.3 → -68.9 |                -10.5 → -27.3 |                 -18.2 → -38.1 |
| Canary GV                                  |                  -48.1 → -73.8 |                 -40.2 → -65.1 |                -26.1 → -52.5 |                 -17.0 → -42.2 |
| Colemak-DN                                 |                  -48.2 → -69.0 |                 -36.6 → -58.2 |                 -1.3 → -23.3 |                 -10.9 → -34.1 |
| 16 Maks                                    |                  -48.2 → -81.2 |                 -49.7 → -83.6 |                -38.1 → -67.8 |                 -34.4 → -67.1 |
| Really?                                    |                  -48.3 → -67.6 |                 -47.4 → -66.7 |                -10.3 → -33.3 |                 -13.9 → -36.6 |
| Hands Down Alt                             |                  -48.5 → -68.3 |                 -47.2 → -63.4 |                -18.5 → -39.4 |                 -26.5 → -45.2 |
| Phonkie                                    |                  -48.5 → -68.9 |                 -44.6 → -62.8 |                   7.2 → -8.6 |                 -12.6 → -30.1 |
| Minred2                                    |                  -48.6 → -71.9 |                 -43.0 → -61.4 |                -11.5 → -35.1 |                 -17.6 → -37.4 |
| APTv3                                      |                  -48.6 → -73.9 |                 -45.3 → -69.7 |                   6.8 → -8.3 |                  -8.7 → -26.4 |
| Handymak                                   |                  -48.7 → -68.7 |                 -47.0 → -67.4 |                -33.7 → -56.3 |                 -33.5 → -56.7 |
| Moyaimak                                   |                  -48.7 → -65.1 |                 -44.0 → -60.0 |                   4.6 → -8.8 |                  -6.9 → -21.5 |
| AdNW                                       |                  -48.7 → -71.0 |                 -51.0 → -71.6 |                 -4.1 → -17.3 |                  -8.0 → -20.6 |
| Dsend Thumbshift                           |                  -48.7 → -66.4 |                 -50.1 → -66.1 |                -13.6 → -30.5 |                 -15.8 → -31.3 |
| Embizone Mod Ian                           |                  -48.7 → -68.1 |                 -44.6 → -61.7 |                -12.0 → -26.9 |                 -22.9 → -38.1 |
| Hexalgram                                  |                  -49.6 → -69.0 |                 -44.9 → -63.4 |                -37.0 → -55.0 |                 -32.0 → -50.4 |
| Canary Pow 123                             |                  -49.6 → -77.9 |                 -43.9 → -70.5 |                -35.5 → -64.5 |                 -27.5 → -55.3 |
| Arensito Kinesis                           |                  -49.8 → -76.5 |                 -54.2 → -81.8 |                -40.3 → -67.6 |                 -48.1 → -77.4 |
| Minred                                     |                  -50.0 → -67.3 |                 -48.2 → -64.0 |                 -0.9 → -14.5 |                 -17.7 → -32.4 |
| Arensito                                   |                  -50.2 → -78.9 |                 -43.6 → -72.2 |                -38.3 → -66.5 |                 -37.4 → -67.6 |
| Colemak                                    |                  -50.4 → -72.0 |                 -47.8 → -70.4 |                -35.7 → -53.7 |                 -30.3 → -49.6 |
| Culemak                                    |                  -50.6 → -72.1 |                 -47.2 → -69.9 |                -34.6 → -52.6 |                 -29.8 → -49.1 |
| Hands On (ErgoDox)                         |                  -50.6 → -66.4 |                 -58.4 → -72.8 |                -42.1 → -63.5 |                 -45.4 → -64.0 |
| Wreath                                     |                  -50.7 → -76.5 |                 -45.2 → -69.0 |                  3.1 → -14.9 |                 -12.0 → -31.3 |
| Asthl                                      |                  -50.9 → -70.4 |                 -60.0 → -79.9 |                -14.4 → -35.0 |                 -28.7 → -49.4 |
| Hands Down Alt (KLAnext)                   |                  -50.9 → -66.8 |                 -41.2 → -56.5 |                -27.0 → -48.7 |                 -26.4 → -46.2 |
| Boo 20211119                               |                  -51.1 → -76.0 |                 -45.6 → -67.9 |                 -4.8 → -31.4 |                 -17.5 → -42.6 |
| Colemak-DHv                                |                  -51.1 → -74.1 |                 -52.1 → -74.8 |                -32.6 → -55.8 |                 -32.2 → -55.4 |
| INTS                                       |                  -51.1 → -79.1 |                 -50.2 → -77.7 |                  0.8 → -24.6 |                 -19.6 → -46.4 |
| Burroughs Bower (typewriter) configuration |                  -51.1 → -74.3 |                 -49.4 → -73.1 |                -42.5 → -63.4 |                 -45.2 → -68.4 |
| Optimal Trigram                            |                  -51.2 → -69.8 |                 -51.8 → -70.3 |                   9.4 → -2.9 |                  -7.0 → -21.1 |
| Colemak H                                  |                  -51.2 → -71.2 |                 -48.9 → -69.3 |                -32.7 → -54.6 |                 -27.5 → -48.5 |
| Capewell                                   |                  -51.2 → -76.4 |                 -47.3 → -73.3 |                -35.7 → -65.1 |                 -40.7 → -69.7 |
| Middlephobia                               |                  -51.2 → -73.5 |                 -48.1 → -69.6 |                 -2.8 → -19.2 |                 -13.7 → -31.9 |
| Rollmak                                    |                  -51.3 → -76.2 |                 -48.6 → -72.5 |                -24.0 → -46.5 |                 -21.1 → -44.0 |
| Semimak JQ                                 |                  -51.6 → -68.3 |                 -43.5 → -61.5 |                 -0.1 → -21.1 |                  -8.8 → -30.4 |
| Hirou                                      |                  -51.6 → -68.4 |                 -59.8 → -77.1 |                -34.4 → -56.0 |                 -33.7 → -54.7 |
| Aptsym                                     |                  -51.7 → -77.4 |                 -52.6 → -80.5 |                -21.9 → -42.1 |                 -20.1 → -41.3 |
| Shai                                       |                  -51.9 → -71.6 |                 -49.6 → -69.5 |                -34.5 → -56.5 |                 -28.8 → -49.6 |
| Chendan Cmu Qawzxcv                        |                  -51.9 → -68.4 |                 -47.8 → -65.5 |                -23.2 → -45.6 |                 -26.0 → -48.4 |
| Colemak Mod DH                             |                  -51.9 → -72.0 |                 -49.2 → -69.5 |                -30.6 → -52.1 |                 -27.1 → -48.3 |
| Nirvana Opt                                |                  -52.0 → -70.4 |                 -61.3 → -79.1 |                -26.4 → -44.2 |                 -37.3 → -55.3 |
| Colemak-DH Angle                           |                  -52.1 → -72.1 |                 -49.1 → -69.5 |                -31.6 → -53.1 |                 -27.4 → -48.4 |
| X1 Atreus 44 Keys                          |                  -52.1 → -63.9 |                 -57.5 → -69.4 |                -25.7 → -36.8 |                 -41.1 → -53.6 |
| Ruthenium                                  |                  -52.2 → -75.7 |                 -40.2 → -60.9 |                  1.3 → -15.6 |                  -5.6 → -23.3 |
| Ace Vim Test                               |                  -52.3 → -78.1 |                 -47.4 → -71.4 |                 -9.3 → -31.6 |                 -18.5 → -41.5 |
| Kyu Vanilla                                |                  -52.3 → -70.5 |                 -45.1 → -62.7 |                 -0.8 → -15.2 |                 -13.0 → -27.5 |
| RL Eai                                     |                  -52.3 → -87.0 |                 -40.8 → -70.2 |                 10.0 → -15.7 |                  -3.6 → -28.7 |
| RTNA                                       |                  -52.3 → -82.3 |                 -47.4 → -77.1 |                -25.5 → -59.2 |                 -31.0 → -64.9 |
| Nerbs                                      |                  -52.4 → -71.7 |                 -45.0 → -62.8 |                   7.6 → -6.5 |                  -5.1 → -20.0 |
| Colemak Asrt Mod Hazaskull                 |                  -52.4 → -78.0 |                 -49.0 → -74.6 |                -35.7 → -56.5 |                 -31.1 → -53.0 |
| Colemak-DH                                 |                  -52.4 → -72.5 |                 -49.8 → -70.2 |                -32.2 → -53.7 |                 -27.7 → -48.7 |
| Maplefyre                                  |                  -52.5 → -71.8 |                 -47.6 → -66.0 |                -13.4 → -31.1 |                 -16.4 → -35.4 |
| Weltsch                                    |                  -52.7 → -69.2 |                 -41.3 → -58.2 |                -15.9 → -37.2 |                 -14.4 → -35.3 |
| Sind                                       |                  -52.8 → -79.4 |                 -51.4 → -76.2 |                -11.4 → -37.5 |                 -19.9 → -46.6 |
| Chendan Cmu Qawzxc                         |                  -52.9 → -69.5 |                 -48.5 → -66.2 |                -22.0 → -45.1 |                 -25.5 → -48.3 |
| Carbyne (cyanophage)                       |                  -53.0 → -66.8 |                 -44.1 → -58.0 |                -15.3 → -34.3 |                 -15.9 → -33.8 |
| Asrt DH                                    |                  -53.1 → -69.0 |                 -47.8 → -64.3 |                -25.6 → -47.3 |                 -30.8 → -52.2 |
| Handson Ui V2                              |                  -53.3 → -73.3 |                 -51.2 → -71.9 |                -49.2 → -70.6 |                 -40.9 → -61.2 |
| Colemak VCP                                |                  -53.4 → -73.6 |                 -53.7 → -73.5 |                -33.1 → -54.5 |                 -33.2 → -53.4 |
| STNC FHM                                   |                  -53.4 → -80.9 |                 -44.6 → -68.7 |                 -7.4 → -28.9 |                 -15.9 → -37.9 |
| Programmer Colemak                         |                  -53.6 → -75.2 |                 -51.9 → -74.8 |                -38.9 → -57.0 |                 -34.7 → -54.2 |
| Austenmak                                  |                  -53.7 → -76.8 |                 -57.4 → -78.9 |                -19.0 → -39.8 |                 -29.7 → -48.8 |
| Uiy N Ansi Maks                            |                  -53.7 → -70.8 |                 -50.0 → -66.4 |                -28.2 → -41.4 |                 -31.1 → -44.4 |
| Beesechurger                               |                  -53.7 → -81.3 |                 -49.4 → -77.4 |                -26.3 → -58.4 |                 -25.6 → -57.2 |
| Juyanith                                   |                  -53.7 → -70.6 |                 -45.7 → -62.1 |                 -9.0 → -25.7 |                 -10.4 → -26.9 |
| Karrenbauer Oulasvirta Mod Ian             |                  -53.8 → -64.9 |                 -65.9 → -77.1 |                -50.2 → -61.4 |                 -62.3 → -74.2 |
| Castra                                     |                  -53.8 → -76.3 |                 -52.4 → -77.4 |                 -9.4 → -32.2 |                 -12.9 → -35.7 |
| Anrt                                       |                  -53.9 → -77.7 |                 -59.0 → -81.7 |                -18.8 → -45.1 |                 -29.1 → -54.0 |
| Dvorky                                     |                  -54.1 → -75.3 |                 -55.6 → -73.4 |                  2.9 → -11.3 |                 -11.3 → -25.5 |
| Maya                                       |                  -54.1 → -74.1 |                 -46.8 → -64.9 |                   9.5 → -5.2 |                  -4.7 → -20.0 |
| Soul                                       |                  -54.1 → -73.0 |                 -53.2 → -73.2 |                -29.5 → -53.1 |                 -31.0 → -54.2 |
| S2 Klopt                                   |                  -54.3 → -71.3 |                 -52.8 → -67.1 |                 -3.5 → -16.2 |                 -14.8 → -27.1 |
| Engram (ES)                                |                  -54.3 → -76.2 |                 -59.6 → -80.2 |                -47.0 → -74.9 |                 -41.6 → -65.0 |
| Adnw (KLAnext)                             |                  -54.4 → -74.4 |                 -54.3 → -73.2 |                -11.8 → -24.9 |                 -17.0 → -29.7 |
| UCIEA                                      |                  -54.4 → -66.5 |                 -42.3 → -53.8 |                -22.3 → -43.1 |                 -19.5 → -37.3 |
| My Life For Aeir                           |                  -54.5 → -78.8 |                 -42.1 → -60.6 |                 -7.0 → -26.7 |                  -8.7 → -25.8 |
| Beakl49                                    |                  -54.6 → -73.0 |                 -47.5 → -64.4 |                -30.5 → -44.6 |                 -27.5 → -42.3 |
| Codemak                                    |                  -54.6 → -76.3 |                 -53.6 → -76.7 |                -39.8 → -58.0 |                 -35.9 → -55.6 |
| Nitrogen                                   |                  -54.6 → -73.9 |                 -46.9 → -65.2 |                 -2.7 → -16.4 |                  -9.8 → -23.6 |
| MTGAP-T                                    |                  -54.8 → -78.1 |                 -53.4 → -73.7 |                 -4.0 → -18.0 |                 -10.4 → -26.3 |
| Colemak Mod Fox                            |                  -54.9 → -78.0 |                 -54.7 → -78.9 |                -35.7 → -55.0 |                 -35.5 → -56.4 |
| Sent                                       |                  -55.0 → -78.5 |                 -45.2 → -65.9 |                 -3.0 → -25.0 |                 -10.4 → -31.1 |
| Uciea Keyboard                             |                  -55.1 → -67.2 |                 -44.6 → -56.1 |                -23.1 → -43.8 |                 -21.5 → -39.3 |
| KOY                                        |                  -55.1 → -74.7 |                 -56.0 → -74.9 |                -13.1 → -27.5 |                 -14.3 → -27.6 |
| Sclarb                                     |                  -55.1 → -72.3 |                 -51.7 → -68.5 |                -31.1 → -44.4 |                 -36.2 → -50.7 |
| Ashe                                       |                  -55.1 → -84.1 |                 -60.0 → -90.7 |                -48.1 → -75.4 |                 -51.7 → -81.2 |
| Gallium Colstag                            |                  -55.1 → -75.1 |                 -44.1 → -61.9 |                   9.0 → -4.9 |                  -3.2 → -18.0 |
| Culemak Mod Ian HP                         |                  -55.2 → -76.1 |                 -51.1 → -73.5 |                -32.3 → -50.8 |                 -29.6 → -49.7 |
| Colemak Estonian                           |                  -55.3 → -77.1 |                 -51.3 → -74.3 |                -35.8 → -54.0 |                 -31.3 → -50.9 |
| Gallium Angle                              |                  -55.3 → -72.8 |                 -47.0 → -62.8 |                  7.4 → -10.0 |                  -5.4 → -22.6 |
| Kirana Melayu                              |                  -55.4 → -81.6 |                 -57.7 → -83.5 |                -52.3 → -73.3 |                 -56.8 → -79.4 |
| Rhea                                       |                  -55.4 → -77.1 |                 -47.4 → -65.4 |                 -2.5 → -23.2 |                 -12.1 → -31.3 |
| Celestial (KLAnext)                        |                  -55.5 → -82.4 |                 -45.0 → -70.6 |                  1.2 → -22.3 |                  -8.8 → -31.4 |
| Eka                                        |                  -55.5 → -75.0 |                 -42.8 → -60.6 |                  6.3 → -16.0 |                  -6.7 → -28.1 |
| Bone                                       |                  -55.6 → -82.0 |                 -52.2 → -76.4 |                -42.9 → -64.1 |                 -53.2 → -74.8 |
| Gallium                                    |                  -55.6 → -72.6 |                 -47.3 → -62.8 |                   7.0 → -9.9 |                  -6.0 → -22.7 |
| Beakl Stretch                              |                  -55.7 → -78.2 |                 -63.3 → -84.0 |                -37.8 → -53.9 |                 -47.7 → -65.0 |
| Adnw English Bigram                        |                  -55.9 → -76.2 |                 -48.6 → -64.5 |                -12.2 → -26.5 |                 -10.9 → -23.5 |
| Focal                                      |                  -56.0 → -74.2 |                 -44.5 → -60.8 |                 -3.1 → -25.8 |                  -8.3 → -29.7 |
| Sturdy Anglemod                            |                  -56.1 → -79.0 |                 -43.8 → -63.8 |                  4.9 → -16.4 |                  -3.4 → -23.9 |
| Bone (ß in the home row)                   |                  -56.1 → -82.7 |                 -52.3 → -76.7 |                -43.0 → -64.3 |                 -53.2 → -74.8 |
| Vylet                                      |                  -56.3 → -80.2 |                 -52.2 → -76.3 |                  1.1 → -13.2 |                 -13.9 → -31.2 |
| Dvimcat                                    |                  -56.3 → -85.0 |                 -42.7 → -68.3 |                 -0.1 → -19.8 |                  -7.2 → -27.0 |
| Asset (KLA)                                |                  -56.3 → -77.3 |                 -60.2 → -82.5 |                -56.0 → -77.4 |                 -52.4 → -75.4 |
| Real 2                                     |                  -56.4 → -87.7 |                 -45.5 → -73.8 |                 -5.8 → -30.0 |                 -10.9 → -33.4 |
| Tarmak 3 (ETR)                             |                  -56.5 → -80.8 |                 -61.2 → -87.7 |               -79.0 → -105.3 |                 -62.8 → -90.0 |
| Colemak Cub                                |                  -56.5 → -80.0 |                 -54.6 → -78.6 |                -41.2 → -60.2 |                 -35.7 → -55.3 |
| Hands On (sym)                             |                  -56.6 → -70.9 |                 -57.1 → -70.3 |                -44.0 → -66.9 |                 -45.9 → -65.2 |
| Colibius August                            |                  -56.8 → -73.7 |                 -48.0 → -61.9 |                -20.4 → -41.1 |                 -23.8 → -42.0 |
| Colemak Mod JPH                            |                  -56.8 → -78.8 |                 -56.7 → -78.7 |               -93.4 → -113.3 |                 -77.4 → -97.8 |
| Noctum                                     |                  -56.8 → -77.4 |                 -45.2 → -64.3 |                  6.5 → -14.8 |                  -7.2 → -28.6 |
| Sturdy                                     |                  -56.9 → -79.8 |                 -43.6 → -63.7 |                  4.6 → -16.7 |                  -3.4 → -23.9 |
| Colemak Textblade                          |                  -57.1 → -78.5 |                 -58.5 → -80.8 |                -42.2 → -60.8 |                 -42.6 → -61.6 |
| STNDC                                      |                  -57.1 → -80.9 |                 -49.3 → -71.4 |                 -4.5 → -27.4 |                 -12.9 → -35.1 |
| Gemini                                     |                  -57.4 → -82.1 |                 -47.6 → -70.6 |                  3.9 → -17.2 |                  -4.1 → -25.2 |
| Fire                                       |                  -57.4 → -80.2 |                 -47.6 → -68.0 |                  3.4 → -14.6 |                  -5.3 → -24.9 |
| Tarmak 4 (ETRO)                            |                  -57.5 → -79.5 |                 -54.9 → -78.7 |                -60.5 → -82.6 |                 -53.6 → -77.7 |
| Paw177 Mod Ian                             |                  -57.5 → -76.2 |                 -50.8 → -68.1 |                -12.7 → -29.1 |                 -13.1 → -31.4 |
| Lela Rus                                   |                  -57.5 → -81.8 |                 -46.9 → -69.1 |                  0.4 → -21.5 |                  -8.0 → -29.2 |
| Hands Down Polyglot (sym)                  |                  -57.9 → -78.2 |                 -50.2 → -70.1 |                -24.7 → -42.3 |                 -26.4 → -44.9 |
| Flame                                      |                  -58.0 → -84.0 |                 -46.3 → -69.2 |                 -1.5 → -25.7 |                  -8.0 → -30.3 |
| Beakl 4 Mod Ian 1                          |                  -58.1 → -75.3 |                 -52.4 → -67.5 |                -13.3 → -27.3 |                 -23.0 → -36.6 |
| Asset                                      |                  -58.1 → -78.6 |                 -58.2 → -80.5 |                -53.7 → -75.1 |                 -49.5 → -72.6 |
| Flame (KLAnext)                            |                  -58.2 → -83.9 |                 -44.8 → -67.0 |                 -0.4 → -24.1 |                  -5.5 → -27.3 |
| Solemak                                    |                  -58.2 → -78.3 |                 -54.6 → -75.8 |                -31.4 → -54.6 |                 -34.2 → -57.9 |
| Colemak Lite                               |                  -58.4 → -78.3 |                 -64.5 → -84.9 |                -29.9 → -49.5 |                 -35.1 → -55.0 |
| Colibius August Mod Ian                    |                  -58.4 → -77.6 |                 -54.1 → -70.9 |                -32.9 → -49.7 |                 -32.7 → -48.9 |
| Boo                                        |                  -58.4 → -84.3 |                 -51.3 → -73.7 |                 -8.1 → -34.8 |                 -19.2 → -44.5 |
| Asrt                                       |                  -58.6 → -77.7 |                 -55.1 → -75.8 |                -36.9 → -55.4 |                 -36.3 → -56.6 |
| Semimak                                    |                  -58.6 → -77.5 |                 -51.2 → -72.4 |                 -0.3 → -21.3 |                  -9.4 → -31.3 |
| Ruthenium NL                               |                  -58.8 → -80.4 |                 -53.2 → -72.6 |                 -1.2 → -18.0 |                 -13.3 → -30.5 |
| Righty                                     |                  -58.8 → -77.1 |                 -60.7 → -76.8 |                -45.9 → -60.7 |                 -46.5 → -62.0 |
| Rukia                                      |                  -58.8 → -80.6 |                 -53.5 → -75.2 |                -30.9 → -56.4 |                 -30.2 → -55.3 |
| Vu Keys                                    |                  -58.9 → -74.4 |                 -53.9 → -68.6 |                -37.1 → -55.7 |                 -36.8 → -54.1 |
| Nila                                       |                  -59.0 → -80.3 |                 -55.7 → -74.9 |                  1.4 → -16.1 |                 -13.7 → -31.1 |
| Blaze                                      |                  -59.0 → -87.7 |                 -47.7 → -74.0 |                 -0.3 → -21.8 |                  -8.8 → -31.9 |
| Ough                                       |                  -59.1 → -71.5 |                 -67.7 → -79.8 |                -36.2 → -49.7 |                 -47.7 → -61.4 |
| Lela                                       |                  -59.1 → -90.7 |                 -50.7 → -81.2 |                  1.6 → -21.9 |                  -9.7 → -35.1 |
| Hydrogen                                   |                  -59.1 → -81.7 |                 -50.3 → -69.8 |                  5.0 → -11.1 |                  -9.7 → -27.5 |
| Colevim                                    |                  -59.3 → -83.3 |                 -59.8 → -83.9 |                -37.1 → -61.0 |                 -32.6 → -56.0 |
| Optimal Digram                             |                  -59.3 → -79.2 |                 -49.8 → -65.3 |                -16.1 → -30.0 |                 -12.8 → -24.9 |
| Hands Down Alt (ortho)                     |                  -59.4 → -75.0 |                 -54.4 → -67.9 |                -25.3 → -45.5 |                 -35.6 → -52.7 |
| Stndc (KLAnext)                            |                  -59.6 → -83.8 |                 -50.8 → -73.3 |                 -9.5 → -32.4 |                 -15.0 → -37.3 |
| Blaze (KLAnext)                            |                  -59.7 → -88.3 |                 -47.7 → -74.0 |                  1.0 → -20.5 |                  -7.8 → -30.9 |
| Dhorf (KLAnext)                            |                  -59.9 → -81.1 |                 -51.5 → -71.0 |                 -3.5 → -27.6 |                  -8.7 → -31.8 |
| Rolll                                      |                  -59.9 → -84.9 |                 -49.0 → -72.5 |                 -3.3 → -19.3 |                  -8.2 → -25.8 |
| Poutea                                     |                  -60.1 → -80.2 |                 -54.6 → -73.1 |                -48.6 → -68.9 |                 -44.6 → -64.4 |
| Hands Down XKCD                            |                  -60.2 → -88.9 |                 -49.9 → -75.2 |                -54.7 → -89.2 |                 -54.4 → -86.7 |
| Dangvu                                     |                  -60.3 → -75.5 |                 -55.0 → -69.2 |                -42.5 → -60.2 |                 -41.1 → -57.7 |
| S-Roll                                     |                  -60.3 → -86.6 |                 -47.9 → -69.7 |                  5.1 → -12.5 |                  -8.0 → -26.5 |
| Recurva                                    |                  -60.3 → -90.1 |                 -51.3 → -79.1 |                 -3.9 → -26.3 |                 -12.2 → -35.7 |
| Chendan Cmu Punctuation                    |                  -60.4 → -88.8 |                 -49.7 → -77.9 |                -21.9 → -46.1 |                 -25.9 → -51.5 |
| Another Method Non                         |                  -60.5 → -89.7 |                 -56.5 → -80.8 |                -36.0 → -52.9 |                 -34.6 → -52.0 |
| Celestial                                  |                  -60.5 → -91.1 |                 -46.8 → -73.3 |                 -3.8 → -28.4 |                 -10.5 → -33.1 |
| Oistd                                      |                  -60.7 → -87.6 |                 -65.5 → -93.7 |                -34.7 → -55.3 |                 -38.8 → -61.9 |
| Colemaq (KLAnext)                          |                  -60.8 → -84.5 |                 -56.2 → -79.6 |                -32.4 → -55.4 |                 -32.8 → -55.9 |
| Rolll (genkey)                             |                  -60.9 → -88.1 |                 -50.3 → -74.0 |                 -3.9 → -23.2 |                  -9.2 → -27.6 |
| Chendan Cmu ZXCV                           |                  -60.9 → -77.5 |                 -59.5 → -76.8 |                -40.8 → -59.0 |                 -40.1 → -59.1 |
| Wordslow SF                                |                  -60.9 → -82.9 |                 -62.3 → -83.2 |                 -6.6 → -25.4 |                 -22.4 → -40.9 |
| Colemaq                                    |                  -61.0 → -84.8 |                 -56.5 → -79.9 |                -33.4 → -56.4 |                 -33.1 → -56.2 |
| Xenia                                      |                  -61.2 → -96.6 |                 -54.4 → -88.6 |                  2.4 → -21.2 |                 -13.2 → -39.4 |
| Colman                                     |                  -61.3 → -89.0 |                 -53.1 → -80.9 |                -26.8 → -50.1 |                 -32.3 → -57.5 |
| Colemaq-F                                  |                  -61.3 → -85.3 |                 -56.0 → -79.8 |                -31.2 → -54.1 |                 -32.2 → -55.4 |
| Balanced                                   |                  -61.6 → -85.3 |                 -64.8 → -86.9 |                -32.6 → -58.4 |                 -41.7 → -66.4 |
| Dhorf                                      |                  -61.6 → -83.6 |                 -52.1 → -72.5 |                 -3.8 → -26.0 |                  -9.9 → -31.4 |
| Hands On                                   |                  -61.9 → -76.2 |                 -59.3 → -73.0 |                -47.8 → -70.9 |                 -46.8 → -66.9 |
| Noctum (KLAnext)                           |                  -62.0 → -82.4 |                 -53.1 → -71.2 |                 -1.4 → -16.7 |                 -13.6 → -29.6 |
| Uiy G Ansi Maks                            |                  -62.2 → -81.0 |                 -57.2 → -75.1 |                -39.5 → -53.8 |                 -42.0 → -56.8 |
| N Ansi Maks                                |                  -62.3 → -84.5 |                 -61.2 → -80.0 |                -15.6 → -27.7 |                 -23.5 → -36.8 |
| Stronk                                     |                  -62.4 → -85.2 |                 -49.0 → -70.1 |                 -5.1 → -25.7 |                  -9.2 → -31.3 |
| Ali Kian                                   |                  -62.4 → -75.6 |                 -69.7 → -82.5 |                -67.1 → -77.5 |                 -58.2 → -69.2 |
| Thallium                                   |                  -62.6 → -81.3 |                 -52.8 → -72.4 |                 -6.5 → -23.8 |                  -9.2 → -27.7 |
| BvoFRak EN V0.5                            |                  -62.6 → -80.8 |                 -60.3 → -76.0 |                -36.0 → -53.9 |                 -35.1 → -50.9 |
| Synth                                      |                  -62.7 → -94.3 |                 -57.3 → -86.8 |                 -1.3 → -23.3 |                 -12.2 → -35.2 |
| Aehi                                       |                  -63.0 → -81.5 |                 -61.4 → -77.6 |                -22.9 → -38.0 |                 -24.8 → -39.9 |
| Bubbletea                                  |                  -63.0 → -76.8 |                 -55.6 → -69.4 |                -57.8 → -80.6 |                 -48.9 → -69.5 |
| Xsvmtkrnl Fhy                              |                  -63.3 → -84.6 |                 -57.6 → -76.4 |                  4.8 → -11.4 |                 -11.9 → -28.7 |
| Argon                                      |                  -63.5 → -89.2 |                 -53.1 → -74.4 |                 -0.8 → -18.6 |                 -12.6 → -30.8 |
| Hands Down Alt (sym)                       |                  -63.5 → -79.3 |                 -56.8 → -71.3 |                -30.9 → -52.8 |                 -33.6 → -52.8 |
| SHZ                                        |                  -63.6 → -85.8 |                 -65.7 → -85.4 |                -31.1 → -49.0 |                 -40.5 → -58.8 |
| Zsvmtjrnl Fkhy                             |                  -63.8 → -85.1 |                 -57.1 → -76.1 |                  5.1 → -11.2 |                 -10.8 → -27.0 |
| Flare (KLAnext)                            |                  -63.8 → -91.2 |                 -54.1 → -78.4 |                 -2.7 → -27.2 |                 -10.5 → -33.9 |
| Astarte                                    |                  -63.9 → -81.8 |                 -65.0 → -81.9 |                -40.7 → -64.4 |                 -46.9 → -68.7 |
| G Ansi Maks                                |                  -64.0 → -85.7 |                 -62.8 → -81.1 |                -24.5 → -38.8 |                 -33.7 → -48.5 |
| Mine                                       |                  -64.2 → -92.1 |                 -56.3 → -82.2 |                -35.1 → -56.2 |                 -43.0 → -63.4 |
| Nrstmak                                    |                  -64.2 → -91.0 |                 -55.0 → -77.9 |                -12.0 → -29.6 |                 -18.7 → -38.0 |
| Beakl Hm1 Mod Ian                          |                  -64.5 → -83.2 |                 -72.5 → -90.2 |                -53.0 → -74.0 |                 -64.9 → -85.7 |
| Noted                                      |                  -64.5 → -88.3 |                 -58.9 → -80.1 |                -31.8 → -47.7 |                 -34.7 → -49.4 |
| Rain                                       |                  -64.7 → -92.0 |                 -55.8 → -81.9 |                 -2.0 → -23.3 |                 -12.7 → -36.2 |
| Nitro S                                    |                  -64.9 → -87.4 |                 -54.0 → -74.2 |                 -2.3 → -20.6 |                 -14.6 → -34.4 |
| Rain (KLAnext)                             |                  -65.1 → -91.0 |                 -54.8 → -79.2 |                 -3.0 → -21.6 |                 -10.9 → -31.1 |
| Freq3                                      |                  -65.2 → -86.1 |                 -59.8 → -79.8 |                -13.3 → -32.5 |                 -20.0 → -40.2 |
| Em0gus                                     |                  -65.3 → -94.6 |                 -54.2 → -79.4 |                 -2.1 → -26.8 |                 -10.1 → -33.4 |
| Setrain                                    |                  -65.5 → -86.7 |                 -55.2 → -74.7 |                  2.7 → -16.0 |                 -10.2 → -29.8 |
| Stance                                     |                  -65.8 → -91.0 |                 -55.4 → -76.6 |                 -8.5 → -32.4 |                 -18.2 → -40.1 |
| Iaenh                                      |                  -65.8 → -84.2 |                 -62.7 → -81.3 |                -59.9 → -76.3 |                 -54.8 → -73.2 |
| Minimotion                                 |                  -65.8 → -82.5 |                 -65.5 → -78.7 |                -33.5 → -46.5 |                 -35.1 → -47.1 |
| Beakl421 Mod Ian                           |                  -66.1 → -81.2 |                 -56.6 → -71.1 |                -15.3 → -28.6 |                 -21.7 → -35.8 |
| Hrnia                                      |                 -66.1 → -101.1 |                 -67.2 → -97.4 |                -39.1 → -63.7 |                 -47.4 → -74.0 |
| Uciea Vanilla                              |                  -66.1 → -81.7 |                 -54.4 → -68.6 |                -27.8 → -51.6 |                 -21.6 → -40.3 |
| Seht Drai                                  |                  -66.3 → -97.2 |                 -64.9 → -97.7 |                 -6.2 → -39.4 |                 -21.3 → -55.8 |
| Atreyata                                   |                  -66.4 → -86.3 |                 -57.5 → -77.5 |                -37.9 → -60.0 |                 -30.4 → -51.3 |
| Rotsw                                      |                  -66.4 → -85.8 |                 -72.1 → -91.2 |                -74.3 → -91.4 |                 -69.5 → -87.1 |
| Colemak HU                                 |                  -66.5 → -87.9 |                 -55.1 → -76.1 |                -38.2 → -58.4 |                 -34.9 → -55.8 |
| Vimak                                      |                  -66.5 → -88.6 |                 -64.1 → -87.0 |                -36.1 → -59.5 |                 -34.8 → -58.5 |
| Romberg                                    |                  -66.6 → -84.8 |                 -75.1 → -94.6 |               -89.4 → -110.5 |                -80.8 → -104.0 |
| Ttast                                      |                  -66.6 → -99.2 |                -71.8 → -105.6 |                -55.1 → -84.3 |                 -58.6 → -91.5 |
| Snorkle                                    |                 -66.7 → -101.5 |                 -62.5 → -95.7 |                 -7.2 → -37.3 |                 -16.7 → -46.8 |
| Doerak                                     |                  -66.7 → -87.3 |                 -63.7 → -85.0 |                -44.4 → -66.6 |                 -46.3 → -68.2 |
| Balance 12                                 |                  -66.8 → -84.6 |                 -41.5 → -57.9 |                -23.7 → -38.9 |                 -18.0 → -33.5 |
| Flare                                      |                  -66.8 → -92.0 |                 -56.7 → -79.3 |                 -1.8 → -26.0 |                  -9.4 → -32.6 |
| Whorf Am                                   |                  -66.8 → -91.9 |                 -55.1 → -79.0 |                 -1.4 → -25.9 |                 -12.1 → -37.5 |
| Code Weaver                                |                  -67.3 → -88.7 |                 -58.8 → -81.5 |                -50.7 → -78.9 |                 -47.9 → -75.8 |
| Whorf                                      |                  -67.4 → -92.6 |                 -55.3 → -79.3 |                  0.3 → -23.9 |                 -11.1 → -36.3 |
| Lumin                                      |                  -67.4 → -94.6 |                 -47.6 → -70.8 |                -12.1 → -35.2 |                 -14.4 → -35.9 |
| Phynnboi                                   |                  -67.4 → -81.1 |                 -69.7 → -81.7 |                -33.8 → -45.6 |                 -40.2 → -52.1 |
| Colemak DH Ring 20211116                   |                  -67.4 → -89.8 |                 -60.7 → -84.0 |                -33.6 → -55.5 |                 -33.7 → -57.3 |
| Acemak 1                                   |                  -67.5 → -91.1 |                 -64.5 → -89.5 |                -47.7 → -68.0 |                 -44.7 → -66.4 |
| Real                                       |                  -67.7 → -89.7 |                 -50.9 → -73.1 |                -11.0 → -32.4 |                 -17.8 → -39.4 |
| Workwoman                                  |                  -67.8 → -79.1 |                 -58.8 → -70.4 |                -39.0 → -57.8 |                 -32.1 → -49.2 |
| Hands Down Alt-x                           |                  -67.9 → -83.7 |                 -51.9 → -67.1 |                -29.6 → -51.2 |                 -30.5 → -50.2 |
| Trendy (KLAnext)                           |                  -68.1 → -94.7 |                 -54.8 → -75.9 |                 -3.0 → -21.6 |                  -8.0 → -26.3 |
| JPPE                                       |                  -68.2 → -92.2 |                 -65.7 → -89.6 |               -95.9 → -116.3 |                 -78.5 → -99.3 |
| Hands On (ortho)                           |                  -68.4 → -84.2 |                 -72.0 → -85.9 |                -45.5 → -65.5 |                 -54.5 → -72.1 |
| Lumin (KLAnext)                            |                  -68.7 → -95.9 |                 -48.2 → -71.3 |                -12.8 → -35.9 |                 -14.1 → -35.5 |
| Workman                                    |                  -68.9 → -97.3 |                 -67.8 → -96.5 |                -38.4 → -62.2 |                 -44.9 → -69.4 |
| Quesnel Mtgap                              |                  -68.9 → -85.3 |                 -62.4 → -78.9 |                -30.2 → -48.7 |                 -29.6 → -47.3 |
| Colemaq F                                  |                  -69.3 → -93.8 |                 -65.9 → -90.2 |                -34.1 → -57.9 |                 -35.4 → -59.1 |
| Three Vanilla                              |                  -69.5 → -87.8 |                 -71.9 → -88.9 |                -27.2 → -44.0 |                 -41.5 → -58.9 |
| Box X                                      |                  -69.5 → -86.4 |                 -69.2 → -84.6 |                -40.6 → -56.7 |                 -46.9 → -62.9 |
| Kilo 62 Vanilla                            |                  -69.7 → -88.0 |                 -66.2 → -82.7 |                -26.4 → -43.0 |                 -34.9 → -49.4 |
| Aryo                                       |                  -70.0 → -94.9 |                 -64.3 → -90.7 |                -64.0 → -85.2 |                 -57.4 → -82.9 |
| ZX 1                                       |                  -70.0 → -84.3 |                 -60.8 → -74.5 |                -47.3 → -59.9 |                 -44.4 → -57.9 |
| Dutchman                                   |                  -70.4 → -95.7 |                 -69.6 → -95.7 |                -32.1 → -55.5 |                 -37.7 → -62.5 |
| Pine (KLAnext)                             |                  -70.4 → -95.2 |                 -64.9 → -87.4 |                 -8.5 → -30.3 |                 -18.0 → -40.4 |
| Pine                                       |                  -70.5 → -95.3 |                 -64.4 → -86.9 |                 -8.6 → -30.4 |                 -18.1 → -40.4 |
| Seruxie                                    |                  -70.5 → -96.9 |                 -68.7 → -95.8 |                -41.8 → -62.8 |                 -39.3 → -61.9 |
| Hieaqmtsrn                                 |                  -70.6 → -84.7 |                 -79.8 → -94.0 |                -25.1 → -38.1 |                 -51.2 → -65.8 |
| Qwicklystep2                               |                  -70.9 → -88.2 |                -81.6 → -101.2 |                -71.6 → -92.0 |                 -66.2 → -88.0 |
| Rusk                                       |                  -71.1 → -99.7 |                -80.7 → -108.9 |                -61.8 → -87.9 |                -83.1 → -112.2 |
| Trendy                                     |                  -71.6 → -97.9 |                 -55.9 → -76.6 |                 -2.6 → -22.2 |                  -7.7 → -26.5 |
| Jyz                                        |                  -71.6 → -92.2 |                 -69.3 → -87.9 |                -29.4 → -48.8 |                 -33.3 → -51.9 |
| Workman for Programmers                    |                 -71.6 → -100.0 |                -71.8 → -100.5 |                -41.0 → -64.4 |                 -49.3 → -74.0 |
| Light Anderson Mod Ian                     |                  -71.6 → -89.0 |                 -69.0 → -85.1 |                -48.7 → -68.0 |                 -51.4 → -69.1 |
| Dvorak                                     |                  -71.7 → -87.4 |                 -74.6 → -89.1 |                -30.4 → -43.2 |                 -37.0 → -50.1 |
| Sorenk                                     |                  -71.8 → -98.3 |                 -58.8 → -81.3 |                -37.2 → -56.6 |                 -35.5 → -55.1 |
| Spanish Dvorak (Jorge Sanz)                |                  -72.3 → -85.9 |                 -74.4 → -86.5 |                -50.9 → -69.5 |                 -50.4 → -66.7 |
| Dvorak IU Swap                             |                  -72.9 → -88.6 |                 -75.5 → -89.9 |                -29.1 → -42.0 |                 -35.6 → -48.7 |
| Seht Drai (KLAnext)                        |                 -72.9 → -110.4 |                -70.0 → -107.4 |                 -5.1 → -39.0 |                 -21.0 → -55.9 |
| Eito                                       |                 -72.9 → -102.7 |                 -66.9 → -96.4 |                -24.5 → -49.9 |                 -30.3 → -55.9 |
| Qphyx Adapted                              |                  -73.0 → -85.3 |                 -57.7 → -70.0 |                -28.6 → -46.7 |                 -26.0 → -41.8 |
| OISEAU                                     |                  -73.0 → -87.6 |                 -73.8 → -87.1 |                -35.0 → -46.9 |                 -41.3 → -53.5 |
| Qwickly Nrio                               |                  -73.1 → -96.8 |                 -71.9 → -97.5 |                -40.1 → -63.4 |                 -49.5 → -75.9 |
| X7 2h                                      |                  -73.1 → -93.8 |                 -78.5 → -99.7 |               -88.7 → -108.1 |                -99.8 → -120.7 |
| Rsi Terminated Vanilla                     |                  -73.2 → -96.7 |                 -66.6 → -91.2 |                -38.4 → -62.8 |                 -37.6 → -62.9 |
| Hands Down Alt-x (ortho)                   |                  -73.2 → -89.2 |                 -64.9 → -79.5 |                -27.5 → -49.7 |                 -37.1 → -56.7 |
| Niro                                       |                  -73.6 → -96.8 |                -74.2 → -100.6 |                -41.0 → -65.6 |                 -48.5 → -75.9 |
| Adore                                      |                  -73.9 → -87.6 |                 -69.2 → -82.2 |                -72.2 → -93.7 |                 -67.5 → -88.6 |
| Vukeys Swapped Mod Ian 2                   |                  -73.9 → -90.1 |                 -82.9 → -96.6 |                -47.7 → -63.1 |                 -56.3 → -70.9 |
| BEAKL-15                                   |                  -74.0 → -94.0 |                 -71.7 → -90.0 |                -66.0 → -84.4 |                 -58.2 → -76.6 |
| Dvorak Mod Ian                             |                  -74.0 → -89.4 |                 -67.5 → -81.9 |                -31.5 → -44.1 |                 -38.9 → -51.9 |
| KHLC                                       |                  -74.1 → -85.6 |                 -66.2 → -79.0 |                -70.0 → -89.5 |                 -57.3 → -75.9 |
| Qwicklystep3                               |                  -74.1 → -97.3 |                -75.5 → -101.9 |                -49.0 → -73.5 |                 -50.9 → -77.9 |
| Dvorak-fr (Francis Leboutte)               |                  -74.1 → -95.2 |                -81.6 → -100.6 |              -113.0 → -132.9 |               -121.4 → -141.8 |
| Workman Cub                                |                 -74.3 → -104.9 |                -74.4 → -104.5 |                -44.3 → -69.0 |                 -50.7 → -75.5 |
| Minimak-12                                 |                 -74.4 → -101.6 |                -81.3 → -110.3 |               -82.6 → -107.4 |                -78.4 → -104.0 |
| Vas Keys                                   |                  -74.8 → -93.3 |                 -63.9 → -80.8 |                -40.2 → -61.2 |                 -36.2 → -56.1 |
| Hands Down Polyglot (ErgoDox)              |                  -75.1 → -93.1 |                 -68.9 → -86.9 |                -30.6 → -47.5 |                 -39.0 → -57.4 |
| Keyboardsamurai July                       |                  -75.3 → -95.0 |                -79.3 → -100.4 |                -67.3 → -83.7 |                 -55.5 → -74.0 |
| Programmer Dvorak - Ordered Numbers        |                  -75.8 → -91.5 |                 -80.1 → -94.6 |                -34.0 → -47.4 |                 -42.5 → -55.9 |
| Qwicklystep4                               |                 -75.8 → -100.3 |                -74.7 → -101.7 |                -37.7 → -61.7 |                 -46.1 → -73.5 |
| Qwickly Comma                              |                 -76.0 → -100.1 |                -75.6 → -101.9 |                -41.7 → -65.6 |                 -48.0 → -74.6 |
| Yak                                        |                 -76.4 → -102.2 |                -93.8 → -122.5 |              -102.2 → -128.6 |                -98.0 → -127.7 |
| Qwickly KZ Comma                           |                 -76.7 → -100.6 |                -76.6 → -102.9 |                -41.7 → -65.7 |                 -49.9 → -76.6 |
| Typehack                                   |                 -76.8 → -101.3 |                -78.8 → -102.0 |                -21.3 → -46.3 |                 -34.7 → -59.5 |
| Big Guyy                                   |                 -76.9 → -101.5 |                 -73.6 → -98.6 |                -41.9 → -64.9 |                 -49.3 → -74.3 |
| Chendan Cmu No Contraints                  |                 -77.0 → -108.8 |                 -68.1 → -96.4 |                -26.6 → -54.1 |                 -34.2 → -60.5 |
| Einbinder 10 Finger                        |                 -77.3 → -112.4 |                -77.5 → -113.9 |                -59.5 → -90.2 |                 -59.8 → -93.3 |
| Gelatin                                    |                  -77.6 → -96.4 |                 -73.9 → -93.2 |                -65.1 → -80.3 |                 -56.5 → -72.3 |
| EAton                                      |                  -77.8 → -96.8 |                 -79.7 → -97.2 |                -28.6 → -47.9 |                 -40.2 → -58.7 |
| Dvorak Original Numbers                    |                  -78.0 → -93.1 |                -86.5 → -100.4 |                -34.1 → -47.0 |                 -43.7 → -56.5 |
| Rusk Mod Ian                               |                 -78.4 → -107.3 |                -81.0 → -109.8 |                -65.1 → -93.1 |                -75.0 → -105.9 |
| Smartly Modified Dvorak                    |                  -79.3 → -91.6 |                 -83.6 → -94.9 |                -46.9 → -59.5 |                 -50.5 → -62.9 |
| GG Beakl 15                                |                  -79.3 → -98.9 |                 -76.6 → -94.4 |                -73.0 → -91.0 |                 -63.5 → -81.3 |
| Klausler                                   |                 -79.6 → -102.2 |                 -78.1 → -96.3 |                -34.3 → -49.0 |                 -48.3 → -62.9 |
| QWPR                                       |                 -79.9 → -104.2 |                -87.8 → -113.9 |               -83.1 → -103.4 |                 -75.7 → -96.7 |
| As In Red Hot Mod Ian                      |                 -81.5 → -102.8 |                -81.4 → -102.9 |                -67.9 → -88.5 |                 -69.4 → -91.6 |
| Svorak-r                                   |                  -81.9 → -98.7 |                 -78.7 → -93.3 |                -36.5 → -49.1 |                 -39.4 → -52.0 |
| Capewell-Dvorak                            |                 -82.4 → -101.1 |                 -77.9 → -95.7 |                -34.5 → -52.3 |                 -42.1 → -61.0 |
| Autogen 1                                  |                 -83.1 → -103.9 |                -88.6 → -106.5 |                -10.5 → -28.8 |                 -34.7 → -51.4 |
| The 1                                      |                 -83.2 → -110.4 |                -75.4 → -104.2 |                -35.5 → -64.1 |                 -34.9 → -65.0 |
| JNSF                                       |                 -83.6 → -111.4 |                -87.5 → -114.9 |               -75.3 → -106.0 |                -69.7 → -100.0 |
| Hands Down Polyglot (ortho)                |                 -83.6 → -101.9 |                 -79.3 → -96.8 |                -38.4 → -55.3 |                 -45.2 → -62.0 |
| Kaeteker's Modified Dvorak                 |                 -83.8 → -102.4 |                -82.0 → -100.3 |                -39.7 → -56.3 |                 -46.4 → -65.5 |
| Halmak                                     |                 -84.1 → -109.0 |                -80.1 → -104.8 |                -34.1 → -55.0 |                 -37.4 → -58.6 |
| Arsonite                                   |                 -84.6 → -103.3 |               -103.5 → -123.7 |               -82.6 → -103.4 |                -84.0 → -105.9 |
| Minimak 8-key                              |                 -85.0 → -116.6 |                -92.3 → -126.3 |               -89.0 → -116.0 |                -87.2 → -115.9 |
| Ina DV                                     |                 -85.2 → -100.3 |                 -80.3 → -97.1 |              -125.9 → -142.3 |               -119.7 → -139.4 |
| Willems                                    |                  -85.4 → -99.9 |               -106.9 → -120.8 |                -78.8 → -97.9 |                -93.5 → -111.5 |
| Heads Up                                   |                 -85.6 → -107.6 |                -97.3 → -120.8 |                -70.3 → -90.8 |                 -74.3 → -97.3 |
| Benkeyless                                 |                 -85.6 → -108.2 |                -88.4 → -110.5 |                -77.1 → -99.4 |                 -76.5 → -98.3 |
| Ninedotnine                                |                 -86.0 → -105.8 |                -92.0 → -112.4 |               -80.9 → -101.4 |                 -78.9 → -99.7 |
| Ninedotnine Mod Ian                        |                 -86.0 → -105.2 |                -96.1 → -115.5 |               -88.6 → -108.7 |                -84.1 → -104.5 |
| Etni                                       |                 -86.1 → -123.6 |                -98.5 → -137.9 |               -87.7 → -126.6 |                -85.1 → -127.3 |
| Lowerpinky                                 |                 -86.5 → -119.9 |                -84.8 → -117.2 |                -54.5 → -82.3 |                 -56.9 → -85.3 |
| Dvorak (classic)                           |                 -86.6 → -102.7 |                -95.5 → -110.7 |                -31.1 → -44.1 |                 -38.5 → -51.4 |
| Goettl Brugh Julstrom                      |                 -87.0 → -116.7 |                -86.4 → -111.3 |                -57.7 → -76.5 |                 -62.7 → -80.3 |
| Halmak (cyanophage)                        |                 -87.5 → -111.5 |                -82.0 → -106.0 |                -34.1 → -54.2 |                 -37.1 → -57.6 |
| Frontier                                   |                 -87.5 → -116.4 |                 -64.3 → -88.6 |                -50.1 → -75.0 |                 -50.4 → -73.4 |
| X6 2h                                      |                  -87.8 → -99.3 |                -99.1 → -110.0 |              -113.9 → -124.0 |                -95.8 → -106.3 |
| Bgrassy                                    |                 -88.2 → -110.4 |                -85.1 → -108.1 |                -39.0 → -56.3 |                 -50.1 → -71.0 |
| Tarmak 2                                   |                 -88.7 → -115.8 |                -95.4 → -124.5 |              -101.0 → -128.9 |                -90.2 → -119.0 |
| Code                                       |                 -88.9 → -114.3 |                -84.1 → -110.4 |                -41.9 → -69.7 |                 -48.7 → -76.2 |
| Syperk Qwfrj                               |                 -89.5 → -116.6 |                -96.2 → -125.3 |              -100.4 → -128.2 |                -90.4 → -119.2 |
| Rstlne Manual                              |                 -90.4 → -109.7 |               -104.5 → -124.0 |               -87.6 → -109.6 |                -94.6 → -118.2 |
| Wong Oiuea                                 |                 -91.8 → -114.0 |                -90.3 → -113.6 |              -144.0 → -166.7 |               -128.9 → -151.2 |
| Workman LD                                 |                 -93.2 → -124.1 |                -79.0 → -112.4 |                -45.8 → -73.2 |                 -40.7 → -71.5 |
| Liigol                                     |                 -93.9 → -113.9 |               -101.0 → -121.7 |                -63.6 → -83.4 |                -81.8 → -102.7 |
| Alphametric                                |                 -94.7 → -107.2 |                -94.4 → -107.3 |                -54.7 → -68.9 |                 -52.8 → -67.0 |
| NTSC                                       |                 -94.7 → -112.5 |                -89.3 → -105.3 |                -49.3 → -64.5 |                 -60.1 → -75.8 |
| Heiadtsrn WFGV                             |                 -94.8 → -116.7 |                -94.1 → -112.9 |                -26.6 → -39.0 |                 -52.0 → -66.3 |
| Dnat                                       |                 -95.1 → -142.7 |                -91.7 → -137.8 |               -99.3 → -150.1 |                -95.5 → -144.4 |
| Pittard                                    |                 -95.6 → -109.9 |                -92.5 → -107.3 |               -91.9 → -108.2 |                 -81.1 → -99.6 |
| Colemak Wide                               |                 -95.6 → -120.2 |               -104.8 → -130.6 |                -46.9 → -67.1 |                 -65.1 → -86.7 |
| Tarmak 1                                   |                 -95.6 → -123.0 |               -103.3 → -133.6 |              -114.1 → -142.7 |               -103.7 → -133.8 |
| FLAW                                       |                 -96.3 → -142.4 |                -91.2 → -133.3 |                -15.2 → -48.7 |                 -33.2 → -68.4 |
| Qwerty Comfort                             |                 -96.4 → -133.2 |               -116.1 → -158.2 |              -115.3 → -155.3 |               -130.0 → -175.5 |
| JNRF                                       |                 -96.5 → -122.2 |               -109.8 → -136.9 |                -69.4 → -96.6 |                -82.4 → -110.9 |
| Colemak Mod Ian 2                          |                 -96.6 → -117.4 |                -99.5 → -119.3 |                -64.1 → -81.4 |                 -74.7 → -91.9 |
| Thumb O Board Tweaked                      |                 -97.7 → -132.0 |                -90.0 → -124.5 |                -44.8 → -77.4 |                 -63.7 → -99.2 |
| Halmak (KLAnext)                           |                 -97.7 → -120.9 |                -86.3 → -110.3 |                -58.2 → -78.3 |                 -51.0 → -73.1 |
| Liigol Mod Ian 2                           |                 -97.8 → -118.2 |                -88.6 → -109.0 |                -61.3 → -79.4 |                 -59.7 → -78.6 |
| Minimak 4key                               |                 -98.0 → -136.9 |               -105.9 → -148.3 |              -104.2 → -140.4 |               -102.6 → -141.4 |
| Hoke                                       |                 -98.6 → -119.8 |                -95.3 → -118.5 |              -104.6 → -124.0 |                -93.2 → -115.9 |
| Bsdhacker                                  |                 -98.6 → -135.3 |                -90.2 → -124.1 |                -71.8 → -96.6 |                -79.8 → -107.4 |
| German Dvorak Type II                      |                 -98.7 → -114.2 |               -100.2 → -115.5 |                -46.7 → -63.8 |                 -46.8 → -63.8 |
| Colemak-DH Wide ISO                        |                 -99.3 → -122.5 |                -91.8 → -114.3 |                -66.9 → -92.7 |                 -60.2 → -83.5 |
| Aserth                                     |                 -99.4 → -118.1 |               -118.4 → -138.6 |              -106.7 → -127.1 |               -111.3 → -134.3 |
| Tarmak 4                                   |                 -99.5 → -124.1 |                -99.5 → -125.4 |                -64.7 → -84.9 |                 -70.0 → -91.8 |
| Qwerty Row Swap                            |                -100.5 → -119.0 |               -120.9 → -142.3 |              -115.9 → -140.7 |               -119.1 → -145.8 |
| Siwei                                      |                -100.5 → -142.0 |               -115.5 → -159.0 |              -102.3 → -142.2 |               -101.5 → -146.2 |
| Cyberswarm Mod Ian                         |                -101.1 → -123.6 |               -106.4 → -129.3 |               -80.8 → -102.4 |                -89.0 → -112.7 |
| Jeff                                       |                -101.5 → -121.9 |               -105.9 → -124.9 |               -74.9 → -100.9 |                 -71.9 → -94.5 |
| Norman                                     |                -103.5 → -126.6 |               -113.6 → -138.5 |                -67.2 → -91.8 |                -81.9 → -109.4 |
| Fargas                                     |                -103.7 → -128.2 |               -113.8 → -134.6 |                -77.2 → -97.8 |               -101.5 → -122.8 |
| Qwicklystep1                               |                -105.1 → -130.5 |               -124.3 → -150.9 |              -114.2 → -141.3 |               -118.0 → -146.8 |
| Tarmak 3                                   |                -105.2 → -130.4 |               -105.4 → -132.8 |               -89.3 → -113.6 |                -93.1 → -119.8 |
| Qwerty Row Swap Mod Ian                    |                -105.5 → -124.3 |               -118.2 → -139.8 |              -105.5 → -130.5 |               -115.5 → -142.2 |
| Qwerak                                     |                -106.1 → -130.3 |                -98.3 → -121.4 |                -38.8 → -60.8 |                 -43.8 → -66.9 |
| Solemak Rightshift                         |                -106.3 → -127.7 |                -99.2 → -121.0 |               -76.1 → -101.3 |                -75.5 → -100.1 |
| Hieamtsrn Optimized                        |                -106.6 → -129.3 |               -102.8 → -123.4 |                -45.8 → -65.3 |                 -63.8 → -83.4 |
| Antibracket (on AltGr)                     |                -108.2 → -130.4 |               -107.2 → -127.1 |               -89.0 → -115.3 |                -88.8 → -112.7 |
| Tyler                                      |                -109.0 → -127.5 |               -121.8 → -139.9 |              -105.9 → -121.9 |               -123.3 → -142.5 |
| Mcgunnigle Scientific                      |                -109.2 → -135.6 |               -122.4 → -149.2 |                -75.6 → -96.3 |                -90.4 → -113.2 |
| Kumar Desai                                |                -109.6 → -133.4 |               -116.1 → -140.0 |               -93.8 → -117.2 |                -93.1 → -118.7 |
| Rstlne Ai                                  |                -109.7 → -137.1 |                -87.5 → -111.0 |              -124.8 → -153.4 |                -96.9 → -123.1 |
| Orthocarpus                                |                -109.8 → -136.5 |               -106.4 → -129.9 |                -75.3 → -96.8 |                -82.0 → -102.8 |
| Foalmak                                    |                -109.9 → -152.0 |               -106.1 → -147.2 |               -80.3 → -115.7 |                -89.5 → -128.0 |
| QGMLWY                                     |                -111.2 → -125.5 |               -106.9 → -120.8 |                -51.9 → -66.8 |                 -69.7 → -84.5 |
| CarpalxQ                                   |                -111.8 → -135.7 |               -116.7 → -142.2 |              -101.6 → -120.8 |                -87.6 → -109.5 |
| Anglian                                    |                -113.4 → -145.9 |                -99.6 → -127.9 |                -62.2 → -86.2 |                 -62.4 → -87.3 |
| Antithesis                                 |                -113.5 → -143.1 |               -105.1 → -134.1 |              -119.4 → -155.1 |               -110.2 → -143.8 |
| Carpalx (full optimization)                |                -116.2 → -132.6 |               -108.3 → -123.6 |                -59.2 → -75.4 |                 -78.3 → -94.0 |
| Capewell Qwerf                             |                -116.3 → -153.6 |               -130.7 → -169.9 |              -122.7 → -158.0 |               -123.9 → -163.4 |
| Newden Mod Ian                             |                -116.6 → -140.3 |               -110.3 → -132.0 |                -53.9 → -70.3 |                 -68.7 → -85.5 |
| Neo 2.0                                    |                -116.7 → -138.6 |               -125.8 → -148.2 |              -110.6 → -131.6 |               -111.7 → -133.1 |
| Eucalyn                                    |                -116.7 → -132.2 |               -114.1 → -130.9 |              -140.8 → -159.7 |               -128.6 → -150.4 |
| Codemakx                                   |                -117.8 → -132.6 |               -113.6 → -127.9 |                -55.9 → -70.9 |                 -76.2 → -91.4 |
| A Joy Rehomed                              |                -118.1 → -149.1 |               -106.4 → -135.3 |               -85.2 → -119.8 |                -85.1 → -117.9 |
| QGMLWY Cub                                 |                -118.8 → -134.6 |               -114.0 → -129.0 |                -57.9 → -73.7 |                 -76.0 → -91.1 |
| Savard                                     |                -119.1 → -132.8 |               -130.1 → -143.3 |                -77.6 → -96.7 |                 -76.3 → -94.0 |
| QWERFJ                                     |                -119.3 → -158.8 |               -135.3 → -176.3 |              -120.8 → -158.9 |               -127.2 → -169.8 |
| Jan                                        |                -120.7 → -144.2 |               -124.6 → -150.2 |              -107.4 → -126.4 |                -94.5 → -116.7 |
| Oatpie                                     |                -120.8 → -136.1 |               -123.9 → -141.7 |               -91.9 → -108.5 |                -98.4 → -116.6 |
| Harrison                                   |                -123.3 → -149.4 |               -124.0 → -150.6 |              -120.1 → -149.5 |               -112.8 → -142.4 |
| Ingulish v2                                |                -123.5 → -138.8 |               -133.2 → -145.9 |              -161.8 → -173.8 |               -148.9 → -161.2 |
| QGMLWB Cub                                 |                -123.7 → -141.7 |               -115.4 → -131.9 |                -65.1 → -82.4 |                -84.6 → -100.7 |
| Blick Mod Ian                              |                -123.8 → -145.2 |               -128.3 → -151.3 |               -91.3 → -112.8 |                -94.1 → -118.0 |
| Wong Poiea                                 |                -124.0 → -142.9 |               -130.3 → -149.8 |              -172.8 → -188.7 |               -149.8 → -167.1 |
| Qgmlwb Programmer                          |                -124.4 → -141.4 |               -117.3 → -133.2 |                -65.5 → -82.0 |                -87.7 → -104.1 |
| Niro Rightshift                            |                -125.3 → -152.8 |               -144.0 → -173.0 |               -93.1 → -119.4 |               -115.2 → -144.0 |
| Hein Rightshift                            |                -125.7 → -153.9 |               -130.2 → -159.3 |              -127.1 → -153.0 |               -141.0 → -168.7 |
| Ingulish                                   |                -126.6 → -144.1 |               -133.4 → -147.5 |              -125.7 → -140.8 |               -127.2 → -141.3 |
| Neo2                                       |                -126.7 → -148.4 |               -131.9 → -154.4 |              -113.4 → -133.8 |               -119.1 → -141.1 |
| Rhythmic                                   |                -126.8 → -148.4 |               -115.8 → -136.2 |                -68.8 → -90.6 |                 -72.9 → -93.5 |
| Tallus                                     |                -127.2 → -159.4 |               -145.7 → -176.3 |              -105.2 → -128.8 |               -118.4 → -142.8 |
| Widely Alternating A                       |                -127.4 → -143.5 |               -111.2 → -127.6 |                -63.8 → -79.5 |                 -70.7 → -86.7 |
| Light Anderson                             |                -127.6 → -150.1 |               -135.1 → -155.2 |              -106.3 → -126.1 |               -110.7 → -129.4 |
| Navarre 1907 (ZHJAYSCPG)                   |                -128.0 → -144.2 |               -138.3 → -156.0 |              -158.4 → -188.0 |               -172.5 → -199.6 |
| Harmony                                    |                -129.0 → -161.0 |               -133.8 → -167.4 |               -94.5 → -116.5 |               -104.8 → -129.9 |
| AZERTY (Macintosh)                         |                -129.8 → -177.1 |               -148.5 → -201.6 |              -149.0 → -198.0 |               -156.7 → -210.7 |
| Xpert                                      |                -130.0 → -155.4 |               -136.1 → -162.2 |              -143.0 → -168.8 |               -134.1 → -159.9 |
| Tahan                                      |                -130.0 → -177.3 |               -138.7 → -182.8 |              -157.5 → -219.7 |               -159.2 → -217.9 |
| Keymacs Madand                             |                -130.2 → -154.9 |               -127.7 → -153.0 |               -89.0 → -110.9 |                -97.1 → -121.1 |
| Rike                                       |                -130.4 → -156.2 |               -129.2 → -156.1 |              -136.3 → -160.2 |               -128.9 → -154.7 |
| QWERTY-SUX 1.0                             |                -130.8 → -181.4 |               -133.1 → -183.6 |              -153.8 → -195.8 |               -157.7 → -207.5 |
| Colevrak                                   |                -130.9 → -167.2 |               -135.3 → -172.4 |               -77.2 → -106.3 |               -101.1 → -134.7 |
| AZERTY fr-latin9 (legacy)                  |                -131.3 → -177.0 |               -149.6 → -201.5 |              -149.2 → -198.0 |               -156.0 → -209.9 |
| Keymacs2                                   |                -131.4 → -158.0 |               -128.9 → -155.4 |               -88.6 → -110.9 |                -99.0 → -123.6 |
| WidePDK Custom                             |                -132.1 → -150.1 |               -135.2 → -152.3 |               -94.0 → -111.5 |               -105.5 → -122.4 |
| Banaji                                     |                -133.9 → -170.9 |               -158.3 → -200.1 |              -127.6 → -167.7 |               -150.3 → -193.8 |
| CHIN                                       |                -134.1 → -159.5 |               -130.6 → -158.2 |              -108.3 → -135.0 |               -109.1 → -136.8 |
| QWERTY (Spanish - International)           |                -134.8 → -179.1 |               -150.1 → -199.0 |              -141.2 → -187.1 |               -144.9 → -196.2 |
| Jesan                                      |                -135.3 → -161.6 |               -141.7 → -167.6 |              -197.4 → -225.8 |               -176.6 → -204.6 |
| AZERTY AFNOR (NF Z71-300)                  |                -135.5 → -184.7 |               -152.5 → -208.2 |              -139.3 → -188.1 |               -152.3 → -205.8 |
| International P                            |                -135.5 → -178.7 |               -154.8 → -203.4 |              -141.0 → -187.1 |               -148.1 → -198.9 |
| English P                                  |                -135.9 → -180.7 |               -149.3 → -197.4 |              -126.8 → -172.3 |               -129.4 → -176.9 |
| As In Red Hot                              |                -136.0 → -152.7 |               -132.6 → -151.2 |              -150.9 → -170.9 |               -142.3 → -165.4 |
| Qwerty P                                   |                -136.3 → -179.5 |               -154.4 → -202.7 |              -140.5 → -186.3 |               -147.5 → -198.6 |
| Qwerty Angle Mod                           |                -136.6 → -179.8 |               -153.9 → -201.8 |              -137.7 → -183.5 |               -146.0 → -196.9 |
| Dreymar                                    |                -136.7 → -159.7 |               -132.2 → -154.1 |                -76.2 → -97.2 |                -92.3 → -114.0 |
| Xpert Express                              |                -136.7 → -156.8 |               -138.5 → -159.4 |              -126.4 → -151.8 |               -129.9 → -157.6 |
| Keymacs                                    |                -137.0 → -161.0 |               -145.9 → -168.1 |              -117.1 → -136.4 |               -141.3 → -161.5 |
| CHIN-Programmer                            |                -137.1 → -162.4 |               -135.2 → -163.0 |              -111.6 → -138.3 |               -114.0 → -142.0 |
| AZERTY 1DK (Kazerty)                       |                -137.7 → -180.6 |               -147.8 → -194.8 |              -146.5 → -195.2 |               -154.6 → -207.8 |
| QWERTY (US)                                |                -137.8 → -180.7 |               -156.1 → -204.0 |              -141.1 → -186.9 |               -148.7 → -199.5 |
| AZERTY (FR)                                |                -138.3 → -185.8 |               -155.0 → -209.0 |              -148.5 → -197.4 |               -159.3 → -213.3 |
| Power                                      |                -140.7 → -170.7 |               -142.0 → -172.9 |              -148.2 → -180.2 |               -136.9 → -169.3 |
| QWERTY Estonian                            |                -140.8 → -184.1 |               -158.6 → -206.8 |              -142.6 → -188.6 |               -150.7 → -202.0 |
| QWERTY (Danish - International)            |                -141.2 → -184.4 |               -159.0 → -207.2 |              -143.0 → -188.9 |               -151.1 → -202.4 |
| German QWERTY                              |                -141.7 → -186.4 |               -156.8 → -205.6 |              -142.1 → -188.0 |               -146.0 → -197.3 |
| AZERTY (US symbols)                        |                -142.5 → -189.2 |               -160.4 → -212.9 |              -140.0 → -188.5 |               -148.4 → -201.4 |
| QWERTY-Programmer                          |                -142.6 → -185.8 |               -161.2 → -209.5 |              -143.5 → -189.2 |               -152.5 → -203.5 |
| QWERTZ                                     |                -142.7 → -187.4 |               -157.5 → -206.3 |              -135.5 → -179.9 |               -146.9 → -197.6 |
| Crate                                      |                -144.5 → -172.9 |               -138.6 → -166.7 |              -186.8 → -219.6 |               -148.4 → -179.0 |
| Hawaiian                                   |                -145.3 → -188.3 |               -161.8 → -209.7 |              -142.0 → -187.8 |               -149.5 → -200.3 |
| Stial                                      |                -147.1 → -167.6 |               -153.4 → -174.8 |              -113.9 → -140.9 |               -130.7 → -156.2 |
| Quartz Glyph                               |                -148.5 → -196.2 |               -166.0 → -214.1 |              -165.6 → -218.0 |               -177.7 → -231.3 |
| Spanish (OLPC)                             |                -149.0 → -194.6 |               -161.8 → -212.0 |              -139.6 → -185.6 |               -148.1 → -199.4 |
| White Refingered                           |                -150.1 → -169.8 |               -139.6 → -162.8 |               -86.0 → -108.2 |                -87.8 → -112.4 |
| Isa                                        |                -150.7 → -188.6 |               -152.5 → -188.2 |              -119.7 → -161.6 |               -123.7 → -164.6 |
| De Correspondent                           |                -151.9 → -170.6 |               -146.0 → -163.0 |               -88.3 → -109.5 |               -109.0 → -129.4 |
| Qwyrfm                                     |                -153.7 → -180.8 |               -153.6 → -181.2 |              -123.0 → -145.2 |               -126.1 → -149.8 |
| Quickstephen                               |                -154.3 → -177.2 |               -155.7 → -179.5 |              -203.3 → -231.7 |               -191.4 → -218.5 |
| Ward                                       |                -159.6 → -177.5 |               -154.8 → -169.6 |              -115.2 → -138.8 |               -121.1 → -140.4 |
| Qwkrfy                                     |                -160.5 → -189.6 |               -152.2 → -182.8 |              -165.5 → -191.8 |               -143.4 → -171.7 |
| Qwerty Wide Programmer                     |                -161.2 → -200.1 |               -176.4 → -219.1 |              -146.7 → -183.6 |               -180.5 → -225.3 |
| TaserFR                                    |                -165.1 → -184.8 |               -178.3 → -205.0 |              -183.4 → -201.3 |               -191.0 → -211.5 |
| Cyberswarm                                 |                -165.4 → -192.2 |               -151.2 → -177.1 |              -129.5 → -152.1 |               -133.7 → -157.5 |
| Dvorak Mod Elazharty Azmi Suliman Mod Ian  |                -165.4 → -190.5 |               -156.4 → -184.1 |              -128.0 → -150.5 |               -139.7 → -165.1 |
| Gardner                                    |                -165.6 → -207.5 |               -192.5 → -235.0 |              -176.3 → -219.7 |               -188.8 → -231.5 |
| Kurriss                                    |                -166.3 → -199.5 |               -174.7 → -205.3 |              -153.2 → -175.8 |               -150.5 → -174.6 |
| QWERTY French (US with dead keys)          |                -167.9 → -215.6 |               -183.2 → -235.5 |              -143.4 → -189.6 |               -147.5 → -198.2 |
| Savard Vertical Alpha                      |                -169.3 → -212.8 |               -176.0 → -218.5 |              -182.7 → -226.3 |               -182.2 → -228.9 |
| Drix                                       |                -169.7 → -221.7 |               -184.3 → -241.6 |              -127.3 → -170.8 |               -135.7 → -184.1 |
| Qwerty Angle Wide Mod                      |                -170.4 → -208.8 |               -187.9 → -230.2 |              -135.0 → -174.5 |               -161.6 → -206.3 |
| QWERTY: Wide Mod                           |                -171.5 → -209.8 |               -190.1 → -232.3 |              -138.3 → -177.8 |               -164.3 → -208.9 |
| Qwerty Wide Mod                            |                -171.5 → -209.8 |               -190.0 → -232.3 |              -138.3 → -177.8 |               -164.3 → -208.9 |
| Mcgunnigle Perfect                         |                -171.9 → -196.5 |               -151.4 → -176.2 |              -134.3 → -154.8 |               -126.9 → -151.1 |
| Qwerty Revised                             |                -174.1 → -212.1 |               -173.6 → -208.6 |              -137.9 → -171.5 |               -158.4 → -192.4 |
| ASHLEY-GUDYR                               |                -177.0 → -198.4 |               -174.1 → -196.2 |              -117.6 → -138.4 |               -108.0 → -130.8 |
| Qwerty Q Layout                            |                -178.1 → -222.2 |               -189.2 → -239.9 |              -138.6 → -184.6 |               -153.9 → -207.1 |
| Wolcott                                    |                -181.8 → -225.7 |               -190.5 → -233.4 |              -199.5 → -238.8 |               -192.3 → -235.3 |
| Walker                                     |                -182.4 → -211.0 |               -185.2 → -212.4 |              -180.4 → -210.4 |               -154.6 → -182.8 |
| Harbaugh                                   |                -182.9 → -212.9 |               -163.5 → -191.0 |              -122.1 → -149.7 |               -123.2 → -151.0 |
| Parkinson                                  |                -188.6 → -224.3 |               -165.7 → -197.2 |              -138.1 → -171.4 |               -145.5 → -179.0 |
| Orthographic                               |                -190.2 → -221.5 |               -206.7 → -238.5 |              -186.6 → -218.0 |               -186.3 → -219.9 |
| Qwuio                                      |                -190.7 → -225.3 |               -187.5 → -223.8 |              -136.0 → -165.7 |               -164.8 → -200.8 |
| Sanie                                      |                -193.1 → -217.5 |               -217.8 → -243.3 |              -143.4 → -165.1 |               -155.5 → -179.0 |
| Blickensderfer 5 (thumb)                   |                -198.2 → -219.0 |               -204.6 → -226.4 |              -147.5 → -165.3 |               -165.1 → -184.5 |
| Speedkeys                                  |                -204.1 → -238.9 |               -207.8 → -244.7 |              -287.6 → -345.0 |               -257.6 → -310.6 |
| Print Face                                 |                -212.6 → -249.3 |               -205.2 → -243.2 |              -200.4 → -236.8 |               -179.7 → -215.8 |
| Streitz                                    |                -213.4 → -261.9 |               -226.2 → -275.2 |              -160.9 → -199.9 |               -181.2 → -222.5 |
| Trotman                                    |                -219.6 → -273.5 |               -205.5 → -251.8 |              -208.1 → -265.5 |               -195.9 → -246.6 |
| Us Split V3                                |                -223.0 → -267.7 |               -240.8 → -286.6 |              -172.6 → -215.5 |               -208.7 → -256.1 |
| Blick                                      |                -231.9 → -251.3 |               -241.7 → -262.6 |              -161.8 → -182.3 |               -173.0 → -194.9 |
| Reverse Qwerty                             |                -240.6 → -293.9 |               -248.4 → -303.6 |              -285.2 → -335.5 |               -274.8 → -327.1 |
| 93fk Optimal                               |                -249.0 → -282.3 |               -257.3 → -290.9 |              -237.1 → -264.8 |               -221.3 → -252.8 |
| Gardner2                                   |                -255.9 → -309.6 |               -265.5 → -319.6 |              -205.8 → -247.7 |               -215.5 → -260.9 |
| ABCDEF                                     |                -263.4 → -304.1 |               -273.8 → -319.1 |              -275.5 → -316.8 |               -267.5 → -313.9 |
| Onsorodi Korhan                            |                -275.1 → -309.4 |               -288.3 → -322.6 |              -226.6 → -268.6 |               -234.0 → -275.2 |
| Sholes                                     |                -286.9 → -332.1 |               -291.9 → -337.3 |              -276.7 → -313.8 |               -298.1 → -338.7 |
| Fitch                                      |                -298.8 → -332.7 |               -305.3 → -341.9 |              -354.5 → -393.1 |               -344.6 → -385.1 |
| Combinational                              |                -302.7 → -328.8 |               -301.2 → -326.7 |              -254.3 → -279.5 |               -269.5 → -294.5 |
| Rushforth                                  |                -304.6 → -343.0 |               -328.5 → -369.8 |              -411.9 → -481.7 |               -393.7 → -460.2 |
| Armel Mod Ian                              |                -315.8 → -351.7 |               -344.4 → -380.4 |              -375.3 → -410.9 |               -385.7 → -424.0 |
| One-handed Dvorak (Right)                  |                -317.4 → -345.2 |               -353.9 → -386.7 |              -342.2 → -364.9 |               -359.1 → -389.1 |
| TNWMLC (Worst CarpalX layout)              |                -397.9 → -481.1 |               -423.3 → -511.6 |              -383.3 → -471.0 |               -393.0 → -483.4 |
| Mcgunnigle Peoples Rehomed                 |                -401.7 → -453.6 |               -419.3 → -471.7 |              -360.5 → -402.7 |               -378.2 → -423.8 |
| Rowell                                     |                -479.9 → -523.1 |               -510.3 → -555.3 |              -615.5 → -691.1 |               -563.5 → -629.4 |
| Armel Refingered Ian                       |                -513.4 → -566.2 |               -530.2 → -583.2 |              -501.9 → -547.7 |               -487.0 → -535.1 |
| Vitrimak Ortho                             |                -521.2 → -609.3 |               -528.2 → -611.8 |              -643.6 → -754.7 |               -613.7 → -718.9 |
| Noel                                       |                -540.2 → -628.0 |               -566.5 → -662.5 |              -574.4 → -634.9 |               -538.8 → -608.7 |
| Vitrimak                                   |                -541.3 → -627.3 |               -542.5 → -623.5 |              -652.8 → -759.9 |               -622.8 → -726.2 |
| Layman                                     |                -549.6 → -654.2 |               -585.7 → -697.8 |              -508.1 → -578.3 |               -537.1 → -616.3 |
| One-handed Dvorak (Left)                   |                -616.4 → -709.0 |               -654.6 → -752.6 |              -541.0 → -608.8 |               -568.9 → -646.5 |
| Marsan English                             |                  -25.1 → -34.3 |                 -25.2 → -32.6 |                -24.2 → -37.9 |                 -28.2 → -39.6 |
| Hands Down Neu (ErgoDox)                   |                  -27.0 → -46.5 |                 -31.5 → -47.9 |                 -4.9 → -19.8 |                 -17.5 → -32.5 |
| HS Indeks                                  |                  -28.0 → -45.4 |                 -31.1 → -46.6 |                -22.5 → -36.6 |                 -24.4 → -38.4 |
| Bépo (ErgoDox)                             |                  -37.8 → -52.5 |                 -41.1 → -57.5 |                -70.7 → -91.1 |                 -60.9 → -80.3 |
| Hands Down Polyglot (ErgoDox, archive)     |                  -46.0 → -65.7 |                 -47.1 → -66.4 |                -16.0 → -32.6 |                 -26.3 → -44.1 |
| Bl13 2                                     |                  -49.6 → -63.3 |                 -55.6 → -69.4 |                -17.6 → -30.1 |                 -28.4 → -42.1 |
| X1                                         |                  -52.5 → -64.4 |                 -57.6 → -69.6 |                -24.1 → -35.3 |                 -39.9 → -52.6 |
| Beakl Opted36                              |                  -52.8 → -70.2 |                 -54.5 → -70.6 |                -13.4 → -27.9 |                 -27.9 → -42.4 |
| Bl13                                       |                  -53.7 → -73.4 |                 -58.0 → -76.6 |                -20.4 → -36.8 |                 -35.5 → -51.9 |
| Uciea Vanilla (KLAnext, ErgoDox)           |                  -59.6 → -71.6 |                 -45.9 → -57.6 |                -26.5 → -47.4 |                 -22.7 → -40.8 |
| Full Maks                                  |                  -63.2 → -80.0 |                 -58.1 → -72.8 |                 -8.1 → -20.4 |                 -19.8 → -33.2 |
| Modified UPD                               |                  -76.3 → -91.9 |                 -84.2 → -98.5 |                -35.7 → -49.1 |                 -45.8 → -58.7 |
| Balanced V                                 |                  -83.4 → -99.7 |                -86.7 → -101.6 |                -64.9 → -80.5 |                 -70.4 → -85.3 |
| Dvorak Mod Kengo                           |                 -88.1 → -106.4 |                -93.5 → -110.2 |                -29.8 → -41.9 |                 -44.9 → -58.6 |
| Morgenstern                                |                 -89.6 → -121.5 |                -99.2 → -131.3 |                -71.4 → -94.5 |                -83.4 → -110.8 |
| Hands Down Élan                            |                -110.1 → -125.9 |               -107.8 → -122.1 |              -110.9 → -131.5 |               -106.0 → -125.0 |
| Maltron Us                                 |                -116.0 → -143.0 |               -123.9 → -149.6 |              -114.8 → -137.6 |               -122.0 → -145.1 |
| Hands Down Bronze (KLAnext, ErgoDox)       |                -116.1 → -132.4 |               -116.8 → -131.9 |              -130.5 → -148.1 |               -116.8 → -134.4 |
| Hands Down Bronze                          |                -119.2 → -135.9 |               -118.6 → -133.8 |              -131.2 → -148.8 |               -117.5 → -135.1 |
| Hands Down Extreme (ErgoDox)               |                -119.5 → -142.8 |               -116.9 → -137.2 |              -129.2 → -159.9 |               -111.6 → -138.6 |
| Hands Down Platinum                        |                -122.0 → -139.0 |               -125.1 → -141.2 |              -115.5 → -136.4 |               -110.3 → -130.6 |
| Hands Down Chromium                        |                -122.2 → -143.0 |               -124.3 → -142.9 |              -107.2 → -123.3 |               -112.1 → -129.0 |
| Neo2 Us                                    |                -125.6 → -145.5 |               -133.1 → -154.2 |              -127.7 → -148.0 |               -130.9 → -152.9 |
| Hands Down Vibranium (KLAnext, ErgoDox)    |                -129.8 → -146.8 |               -135.5 → -150.9 |              -114.8 → -130.5 |               -122.7 → -138.6 |
| Hands Down Cesium                          |                -132.0 → -161.0 |               -125.9 → -150.3 |              -112.8 → -132.4 |               -113.7 → -134.2 |
| Brown                                      |                -133.2 → -163.6 |               -115.7 → -140.2 |               -90.9 → -116.6 |                -77.8 → -101.6 |
| Hands Down Élan (matrix)                   |                -134.3 → -151.0 |               -127.7 → -143.1 |              -109.9 → -125.3 |               -109.7 → -125.0 |
| Hands Down Vibranium                       |                -136.6 → -159.2 |               -140.4 → -160.1 |              -118.7 → -137.2 |               -124.3 → -143.5 |
| Hands Down Promethium                      |                -137.8 → -159.7 |               -133.7 → -152.9 |              -119.1 → -135.2 |               -118.8 → -136.2 |
| Hands Down Gold (cyanophage, page 2)       |                -137.9 → -158.7 |               -144.4 → -162.3 |              -128.0 → -143.2 |               -132.0 → -147.6 |
| Corny Furry                                |                -139.5 → -170.1 |               -126.2 → -155.0 |              -130.4 → -149.6 |               -114.0 → -134.1 |
| Hands Down Vibranium vfj                   |                -140.1 → -159.0 |               -140.2 → -157.0 |              -116.9 → -132.9 |               -123.8 → -140.2 |
| Hands Down Vibranium vx                    |                -142.3 → -161.8 |               -142.1 → -159.8 |              -118.7 → -135.0 |               -126.0 → -142.4 |
| Nordrassil                                 |                -142.3 → -165.2 |               -143.2 → -162.3 |              -136.9 → -154.8 |               -138.8 → -155.2 |
| Hands Down Vibranium VP (KLAnext, ErgoDox) |                -142.8 → -159.0 |               -146.5 → -161.1 |              -114.2 → -129.6 |               -121.7 → -137.5 |
| Hands Down Titanium (KLAnext, ErgoDox)     |                -143.2 → -159.5 |               -147.0 → -161.7 |              -118.8 → -134.2 |               -128.2 → -143.7 |
| Hands Down Rhodium (KLAnext, ErgoDox)      |                -143.3 → -161.3 |               -138.8 → -154.9 |              -123.3 → -146.6 |               -122.4 → -143.9 |
| Hands Down Gold (KLAnext, ErgoDox)         |                -144.5 → -160.4 |               -151.7 → -166.4 |              -127.5 → -142.1 |               -132.8 → -147.7 |
| Hands On TS                                |                -144.6 → -163.3 |               -140.3 → -158.6 |              -151.6 → -169.4 |               -137.2 → -155.0 |
| Hands Down Vibranium VF (KLAnext, ErgoDox) |                -144.8 → -161.1 |               -149.1 → -164.0 |              -116.7 → -132.0 |               -123.5 → -139.5 |
| X2                                         |                -145.6 → -159.9 |               -150.2 → -164.4 |              -161.2 → -174.7 |               -152.6 → -166.3 |
| Hands Down Vibranium VB (KLAnext, ErgoDox) |                -146.2 → -162.8 |               -149.5 → -165.1 |              -117.5 → -133.2 |               -124.4 → -140.7 |
| Hands Down Rhodium                         |                -146.7 → -164.8 |               -140.6 → -156.6 |              -124.0 → -147.3 |               -123.1 → -144.6 |
| Hands Down Vibranium vp                    |                -147.1 → -163.3 |               -148.2 → -162.8 |              -115.0 → -130.4 |               -122.3 → -138.1 |
| Hands Down Titanium                        |                -148.0 → -164.3 |               -150.4 → -165.1 |              -119.0 → -134.3 |               -129.4 → -144.7 |
| Hands Down Vibranium vf                    |                -148.1 → -164.5 |               -150.0 → -164.9 |              -117.0 → -132.5 |               -124.0 → -140.0 |
| Hands Down Gold                            |                -148.5 → -164.5 |               -153.4 → -168.2 |              -128.3 → -142.9 |               -133.2 → -148.1 |
| Hands Down Vibranium vb                    |                -149.3 → -166.1 |               -150.5 → -166.1 |              -117.9 → -133.6 |               -124.9 → -141.2 |
| Hands Down Silver (KLAnext, ErgoDox)       |                -150.9 → -167.7 |               -150.8 → -166.8 |              -125.4 → -138.9 |               -124.6 → -139.9 |
| Hands Down Unobtanium                      |                -151.3 → -180.4 |               -149.0 → -176.4 |              -115.2 → -134.8 |               -115.2 → -135.1 |
| Sunlight                                   |                -151.5 → -167.2 |               -142.6 → -156.7 |              -116.1 → -135.1 |               -113.4 → -131.8 |
| X6 Mod Sc0ty Nongr                         |                -152.6 → -167.2 |               -160.1 → -173.6 |              -176.3 → -191.3 |               -158.9 → -172.7 |
| Coastland                                  |                -153.2 → -172.0 |               -145.9 → -162.7 |              -122.0 → -143.3 |               -121.2 → -140.8 |
| Hands Down Silver                          |                -154.8 → -171.9 |               -153.1 → -169.2 |              -126.1 → -139.6 |               -125.4 → -140.7 |
| Adextre                                    |                -155.4 → -176.2 |               -161.0 → -183.7 |              -179.3 → -201.8 |               -176.1 → -200.3 |
| Hands Down Promethium (ErgoDox)            |                -155.5 → -175.1 |               -148.3 → -165.6 |              -115.8 → -131.1 |               -118.4 → -135.4 |
| Hands Down Vibranium vv                    |                -155.7 → -177.3 |               -154.4 → -173.0 |              -115.9 → -133.6 |               -124.5 → -143.2 |
| Seasalt                                    |                -158.5 → -178.7 |               -157.5 → -176.4 |              -109.6 → -122.4 |               -118.5 → -132.0 |
| Beakrak Mod Ian                            |                -158.7 → -175.5 |               -160.7 → -177.1 |              -148.0 → -163.0 |               -152.6 → -168.4 |
| Proxkb Thumbshift                          |                -159.3 → -184.0 |               -158.3 → -179.6 |              -146.0 → -163.8 |               -139.9 → -158.6 |
| Beakrak                                    |                -159.8 → -178.8 |               -161.3 → -180.3 |              -153.9 → -172.3 |               -149.3 → -168.9 |
| Hands Down Alt-nx                          |                -162.1 → -179.6 |               -164.6 → -179.9 |              -126.5 → -140.6 |               -132.3 → -146.5 |
| Night                                      |                -165.1 → -185.0 |               -158.0 → -177.0 |               -99.6 → -116.1 |               -115.8 → -133.6 |
| Hands Down Alt-tx                          |                -165.4 → -184.9 |               -170.1 → -186.3 |              -141.4 → -160.4 |               -144.4 → -161.8 |
| HS Indeks Ex                               |                -167.4 → -187.1 |               -172.3 → -189.6 |              -160.9 → -177.4 |               -158.8 → -175.3 |
| North                                      |                -169.9 → -191.4 |               -162.9 → -182.4 |               -96.8 → -112.6 |               -105.8 → -122.3 |
| Maltron Us 90                              |                -172.1 → -205.2 |               -175.5 → -206.8 |              -158.0 → -187.0 |               -159.0 → -188.1 |
| Stern                                      |                -172.2 → -191.1 |               -161.5 → -179.4 |              -102.8 → -119.7 |               -114.2 → -132.4 |
| Hands Down Alt-nx (matrix)                 |                -174.9 → -193.1 |               -168.0 → -183.2 |              -126.9 → -141.6 |               -130.4 → -144.7 |
| Racket                                     |                -175.4 → -204.9 |               -163.8 → -190.8 |              -105.0 → -124.1 |               -111.6 → -132.4 |
| Maks SX                                    |                -177.2 → -196.0 |               -168.2 → -184.1 |              -113.9 → -125.8 |               -114.4 → -126.9 |
| Aptmak                                     |                -178.5 → -206.7 |               -178.8 → -207.2 |              -144.5 → -167.6 |               -151.5 → -177.4 |
| Dusk                                       |                -179.3 → -210.0 |               -170.7 → -201.2 |              -107.4 → -128.1 |               -117.3 → -139.7 |
| Pfouyhai                                   |                -179.8 → -199.6 |               -178.9 → -197.9 |              -143.8 → -161.0 |               -153.7 → -171.8 |
| Hands Down Alt-ex                          |                -180.0 → -198.0 |               -182.8 → -199.6 |              -162.1 → -182.3 |               -164.4 → -183.2 |
| Enne P 111 69                              |                -180.8 → -208.5 |               -174.5 → -198.7 |              -170.7 → -200.4 |               -158.9 → -187.1 |
| SNTH                                       |                -181.3 → -201.2 |               -165.4 → -183.4 |              -106.0 → -124.6 |               -113.7 → -132.3 |
| Maltron Us 90 Mod Andreas                  |                -182.1 → -213.7 |               -184.4 → -217.6 |              -169.1 → -194.1 |               -167.4 → -194.4 |
| Maltron                                    |                -184.2 → -216.4 |               -190.0 → -220.6 |              -154.0 → -183.2 |               -158.5 → -187.8 |
| Maks Ex                                    |                -185.9 → -209.7 |               -187.0 → -208.6 |              -162.8 → -181.7 |               -166.7 → -185.2 |
| Rsthd 2                                    |                -186.8 → -210.3 |               -204.1 → -229.3 |              -149.6 → -169.8 |               -166.4 → -189.3 |
| Lydell Anishtro                            |                -187.1 → -225.6 |               -188.4 → -228.0 |              -155.3 → -187.1 |               -160.2 → -197.8 |
| Caster                                     |                -188.7 → -218.6 |               -171.5 → -201.4 |              -147.0 → -169.3 |               -142.6 → -168.1 |
| RSTHD                                      |                -189.1 → -216.4 |               -183.2 → -210.6 |              -141.8 → -162.1 |               -149.5 → -172.8 |
| Cole Shift E                               |                -192.8 → -223.4 |               -198.3 → -227.7 |              -178.3 → -203.5 |               -180.8 → -208.6 |
| Hands Down Dash (ErgoDox)                  |                -193.1 → -216.0 |               -190.3 → -209.4 |              -142.9 → -163.0 |               -156.5 → -175.4 |
| Mithril                                    |                -195.1 → -219.5 |               -183.7 → -206.9 |              -115.2 → -133.3 |               -125.0 → -144.6 |
| DSTHK                                      |                -198.2 → -236.8 |               -197.0 → -235.2 |              -155.5 → -182.8 |               -163.5 → -192.0 |
| T Ht01 75 54                               |                -198.6 → -224.9 |               -193.8 → -216.5 |              -179.9 → -199.7 |               -167.1 → -185.6 |
| Hands Down Alt-ex (ortho)                  |                -199.8 → -220.4 |               -200.4 → -218.2 |              -145.2 → -166.4 |               -164.9 → -183.9 |
| Hands Down Dash                            |                -200.1 → -225.0 |               -195.6 → -216.0 |              -149.9 → -171.0 |               -159.4 → -178.9 |
| Hands Down Alt-tx (matrix)                 |                -201.1 → -220.6 |               -186.8 → -202.9 |              -154.5 → -173.1 |               -150.9 → -168.6 |
| Hands Down Alt-nx (ortho)                  |                -204.5 → -223.9 |               -191.6 → -208.3 |              -137.5 → -152.5 |               -145.5 → -159.9 |
| Hands Down Alt-tx (ortho)                  |                -204.9 → -226.2 |               -197.1 → -214.7 |              -153.3 → -173.5 |               -158.4 → -176.0 |
| Hands Down Alt-ex (matrix)                 |                -206.7 → -224.5 |               -196.8 → -213.7 |              -166.5 → -187.2 |               -167.9 → -186.6 |
| Neo 2 in progress (Samuel Suther)          |                -220.0 → -244.5 |               -223.4 → -248.0 |              -228.7 → -253.5 |               -219.6 → -244.2 |
| ЙЦУКЕН (JCUKEN)                            |              -1113.0 → -1188.9 |               -699.8 → -739.2 |            -2031.2 → -2053.0 |               -708.0 → -743.4 |
