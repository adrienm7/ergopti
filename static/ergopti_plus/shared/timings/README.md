# `_shared/timings/constants.toml` — Canonical Timing Registry

## Purpose

`constants.toml` is the **single source of truth** for every timing constant
(debounce delays, poll intervals, timeouts, TTLs, animation durations) used
across the Ergopti drivers.

Before this file existed, timing values were scattered as magic numbers or
duplicated local constants in dozens of AHK and Lua files. Changes required
touching multiple files and keeping values manually in sync. This file
eliminates that problem.

---

## File layout

Values are grouped into thematic sections:

| Section        | Contents |
|----------------|----------|
| `[llm]`        | LLM prediction debounce, request timeouts, streaming watchdogs, warmup retries, model discovery |
| `[tooltip]`    | Tooltip display TTLs, error dialogs, success banners |
| `[debounce]`   | Keyboard/clipboard settle delays, Karabiner probing, hotstring expansion |
| `[gestures]`   | Touchdevice probe loop, tap geometry, click cooldown |
| `[keep_awake]` | Mouse-jitter activity simulation tick bounds |
| `[keylogger]`  | Ingest tick, session gaps, WPM windows, network/sensor polls, hook flush |
| `[tap_hold]`   | Tap-min, key-repeat initial delay and interval, one-shot shift |
| `[ergonomics]` | Block-break, flow window, hesitation detection |
| `[ui]`         | Menu refresh delays, Karabiner lifecycle, WPM widgets, HS reload debounce |

All values are in **milliseconds** unless the key name explicitly says `_sec`.

---

## How to consume this file

### Hammerspoon (macOS Lua)

The `toml_codec` adapter (already used for `config.toml`) can read this file
at startup. Expose the table through the shared state so constants are
available project-wide:

```lua
local ok, timings = pcall(require, "adapters.toml_codec")
-- … load and pass to modules via M.init()
```

The recommended pattern is to load once in `init.lua`, attach to the core
state table, and pass it to every module that needs timing values.

### AutoHotkey (Windows)

The project TOML reader (`modules/config/toml_reader.ahk` or equivalent)
should load `constants.toml` alongside `config.toml`. Constants are then
accessible as `Timings["section"]["key"]`.

---

## Adding a new constant

1. Choose the appropriate section (or add a new one if genuinely distinct).
2. Name the key `snake_case` with a `_ms` suffix (or `_sec` when the driver
   API works natively in seconds and conversion would be lossy).
3. Add a one-line comment explaining **why** the value exists and which
   driver constant(s) it maps to.
4. Remove the hardcoded value from the driver file and replace it with a
   lookup from this table.

---

## Editing policy

- **Never** hardcode a timing value in a driver file if an entry already
  exists here. Reference this file instead.
- **Never** duplicate a value — if two driver files use the same logical
  constant, they must both reference the same key in this file.
- Commit message for timing changes: `perf(shared): tune <key> — <reason>`.
