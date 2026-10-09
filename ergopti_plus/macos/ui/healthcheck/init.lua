--- ui/healthcheck/init.lua

--- ==============================================================================
--- MODULE: Healthcheck
--- DESCRIPTION:
--- The diagnostics window of the Hammerspoon driver: a snapshot of the runtime
--- state in the version 2 shape of _shared/modules/diagnostics/schema.json,
--- shown by the shared page _shared/ui/healthcheck/.
---
--- This is the entry point: requiring "ui.healthcheck" returns the public API
--- (run / show_window / config / event_tap_telemetry). The implementation is
--- split to mirror the Windows ui/healthcheck/ layout:
---   ui.healthcheck.core    -- The snapshot, the window and its message bridge.
---   ui.healthcheck.helpers -- The synchronous collectors, one per section.
---   ui.healthcheck.probes  -- The asynchronous probes (network, AI, sysctl, df).
---   ui.healthcheck.report  -- The page's actions and the Debug menu's reports.
---
--- Unlike AutoHotkey, Lua does not hoist symbols across files, so this index does
--- not merely #Include its siblings — it requires core (which in turn requires
--- helpers) and re-exports its table as the module's public surface.
--- ==============================================================================

return require("ui.healthcheck.core")
