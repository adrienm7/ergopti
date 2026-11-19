# Source census after the structure phase

Census source: `b90ad8de` (`fix/windows-pc-2026-11-17`, structure step S26
included). Date: November 19, 2026. Previous pinned census:
[tap-holds follow-up](../2026-11-12-tap-holds-followup/source-areas.json) at
`c054579d`.

## Method

- **Census:** `python -B tools/audit/source-areas.py --ref HEAD --output
source-areas.json`, the tool and selection of every earlier census (`--check`
  reproduces it). The tool groups only `modules/`, `ui/`, `native/`, `lua/`,
  `python/` and `go/` one level deeper, so each feature folder the structure
  phase created (`core/`, `platform/`, `ai/`, `hotstrings/`…) is one area. For
  a usable grain the reconciliation also reports **units**: an area plus the
  layer folder under it (`core/network`, `ai/engine`, `hotstrings/ui`).
- **Reconciliation:** `node tools/audit/parity-census.cjs --census
source-areas.json --previous ../2026-11-12-tap-holds-followup/source-areas.json
--output reconciliation.json` (about 4 minutes). For each of the 46 campaign
  folders it reads the pinned source (the report's « Audited source » line;
  `2026-11-12-pause` and `2026-11-13-tooltips-wpm` name a branch, so the commit
  that added the report stands in). It resolves every source file the
  campaign's Markdown names, and every backticked folder that starts at a
  driver root, in the tree at that pin, then follows it through renames to
  `b90ad8de`.
- **Drift:** a rename-aware diff from the pin of the latest campaign that
  named a file of the area to `b90ad8de`. A pure rename counts zero.
  « Behavioural lines » also leave out the hunks whose every changed line pair
  differs only in path-like tokens (requires, includes, dotted module names),
  which is what a structure step rewrites. An area is **drifted** when it has
  behavioural lines, **stable** otherwise.

Limits:

- Coverage is lexical. A campaign that named a module by a folder without a
  driver root (`ui/menu`) or by its functions covers nothing here.
- A file created after its module's campaign shows as never campaigned.
- Two reports name no file. They get their declared scope from the script's
  `DECLARED_SCOPE`: tooltips and WPM, and the editors' shared pages.
- A named file is not a reviewed file. The tables rank the next campaigns and
  certify nothing.

## Numbers

| Census                | Areas | Units | Members |     Lines |
| --------------------- | ----: | ----: | ------: | --------: |
| `c054579d` (11-12)    |   381 |     — |   2,540 |         — |
| `b90ad8de` (this one) |   190 |   316 |   2,668 | 1,235,958 |

| Status           | Areas | Units |
| ---------------- | ----: | ----: |
| drifted          |   108 |   188 |
| stable           |    13 |    29 |
| never campaigned |    69 |    99 |

The 99 never-campaigned units hold 90,048 lines. 25 of them are generated,
vendored, lock, data or port-spec files, out of parity scope.

### Old areas to new paths

Of the 381 areas of `c054579d`:

- 121 keep their key: the `modules/*` and `ui/*` areas not moved yet (keymap,
  keystats, shortcuts, updater, most windows);
- 237 moved whole into one new area, for example `windows/modules/hotstrings`
  to `windows/hotstrings` and `macos/modules/llm` to `macos/ai`;
- 20 split across several areas (table below);
- 3 left the census: `ui/layer_editor` on the three drivers, retired with the
  shared page by f455d6a74e when the navigation layer moved into the Studio.

16 of the 2,540 members left the census. 10 new areas have no old member: the
layout analysis and optimizer pages, the layout editor window, four shared UI
helpers and the Windows Lua export DLL. The full mapping is `previous_areas` in
`reconciliation.json`. The split areas:

| Old area                 | Now (members)                                                                                                                                             |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `linux/adapters`         | `linux/core` (21), `linux/platform` (18), `linux/adapters` (8), `linux/clipboard` (6), `linux/apps` (2), `linux/hotstrings` (1), `linux/tray` (1)         |
| `linux/infra`            | `linux/core` (63), `linux/infra` (20), `linux/settings` (9), `linux/platform` (7), `linux/hotstrings` (6), `linux/ai` (3), `linux/menu` (3), 2 more areas |
| `linux/modules/updater`  | `linux/modules/updater` (7), `shared/updater` (1)                                                                                                         |
| `linux/platform`         | `linux/platform` (10), `linux/core` (5), `linux/tray` (1)                                                                                                 |
| `linux/ui/menu`          | `linux/menu` (9), `linux/ui/menu` (9), `linux/ai` (7), `linux/settings` (3), `linux/apps` (2), `linux/hotstrings` (2), 2 more areas                       |
| `macos/adapters`         | `macos/core` (27), `macos/adapters` (25), `macos/platform` (17), `macos/diagnostics` (10), `macos/ai` (8), `macos/clipboard` (3), 2 more areas            |
| `macos/data`             | `macos/ai` (2), `macos/diagnostics` (2), `macos/data` (1)                                                                                                 |
| `macos/infra`            | `macos/core` (37), `macos/diagnostics` (19), `macos/infra` (12), `macos/settings` (9), `macos/hotstrings` (6), `macos/menu` (4), 5 more areas             |
| `macos/modules/keymap`   | `macos/hotstrings` (14), `macos/modules/keymap` (10), `macos/ai` (2)                                                                                      |
| `macos/platform`         | `macos/platform` (38), `macos/ai` (6), `macos/core` (3)                                                                                                   |
| `macos/ui/menu`          | `macos/ai` (36), `macos/menu` (21), `macos/ui/menu` (13), `macos/hotstrings` (7), `macos/settings` (4), `macos/gestures` (2), 1 more area                 |
| `shared/ahk`             | `shared/settings` (2), `shared/tap_hold` (1)                                                                                                              |
| `shared/core`            | `shared/core` (30), `shared/settings` (10)                                                                                                                |
| `shared/data`            | `shared/core` (32), `shared/metrics` (9), `shared/layouts` (6), `shared/apps` (2), `shared/data` (2), `shared/hotstrings` (2), 2 more areas               |
| `shared/go/native_http`  | `shared/core` (31), `shared/ai` (2)                                                                                                                       |
| `shared/modules/llm`     | `shared/ai` (34), `shared/core` (2)                                                                                                                       |
| `windows/adapters`       | `windows/core` (26), `windows/platform` (14), `windows/adapters` (5), `windows/tray` (4), `windows/ai` (3), `windows/diagnostics` (3), 3 more areas       |
| `windows/infra`          | `windows/core` (44), `windows/hotstrings` (29), `windows/infra` (22), `windows/settings` (18), `windows/menu` (11), `windows/diagnostics` (10), 4 more    |
| `windows/modules/keymap` | `windows/modules/keymap` (20), `windows/hotstrings` (2), `windows/ai` (1)                                                                                 |
| `windows/ui/menu`        | `windows/ai` (18), `windows/menu` (5), `windows/ui/menu` (5), `windows/hotstrings` (3), `windows/apps` (1), `windows/gestures` (1)                        |

