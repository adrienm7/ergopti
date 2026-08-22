---
name: linux-driver
description: Apply the Linux driver's LuaJIT, evdev, ydotool, and kanata invariants. Use when writing, editing, or reviewing the Linux driver.
---

# Linux driver foot-guns

Universal code rules live in `AGENTS.md`; the strict convention lint is the
formatting authority. This file covers what has actually gone wrong, or is
provably wrong today, in the Linux driver.

**Rewritten 2026-08-06.** Every technical section of the previous version
described a defect that had since been fixed — the grab, the dead evdev decoder,
the missing ShellRunner, the race test's apostrophe hole, kanata's device flag.
A skill is loaded automatically and read as current, so a stale one is worse
than none: it sends the next reader to repair code that is already correct, and
its warnings argue against decisions the driver has since made deliberately.
Verify before you trust anything here, and rewrite it when you find it wrong.

## What still holds

### CI runs LuaJIT — luv and lfs are absent

`npm run test:linux` probes `luajit`, then `lua5.4`, then `lua`. Develop against
5.4 locally and you are not testing what gates the merge.

- **`utf8` is absent under LuaJIT.** `tests/run.lua` installs `compat.utf8`
  before any test module loads. Under 5.4 the shim is redundant, so a module
  that depends on its exact shape breaks only on LuaJIT.
- **No bitwise operators.** LuaJIT is 5.1-based; `&`, `<<` and `//` are 5.3+.
  `device_finder.lua` spells the EV_KEY bit test out arithmetically for exactly
  this reason. A `&` compiles fine on 5.4 and is a syntax error in CI.
- **`os.execute` return type.** 5.1/LuaJIT return a number, 5.2+ return `true`.
  Every call site must accept both (`result == true or result == 0`).
- **`luv` is not installed**, so `sleep_ms` always takes the forked-`/bin/sleep`
  fallback in CI. **`lfs` is not installed**, so test discovery shells out.
- Plain `lua5.1` is not viable: `goto` is 5.2+.

### A `local` declared after the function that reads it is a nil global

The single most repeated defect in this driver — **five occurrences**, two of
them on 2026-08-06 alone. The function binds the nil GLOBAL instead of the
local, and the read silently does nothing: no error, no log, just a counter that
stays at zero or a state that never applies.

Declare module state in the state section at the top, above every reader. This
has its own entry in `docs/memory/linux-web-release.md`
(`project-lua-closure-before-local-nil-global`).

### A value must be named at EVERY boundary it crosses

Nine defects in one session had one shape: a value computed correctly and lost
at a boundary that drops whatever it does not name by hand — the writer's
`allowed` set, `get_app_stats`'s projection, the reader's code-to-table map, an
i18n envelope. Nothing errors; the symptom is a panel of zeroes, which reads as
"nobody uses this feature".

When adding a value that must reach the database or a page, grep the whole path
for anything that ENUMERATES fields and add it to every one. Then test the
join, not the units: this driver has shipped a walk and a writer that were each
correct in isolation while the flush called neither.

### Writing a table nobody reads is the same blank panel as not writing it

Both halves land in the same change, or the second half looks like the first
half not working. The same rule applies to adapters: `adapters/notifier.lua` was
deleted once under ADR-008 for having no callers — the file made the port matrix
answer "does Linux notify?" affirmatively by inspection while the practical
answer was no.

### Hardware is still unverified in CI

The Linux e2e job is stubbed — no real evdev, no real ydotool. `EVIOCGRAB` and a
ydotool injection have never run in this repo's CI. Treat every runtime claim as
verified by reading, and validate on real hardware before shipping.

`tests/hardware/` exists for exactly this and is the right home for anything a
runner cannot answer.

## What was fixed, so you do not go looking

- **The grab.** `--grab` is now the DEFAULT (`opts.grab = true`); `--no-grab` is
  the escape hatch. `get_mode()` returns `"intercept"` in production. The old
  warning that turning it on "makes normal typing vanish entirely" is obsolete —
  the pass-through was built.
- **The evdev struct decoder.** `M.new`, `parse_event` and the byte-order
  helpers were dead code with a test that asserted nothing. Both are gone;
  `input_reader` now exports `get_layouts` and `resolve_char` only.
- **`adapters/shell_runner.lua` exists.** New shell-outs go through it. There
  are still ~150 direct `io.popen`/`os.execute` sites outside it; migrating one
  is welcome, re-deriving quoting at a new site is not.
- **The race test's apostrophe hole.** It has a case named "types an apostrophe
  like any other character".
- **kanata's device selection.** It takes neither `--device` nor
  `--auto-detect` — no such flag exists. The generated config names the devices
  to keep away from, and `device_finder` drops `/devices/virtual/` so the daemon
  cannot read its own uinput device back.
- **kanata double-start.** `is_running()` asks the system, `owns_process()`
  asks whether this daemon spawned it, and only the second may be killed.

## kanata: never hand-edit the defalias block

`platform/remap/manager.lua` generates it from `_shared/tap_hold/defaults.toml`
through the shared `kanata_generator` and merges it into the static
`kanata.kbd` template. `npm run test:kanata-defalias-parity` pins every
`tap-hold-press` timeout to `round(time_activation_seconds * 1000)` and the
committed template to a golden file. Change the TOML and regenerate; the gate
catches drift in either direction.

A user's `tap_hold.toml` MERGES with the shared defaults key by key and field by
field. It used to replace them wholesale, which meant a file naming one key
disabled tap-hold on the rest of the keyboard.
