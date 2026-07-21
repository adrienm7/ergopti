---
name: linux-driver
description: Foot-guns of the Linux driver (static/ergopti_plus/linux) — why observe mode corrupts typed text, the evdev decoder that nothing runs and nothing tests, 137 hand-quoted shell-outs with no adapter, LuaJIT-only CI, and kanata's uncoordinated device pick. Use when working on the Linux driver, and read the first section before touching the hook or the injector.
---

# Linux driver foot-guns

Style rules live in `.github/copilot-instructions.md`. This skill covers what
has actually gone wrong, or is provably wrong today, in the Linux driver.

**Almost nothing here is covered by automation.** The Linux e2e job is explicitly
stubbed — no real evdev, no real ydotool (`.github/workflows/ci.yml`) — and replays
the pure-Lua engine only. `EVIOCGRAB` and a ydotool injection have never run in
this repo's CI. Treat every runtime claim below as verified by reading, and
validate on real hardware before shipping.

`docs/PROJECT_MEMORY.md` currently has **no** Linux entry at all. When the
observe-mode fix lands, that is the first one it should gain.

## Observe mode is why hotstring replacement corrupts text

This is the driver's one open user-facing bug. Read this before touching the hook or the injector.

`keyboard_hook` has two capture modes. `observe` (the default) shells out to `libinput debug-events`, which reads events **without** consuming them. `intercept` shells out to `evtest --grab`, which takes `EVIOCGRAB` and suppresses delivery to the desktop.

The daemon starts the hook with **no `intercept` key at all** (`ergopti_hotstrings.lua:542-548`), and `_intercept = options.intercept == true` (`adapters/keyboard_hook.lua:396`) therefore resolves to `false`. There is no `--intercept` CLI flag: `intercept` appears in `ergopti_hotstrings.lua` only inside comments. **`get_mode()` can never return `"intercept"` in production.**

The failure: on a match the injector erases the trigger then types the replacement (`modules/hotstrings/injector.lua:220-230`). That window is tens of milliseconds. Because the daemon never grabbed, every key the user keeps typing during it goes **straight to the application**, interleaving with the synthetic backspace/type stream. Result: non-deterministic scrambling (`"abcd"` → `"acd"`).

The existing mitigation does not fix this. `injector._begin_injection()` / `_queue_char()` / `_end_injection()` (`ergopti_hotstrings.lua:365-368, 414-426`) defer the daemon's **own** buffer bookkeeping so the engine's model stays consistent. It has no authority over the OS input path. The queue only becomes a real fix once the daemon owns the output stream.

**Flipping the default is not the fix either.** Grabbing suppresses *all* physical input, so the daemon must then re-emit **every** event — modifiers, control keys, key-repeat (`value 2`) and releases included — through the single ydotool/uinput channel. Today nothing does that: `_pump_one` early-returns on releases (`keyboard_hook.lua:230-239`) and swallows modifiers and control keys (`:281-306`) instead of forwarding them. Turn on `intercept` as-is and normal typing vanishes entirely. The pass-through must be built and validated on real evdev+ydotool hardware first.

## The evdev struct decoder is dead code, and its test proves nothing

`modules/hotstrings/input_reader.lua` opens with a detailed account of the 24-byte `input_event` struct: 16-byte timeval, then `__u16 type` at offset 17, `__u16 code` at 19, `__s32 value` at 21, little-endian, `EV_KEY == 1`, values 0/1/2 = up/down/repeat (`:48-62`). `decode_u16_le`, `decode_s32_le` and `parse_event` implement it (`:192-225`), and `M.new()` wraps them in a blocking read loop (`:240-341`).

**None of it runs in production.** `keyboard_hook` never calls `M.new` — it scrapes the *text* output of `libinput`/`evtest` with Lua patterns (`keyboard_hook.lua:179-198`) and uses `input_reader` only for `resolve_char` (`:327-331`). Grep confirms `M.new` has no non-test caller. So the driver decodes `pressed`/`released` word-matching, not structs, and the offsets/endianness above describe a path nothing exercises.

Worse, `tests/unit/meta/test_input_reader_decode.lua` is named for the decoder and never invokes it. Its first case is literally `helpers.assert_true(true)  -- structure test` (`:26`). The case titled `"parse_event decodes a well-formed 24-byte input_event"` builds a correct synthetic buffer over `:35-45` and then **discards it**, asserting only `type(reader) == "table"` (`:49-53`). Every remaining case checks `pcall` did not throw. Real coverage of the decode is **zero**, with a green suite claiming otherwise.

Consequences: `M.new` carries a second, divergent copy of shift and control-key handling that will drift from `keyboard_hook` unnoticed; and if you ever switch to the direct path, the offsets are unvalidated (`OFFSET_TYPE = 17` hardcodes a 64-bit `timeval`; a 32-bit userspace has an 8-byte one and every field lands wrong). Either delete `M.new` or wire it up and give `parse_event` an assertion that actually reads its output.

## No ShellRunner adapter — 137 hand-quoted shell-outs

macOS and Windows both ship `adapters/shell_runner.{lua,ahk}`. **Linux is the only driver without one**, and it is the driver that shells out most: 137 `io.popen`/`os.execute` sites across 36 non-test files, including the keystroke path.

Quoting is therefore re-derived at each call site. Today every site is correct — `_device` is escaped at `keyboard_hook.lua:130` and `:133`, the kbd path at `kanata/manager.lua:369-371`, and the replacement text at `injector.lua:113` via `text:gsub("'", "'\\''")`, which is the correct POSIX close-escape-reopen idiom (verified: `it's working` → `'it'\''s working'`). Single-quoting also neutralises `$HOME`, backticks and `&` in replacement text.

