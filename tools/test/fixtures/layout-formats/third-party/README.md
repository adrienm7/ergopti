# Third-party layout files

Real files published by other projects, read by `tools/test/test-layout-formats.cjs` to hold the layout
editor's and the Comparer's readers (`_shared/ui/layout_analysis/layout_formats.js`) to what those tools actually
write. Kept byte for byte as published; fetched on 2026-11-15 (Paris time).

| File                        | Format        | Source                                                                        | Licence                       |
| --------------------------- | ------------- | ----------------------------------------------------------------------------- | ----------------------------- |
| `ergol.toml`                | Kalamine TOML | https://github.com/Nuclear-Squid/ergol, `keymaps/fr/ergol.toml` (branch main) | WTFPL v2, `LICENSE-ergol.txt` |
| `ergol.json`                | Kalamine JSON | https://github.com/Nuclear-Squid/ergol, `keymaps/fr/ergol.json` (branch main) | WTFPL v2, `LICENSE-ergol.txt` |
| `kalamine-qwerty-prog.toml` | Kalamine TOML | https://github.com/OneDeadKey/kalamine, `layouts/prog.toml` (branch main)     | MIT, `LICENSE-kalamine.txt`   |
| `kla-european.azerty.json` | KLA JSON | https://github.com/patorjk/keyboard-layout-analyzer, `layouts/european.azerty` (commit c4f2f9bb43) | MIT, `LICENSE-kla.txt` |
| `kla-european.bepo.json` | KLA JSON | https://github.com/patorjk/keyboard-layout-analyzer, `layouts/european.bepo` (commit c4f2f9bb43) | MIT, `LICENSE-kla.txt` |
| `kla-standard.dvorakmod.json` | KLA JSON | https://github.com/patorjk/keyboard-layout-analyzer, `layouts/standard.dvorakmod` (commit c4f2f9bb43) | MIT, `LICENSE-kla.txt` |
| `kla-ergodox.workman.json` | KLA JSON | https://github.com/patorjk/keyboard-layout-analyzer, `layouts/ergodox.workman` (commit c4f2f9bb43) | MIT, `LICENSE-kla.txt` |

The four Keyboard Layout Analyzer files are its own built-in layouts, one per board it knows (european, standard,
ergodox), fetched on 2026-11-17 (Paris time) at the pinned commit; they are the published bytes with their line ends
normalised to LF, and `.json` added to the name (KLA serves them without an extension).

Not here yet: an XKB symbols file, a KLC and a DOF or cmini file published by another project under a licence that
allows shipping them (the Oxeylyzer data files state none we could find, cmini's are GPL-3.0).
