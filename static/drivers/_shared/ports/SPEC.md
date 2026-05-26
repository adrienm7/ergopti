# Ergopti+ — Ports & Adapters Specification (Hexagonal Architecture — Step 1)

This folder defines the **port contracts** for the seven OS-facing interfaces that
every Ergopti+ driver must implement. A "port" is a pure, platform-agnostic
interface description. A "driver adapter" is the OS-specific implementation that
satisfies it.

---

## 1. Motivation

Each driver (AHK, Hammerspoon, future Linux/web) currently calls OS APIs
directly — `InputHook`, `hs.eventtap`, `WinHttp`, `hs.http.asyncPost`, etc.
This makes domain logic (hotstring expansion, LLM calls, gesture recognition)
inseparable from OS details, blocking cross-driver testing and future ports.

The hexagonal architecture solves this by inverting dependencies:

```
Domain modules          Ports (contracts)         Adapters (OS)
──────────────          ─────────────────         ─────────────
Registry ────────────▶  KeyboardHook.spec.js ◀─── AHK InputHook
Expander ────────────▶  TextSender.spec.js   ◀─── AHK SendInput
TooltipController ───▶  TooltipRenderer.spec ◀─── HS canvas
LlmOrchestrator ─────▶  HttpClient.spec.js   ◀─── hs.http
                         TimerScheduler.spec  ◀─── hs.timer / SetTimer
                         Notifier.spec.js     ◀─── hs.notify / TrayTip
                         TrayMenu.spec.js     ◀─── hs.menubar / AHK Menu
```

Domain modules **only** call ports. Adapters **only** implement ports. The two
sides never import each other directly.

---

## 2. Folder Contents

```
static/drivers/_shared/ports/
├── SPEC.md                  ← This file
├── KeyboardHook.spec.js     ← Keyboard event subscription contract
├── TextSender.spec.js       ← Text/keystroke injection contract
├── TooltipRenderer.spec.js  ← Tooltip show/hide contract
├── HttpClient.spec.js       ← HTTP request/response contract
├── TimerScheduler.spec.js   ← Delayed/repeating action contract
├── Notifier.spec.js         ← System notification contract
└── TrayMenu.spec.js         ← Tray icon/menu management contract
```

Each `.spec.js` file exports:

1. **`portContract`** — The interface description (method names, parameter
   shapes, return value shapes, error conditions).
2. **`contractTestVectors()`** — Compliance test vectors an adapter MUST pass.
3. **`validateAdapter(adapter)`** — A structural validator that asserts every
   required method exists with the expected arity.

---

## 3. Driver Compliance Table

| Port | AHK Adapter | HS Adapter |
|---|---|---|
| KeyboardHook | `modules/keylogger/keylogger_hook.ahk` | `modules/keymap/init.lua` |
| TextSender | `lib/hotstrings/hotstring_engine.ahk` | `modules/shortcuts/actions/text.lua` |
| TooltipRenderer | `lib/tooltip.ahk` | `ui/tooltip/init.lua` |
| HttpClient | `modules/llm/api_remote.ahk` | `modules/llm/api_remote.lua` |
| TimerScheduler | `SetTimer` wrapper (inline) | `hs.timer` wrapper (inline) |
| Notifier | `TrayTip` (inline) | `lib/notifications.lua` |
| TrayMenu | `ui/tray_menu.ahk` | `ui/menu/init.lua` |

---

## 4. Compliance Checklist

A driver adapter is considered compliant with a port spec when:

- [ ] `validateAdapter(adapter)` returns no violations.
- [ ] All `contractTestVectors()` assertions pass when driven against the adapter
      (either via a mock harness or an integration test).
- [ ] Error paths (network failure, caret unavailable, hook already started) are
      handled according to the contract's `error_behavior` field — never silently
      swallowed.
- [ ] Lifecycle methods (`start`/`stop`) are idempotent: calling `start()` twice
      is safe; calling `stop()` before `start()` is safe.
- [ ] No domain-layer import appears inside an adapter file. Adapters depend only
      on OS APIs and the port contract.

---

## 5. Conventions

### 5.1 Method naming

All port methods use **camelCase** matching the JS spec files. Driver-language
adapters expose these methods under their own naming convention:

| Port method | AHK name | HS name |
|---|---|---|
| `hook.start()` | `KL_Hook_Start()` | `M.start()` |
| `hook.stop()` | `KL_Hook_Stop()` | `M.stop()` |
| `sender.send(text)` | `SendFinalResult(text)` | `_send_text(text)` |
| `tooltip.show(payload)` | `TooltipShow(items, dur)` | `M.show(content, …)` |
| `http.post(url, body, cb)` | `LLM_RemoteGenerate(…)` | `M.generate(…)` |
| `timer.after(delay, fn)` | `SetTimer(fn, -ms)` | `hs.timer.doAfter(s, fn)` |
| `notifier.send(msg)` | `TrayTip(title, text)` | `M.notify(title, body, kind)` |
| `tray.update(state)` | `UpdateTrayIcon()` | `update_icon(custom_text)` |

### 5.2 Error behavior vocabulary

| Value | Meaning |
|---|---|
| `"throw"` | Raise an exception / AHK throw / Lua error() |
| `"log_and_return"` | Log the error and return nil/false/null — never crash |
| `"ignore"` | No-op silently — use sparingly, document why |

### 5.3 Async vs. sync

- AHK HTTP calls are **synchronous** (blocks the thread for up to 30 s).
- HS HTTP calls are **asynchronous** (callback-based, never blocks).
- Both satisfy the `HttpClient` contract via a callback parameter: on AHK, the
  callback is invoked inline before `post()` returns; on HS, it is deferred to
  the next runloop cycle.

---

## 6. References

- [KeyboardHook.spec.js](./KeyboardHook.spec.js)
- [TextSender.spec.js](./TextSender.spec.js)
- [TooltipRenderer.spec.js](./TooltipRenderer.spec.js)
- [HttpClient.spec.js](./HttpClient.spec.js)
- [TimerScheduler.spec.js](./TimerScheduler.spec.js)
- [Notifier.spec.js](./Notifier.spec.js)
- [TrayMenu.spec.js](./TrayMenu.spec.js)
- [Tooltip engine spec](../tooltip/SPEC.md)
- [Config schema](../config_schema/SCHEMA.md)
