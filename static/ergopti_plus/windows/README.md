# ErgoptiPlus — Windows driver (AutoHotkey v2)

The Windows implementation of ErgoptiPlus. It mirrors the macOS driver
(`../macos/`) directory-for-directory so the analogue of any file lives at the
same relative path on both platforms.

## Entry point

`ErgoptiPlus.ahk` is the driver entry: directives, the `#Include` manifest, the
global error net (armed via `OnError`), and the boot orchestration (config load,
feature-map build, layout probes, hotkey registration, deferred post-"ready"
tasks). It holds **only** orchestration — feature logic lives in the modules it
includes.

> Source-file rule: AHK v2 files MUST be UTF-8 **with BOM** and **CRLF** line
> endings, or the parser silently aborts mid-file. Edit with tooling that
> preserves this; never append via a POSIX `cat >>`. The suite enforces it
> (`npm run test:ahk-encoding`).

## Layout (mirror of `../macos/`)

| Path | Role |
|---|---|
| `ErgoptiPlus.ahk` | Thin entry: directives + include manifest + error net + boot. |
| `adapters/` | OS-isolation layer — every `DllCall`, `Send*`, `WinGet*`, file/COM call lives here (one file per port of `_shared/core/ports/contracts.json`), so domain code stays OS-agnostic. |
| `lib/` | Infrastructure & domain helpers (no UI windows). Foldered submodules (`lib/hotstrings/`, `lib/updater/`, …) for the large ones. |
| `modules/<feature>/` | One folder per feature (`gestures/`, `keylogger/`, `keymap/`, `llm/`, `tap_holds/`, `shortcuts/`, …). |
| `ui/<window>/` | One folder per UI window (`menu/`, `tooltip/`, `onboarding/`, `healthcheck/`, `changelog/`, `spotlight/`, `wpm/`, `model_browser/`, `hotstrings_config_window/`), each with an `init.ahk` index. |
| `data/` | Pure data (default TOMLs, etc.). |
| `_generated/` | Codegen output — never hand-edited (regenerated from `_shared/`). |
| `tests/` | `meta/` (source-introspection guards), unit/integration tests, `e2e/`, `helpers/`, `stubs/`. |

## Running the tests

The canonical commands for every layer (AHK, Lua, JS, encoding) live in
[`../../../docs/TESTING.md`](../../../docs/TESTING.md). In short, the AHK suite
is run by pointing AutoHotkey64 at the runner:

```
& "C:\Program Files\AutoHotkey\v2.0.x\AutoHotkey64.exe" /ErrorStdOut tests\run_all.ahk
```

To syntax-check the full include graph, compile it with `Ahk2Exe` (`/in ErgoptiPlus.ahk /out %TEMP%\probe.exe`, exit 17 on a syntax error). Never use `/validate`: the flag is ignored and the script RUNS
without launching the driver.

## Conventions

Code is English, UI is French; tabs for indentation; section/subsection banners
and logging conventions are defined in
[`../../../.github/copilot-instructions.md`](../../../.github/copilot-instructions.md).
Hard-won gotchas live in
[`../../../docs/PROJECT_MEMORY.md`](../../../docs/PROJECT_MEMORY.md); work that is
known but not done is in [`../../../TODO.md`](../../../TODO.md).
