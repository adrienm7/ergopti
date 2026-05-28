# _shared/hotstrings/ — Cross-Driver Hotstring Data

This directory is the **single source of truth** for all bundled hotstring data.
Both the AHK driver (`hotstrings_generated.ahk`) and the Hammerspoon driver
consume data from this directory, either directly or via the code-generator.

## Directory layout

```
shared/hotstrings/
  autocorrection/          Pure substitution rules (typos, accents, names, etc.)
    accents.toml
    caps.toml
    errors.toml
    minus.toml
    minus_apostrophe.toml
    multiple_punctuation_marks.toml
    names.toml
    ou.toml
    suffixes_a_chaining.toml
    typographic_apostrophe.toml
  distances_reduction/     Typing-distance optimisations
    comma_far_letters.toml
    comma_j.toml
    dead_key_e_circumflex.toml
    e_circumflex_e.toml
    qu.toml
    suffixes_a.toml
  sfbs_reduction/          Same-finger bigram reductions
    bu.toml
    comma.toml
    e_circ.toml
    e_grave.toml
    ie.toml
  rolls/                   Roll-based shortcuts (coding, writing)
    assign.toml
    ... (one file per section)
  magic_key/               Magic-key expansion sequences
    repeat_corrections.toml
    text_expansion.toml
    text_expansion_emojis.toml
    text_expansion_symbols.toml
    text_expansion_symbols_typst.toml
  schema.md                Schema documentation for all TOML files
```

## TOML file schema

Each `.toml` file under a category folder contains one `[[entry]]` array:

```toml
# Example: autocorrection/errors.toml
[[entry]]
trigger     = "teh"
replacement = "the"
flags       = []          # optional: ["word", "case_sensitive", "auto", "final"]

[[entry]]
trigger     = "recieve"
replacement = "receive"
flags       = ["word"]
```

## Code generation

Run `npm run build:hotstrings` to regenerate:
- `static/ergopti_plus/windows/lib/hotstrings/hotstrings_generated.ahk`
- (future) `static/ergopti_plus/macos/_generated/hotstrings_registry.lua`
- (future) `static/ergopti_plus/linux/_generated/hotstrings_registry.lua`

Never edit `hotstrings_generated.ahk` by hand — all changes go in the TOML files.