That correctness is unenforced. Nothing tests it: `tests/unit/meta/test_injector_commands.lua` feeds `"$HOME `date` &"` and `"it's working"` through `inject()` and asserts only `pcall` returned true (`:61-75`) — never the resulting command string. A future call site that interpolates user text without the `gsub`, or a rewrite that drops it, passes the suite unchanged. Hotstring replacements are user-authored, so that is arbitrary command execution.

When you add a shell-out here: escape with the same `gsub` idiom, or better, add the missing `shell_runner` adapter and route through it.

Note also `injector.lua:115` passes `--clearmodifiers` to `ydotool type`. That flag is `xdotool` vocabulary; whether `ydotool` accepts it or errors is only answerable on a real machine.

## The race test's virtual runner silently drops apostrophes

`tests/unit/meta/test_injector_race.lua` models ydotool against a virtual document. It extracts the typed text with:

```lua
local text = cmd:match("%-%-%s+'([^']*)'$")   -- :56
if text then doc_t.value = doc_t.value .. text end
return true
```

`[^']*` cannot span the injector's escape sequence. Verified by running the real `send_text` escaping against this pattern in Lua:

```
-- 'by the way'        => match=by the way
-- 'it'\''s working'   => NIL
-- 'aujourd'\''hui'    => NIL
```

On a NIL match the runner appends nothing **and still returns `true`**, so the injection reads as successful and the document is silently left unmodified.

This is live only because both fixtures happen to be apostrophe-free (`"by the way"`). Add a French replacement — overwhelmingly likely in this repo — and the corruption case at `:134` (`assert_true(doc.value ~= "by the wayc")`) passes **for the wrong reason**: the text was never typed, so the values differ trivially. A regression test that asserts non-equality now guards nothing.

Fix the pattern before extending the fixtures, and prefer positive assertions (`assert_eq` on the expected document) over `~=`.

## CI runs LuaJIT only — luv and lfs are absent

`npm run test:linux` probes `luajit`, then `lua5.4`, then `lua` (`package.json:59-60`). **CI installs only `luajit`** and no luarocks (`.github/workflows/ci.yml:603-615`, e2e at `:631-641`). Develop against 5.4 locally and you are not testing what gates the merge.

What differs:

- **`utf8` is absent under LuaJIT.** `tests/run.lua:54-62` installs `compat.utf8` *before* any test module loads; without it `require("keylogger.utils")` dies on a nil global. Under 5.4 the shim is redundant, so a module that depends on the shim's exact shape breaks only on LuaJIT.
- **No bitwise operators.** LuaJIT is 5.1-based; `&`, `<<` and `//` are 5.3+. `device_finder.lua:169-171` spells the EV_KEY bit test out arithmetically for exactly this reason. Keep that discipline — a `&` compiles fine on 5.4 and is a syntax error in CI.
- **`os.execute` return type.** 5.1/LuaJIT return a number; 5.2+ return `true`. `injector.lua:85` handles both (`result == true or result == 0`); anything new must too.
- **`luv` is not installed.** `injector.lua:39-40` pcalls it, so `sleep_ms` always takes the forked-`/bin/sleep` fallback in CI. The yielding-sleep invariant is pinned only at source level (`test_injector_commands.lua:112-117` greps for the string `luv.sleep`) — the fast path is never executed anywhere.
- **`lfs` is not installed.** Test discovery falls back to shelling out to `find` (`tests/run.lua:122-146`).

Plain `lua5.1` is not viable at all: `goto` (`input_reader.lua:281`, `device_finder.lua:171`) is 5.2+, which LuaJIT supports and 5.1 does not.

## kanata: generated config, CI-guarded timeouts, uncoordinated device pick

kanata is the separate daemon doing tap-hold and the Ergo-QWERTY remap; the Lua daemon does hotstrings on top. `modules/kanata/manager.lua` generates the `defalias` block from `_shared/tap_hold/defaults.toml` via the shared `kanata_generator`, merges it into the static `kanata.kbd` template, and writes `~/.config/kanata/ergopti.kbd`.

**Never hand-edit the `defalias` block.** `npm run test:kanata-defalias-parity` (`tools/test/test-kanata-defalias-parity.cjs`) asserts every `tap-hold-press` timeout equals `round(defaults.toml time_activation_seconds * 1000)`, that the one-shot ms matches `_shared/modules/timings/constants.toml`, and that `_shared/tap_hold/golden_kanata_defalias.kbd` matches the committed `kanata.kbd`. Change a timeout in the TOML and regenerate; the gate catches drift in either direction.

The unguarded part is device selection. kanata is launched with `--auto-detect` and no explicit device (`manager.lua:367-371`), while the Lua daemon independently runs `device_finder.find_keyboard()`, which ranks purely on the name containing `"keyboard"` or `"kbd"` (`device_finder.lua:137-140, 156-195`). Nothing coordinates the two, and `find_keyboard` has **no exclusion for virtual/uinput devices** — neither kanata's output device nor ydotoold's. Two consequences, both only observable on real hardware:

- The daemon most likely reads the **physical** device, i.e. pre-kanata keycodes, so `resolve_char` sees the unremapped key while the app receives the remapped one.
- If auto-detection ever lands on the ydotoold virtual device, injected text feeds back into the engine and expansions loop.

Use `--device` explicitly when diagnosing anything layout-related.
