--- platform/remap/ke_paths.lua

--- ==============================================================================
--- MODULE: Karabiner-Elements Binary Paths
--- DESCRIPTION:
--- Absolute paths used either for the one supported CLI write boundary or for
--- read-only Karabiner installation checks, declared exactly once.
---
--- FEATURES & RATIONALE:
--- 1. Single Source: the `karabiner_cli` literal was written out three times —
---    in ke_lifecycle.lua, onboarding.lua and watchers.lua — with a fourth about
---    to be added by the gesture bridge. Karabiner v15.7 already renamed
---    one binary in that directory once, and a rename that reaches two of four
---    copies is a driver that reports Karabiner as installed while being unable
---    to talk to it.
--- 2. No Fallbacks: these paths are the PKG install locations and are not
---    configurable. A missing binary is reported by the caller that needs it,
---    loudly, rather than silently substituted here.
--- ==============================================================================

local M = {}

-- Shared package root. Command-line helpers remain under bin/, while v15.7+
-- moved the keyboard core executable into an app bundle so macOS can present
-- its permissions independently.
local SUPPORT_DIR = "/Library/Application Support/org.pqrs/Karabiner-Elements/"
local BIN_DIR = SUPPORT_DIR .. "bin/"

--- The CLI. Present in every version since v14 and never renamed, which makes it
--- both the IPC channel (`--set-variables`) and the most
--- reliable "is the full stack installed" probe.
M.CLI = BIN_DIR .. "karabiner_cli"

--- Shared console user server retained for version-tolerant diagnostics. It is
--- never started, stopped, signalled, or treated as Ergopti-owned state.
M.CONSOLE_USER_SERVER = BIN_DIR .. "karabiner_console_user_server"

--- The event grabber name used before v15.7.
M.GRABBER = BIN_DIR .. "karabiner_grabber"

--- The same component under its v15.7+ app-bundle location. The root daemon and
--- logged-in-user agent execute this same path, so callers must also check UID
--- when they need to distinguish the keyboard-processing daemon.
M.CORE_SERVICE = SUPPORT_DIR
	.. "Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service"

return M
