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

| `xkeyboard-config.fr.xkb_symbols` | XKB symbols | https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config, `symbols/fr` (commit f4d3ed8bb8) | MIT/HPND notices, `LICENSE-xkeyboard-config.txt` |
| `xkeyboard-config.epo.xkb_symbols` | XKB symbols | https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config, `symbols/epo` (commit f4d3ed8bb8) | MIT/HPND notices, `LICENSE-xkeyboard-config.txt` |
| `mod-dh.colemak_dh_iso_uk.klc` | Windows KLC (UTF-8) | https://github.com/ColemakMods/mod-dh, `klc/colemak_dh_iso_uk.klc` (commit d9398d5769) | CC0 1.0, `LICENSE-mod-dh.txt` |
| `mod-dh.colemak_dh_ansi_us.klc` | Windows KLC (UTF-16) | https://github.com/ColemakMods/mod-dh, `klc/colemak_dh_ansi_us.klc` (commit d9398d5769) | CC0 1.0, `LICENSE-mod-dh.txt` |
| `libdof.maximal.dof` | Oxeylyzer DOF | https://github.com/o-x-e-y/libdof, `example_dofs/maximal.dof` (commit 4868cf550e) | Apache-2.0, `LICENSE-libdof.txt` |
| `libdof.minimal_valid.dof` | Oxeylyzer DOF | https://github.com/o-x-e-y/libdof, `example_dofs/minimal_valid.dof` (commit 4868cf550e) | Apache-2.0, `LICENSE-libdof.txt` |
| `libdof.aptmak.dof` | Oxeylyzer DOF | https://github.com/o-x-e-y/libdof, `example_dofs/aptmak.dof` (commit 4868cf550e) | Apache-2.0, `LICENSE-libdof.txt` |
| `libdof.buggy.dof` | Oxeylyzer DOF | https://github.com/o-x-e-y/libdof, `example_dofs/buggy.dof` (commit 4868cf550e) | Apache-2.0, `LICENSE-libdof.txt` |

The four Keyboard Layout Analyzer files are its own built-in layouts, one per board it knows (european, standard,
ergodox), fetched on 2026-11-17 (Paris time) at the pinned commit; they are the published bytes with their line ends
normalised to LF, and `.json` added to the name (KLA serves them without an extension).

The XKB, KLC and DOF files were fetched on 2026-11-17 (Paris time) at the pinned commits. The UTF-16 KLC is the
published bytes (CRLF line ends included: Git keeps a UTF-16 file as binary); the UTF-8 files are the published bytes
with their line ends normalised to LF. The project's name is prefixed to each file name, and `.xkb_symbols` added to
the XKB ones (xkeyboard-config names them without an extension). libdof has no NOTICE file.

Not shipped, with the reason:

- genkey's layouts (https://github.com/semilin/genkey, `layouts/`) and cmini's (https://github.com/Apsu/cmini) are
  GPL-3.0: the gate writes a genkey layout and cmini JSON itself, in their documented shapes (genkey's
  `layout.go` LoadLayout, cmini's `layouts/*.json`).
- KLAnext's layouts (https://klanext.keyboard-design.com, `layouts/*.json`) state no licence and the site calls its
  source « not open source »: the gate keeps only the key index of each QWERTY character on its matrix board, a fact
  read from `layouts/qwerty.en.matrix.json` on 2026-11-17, and builds its matrix files from it.
