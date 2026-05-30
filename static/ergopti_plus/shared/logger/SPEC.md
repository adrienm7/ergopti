# Ergopti+ — Logger Specification (cross-driver)

This document is the **single source of truth** for the logger contract shared by
the AHK and Hammerspoon drivers. Both `lib/logger.ahk` and `lib/logger.lua` MUST
conform to every behaviour described here. Divergences between the two
implementations are listed explicitly in [§ Driver-specific extensions](#driver-specific-extensions)
and are intentional.

---

## 1. The 8 Variants

The logger exposes exactly **8 variants** organised on two axes:
_importance_ (DEBUG vs INFO vs WARNING vs ERROR) and
_lifecycle role_ (misc, start, end).

| Variant   | Axis    | Role       | Severity | Colour (guidance)   |
|-----------|---------|------------|----------|---------------------|
| `debug`   | DEBUG   | misc       | 10       | grey                |
| `trace`   | DEBUG   | lifecycle start | 10  | dim cyan            |
| `done`    | DEBUG   | lifecycle end   | 10  | dim green           |
| `info`    | INFO    | misc       | 20       | near-black          |
| `start`   | INFO    | lifecycle start | 20  | bright cyan         |
| `success` | INFO    | lifecycle end   | 20  | bright green        |
| `warn`    | WARNING | misc       | 30       | orange              |
| `error`   | ERROR   | misc       | 40       | red                 |

### 1.1 When to use each

- **`debug`** — verbose detail: setter calls, state snapshots, per-keystroke events,
  anything fired at high frequency.
- **`trace`** — start of a **routine internal operation** at debug granularity
  (e.g. arming a debounce timer). Always paired with `done`.
- **`done`** — successful end of a routine internal operation. Always paired with `trace`.
- **`info`** — general status worth knowing: config loaded, feature toggled, model changed.
- **`start`** — start of a **significant action** at INFO level (e.g. init, HTTP request,
  user-triggered operation). Always paired with `success`.
- **`success`** — successful completion of a significant action. Always paired with `start`.
- **`warn`** — unexpected condition the code can recover from; must be investigated.
- **`error`** — unrecoverable failure; execution should stop or degrade gracefully.

### 1.2 Lifecycle pairing rule

Lifecycle variants MUST come in pairs. A `start` without a following `success` in the
logs immediately signals a silent failure. Same for `trace`/`done`.

```
# Correct — matched pair at INFO level
start  "Initialising LLM bridge…"
success "LLM bridge initialised (4 mappings)."

# Correct — matched pair at DEBUG level
trace  "Inactivity timer started (0.300s)."
done   "Inactivity timer stopped."
```

---

## 2. Calling Convention

### 2.1 AHK

```ahk
LoggerDebug(Tag,   Msg, Args*)
LoggerTrace(Tag,   Msg, Args*)
LoggerDone(Tag,    Msg, Args*)
LoggerInfo(Tag,    Msg, Args*)
LoggerStart(Tag,   Msg, Args*)
LoggerSuccess(Tag, Msg, Args*)
LoggerWarn(Tag,    Msg, Args*)
LoggerError(Tag,   Msg, Args*)
```

- `Tag`  — caller-supplied module tag string, e.g. `"TapHoldLoader"`.
- `Msg`  — format string using AHK `{N}` placeholders (e.g. `"Loaded {1} key(s)."`).
- `Args` — variadic arguments substituted into `Msg`.

### 2.2 Hammerspoon / Lua

```lua
Logger.debug(module_name,   msg, ...)
Logger.trace(module_name,   msg, ...)
Logger.done(module_name,    msg, ...)
Logger.info(module_name,    msg, ...)
Logger.start(module_name,   msg, ...)
Logger.success(module_name, msg, ...)
Logger.warn(module_name,    msg, ...)
Logger.error(module_name,   msg, ...)
```

- `module_name` — caller-supplied module tag string, e.g. `"menu_llm"`.
- `msg`         — format string using Lua `string.format` `%` syntax
  (e.g. `"Loaded %d key(s)."` ).
- `...`         — variadic arguments substituted into `msg`.

---

## 3. Log Line Format

Every emitted line MUST follow this structure:

```
TIMESTAMP [LEVEL] [MODULE] message_body
```

### 3.1 Timestamp

```
YYYY-MM-DD HH:MM:SS:mmm
```

- ISO 8601 date, 24-hour time, **milliseconds zero-padded to 3 digits**.
- Separator between seconds and milliseconds is `:` (colon), not `.` (dot).

Examples:
```
2026-05-26 14:32:15:042
2026-05-26 08:00:00:000
```

### 3.2 Level label

The level label is the variant name in **UPPER CASE**, enclosed in square brackets.

```
[DEBUG] [TRACE] [DONE] [INFO] [START] [SUCCESS] [WARNING] [ERROR]
```

Note: the `warn` variant emits `[WARNING]` (not `[WARN]`).

### 3.3 Module tag

The caller-supplied tag is wrapped in square brackets verbatim.

```
[TapHoldLoader]
[menu_llm]
```

### 3.4 Full example lines

```
2026-05-26 14:32:15:042 [INFO] [TapHoldLoader] Tap-hold config loaded (8 key(s), 2 layer(s)).
2026-05-26 14:32:15:043 [START] [menu_llm] Initialising LLM bridge…
2026-05-26 14:32:15:044 [SUCCESS] [menu_llm] LLM bridge initialised (4 mappings).
2026-05-26 14:32:15:045 [WARNING] [gestures] Probe timed out — retry 1/3.
2026-05-26 14:32:15:046 [ERROR] [karabiner] Config write failed: permission denied.
```

---

## 4. Severity Filtering

The logger MUST expose a configurable minimum severity level. Lines below the
active level are discarded and never written to any output.

| Numeric level | Covers variants              |
|---------------|------------------------------|
| 10            | DEBUG, TRACE, DONE, INFO, START, SUCCESS, WARNING, ERROR |
| 20            | INFO, START, SUCCESS, WARNING, ERROR |
| 30            | WARNING, ERROR               |
| 40            | ERROR only                   |

String aliases accepted by `set_level()`:
`"debug"` → 10, `"info"` → 20, `"warning"` → 30, `"error"` → 40.

Default level: **10** (all variants active).

---

## 5. Ring Buffer

- Fixed capacity: **200 entries**.
- Implemented as a circular array (head pointer, O(1) push, O(n) snapshot).
- Each entry stores the complete formatted line (string, post-substitution).
- On overflow, the oldest entry is silently overwritten.
- A `ring_buffer_snapshot()` / `LoggerRingBufferSnapshot()` function returns
  the entries in chronological order as a flat list.

---

## 6. Log Files

### 6.1 Main log

| Property       | Value                                |
|----------------|--------------------------------------|
| Filename       | `ErgoptiPlus_YYYY-MM-DD.log`         |
| Encoding       | UTF-8                                |
| Line endings   | Platform-native (CRLF on Windows / LF on macOS) |
| Rotation       | Daily — a new file is created when the calendar day changes |
| Retention      | Files older than **14 days** are deleted on the next rotation |
| Purge strategy | Based on date in filename, not file modification time |

AHK path: `<ConfigDir>/autohotkey/logs/ErgoptiPlus_YYYY-MM-DD.log`
HS  path:  `<ConfigDir>/hammerspoon/logs/ErgoptiPlus_YYYY-MM-DD.log`

### 6.2 Fan-out sub-files

In addition to the main log, the logger routes each line to one or more
topical sub-files when the line matches the sub-file's routing rule.

Routing rules are defined in [`sub_files.toml`](./sub_files.toml) (see § 7).

Every sub-file uses the same UTF-8 encoding, CRLF/LF line endings, and
daily rotation as the main log. The retention policy (14 days) also applies.

### 6.3 Write strategy

- Lines are buffered and flushed on a timer interval (≤ 500 ms).
- Lines at `WARNING` or `ERROR` severity trigger an immediate forced flush
  to prevent data loss on crash.
- The file handle is kept open for the process lifetime to minimise I/O overhead.

---

## 7. Sub-file Routing (`sub_files.toml`)

Each entry in [`sub_files.toml`](./sub_files.toml) defines one topical sub-file:

```toml
[[sub_files]]
name     = "gestures"                  # suffix of ErgoptiPlus_<name>.log
patterns = ["[gestures", "gesture"]    # substring patterns matched against the full log line
platforms = ["ahk", "hs"]             # which drivers write this sub-file
```

A log line is routed to a sub-file if **any** of its `patterns` is found as a
substring of the full formatted line (case-sensitive). The match is against the
complete line including timestamp, level, and module tag.

---

## 8. Message Punctuation Rules

Log messages MUST follow these punctuation conventions:

- **In-progress / starting:** end with `…` (ellipsis) — `"Loading model…"`
- **Completed / asserted:** end with `.` (full stop) — `"Model loaded successfully."`
- **Lifecycle `start`/`trace`:** always end with `…`
- **Lifecycle `success`/`done`:** always end with `.`
- **Inline comments in code:** MUST NOT end with a full stop.

---

## 9. Initialisation

### 9.1 AHK

```ahk
LoggerInit()
```

Called once at driver startup. Reads the configured log directory from the
global path variables, sets up the flush timer, and purges old log files.

### 9.2 Hammerspoon / Lua

```lua
Logger.init_log_path(config_dir, max_age_days)
Logger.set_level(level)                         -- optional, default = 10
Logger.set_error_notification_handler(fn)       -- optional
```

Called during the `init.lua` boot sequence.

---

## 10. Driver-specific Extensions

These features exist in one driver only and are **not** part of the shared
contract. Both drivers are free to keep or remove them independently.

| Feature                        | AHK  | HS   | Notes |
|--------------------------------|------|------|-------|
| Coloured console output        | ✗    | ✓    | `hs.console.printStyledText()` with per-variant RGB colour |
| DEBUG-axis indentation         | ✗    | ✓    | 10-space prefix on DEBUG / TRACE / DONE lines in console |
| Consecutive-line deduplication | ✗    | ✓    | Suppresses repeated identical lines; prints count summary |
| Error notification callback    | ✗    | ✓    | Optional handler passed to `set_error_notification_handler()` |
| `pcall` wrapper                | ✗    | ✓    | `Logger.pcall(module, fn, ...)` — wraps pcall with error logging |
| `build` wrapper                | ✗    | ✓    | `Logger.build(module, label, fn, ctx)` — builder with error logging |

---

## 11. Test Vectors

[`test_vectors.json`](./test_vectors.json) contains pairs of
`(variant, module_name, raw_message, format_args)` → `expected_rendered_line`
that validate the line format produced by **both** loggers. The timestamp field
is replaced with the sentinel `"TIMESTAMP"` in expected lines so vectors are
time-independent.

Test-runner integration:
- **AHK**: `tests/test_logger.ahk` includes a section that loads `test_vectors.json`
  via `JsonParse()` and asserts each expected line (with timestamp replaced).
- **HS**: `tests/unit/lib/test_logger.lua` does the same via `require("lib.json")`.

---

## References

- AHK implementation: [`static/ergopti_plus/windows/lib/logger.ahk`](../../windows/lib/logger.ahk)
- HS implementation:  [`static/ergopti_plus/macos/lib/logger.lua`](../../macos/lib/logger.lua)
- Sub-file routing:   [`sub_files.toml`](./sub_files.toml)
- Test vectors:       [`test_vectors.json`](./test_vectors.json)
