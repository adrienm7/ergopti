<!-- docs/design/magic-and-repeat-keys.md -->

# Magic and repeat keys in the layout model

Status: the maintainer chose on 2026-11-25 to build this design, the analysis
first. Built: the engine model and the analysis (step 1 below, as
[Ways of typing](layout-analysis.md#ways-of-typing) describes it), the source
format, the three drivers' emulation and the exports' omissions (steps 3 and
4, [layout-source-format.md](layout-source-format.md), « Document schema »).
Left, under « Layout repeat and magic keys » in TODO.md: the importers (step
2), the editor's key panel and the field checks on each OS.

Written on 2026-11-25 for the Layouts Wiki playground follow-up
([the comparison](../audits/layout-analysers/layouts-wiki-playground.md),
shortlist item 8). The playground, Kawalyzer and chogalyzer analyse keys whose
output depends on what was typed before: a **repeat key** (types the previous
output again), a **skip-repeat key** (the one before it), and a **magic key**
(rules « after this context, this key types that »; Kawalyzer calls a family of
them « Clever Keys »). Ergopti's analysis has none of them; this note says how
they would enter it, and what waits for the maintainer.

## What already exists, and the decision in the way

- Ergopti+ has its own magic key, « ★ »: a configured character
  (`hotstrings.trigger_char`) that ends text replacements in the drivers'
  hotstring engine (`docs/memory/maintainer-decisions.md`, « The magic key is a
  configured character », 2026-11-21). It is not part of a layout: the
  replacements live in the hotstring catalogues.
- The same decision says « Studio shows layouts, not the magic key ». Analysing
  a layout's repeat or magic key in the Studio was therefore a new product
  choice, which the maintainer made on 2026-11-25
  (`docs/memory/maintainer-decisions.md`, « Maintainer answers of 2026-11-25 »).

## Model

A layout's `context` record (`layoutFromRows`) maps a key to one action per
level, beside its rows, whose cell is `null` there (decided by the agent on
2026-11-25, to review by the maintainer: every reader of the rows, the
exports, drawings and the optimiser, keeps reading characters). An action is
one of:

- `{repeat: 1}` types the last character typed again; `{repeat: 2}` the one
  before it (skip-repeat). Nothing typed yet: the key types nothing.
- `{magic: "<id>"}` types what the magic table `<id>` gives for the context: a
  layout's `magic` maps an id to `{rules: [{after: "<text>", types: "<char>"}],
fallback: "<char>"}`. The longest `after` that ends the typed text wins (a
  rule list is checked for duplicate contexts); no rule matches: the fallback.
  Each output is one character (decided by the agent on 2026-11-25, to review
  by the maintainer: a longer one would be a chord of the context).

The context is the **output** text, never the keys pressed, so a dead key, an
AltGr level or another magic key all feed it the same way, and the model stays
one source for the analysis, the drivers and the exports.

## Engine

The ways of typing (`compileWays`) gain, for each character, the ways through a
repeat or magic key: a way valid only after a given context. They join the
context-dependent ways the planner already chooses between (chords and the
« best » typing mode, [Ways of typing](layout-analysis.md#ways-of-typing)):

- the planner's pair and triple costs read the previous token, so « this
  character after that one » can take the repeat way (a double letter typed by
  two fingers instead of one SFB) or a magic rule's way;
- the n-gram tables already give each character with its predecessors, which
  is the context a repeat or a one-character `after` needs; a longer `after`
  needs the trigram table (two characters) at most, so rules are limited to two
  characters of context, which every analyser surveyed keeps to;
- the key stream counts the repeat or magic key's press like any key, so SFB,
  rolls and the heatmaps see it, and the score needs no new weight (the
  decided weights stay as they are).

The trace (`traceText`) and the word efforts show which characters took such a
way; a new shown-only metric « repeat and magic uses » gives their share.

## Source format and drivers

- The layout source gains `repeat` and `magic` mapping forms
  ([layout-source-format.md](layout-source-format.md), « Document schema »)
  and a `magic[]` record; the validator refuses an unknown table, a rule
  without context or a context longer than two characters.
- No native layout file can hold them (`.keylayout`, KLC, XKB), so every export
  lists them as omitted (`context_key_not_in_<format>`) and the drivers emulate them, as they emulate
  levels a `.keylayout` lacks (« Emulation of what no `.keylayout` holds »): the
  three drivers already keep the last typed text for the hotstrings, the source
  of the context: each passes its hotstring buffer to the source emulation's
  press (macOS `CoreState.buffer`, Linux `engine:current_buffer()`, Windows
  `HSE_Buffer`), which types the key's output as a text key would and refuses a
  press without it. `cross-driver-parity` applies: one shared rule engine in Lua
  (macOS, Linux), its web twin and AutoHotkey, all replaying the shared vectors
  (`_shared/tests/corpus/layouts/magic_vectors.json`). A tap-hold's tap cannot be
  such a key (`context_key_tap_not_emulated`): its text would be chosen at the
  release, after keys the context has not seen.
- The ★ of Ergopti+ stays a hotstring trigger; a layout's own magic key is a
  separate key, and the two must not share a character unless the maintainer
  decides they should.

## Order of work, once decided

1. Engine model and analysis (`layoutFromRows`, `compileWays`, planner), with
   vectors computed by hand, then the trace and the shown-only metric.
2. Importers that already carry such keys (the playground's and Kawalyzer's
   formats, chogalyzer's), if their licences allow reading them.
3. Source format and the editor's key panel.
4. The drivers' emulation, the three together, then the exports' refusals.
