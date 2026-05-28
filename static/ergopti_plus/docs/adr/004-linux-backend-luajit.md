# 004 — Linux driver uses LuaJIT + libinput + uinput

| Field | Value |
|---|---|
| **Date** | 2025-10-01 |
| **Status** | Proposed |
| **Deciders** | Core team |

---

## Context

Ergopti currently ships functional drivers for macOS (Hammerspoon/Lua) and
Windows (AutoHotkey). The Linux driver directory (`static/ergopti_plus/linux/`)
exists and contains filesystem, timer, and notifier adapters written in Lua,
but no keyboard interception layer has been selected yet.

Three implementation paths were evaluated:

1. **AHK under Wine** — reuse the Windows driver unchanged. Rejected early:
   Wine overhead is unacceptable for a low-latency keyboard interceptor, and
   Wine is not available on all Linux distributions.
2. **Python + evdev** — the ecosystem is mature, but the existing shared
   domain modules are Lua. A Python runtime would require rewriting the
   domain layer or bridging two runtimes, both expensive and error-prone.
3. **LuaJIT + libinput + uinput** — the Hammerspoon driver is already
   written in Lua; `static/ergopti_plus/shared/lua/` contains portable Lua
   modules (TOML codec, LLM bridge utilities) that work under plain Lua 5.4
   or LuaJIT without modification. The Linux kernel exposes keyboard events
   via `libinput` (read path) and `uinput` (write path), both accessible
   from LuaJIT via FFI.

## Decision

The Linux driver will use **LuaJIT** as its runtime, **libinput** for
intercepting raw keyboard and pointer events, and **uinput** for injecting
synthetic key events.

All nine Linux adapters (`file_system.lua`, `http_client.lua`,
`keyboard_hook.lua`, `notifier.lua`, `text_sender.lua`, `timer_scheduler.lua`,
`tooltip_renderer.lua`, `tray_menu.lua`, `window_info.lua`) are written to
this assumption. The core I/O adapters use only the standard Lua I/O and `os`
libraries; the keyboard and injection adapters use LuaJIT FFI bindings to
libinput and uinput respectively.

The shared Lua modules in `static/ergopti_plus/shared/lua/` (TOML codec, LLM
utilities) are the canonical implementations for the Linux driver — no rewrite.

## Consequences

### Positive

- Domain modules in `shared/lua/` are reused directly; zero code duplication.
- LuaJIT's FFI removes the need for a C extension module for libinput/uinput.
- A single Lua version (5.4-compatible subset) spans macOS, Linux, and shared
  modules — contributors need to learn only one language.
- The port contract system (ADR-001) means the Linux adapters can be tested
  independently of the domain logic.

### Negative / Trade-offs

- LuaJIT requires a separate installation step on the target Linux system.
- libinput access typically requires the user to be in the `input` group or
  run with elevated privileges; this is a packaging concern.
- LuaJIT's FFI is more verbose than Python's ctypes for complex structs.

### Neutral

- The `uinput` device must be created and destroyed cleanly; a crash without
  teardown can leave a phantom input device in `/dev/input/`.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Python + evdev | Would require a second runtime; domain layer is Lua |
| AHK under Wine | Unacceptable latency and portability issues |
| C extension | Higher maintenance cost; LuaJIT FFI achieves the same result |
| Wayland-native (wlroots) | Too early — most distributions still ship Xorg or mixed sessions |

## Evidence in the codebase

- Linux adapter implementations (9 adapters): `static/ergopti_plus/linux/adapters/`
- Shared portable Lua modules: `static/ergopti_plus/shared/lua/toml_codec/`, `static/ergopti_plus/shared/lua/llm/`
- Port contracts: `static/ergopti_plus/shared/ports/KeyboardHook.spec.js`, `TextSender.spec.js`, etc.
- Linux tests: `static/ergopti_plus/linux/tests/`
