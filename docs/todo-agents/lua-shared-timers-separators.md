<!-- docs/todo-agents/lua-shared-timers-separators.md -->

# Lua timers ceiling, tap-binding malformed sources, POSIX separator owner

## Done (local dev, not pushed by this agent)

- `d5c520ce94` fix(timers): refuse a delay above 2^53 ms on every Lua timer boundary (L105). One
  ceiling, `MAX_TIMER_DELAY_MS = 2 ^ 53`, in `_shared/lua/number_policy.lua`, with
  `within_timer_ceiling()` and `timer_delay_ms(seconds)` (floating-point product: Lua 5.4 wrapped an
  integer second count negative). Enforced in `linux/infra/native_timer.lua` (every libuv timer arms
  there), both TimerScheduler adapters, the Linux event loop (`defer`, periodic, `sleep_ms`),
  `linux/infra/native_sleep.lua`, the shell runner and desktop confirmation deadlines, and macOS
  `sleep_us`. Corpus `_shared/tests/corpus/timer/delay_ceiling_vectors.json`, replayed by
  `_shared/lua/test/timer_delay_ceiling_contract.lua` from both suites.
- `e9a50f5ebd` test(tap-binding): read malformed native sources from a real file. Each vector names
  its exact outcome; a mutation case removes the malformed-source branch and requires every malformed
  vector to fail. macOS `tap_keys` now reports a read failure and malformed content separately.
- `b4711585e0` refactor(paths): give POSIX path splitting one shared owner
  (`_shared/lua/native_path.lua`, contract `_shared/lua/test/native_path_contract.lua`).
- `163b8214cb` test(macos): compile platform, vendor and generated sources too (the guard that
  missed `platform/remap/init.lua` at the 200-local limit).
- `2f52d000cb`, `1b764309b5`, `e1ad4c2c2a`, `e3a7eb6814`: infra/bootstrap, modules, remap and ui
  sites converted. The nav_layer and generator conversions landed inside `356d14a3f3`.
- `9fb40dd50f`, `2ef09cbfa7`: guard `macos/tests/meta/lua_safety/test_posix_path_separator_owner.lua`
  (empty baseline, floors of 300 files and 60 owner calls).

## Remaining

- `[/\\]` sites outside macOS, not converted (scope was the macOS driver):
  `rg -n '\[\^?(/\\\\|\\\\/)' static/ergopti_plus/_shared/lua static/ergopti_plus/linux --glob '!**/tests/**'`.
  About 25 shared sites (reload_gate, keymap/layers, layer_preset, diagnostics/snapshot,
  hotstrings/extensions, config_migrate, config_unused_keys, keycodes/evdev, llm/profile_selector...)
  and about 8 Linux ones. Keep the genuine Windows-path parsers (`program_parameter.lua` drive and UNC
  checks, `diagnostics/redact.lua` if it redacts Windows homes). Linux `infra/paths.lua`
  `normalize_native_separators` stays: it runs before the shared root is known.
- L105 no-luv periodic clock diagnosis is untouched. Windows AHK `SetTimer` was out of scope.
- The Linux injector's `luv.sleep` and `os.execute sleep` fallbacks (no FFI) do not check the
  ceiling; the FFI path does through `native_sleep`.

## Checks only CI can make

- Linux under LuaJIT: the ceiling fixture `linux/tests/fixtures/native_timer_finite_admission.lua`
  (26 cases, real libuv), the corpus replay and the tap-binding mutation (`loadstring`,
  `package.searchpath`). Local runs were Windows Lua 5.4 with a `luv.hrtime` shim; no WSL distro here.
- macOS: real `FileSystem.read` on the malformed temp files and the read-failure modes; the separator
  conversions on real macOS paths. Local macOS-suite failures (about 1400) are Windows-host
  environment failures present on the baseline as well.

## Risks

- Other agents edited `init.lua`, `infra/logger.lua`, `infra/notifications.lua` and remap files
  concurrently; commits were built on a private index from HEAD plus owned hunks only.