## Drift since the covering campaign

Every campaign predates S01, so most covered areas drifted. The largest
behavioural drifts:

- `shared/layouts`, 57,918 lines since the pause campaign: the composer,
  emulation, layer and registry engines left `_shared/lua/layouts` with heavy
  edits (Studio store, XKB converter, number-row policy);
- `shared/core`, 25,067 since tooltips-wpm: network, i18n, text and the shared
  UI engines;
- `shared/ui/layout_editor`, 12,644 since the hotstring cascade campaign;
- then `macos/ai` (3,076), `shared/settings` (2,554), `linux/platform`
  (2,002), `linux/ai` (1,657), `windows/core` (1,447),
  `windows/ui/layout_manager` (1,343) and the three `hotstrings` areas (1,023
  to 1,325 each).

The 13 stable areas are small: `linux/uninstall.sh`, `windows/clipboard`, the
Windows network PAC and keyboard layout DLL sources, `windows/ui/download_window`,
two Windows forwarders and four single shared files.

The full table, by behavioural lines:

| Area                                                 | Members |  Lines | Latest campaign                 | Pin        | Changed / new members | Changed lines | Behavioural lines | Status  |
| ---------------------------------------------------- | ------: | -----: | ------------------------------- | ---------- | --------------------: | ------------: | ----------------: | ------- |
| `shared/layouts`                                     |      52 |  70465 | 11-12-pause                     | `0ebaaac2` |               47 / 13 |         58070 |             57918 | drifted |
| `shared/core`                                        |     199 | 159803 | 11-13-tooltips-wpm              | `d9c6436e` |                62 / 2 |         25595 |             25067 | drifted |
| `shared/ui/layout_editor`                            |      17 |  15160 | 11-11-hotstring-cascade         | `96e13ff9` |                16 / 8 |         12656 |             12644 | drifted |
| `macos/ai`                                           |     127 |  68757 | 11-12-i18n-runtime              | `b61a7b67` |               124 / 1 |          4040 |              3076 | drifted |
| `shared/settings`                                    |      56 |  20916 | 11-12-pause                     | `0ebaaac2` |                56 / 6 |          3202 |              2554 | drifted |
| `linux/platform`                                     |      40 |  20304 | 11-12-tap-holds-followup        | `c054579d` |                38 / 1 |          2172 |              2002 | drifted |
| `linux/ai`                                           |      57 |  21968 | 11-12-i18n-runtime              | `b61a7b67` |                57 / 0 |          2219 |              1657 | drifted |
| `windows/core`                                       |      86 |  41402 | 11-13-tooltips-wpm              | `d9c6436e` |                85 / 2 |          1749 |              1447 | drifted |
| `windows/ui/layout_manager`                          |       7 |   4505 | 11-12-pause                     | `0ebaaac2` |                 6 / 1 |          1357 |              1343 | drifted |
| `macos/hotstrings`                                   |      38 |  22563 | 11-12-hotstrings-engine         | `943cabf4` |                38 / 0 |          1543 |              1325 | drifted |
| `macos/diagnostics`                                  |      43 |  15723 | 11-12-i18n-runtime              | `b61a7b67` |                43 / 0 |          1467 |              1131 | drifted |
| `linux/hotstrings`                                   |      31 |  15162 | 11-12-hotstrings-engine         | `943cabf4` |                31 / 0 |          1339 |              1111 | drifted |
| `windows/hotstrings`                                 |      52 |  29517 | 11-12-pause                     | `0ebaaac2` |                52 / 1 |          1347 |              1023 | drifted |
| `windows/platform`                                   |      62 |  36676 | 11-12-tap-holds-followup        | `c054579d` |                47 / 2 |          1198 |               998 | drifted |
| `linux/settings`                                     |      16 |   2398 | 11-05-sequential                | `7aecd9a2` |                16 / 4 |           969 |               927 | drifted |
| `shared/ui/metrics_typing`                           |      15 |  13299 | 11-04-deep                      | `89b0b774` |                15 / 1 |           904 |               894 | drifted |
| `linux/modules/keystats`                             |      20 |  11712 | 11-11-metrics                   | `f6044e52` |                20 / 0 |           882 |               836 | drifted |
| `linux/gestures`                                     |      19 |   7783 | 11-11-hotstring-cascade         | `96e13ff9` |                19 / 0 |           963 |               789 | drifted |
| `macos/modules/keymap`                               |      12 |   5903 | 11-11-input-layout              | `e0a801ef` |                12 / 2 |           791 |               761 | drifted |
| `windows/ai`                                         |      77 |  51798 | 11-12-pause                     | `0ebaaac2` |                77 / 0 |          1184 |               754 | drifted |
| `macos/modules/keystats`                             |      39 |  18614 | 11-12-i18n-runtime              | `b61a7b67` |                29 / 1 |           691 |               649 | drifted |
| `macos/menu`                                         |      25 |   8718 | 11-12-menus-tray                | `b74634f0` |                25 / 0 |           725 |               615 | drifted |
| `linux/diagnostics`                                  |      15 |   4550 | 11-12-healthcheck               | `39d90bc3` |                15 / 1 |           678 |               568 | drifted |
| `linux/modules/keymap`                               |       8 |   3290 | 11-11-input-layout              | `e0a801ef` |                 8 / 1 |           613 |               561 | drifted |
| `shared/ui/metrics_apps`                             |       7 |   5574 | 11-04-deep                      | `89b0b774` |                 7 / 0 |           521 |               519 | drifted |
| `macos/infra`                                        |      12 |   1501 | 11-05-caps-word                 | `f2a7dba5` |                11 / 3 |           521 |               507 | drifted |
| `linux/ui/layout_manager`                            |       2 |    382 | 11-12-layout-manager            | `49d49988` |                 2 / 1 |           504 |               502 | drifted |
| `windows/ui/physical_shortcuts`                      |       5 |   1873 | 11-12-pause                     | `0ebaaac2` |                 5 / 1 |           509 |               499 | drifted |
| `macos/gestures`                                     |      20 |  12269 | 11-12-i18n-runtime              | `b61a7b67` |                20 / 0 |           622 |               476 | drifted |
| `macos/modules/updater`                              |       6 |   1868 | 11-04-recovery                  | `3a680d9f` |                 6 / 0 |           497 |               471 | drifted |
| `windows/modules/updater`                            |       8 |  10782 | 11-12-updater-followup          | `9feb515a` |                 8 / 0 |           519 |               467 | drifted |
| `windows/settings`                                   |      20 |  14382 | 11-12-pause                     | `0ebaaac2` |                20 / 0 |           572 |               466 | drifted |
| `shared/metrics`                                     |      60 |  13641 | 11-13-tooltips-wpm              | `d9c6436e` |                 8 / 3 |           467 |               465 | drifted |
| `macos/launcher`                                     |     104 |  26967 | 11-12-start-at-login            | `6dfaa693` |                22 / 1 |           477 |               437 | drifted |
| `shared/ai`                                          |     101 |  23030 | 11-12-ai-flows-followup         | `67ac8860` |                86 / 0 |           768 |               420 | drifted |
| `macos/settings`                                     |      14 |   6031 | 11-12-editors                   | `2f7264b6` |                14 / 0 |           451 |               405 | drifted |
| `windows/modules/keystats`                           |      66 |  27025 | 11-12-pause                     | `0ebaaac2` |                20 / 0 |           449 |               401 | drifted |
| `linux/core`                                         |     104 |  25845 | 11-17-key-combinations-bindings | `01ab90fa` |                 8 / 1 |           386 |               368 | drifted |
| `linux/ergopti_hotstrings.lua`                       |       1 |   3880 | 11-12-input-layout-followup     | `76da919b` |                 1 / 0 |           476 |               366 | drifted |
| `linux/modules/updater`                              |       7 |   4432 | 11-11-hotstring-cascade         | `96e13ff9` |                 7 / 0 |           395 |               357 | drifted |
| `macos/init.lua`                                     |       1 |   2575 | 11-04-recovery                  | `3a680d9f` |                 1 / 0 |           391 |               357 | drifted |
| `macos/modules/shortcuts`                            |      20 |  14792 | 11-17-key-combinations-bindings | `01ab90fa` |                11 / 1 |           368 |               346 | drifted |
| `macos/adapters`                                     |      25 |   4335 | 11-05-one-shot-shift            | `9c565c88` |                23 / 0 |           333 |               331 | drifted |
| `macos/ui/onboarding`                                |       1 |   1354 | 11-04-deep                      | `89b0b774` |                 1 / 0 |           324 |               318 | drifted |
| `windows/_generated`                                 |      28 |   4919 | 11-12-pause                     | `0ebaaac2` |                28 / 1 |           375 |               301 | drifted |
| `linux/apps`                                         |      14 |   1993 | 11-12-bundled-apps              | `a7cb1c1e` |                14 / 0 |           352 |               298 | drifted |
| `linux/menu`                                         |      14 |   1524 | 11-12-menus-tray                | `b74634f0` |                14 / 2 |           370 |               284 | drifted |
| `windows/modules/keymap`                             |      20 |  10212 | 11-12-pause                     | `0ebaaac2` |                12 / 0 |           343 |               279 | drifted |
| `windows/menu`                                       |      17 |  10568 | 11-12-start-at-login            | `6dfaa693` |                17 / 0 |           390 |               270 | drifted |
| `macos/core`                                         |      79 |  29807 | 11-17-key-combinations-bindings | `01ab90fa` |                10 / 1 |           256 |               248 | drifted |
| `shared/hotstrings`                                  |      45 |  10746 | 11-12-hotstrings-engine         | `943cabf4` |                42 / 1 |           356 |               234 | drifted |
| `shared/ui/hotstring_editor`                         |       3 |   3579 | 11-12-editors                   | `2f7264b6` |                 3 / 0 |           225 |               223 | drifted |
| `macos/platform`                                     |      56 |  42362 | 11-17-key-combinations-bindings | `01ab90fa` |                12 / 0 |           240 |               218 | drifted |
| `linux/ui/changelog`                                 |       1 |    857 | 11-04-deep                      | `89b0b774` |                 1 / 0 |           218 |               212 | drifted |
| `windows/ui/wpm`                                     |       7 |   2904 | 11-13-tooltips-wpm              | `d9c6436e` |                 3 / 0 |           194 |               192 | drifted |
| `shared/menu`                                        |      25 |  16385 | 11-12-pause                     | `0ebaaac2` |                24 / 0 |           309 |               191 | drifted |
| `shared/shortcuts`                                   |      34 |   6341 | 11-12-tap-holds-followup        | `c054579d` |                30 / 0 |           344 |               188 | drifted |
| `linux/ui/onboarding`                                |       2 |    736 | 11-04-deep                      | `89b0b774` |                 2 / 0 |           189 |               183 | drifted |
| `linux/clipboard`                                    |       6 |   2130 | 11-11-adapters                  | `486194c1` |                 6 / 0 |           183 |               159 | drifted |
| `macos/apps`                                         |      20 |   5886 | 11-12-bundled-apps              | `a7cb1c1e` |                 9 / 0 |           179 |               153 | drifted |
| `shared/ui/_generated`                               |       8 |  13461 | 11-12-onboarding                | `2530aaaa` |                 7 / 1 |           150 |               136 | drifted |
| `shared/ui/hotstrings_config_window`                 |       3 |    873 | 11-05-native-ui                 | `3aaaae7d` |                 3 / 0 |           136 |               136 | drifted |
| `macos/ui/changelog`                                 |       1 |   1140 | 11-04-recovery                  | `3a680d9f` |                 1 / 0 |           146 |               134 | drifted |
| `shared/ui/onboarding`                               |       3 |   1923 | 11-12-onboarding                | `2530aaaa` |                 3 / 0 |           129 |               129 | drifted |
| `windows/ui/menu`                                    |       5 |   2370 | 11-12-pause                     | `0ebaaac2` |                 5 / 0 |           143 |               129 | drifted |
| `shared/ui/changelog`                                |       5 |   3116 | 11-04-deep                      | `89b0b774` |                 3 / 0 |           125 |               123 | drifted |
| `linux/adapters`                                     |       8 |   5630 | 11-13-tooltips-wpm              | `d9c6436e` |                 6 / 0 |           120 |               112 | drifted |
| `shared/platform`                                    |       8 |   1435 | 11-04-recovery                  | `3a680d9f` |                 8 / 1 |           158 |               110 | drifted |
| `macos/ui/metrics_typing`                            |       3 |   1544 | 11-04-deep                      | `89b0b774` |                 3 / 0 |           106 |               106 | drifted |
| `windows/apps`                                       |      10 |   2075 | 11-12-pause                     | `0ebaaac2` |                10 / 0 |           127 |                91 | drifted |
| `shared/gestures`                                    |       4 |    378 | 11-11-gestures                  | `0ca3803f` |                 4 / 0 |           110 |                88 | drifted |
| `shared/keyboard`                                    |       7 |    900 | 11-05-sequential                | `7aecd9a2` |                 6 / 0 |           110 |                88 | drifted |
| `shared/updater`                                     |      29 |   5054 | 11-12-updater-followup          | `9feb515a` |                26 / 1 |           160 |                82 | drifted |
| `linux/install`                                      |      19 |   1784 | 11-12-start-at-login            | `6dfaa693` |                11 / 0 |           120 |                80 | drifted |
| `windows/infra`                                      |      22 |   9487 | 11-17-key-combinations-bindings | `01ab90fa` |                 4 / 0 |            80 |                80 | drifted |
| `windows/gestures`                                   |      18 |   8712 | 11-12-pause                     | `0ebaaac2` |                18 / 0 |           201 |                77 | drifted |
| `macos/ui/wpm`                                       |       3 |   1126 | 11-13-tooltips-wpm              | `d9c6436e` |                 3 / 0 |            76 |                74 | drifted |
| `windows/ui/changelog`                               |       1 |   1535 | 11-12-pause                     | `0ebaaac2` |                 1 / 0 |            84 |                74 | drifted |
| `shared/diagnostics`                                 |      32 |   6996 | 11-12-healthcheck               | `39d90bc3` |                29 / 0 |           195 |                71 | drifted |
| `linux/ui/physical_shortcuts`                        |       1 |    311 | 11-12-editors                   | `2f7264b6` |                 1 / 0 |            64 |                64 | drifted |
| `linux/modules/shortcuts`                            |      15 |   5768 | 11-17-key-combinations-bindings | `01ab90fa` |                 6 / 0 |            64 |                44 | drifted |
| `macos/ui/action_picker`                             |       1 |    449 | 11-05-native-ui                 | `3aaaae7d` |                 1 / 0 |            39 |                39 | drifted |
| `macos/ui/physical_shortcuts`                        |       1 |    335 | 11-04-deep                      | `89b0b774` |                 1 / 0 |            41 |                39 | drifted |
| `windows/tray`                                       |       6 |   1032 | 11-12-pause                     | `0ebaaac2` |                 6 / 1 |            53 |                39 | drifted |
| `linux/infra`                                        |      20 |   5182 | 11-17-key-combinations-bindings | `01ab90fa` |                 5 / 0 |            40 |                34 | drifted |
| `shared/ui/prompt_editor`                            |       3 |   1038 | 11-12-editors                   | `2f7264b6` |                 3 / 0 |            33 |                33 | drifted |
| `windows/ErgoptiPlus.ahk`                            |       1 |   1827 | 11-12-pause                     | `0ebaaac2` |                 1 / 0 |           420 |                32 | drifted |
| `shared/onboarding`                                  |       2 |    608 | 11-12-onboarding                | `2530aaaa` |                 2 / 0 |            34 |                30 | drifted |
| `shared/ui/host_bridge.js`                           |       1 |    267 | 11-12-webview-hosts             | `8e976501` |                 1 / 0 |            30 |                30 | drifted |
| `shared/apps`                                        |       8 |    823 | 11-12-start-at-login            | `6dfaa693` |                 8 / 0 |            43 |                29 | drifted |
| `windows/diagnostics`                                |      28 |  11086 | 11-12-pause                     | `0ebaaac2` |                28 / 0 |           202 |                28 | drifted |
| `shared/tap_hold`                                    |      15 |   3370 | 11-17-key-combinations-bindings | `01ab90fa` |                 1 / 0 |            25 |                25 | drifted |
| `windows/ui/update_check`                            |       1 |    968 | 11-12-pause                     | `0ebaaac2` |                 1 / 0 |            26 |                24 | drifted |
| `windows/ui/action_picker_webview.ahk`               |       1 |    920 | 11-12-pause                     | `0ebaaac2` |                 1 / 0 |            25 |                23 | drifted |
| `windows/modules/shortcuts`                          |       5 |   1345 | 11-12-pause                     | `0ebaaac2` |                 2 / 0 |            28 |                22 | drifted |
| `linux/ui/wpm`                                       |       2 |    943 | 11-13-tooltips-wpm              | `d9c6436e` |                 2 / 0 |            27 |                19 | drifted |
| `shared/ui/paths_editor`                             |       3 |    515 | 11-12-editors                   | `2f7264b6` |                 1 / 0 |            14 |                14 | drifted |
| `shared/ui/healthcheck`                              |       5 |   2687 | 11-12-healthcheck               | `39d90bc3` |                 2 / 0 |            14 |                12 | drifted |
| `macos/clipboard`                                    |       4 |    472 | 11-11-adapters                  | `486194c1` |                 4 / 0 |            18 |                10 | drifted |
| `windows/ui/action_picker`                           |       1 |    242 | 11-12-pause                     | `0ebaaac2` |                 1 / 0 |            10 |                10 | drifted |
| `macos/ui/menu`                                      |      13 |   6629 | 11-17-key-combinations-bindings | `01ab90fa` |                 4 / 0 |            13 |                 7 | drifted |
| `windows/ui/onboarding`                              |       7 |   2088 | 11-12-pause                     | `0ebaaac2` |                 4 / 0 |            18 |                 6 | drifted |
| `linux/ui/menu`                                      |       9 |   3053 | 11-17-key-combinations-bindings | `01ab90fa` |                 2 / 0 |            17 |                 5 | drifted |
| `shared/ui/personal_info_editor`                     |       3 |    298 | 11-12-editors                   | `2f7264b6` |                 2 / 0 |             5 |                 5 | drifted |
| `windows/adapters`                                   |       5 |   1153 | 11-12-pause                     | `0ebaaac2` |                 2 / 0 |             8 |                 4 | drifted |
| `windows/modules/take_note.ahk`                      |       1 |    594 | 11-12-pause                     | `0ebaaac2` |                 1 / 0 |             4 |                 4 | drifted |
| `windows/vendor`                                     |      26 |  15816 | 11-12-pause                     | `0ebaaac2` |                 6 / 0 |            14 |                 4 | drifted |
| `linux/install.sh`                                   |       1 |   1590 | 11-12-start-at-login            | `6dfaa693` |                 1 / 0 |            22 |                 2 | drifted |
| `linux/uninstall.sh`                                 |       1 |    535 | 11-12-linux-install             | `709fdfa5` |                 1 / 0 |             8 |                 0 | stable  |
| `shared/tray`                                        |       1 |     77 | 11-04-recovery                  | `3a680d9f` |                 1 / 0 |            10 |                 0 | stable  |
| `shared/ui/key_names.js`                             |       1 |     38 | 11-12-start-at-login            | `6dfaa693` |                 1 / 0 |             2 |                 0 | stable  |
| `shared/ui/metrics_manifest_keys.js`                 |       1 |     19 | 11-12-start-at-login            | `6dfaa693` |                 0 / 0 |             0 |                 0 | stable  |
| `windows/clipboard`                                  |       2 |   1648 | 11-12-pause                     | `0ebaaac2` |                 2 / 0 |             6 |                 0 | stable  |
| `windows/modules/shortcuts.ahk`                      |       1 |     30 | 11-12-pause                     | `0ebaaac2` |                 0 / 0 |             0 |                 0 | stable  |
| `windows/modules/updater.ahk`                        |       1 |     44 | 11-12-pause                     | `0ebaaac2` |                 1 / 0 |             2 |                 0 | stable  |
| `windows/native/ergopti_network_pac_platform.c`      |       1 |    269 | 11-12-pause                     | `0ebaaac2` |                 0 / 0 |             0 |                 0 | stable  |
| `windows/native/ergopti_network_pac_platform.h`      |       1 |      9 | 11-12-pause                     | `0ebaaac2` |                 0 / 0 |             0 |                 0 | stable  |
| `windows/native/ergopti_network_pac_test_platform.c` |       1 |    154 | 11-12-pause                     | `0ebaaac2` |                 0 / 0 |             0 |                 0 | stable  |
| `windows/native/ergopti_network_pac.c`               |       1 |    106 | 11-12-pause                     | `0ebaaac2` |                 1 / 0 |             2 |                 0 | stable  |
| `windows/native/keyboard_layout`                     |       3 |    934 | 11-12-pause                     | `0ebaaac2` |                 0 / 0 |             0 |                 0 | stable  |
| `windows/ui/download_window`                         |       2 |    888 | 11-12-pause                     | `0ebaaac2` |                 0 / 0 |             0 |                 0 | stable  |

