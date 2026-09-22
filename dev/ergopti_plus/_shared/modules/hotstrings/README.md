# \_shared/modules/hotstrings/ — Cross-Driver Hotstring Data

This directory is the **single source of truth** for all bundled hotstring data.
The AHK driver consumes it at runtime via a self-healing `.tsv` cache (no
generated code is committed), and the Hammerspoon driver consumes it directly.

## Directory layout

```
_shared/modules/hotstrings/
  _index.toml              Category order, and the [languages] packs
  distancesreduction.toml  Language-neutral categories (one file each):
  sfbsreduction.toml         layout distances, same-finger bigrams, rolls,
  rolls.toml                 brand capitalisation, symbols
  autocorrection.toml
  magickey.toml
  french/                  French language pack (declared in _index.toml)
    distancesreduction.toml  French suffixes
    autocorrection.toml      accents, names, elisions, hyphens, typos
    magickey.toml            French abbreviations and emoji names
  defaults.toml            Delay and colour fallbacks
  priority.json            Collision priority tiers
  schema.md                Schema documentation for all TOML files
```

## Language packs

Hotstrings that only make sense in one natural language live in a folder named
after it and are declared in `_index.toml`:

```toml
[languages]
order = ["french"]

[languages.french]
locale = "fr"                # key into _shared/data/locale_names.json
categories_order = ["distancesreduction", "autocorrection", "magickey"]
```

Each `<language>/<stem>.toml` loads as its own group `"<language>_<stem>"`
(`french_autocorrection`), which is also its `config.toml` section and its
`[[features.hotstrings.<group>]]` rows in the feature manifest. Every driver
shows the pack as a submenu of Hotstrings labelled with the language's native
name, with bulk enable/disable rows for the whole language. Adding a language is
data only: the folder, its `[languages.<id>]` table, and its manifest rows plus
a `[menu.hotstring_category_keys]` gate (`npm run test:hotstring-language-packs`
checks that nothing is missing).

Every bundled hotstring section ships **disabled**; the user opts in.
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
