# Text and TOML reader units

Audited source: `d02f838a` (`dev`). Date: November 25, 2026. Two units the
[2026-11-19 census](../2026-11-19-census/report.md) lists as never campaigned
(`macos/core/text`, rank 11, and `linux/core/text`, rank 22), read against the
shared `_shared/core/text/engine` they wrap and the Windows
`core/text/engine/toml` that plays their part.

## Scope

- macOS `core/text/engine/utils.lua` and `core/text/engine/toml/` (`codec`,
  `reader`, `writer`, `record_editor`);
- Linux `core/text/engine/gvariant_string.lua` and
  `core/text/engine/toml/reader.lua`;
- every production caller of the shared `toml_codec.reader` in both Lua
  drivers, and the Windows `toml.parse` phase of
  `core/text/engine/toml/helpers.ahk`.

Read for each: which reader a file parse goes through, whether the parse is
counted in the `toml.parse` phase summary (`infra/phase_stats`) and what each
driver-only file is for. Source reading and the Linux Lua suite in a Linux
container; the AutoHotkey suites did not run (no Windows host) and no Windows
source changed.

Checked and kept:

- **Shims.** The macOS `codec`, `writer` and `utils` shims re-export the shared
  library (the writer binds the macOS file-system adapter); Linux callers bind
  the shared writer and codec directly with their own adapter, so the same
  code writes on both.
- **`record_editor.lua`** is macOS's alone: the hotstring catalogue's
  overrides (`hotstrings/engine/catalogue/config.lua`) patch one field of a
  table in place through it. Linux's module of the same name writes its
  overrides through the shared `leaf_rows` and writer instead (see Open).
- **`gvariant_string.lua`** is Linux-only by its OS: it decodes `gsettings`
  output, which only GNOME has.
- **Windows** times both of its TOML parse entry points as `toml.parse`
  (`helpers.ahk`), the phase name the two Lua drivers use.

## Fixed

| Id     | OS    | Sequence                                                                                   | Reference                                                                                                         | Before                                                                                                                                                                                                                 | Regression                                                                                                        |
| ------ | ----- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| TXT-01 | Linux | Start the daemon, open a hotstring window, read the `toml.parse` line of the phase summary | macOS parses the timing registry, the tooltip constants and the hotstring windows' files through its timed reader | The timing registry, the tooltip constants and the two hotstring windows' bridges required the shared reader itself, so their parses never reached the `toml.parse` count or its cost: the summary under-read the boot | `every production module parses TOML through the timed reader (txt-01)` (`tests/unit/infra/test_phase_stats.lua`) |

## Open

- **Catalogue override writes.** macOS patches one field in place
  (`record_editor.lua`), Linux rewrites through the shared `leaf_rows` and
  writer. Whether both keep a hand-edited `config.toml`'s comments and other
  records byte for byte was not compared here: the next campaign on
  `hotstrings/engine/catalogue` should replay one hand-edited file through
  both.