## Never-campaigned units

Ranked by behavioural risk, then by size. The risk is a judgement, not a
measurement:

- **high:** the typing path, privacy, a native process, a timer or a tray;
- **medium:** a window with user actions or a metrics view;
- **low:** a page or helper with one shared source, where parity can only fail
  in the host.

Several of these modules had a campaign that compared them without naming
these files:

- the managed Ollama runtime: the 2026-11-05 native-ui campaign, at
  `3aaaae7d`, before these adapters existed under these names;
- the tray: the menus-tray campaign named only the menu files.

They are listed so that their next campaign reads the drift, not so that it
starts from nothing.

| Rank | Unit                                     | Members | Lines | Risk   |
| ---: | ---------------------------------------- | ------: | ----: | ------ |
|    1 | `macos/core/logger`                      |       8 |  4982 | high   |
|    2 | `macos/ai/adapters`                      |      14 |  3345 | high   |
|    3 | `shared/ai/adapters`                     |       9 |  2113 | high   |
|    4 | `linux/core/logger`                      |       5 |  1496 | high   |
|    5 | `linux/tray/adapters`                    |       2 |  1164 | high   |
|    6 | `macos/platform/focus`                   |       5 |  1033 | high   |
|    7 | `linux/native/archive_output`            |       2 |   715 | high   |
|    8 | `macos/menu/engine`                      |       4 |   667 | high   |
|    9 | `macos/apps/engine`                      |       1 |   602 | high   |
|   10 | `macos/core/timing`                      |       4 |   445 | high   |
|   11 | `macos/core/text`                        |       5 |   350 | high   |
|   12 | `windows/native/ergopti_lua_export.c`    |       1 |   331 | high   |
|   13 | `linux/platform/desktop_focus`           |       4 |   257 | high   |
|   14 | `linux/core/timing`                      |       4 |   240 | high   |
|   15 | `linux/apps/adapters`                    |       2 |   234 | high   |
|   16 | `linux/modules/keep_awake.lua`           |       1 |   231 | high   |
|   17 | `macos/ui/legacy_rules_cleanup.lua`      |       1 |   167 | high   |
|   18 | `macos/tray/adapters`                    |       1 |   153 | high   |
|   19 | `linux/menu/engine`                      |       3 |   113 | high   |
|   20 | `macos/ui/virtual_hid_update.lua`        |       1 |   110 | high   |
|   21 | `macos/apps/adapters`                    |       1 |    95 | high   |
|   22 | `linux/core/text`                        |       2 |    77 | high   |
|   23 | `macos/clipboard`                        |       1 |    59 | high   |
|   24 | `linux/hotstrings/adapters`              |       1 |    51 | high   |
|   25 | `macos/native/SystemSwitcherState.swift` |       1 |    31 | high   |
|   26 | `shared/ui/model_browser`                |       3 |  1884 | medium |
|   27 | `shared/ui/action_picker`                |       3 |  1882 | medium |
|   28 | `shared/ui/layout_editor_window`         |       4 |  1248 | medium |
|   29 | `macos/ui/metrics_apps`                  |       1 |  1241 | medium |
|   30 | `macos/ui/download_window`               |       3 |  1102 | medium |
|   31 | `shared/ui/download_window`              |       4 |   933 | medium |
|   32 | `shared/ui/layout_manager`               |       4 |   857 | medium |
|   33 | `macos/ui/permission_dialog`             |       2 |   808 | medium |
|   34 | `shared/ui/update_check`                 |       3 |   681 | medium |
|   35 | `macos/ui/layout_manager`                |       1 |   593 | medium |
|   36 | `linux/ui/download_window`               |       1 |   503 | medium |
|   37 | `linux/ui/action_picker`                 |       1 |   436 | medium |
|   38 | `linux/ui/update_check`                  |       1 |   427 | medium |
|   39 | `shared/ui/error_dialog`                 |       3 |   427 | medium |
|   40 | `shared/ui/update_channels.js`           |       1 |   365 | medium |
|   41 | `macos/ui/update_check`                  |       1 |   347 | medium |
|   42 | `shared/ui/physical_shortcuts`           |       3 |   316 | medium |
|   43 | `shared/ui/config_cleanup`               |       3 |   292 | medium |
|   44 | `shared/ui/release_notes`                |       4 |   289 | medium |
|   45 | `shared/ui/numeric_prompt`               |       3 |   282 | medium |
|   46 | `linux/ui/metrics_typing`                |       1 |   263 | medium |
|   47 | `shared/ui/token_prompt`                 |       3 |   257 | medium |
|   48 | `linux/ui/metrics_flush_bridge.lua`      |       1 |   249 | medium |
|   49 | `linux/ui/metrics_apps`                  |       1 |   218 | medium |
|   50 | `linux/platform`                         |       1 |   202 | medium |
|   51 | `shared/ui/metrics_rebuild_banner.js`    |       1 |   194 | medium |
|   52 | `shared/ui/metrics_freshness.js`         |       1 |   184 | medium |
|   53 | `shared/ui/metrics_calendar.js`          |       1 |   129 | medium |
|   54 | `shared/ui/version_order.js`             |       1 |   120 | medium |
|   55 | `linux/ui/user_action_editor.lua`        |       1 |   114 | medium |
|   56 | `linux/modules/take_note.lua`            |       1 |    61 | medium |
|   57 | `shared/ui/layout_analysis`              |      17 | 24165 | low    |
|   58 | `shared/ui/layout_composer`              |       7 |  4901 | low    |
|   59 | `shared/ui/layout_optimizer`             |       6 |  4039 | low    |
|   60 | `shared/ui/layout_analysis/board`        |       4 |  1020 | low    |
|   61 | `shared/ui/layer_editor`                 |       1 |   807 | low    |
|   62 | `shared/ui/markdown.js`                  |       1 |   666 | low    |
|   63 | `shared/ui/theme.css`                    |       1 |   648 | low    |
|   64 | `shared/ui/value_check.js`               |       1 |   611 | low    |
|   65 | `shared/ui/redact.js`                    |       1 |   512 | low    |
|   66 | `shared/ui/i18n.js`                      |       1 |   284 | low    |
|   67 | `shared/ui/issue_link.js`                |       1 |   191 | low    |
|   68 | `shared/ui/a11y_prefs.js`                |       1 |   132 | low    |
|   69 | `shared/ui/program_parameter.js`         |       1 |    84 | low    |
|   70 | `shared/ui/key_shape.js`                 |       1 |    83 | low    |
|   71 | `shared/ui/repository_links.js`          |       1 |    60 | low    |
|   72 | `shared/ui/theme_choice.js`              |       1 |    51 | low    |
|   73 | `shared/ui/dom_utils.js`                 |       1 |    38 | low    |
|   74 | `shared/ui/theme_tokens.js`              |       1 |    34 | low    |

