# 001 — Hexagonal architecture with ports and adapters

| Field | Value |
|---|---|
| **Date** | 2025-09-01 |
| **Status** | Accepted |
| **Deciders** | Core team |

---

## Context

Ergopti targets three OS environments: macOS (Hammerspoon/Lua), Windows
(AutoHotkey), and Linux (LuaJIT). Each driver was originally self-contained,
meaning every OS-facing call — filesystem I/O, timers, HTTP, tray menus,
keyboard hooks, notifications, tooltips, window info — was scattered
throughout the feature modules. This created three problems:

1. **Duplication without abstraction.** The same logical operation (e.g.
   "write a file") was implemented differently in each driver, making
   cross-driver consistency impossible to verify.
2. **Untestable domain logic.** Feature modules could not be unit-tested
   without spinning up the full OS runtime (Hammerspoon or AHK).
3. **Combinatorial growth.** Adding a fourth driver (Linux) or a fifth
   (Espanso) required rewriting all OS interactions from scratch.

The team also observed that the domain logic (hotstring matching, tap-hold
detection, config parsing) is platform-agnostic — only the twenty OS-facing
surfaces differ between drivers.

## Decision

Adopt a **hexagonal (ports-and-adapters) architecture** across all drivers.

- **Ports** are formal JavaScript interface contracts stored in
  `static/ergopti_plus/shared/ports/`. Each port `.spec.js` file documents
  the exact method signatures, parameter types, and return values that
  every adapter must implement.
- **Adapters** are driver-specific implementations of those contracts. The
  macOS driver provides Hammerspoon adapters; the Linux driver provides
  LuaJIT/POSIX adapters; the Windows driver provides AHK COM adapters.
- **Domain modules** in `static/ergopti_plus/shared/domain/` depend only on
  port interfaces, never on concrete OS APIs.

The twenty port contracts are: `FileSystem`, `HttpClient`, `KeyboardHook`,
`Notifier`, `TextSender`, `TimerScheduler`, `TooltipRenderer`, `TrayMenu`,
`SecureFieldDetector`, `Clipboard`, `Storage`, `ProcessLifecycle`, `KeyState`,
`MouseControl`, `NetworkInfo`, `WindowInfo`, `WindowManager`, `AppLauncher`,
`Crypto`, `GraphicsRenderer`.

## Consequences

### Positive

- Domain logic can be unit-tested without any OS runtime.
- Adding a new driver requires only implementing the twenty port adapters.
- Port compliance is enforced by `npm run test:port-compliance`.
- Cross-driver divergence is caught at the spec level, not discovered at runtime.

### Negative / Trade-offs

- Adapters introduce an indirection layer; contributors must understand which
  port to extend rather than calling OS APIs directly.
- The twenty port specs must be kept in sync with every adapter as APIs evolve.

### Neutral

- Existing driver code that predates the ports is progressively migrated;
  the old call sites remain functional during migration.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Shared Lua/AHK utility library | Would tightly couple drivers to a shared runtime, breaking the hermetic test boundary |
| Driver-specific abstraction layers | Would still require per-driver test stubs; harder to cross-validate |
| No abstraction (status quo) | Made Linux driver addition require a full rewrite |

## Evidence in the codebase

- Port contracts: `static/ergopti_plus/shared/ports/*.spec.js` (20 files: `FileSystem.spec.js`, `HttpClient.spec.js`, `KeyboardHook.spec.js`, `Notifier.spec.js`, `TextSender.spec.js`, `TimerScheduler.spec.js`, `TooltipRenderer.spec.js`, `TrayMenu.spec.js`, `SecureFieldDetector.spec.js`, `Clipboard.spec.js`, `Storage.spec.js`, `ProcessLifecycle.spec.js`, `KeyState.spec.js`, `MouseControl.spec.js`, `NetworkInfo.spec.js`, `WindowInfo.spec.js`, `WindowManager.spec.js`, `AppLauncher.spec.js`, `Crypto.spec.js`, `GraphicsRenderer.spec.js`)
- Port spec documentation: `static/ergopti_plus/shared/ports/SPEC.md`
- Linux adapter implementations: `static/ergopti_plus/linux/adapters/`
- Compliance enforcement script: `tools/test/test-port-compliance.cjs` (`npm run test:port-compliance`)
- Domain module specs: `static/ergopti_plus/shared/domain/SPEC.md`
