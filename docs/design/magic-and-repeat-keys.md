<!-- docs/design/magic-and-repeat-keys.md -->

# Magic and repeat keys in the layout model

Status: the maintainer chose on 2026-11-25 to build this design, the analysis
first. Built: the engine model and the analysis (step 1 below, as
[Ways of typing](layout-analysis.md#ways-of-typing) describes it), Kawalyzer's
« Clever Keys » importer (step 2, [Importers](#importers)), the source format
and the editor's key panel (step 3, [Key panel](#key-panel)), the three
drivers' emulation and the exports' omissions (step 4,
[layout-source-format.md](layout-source-format.md), « Document schema »).
Left, under « Layout repeat and magic keys » in TODO.md: the field checks on
each OS.

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

## Importers

Each analyser's licence was checked on 2026-11-25 (Paris time) before reading
its format; a format is read only where the licence allows it, and no code is
copied, the reader written from the format's description and its examples:

- **Kawalyzer**, the web port `nbodinripert/kawalyzer` (GPL-3.0, commit
  de03c0f, 2026-11-12; it ports Kawamashi's Excel analyser `Kawamashi/Kawalyzer`,
  which states no licence and is not read). Its layout files are Kalamine TOML,
  which the Studio already reads; its magic and repeat keys live in a separate
  JSON of replacements, `essentialCorrections` and `optionalCorrections` of
  `{text, keys}`, the keys writing the magic key `#`, the repeat key `$` and the
  dead key `*`. `LAYOUT_FORMATS.fromKawalyzerRules` reads such a file into one
  magic table: a rule whose keys are characters typed as themselves then `#`,
  and whose text is those characters then one more, becomes `{after, types}`;
  `#` alone typing one character becomes the fallback. Every other rule is
  listed with its reason (`KAWALYZER_REASONS`): typed by other keys (a
  correction such as `quoi` ← `qh`, or a rule on the repeat key), more than one
  character typed (most of its « Clever Keys », such as `ion` ← `i#`), more than
  two characters before the key, a condition on the letters around it, or a
  second rule after the same characters. Kawalyzer's repeat key needs no
  import: it types the last key again, which the source's `repeat = 1` does.
- **chogalyzer** (`Lenchog/chogalyzer`, commit 874b8ba, 2026-06-06) and the
  **Layouts Wiki playground** (layouts.wiki, its site and its author's
  repositories): no licence is published, so neither format is read. An
  importer waits for a licence that allows it (TODO.md, « Layout repeat and
  magic keys »).

## Key panel

The editor's key panel (`layout_editor/editor_page.js`, `mappingEditor`) offers
« Repeat key » (the last character typed, or the one before it) and « Magic key
of the layout » beside the other kinds. A magic key names a table: one the
layout has, or a new name, which `LayoutEditorModel.setMapping` creates empty
with the key (decided by the agent on 2026-11-25, to review by the maintainer:
a table belongs to the keys that name it, so the edit that changes the last of
them removes it, since the format refuses a table no key types; undo brings it
back, and a swap of two magic keys keeps both tables). Under a magic key, the
table's rules (after, types), each removed by its own button, the fallback and
« Import Kawalyzer rules », which replaces the rules in one step of the history
and lists what it left out. Every control has a visible label and a 44 px
target; the rules and the fallback save through the source's `magic[]` record
(`tools/test/test-layout-editor-model.cjs`,
`tools/test/browser/layout-editor-context-keys.cjs`).

## Order of work, once decided

1. Engine model and analysis (`layoutFromRows`, `compileWays`, planner), with
   vectors computed by hand, then the trace and the shown-only metric.
2. Importers that already carry such keys (the playground's and Kawalyzer's
   formats, chogalyzer's), if their licences allow reading them.
3. Source format and the editor's key panel.
4. The drivers' emulation, the three together, then the exports' refusals.
