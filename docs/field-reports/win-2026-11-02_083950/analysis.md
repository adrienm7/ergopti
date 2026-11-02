# Field log analysis

Logs: ErgoptiPlus_2026-11-02.log (505 lines, 503 records, 0 continuation lines); span 2026-11-02 08:39:23:136 to 2026-11-02 08:40:04:281.
Previous report compared: none of this OS tag in this folder.

## What to fix first

| #   | Score | Kind    | What                                                                                         | Count | Detail                                                                                                                      |
| --- | ----- | ------- | -------------------------------------------------------------------------------------------- | ----- | --------------------------------------------------------------------------------------------------------------------------- |
| 1   | 3     | slow    | boot.total over its 2500 ms budget                                                           | 1     | max 7187 ms at 2026-11-02 08:39:29:283                                                                                      |
| 2   | 3     | slow    | hotpath:Config.TomlBuild over its 5 ms budget                                                | 1     | max 27.85 ms at 2026-11-02 08:39:28:914                                                                                     |
| 3   | 3     | slow    | hotpath:Menu.populate_leaf over its 5 ms budget                                              | 1     | max 15.15 ms at 2026-11-02 08:39:30:690                                                                                     |
| 4   | 3     | slow    | menu.rebuild over its 250 ms budget                                                          | 1     | max 1656 ms at 2026-11-02 08:39:26:707                                                                                      |
| 5   | 1     | warning | [HotPath] Slow Config.TomlBuild detail: <\*> update(s).                                      | 1     | 2026-11-02 08:39:28:914 [WARNING] [HotPath] Slow Config.TomlBuild detail: 0 update(s).                                      |
| 6   | 1     | warning | [HotPath] Slow Menu.populate_leaf detail: background; list=locales; rows=<_>; remaining=<_>. | 1     | 2026-11-02 08:39:30:691 [WARNING] [HotPath] Slow Menu.populate_leaf detail: background; list=locales; rows=16; remaining=4. |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ✅ network: pass (2026-11-02 08:40:04:116)
- ✅ composer: pass (2026-11-02 08:40:04:247)
- ✅ autohotkey: pass (collector_checks)
- ✅ driver_running: pass (collector_checks)
- ✅ python: pass (collector_checks)
- ✅ webview2: pass (collector_checks)
- ❌ field_boot_cost: fail (field_run_checks)
- ✅ field_network: pass (field_run_checks)
- ✅ field_composer: pass (field_run_checks)

Check verdicts summary: ✅ 8 pass, ❌ 1 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 0 other.

## Errors and warnings

0 error group(s), 6 warning group(s); 6 occurrence(s); no previous report, so none marked new since the previous report.

| Level   | Module      | Template                                                                                           | Count | First                   | Last                    | New |
| ------- | ----------- | -------------------------------------------------------------------------------------------------- | ----- | ----------------------- | ----------------------- | --- |
| WARNING | Menu        | Over budget: menu.rebuild took <_> ms (budget <_> ms).                                             | 1     | 2026-11-02 08:39:26:708 | 2026-11-02 08:39:26:708 |     |
| WARNING | HotPath     | Slow Config.TomlBuild: <_> ms own, <_> ms total, parent none (<\*> similar since the last line).   | 1     | 2026-11-02 08:39:28:914 | 2026-11-02 08:39:28:914 |     |
| WARNING | HotPath     | Slow Config.TomlBuild detail: <\*> update(s).                                                      | 1     | 2026-11-02 08:39:28:914 | 2026-11-02 08:39:28:914 |     |
| WARNING | BootProfile | Over budget: boot took <_> ms (budget <_> ms).                                                     | 1     | 2026-11-02 08:39:29:283 | 2026-11-02 08:39:29:283 |     |
| WARNING | HotPath     | Slow Menu.populate_leaf: <_> ms own, <_> ms total, parent none (<\*> similar since the last line). | 1     | 2026-11-02 08:39:30:690 | 2026-11-02 08:39:30:690 |     |
| WARNING | HotPath     | Slow Menu.populate_leaf detail: background; list=locales; rows=<_>; remaining=<_>.                 | 1     | 2026-11-02 08:39:30:691 | 2026-11-02 08:39:30:691 |     |

<details><summary>One example line per group</summary>

```
2026-11-02 08:39:26:708 [WARNING] [Menu] Over budget: menu.rebuild took 1656 ms (budget 250 ms).
```

```
2026-11-02 08:39:28:914 [WARNING] [HotPath] Slow Config.TomlBuild: 27.85 ms own, 32.04 ms total, parent none (0 similar since the last line).
```

```
2026-11-02 08:39:28:914 [WARNING] [HotPath] Slow Config.TomlBuild detail: 0 update(s).
```

```
2026-11-02 08:39:29:283 [WARNING] [BootProfile] Over budget: boot took 7187 ms (budget 2500 ms).
```