Out of parity scope (generated, vendored, lock, data and port-spec files):

`shared/core/ports` (4922), `macos/diagnostics/data` (1638), `shared/ui/layout_analysis/_generated` (1363), `shared/_generated` (1224), `macos/_generated` (1127), `linux/_generated` (972), `macos/uv.lock` (955), `shared/ui/vendor` (861), `macos/ai/data` (551), `linux/diagnostics/data` (497), `shared/ui/apps.manifest.json` (249), `linux/vendor` (246), `shared/ui/layer_editor/_generated` (240), `shared/core` (149), `shared/ui/metrics_typing/_generated` (144), `windows/native/ergopti_lua_export_test.c` (127), `shared/data` (112), `macos/vendor/hs_asm` (89), `shared/ui/layout_composer/_generated` (66), `linux/ergopti-hotstrings.service` (57), `macos/pyproject.toml` (48), `macos/vendor/remap-runtime` (46), `windows/native/ergopti_lua_export.pin.json` (37), `macos/vendor/karabiner-elements` (22), `macos/data` (15).

## Proposed order for the next campaigns

Each campaign takes one bounded module on the three drivers and its shared
owner. Windows is the reference unless a shared contract says otherwise.

1. **Secure-field detection.** Units `macos/platform/focus` and
   `linux/platform/desktop_focus` were never campaigned. The Windows detector
   was named only by the adapters campaign (`486194c1`), and has drifted since.
   It decides whether a hotstring or an AI request reads or types into a
   password field, so it is privacy on the typing path. About 1,250 lines of
   detectors plus the shared `secure_apps` data. Taken below.
