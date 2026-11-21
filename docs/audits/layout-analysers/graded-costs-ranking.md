<!-- docs/audits/layout-analysers/graded-costs-ranking.md -->

# Graded costs: the proposed scale and its ranking impact

Written on 2026-11-21 (Paris time) for the maintainer's decision of the same
day (docs/memory/maintainer-decisions.md, « Layout score: graded costs »):
the Studio's single weights become graded costs, a starting scale is proposed
from the known analysers, every grade is editable in the Comparer's score
settings, and the scale ships as the default once this report exists. The
engine side is specified in
[docs/design/layout-analysis.md](../../design/layout-analysis.md#graded-costs).

## The proposed scale

Each grade multiplies its metric's weight (`score_weights.json` « grades »).
No weight changes but `row_jump`'s, which had none: it is half of `sfb`'s.

| Metric           | Grade         | Factor | Why                                                                                                                                                                                                                                                                                        |
| ---------------- | ------------- | -----: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `sfb` (5)        | `same_row`    |      1 | A lateral move of the index or the pinky (or two keys of one thumb) is 1 u, as long as a one-row move.                                                                                                                                                                                     |
| `sfb`            | `one_row`     |      1 | The reference: home row to top row.                                                                                                                                                                                                                                                        |
| `sfb`            | `two_rows`    |      2 | With `sfb_distance` 0.26 on top, a two-row SFB (about 38 mm) costs 10 + 10 = 20 points per %, twice a one-row one (5 + 5 = 10): Oxeylyzer's linear distance gives twice too, genkey's quadratic `dy²` about four times; the flat model gave 1.5 times.                                     |
| `sfs` (3)        | `adjacent`    |    0.1 | 0.3 points per % of the trigrams: an alternation whose outer keys are on adjacent fingers earns nothing net beside `alternation` 0.3 (Oxeylyzer rewards `alternates_sfs` 0.1 against `alternates` 0.4); a tenth of a same-finger skipgram, since two fingers move freely where one cannot. |
| `sfs`            | `one_apart`   |   0.05 | Half the adjacent pair: a finger between them leaves both freer.                                                                                                                                                                                                                           |
| `sfs`            | `index_pinky` |   0.01 | « Barely counted, since that is comfortable » (maintainer).                                                                                                                                                                                                                                |
| `row_jump` (2.5) | `adjacent`    |      1 | Half the SFB weight (maintainer). Keysolve's full-scissor bigram and Cyanophage's scissors make adjacent fingers two rows apart the worst stretch. A full scissor counts in `scissors` too: 5.5 points per % in all, about an SFB.                                                         |
| `row_jump`       | `one_apart`   |    0.5 | Index and ring, middle and pinky: the hand turns rather than stretches.                                                                                                                                                                                                                    |
| `row_jump`       | `index_pinky` |   0.25 | The two outer fingers reach different rows with little strain.                                                                                                                                                                                                                             |
| `distance` (1)   | `index`       |      1 | The reference.                                                                                                                                                                                                                                                                             |
| `distance`       | `middle`      |    1.1 | genkey's and Oxeylyzer's finger speeds: 5.5 for the index, 4.8 for the middle finger (5.5 / 4.8 = 1.15).                                                                                                                                                                                   |
| `distance`       | `ring`        |    1.3 | Cyanophage's ring factor (`same_finger_factor`); genkey and Oxeylyzer give 5.5 / 3.6 = 1.53.                                                                                                                                                                                               |
| `distance`       | `pinky`       |    1.7 | Cyanophage's pinky factor; genkey and Oxeylyzer give 5.5 / 1.5 = 3.7, kept lower since `pinky_load` already weighs the pinkies' presses.                                                                                                                                                   |
| `distance`       | `thumb`       |      1 | A thumb travels little, from a rest key: as the index.                                                                                                                                                                                                                                     |

The flat model, the single weights of before 2026-11-21, is every split grade
at 1, the `sfs` grades at 0 and `row_jump` at 0
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

- The ranking barely moves: Spearman's rank correlation is 0.996 to 0.998 on
  every corpus, and 23 to 28 of the flat top 30 stay in the graded top 30.
- Every score drops by about 12 points, nearly the same for every layout: the
  skipgrams on two fingers take 5 to 6 points, the row jumps about 3.8, the
  two-row SFBs 2.6 to 2.9 and the finger travel 1.7 to 2.1 on average over the
  complete layouts. A score is read against another, so the common drop
  changes no comparison.
- Ergopti on the French corpora: Ergopti+ moves from 4th to 3rd on
  `fr_don_quichotte` (Ergopti 7th, Ergopti ANSI 8th, unchanged) and stays 6th
  on `fr_wikipedia_1m`, where Ergopti and Ergopti ANSI lose three places (8th
  and 9th to 11th and 12th) to Ergo-L and Colemak French Touch. On the English
  corpora, Ergopti's layouts gain zero to four places (around 205th and 225th).
- The largest moves are in the middle of the ranking: Colemak-DH variants and
  Boo-like layouts climb (few row jumps, little pinky travel), while layouts
  with many two-row SFBs or adjacent-finger row jumps (Lela, Austenmak, AdNW,
  Sertain) fall.

## Results

### fr_don_quichotte

Spearman rank correlation 0.9961; 27 of the flat top 30 stay in the graded top 30.

Mean change of each graded metric's points over the 686 complete layouts: sfb -2.88, sfs -5.05, row_jump -3.82, distance -1.77.

| Graded rank | Layout                         | Graded score | Flat rank | Flat score | Move |
| ----------: | ------------------------------ | -----------: | --------: | ---------: | :--: |
|           1 | Erglace (JF)                   |         -1.3 |         1 |        8.4 |  =   |
|           2 | Ergaie                         |         -2.7 |         2 |        7.3 |  =   |
|           3 | Ergopti+                       |         -3.7 |         4 |        6.7 |  +1  |
|           4 | Erglace                        |         -4.1 |         3 |        6.8 |  −1  |
|           5 | Ergopti+ ANSI                  |         -4.9 |         5 |        5.7 |  =   |
|           6 | Erglace (Nuke)                 |         -5.2 |         6 |        5.6 |  =   |
|           7 | Ergopti                        |         -8.2 |         7 |        2.7 |  =   |
|           8 | Ergopti ANSI                   |         -9.5 |         8 |        1.6 |  =   |
|           9 | Optimot                        |        -11.3 |        10 |       -1.0 |  +1  |
|          10 | BEO                            |        -11.6 |         9 |        1.3 |  −1  |
|          11 | Ergo-L                         |        -13.1 |        11 |       -3.8 |  =   |
|          12 | Ergo-L (ISO variant)           |        -13.2 |        12 |       -3.8 |  =   |
|          13 | Colemak French Touch           |        -13.4 |        14 |       -6.1 |  +1  |
|          14 | Béopy 1DFH                     |        -14.3 |        13 |       -6.1 |  −1  |
|          15 | Optimot (ErgoDox)              |        -16.6 |        15 |       -6.3 |  =   |
|          16 | BvoFRak 1.0 FR                 |        -19.2 |        16 |       -8.1 |  =   |
|          17 | NSTR                           |        -19.3 |        17 |       -9.4 |  =   |
|          18 | Hands Down Reference           |        -24.3 |        18 |      -11.9 |  =   |
|          19 | Hands Down Reference (ErgoDox) |        -25.1 |        20 |      -14.2 |  +1  |
|          20 | Urts                           |        -25.3 |        19 |      -13.2 |  −1  |
|          21 | Inrolly2                       |        -27.6 |        21 |      -15.8 |  =   |
|          22 | Hiyou Satan                    |        -28.8 |        23 |      -17.6 |  +1  |
|          23 | Hands Up                       |        -28.9 |        22 |      -16.7 |  −1  |
|          24 | Pietergen 2                    |        -32.3 |        26 |      -22.4 |  +2  |
|          25 | Béopy                          |        -33.6 |        32 |      -24.2 |  +7  |
|          26 | Embizone                       |        -33.9 |        30 |      -23.7 |  +4  |
|          27 | Eureka Plus                    |        -34.0 |        25 |      -22.4 |  −2  |
|          28 | HIEAMTSRN                      |        -34.1 |        35 |      -25.3 |  +7  |
|          29 | Bépolar                        |        -34.3 |        37 |      -25.6 |  +8  |
|          30 | Ev29                           |        -34.7 |        27 |      -22.7 |  −3  |

Ergopti's layouts:

| Layout        | Graded rank | Graded score | Flat rank | Flat score | Move |
| ------------- | ----------: | -----------: | --------: | ---------: | :--: |
| Ergopti+      |           3 |         -3.7 |         4 |        6.7 |  +1  |
| Ergopti+ ANSI |           5 |         -4.9 |         5 |        5.7 |  =   |
| Ergopti       |           7 |         -8.2 |         7 |        2.7 |  =   |
| Ergopti ANSI  |           8 |         -9.5 |         8 |        1.6 |  =   |

Largest moves up: Colemak Textblade (+60), Colemaq-F (+56), Colemaq (+55), Irstmak (+55), Colemak DHv (genkey) (+54), Colemaq (KLAnext) (+53), Colemak DH Ring 20211116 (+50), Colemak Estonian (+50).

Largest moves down: RL Eai (−100), Lela (−73), Austenmak (−68), AdNW (−65), Sertain (−64), Hyperroll (−62), Another Method Non (−62), My Life For Aeir (−61).

### fr_wikipedia_1m

Spearman rank correlation 0.9966; 28 of the flat top 30 stay in the graded top 30.

Mean change of each graded metric's points over the 686 complete layouts: sfb -2.93, sfs -5.55, row_jump -3.80, distance -1.97.

| Graded rank | Layout                         | Graded score | Flat rank | Flat score | Move |
| ----------: | ------------------------------ | -----------: | --------: | ---------: | :--: |
|           1 | Erglace                        |        -10.5 |         1 |        0.8 |  =   |
|           2 | Ergaie                         |        -10.7 |         2 |        0.3 |  =   |
|           3 | Erglace (JF)                   |        -12.3 |         3 |       -1.9 |  =   |
|           4 | Erglace (Nuke)                 |        -15.3 |         5 |       -3.8 |  +1  |
|           5 | BEO                            |        -15.4 |         4 |       -2.4 |  −1  |
|           6 | Ergopti+                       |        -16.1 |         6 |       -4.1 |  =   |
|           7 | Ergo-L (ISO variant)           |        -16.1 |        10 |       -7.4 |  +3  |
|           8 | Ergo-L                         |        -16.3 |        11 |       -7.6 |  +3  |
|           9 | Ergopti+ ANSI                  |        -17.0 |         7 |       -4.9 |  −2  |
|          10 | Colemak French Touch           |        -18.1 |        13 |      -10.4 |  +3  |
|          11 | Ergopti                        |        -18.1 |         8 |       -5.7 |  −3  |
|          12 | Ergopti ANSI                   |        -19.1 |         9 |       -6.5 |  −3  |
|          13 | Urts                           |        -21.3 |        12 |       -9.1 |  −1  |
|          14 | NSTR                           |        -23.9 |        14 |      -12.1 |  =   |
|          15 | Béopy 1DFH                     |        -24.1 |        15 |      -14.5 |  =   |
|          16 | Optimot                        |        -27.6 |        17 |      -15.9 |  +1  |
|          17 | BvoFRak 1.0 FR                 |        -28.0 |        16 |      -14.8 |  −1  |
|          18 | Pietergen 2                    |        -29.6 |        22 |      -18.7 |  +4  |
|          19 | Hands Down Reference           |        -30.2 |        18 |      -16.5 |  −1  |
|          20 | Hands Down Reference (ErgoDox) |        -30.2 |        19 |      -17.2 |  −1  |
|          21 | Inrolly2                       |        -31.1 |        20 |      -17.8 |  −1  |
|          22 | Hands Up                       |        -31.5 |        21 |      -18.5 |  −1  |
|          23 | Hiyou Satan                    |        -32.2 |        23 |      -19.6 |  =   |
|          24 | Helium                         |        -32.7 |        24 |      -20.8 |  =   |
|          25 | Optimot (ErgoDox)              |        -33.6 |        25 |      -21.8 |  =   |
|          26 | Hands Down Extreme             |        -34.3 |        26 |      -21.8 |  =   |
|          27 | HIEAMTSRN                      |        -35.0 |        28 |      -24.0 |  +1  |
|          28 | Hoogendoorn                    |        -35.3 |        31 |      -24.4 |  +3  |
|          29 | Embizone                       |        -36.2 |        30 |      -24.3 |  +1  |
|          30 | Oneproduct (KLAnext)           |        -37.0 |        33 |      -25.4 |  +3  |

Ergopti's layouts:

| Layout        | Graded rank | Graded score | Flat rank | Flat score | Move |
| ------------- | ----------: | -----------: | --------: | ---------: | :--: |
| Ergopti+      |           6 |        -16.1 |         6 |       -4.1 |  =   |
| Ergopti+ ANSI |           9 |        -17.0 |         7 |       -4.9 |  −2  |
| Ergopti       |          11 |        -18.1 |         8 |       -5.7 |  −3  |
| Ergopti ANSI  |          12 |        -19.1 |         9 |       -6.5 |  −3  |

Largest moves up: Irstmak (+64), Colemak-DH Angle (+58), Colemak DHv (genkey) (+58), Colemaq-F (+58), Colemak Mod DH (+57), Colemak-DH (+55), Colemak H (+55), Colemaq (KLAnext) (+54).

Largest moves down: Lela (−98), AdNW (−64), Aptsym (−59), Rolll (−58), Dvarf (−58), Sertain (−57), STNC FHM (−56), Sertain2 (−56).

### en_don_quixote

Spearman rank correlation 0.9981; 27 of the flat top 30 stay in the graded top 30.

Mean change of each graded metric's points over the 686 complete layouts: sfb -2.59, sfs -5.55, row_jump -3.78, distance -1.69.

| Graded rank | Layout           | Graded score | Flat rank | Flat score | Move |
| ----------: | ---------------- | -----------: | --------: | ---------: | :--: |
|           1 | Optimal Trigram  |         -0.9 |         4 |        9.4 |  +3  |
|           2 | Layoutfluid      |         -1.4 |         2 |        9.6 |  =   |
|           3 | Graphite         |         -1.7 |         5 |        9.3 |  +2  |
|           4 | Gallium Colstag  |         -1.8 |         6 |        9.0 |  +2  |
|           5 | Maya             |         -2.1 |         3 |        9.5 |  −2  |
|           6 | Apt3 Am          |         -2.3 |         9 |        7.3 |  +3  |
|           7 | APTv3            |         -2.7 |        12 |        6.8 |  +5  |
|           8 | Wreathy          |         -2.8 |        15 |        5.9 |  +7  |
|           9 | Nerbs            |         -3.4 |         7 |        7.6 |  −2  |
|          10 | RL Eai           |         -3.7 |         1 |       10.0 |  −9  |
|          11 | Hiyou Satan      |         -4.6 |        17 |        5.3 |  +6  |
|          12 | Phonkie          |         -5.2 |        10 |        7.2 |  −2  |
|          13 | S-Roll           |         -5.3 |        19 |        5.1 |  +6  |
|          14 | Inrolly2         |         -5.7 |        22 |        4.9 |  +8  |
|          15 | Moyaimak         |         -5.8 |        25 |        4.6 | +10  |
|          16 | Wreath           |         -5.8 |        33 |        3.1 | +17  |
|          17 | Voxveritas       |         -5.9 |        16 |        5.3 |  −1  |
|          18 | Noctum           |         -6.6 |        13 |        6.5 |  −5  |
|          19 | F You            |         -6.7 |        27 |        4.1 |  +8  |
|          20 | Gallium Angle    |         -6.8 |         8 |        7.4 | −12  |
|          21 | Gallium          |         -6.9 |        11 |        7.0 | −10  |
|          22 | Hydrogen         |         -6.9 |        20 |        5.0 |  −2  |
|          23 | Eka              |         -7.0 |        14 |        6.3 |  −9  |
|          24 | Sturdy Anglemod  |         -7.1 |        21 |        4.9 |  −3  |
|          25 | Saiga            |         -7.1 |        35 |        2.9 | +10  |
|          26 | Hyperroll        |         -7.3 |        30 |        3.8 |  +4  |
|          27 | Vylet            |         -7.3 |        46 |        1.1 | +19  |
|          28 | Sturdy           |         -7.4 |        24 |        4.6 |  −4  |
|          29 | Zsvmtjrnl Fkhy   |         -7.5 |        18 |        5.1 | −11  |
|          30 | Rollla (KLAnext) |         -7.6 |        26 |        4.1 |  −4  |

Ergopti's layouts:

| Layout        | Graded rank | Graded score | Flat rank | Flat score | Move |
| ------------- | ----------: | -----------: | --------: | ---------: | :--: |
| Ergopti+      |         203 |        -24.8 |       205 |      -13.8 |  +2  |
| Ergopti+ ANSI |         206 |        -25.3 |       210 |      -14.3 |  +4  |
| Ergopti       |         209 |        -25.5 |       212 |      -14.4 |  +3  |
| Ergopti ANSI  |         212 |        -26.0 |       216 |      -14.9 |  +4  |

Largest moves up: Blou (+47), STNDC (+42), Beesechurger (+40), Boo 20211119 (+39), Irst (+39), Colemak DH Ring 20211116 (+38), Rollly2 (+38), Colemak DHv (genkey) (+36).

Largest moves down: Austenmak (−62), Hands Down Reference (ErgoDox) (−50), Hands Down Hazamod (−48), Isrtgap (−46), SHZ (−44), Lela (−44), Chendan Cmu No Contraints (−44), Uciea Vanilla (−42).

### en_wikipedia_1m

Spearman rank correlation 0.9971; 23 of the flat top 30 stay in the graded top 30.

Mean change of each graded metric's points over the 686 complete layouts: sfb -2.91, sfs -5.94, row_jump -3.93, distance -2.08.

| Graded rank | Layout              | Graded score | Flat rank | Flat score | Move |
| ----------: | ------------------- | -----------: | --------: | ---------: | :--: |
|           1 | Carbyne Ian         |        -14.9 |         1 |       -2.3 |  =   |
|           2 | Inrolly2            |        -15.1 |         2 |       -2.6 |  =   |
|           3 | Sturdy Anglemod     |        -16.0 |         4 |       -3.4 |  +1  |
|           4 | Sturdy              |        -16.1 |         5 |       -3.4 |  +1  |
|           5 | Gallium Colstag     |        -16.7 |         3 |       -3.2 |  −2  |
|           6 | Voxveritas          |        -16.8 |         7 |       -3.6 |  +1  |
|           7 | RL Eai              |        -16.9 |         6 |       -3.6 |  −1  |
|           8 | Rollla (KLAnext)    |        -17.5 |        10 |       -4.2 |  +2  |
|           9 | Gemini              |        -17.5 |         9 |       -4.1 |  =   |
|          10 | Graphite            |        -17.8 |         8 |       -3.9 |  −2  |
|          11 | Optimal Trigram     |        -18.1 |        27 |       -7.0 | +16  |
|          12 | Layoutfluid         |        -18.3 |        11 |       -4.4 |  −1  |
|          13 | Wreathy             |        -18.5 |        57 |       -9.1 | +44  |
|          14 | Maya                |        -18.5 |        12 |       -4.7 |  −2  |
|          15 | Ruthenium           |        -18.6 |        17 |       -5.6 |  +2  |
|          16 | Nerbs               |        -18.8 |        13 |       -5.1 |  −3  |
|          17 | Flame (KLAnext)     |        -18.8 |        16 |       -5.5 |  −1  |
|          18 | Celestial (KLAnext) |        -18.9 |        51 |       -8.8 | +33  |
|          19 | APTv3               |        -19.4 |        49 |       -8.7 | +30  |
|          20 | F You               |        -19.4 |        24 |       -6.7 |  +4  |
|          21 | Rollla              |        -19.6 |        21 |       -6.2 |  =   |
|          22 | Hyperroll           |        -19.6 |        28 |       -7.0 |  +6  |
|          23 | Carbyne             |        -19.7 |        22 |       -6.4 |  −1  |
|          24 | Apt3 Am             |        -19.8 |        56 |       -9.0 | +32  |
|          25 | Rolll               |        -20.0 |        43 |       -8.2 | +18  |
|          26 | Heart (KLAnext)     |        -20.0 |        18 |       -6.0 |  −8  |
|          27 | AdNW                |        -20.1 |        41 |       -8.0 | +14  |
|          28 | Fire                |        -20.1 |        14 |       -5.3 | −14  |
|          29 | S-Roll              |        -20.1 |        36 |       -8.0 |  +7  |
|          30 | Moyaimak            |        -20.2 |        25 |       -6.9 |  −5  |

Ergopti's layouts:

| Layout        | Graded rank | Graded score | Flat rank | Flat score | Move |
| ------------- | ----------: | -----------: | --------: | ---------: | :--: |
| Ergopti+      |         221 |        -32.8 |       224 |      -20.6 |  +3  |
| Ergopti+ ANSI |         225 |        -33.3 |       227 |      -21.1 |  +2  |
| Ergopti       |         229 |        -33.6 |       230 |      -21.2 |  +1  |
| Ergopti ANSI  |         235 |        -34.1 |       235 |      -21.7 |  =   |

Largest moves up: Boo 20211119 (+67), STNDC (+62), Irst (+55), Stndc (KLAnext) (+53), Colemak-DN (+51), Real (+50), Sent (+50), Rollly2 (+48).

Largest moves down: Lela (−95), APTv4 (−67), Austenmak (−63), Hexalgram (−60), Nerts (KLAnext) (−55), Ammon134 (−54), Nerps (KLAnext) (−53), Sertain (−51).

### Every layout score

| Layout                                     | fr_don_quichotte flat → graded | fr_wikipedia_1m flat → graded | en_don_quixote flat → graded | en_wikipedia_1m flat → graded |
| ------------------------------------------ | -----------------------------: | ----------------------------: | ---------------------------: | ----------------------------: |
| Erglace (JF)                               |                     8.4 → -1.3 |                  -1.9 → -12.3 |                 -8.9 → -22.7 |                 -12.3 → -25.1 |
| Ergaie                                     |                     7.3 → -2.7 |                   0.3 → -10.7 |                 -6.4 → -19.3 |                 -12.6 → -24.9 |
| Erglace                                    |                     6.8 → -4.1 |                   0.8 → -10.5 |                -14.3 → -28.1 |                 -15.8 → -29.2 |
| Ergopti+                                   |                     6.7 → -3.7 |                  -4.1 → -16.1 |                -13.8 → -24.8 |                 -20.6 → -32.8 |
| Ergopti+ ANSI                              |                     5.7 → -4.9 |                  -4.9 → -17.0 |                -14.3 → -25.3 |                 -21.1 → -33.3 |
| Erglace (Nuke)                             |                     5.6 → -5.2 |                  -3.8 → -15.3 |                 -9.6 → -23.5 |                 -14.0 → -27.3 |
| Ergopti                                    |                     2.7 → -8.2 |                  -5.7 → -18.1 |                -14.4 → -25.5 |                 -21.2 → -33.6 |
| Ergopti ANSI                               |                     1.6 → -9.5 |                  -6.5 → -19.1 |                -14.9 → -26.0 |                 -21.7 → -34.1 |
| BEO                                        |                    1.3 → -11.6 |                  -2.4 → -15.4 |                -15.7 → -30.0 |                 -23.7 → -37.8 |
| Optimot                                    |                   -1.0 → -11.3 |                 -15.9 → -27.6 |                -35.5 → -48.5 |                 -42.9 → -56.8 |
| Ergo-L                                     |                   -3.8 → -13.1 |                  -7.6 → -16.3 |                -28.2 → -39.6 |                 -23.9 → -33.9 |
| Ergo-L (ISO variant)                       |                   -3.8 → -13.2 |                  -7.4 → -16.1 |                -25.3 → -36.1 |                 -22.5 → -32.5 |
| Béopy 1DFH                                 |                   -6.1 → -14.3 |                 -14.5 → -24.1 |                -39.9 → -52.2 |                 -35.4 → -47.7 |
| Colemak French Touch                       |                   -6.1 → -13.4 |                 -10.4 → -18.1 |                -32.4 → -44.5 |                 -23.1 → -32.7 |
| Optimot (ErgoDox)                          |                   -6.3 → -16.6 |                 -21.8 → -33.6 |                -36.0 → -49.7 |                 -40.9 → -54.8 |
| BvoFRak 1.0 FR                             |                   -8.1 → -19.2 |                 -14.8 → -28.0 |               -88.8 → -102.2 |                 -77.5 → -91.9 |
| NSTR                                       |                   -9.4 → -19.3 |                 -12.1 → -23.9 |                   2.2 → -9.8 |                  -6.9 → -20.9 |
| Hands Down Reference                       |                  -11.9 → -24.3 |                 -16.5 → -30.2 |                -22.9 → -38.0 |                 -23.1 → -39.5 |
| Urts                                       |                  -13.2 → -25.3 |                  -9.1 → -21.3 |                 -3.6 → -16.1 |                  -8.9 → -22.1 |
| Hands Down Reference (ErgoDox)             |                  -14.2 → -25.1 |                 -17.2 → -30.2 |                -26.4 → -42.6 |                 -24.6 → -41.1 |
| Inrolly2                                   |                  -15.8 → -27.6 |                 -17.8 → -31.1 |                   4.9 → -5.7 |                  -2.6 → -15.1 |
| Hands Up                                   |                  -16.7 → -28.9 |                 -18.5 → -31.5 |                 -0.2 → -10.7 |                  -8.0 → -20.6 |
| Hiyou Satan                                |                  -17.6 → -28.8 |                 -19.6 → -32.2 |                   5.3 → -4.6 |                  -8.3 → -20.8 |
| Hiyou (KLAnext)                            |                  -22.3 → -35.7 |                 -30.5 → -44.3 |                 -4.8 → -15.4 |                 -16.5 → -29.4 |
| Eureka Plus                                |                  -22.4 → -34.0 |                 -24.2 → -37.2 |                -57.9 → -74.5 |                 -39.4 → -56.3 |
| Pietergen 2                                |                  -22.4 → -32.3 |                 -18.7 → -29.6 |                -26.7 → -36.9 |                 -20.1 → -31.8 |
| Ev29                                       |                  -22.7 → -34.7 |                 -29.7 → -41.3 |                -21.1 → -33.4 |                 -28.7 → -41.3 |
| Hands Down Extreme                         |                  -22.9 → -34.8 |                 -21.8 → -34.3 |                -21.6 → -36.0 |                 -22.9 → -38.5 |
| Hands Down Neu (cyanophage)                |                  -23.6 → -38.5 |                 -29.2 → -43.2 |                 -7.1 → -18.4 |                 -20.4 → -32.8 |
| Embizone                                   |                  -23.7 → -33.9 |                 -24.3 → -36.2 |                 -1.9 → -11.4 |                 -11.2 → -23.5 |
| Full R2 Rt161 57 5bc1aa                    |                  -23.9 → -37.8 |                 -29.1 → -42.0 |                -30.9 → -43.1 |                 -29.6 → -42.4 |
| Béopy                                      |                  -24.2 → -33.6 |                 -27.8 → -39.5 |                -51.7 → -65.7 |                 -50.3 → -64.2 |
| F You                                      |                  -24.5 → -37.5 |                 -23.9 → -37.3 |                   4.1 → -6.7 |                  -6.7 → -19.4 |
| Haeik                                      |                  -25.2 → -37.7 |                 -32.6 → -45.4 |                -24.2 → -35.4 |                 -31.6 → -44.6 |
| HIEAMTSRN                                  |                  -25.3 → -34.1 |                 -24.0 → -35.0 |                 -1.1 → -10.5 |                  -9.8 → -21.6 |
| Full R2 Rt161 57 47179e                    |                  -25.3 → -38.8 |                 -31.1 → -43.8 |                -31.4 → -43.6 |                 -30.2 → -43.0 |
| Bépolar                                    |                  -25.6 → -34.3 |                 -31.6 → -41.9 |                -59.3 → -71.6 |                 -46.5 → -58.0 |
| Helium                                     |                  -25.9 → -36.9 |                 -20.8 → -32.7 |                -13.2 → -23.1 |                 -17.4 → -29.5 |
| Mtgap Hybrid Vanilla                       |                  -27.2 → -37.7 |                 -33.4 → -44.7 |                -10.7 → -20.0 |                 -17.9 → -29.6 |
| Balance Twelve                             |                  -27.5 → -36.0 |                 -27.9 → -38.4 |                 -7.5 → -16.4 |                 -16.3 → -27.6 |
| Mtgap Optimised Shifted                    |                  -28.0 → -38.5 |                 -33.7 → -44.5 |                 -8.9 → -18.3 |                 -16.3 → -27.7 |
| Hands Down Neu                             |                  -28.1 → -43.5 |                 -31.7 → -46.2 |                 -5.7 → -17.1 |                 -18.6 → -31.3 |
| Rollly                                     |                  -28.4 → -38.5 |                 -29.9 → -41.5 |                   3.6 → -7.8 |                  -9.1 → -21.8 |
| Oneproduct (KLAnext)                       |                  -28.6 → -38.7 |                 -25.4 → -37.0 |                 -0.8 → -11.3 |                  -7.8 → -20.4 |
| Ctgap Ev                                   |                  -28.7 → -42.8 |                 -32.4 → -46.4 |                -12.7 → -24.4 |                 -15.5 → -28.3 |
| Hands Down Hazamod                         |                  -28.8 → -41.4 |                 -24.5 → -39.1 |                -34.1 → -50.6 |                 -24.8 → -42.3 |
| Balance-12                                 |                  -29.0 → -38.7 |                 -26.8 → -37.6 |                -12.8 → -23.0 |                 -15.1 → -26.6 |
| Full R2 Rt162 25 2ec2c1                    |                  -29.3 → -42.3 |                 -33.0 → -45.2 |                -27.2 → -40.1 |                 -27.6 → -40.0 |
| Navarre 2023 (ZHJAYSCPG)                   |                  -29.6 → -40.7 |                 -36.7 → -51.1 |                -77.2 → -94.1 |                -81.8 → -100.7 |
| Ammon134                                   |                  -30.3 → -46.9 |                 -29.8 → -47.3 |                 -2.8 → -16.4 |                 -12.6 → -28.8 |
| Colemak LF                                 |                  -31.0 → -41.0 |                 -30.3 → -41.0 |                -34.7 → -46.7 |                 -31.0 → -43.3 |
| bépo                                       |                  -31.2 → -40.3 |                 -32.8 → -44.8 |                -58.6 → -73.5 |                 -50.5 → -64.9 |
| MTGAP 3.0                                  |                  -31.2 → -41.6 |                 -37.4 → -48.4 |                -11.0 → -20.6 |                 -18.4 → -30.2 |
| Mtgap Mod Joey2216                         |                  -31.4 → -42.4 |                 -36.8 → -47.9 |                -10.5 → -19.8 |                 -19.7 → -30.6 |
| Rollly2                                    |                  -31.6 → -39.6 |                 -32.3 → -41.2 |                 -4.5 → -13.3 |                 -17.0 → -26.9 |
| Bone (KLAnext)                             |                  -31.8 → -45.7 |                 -29.5 → -43.4 |                -15.3 → -29.2 |                 -13.6 → -28.3 |
| Narts 9                                    |                  -31.8 → -45.2 |                 -32.9 → -46.5 |                 -8.4 → -20.7 |                 -15.9 → -30.0 |
| Kilo 37 Vanilla                            |                  -32.1 → -41.4 |                 -40.1 → -50.6 |                -43.1 → -53.3 |                 -35.1 → -45.5 |
| Beakl19bis                                 |                  -32.1 → -44.9 |                 -38.5 → -52.6 |                -15.6 → -27.9 |                 -28.9 → -43.1 |
| Isrt Anglemod                              |                  -32.4 → -40.7 |                 -37.0 → -46.2 |                -10.5 → -20.0 |                 -16.4 → -26.7 |
| Hands Down Reference (sym)                 |                  -32.5 → -44.8 |                 -33.1 → -47.1 |                -51.3 → -69.0 |                 -38.5 → -56.7 |
| Ctgap Final                                |                  -32.9 → -47.2 |                 -30.9 → -45.6 |                 -6.2 → -18.0 |                 -11.4 → -24.8 |
| Gyf Beta                                   |                  -33.0 → -43.1 |                 -41.6 → -52.9 |                -29.0 → -38.7 |                 -37.1 → -48.7 |
| L You                                      |                  -33.0 → -44.8 |                 -28.9 → -40.9 |                 -2.5 → -13.2 |                 -10.6 → -22.2 |
| 14 Maks                                    |                  -33.0 → -46.1 |                 -32.8 → -45.2 |                -49.1 → -61.6 |                 -36.0 → -48.5 |
| CTGAP 3                                    |                  -33.1 → -46.3 |                 -41.5 → -55.3 |                -10.5 → -21.4 |                 -20.9 → -33.6 |
| Hoogendoorn                                |                  -33.2 → -44.7 |                 -24.4 → -35.3 |                -29.0 → -38.9 |                 -22.8 → -34.0 |
| Megamak                                    |                  -33.3 → -45.1 |                 -27.2 → -39.9 |                -14.2 → -27.1 |                 -12.9 → -26.4 |
| Neauwr Bits                                |                  -33.6 → -42.3 |                 -38.8 → -48.4 |                -36.6 → -45.9 |                 -47.9 → -58.2 |
| Crstm                                      |                  -33.7 → -45.4 |                 -30.0 → -43.8 |                 -6.2 → -17.4 |                 -12.0 → -25.0 |
| Beakl Mod Ctgap                            |                  -34.2 → -48.8 |                 -52.2 → -67.2 |                -14.7 → -24.7 |                 -37.4 → -49.9 |
| Snug                                       |                  -34.6 → -44.6 |                 -28.9 → -39.3 |                -12.0 → -25.1 |                  -9.4 → -21.6 |
| Wedlock                                    |                  -35.0 → -45.9 |                 -29.5 → -42.2 |                -10.2 → -21.7 |                 -11.8 → -25.1 |
| Full 157 64 17e2a0                         |                  -35.1 → -48.5 |                 -37.3 → -49.9 |                -28.8 → -43.0 |                 -29.2 → -42.6 |
| HRST                                       |                  -35.1 → -52.2 |                 -30.7 → -47.3 |                  0.1 → -11.7 |                  -9.6 → -23.0 |
| Tesc                                       |                  -35.1 → -46.5 |                 -30.1 → -42.8 |                 -4.6 → -17.5 |                 -10.7 → -24.1 |
| Isrtgap                                    |                  -35.4 → -48.4 |                 -31.9 → -45.6 |                -10.1 → -25.4 |                 -15.4 → -32.0 |
| Blou                                       |                  -35.4 → -46.8 |                 -37.5 → -48.9 |                -15.1 → -22.2 |                 -23.9 → -32.3 |
| AHEI                                       |                  -35.6 → -46.6 |                 -38.5 → -50.9 |                -24.1 → -34.1 |                 -27.3 → -39.3 |
| Paw177                                     |                  -35.7 → -48.3 |                 -35.9 → -49.4 |                 -9.5 → -20.7 |                 -16.6 → -30.4 |
| Crankiest Y                                |                  -35.7 → -48.2 |                 -31.6 → -44.6 |                 -3.2 → -16.9 |                 -11.5 → -25.4 |
| Inrolly                                    |                  -35.8 → -48.7 |                 -41.8 → -56.9 |                  3.9 → -10.5 |                 -14.6 → -30.2 |
| Arts                                       |                  -35.8 → -43.9 |                 -35.4 → -45.1 |                -10.6 → -21.3 |                 -16.1 → -27.2 |
| Hyperroll                                  |                  -35.9 → -54.0 |                 -35.4 → -53.2 |                   3.8 → -7.3 |                  -7.0 → -19.6 |
| Engram                                     |                  -35.9 → -46.9 |                 -29.4 → -41.9 |                -11.4 → -24.0 |                 -17.8 → -31.3 |
| Nerts (KLAnext)                            |                  -36.0 → -49.3 |                 -30.3 → -44.7 |                 -3.0 → -17.6 |                  -9.9 → -26.4 |
| Rtnsg                                      |                  -36.2 → -47.7 |                 -30.5 → -44.1 |                -11.6 → -23.7 |                 -12.2 → -26.1 |
| Debian                                     |                  -36.2 → -49.8 |                 -28.4 → -41.6 |                -14.5 → -25.9 |                 -15.2 → -28.2 |
| Ahei (KLAnext)                             |                  -36.4 → -48.5 |                 -36.0 → -49.3 |                -19.9 → -29.9 |                 -21.5 → -33.5 |
| DTK Eia                                    |                  -36.6 → -52.5 |                 -36.9 → -52.1 |                -21.1 → -34.4 |                 -19.4 → -32.6 |
| Nerts                                      |                  -36.7 → -49.4 |                 -30.8 → -44.5 |                 -4.6 → -15.5 |                 -11.4 → -24.5 |
| APTv4                                      |                  -36.7 → -51.3 |                 -30.1 → -44.5 |                 -7.9 → -22.9 |                 -11.8 → -28.4 |
| S2                                         |                  -37.2 → -45.1 |                 -38.0 → -47.9 |                -28.5 → -38.0 |                 -30.0 → -40.8 |
| Fire (KLAnext)                             |                  -37.2 → -51.0 |                 -30.5 → -44.9 |                 -3.6 → -15.4 |                  -8.3 → -22.5 |
| Poqtea QP                                  |                  -37.4 → -48.5 |                 -32.6 → -44.1 |                -42.8 → -55.3 |                 -35.7 → -48.6 |
| Oneproduct ZXCV                            |                  -37.7 → -46.9 |                 -28.9 → -39.8 |                 -2.2 → -12.4 |                  -8.3 → -20.8 |
| Irst                                       |                  -37.8 → -48.2 |                 -33.1 → -43.2 |                 -4.6 → -13.5 |                 -12.7 → -22.2 |
| Engrammer                                  |                  -37.9 → -49.1 |                 -30.2 → -42.6 |                -11.8 → -24.3 |                 -18.8 → -32.3 |
| Poqtea Tuned                               |                  -38.0 → -48.4 |                 -35.0 → -46.0 |                -46.0 → -58.1 |                 -38.7 → -51.0 |
| Voxveritas                                 |                  -38.2 → -50.9 |                 -33.6 → -46.9 |                   5.3 → -5.9 |                  -3.6 → -16.8 |
| BEAKL-19                                   |                  -38.2 → -52.8 |                 -45.5 → -60.1 |                -24.0 → -38.2 |                 -29.8 → -44.0 |
| Nerps (KLAnext)                            |                  -38.3 → -51.4 |                 -34.0 → -48.2 |                 -4.1 → -18.5 |                 -13.1 → -29.5 |
| Nerps                                      |                  -38.4 → -51.0 |                 -33.7 → -47.3 |                 -5.6 → -16.4 |                 -14.6 → -27.7 |
| Pieter Saeio                               |                  -38.6 → -47.2 |                 -45.2 → -54.6 |                -21.2 → -31.5 |                 -30.5 → -42.1 |
| K U Tea SHRT PNCT                          |                  -38.9 → -50.8 |                 -38.6 → -50.3 |                -53.0 → -68.6 |                 -43.4 → -57.3 |
| Canary Ortho                               |                  -38.9 → -49.0 |                 -35.4 → -45.9 |                -20.7 → -33.4 |                 -15.2 → -27.0 |
| ZXCV Fingers                               |                  -39.3 → -47.9 |                 -37.0 → -47.1 |                -53.3 → -65.7 |                 -42.7 → -55.1 |
| Canary Plusplus                            |                  -39.4 → -50.3 |                 -40.9 → -53.1 |                -20.5 → -33.3 |                 -21.9 → -35.4 |
| Pine V4                                    |                  -39.6 → -51.9 |                 -40.2 → -54.7 |                 -2.8 → -15.6 |                 -10.7 → -24.3 |
| Beakl Opted4                               |                  -39.7 → -50.8 |                 -48.3 → -60.7 |                -14.5 → -26.2 |                 -27.7 → -41.1 |
| Hein                                       |                  -39.7 → -50.5 |                 -38.6 → -50.7 |                -41.2 → -53.3 |                 -43.2 → -57.0 |
| Rollla                                     |                  -39.7 → -52.4 |                 -34.7 → -47.6 |                   2.3 → -9.4 |                  -6.2 → -19.6 |
| Northstar                                  |                  -39.9 → -51.2 |                 -31.1 → -44.3 |                -23.1 → -33.3 |                 -16.2 → -29.2 |
| Pow 123                                    |                  -39.9 → -51.4 |                 -35.1 → -48.3 |                -19.0 → -29.4 |                 -22.1 → -35.0 |
| Heart                                      |                  -40.0 → -49.0 |                 -31.4 → -41.6 |                 -5.3 → -18.6 |                  -6.1 → -20.2 |
| Rollla (KLAnext)                           |                  -40.0 → -52.7 |                 -34.7 → -47.6 |                   4.1 → -7.6 |                  -4.2 → -17.5 |
| ISRT                                       |                  -40.0 → -48.4 |                 -42.5 → -51.8 |                -12.9 → -22.5 |                 -16.9 → -27.3 |
| Heart (KLAnext)                            |                  -40.1 → -49.1 |                 -31.3 → -41.6 |                 -5.0 → -18.3 |                  -6.0 → -20.0 |
| Canary                                     |                  -40.2 → -52.4 |                 -36.7 → -49.2 |                -21.0 → -35.6 |                 -16.4 → -30.8 |
| Dwarf                                      |                  -40.2 → -55.2 |                 -33.7 → -48.8 |                 -5.3 → -19.7 |                 -13.3 → -28.6 |
| Arinh                                      |                  -40.3 → -50.3 |                 -43.0 → -53.1 |                -34.3 → -44.0 |                 -37.4 → -49.3 |
| Oneproduct                                 |                  -40.4 → -51.4 |                 -43.5 → -55.5 |                 -9.8 → -20.8 |                 -20.2 → -33.1 |
| Ctgap                                      |                  -40.5 → -52.9 |                 -34.4 → -46.8 |                -17.0 → -28.1 |                 -11.3 → -23.5 |
| Colemak Cousin                             |                  -40.7 → -49.5 |                 -36.5 → -47.0 |                -47.6 → -59.4 |                 -38.9 → -51.3 |
| Trendei (KLAnext)                          |                  -40.7 → -54.0 |                 -33.2 → -46.2 |                -10.4 → -21.6 |                  -9.8 → -22.5 |
| Aptx                                       |                  -40.7 → -52.6 |                 -32.1 → -45.4 |                  1.0 → -13.5 |                  -7.1 → -22.9 |
| Sertain2                                   |                  -40.9 → -57.6 |                 -33.6 → -51.4 |                 -6.3 → -19.1 |                 -11.5 → -27.4 |
| Canary (KLAnext)                           |                  -40.9 → -52.8 |                 -37.9 → -50.1 |                -21.0 → -34.3 |                 -17.3 → -31.4 |
| Colemak Qix                                |                  -40.9 → -48.4 |                 -34.1 → -43.3 |                -12.1 → -21.5 |                 -16.7 → -27.5 |
| APT                                        |                  -41.0 → -53.4 |                 -33.9 → -46.7 |                 -8.3 → -22.3 |                 -13.6 → -29.0 |
| Hiyou                                      |                  -41.1 → -55.7 |                 -46.6 → -61.4 |                -12.2 → -24.4 |                 -19.4 → -32.6 |
| Octa8 (KLAnext)                            |                  -41.2 → -56.2 |                 -35.9 → -49.3 |                   2.4 → -8.7 |                  -9.1 → -21.5 |
| Athena                                     |                  -41.3 → -53.2 |                 -38.6 → -51.7 |                -32.6 → -47.5 |                 -26.3 → -41.0 |
| Colemak Qi;x                               |                  -41.4 → -49.4 |                 -34.4 → -43.9 |                -12.3 → -21.9 |                 -16.7 → -27.7 |
| Dilbert                                    |                  -41.5 → -56.7 |                 -38.7 → -52.6 |                -23.7 → -39.0 |                 -22.7 → -36.4 |
| Uciea Vanilla Mod Gergely                  |                  -41.6 → -54.3 |                 -34.5 → -47.0 |                 -8.4 → -18.8 |                 -11.6 → -23.2 |
| GG Beakl 19                                |                  -41.7 → -55.5 |                 -48.9 → -62.8 |                -28.0 → -40.8 |                 -32.3 → -45.5 |
| Hands Down Ref (ortho)                     |                  -41.8 → -54.2 |                 -37.0 → -49.7 |                -37.6 → -53.4 |                 -37.9 → -53.7 |
| Adnw Mod Keen                              |                  -41.9 → -52.9 |                 -40.0 → -51.2 |                -11.2 → -22.9 |                 -16.6 → -29.0 |
| Poqtea Klopt                               |                  -41.9 → -52.3 |                 -40.2 → -51.6 |                -48.1 → -61.6 |                 -37.7 → -50.8 |
| Ants                                       |                  -42.0 → -50.8 |                 -35.8 → -45.3 |                -16.1 → -25.5 |                 -26.9 → -38.0 |
| Nerps (cyanophage)                         |                  -42.2 → -54.9 |                 -38.0 → -52.0 |                 -7.0 → -21.3 |                 -16.2 → -32.5 |
| Ctgap 2                                    |                  -42.2 → -53.8 |                 -45.7 → -57.9 |                -14.1 → -24.3 |                 -26.5 → -38.1 |
| Noname 30                                  |                  -42.3 → -54.6 |                 -41.0 → -53.2 |                 -6.2 → -17.1 |                 -14.3 → -26.4 |
| Sertain2 Mod Ian                           |                  -42.5 → -54.9 |                 -29.1 → -41.5 |                -18.4 → -31.2 |                 -15.3 → -28.0 |
| Trendei                                    |                  -42.6 → -56.1 |                 -35.3 → -48.5 |                -11.3 → -22.5 |                 -11.0 → -23.7 |
| Carbyne Ian                                |                  -42.6 → -54.2 |                 -32.5 → -44.1 |                  1.5 → -10.1 |                  -2.3 → -14.9 |
| Hands Down Alt (KLAnext, ErgoDox)          |                  -42.7 → -52.4 |                 -46.5 → -58.2 |                -21.0 → -32.5 |                 -28.5 → -41.4 |
| Poqdea                                     |                  -42.7 → -59.1 |                 -36.2 → -50.4 |                -53.6 → -68.4 |                 -40.6 → -54.6 |
| Crest                                      |                  -42.8 → -54.2 |                 -31.0 → -43.8 |                 -6.5 → -19.0 |                  -7.4 → -20.3 |
| Uciea PCRW                                 |                  -42.9 → -55.5 |                 -34.9 → -47.0 |                -11.7 → -22.9 |                 -13.1 → -24.7 |
| Heartae                                    |                  -42.9 → -51.9 |                 -31.7 → -41.9 |                -16.0 → -29.3 |                 -11.4 → -25.5 |
| Sertain                                    |                  -42.9 → -59.9 |                 -34.7 → -52.6 |                 -6.9 → -19.8 |                 -12.4 → -28.3 |
| Dickens LSF                                |                  -43.0 → -51.9 |                 -45.1 → -54.8 |                -32.0 → -41.0 |                 -34.2 → -45.2 |
| Uciea GCSV                                 |                  -43.1 → -55.9 |                 -33.4 → -45.7 |                 -6.2 → -18.9 |                 -10.5 → -23.0 |
| Ace Vim                                    |                  -43.2 → -53.4 |                 -36.3 → -47.3 |                 -4.2 → -18.0 |                  -9.6 → -23.7 |
| Colemak Pine                               |                  -43.3 → -54.6 |                 -37.5 → -48.8 |                 -7.1 → -16.3 |                 -14.3 → -24.9 |
| Homework                                   |                  -43.3 → -58.2 |                 -44.7 → -58.9 |                 -9.0 → -19.2 |                 -17.9 → -30.1 |
| Beakl421                                   |                  -43.6 → -53.5 |                 -39.2 → -51.1 |                -21.4 → -33.0 |                 -22.7 → -35.9 |
| Hinsty                                     |                  -43.8 → -55.2 |                 -39.8 → -51.8 |                -17.7 → -27.5 |                 -26.1 → -37.2 |
| Colemak Qi (KLAnext)                       |                  -43.9 → -51.9 |                 -35.2 → -45.2 |                -15.3 → -26.1 |                 -16.4 → -28.0 |
| Aptsym2                                    |                  -44.0 → -56.1 |                 -41.5 → -54.3 |                 -5.2 → -18.3 |                  -8.0 → -21.5 |
| Gust                                       |                  -44.1 → -57.7 |                 -36.5 → -50.9 |                 -1.6 → -14.2 |                  -8.8 → -23.4 |
| Northstar (cyanophage, page 2)             |                  -44.1 → -55.5 |                 -37.3 → -50.5 |                -17.6 → -28.0 |                 -14.0 → -27.0 |
| LSNT                                       |                  -44.2 → -58.6 |                 -60.1 → -75.6 |                -22.6 → -33.5 |                 -43.2 → -57.4 |
| Colemak Qi                                 |                  -44.3 → -52.4 |                 -35.9 → -45.9 |                -15.9 → -26.7 |                 -16.7 → -28.3 |
| Burroughs Bower Mod Ian                    |                  -44.5 → -54.1 |                 -43.3 → -52.6 |                -39.7 → -48.9 |                 -37.9 → -47.1 |
| Irstmak                                    |                  -44.6 → -51.1 |                 -50.8 → -57.9 |                -24.1 → -31.4 |                 -27.1 → -35.5 |
| BuTeck                                     |                  -44.6 → -57.2 |                 -44.0 → -56.3 |                 -8.6 → -19.5 |                 -19.1 → -30.9 |
| CMBK Nlhy 2                                |                  -44.7 → -55.2 |                 -37.8 → -47.9 |                -17.4 → -26.6 |                 -17.0 → -27.8 |
| Calemog                                    |                  -44.7 → -56.8 |                 -39.1 → -51.2 |                 -5.9 → -15.8 |                 -12.7 → -24.1 |
| Saiga                                      |                  -44.8 → -54.4 |                 -44.6 → -54.8 |                   2.9 → -7.1 |                 -10.7 → -21.6 |
| Iena                                       |                  -44.9 → -53.5 |                 -46.6 → -56.2 |                -23.6 → -34.5 |                 -31.4 → -42.5 |
| Graphite                                   |                  -44.9 → -55.4 |                 -40.0 → -52.9 |                   9.3 → -1.7 |                  -3.9 → -17.8 |
| Athena Alt                                 |                  -44.9 → -56.9 |                 -40.3 → -53.6 |                -25.8 → -38.8 |                 -25.9 → -40.6 |
| Apthd                                      |                  -45.1 → -55.3 |                 -44.6 → -55.2 |                -21.1 → -34.0 |                 -21.1 → -34.4 |
| Another Method Non Mirrored                |                  -45.8 → -60.3 |                 -55.8 → -68.8 |                -40.6 → -53.6 |                 -33.5 → -46.1 |
| Carbyne                                    |                  -45.8 → -58.7 |                 -35.1 → -47.6 |                  0.1 → -12.5 |                  -6.4 → -19.7 |
| Eureka                                     |                  -45.9 → -58.1 |                 -46.4 → -60.5 |                -59.4 → -75.9 |                 -49.1 → -65.8 |
| Notarise                                   |                  -45.9 → -54.5 |                 -55.3 → -64.8 |                -66.9 → -77.1 |                 -57.0 → -67.3 |
| Layoutissimus                              |                  -46.0 → -56.2 |                 -44.1 → -54.9 |                -79.1 → -93.2 |                 -60.6 → -75.6 |
| Dvormax                                    |                  -46.2 → -54.9 |                 -37.5 → -47.8 |                 -9.5 → -19.7 |                 -10.0 → -20.8 |
| Middlemak                                  |                  -46.3 → -57.8 |                 -45.1 → -57.3 |                -35.7 → -47.4 |                 -33.1 → -46.2 |
| Louda                                      |                  -46.4 → -57.5 |                 -41.7 → -53.6 |                -25.8 → -39.5 |                 -18.1 → -32.4 |
| Apt (KLAnext)                              |                  -46.5 → -56.6 |                 -34.9 → -46.2 |                -20.5 → -34.8 |                 -15.1 → -30.3 |
| X4                                         |                  -46.5 → -53.7 |                 -51.1 → -59.6 |                -43.8 → -51.0 |                 -47.7 → -56.5 |
| Asrt Hrl2                                  |                  -46.7 → -57.9 |                 -47.9 → -59.2 |                -19.1 → -30.8 |                 -26.2 → -38.7 |
| Colemak Mod UK                             |                  -46.7 → -53.5 |                 -47.1 → -55.2 |                -39.7 → -47.9 |                 -36.6 → -46.4 |
| Hands Right                                |                  -46.8 → -57.0 |                 -36.4 → -48.1 |                 -3.2 → -17.1 |                  -9.3 → -23.9 |
| Colemak DHv (genkey)                       |                  -46.8 → -53.0 |                 -50.8 → -58.3 |                -30.6 → -37.8 |                 -30.8 → -39.8 |
| Octa8                                      |                  -46.9 → -59.6 |                 -41.8 → -54.1 |                 -1.6 → -12.4 |                 -10.3 → -22.5 |
| Wreathy                                    |                  -46.9 → -57.9 |                 -40.8 → -52.0 |                   5.9 → -2.8 |                  -9.1 → -18.5 |
| Kyudi                                      |                  -47.3 → -59.3 |                 -40.6 → -52.7 |                -14.2 → -25.3 |                 -17.1 → -28.9 |
| Middlemak NH                               |                  -47.5 → -59.6 |                 -40.8 → -54.3 |                -31.4 → -43.6 |                 -23.4 → -37.8 |
| Kaehi                                      |                  -47.7 → -58.6 |                 -42.2 → -53.9 |                -34.7 → -49.6 |                 -33.3 → -49.0 |
| Layoutfluid                                |                  -47.8 → -58.2 |                 -42.3 → -55.2 |                   9.6 → -1.4 |                  -4.4 → -18.3 |
| Vimak Beta                                 |                  -47.8 → -59.4 |                 -42.3 → -54.3 |                -26.2 → -38.4 |                 -25.4 → -38.6 |
| Mtgap R                                    |                  -47.9 → -62.3 |                 -40.3 → -53.5 |                -12.5 → -23.6 |                 -15.6 → -26.8 |
| Apt3 Am                                    |                  -47.9 → -58.5 |                 -45.3 → -56.1 |                   7.3 → -2.3 |                  -9.0 → -19.8 |
| Uhiea Davison                              |                  -47.9 → -60.2 |                 -50.2 → -63.1 |                -12.5 → -23.5 |                 -22.8 → -35.7 |
| Dvarf                                      |                  -48.0 → -63.3 |                 -45.3 → -61.1 |                -10.5 → -22.6 |                 -18.2 → -33.1 |
| Canary GV                                  |                  -48.1 → -60.3 |                 -40.2 → -52.4 |                -26.1 → -40.4 |                 -17.0 → -31.1 |
| Colemak-DN                                 |                  -48.2 → -58.1 |                 -36.6 → -48.1 |                  -1.3 → -9.7 |                 -10.9 → -20.9 |
| 16 Maks                                    |                  -48.2 → -59.5 |                 -49.7 → -61.0 |                -38.1 → -49.9 |                 -34.4 → -46.6 |
| Really?                                    |                  -48.3 → -56.0 |                 -47.4 → -56.4 |                -10.3 → -20.1 |                 -13.9 → -24.4 |
| Hands Down Alt                             |                  -48.5 → -61.2 |                 -47.2 → -60.1 |                -18.5 → -30.0 |                 -26.5 → -39.4 |
| Phonkie                                    |                  -48.5 → -60.7 |                 -44.6 → -56.1 |                   7.2 → -5.2 |                 -12.6 → -25.3 |
| Minred2                                    |                  -48.6 → -63.8 |                 -43.0 → -57.0 |                -11.5 → -24.9 |                 -17.6 → -31.3 |
| APTv3                                      |                  -48.6 → -59.3 |                 -45.3 → -56.1 |                   6.8 → -2.7 |                  -8.7 → -19.4 |
| Handymak                                   |                  -48.7 → -58.6 |                 -47.0 → -58.1 |                -33.7 → -42.1 |                 -33.5 → -44.0 |
| Moyaimak                                   |                  -48.7 → -58.5 |                 -44.0 → -56.3 |                   4.6 → -5.8 |                  -6.9 → -20.2 |
| AdNW                                       |                  -48.7 → -66.5 |                 -51.0 → -68.4 |                 -4.1 → -15.9 |                  -8.0 → -20.1 |
| Dsend Thumbshift                           |                  -48.7 → -63.5 |                 -50.1 → -64.1 |                -13.6 → -27.6 |                 -15.8 → -29.6 |
| Embizone Mod Ian                           |                  -48.7 → -59.7 |                 -44.6 → -57.2 |                -12.0 → -22.1 |                 -22.9 → -35.6 |
| Hexalgram                                  |                  -49.6 → -62.1 |                 -44.9 → -59.4 |                -37.0 → -53.1 |                 -32.0 → -49.5 |
| Canary Pow 123                             |                  -49.6 → -61.2 |                 -43.9 → -55.6 |                -35.5 → -47.8 |                 -27.5 → -40.7 |
| Arensito Kinesis                           |                  -49.8 → -58.4 |                 -54.2 → -63.4 |                -40.3 → -47.9 |                 -48.1 → -56.7 |
| Minred                                     |                  -50.0 → -61.5 |                 -48.2 → -61.0 |                 -0.9 → -11.3 |                 -17.7 → -30.4 |
| Arensito                                   |                  -50.2 → -60.5 |                 -43.6 → -53.9 |                -38.3 → -46.8 |                 -37.4 → -47.2 |
| Colemak                                    |                  -50.4 → -57.0 |                 -47.8 → -55.9 |                -35.7 → -43.6 |                 -30.3 → -39.9 |
| Culemak                                    |                  -50.6 → -57.1 |                 -47.2 → -55.4 |                -34.6 → -42.5 |                 -29.8 → -39.4 |
| Hands On (ErgoDox)                         |                  -50.6 → -59.7 |                 -58.4 → -69.9 |                -42.1 → -53.4 |                 -45.4 → -58.0 |
| Wreath                                     |                  -50.7 → -61.2 |                 -45.2 → -56.0 |                   3.1 → -5.8 |                 -12.0 → -21.9 |
| Asthl                                      |                  -50.9 → -59.2 |                 -60.0 → -69.4 |                -14.4 → -23.2 |                 -28.7 → -38.6 |
| Hands Down Alt (KLAnext)                   |                  -50.9 → -60.8 |                 -41.2 → -53.0 |                -27.0 → -39.8 |                 -26.4 → -39.7 |
| Boo 20211119                               |                  -51.1 → -62.1 |                 -45.6 → -55.7 |                 -4.8 → -13.5 |                 -17.5 → -26.2 |
| Colemak-DHv                                |                  -51.1 → -58.4 |                 -52.1 → -60.3 |                -32.6 → -40.2 |                 -32.2 → -41.5 |
| INTS                                       |                  -51.1 → -62.3 |                 -50.2 → -60.8 |                   0.8 → -8.9 |                 -19.6 → -30.5 |
| Burroughs Bower (typewriter) configuration |                  -51.1 → -60.1 |                 -49.4 → -58.4 |                -42.5 → -52.2 |                 -45.2 → -55.1 |
| Optimal Trigram                            |                  -51.2 → -62.6 |                 -51.8 → -64.4 |                   9.4 → -0.9 |                  -7.0 → -18.1 |
| Colemak H                                  |                  -51.2 → -57.8 |                 -48.9 → -56.7 |                -32.7 → -40.9 |                 -27.5 → -36.7 |
| Capewell                                   |                  -51.2 → -61.5 |                 -47.3 → -58.0 |                -35.7 → -43.4 |                 -40.7 → -49.9 |
| Middlephobia                               |                  -51.2 → -65.3 |                 -48.1 → -61.4 |                 -2.8 → -14.6 |                 -13.7 → -26.6 |
| Rollmak                                    |                  -51.3 → -60.2 |                 -48.6 → -57.7 |                -24.0 → -34.0 |                 -21.1 → -32.1 |
| Semimak JQ                                 |                  -51.6 → -63.3 |                 -43.5 → -56.3 |                 -0.1 → -13.8 |                  -8.8 → -22.9 |
| Hirou                                      |                  -51.6 → -59.1 |                 -59.8 → -68.8 |                -34.4 → -42.7 |                 -33.7 → -43.6 |
| Aptsym                                     |                  -51.7 → -66.6 |                 -52.6 → -69.8 |                -21.9 → -36.5 |                 -20.1 → -34.9 |
| Shai                                       |                  -51.9 → -58.4 |                 -49.6 → -57.4 |                -34.5 → -42.8 |                 -28.8 → -38.0 |
| Chendan Cmu Qawzxcv                        |                  -51.9 → -60.2 |                 -47.8 → -58.0 |                -23.2 → -33.6 |                 -26.0 → -37.6 |
| Colemak Mod DH                             |                  -51.9 → -58.4 |                 -49.2 → -56.9 |                -30.6 → -38.3 |                 -27.1 → -36.4 |
| Nirvana Opt                                |                  -52.0 → -63.3 |                 -61.3 → -74.7 |                -26.4 → -40.8 |                 -37.3 → -52.5 |
| Colemak-DH Angle                           |                  -52.1 → -58.5 |                 -49.1 → -56.8 |                -31.6 → -39.0 |                 -27.4 → -36.4 |
| X1 Atreus 44 Keys                          |                  -52.1 → -61.3 |                 -57.5 → -68.7 |                -25.7 → -34.6 |                 -41.1 → -52.6 |
| Ruthenium                                  |                  -52.2 → -65.5 |                 -40.2 → -53.1 |                  1.3 → -11.0 |                  -5.6 → -18.6 |
| Ace Vim Test                               |                  -52.3 → -64.7 |                 -47.4 → -60.3 |                 -9.3 → -23.0 |                 -18.5 → -32.1 |
| Kyu Vanilla                                |                  -52.3 → -67.6 |                 -45.1 → -60.2 |                 -0.8 → -14.6 |                 -13.0 → -27.0 |
| RL Eai                                     |                  -52.3 → -72.4 |                 -40.8 → -56.8 |                  10.0 → -3.7 |                  -3.6 → -16.9 |
| RTNA                                       |                  -52.3 → -67.4 |                 -47.4 → -62.9 |                -25.5 → -39.1 |                 -31.0 → -46.3 |
| Nerbs                                      |                  -52.4 → -65.6 |                 -45.0 → -59.3 |                   7.6 → -3.4 |                  -5.1 → -18.8 |
| Colemak Asrt Mod Hazaskull                 |                  -52.4 → -64.3 |                 -49.0 → -62.0 |                -35.7 → -48.5 |                 -31.1 → -45.4 |
| Colemak-DH                                 |                  -52.4 → -58.9 |                 -49.8 → -57.5 |                -32.2 → -39.6 |                 -27.7 → -36.8 |
| Maplefyre                                  |                  -52.5 → -64.1 |                 -47.6 → -59.3 |                -13.4 → -27.4 |                 -16.4 → -30.6 |
| Weltsch                                    |                  -52.7 → -61.6 |                 -41.3 → -51.2 |                -15.9 → -26.1 |                 -14.4 → -25.9 |
| Sind                                       |                  -52.8 → -63.3 |                 -51.4 → -62.4 |                -11.4 → -23.4 |                 -19.9 → -33.0 |
| Chendan Cmu Qawzxc                         |                  -52.9 → -61.2 |                 -48.5 → -58.6 |                -22.0 → -33.0 |                 -25.5 → -37.3 |
| Carbyne (cyanophage)                       |                  -53.0 → -62.5 |                 -44.1 → -54.7 |                -15.3 → -27.6 |                 -15.9 → -28.4 |
| Asrt DH                                    |                  -53.1 → -61.1 |                 -47.8 → -57.3 |                -25.6 → -35.4 |                 -30.8 → -41.9 |
| Handson Ui V2                              |                  -53.3 → -63.9 |                 -51.2 → -64.2 |                -49.2 → -63.3 |                 -40.9 → -55.7 |
| Colemak VCP                                |                  -53.4 → -59.8 |                 -53.7 → -61.2 |                -33.1 → -40.6 |                 -33.2 → -42.1 |
| STNC FHM                                   |                  -53.4 → -69.0 |                 -44.6 → -59.9 |                 -7.4 → -21.6 |                 -15.9 → -32.0 |
| Programmer Colemak                         |                  -53.6 → -60.2 |                 -51.9 → -60.2 |                -38.9 → -46.9 |                 -34.7 → -44.5 |
| Austenmak                                  |                  -53.7 → -70.6 |                 -57.4 → -73.1 |                -19.0 → -39.3 |                 -29.7 → -47.3 |
| Uiy N Ansi Maks                            |                  -53.7 → -62.6 |                 -50.0 → -60.3 |                -28.2 → -38.1 |                 -31.1 → -42.7 |
| Beesechurger                               |                  -53.7 → -61.9 |                 -49.4 → -57.5 |                -26.3 → -33.1 |                 -25.6 → -33.4 |
| Juyanith                                   |                  -53.7 → -62.9 |                 -45.7 → -55.4 |                 -9.0 → -20.8 |                 -10.4 → -22.2 |
| Karrenbauer Oulasvirta Mod Ian             |                  -53.8 → -62.5 |                 -65.9 → -75.9 |                -50.2 → -59.2 |                 -62.3 → -72.9 |
| Castra                                     |                  -53.8 → -67.0 |                 -52.4 → -68.4 |                 -9.4 → -20.5 |                 -12.9 → -25.5 |
| Anrt                                       |                  -53.9 → -61.7 |                 -59.0 → -68.7 |                -18.8 → -28.9 |                 -29.1 → -40.5 |
| Dvorky                                     |                  -54.1 → -67.6 |                 -55.6 → -69.4 |                   2.9 → -8.9 |                 -11.3 → -24.8 |
| Maya                                       |                  -54.1 → -67.6 |                 -46.8 → -61.1 |                   9.5 → -2.1 |                  -4.7 → -18.5 |
| Soul                                       |                  -54.1 → -62.1 |                 -53.2 → -63.2 |                -29.5 → -39.1 |                 -31.0 → -42.4 |
| S2 Klopt                                   |                  -54.3 → -66.0 |                 -52.8 → -64.5 |                 -3.5 → -13.6 |                 -14.8 → -26.5 |
| Engram (ES)                                |                  -54.3 → -70.6 |                 -59.6 → -75.7 |                -47.0 → -65.2 |                 -41.6 → -58.0 |
| Adnw (KLAnext)                             |                  -54.4 → -69.6 |                 -54.3 → -70.0 |                -11.8 → -23.4 |                 -17.0 → -29.2 |
| UCIEA                                      |                  -54.4 → -63.3 |                 -42.3 → -52.3 |                -22.3 → -35.9 |                 -19.5 → -31.9 |
| My Life For Aeir                           |                  -54.5 → -71.2 |                 -42.1 → -57.0 |                 -7.0 → -20.0 |                  -8.7 → -21.2 |
| Beakl49                                    |                  -54.6 → -68.2 |                 -47.5 → -61.4 |                -30.5 → -41.0 |                 -27.5 → -39.8 |
| Codemak                                    |                  -54.6 → -61.3 |                 -53.6 → -62.2 |                -39.8 → -47.9 |                 -35.9 → -45.9 |
| Nitrogen                                   |                  -54.6 → -67.9 |                 -46.9 → -60.8 |                 -2.7 → -13.6 |                  -9.8 → -22.0 |
| MTGAP-T                                    |                  -54.8 → -68.7 |                 -53.4 → -66.4 |                 -4.0 → -15.0 |                 -10.4 → -23.0 |
| Colemak Mod Fox                            |                  -54.9 → -62.9 |                 -54.7 → -64.2 |                -35.7 → -44.9 |                 -35.5 → -46.6 |
| Sent                                       |                  -55.0 → -65.8 |                 -45.2 → -55.3 |                 -3.0 → -12.5 |                 -10.4 → -20.2 |
| Uciea Keyboard                             |                  -55.1 → -64.0 |                 -44.6 → -54.5 |                -23.1 → -36.6 |                 -21.5 → -33.8 |
| KOY                                        |                  -55.1 → -69.5 |                 -56.0 → -71.6 |                -13.1 → -23.9 |                 -14.3 → -25.6 |
| Sclarb                                     |                  -55.1 → -63.4 |                 -51.7 → -60.8 |                -31.1 → -40.7 |                 -36.2 → -46.7 |
| Ashe                                       |                  -55.1 → -66.7 |                 -60.0 → -71.9 |                -48.1 → -58.9 |                 -51.7 → -63.6 |
| Gallium Colstag                            |                  -55.1 → -68.7 |                 -44.1 → -58.2 |                   9.0 → -1.8 |                  -3.2 → -16.7 |
| Culemak Mod Ian HP                         |                  -55.2 → -62.4 |                 -51.1 → -59.7 |                -32.3 → -40.5 |                 -29.6 → -39.6 |
| Colemak Estonian                           |                  -55.3 → -61.8 |                 -51.3 → -59.6 |                -35.8 → -44.2 |                 -31.3 → -41.3 |
| Gallium Angle                              |                  -55.3 → -67.2 |                 -47.0 → -59.7 |                   7.4 → -6.8 |                  -5.4 → -21.0 |
| Kirana Melayu                              |                  -55.4 → -67.7 |                 -57.7 → -70.6 |                -52.3 → -61.3 |                 -56.8 → -67.5 |
| Rhea                                       |                  -55.4 → -68.5 |                 -47.4 → -59.6 |                 -2.5 → -13.1 |                 -12.1 → -24.0 |
| Celestial (KLAnext)                        |                  -55.5 → -67.4 |                 -45.0 → -57.2 |                   1.2 → -8.1 |                  -8.8 → -18.9 |
| Eka                                        |                  -55.5 → -68.4 |                 -42.8 → -55.7 |                   6.3 → -7.0 |                  -6.7 → -20.4 |
| Bone                                       |                  -55.6 → -69.2 |                 -52.2 → -65.9 |                -42.9 → -55.5 |                 -53.2 → -64.8 |
| Gallium                                    |                  -55.6 → -67.0 |                 -47.3 → -59.7 |                   7.0 → -6.9 |                  -6.0 → -21.2 |
| Beakl Stretch                              |                  -55.7 → -72.4 |                 -63.3 → -79.7 |                -37.8 → -52.4 |                 -47.7 → -64.1 |
| Adnw English Bigram                        |                  -55.9 → -66.9 |                 -48.6 → -59.0 |                -12.2 → -22.9 |                 -10.9 → -22.5 |
| Focal                                      |                  -56.0 → -67.3 |                 -44.5 → -55.9 |                 -3.1 → -16.0 |                  -8.3 → -21.6 |
| Sturdy Anglemod                            |                  -56.1 → -68.7 |                 -43.8 → -55.5 |                   4.9 → -7.1 |                  -3.4 → -16.0 |
| Bone (ß in the home row)                   |                  -56.1 → -69.8 |                 -52.3 → -66.0 |                -43.0 → -55.6 |                 -53.2 → -64.8 |
| Vylet                                      |                  -56.3 → -66.6 |                 -52.2 → -63.3 |                   1.1 → -7.3 |                 -13.9 → -23.9 |
| Dvimcat                                    |                  -56.3 → -73.0 |                 -42.7 → -57.9 |                 -0.1 → -13.2 |                  -7.2 → -21.2 |
| Asset (KLA)                                |                  -56.3 → -65.7 |                 -60.2 → -70.3 |                -56.0 → -65.5 |                 -52.4 → -63.0 |
| Real 2                                     |                  -56.4 → -73.0 |                 -45.5 → -60.1 |                 -5.8 → -17.1 |                 -10.9 → -21.1 |
| Tarmak 3 (ETR)                             |                  -56.5 → -67.1 |                 -61.2 → -73.4 |                -79.0 → -92.1 |                 -62.8 → -76.6 |
| Colemak Cub                                |                  -56.5 → -65.3 |                 -54.6 → -64.1 |                -41.2 → -50.5 |                 -35.7 → -45.7 |
| Hands On (sym)                             |                  -56.6 → -64.6 |                 -57.1 → -67.3 |                -44.0 → -55.6 |                 -45.9 → -58.4 |
| Colibius August                            |                  -56.8 → -67.0 |                 -48.0 → -58.7 |                -20.4 → -30.7 |                 -23.8 → -35.1 |
| Colemak Mod JPH                            |                  -56.8 → -65.9 |                 -56.7 → -65.9 |               -93.4 → -103.0 |                 -77.4 → -88.2 |
| Noctum                                     |                  -56.8 → -70.6 |                 -45.2 → -59.0 |                   6.5 → -6.6 |                  -7.2 → -21.2 |
| Sturdy                                     |                  -56.9 → -69.5 |                 -43.6 → -55.3 |                   4.6 → -7.4 |                  -3.4 → -16.1 |
| Colemak Textblade                          |                  -57.1 → -63.1 |                 -58.5 → -66.0 |                -42.2 → -50.8 |                 -42.6 → -51.7 |
| STNDC                                      |                  -57.1 → -67.8 |                 -49.3 → -60.3 |                 -4.5 → -13.1 |                 -12.9 → -22.1 |
| Gemini                                     |                  -57.4 → -71.2 |                 -47.6 → -61.0 |                   3.9 → -8.4 |                  -4.1 → -17.5 |
| Fire                                       |                  -57.4 → -71.2 |                 -47.6 → -61.8 |                   3.4 → -9.1 |                  -5.3 → -20.1 |
| Tarmak 4 (ETRO)                            |                  -57.5 → -65.7 |                 -54.9 → -65.0 |                -60.5 → -70.4 |                 -53.6 → -65.4 |
| Paw177 Mod Ian                             |                  -57.5 → -68.5 |                 -50.8 → -61.8 |                -12.7 → -24.3 |                 -13.1 → -25.2 |
| Lela Rus                                   |                  -57.5 → -71.0 |                 -46.9 → -60.2 |                  0.4 → -12.6 |                  -8.0 → -21.5 |
| Hands Down Polyglot (sym)                  |                  -57.9 → -71.3 |                 -50.2 → -65.0 |                -24.7 → -37.4 |                 -26.4 → -41.0 |
| Flame                                      |                  -58.0 → -71.4 |                 -46.3 → -58.4 |                 -1.5 → -14.3 |                  -8.0 → -21.2 |
| Beakl 4 Mod Ian 1                          |                  -58.1 → -69.3 |                 -52.4 → -64.4 |                -13.3 → -24.3 |                 -23.0 → -35.2 |
| Asset                                      |                  -58.1 → -67.5 |                 -58.2 → -68.3 |                -53.7 → -63.2 |                 -49.5 → -60.1 |
| Flame (KLAnext)                            |                  -58.2 → -71.6 |                 -44.8 → -56.9 |                 -0.4 → -13.2 |                  -5.5 → -18.8 |
| Solemak                                    |                  -58.2 → -67.1 |                 -54.6 → -65.5 |                -31.4 → -41.0 |                 -34.2 → -46.4 |
| Colemak Lite                               |                  -58.4 → -66.8 |                 -64.5 → -74.5 |                -29.9 → -39.9 |                 -35.1 → -46.4 |
| Colibius August Mod Ian                    |                  -58.4 → -70.3 |                 -54.1 → -67.1 |                -32.9 → -44.6 |                 -32.7 → -45.9 |
| Boo                                        |                  -58.4 → -70.4 |                 -51.3 → -61.7 |                 -8.1 → -17.0 |                 -19.2 → -28.2 |
| Asrt                                       |                  -58.6 → -66.8 |                 -55.1 → -65.2 |                -36.9 → -46.4 |                 -36.3 → -47.6 |
| Semimak                                    |                  -58.6 → -73.1 |                 -51.2 → -67.7 |                 -0.3 → -13.7 |                  -9.4 → -23.4 |
| Ruthenium NL                               |                  -58.8 → -72.2 |                 -53.2 → -67.5 |                 -1.2 → -12.6 |                 -13.3 → -27.1 |
| Righty                                     |                  -58.8 → -71.7 |                 -60.7 → -73.6 |                -45.9 → -57.1 |                 -46.5 → -59.7 |
| Rukia                                      |                  -58.8 → -69.7 |                 -53.5 → -65.1 |                -30.9 → -42.2 |                 -30.2 → -42.2 |
| Vu Keys                                    |                  -58.9 → -67.4 |                 -53.9 → -64.7 |                -37.1 → -48.9 |                 -36.8 → -49.3 |
| Nila                                       |                  -59.0 → -72.6 |                 -55.7 → -70.2 |                  1.4 → -10.8 |                 -13.7 → -27.8 |
| Blaze                                      |                  -59.0 → -73.3 |                 -47.7 → -61.8 |                 -0.3 → -12.7 |                  -8.8 → -23.5 |
| Ough                                       |                  -59.1 → -67.8 |                 -67.7 → -77.5 |                -36.2 → -46.6 |                 -47.7 → -58.8 |
| Lela                                       |                  -59.1 → -78.7 |                 -50.7 → -71.4 |                  1.6 → -14.3 |                  -9.7 → -28.1 |
| Hydrogen                                   |                  -59.1 → -72.8 |                 -50.3 → -62.6 |                   5.0 → -6.9 |                  -9.7 → -22.0 |
| Colevim                                    |                  -59.3 → -67.4 |                 -59.8 → -68.9 |                -37.1 → -45.3 |                 -32.6 → -42.7 |
| Optimal Digram                             |                  -59.3 → -69.4 |                 -49.8 → -59.8 |                -16.1 → -26.3 |                 -12.8 → -23.9 |
| Hands Down Alt (ortho)                     |                  -59.4 → -68.6 |                 -54.4 → -64.6 |                -25.3 → -36.3 |                 -35.6 → -46.6 |
| Stndc (KLAnext)                            |                  -59.6 → -70.8 |                 -50.8 → -62.2 |                 -9.5 → -18.3 |                 -15.0 → -24.4 |
| Blaze (KLAnext)                            |                  -59.7 → -73.9 |                 -47.7 → -61.8 |                  1.0 → -11.4 |                  -7.8 → -22.5 |
| Dhorf (KLAnext)                            |                  -59.9 → -73.7 |                 -51.5 → -65.3 |                 -3.5 → -17.0 |                  -8.7 → -23.0 |
| Rolll                                      |                  -59.9 → -77.3 |                 -49.0 → -65.6 |                 -3.3 → -14.0 |                  -8.2 → -20.0 |
| Poutea                                     |                  -60.1 → -70.1 |                 -54.6 → -66.0 |                -48.6 → -62.0 |                 -44.6 → -58.0 |
| Hands Down XKCD                            |                  -60.2 → -75.5 |                 -49.9 → -64.0 |                -54.7 → -71.0 |                 -54.4 → -71.9 |
| Dangvu                                     |                  -60.3 → -68.7 |                 -55.0 → -65.2 |                -42.5 → -54.4 |                 -41.1 → -53.9 |
| S-Roll                                     |                  -60.3 → -74.2 |                 -47.9 → -60.8 |                   5.1 → -5.3 |                  -8.0 → -20.1 |
| Recurva                                    |                  -60.3 → -74.7 |                 -51.3 → -65.4 |                 -3.9 → -18.0 |                 -12.2 → -28.1 |
| Chendan Cmu Punctuation                    |                  -60.4 → -72.1 |                 -49.7 → -62.7 |                -21.9 → -33.7 |                 -25.9 → -38.6 |
| Another Method Non                         |                  -60.5 → -78.9 |                 -56.5 → -71.6 |                -36.0 → -47.8 |                 -34.6 → -47.0 |
| Celestial                                  |                  -60.5 → -73.1 |                 -46.8 → -59.0 |                 -3.8 → -14.2 |                 -10.5 → -21.1 |
| Oistd                                      |                  -60.7 → -72.0 |                 -65.5 → -76.4 |                -34.7 → -42.8 |                 -38.8 → -47.3 |
| Colemaq (KLAnext)                          |                  -60.8 → -68.0 |                 -56.2 → -64.2 |                -32.4 → -39.6 |                 -32.8 → -41.8 |
| Rolll (genkey)                             |                  -60.9 → -78.1 |                 -50.3 → -66.9 |                 -3.9 → -14.4 |                  -9.2 → -21.0 |
| Chendan Cmu ZXCV                           |                  -60.9 → -70.5 |                 -59.5 → -70.5 |                -40.8 → -51.4 |                 -40.1 → -51.8 |
| Wordslow SF                                |                  -60.9 → -73.7 |                 -62.3 → -75.8 |                 -6.6 → -19.8 |                 -22.4 → -35.7 |
| Colemaq                                    |                  -61.0 → -68.2 |                 -56.5 → -64.5 |                -33.4 → -40.6 |                 -33.1 → -42.1 |
| Xenia                                      |                  -61.2 → -75.4 |                 -54.4 → -68.9 |                  2.4 → -10.4 |                 -13.2 → -26.5 |
| Colman                                     |                  -61.3 → -71.8 |                 -53.1 → -65.5 |                -26.8 → -38.1 |                 -32.3 → -45.5 |
| Colemaq-F                                  |                  -61.3 → -68.5 |                 -56.0 → -64.0 |                -31.2 → -38.5 |                 -32.2 → -41.2 |
| Balanced                                   |                  -61.6 → -70.8 |                 -64.8 → -73.4 |                -32.6 → -41.3 |                 -41.7 → -51.1 |
| Dhorf                                      |                  -61.6 → -76.0 |                 -52.1 → -66.6 |                 -3.8 → -16.5 |                  -9.9 → -23.9 |
| Hands On                                   |                  -61.9 → -70.5 |                 -59.3 → -70.2 |                -47.8 → -60.0 |                 -46.8 → -60.0 |
| Noctum (KLAnext)                           |                  -62.0 → -75.2 |                 -53.1 → -66.8 |                 -1.4 → -12.3 |                 -13.6 → -27.1 |
| Uiy G Ansi Maks                            |                  -62.2 → -73.7 |                 -57.2 → -70.7 |                -39.5 → -52.0 |                 -42.0 → -56.9 |
| N Ansi Maks                                |                  -62.3 → -79.3 |                 -61.2 → -75.7 |                -15.6 → -26.4 |                 -23.5 → -35.5 |
| Stronk                                     |                  -62.4 → -77.0 |                 -49.0 → -63.8 |                 -5.1 → -18.4 |                  -9.2 → -24.2 |
| Ali Kian                                   |                  -62.4 → -73.4 |                 -69.7 → -82.0 |                -67.1 → -77.6 |                 -58.2 → -70.2 |
| Thallium                                   |                  -62.6 → -76.6 |                 -52.8 → -68.8 |                 -6.5 → -18.2 |                  -9.2 → -22.0 |
| BvoFRak EN V0.5                            |                  -62.6 → -73.5 |                 -60.3 → -71.6 |                -36.0 → -48.9 |                 -35.1 → -48.1 |
| Synth                                      |                  -62.7 → -78.7 |                 -57.3 → -73.4 |                 -1.3 → -15.3 |                 -12.2 → -27.4 |
| Aehi                                       |                  -63.0 → -75.4 |                 -61.4 → -74.3 |                -22.9 → -34.3 |                 -24.8 → -37.6 |
| Bubbletea                                  |                  -63.0 → -71.9 |                 -55.6 → -66.2 |                -57.8 → -70.3 |                 -48.9 → -61.8 |
| Xsvmtkrnl Fhy                              |                  -63.3 → -76.8 |                 -57.6 → -71.4 |                   4.8 → -7.7 |                 -11.9 → -26.3 |
| Argon                                      |                  -63.5 → -79.8 |                 -53.1 → -68.9 |                 -0.8 → -13.8 |                 -12.6 → -27.5 |
| Hands Down Alt (sym)                       |                  -63.5 → -72.5 |                 -56.8 → -67.4 |                -30.9 → -42.1 |                 -33.6 → -45.6 |
| SHZ                                        |                  -63.6 → -79.1 |                 -65.7 → -81.6 |                -31.1 → -45.6 |                 -40.5 → -56.5 |
| Zsvmtjrnl Fkhy                             |                  -63.8 → -77.7 |                 -57.1 → -71.3 |                   5.1 → -7.5 |                 -10.8 → -24.9 |
| Flare (KLAnext)                            |                  -63.8 → -78.8 |                 -54.1 → -67.9 |                 -2.7 → -17.0 |                 -10.5 → -25.5 |
| Astarte                                    |                  -63.9 → -73.8 |                 -65.0 → -75.7 |                -40.7 → -52.5 |                 -46.9 → -59.2 |
| G Ansi Maks                                |                  -64.0 → -78.2 |                 -62.8 → -77.6 |                -24.5 → -37.5 |                 -33.7 → -48.8 |
| Mine                                       |                  -64.2 → -74.1 |                 -56.3 → -66.9 |                -35.1 → -43.2 |                 -43.0 → -50.9 |
| Nrstmak                                    |                  -64.2 → -78.2 |                 -55.0 → -67.6 |                -12.0 → -22.1 |                 -18.7 → -31.3 |
| Beakl Hm1 Mod Ian                          |                  -64.5 → -76.7 |                 -72.5 → -86.1 |                -53.0 → -65.5 |                 -64.9 → -79.9 |
| Noted                                      |                  -64.5 → -77.3 |                 -58.9 → -72.4 |                -31.8 → -40.9 |                 -34.7 → -44.2 |
| Rain                                       |                  -64.7 → -76.9 |                 -55.8 → -68.6 |                 -2.0 → -13.0 |                 -12.7 → -24.7 |
| Nitro S                                    |                  -64.9 → -76.0 |                 -54.0 → -65.2 |                 -2.3 → -14.4 |                 -14.6 → -27.0 |
| Rain (KLAnext)                             |                  -65.1 → -76.5 |                 -54.8 → -66.1 |                 -3.0 → -13.4 |                 -10.9 → -22.4 |
| Freq3                                      |                  -65.2 → -79.2 |                 -59.8 → -75.5 |                -13.3 → -27.1 |                 -20.0 → -35.7 |
| Em0gus                                     |                  -65.3 → -80.4 |                 -54.2 → -67.7 |                 -2.1 → -16.4 |                 -10.1 → -25.0 |
| Setrain                                    |                  -65.5 → -79.9 |                 -55.2 → -69.6 |                  2.7 → -10.6 |                 -10.2 → -24.9 |
| Stance                                     |                  -65.8 → -78.2 |                 -55.4 → -66.7 |                 -8.5 → -17.4 |                 -18.2 → -28.1 |
| Iaenh                                      |                  -65.8 → -75.8 |                 -62.7 → -73.2 |                -59.9 → -68.5 |                 -54.8 → -65.0 |
| Minimotion                                 |                  -65.8 → -76.3 |                 -65.5 → -75.7 |                -33.5 → -42.4 |                 -35.1 → -45.3 |
| Beakl421 Mod Ian                           |                  -66.1 → -75.7 |                 -56.6 → -68.3 |                -15.3 → -27.7 |                 -21.7 → -35.4 |
| Hrnia                                      |                  -66.1 → -83.4 |                 -67.2 → -81.3 |                -39.1 → -49.5 |                 -47.4 → -58.7 |
| Uciea Vanilla                              |                  -66.1 → -76.9 |                 -54.4 → -66.4 |                -27.8 → -42.7 |                 -21.6 → -34.7 |
| Seht Drai                                  |                  -66.3 → -77.9 |                 -64.9 → -77.4 |                 -6.2 → -17.6 |                 -21.3 → -33.9 |
| Atreyata                                   |                  -66.4 → -73.1 |                 -57.5 → -65.3 |                -37.9 → -46.3 |                 -30.4 → -39.8 |
| Rotsw                                      |                  -66.4 → -76.5 |                 -72.1 → -82.7 |                -74.3 → -84.7 |                 -69.5 → -80.9 |
| Colemak HU                                 |                  -66.5 → -77.1 |                 -55.1 → -66.3 |                -38.2 → -45.6 |                 -34.9 → -44.2 |
| Vimak                                      |                  -66.5 → -74.7 |                 -64.1 → -73.6 |                -36.1 → -44.6 |                 -34.8 → -45.6 |
| Romberg                                    |                  -66.6 → -74.9 |                 -75.1 → -84.5 |                -89.4 → -98.3 |                 -80.8 → -90.8 |
| Ttast                                      |                  -66.6 → -79.6 |                 -71.8 → -84.3 |                -55.1 → -68.5 |                 -58.6 → -72.4 |
| Snorkle                                    |                  -66.7 → -78.5 |                 -62.5 → -73.7 |                 -7.2 → -16.8 |                 -16.7 → -26.7 |
| Doerak                                     |                  -66.7 → -81.3 |                 -63.7 → -80.2 |                -44.4 → -65.3 |                 -46.3 → -66.5 |
| Balance 12                                 |                  -66.8 → -77.2 |                 -41.5 → -52.8 |                -23.7 → -35.5 |                 -18.0 → -30.3 |
| Flare                                      |                  -66.8 → -79.6 |                 -56.7 → -69.1 |                 -1.8 → -15.7 |                  -9.4 → -24.2 |
| Whorf Am                                   |                  -66.8 → -83.4 |                 -55.1 → -72.6 |                 -1.4 → -14.5 |                 -12.1 → -28.0 |
| Code Weaver                                |                  -67.3 → -77.8 |                 -58.8 → -70.3 |                -50.7 → -61.3 |                 -47.9 → -58.5 |
| Whorf                                      |                  -67.4 → -84.1 |                 -55.3 → -72.9 |                  0.3 → -12.8 |                 -11.1 → -27.0 |
| Lumin                                      |                  -67.4 → -80.5 |                 -47.6 → -58.7 |                -12.1 → -23.1 |                 -14.4 → -24.6 |
| Phynnboi                                   |                  -67.4 → -77.3 |                 -69.7 → -80.2 |                -33.8 → -43.9 |                 -40.2 → -52.0 |
| Colemak DH Ring 20211116                   |                  -67.4 → -74.4 |                 -60.7 → -68.3 |                -33.6 → -40.0 |                 -33.7 → -41.7 |
| Acemak 1                                   |                  -67.5 → -76.1 |                 -64.5 → -74.3 |                -47.7 → -57.7 |                 -44.7 → -56.3 |
| Real                                       |                  -67.7 → -75.3 |                 -50.9 → -59.5 |                -11.0 → -19.5 |                 -17.8 → -27.2 |
| Workwoman                                  |                  -67.8 → -77.1 |                 -58.8 → -69.7 |                -39.0 → -51.9 |                 -32.1 → -45.3 |
| Hands Down Alt-x                           |                  -67.9 → -77.4 |                 -51.9 → -63.1 |                -29.6 → -42.1 |                 -30.5 → -43.5 |
| Trendy (KLAnext)                           |                  -68.1 → -82.4 |                 -54.8 → -67.8 |                 -3.0 → -14.4 |                  -8.0 → -20.6 |
| JPPE                                       |                  -68.2 → -77.4 |                 -65.7 → -75.0 |               -95.9 → -105.5 |                 -78.5 → -89.3 |
| Hands On (ortho)                           |                  -68.4 → -77.9 |                 -72.0 → -83.0 |                -45.5 → -55.6 |                 -54.5 → -65.9 |
| Lumin (KLAnext)                            |                  -68.7 → -81.9 |                 -48.2 → -59.3 |                -12.8 → -23.9 |                 -14.1 → -24.3 |
| Workman                                    |                  -68.9 → -80.8 |                 -67.8 → -80.5 |                -38.4 → -49.7 |                 -44.9 → -57.7 |
| Quesnel Mtgap                              |                  -68.9 → -78.7 |                 -62.4 → -72.7 |                -30.2 → -41.7 |                 -29.6 → -42.0 |
| Colemaq F                                  |                  -69.3 → -76.7 |                 -65.9 → -73.9 |                -34.1 → -42.0 |                 -35.4 → -44.9 |
| Three Vanilla                              |                  -69.5 → -78.3 |                 -71.9 → -81.9 |                -27.2 → -37.0 |                 -41.5 → -53.3 |
| Box X                                      |                  -69.5 → -79.6 |                 -69.2 → -80.3 |                -40.6 → -51.0 |                 -46.9 → -59.5 |
| Kilo 62 Vanilla                            |                  -69.7 → -77.4 |                 -66.2 → -75.3 |                -26.4 → -35.5 |                 -34.9 → -45.0 |
| Aryo                                       |                  -70.0 → -81.2 |                 -64.3 → -76.3 |                -64.0 → -73.9 |                 -57.4 → -70.0 |
| ZX 1                                       |                  -70.0 → -79.5 |                 -60.8 → -71.8 |                -47.3 → -56.8 |                 -44.4 → -56.3 |
| Dutchman                                   |                  -70.4 → -80.7 |                 -69.6 → -80.7 |                -32.1 → -42.5 |                 -37.7 → -50.0 |
| Pine (KLAnext)                             |                  -70.4 → -84.0 |                 -64.9 → -78.5 |                 -8.5 → -23.0 |                 -18.0 → -34.1 |
| Pine                                       |                  -70.5 → -84.1 |                 -64.4 → -78.0 |                 -8.6 → -23.1 |                 -18.1 → -34.2 |
| Seruxie                                    |                  -70.5 → -78.0 |                 -68.7 → -77.8 |                -41.8 → -50.9 |                 -39.3 → -50.1 |
| Hieaqmtsrn                                 |                  -70.6 → -80.2 |                 -79.8 → -91.5 |                -25.1 → -35.9 |                 -51.2 → -64.0 |
| Qwicklystep2                               |                  -70.9 → -79.6 |                 -81.6 → -91.4 |                -71.6 → -81.4 |                 -66.2 → -76.8 |
| Rusk                                       |                  -71.1 → -83.2 |                 -80.7 → -94.5 |                -61.8 → -73.9 |                 -83.1 → -99.0 |
| Trendy                                     |                  -71.6 → -86.1 |                 -55.9 → -68.9 |                 -2.6 → -14.2 |                  -7.7 → -20.2 |
| Jyz                                        |                  -71.6 → -81.9 |                 -69.3 → -80.8 |                -29.4 → -42.3 |                 -33.3 → -46.4 |
| Workman for Programmers                    |                  -71.6 → -83.2 |                 -71.8 → -84.3 |                -41.0 → -51.6 |                 -49.3 → -62.3 |
| Light Anderson Mod Ian                     |                  -71.6 → -84.0 |                 -69.0 → -80.9 |                -48.7 → -59.1 |                 -51.4 → -63.3 |
| Dvorak                                     |                  -71.7 → -81.5 |                 -74.6 → -85.4 |                -30.4 → -40.3 |                 -37.0 → -48.8 |
| Sorenk                                     |                  -71.8 → -83.6 |                 -58.8 → -69.6 |                -37.2 → -44.7 |                 -35.5 → -43.9 |
| Spanish Dvorak (Jorge Sanz)                |                  -72.3 → -83.5 |                 -74.4 → -85.4 |                -50.9 → -62.9 |                 -50.4 → -62.9 |
| Dvorak IU Swap                             |                  -72.9 → -82.7 |                 -75.5 → -86.3 |                -29.1 → -39.0 |                 -35.6 → -47.3 |
| Seht Drai (KLAnext)                        |                  -72.9 → -91.0 |                 -70.0 → -86.8 |                 -5.1 → -17.1 |                 -21.0 → -33.8 |
| Eito                                       |                  -72.9 → -88.9 |                 -66.9 → -83.8 |                -24.5 → -39.4 |                 -30.3 → -45.1 |
| Qphyx Adapted                              |                  -73.0 → -81.8 |                 -57.7 → -67.9 |                -28.6 → -38.8 |                 -26.0 → -38.0 |
| OISEAU                                     |                  -73.0 → -82.7 |                 -73.8 → -84.6 |                -35.0 → -44.8 |                 -41.3 → -53.2 |
| Qwickly Nrio                               |                  -73.1 → -84.8 |                 -71.9 → -83.6 |                -40.1 → -50.8 |                 -49.5 → -61.3 |
| X7 2h                                      |                  -73.1 → -87.3 |                 -78.5 → -94.4 |               -88.7 → -105.5 |                -99.8 → -117.9 |
| Rsi Terminated Vanilla                     |                  -73.2 → -80.8 |                 -66.6 → -74.7 |                -38.4 → -47.3 |                 -37.6 → -46.9 |
| Hands Down Alt-x (ortho)                   |                  -73.2 → -82.4 |                 -64.9 → -76.0 |                -27.5 → -39.3 |                 -37.1 → -49.4 |
| Niro                                       |                  -73.6 → -84.8 |                 -74.2 → -85.7 |                -41.0 → -52.0 |                 -48.5 → -59.9 |
| Adore                                      |                  -73.9 → -81.1 |                 -69.2 → -77.5 |                -72.2 → -81.5 |                 -67.5 → -77.9 |
| Vukeys Swapped Mod Ian 2                   |                  -73.9 → -83.6 |                 -82.9 → -93.2 |                -47.7 → -56.5 |                 -56.3 → -67.4 |
| BEAKL-15                                   |                  -74.0 → -89.5 |                 -71.7 → -87.4 |                -66.0 → -78.5 |                 -58.2 → -73.2 |
| Dvorak Mod Ian                             |                  -74.0 → -83.0 |                 -67.5 → -77.6 |                -31.5 → -41.6 |                 -38.9 → -50.4 |
| KHLC                                       |                  -74.1 → -81.7 |                 -66.2 → -75.4 |                -70.0 → -81.2 |                 -57.3 → -68.9 |
| Qwicklystep3                               |                  -74.1 → -85.3 |                 -75.5 → -87.1 |                -49.0 → -60.1 |                 -50.9 → -62.2 |
| Dvorak-fr (Francis Leboutte)               |                  -74.1 → -88.9 |                 -81.6 → -97.6 |              -113.0 → -126.2 |               -121.4 → -137.9 |
| Workman Cub                                |                  -74.3 → -88.6 |                 -74.4 → -88.7 |                -44.3 → -56.5 |                 -50.7 → -63.8 |
| Minimak-12                                 |                  -74.4 → -84.0 |                 -81.3 → -92.7 |                -82.6 → -94.6 |                 -78.4 → -91.0 |
| Vas Keys                                   |                  -74.8 → -83.0 |                 -63.9 → -74.2 |                -40.2 → -50.8 |                 -36.2 → -48.0 |
| Hands Down Polyglot (ErgoDox)              |                  -75.1 → -87.6 |                 -68.9 → -83.2 |                -30.6 → -43.0 |                 -39.0 → -53.6 |
| Keyboardsamurai July                       |                  -75.3 → -82.5 |                 -79.3 → -88.2 |                -67.3 → -75.7 |                 -55.5 → -66.1 |
| Programmer Dvorak - Ordered Numbers        |                  -75.8 → -85.5 |                 -80.1 → -91.0 |                -34.0 → -44.5 |                 -42.5 → -54.6 |
| Qwicklystep4                               |                  -75.8 → -87.3 |                 -74.7 → -86.2 |                -37.7 → -48.8 |                 -46.1 → -57.7 |
| Qwickly Comma                              |                  -76.0 → -87.4 |                 -75.6 → -86.8 |                -41.7 → -52.0 |                 -48.0 → -59.0 |
| Yak                                        |                  -76.4 → -87.3 |                -93.8 → -106.8 |              -102.2 → -113.5 |                -98.0 → -111.1 |
| Qwickly KZ Comma                           |                  -76.7 → -88.1 |                 -76.6 → -87.8 |                -41.7 → -52.0 |                 -49.9 → -60.9 |
| Typehack                                   |                  -76.8 → -90.3 |                 -78.8 → -92.7 |                -21.3 → -33.9 |                 -34.7 → -48.1 |
| Big Guyy                                   |                  -76.9 → -86.8 |                 -73.6 → -85.5 |                -41.9 → -54.2 |                 -49.3 → -63.0 |
| Chendan Cmu No Contraints                  |                  -77.0 → -93.6 |                 -68.1 → -81.6 |                -26.6 → -42.2 |                 -34.2 → -47.5 |
| Einbinder 10 Finger                        |                  -77.3 → -94.8 |                 -77.5 → -94.7 |                -59.5 → -73.4 |                 -59.8 → -74.1 |
| Gelatin                                    |                  -77.6 → -84.1 |                 -73.9 → -82.4 |                -65.1 → -73.4 |                 -56.5 → -66.6 |
| EAton                                      |                  -77.8 → -88.1 |                 -79.7 → -91.7 |                -28.6 → -40.4 |                 -40.2 → -53.7 |
| Dvorak Original Numbers                    |                  -78.0 → -88.1 |                 -86.5 → -97.2 |                -34.1 → -44.0 |                 -43.7 → -55.1 |
| Rusk Mod Ian                               |                  -78.4 → -89.7 |                 -81.0 → -94.0 |                -65.1 → -76.8 |                 -75.0 → -89.2 |
| Smartly Modified Dvorak                    |                  -79.3 → -87.1 |                 -83.6 → -92.6 |                -46.9 → -55.7 |                 -50.5 → -61.0 |
| GG Beakl 15                                |                  -79.3 → -94.3 |                 -76.6 → -91.7 |                -73.0 → -85.0 |                 -63.5 → -77.8 |
| Klausler                                   |                  -79.6 → -93.2 |                 -78.1 → -90.1 |                -34.3 → -44.7 |                 -48.3 → -59.7 |
| QWPR                                       |                  -79.9 → -89.7 |                 -87.8 → -99.5 |                -83.1 → -93.8 |                 -75.7 → -87.9 |
| As In Red Hot Mod Ian                      |                  -81.5 → -92.8 |                 -81.4 → -93.8 |                -67.9 → -79.3 |                 -69.4 → -82.0 |
| Svorak-r                                   |                  -81.9 → -91.7 |                 -78.7 → -89.1 |                -36.5 → -46.1 |                 -39.4 → -50.7 |
| Capewell-Dvorak                            |                  -82.4 → -92.2 |                 -77.9 → -88.4 |                -34.5 → -45.2 |                 -42.1 → -53.9 |
| Autogen 1                                  |                  -83.1 → -96.0 |                -88.6 → -101.2 |                -10.5 → -20.2 |                 -34.7 → -46.3 |
| The 1                                      |                  -83.2 → -95.1 |                 -75.4 → -87.4 |                -35.5 → -45.9 |                 -34.9 → -46.7 |
| JNSF                                       |                  -83.6 → -94.0 |                 -87.5 → -98.6 |                -75.3 → -83.9 |                 -69.7 → -79.8 |
| Hands Down Polyglot (ortho)                |                  -83.6 → -95.3 |                 -79.3 → -92.3 |                -38.4 → -50.8 |                 -45.2 → -58.3 |
| Kaeteker's Modified Dvorak                 |                  -83.8 → -92.7 |                 -82.0 → -92.2 |                -39.7 → -49.4 |                 -46.4 → -58.4 |
| Halmak                                     |                  -84.1 → -97.4 |                 -80.1 → -94.8 |                -34.1 → -47.5 |                 -37.4 → -52.4 |
| Arsonite                                   |                  -84.6 → -93.3 |               -103.5 → -113.4 |                -82.6 → -92.5 |                 -84.0 → -94.8 |
| Minimak 8-key                              |                  -85.0 → -97.6 |                -92.3 → -106.6 |               -89.0 → -102.7 |                -87.2 → -101.9 |
| Ina DV                                     |                  -85.2 → -96.3 |                 -80.3 → -93.1 |              -125.9 → -141.1 |               -119.7 → -136.5 |
| Willems                                    |                  -85.4 → -96.7 |               -106.9 → -118.3 |                -78.8 → -93.6 |                -93.5 → -107.5 |
| Heads Up                                   |                  -85.6 → -94.9 |                -97.3 → -107.9 |                -70.3 → -80.3 |                 -74.3 → -85.6 |
| Benkeyless                                 |                  -85.6 → -95.7 |                 -88.4 → -99.7 |                -77.1 → -87.4 |                 -76.5 → -88.3 |
| Ninedotnine                                |                  -86.0 → -99.7 |                -92.0 → -106.4 |                -80.9 → -93.7 |                 -78.9 → -93.0 |
| Ninedotnine Mod Ian                        |                  -86.0 → -98.9 |                -96.1 → -109.6 |               -88.6 → -102.2 |                 -84.1 → -98.8 |
| Etni                                       |                 -86.1 → -107.3 |                -98.5 → -119.5 |               -87.7 → -109.1 |                -85.1 → -108.1 |
| Lowerpinky                                 |                  -86.5 → -97.5 |                 -84.8 → -96.3 |                -54.5 → -64.3 |                 -56.9 → -68.0 |
| Dvorak (classic)                           |                  -86.6 → -97.7 |                -95.5 → -107.5 |                -31.1 → -41.1 |                 -38.5 → -50.0 |
| Goettl Brugh Julstrom                      |                 -87.0 → -109.9 |                -86.4 → -106.5 |                -57.7 → -74.5 |                 -62.7 → -79.1 |
| Halmak (cyanophage)                        |                  -87.5 → -99.9 |                 -82.0 → -95.9 |                -34.1 → -46.7 |                 -37.1 → -51.4 |
| Frontier                                   |                 -87.5 → -100.8 |                 -64.3 → -77.0 |                -50.1 → -60.3 |                 -50.4 → -61.6 |
| X6 2h                                      |                  -87.8 → -94.7 |                -99.1 → -106.6 |              -113.9 → -122.2 |                -95.8 → -105.0 |
| Bgrassy                                    |                 -88.2 → -102.9 |                -85.1 → -101.2 |                -39.0 → -53.1 |                 -50.1 → -66.7 |
| Tarmak 2                                   |                 -88.7 → -101.7 |                -95.4 → -109.8 |              -101.0 → -115.6 |                -90.2 → -105.6 |
| Code                                       |                  -88.9 → -97.2 |                 -84.1 → -93.9 |                -41.9 → -52.1 |                 -48.7 → -60.4 |
| Syperk Qwfrj                               |                 -89.5 → -102.6 |                -96.2 → -110.7 |              -100.4 → -115.1 |                -90.4 → -105.9 |
| Rstlne Manual                              |                  -90.4 → -99.1 |               -104.5 → -114.6 |                -87.6 → -97.3 |                -94.6 → -105.9 |
| Wong Oiuea                                 |                 -91.8 → -100.2 |                 -90.3 → -99.5 |              -144.0 → -154.5 |               -128.9 → -139.4 |
| Workman LD                                 |                 -93.2 → -104.0 |                 -79.0 → -91.1 |                -45.8 → -56.1 |                 -40.7 → -53.3 |
| Liigol                                     |                 -93.9 → -102.5 |               -101.0 → -111.5 |                -63.6 → -74.6 |                 -81.8 → -93.8 |
| Alphametric                                |                 -94.7 → -103.9 |                -94.4 → -105.0 |                -54.7 → -66.6 |                 -52.8 → -65.3 |
| NTSC                                       |                 -94.7 → -108.3 |                -89.3 → -103.2 |                -49.3 → -61.3 |                 -60.1 → -74.2 |
| Heiadtsrn WFGV                             |                 -94.8 → -111.2 |                -94.1 → -109.5 |                -26.6 → -37.5 |                 -52.0 → -64.9 |
| Dnat                                       |                 -95.1 → -117.6 |                -91.7 → -111.6 |               -99.3 → -122.0 |                -95.5 → -116.5 |
| Pittard                                    |                 -95.6 → -105.6 |                -92.5 → -103.0 |               -91.9 → -102.6 |                 -81.1 → -93.0 |
| Colemak Wide                               |                 -95.6 → -103.1 |               -104.8 → -114.1 |                -46.9 → -56.1 |                 -65.1 → -76.1 |
| Tarmak 1                                   |                 -95.6 → -108.7 |               -103.3 → -118.6 |              -114.1 → -129.0 |               -103.7 → -120.1 |
| FLAW                                       |                 -96.3 → -120.1 |                -91.2 → -111.8 |                -15.2 → -28.1 |                 -33.2 → -47.1 |
| Qwerty Comfort                             |                 -96.4 → -117.3 |               -116.1 → -139.1 |              -115.3 → -138.1 |               -130.0 → -156.2 |
| JNRF                                       |                 -96.5 → -107.1 |               -109.8 → -120.3 |                -69.4 → -79.5 |                 -82.4 → -93.7 |
| Colemak Mod Ian 2                          |                 -96.6 → -103.6 |                -99.5 → -107.8 |                -64.1 → -73.2 |                 -74.7 → -85.7 |
| Thumb O Board Tweaked                      |                 -97.7 → -110.6 |                -90.0 → -102.9 |                -44.8 → -56.6 |                 -63.7 → -77.3 |
| Halmak (KLAnext)                           |                 -97.7 → -110.2 |                -86.3 → -100.6 |                -58.2 → -71.9 |                 -51.0 → -67.2 |
| Liigol Mod Ian 2                           |                 -97.8 → -107.2 |                 -88.6 → -99.9 |                -61.3 → -73.4 |                 -59.7 → -73.1 |
| Minimak 4key                               |                 -98.0 → -120.6 |               -105.9 → -132.0 |              -104.2 → -129.8 |               -102.6 → -130.5 |
| Hoke                                       |                 -98.6 → -107.2 |                -95.3 → -105.1 |              -104.6 → -114.3 |                -93.2 → -105.0 |
| Bsdhacker                                  |                 -98.6 → -111.6 |                -90.2 → -102.2 |                -71.8 → -81.4 |                 -79.8 → -90.5 |
| German Dvorak Type II                      |                 -98.7 → -107.6 |               -100.2 → -110.1 |                -46.7 → -56.3 |                 -46.8 → -58.2 |
| Colemak-DH Wide ISO                        |                 -99.3 → -108.1 |                -91.8 → -101.8 |                -66.9 → -78.2 |                 -60.2 → -71.1 |
| Aserth                                     |                 -99.4 → -107.0 |               -118.4 → -127.2 |              -106.7 → -114.8 |               -111.3 → -121.2 |
| Tarmak 4                                   |                 -99.5 → -109.0 |                -99.5 → -110.3 |                -64.7 → -74.3 |                 -70.0 → -81.6 |
| Qwerty Row Swap                            |                -100.5 → -107.4 |               -120.9 → -128.8 |              -115.9 → -125.8 |               -119.1 → -128.6 |
| Siwei                                      |                -100.5 → -123.5 |               -115.5 → -138.4 |              -102.3 → -124.6 |               -101.5 → -126.0 |
| Cyberswarm Mod Ian                         |                -101.1 → -109.4 |               -106.4 → -114.4 |                -80.8 → -88.6 |                 -89.0 → -97.9 |
| Jeff                                       |                -101.5 → -108.7 |               -105.9 → -114.1 |                -74.9 → -84.4 |                 -71.9 → -81.6 |
| Norman                                     |                -103.5 → -116.7 |               -113.6 → -127.6 |                -67.2 → -78.7 |                 -81.9 → -95.7 |
| Fargas                                     |                -103.7 → -121.8 |               -113.8 → -130.1 |                -77.2 → -90.3 |               -101.5 → -116.6 |
| Qwicklystep1                               |                -105.1 → -115.6 |               -124.3 → -136.2 |              -114.2 → -125.3 |               -118.0 → -130.0 |
| Tarmak 3                                   |                -105.2 → -116.2 |               -105.4 → -118.2 |               -89.3 → -100.9 |                -93.1 → -106.9 |
| Qwerty Row Swap Mod Ian                    |                -105.5 → -112.3 |               -118.2 → -126.1 |              -105.5 → -115.4 |               -115.5 → -124.9 |
| Qwerak                                     |                -106.1 → -113.1 |                -98.3 → -106.5 |                -38.8 → -46.2 |                 -43.8 → -53.1 |
| Solemak Rightshift                         |                -106.3 → -116.2 |                -99.2 → -110.9 |                -76.1 → -88.1 |                 -75.5 → -88.8 |
| Hieamtsrn Optimized                        |                -106.6 → -123.0 |               -102.8 → -119.1 |                -45.8 → -62.3 |                 -63.8 → -81.2 |
| Antibracket (on AltGr)                     |                -108.2 → -118.1 |               -107.2 → -117.3 |               -89.0 → -100.9 |                -88.8 → -100.7 |
| Tyler                                      |                -109.0 → -120.1 |               -121.8 → -134.2 |              -105.9 → -119.6 |               -123.3 → -138.4 |
| Mcgunnigle Scientific                      |                -109.2 → -117.5 |               -122.4 → -131.4 |                -75.6 → -82.9 |                 -90.4 → -99.5 |
| Kumar Desai                                |                -109.6 → -119.7 |               -116.1 → -125.7 |               -93.8 → -103.6 |                -93.1 → -103.9 |
| Rstlne Ai                                  |                -109.7 → -121.9 |                 -87.5 → -98.5 |              -124.8 → -134.5 |                -96.9 → -106.8 |
| Orthocarpus                                |                -109.8 → -124.6 |               -106.4 → -120.5 |                -75.3 → -87.5 |                 -82.0 → -95.1 |
| Foalmak                                    |                -109.9 → -128.3 |               -106.1 → -123.5 |                -80.3 → -91.9 |                -89.5 → -102.6 |
| QGMLWY                                     |                -111.2 → -119.6 |               -106.9 → -117.5 |                -51.9 → -61.4 |                 -69.7 → -81.3 |
| CarpalxQ                                   |                -111.8 → -122.3 |               -116.7 → -128.8 |              -101.6 → -112.7 |                -87.6 → -100.6 |
| Anglian                                    |                -113.4 → -133.9 |                -99.6 → -115.7 |                -62.2 → -73.5 |                 -62.4 → -73.9 |
| Antithesis                                 |                -113.5 → -125.6 |               -105.1 → -117.9 |              -119.4 → -133.5 |               -110.2 → -124.3 |
| Carpalx (full optimization)                |                -116.2 → -124.5 |               -108.3 → -118.8 |                -59.2 → -69.0 |                 -78.3 → -90.0 |
| Capewell Qwerf                             |                -116.3 → -135.1 |               -130.7 → -149.5 |              -122.7 → -142.2 |               -123.9 → -144.9 |
| Newden Mod Ian                             |                -116.6 → -132.0 |               -110.3 → -126.4 |                -53.9 → -66.3 |                 -68.7 → -83.4 |
| Neo 2.0                                    |                -116.7 → -126.1 |               -125.8 → -135.8 |              -110.6 → -118.8 |               -111.7 → -120.3 |
| Eucalyn                                    |                -116.7 → -126.4 |               -114.1 → -125.0 |              -140.8 → -152.4 |               -128.6 → -142.3 |
| Codemakx                                   |                -117.8 → -126.8 |               -113.6 → -124.6 |                -55.9 → -65.6 |                 -76.2 → -88.2 |
| A Joy Rehomed                              |                -118.1 → -133.9 |               -106.4 → -120.4 |                -85.2 → -98.9 |                 -85.1 → -99.5 |
| QGMLWY Cub                                 |                -118.8 → -129.2 |               -114.0 → -126.0 |                -57.9 → -68.8 |                 -76.0 → -88.1 |
| Savard                                     |                -119.1 → -127.2 |               -130.1 → -139.8 |                -77.6 → -86.4 |                 -76.3 → -87.6 |
| QWERFJ                                     |                -119.3 → -142.7 |               -135.3 → -158.3 |              -120.8 → -142.4 |               -127.2 → -151.3 |
| Jan                                        |                -120.7 → -131.0 |               -124.6 → -136.8 |              -107.4 → -118.2 |                -94.5 → -107.5 |
| Oatpie                                     |                -120.8 → -131.3 |               -123.9 → -135.6 |               -91.9 → -102.9 |                -98.4 → -110.6 |
| Harrison                                   |                -123.3 → -139.6 |               -124.0 → -142.2 |              -120.1 → -138.7 |               -112.8 → -132.6 |
| Ingulish v2                                |                -123.5 → -131.3 |               -133.2 → -141.6 |              -161.8 → -170.5 |               -148.9 → -158.3 |
| QGMLWB Cub                                 |                -123.7 → -134.0 |               -115.4 → -127.4 |                -65.1 → -76.4 |                 -84.6 → -96.8 |
| Blick Mod Ian                              |                -123.8 → -131.2 |               -128.3 → -137.3 |               -91.3 → -101.3 |                -94.1 → -105.3 |
| Wong Poiea                                 |                -124.0 → -136.5 |               -130.3 → -142.5 |              -172.8 → -181.3 |               -149.8 → -160.2 |
| Qgmlwb Programmer                          |                -124.4 → -133.2 |               -117.3 → -128.3 |                -65.5 → -75.5 |                 -87.7 → -99.9 |
| Niro Rightshift                            |                -125.3 → -139.6 |               -144.0 → -158.2 |               -93.1 → -106.2 |               -115.2 → -128.5 |
| Hein Rightshift                            |                -125.7 → -138.9 |               -130.2 → -144.6 |              -127.1 → -142.0 |               -141.0 → -157.2 |
| Ingulish                                   |                -126.6 → -137.5 |               -133.4 → -143.2 |              -125.7 → -137.7 |               -127.2 → -139.0 |
| Neo2                                       |                -126.7 → -134.2 |               -131.9 → -140.9 |              -113.4 → -120.9 |               -119.1 → -128.4 |
| Rhythmic                                   |                -126.8 → -136.7 |               -115.8 → -128.2 |                -68.8 → -83.1 |                 -72.9 → -87.9 |
| Tallus                                     |                -127.2 → -139.1 |               -145.7 → -157.6 |              -105.2 → -114.1 |               -118.4 → -128.8 |
| Widely Alternating A                       |                -127.4 → -139.0 |               -111.2 → -124.7 |                -63.8 → -76.1 |                 -70.7 → -84.0 |
| Light Anderson                             |                -127.6 → -142.0 |               -135.1 → -150.2 |              -106.3 → -124.1 |               -110.7 → -128.3 |
| Navarre 1907 (ZHJAYSCPG)                   |                -128.0 → -140.2 |               -138.3 → -153.2 |              -158.4 → -177.7 |               -172.5 → -192.0 |
| Harmony                                    |                -129.0 → -144.4 |               -133.8 → -150.3 |               -94.5 → -109.1 |               -104.8 → -120.7 |
| AZERTY (Macintosh)                         |                -129.8 → -163.6 |               -148.5 → -185.6 |              -149.0 → -184.3 |               -156.7 → -197.1 |
| Xpert                                      |                -130.0 → -145.2 |               -136.1 → -154.0 |              -143.0 → -163.1 |               -134.1 → -155.9 |
| Tahan                                      |                -130.0 → -157.8 |               -138.7 → -161.6 |              -157.5 → -196.5 |               -159.2 → -193.7 |
| Keymacs Madand                             |                -130.2 → -140.6 |               -127.7 → -138.1 |                -89.0 → -99.1 |                -97.1 → -107.7 |
| Rike                                       |                -130.4 → -145.3 |               -129.2 → -147.0 |              -136.3 → -153.8 |               -128.9 → -149.9 |
| QWERTY-SUX 1.0                             |                -130.8 → -167.2 |               -133.1 → -169.1 |              -153.8 → -185.8 |               -157.7 → -195.7 |
| Colevrak                                   |                -130.9 → -148.7 |               -135.3 → -153.7 |                -77.2 → -92.6 |               -101.1 → -119.2 |
| AZERTY fr-latin9 (legacy)                  |                -131.3 → -163.9 |               -149.6 → -186.1 |              -149.2 → -184.5 |               -156.0 → -196.3 |
| Keymacs2                                   |                -131.4 → -142.1 |               -128.9 → -139.7 |                -88.6 → -97.8 |                -99.0 → -109.8 |
| WidePDK Custom                             |                -132.1 → -143.7 |               -135.2 → -147.7 |               -94.0 → -107.5 |               -105.5 → -119.9 |
| Banaji                                     |                -133.9 → -158.5 |               -158.3 → -184.6 |              -127.6 → -154.1 |               -150.3 → -177.8 |
| CHIN                                       |                -134.1 → -145.8 |               -130.6 → -143.3 |              -108.3 → -119.7 |               -109.1 → -121.7 |
| QWERTY (Spanish - International)           |                -134.8 → -169.1 |               -150.1 → -187.1 |              -141.2 → -175.6 |               -144.9 → -183.6 |
| Jesan                                      |                -135.3 → -143.8 |               -141.7 → -150.6 |              -197.4 → -207.1 |               -176.6 → -187.0 |
| AZERTY AFNOR (NF Z71-300)                  |                -135.5 → -171.1 |               -152.5 → -192.4 |              -139.3 → -174.5 |               -152.3 → -192.3 |
| International P                            |                -135.5 → -167.5 |               -154.8 → -189.5 |              -141.0 → -175.3 |               -148.1 → -185.6 |
| English P                                  |                -135.9 → -168.8 |               -149.3 → -183.5 |              -126.8 → -155.4 |               -129.4 → -159.7 |
| As In Red Hot                              |                -136.0 → -145.9 |               -132.6 → -144.0 |              -150.9 → -162.6 |               -142.3 → -156.0 |
| Qwerty P                                   |                -136.3 → -168.3 |               -154.4 → -189.3 |              -140.5 → -174.2 |               -147.5 → -185.2 |
| Qwerty Angle Mod                           |                -136.6 → -169.3 |               -153.9 → -189.3 |              -137.7 → -171.7 |               -146.0 → -184.2 |
| Dreymar                                    |                -136.7 → -145.6 |               -132.2 → -141.9 |                -76.2 → -84.4 |                -92.3 → -101.7 |
| Xpert Express                              |                -136.7 → -151.0 |               -138.5 → -155.2 |              -126.4 → -144.0 |               -129.9 → -151.5 |
| Keymacs                                    |                -137.0 → -147.7 |               -145.9 → -157.0 |              -117.1 → -126.9 |               -141.3 → -152.1 |
| CHIN-Programmer                            |                -137.1 → -148.7 |               -135.2 → -148.1 |              -111.6 → -123.0 |               -114.0 → -126.8 |
| AZERTY 1DK (Kazerty)                       |                -137.7 → -168.1 |               -147.8 → -181.3 |              -146.5 → -181.5 |               -154.6 → -194.3 |
| QWERTY (US)                                |                -137.8 → -170.3 |               -156.1 → -191.4 |              -141.1 → -175.0 |               -148.7 → -186.8 |
| AZERTY (FR)                                |                -138.3 → -172.4 |               -155.0 → -193.6 |              -148.5 → -183.7 |               -159.3 → -199.7 |
| Power                                      |                -140.7 → -158.8 |               -142.0 → -161.7 |              -148.2 → -170.5 |               -136.9 → -160.6 |
| QWERTY Estonian                            |                -140.8 → -173.7 |               -158.6 → -194.3 |              -142.6 → -177.2 |               -150.7 → -189.4 |
| QWERTY (Danish - International)            |                -141.2 → -174.1 |               -159.0 → -194.7 |              -143.0 → -177.5 |               -151.1 → -189.7 |
| German QWERTY                              |                -141.7 → -176.1 |               -156.8 → -193.7 |              -142.1 → -176.5 |               -146.0 → -184.7 |
| AZERTY (US symbols)                        |                -142.5 → -175.9 |               -160.4 → -197.5 |              -140.0 → -174.9 |               -148.4 → -187.7 |
| QWERTY-Programmer                          |                -142.6 → -175.3 |               -161.2 → -197.0 |              -143.5 → -177.4 |               -152.5 → -190.9 |
| QWERTZ                                     |                -142.7 → -177.2 |               -157.5 → -194.2 |              -135.5 → -168.5 |               -146.9 → -185.1 |
| Crate                                      |                -144.5 → -156.4 |               -138.6 → -150.1 |              -186.8 → -200.4 |               -148.4 → -160.6 |
| Hawaiian                                   |                -145.3 → -177.8 |               -161.8 → -197.2 |              -142.0 → -175.9 |               -149.5 → -187.6 |
| Stial                                      |                -147.1 → -154.1 |               -153.4 → -161.8 |              -113.9 → -124.1 |               -130.7 → -140.9 |
| Quartz Glyph                               |                -148.5 → -172.5 |               -166.0 → -190.1 |              -165.6 → -195.1 |               -177.7 → -209.9 |
| Spanish (OLPC)                             |                -149.0 → -184.2 |               -161.8 → -199.6 |              -139.6 → -174.2 |               -148.1 → -186.8 |
| White Refingered                           |                -150.1 → -160.0 |               -139.6 → -150.3 |                -86.0 → -94.6 |                 -87.8 → -97.6 |
| Isa                                        |                -150.7 → -168.8 |               -152.5 → -170.6 |              -119.7 → -137.4 |               -123.7 → -141.8 |
| De Correspondent                           |                -151.9 → -160.3 |               -146.0 → -155.8 |                -88.3 → -97.5 |               -109.0 → -120.0 |
| Qwyrfm                                     |                -153.7 → -162.4 |               -153.6 → -163.4 |              -123.0 → -131.2 |               -126.1 → -136.2 |
| Quickstephen                               |                -154.3 → -161.6 |               -155.7 → -163.3 |              -203.3 → -213.5 |               -191.4 → -201.4 |
| Ward                                       |                -159.6 → -171.3 |               -154.8 → -166.6 |              -115.2 → -129.1 |               -121.1 → -132.8 |
| Qwkrfy                                     |                -160.5 → -172.8 |               -152.2 → -166.6 |              -165.5 → -180.1 |               -143.4 → -159.2 |
| Qwerty Wide Programmer                     |                -161.2 → -189.9 |               -176.4 → -207.4 |              -146.7 → -174.3 |               -180.5 → -214.2 |
| TaserFR                                    |                -165.1 → -177.8 |               -178.3 → -195.3 |              -183.4 → -190.5 |               -191.0 → -199.1 |
| Cyberswarm                                 |                -165.4 → -174.2 |               -151.2 → -160.3 |              -129.5 → -137.2 |               -133.7 → -142.7 |
| Dvorak Mod Elazharty Azmi Suliman Mod Ian  |                -165.4 → -175.6 |               -156.4 → -167.7 |              -128.0 → -139.2 |               -139.7 → -151.4 |
| Gardner                                    |                -165.6 → -190.5 |               -192.5 → -219.9 |              -176.3 → -205.3 |               -188.8 → -217.8 |
| Kurriss                                    |                -166.3 → -180.1 |               -174.7 → -187.0 |              -153.2 → -162.1 |               -150.5 → -159.8 |
| QWERTY French (US with dead keys)          |                -167.9 → -204.0 |               -183.2 → -221.4 |              -143.4 → -178.1 |               -147.5 → -185.5 |
| Savard Vertical Alpha                      |                -169.3 → -206.0 |               -176.0 → -211.7 |              -182.7 → -213.2 |               -182.2 → -217.2 |
| Drix                                       |                -169.7 → -206.9 |               -184.3 → -222.0 |              -127.3 → -157.3 |               -135.7 → -169.9 |
| Qwerty Angle Wide Mod                      |                -170.4 → -200.2 |               -187.9 → -219.4 |              -135.0 → -165.5 |               -161.6 → -195.4 |
| QWERTY: Wide Mod                           |                -171.5 → -201.2 |               -190.1 → -221.5 |              -138.3 → -168.8 |               -164.3 → -198.0 |
| Qwerty Wide Mod                            |                -171.5 → -201.2 |               -190.0 → -221.5 |              -138.3 → -168.8 |               -164.3 → -198.0 |
| Mcgunnigle Perfect                         |                -171.9 → -185.2 |               -151.4 → -164.2 |              -134.3 → -143.3 |               -126.9 → -138.8 |
| Qwerty Revised                             |                -174.1 → -196.4 |               -173.6 → -192.5 |              -137.9 → -152.7 |               -158.4 → -173.3 |
| ASHLEY-GUDYR                               |                -177.0 → -187.8 |               -174.1 → -186.2 |              -117.6 → -129.8 |               -108.0 → -120.7 |
| Qwerty Q Layout                            |                -178.1 → -209.5 |               -189.2 → -224.6 |              -138.6 → -170.0 |               -153.9 → -191.2 |
| Wolcott                                    |                -181.8 → -203.2 |               -190.5 → -212.0 |              -199.5 → -219.6 |               -192.3 → -214.5 |
| Walker                                     |                -182.4 → -201.8 |               -185.2 → -206.4 |              -180.4 → -199.7 |               -154.6 → -176.3 |
| Harbaugh                                   |                -182.9 → -202.0 |               -163.5 → -181.4 |              -122.1 → -139.7 |               -123.2 → -141.3 |
| Parkinson                                  |                -188.6 → -210.8 |               -165.7 → -185.2 |              -138.1 → -158.1 |               -145.5 → -166.5 |
| Orthographic                               |                -190.2 → -200.1 |               -206.7 → -216.9 |              -186.6 → -198.2 |               -186.3 → -198.7 |
| Qwuio                                      |                -190.7 → -217.4 |               -187.5 → -216.6 |              -136.0 → -159.7 |               -164.8 → -193.7 |
| Sanie                                      |                -193.1 → -202.5 |               -217.8 → -227.7 |              -143.4 → -154.8 |               -155.5 → -166.6 |
| Blickensderfer 5 (thumb)                   |                -198.2 → -207.6 |               -204.6 → -214.3 |              -147.5 → -155.7 |               -165.1 → -174.5 |
| Speedkeys                                  |                -204.1 → -219.5 |               -207.8 → -225.8 |              -287.6 → -326.3 |               -257.6 → -292.0 |
| Print Face                                 |                -212.6 → -227.5 |               -205.2 → -218.8 |              -200.4 → -217.3 |               -179.7 → -194.8 |
| Streitz                                    |                -213.4 → -248.5 |               -226.2 → -262.9 |              -160.9 → -184.5 |               -181.2 → -208.3 |
| Trotman                                    |                -219.6 → -269.3 |               -205.5 → -247.9 |              -208.1 → -258.3 |               -195.9 → -241.3 |
| Us Split V3                                |                -223.0 → -258.3 |               -240.8 → -275.7 |              -172.6 → -205.8 |               -208.7 → -244.9 |
| Blick                                      |                -231.9 → -238.5 |               -241.7 → -250.1 |              -161.8 → -170.9 |               -173.0 → -183.2 |
| Reverse Qwerty                             |                -240.6 → -278.0 |               -248.4 → -286.7 |              -285.2 → -313.3 |               -274.8 → -305.3 |
| 93fk Optimal                               |                -249.0 → -267.2 |               -257.3 → -274.0 |              -237.1 → -250.3 |               -221.3 → -235.4 |
| Gardner2                                   |                -255.9 → -285.2 |               -265.5 → -296.0 |              -205.8 → -230.6 |               -215.5 → -242.7 |
| ABCDEF                                     |                -263.4 → -287.4 |               -273.8 → -301.0 |              -275.5 → -302.4 |               -267.5 → -297.5 |
| Onsorodi Korhan                            |                -275.1 → -295.8 |               -288.3 → -309.6 |              -226.6 → -253.5 |               -234.0 → -260.4 |
| Sholes                                     |                -286.9 → -294.3 |               -291.9 → -299.7 |              -276.7 → -284.1 |               -298.1 → -306.7 |
| Fitch                                      |                -298.8 → -309.8 |               -305.3 → -317.8 |              -354.5 → -370.4 |               -344.6 → -362.1 |
| Combinational                              |                -302.7 → -317.2 |               -301.2 → -316.3 |              -254.3 → -273.2 |               -269.5 → -286.8 |
| Rushforth                                  |                -304.6 → -312.3 |               -328.5 → -338.0 |              -411.9 → -446.9 |               -393.7 → -424.2 |
| Armel Mod Ian                              |                -315.8 → -341.2 |               -344.4 → -371.5 |              -375.3 → -401.9 |               -385.7 → -416.5 |
| One-handed Dvorak (Right)                  |                -317.4 → -343.1 |               -353.9 → -383.2 |              -342.2 → -359.8 |               -359.1 → -383.3 |
| TNWMLC (Worst CarpalX layout)              |                -397.9 → -473.2 |               -423.3 → -502.4 |              -383.3 → -463.3 |               -393.0 → -473.7 |
| Mcgunnigle Peoples Rehomed                 |                -401.7 → -440.2 |               -419.3 → -457.5 |              -360.5 → -388.9 |               -378.2 → -409.1 |
| Rowell                                     |                -479.9 → -511.9 |               -510.3 → -542.7 |              -615.5 → -678.3 |               -563.5 → -614.9 |
| Armel Refingered Ian                       |                -513.4 → -555.6 |               -530.2 → -571.0 |              -501.9 → -537.5 |               -487.0 → -523.9 |
| Vitrimak Ortho                             |                -521.2 → -603.3 |               -528.2 → -606.3 |              -643.6 → -749.3 |               -613.7 → -713.3 |
| Noel                                       |                -540.2 → -608.8 |               -566.5 → -641.3 |              -574.4 → -612.9 |               -538.8 → -584.0 |
| Vitrimak                                   |                -541.3 → -618.8 |               -542.5 → -616.3 |              -652.8 → -753.3 |               -622.8 → -719.7 |
| Layman                                     |                -549.6 → -630.1 |               -585.7 → -672.7 |              -508.1 → -561.7 |               -537.1 → -596.6 |
| One-handed Dvorak (Left)                   |                -616.4 → -692.5 |               -654.6 → -736.8 |              -541.0 → -594.2 |               -568.9 → -631.5 |
| Marsan English                             |                  -25.1 → -34.3 |                 -25.2 → -34.7 |                -24.2 → -35.1 |                 -28.2 → -39.3 |
| Hands Down Neu (ErgoDox)                   |                  -27.0 → -41.9 |                 -31.5 → -45.5 |                 -4.9 → -16.2 |                 -17.5 → -29.8 |
| HS Indeks                                  |                  -28.0 → -39.4 |                 -31.1 → -43.5 |                -22.5 → -33.4 |                 -24.4 → -37.0 |
| Bépo (ErgoDox)                             |                  -37.8 → -48.3 |                 -41.1 → -54.2 |                -70.7 → -83.3 |                 -60.9 → -74.2 |
| Hands Down Polyglot (ErgoDox, archive)     |                  -46.0 → -58.3 |                 -47.1 → -61.4 |                -16.0 → -27.7 |                 -26.3 → -40.3 |
| Bl13 2                                     |                  -49.6 → -60.0 |                 -55.6 → -68.2 |                -17.6 → -28.9 |                 -28.4 → -41.8 |
| X1                                         |                  -52.5 → -61.5 |                 -57.6 → -68.6 |                -24.1 → -32.8 |                 -39.9 → -51.4 |
| Beakl Opted36                              |                  -52.8 → -63.9 |                 -54.5 → -66.9 |                -13.4 → -26.2 |                 -27.9 → -41.6 |
| Bl13                                       |                  -53.7 → -68.4 |                 -58.0 → -73.8 |                -20.4 → -34.6 |                 -35.5 → -51.1 |
| Uciea Vanilla (KLAnext, ErgoDox)           |                  -59.6 → -68.4 |                 -45.9 → -56.1 |                -26.5 → -40.1 |                 -22.7 → -35.3 |
| Full Maks                                  |                  -63.2 → -76.1 |                 -58.1 → -71.0 |                 -8.1 → -19.1 |                 -19.8 → -32.6 |
| Modified UPD                               |                  -76.3 → -86.0 |                 -84.2 → -95.0 |                -35.7 → -46.2 |                 -45.8 → -57.5 |
| Balanced V                                 |                  -83.4 → -91.2 |                 -86.7 → -95.6 |                -64.9 → -75.0 |                 -70.4 → -81.4 |
| Dvorak Mod Kengo                           |                 -88.1 → -100.2 |                -93.5 → -105.4 |                -29.8 → -40.5 |                 -44.9 → -57.5 |
| Morgenstern                                |                 -89.6 → -102.9 |                -99.2 → -112.3 |                -71.4 → -83.8 |                 -83.4 → -97.0 |
| Hands Down Élan                            |                -110.1 → -120.3 |               -107.8 → -118.2 |              -110.9 → -121.3 |               -106.0 → -116.4 |
| Maltron Us                                 |                -116.0 → -124.2 |               -123.9 → -132.3 |              -114.8 → -121.7 |               -122.0 → -129.6 |
| Hands Down Bronze (KLAnext, ErgoDox)       |                -116.1 → -126.3 |               -116.8 → -127.6 |              -130.5 → -141.4 |               -116.8 → -128.1 |
| Hands Down Bronze                          |                -119.2 → -129.4 |               -118.6 → -129.3 |              -131.2 → -142.1 |               -117.5 → -128.8 |
| Hands Down Extreme (ErgoDox)               |                -119.5 → -131.3 |               -116.9 → -129.7 |              -129.2 → -143.4 |               -111.6 → -126.2 |
| Hands Down Platinum                        |                -122.0 → -132.6 |               -125.1 → -135.3 |              -115.5 → -125.5 |               -110.3 → -120.8 |
| Hands Down Chromium                        |                -122.2 → -134.6 |               -124.3 → -137.4 |              -107.2 → -117.7 |               -112.1 → -125.0 |
| Neo2 Us                                    |                -125.6 → -132.2 |               -133.1 → -140.9 |              -127.7 → -134.7 |               -130.9 → -139.6 |
| Hands Down Vibranium (KLAnext, ErgoDox)    |                -129.8 → -140.8 |               -135.5 → -147.7 |              -114.8 → -125.3 |               -122.7 → -135.0 |
| Hands Down Cesium                          |                -132.0 → -143.2 |               -125.9 → -137.3 |              -112.8 → -122.7 |               -113.7 → -125.8 |
| Brown                                      |                -133.2 → -154.2 |               -115.7 → -134.0 |               -90.9 → -107.8 |                 -77.8 → -94.5 |
| Hands Down Élan (matrix)                   |                -134.3 → -144.4 |               -127.7 → -138.3 |              -109.9 → -119.5 |               -109.7 → -120.5 |
| Hands Down Vibranium                       |                -136.6 → -149.6 |               -140.4 → -154.2 |              -118.7 → -130.3 |               -124.3 → -138.5 |
| Hands Down Promethium                      |                -137.8 → -149.2 |               -133.7 → -145.7 |              -119.1 → -129.2 |               -118.8 → -130.7 |
| Hands Down Gold (cyanophage, page 2)       |                -137.9 → -151.9 |               -144.4 → -158.9 |              -128.0 → -139.9 |               -132.0 → -145.7 |
| Corny Furry                                |                -139.5 → -151.2 |               -126.2 → -137.5 |              -130.4 → -141.1 |               -114.0 → -125.4 |
| Hands Down Vibranium vfj                   |                -140.1 → -150.3 |               -140.2 → -152.0 |              -116.9 → -127.3 |               -123.8 → -136.6 |
| Hands Down Vibranium vx                    |                -142.3 → -151.7 |               -142.1 → -153.0 |              -118.7 → -128.6 |               -126.0 → -137.9 |
| Nordrassil                                 |                -142.3 → -157.2 |               -143.2 → -158.3 |              -136.9 → -150.7 |               -138.8 → -153.7 |
| Hands Down Vibranium VP (KLAnext, ErgoDox) |                -142.8 → -153.3 |               -146.5 → -158.6 |              -114.2 → -124.5 |               -121.7 → -133.8 |
| Hands Down Titanium (KLAnext, ErgoDox)     |                -143.2 → -154.0 |               -147.0 → -159.3 |              -118.8 → -129.4 |               -128.2 → -140.4 |
| Hands Down Rhodium (KLAnext, ErgoDox)      |                -143.3 → -153.2 |               -138.8 → -150.0 |              -123.3 → -133.4 |               -122.4 → -133.7 |
| Hands Down Gold (KLAnext, ErgoDox)         |                -144.5 → -155.6 |               -151.7 → -164.2 |              -127.5 → -138.8 |               -132.8 → -145.6 |
| Hands On TS                                |                -144.6 → -155.9 |               -140.3 → -153.6 |              -151.6 → -163.6 |               -137.2 → -150.9 |
| Hands Down Vibranium VF (KLAnext, ErgoDox) |                -144.8 → -155.2 |               -149.1 → -161.1 |              -116.7 → -127.0 |               -123.5 → -136.2 |
| X2                                         |                -145.6 → -153.7 |               -150.2 → -160.0 |              -161.2 → -171.3 |               -152.6 → -164.0 |
| Hands Down Vibranium VB (KLAnext, ErgoDox) |                -146.2 → -156.6 |               -149.5 → -161.7 |              -117.5 → -127.9 |               -124.4 → -137.2 |
| Hands Down Rhodium                         |                -146.7 → -156.6 |               -140.6 → -151.8 |              -124.0 → -134.1 |               -123.1 → -134.4 |
| Hands Down Vibranium vp                    |                -147.1 → -157.6 |               -148.2 → -160.3 |              -115.0 → -125.2 |               -122.3 → -134.6 |
| Hands Down Titanium                        |                -148.0 → -158.4 |               -150.4 → -162.4 |              -119.0 → -129.3 |               -129.4 → -141.7 |
| Hands Down Vibranium vf                    |                -148.1 → -158.5 |               -150.0 → -162.0 |              -117.0 → -127.3 |               -124.0 → -136.8 |
| Hands Down Gold                            |                -148.5 → -159.6 |               -153.4 → -166.0 |              -128.3 → -139.6 |               -133.2 → -146.1 |
| Hands Down Vibranium vb                    |                -149.3 → -159.8 |               -150.5 → -162.6 |              -117.9 → -128.2 |               -124.9 → -137.8 |
| Hands Down Silver (KLAnext, ErgoDox)       |                -150.9 → -161.5 |               -150.8 → -162.0 |              -125.4 → -136.4 |               -124.6 → -136.1 |
| Hands Down Unobtanium                      |                -151.3 → -163.3 |               -149.0 → -161.9 |              -115.2 → -124.2 |               -115.2 → -125.7 |
| Sunlight                                   |                -151.5 → -159.4 |               -142.6 → -152.1 |              -116.1 → -125.9 |               -113.4 → -124.4 |
| X6 Mod Sc0ty Nongr                         |                -152.6 → -160.8 |               -160.1 → -169.2 |              -176.3 → -185.8 |               -158.9 → -169.8 |
| Coastland                                  |                -153.2 → -163.0 |               -145.9 → -157.3 |              -122.0 → -133.1 |               -121.2 → -133.2 |
| Hands Down Silver                          |                -154.8 → -165.3 |               -153.1 → -164.2 |              -126.1 → -137.2 |               -125.4 → -136.9 |
| Adextre                                    |                -155.4 → -166.0 |               -161.0 → -172.8 |              -179.3 → -191.4 |               -176.1 → -188.5 |
| Hands Down Promethium (ErgoDox)            |                -155.5 → -167.1 |               -148.3 → -160.4 |              -115.8 → -125.9 |               -118.4 → -130.2 |
| Hands Down Vibranium vv                    |                -155.7 → -168.6 |               -154.4 → -168.0 |              -115.9 → -127.2 |               -124.5 → -138.4 |
| Seasalt                                    |                -158.5 → -167.8 |               -157.5 → -168.3 |              -109.6 → -119.9 |               -118.5 → -130.4 |
| Beakrak Mod Ian                            |                -158.7 → -170.2 |               -160.7 → -174.2 |              -148.0 → -160.2 |               -152.6 → -166.8 |
| Proxkb Thumbshift                          |                -159.3 → -169.4 |               -158.3 → -169.2 |              -146.0 → -156.2 |               -139.9 → -151.6 |
| Beakrak                                    |                -159.8 → -173.7 |               -161.3 → -177.6 |              -153.9 → -167.5 |               -149.3 → -166.2 |
| Hands Down Alt-nx                          |                -162.1 → -172.0 |               -164.6 → -176.6 |              -126.5 → -136.9 |               -132.3 → -144.4 |
| Night                                      |                -165.1 → -174.8 |               -158.0 → -168.6 |               -99.6 → -112.9 |               -115.8 → -128.5 |
| Hands Down Alt-tx                          |                -165.4 → -176.0 |               -170.1 → -182.3 |              -141.4 → -152.6 |               -144.4 → -157.0 |
| HS Indeks Ex                               |                -167.4 → -179.1 |               -172.3 → -185.2 |              -160.9 → -172.2 |               -158.8 → -172.3 |
| North                                      |                -169.9 → -182.8 |               -162.9 → -176.0 |               -96.8 → -110.7 |               -105.8 → -120.2 |
| Maltron Us 90                              |                -172.1 → -179.8 |               -175.5 → -184.7 |              -158.0 → -164.9 |               -159.0 → -167.8 |
| Stern                                      |                -172.2 → -182.7 |               -161.5 → -173.5 |              -102.8 → -116.2 |               -114.2 → -128.1 |
| Hands Down Alt-nx (matrix)                 |                -174.9 → -183.7 |               -168.0 → -178.6 |              -126.9 → -137.7 |               -130.4 → -142.2 |
| Racket                                     |                -175.4 → -186.6 |               -163.8 → -175.8 |              -105.0 → -116.1 |               -111.6 → -124.0 |
| Maks SX                                    |                -177.2 → -191.1 |               -168.2 → -181.9 |              -113.9 → -124.8 |               -114.4 → -127.5 |
| Aptmak                                     |                -178.5 → -185.6 |               -178.8 → -188.1 |              -144.5 → -154.1 |               -151.5 → -162.8 |
| Dusk                                       |                -179.3 → -190.8 |               -170.7 → -185.8 |              -107.4 → -118.1 |               -117.3 → -130.0 |
| Pfouyhai                                   |                -179.8 → -190.2 |               -178.9 → -190.5 |              -143.8 → -154.2 |               -153.7 → -166.0 |
| Hands Down Alt-ex                          |                -180.0 → -189.6 |               -182.8 → -194.7 |              -162.1 → -172.1 |               -164.4 → -176.2 |
| Enne P 111 69                              |                -180.8 → -199.0 |               -174.5 → -192.1 |              -170.7 → -186.0 |               -158.9 → -176.1 |
| SNTH                                       |                -181.3 → -193.4 |               -165.4 → -177.9 |              -106.0 → -119.6 |               -113.7 → -127.3 |
| Maltron Us 90 Mod Andreas                  |                -182.1 → -196.3 |               -184.4 → -199.0 |              -169.1 → -178.7 |               -167.4 → -177.7 |
| Maltron                                    |                -184.2 → -191.8 |               -190.0 → -198.8 |              -154.0 → -161.0 |               -158.5 → -167.5 |
| Maks Ex                                    |                -185.9 → -195.1 |               -187.0 → -197.4 |              -162.8 → -173.4 |               -166.7 → -178.1 |
| Rsthd 2                                    |                -186.8 → -194.2 |               -204.1 → -211.6 |              -149.6 → -156.1 |               -166.4 → -174.2 |
| Lydell Anishtro                            |                -187.1 → -196.3 |               -188.4 → -199.1 |              -155.3 → -164.1 |               -160.2 → -171.5 |
| Caster                                     |                -188.7 → -199.5 |               -171.5 → -184.5 |              -147.0 → -159.5 |               -142.6 → -157.6 |
| RSTHD                                      |                -189.1 → -196.6 |               -183.2 → -191.4 |              -141.8 → -148.7 |               -149.5 → -158.5 |
| Cole Shift E                               |                -192.8 → -202.2 |               -198.3 → -208.9 |              -178.3 → -187.4 |               -180.8 → -192.0 |
| Hands Down Dash (ErgoDox)                  |                -193.1 → -207.8 |               -190.3 → -204.7 |              -142.9 → -153.1 |               -156.5 → -168.8 |
| Mithril                                    |                -195.1 → -204.4 |               -183.7 → -193.8 |              -115.2 → -124.6 |               -125.0 → -135.7 |
| DSTHK                                      |                -198.2 → -211.3 |               -197.0 → -212.0 |              -155.5 → -167.8 |               -163.5 → -176.6 |
| T Ht01 75 54                               |                -198.6 → -213.6 |               -193.8 → -208.4 |              -179.9 → -194.1 |               -167.1 → -181.5 |
| Hands Down Alt-ex (ortho)                  |                -199.8 → -209.3 |               -200.4 → -211.2 |              -145.2 → -156.2 |               -164.9 → -176.3 |
| Hands Down Dash                            |                -200.1 → -213.3 |               -195.6 → -208.9 |              -149.9 → -160.0 |               -159.4 → -171.5 |
| Hands Down Alt-tx (matrix)                 |                -201.1 → -210.3 |               -186.8 → -197.8 |              -154.5 → -165.2 |               -150.9 → -163.2 |
| Hands Down Alt-nx (ortho)                  |                -204.5 → -213.5 |               -191.6 → -202.0 |              -137.5 → -149.0 |               -145.5 → -157.0 |
| Hands Down Alt-tx (ortho)                  |                -204.9 → -214.3 |               -197.1 → -207.8 |              -153.3 → -165.5 |               -158.4 → -170.4 |
| Hands Down Alt-ex (matrix)                 |                -206.7 → -215.2 |               -196.8 → -207.4 |              -166.5 → -176.8 |               -167.9 → -179.5 |
| Neo 2 in progress (Samuel Suther)          |                -220.0 → -227.2 |               -223.4 → -231.3 |              -228.7 → -237.7 |               -219.6 → -228.6 |
| ЙЦУКЕН (JCUKEN)                            |              -1113.0 → -1179.7 |               -699.8 → -738.7 |            -2031.2 → -2053.6 |               -708.0 → -741.7 |
