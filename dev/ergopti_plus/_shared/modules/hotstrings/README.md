# \_shared/modules/hotstrings/ — Cross-Driver Hotstring Data

This directory is the **single source of truth** for all bundled hotstring data.
The AHK driver consumes it at runtime via a self-healing `.tsv` cache (no
generated code is committed), and the Hammerspoon driver consumes it directly.

## Directory layout

```
_shared/modules/hotstrings/
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

## How the AHK driver consumes this

There is **no build step and no committed generated code**. On boot the Windows
driver (`lib/hotstrings/hotstrings_cache.ahk`) reads a flat
`generated_hotstrings.tsv` cache that sits beside these TOMLs and is **gitignored**.
If that cache is missing or older than any source `.toml`, the driver rebuilds it
from the TOML on the spot (a one-time cost on first launch or after an edit) and
rewrites it, so every subsequent boot is fast — the same self-healing pattern as
the locale `.tsv` caches. Just edit the TOML files; the cache refreshes itself.