2. **Logger engines.** `macos/core/logger` (4,982 lines) and
   `linux/core/logger` (1,496), against `windows/core/logger`: the boot
   journal, perf counters, keystroke integrity and sinks. The single-source
   gates hold the vocabulary, not these engines.
3. **Managed Ollama runtime, re-read for drift.** `macos/ai/adapters` (3,345)
   and `shared/ai/adapters` (2,113): the bootstrap, daemon authority, pull and
   sessions, created after the 2026-11-05 native-ui campaign.
4. **Tray adapters.** `linux/tray/adapters` (AppIndicator, 1,164),
   `macos/tray/adapters` and the Windows tray adapters (named only by the
   pause campaign): the icon state, the menu rebuild and the click routing.
5. **Update and download windows.** `download_window` on macOS and Linux and
   its shared page; `update_check` on the three and its shared page; plus
   `release_notes`, `update_channels.js` and `version_order.js`. About 5,000
   lines. The Windows window shows only the managed download failure; the
   macOS one shows the model and runtime downloads.
6. **Pickers and prompts.** `action_picker`, `model_browser`,
   `numeric_prompt`, `token_prompt`, `error_dialog`, `config_cleanup` and
   `physical_shortcuts`: their shared pages and the Linux and macOS hosts.
7. **Metrics views.** `metrics_apps`, `metrics_typing`, the Linux flush bridge
   and the shared `metrics_*` helpers. The metrics campaigns read the
   producers and the store, not these views.
