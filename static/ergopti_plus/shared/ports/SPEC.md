# Ergopti+ — Ports & Adapters Specification (Hexagonal Architecture — Step 1)

This folder defines the **port contracts** for the twenty OS-facing port interfaces that
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
static/ergopti_plus/shared/ports/
├── SPEC.md                        ← This file
├── KeyboardHook.spec.js           ← Keyboard event subscription contract
├── TextSender.spec.js             ← Text/keystroke injection contract
├── TooltipRenderer.spec.js        ← Tooltip show/hide contract
├── HttpClient.spec.js             ← HTTP request/response contract
├── TimerScheduler.spec.js         ← Delayed/repeating action contract
├── Notifier.spec.js               ← System notification contract
├── TrayMenu.spec.js               ← Tray icon/menu management contract
├── FileSystem.spec.js             ← Synchronous file-system I/O contract
├── SecureFieldDetector.spec.js    ← Secure field/app detection contract
├── Clipboard.spec.js              ← OS clipboard read/write contract
├── Storage.spec.js                ← Persistent key-value storage contract
├── ProcessLifecycle.spec.js       ← OS process monitoring contract
├── KeyState.spec.js               ← Keyboard state query contract
├── MouseControl.spec.js           ← Mouse movement/click injection contract
├── NetworkInfo.spec.js            ← Network interface information contract
├── WindowInfo.spec.js             ← Focused window metadata contract
├── WindowManager.spec.js          ← Window move/resize/focus contract
├── AppLauncher.spec.js            ← Application launch contract
├── Crypto.spec.js                 ← Cryptographic utilities contract
└── GraphicsRenderer.spec.js       ← Off-screen graphics rendering contract
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
| KeyboardHook | `adapters/keyboard_hook.ahk` | `adapters/keyboard_hook.lua` |
| TextSender | `adapters/text_sender.ahk` | `adapters/text_sender.lua` |
| TooltipRenderer | `adapters/tooltip_renderer.ahk` | `adapters/tooltip_renderer.lua` |
| HttpClient | `adapters/http_client.ahk` | `adapters/http_client.lua` |
| TimerScheduler | `adapters/timer_scheduler.ahk` | `adapters/timer_scheduler.lua` |
| Notifier | `adapters/notifier.ahk` | `adapters/notifier.lua` |
| TrayMenu | `adapters/tray_menu.ahk` | `adapters/tray_menu.lua` |
| FileSystem | `adapters/file_system.ahk` | `adapters/file_system.lua` |
| SecureFieldDetector | `adapters/secure_field_detector.ahk` | `adapters/secure_field_detector.lua` |
| Clipboard | `adapters/clipboard.ahk` | `adapters/clipboard.lua` |
| Storage | `adapters/storage.ahk` | `adapters/storage.lua` |
| ProcessLifecycle | `adapters/process_lifecycle.ahk` | `adapters/process_lifecycle.lua` |
| KeyState | `adapters/key_state.ahk` | `adapters/key_state.lua` |
| MouseControl | `adapters/mouse_control.ahk` | `adapters/mouse_control.lua` |
| NetworkInfo | `adapters/network_info.ahk` | `adapters/network_info.lua` |
| WindowInfo | `adapters/window_info.ahk` | `adapters/window_info.lua` |
| WindowManager | `adapters/window_manager.ahk` | `adapters/window_manager.lua` |
| AppLauncher | `adapters/app_launcher.ahk` | `adapters/app_launcher.lua` |
| Crypto | `adapters/crypto.ahk` | `adapters/crypto.lua` |
| GraphicsRenderer | `adapters/graphics_renderer.ahk` | `adapters/graphics_renderer.lua` |

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
- [FileSystem.spec.js](./FileSystem.spec.js)
- [SecureFieldDetector.spec.js](./SecureFieldDetector.spec.js)
- [Clipboard.spec.js](./Clipboard.spec.js)
- [Storage.spec.js](./Storage.spec.js)
- [ProcessLifecycle.spec.js](./ProcessLifecycle.spec.js)
- [KeyState.spec.js](./KeyState.spec.js)
- [MouseControl.spec.js](./MouseControl.spec.js)
- [NetworkInfo.spec.js](./NetworkInfo.spec.js)
- [WindowInfo.spec.js](./WindowInfo.spec.js)
- [WindowManager.spec.js](./WindowManager.spec.js)
- [AppLauncher.spec.js](./AppLauncher.spec.js)
- [Crypto.spec.js](./Crypto.spec.js)
- [GraphicsRenderer.spec.js](./GraphicsRenderer.spec.js)
- [Tooltip engine spec](../tooltip/SPEC.md)
- [Config schema](../config_schema/SCHEMA.md)
