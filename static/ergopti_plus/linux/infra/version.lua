--- infra/version.lua

--- ==============================================================================
--- MODULE: Driver Version (Linux)
--- DESCRIPTION:
--- Single source of the Linux driver's version string. Every surface that shows a
--- version — the tray menu header, the healthcheck snapshot, the daemon build
--- context — reads M.VERSION from here so the value is defined exactly once. This
--- is the Linux counterpart to the macOS/Windows BUNDLE_VERSION build stamp: a
--- future build step can rewrite the single literal below (as Windows rewrites its
--- "__BUNDLE_VERSION__" placeholder) without touching any caller.
--- ==============================================================================

local M = {}

--- The Linux driver version. Single source of truth — never re-type this literal
--- at a call site; require this module and read M.VERSION instead.
M.VERSION = "3.0.0"

return M