8. **Small native and single-file units.** `linux/native/archive_output`,
   `windows/native/ergopti_lua_export.c`, `linux/modules/keep_awake.lua`,
   `macos/ui/virtual_hid_update.lua`, `macos/ui/legacy_rules_cleanup.lua`,
   `macos/native/SystemSwitcherState.swift` and `linux/modules/take_note.lua`.
   Most are OS-specific: check each one's reason text, not a counterpart.
9. **Layout tool pages.** `layout_analysis`, `layout_composer`,
   `layout_optimizer`, `layout_editor_window` and the `layout_manager` page.
   They are the largest units (35,000 lines), but each has one shared source,
   so only the host bridges can differ.

Re-campaigns for drift, after the never-campaigned modules or when a module's
structure step lands:

- `shared/layouts`, with S29;
- `shared/core`;
- `shared/ui/layout_editor`;
- the `ai` areas, drifted since the i18n-runtime and ai-flows follow-up pins.

## First campaign: secure-field detection

Audited source: `b90ad8de` (`agent/parity-census`, from
`fix/windows-pc-2026-11-17`). Date: November 19, 2026.

### Scope

The three secure-field detectors and their shared data, against the Windows
reference:

- `windows/platform/focus/secure_field_detector.ahk`;
- `macos/platform/focus/secure_field_detector.lua`;
- `linux/platform/focus/secure_field_detector.lua`;
- the shared list `_shared/data/secure_apps.json` and its rule
  `_shared/apps/engine/secure_apps.lua`;
