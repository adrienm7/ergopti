# \_shared/modules/hotstrings/ — Cross-Driver Hotstring Data

This directory owns common and language-specific hotstring data. The shipped
Ergopti extension owns its bound files under `static/layouts/registry/ergopti/`.
The AHK driver consumes it at runtime via a self-healing `.tsv` cache (no
generated code is committed), and the Hammerspoon driver consumes it directly.

## Directory layout

```
_shared/modules/hotstrings/
  _index.toml              Category order, and the [languages] packs
  autocorrection.toml      Common autocorrections
  magickey.toml            Common symbols and native section-order markers
  french/                  French language pack (declared in _index.toml)
    autocorrection.toml      accents, names, elisions, hyphens, typos
    magickey.toml            French abbreviations and emoji names
  defaults.toml            Delay and colour fallbacks
  priority.json            Collision priority tiers
  schema.md                Schema documentation for all TOML files
```

## Ergopti layout hotstrings

The hotstrings written for Ergopti's key positions — distance and SFB reduction,
rolls, French suffixes (`french_distancesreduction` section `suffixes_a`) and the
magic key's repeat corrections (`magickey` section `repeat_corrections`) — live
in the Ergopti layout extension, `static/layouts/registry/ergopti/hotstrings/`.
The same extension owns the translated metadata for the native `magickey.replace`
choice; that metadata file contains no replacement hotstring. The common
MagicKey source retains its section-order marker for the native gate.
Its manifest binds
each file to its historical category, feature section and common priority
tier (`[extension.hotstring_bindings.<stem>]`), so every existing preference
still addresses it. Every driver discovers the pack it ships and always lists
« Hotstrings Ergopti » in the extensions section, even when the Ergopti keyboard
layout has not been installed. Replacement is controlled there; the physical
key picker remains in the Layout menu.

## Language packs

Hotstrings that only make sense in one natural language live in a folder named
after it and are declared in `_index.toml`:

```toml
[languages]
order = ["french"]

[languages.french]
locale = "fr"                # key into _shared/data/locale_names.json
categories_order = ["autocorrection", "magickey"]
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

A Linux explicit path to the actual shipped common file selects its logical
category, including that category's bound extension sections. Native device and
inode observations distinguish the shipped file from a physically distinct user
copy, even when their bytes match. A custom single-file path remains exact and
admits no additional extension categories. Shipped pack discovery reads the local
registry defaults directly; it needs no updater transport or installed layout.
