# Third-party layout files

Real files published by other projects, read by `tools/test/test-layout-formats.cjs` to hold the layout
editor's and the Comparer's readers (`_shared/ui/layout_analysis/layout_formats.js`) to what those tools actually
write. Kept byte for byte as published; fetched on 2026-11-15 (Paris time).

| File                        | Format        | Source                                                                        | Licence                       |
| --------------------------- | ------------- | ----------------------------------------------------------------------------- | ----------------------------- |
| `ergol.toml`                | Kalamine TOML | https://github.com/Nuclear-Squid/ergol, `keymaps/fr/ergol.toml` (branch main) | WTFPL v2, `LICENSE-ergol.txt` |
| `ergol.json`                | Kalamine JSON | https://github.com/Nuclear-Squid/ergol, `keymaps/fr/ergol.json` (branch main) | WTFPL v2, `LICENSE-ergol.txt` |
| `kalamine-qwerty-prog.toml` | Kalamine TOML | https://github.com/OneDeadKey/kalamine, `layouts/prog.toml` (branch main)     | MIT, `LICENSE-kalamine.txt`   |

Not here yet: a Keyboard Layout Analyzer JSON, an XKB symbols file, a KLC and a DOF or cmini file published by
another project under a licence that allows shipping them (the Oxeylyzer data files state none we could find, cmini's
are GPL-3.0).