- the port `_shared/core/ports/SecureFieldDetector.spec.js`.

Callers were read only far enough to know how each driver joins the field
verdict and the application verdict. The UIA worker, the AT-SPI watchers and
the AX observers are not reviewed. Source reading only, no native receiving.

Checked and kept:

- **One list, one rule per identity kind:** Windows process names without
  case (`secure_field_detector.ahk:604-638`, a `Map` with `CaseSense "Off"`),
  macOS display names exact and Linux lowercase fragments
  (`secure_apps.lua:44-77`).
- **Unreadable list:** it fails closed on the three. Windows treats every
  application as secure (`secure_field_detector.ahk:617-622`); the Lua rule
  raises on a malformed list (`secure_apps.lua:45-63`).
- **Empty identity:** it is never secure on the three
  (`secure_field_detector.ahk:632`, macOS `:309`, Linux `:211`).
- **Joining the two axes:** Windows answers the application inside
  `SFD_IsSecureField` (`:104`). macOS ORs `isSecureApp` at every caller:
  keystats `context_tracker.lua:1263-1264` and `:1335-1336`, and the typing
  guard `expander/utils.lua:1629`, whose verdict stops the event tap before
  hotstrings and AI keys (`expander/init.lua:1882-1885`). Linux joins it in
  `keystats.is_context_protected`, which the focus guard publishes
  (`secure_field_detector.lua:178-183`). Different places, same result.