```
2026-11-02 08:39:30:690 [WARNING] [HotPath] Slow Menu.populate_leaf: 15.15 ms own, 15.15 ms total, parent none (0 similar since the last line).
```

```
2026-11-02 08:39:30:691 [WARNING] [HotPath] Slow Menu.populate_leaf detail: background; list=locales; rows=16; remaining=4.
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure                             | Count | p50  | p95  | Mean | Max  | Budget                                                                | Verdict     |
| ----------------------------------- | ----- | ---- | ---- | ---- | ---- | --------------------------------------------------------------------- | ----------- |
| boot.total                          | 1     | 7187 | 7187 | 7187 | 7187 | 2500 ms (static/ergopti_plus/\_shared/modules/timings/constants.toml) | ❌ over (1) |
| boot.stage:tray menu                | 1     | 1656 | 1656 | 1656 | 1656 | no budget declared                                                    | —           |
| boot.stage:layout and remaps        | 1     | 954  | 954  | 954  | 954  | no budget declared                                                    | —           |
| boot.stage:hotstrings               | 1     | 781  | 781  | 781  | 781  | no budget declared                                                    | —           |
| boot.stage:configuration            | 1     | 454  | 454  | 454  | 454  | no budget declared                                                    | —           |
| boot.stage:prefix watcher           | 1     | 282  | 282  | 282  | 282  | no budget declared                                                    | —           |
| boot.stage:menu row llm             | 1     | 281  | 281  | 281  | 281  | no budget declared                                                    | —           |
| boot.stage:shortcuts                | 1     | 94   | 94   | 94   | 94   | no budget declared                                                    | —           |
| boot.stage:menu row keyboard_layout | 1     | 78   | 78   | 78   | 78   | no budget declared                                                    | —           |
| boot.stage:menu row about           | 1     | 63   | 63   | 63   | 63   | no budget declared                                                    | —           |
| boot.stage:menu row hotstrings      | 1     | 47   | 47   | 47   | 47   | no budget declared                                                    | —           |
| boot.stage:i18n                     | 1     | 31   | 31   | 31   | 31   | no budget declared                                                    | —           |
| boot.stage:menu row gestures        | 1     | 16   | 16   | 16   | 16   | no budget declared                                                    | —           |
| boot.stage:menu row metrics         | 1     | 15   | 15   | 15   | 15   | no budget declared                                                    | —           |
| boot.stage:keyboard hook            | 1     | 15   | 15   | 15   | 15   | no budget declared                                                    | —           |
| boot.stage:feature gates            | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:menu row tap_holds       | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:menu row shortcuts       | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:menu row agent           | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:menu row configuration   | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:menu row language        | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:menu row suspend         | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:menu row reload          | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:menu row quit            | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:menu row debug           | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:magic key source         | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |
| boot.stage:metrics                  | 1     | 0    | 0    | 0    | 0    | no budget declared                                                    | —           |

### Menus

| Measure                    | Count | p50   | p95   | Mean  | Max   | Budget                                                               | Verdict     |
| -------------------------- | ----- | ----- | ----- | ----- | ----- | -------------------------------------------------------------------- | ----------- |
| menu.rebuild               | 2     | 7.9   | 1656  | 832   | 1656  | 250 ms (static/ergopti_plus/\_shared/modules/timings/constants.toml) | ❌ over (1) |
| hotpath:Menu.populate_leaf | 1     | 15.15 | 15.15 | 15.15 | 15.15 | 5 ms (static/ergopti_plus/\_shared/modules/timings/constants.toml)   | ❌ over (1) |
| menu.usable                | 1     | 4611  | 4611  | 4611  | 4611  | no budget declared                                                   | —           |
| menu.llm_staging           | 2     | 0     | 0     | 0     | 0     | no budget declared                                                   | —           |

Worst occurrences:

- menu.rebuild: 1656 ms at 2026-11-02 08:39:26:707, 7.9 ms at 2026-11-02 08:39:28:858
- menu.llm_staging: 0 ms at 2026-11-02 08:39:26:569, 0 ms at 2026-11-02 08:39:28:780

### Other hot-path segments

| Measure                  | Count | p50   | p95   | Mean  | Max   | Budget                                                             | Verdict     |
| ------------------------ | ----- | ----- | ----- | ----- | ----- | ------------------------------------------------------------------ | ----------- |
| hotpath:Config.TomlBuild | 1     | 27.85 | 27.85 | 27.85 | 27.85 | 5 ms (static/ergopti_plus/\_shared/modules/timings/constants.toml) | ❌ over (1) |

## Lifecycle

| Event | Count | First                   | Last                    |
| ----- | ----- | ----------------------- | ----------------------- |
| start | 1     | 2026-11-02 08:39:24:204 | 2026-11-02 08:39:24:204 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-11-02 08:39:24:204 — ErgoptiPlus session opened =====
```

</details>
