# healthcheck (Hammerspoon)

## Purpose

The diagnostics window of the Debug menu. It collects a version 2 snapshot
(`_shared/modules/diagnostics/schema.json`) and shows it in the shared page
(`_shared/ui/healthcheck/`), which renders every section, keeps the preview of
what is shared and asks the host for each action by message.

Collection runs in two phases. Phase A reads memory, Hammerspoon queries and
small files only, under the schema's 5 ms budget, because the main run loop
also dispatches the event taps. Phase B runs the probes (api.github.com, the
local AI backend, sysctl and df, the processor load through the callback form
of `hs.host.cpuUsage` and ErgoptiPlus's own share and memory through ps, and
the Bluetooth keyboards, mice and trackpads through system_profiler, since
`hs.usb` sees none of them) as tasks, timers and HTTP requests bounded by their
timeouts, and pushes each answer into the open page.

## Key files

| File          | Description                                                                     |
| ------------- | ------------------------------------------------------------------------------- |
| `init.lua`    | Entry point: re-exports `core.lua`                                              |
| `core.lua`    | `M.run()` (phase A), `M.show_window()`, the `healthcheck` message handler       |
| `helpers.lua` | One synchronous collector per section                                           |
| `probes.lua`  | The asynchronous probes, each answering once: its result, a timeout or an error |
| `report.lua`  | The page's actions (copy, save, report, open) and the Debug menu's reports      |

## Usage

```lua
local Healthcheck = require("ui.healthcheck")
Healthcheck.show_window({ state = menu_state })          -- Debug > Diagnostics
require("ui.healthcheck.report").report_bug()            -- Debug > Report a bug (opens the preview)
```

Every page message goes through `_shared/lua/healthcheck/actions.lua`: the host
opens only the paths it collected, by field id, and the settings pages the
schema declares. Everything copied, saved or sent to GitHub is redacted again
by `_shared/lua/diagnostics/redact.lua`, whatever the page did.
