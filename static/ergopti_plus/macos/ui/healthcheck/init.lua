--- ui/healthcheck/init.lua

--- ==============================================================================
--- MODULE: Healthcheck
--- DESCRIPTION:
--- Diagnostic probe that snapshots the runtime state of the Hammerspoon driver
--- and returns it in both structured (table) and human-readable (string) form.
--- Designed to be called from the tray-menu "Healthcheck" item, an hs.ipc
--- command, or any other surface that needs a quick sanity check.
---
--- This is the entry point: requiring "ui.healthcheck" returns the public API
--- (run / record_error / format_plain / show_window). The implementation is split
--- to mirror the Windows ui/healthcheck/{init,core,helpers} layout:
---   ui.healthcheck.core    -- Probe, public API, hs.webview report window.
---   ui.healthcheck.helpers -- State-gathering probes + snapshot rendering.
---
--- Unlike AutoHotkey, Lua does not hoist symbols across files, so this index does
--- not merely #Include its siblings — it requires core (which in turn requires
--- helpers) and re-exports its table as the module's public surface.
--- ==============================================================================

return require("ui.healthcheck.core")