### Fixed

| Id     | OS      | Sequence                                                                  | macOS / Linux                                                | Windows before                                                                                                                                    | Regression                                                                                                                              |
| ------ | ------- | ------------------------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| SFC-01 | Windows | Type in the Windows Security credential prompt (`CredentialUIBroker.exe`) | Keychain Access, `seahorse`: the whole application is secure | The `system_keychain` row named `credential_guard`, which no process is called (`secure_apps.json:60`): the prompt was secure only field by field | `test-secure-apps-single-source.cjs` (Windows identities are `*.exe`), AHK « the Windows credential prompt is the system keychain row » |

The row came from the old typed Windows map, which had no caller before ADD-1
wired it (adapters report, « Windows, report only »). Its password box was
still protected through the field path (DirectUI is inconclusive, so the
verdict stays secure until UIA answers), but its user name and the rest of
the prompt were not, unlike the system keychain on macOS and Linux. Both
regressions are red on the old data: the gate names `credential_guard`, and the AHK case asserts the application axis (`SFD_IsSecureAppWindow`, with `notepad.exe` as the negative control).

### Open

- **SFC-02 (medium, macOS, hypothesis on its reach):** `refresh()` publishes
  « not secure » when it cannot classify (`secure_field_detector.lua:263-292`):
  - no frontmost application (`:272`);
  - no PID or no Accessibility API (`:153-155`);
  - a raised read (`:284-287`).

  Windows fails closed in the same states (`secure_field_detector.ahk:100-101`,
  `:118-127`), and so does Linux (`secure_field_detector.lua:152-163`,
  `:189-191`). macOS's own header promises the same (`:22-24`). The keystats
  caller marks the context incomplete through the refresh observer
  (`context_tracker.lua:151-157`), and the typing guard uses its own
  inspection, which returns nil on these paths (`expander/utils.lua:1632-1634`).
  So the reach is limited to keystats when no observer is bound. Not changed
  here: proving it needs the keystats ledger replayed with an AX failure.

- **SFC-03 (low, shared contract):** the port says a failed detection
  returns false, « not secure »
  (`SecureFieldDetector.spec.js:14-17`, `:51`). The three adapters
  deliberately fail closed instead (Windows `:17-23`, Linux `:19-21`, macOS
  `:22-24`). The spec and its test vectors should state fail-closed.
- **SFC-04 (decision):** rows with no identity on a driver that has the
  application:
  - `yubikey_manager`: Yubico Authenticator ships on Windows and macOS;
  - `google_authenticator`: macOS only;
  - `keepass`: no macOS name, but KeePass has no native macOS build.

  « Expand, never shrink » makes these additions, not fixes. The maintainer
  picks the identities.

- **SFC-05 (low, Windows test):** « a RoboForm.exe window is secure »
  (`test_adapter_compliance.ahk:82`) cannot fail. It asserts
  `SFD_IsSecureField(A_ScriptHwnd)`, which is true for any process because
  the script window is no Edit control and the field path fails closed. The
  new credential-prompt case asserts the application axis instead. The RoboForm
  case should do the same.
- **SFC-06 (low, Windows):** Credential Manager itself runs inside
  `explorer.exe` and `rundll32.exe`, which cannot be listed. Only its
  password boxes are protected, through the field path.

Native receiving: a real Windows Security prompt (for example the one for a
network share) typed into with a hotstring trigger, on Windows 10 and 11.
