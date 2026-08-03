--- platform/remap/ke_paths.lua

--- ==============================================================================
--- MODULE: Karabiner-Elements Binary Paths
--- DESCRIPTION:
--- The absolute paths of the Karabiner-Elements binaries the driver shells out
--- to, declared exactly once.
---
--- FEATURES & RATIONALE:
--- 1. Single Source: the `karabiner_cli` literal was written out three times —
---    in ke_lifecycle.lua, onboarding.lua and watchers.lua — with a fourth about
---    to be added by the gesture bridge. Karabiner v16 (May 2026) already renamed
---    one binary in that directory once, and a rename that reaches two of four
---    copies is a driver that reports Karabiner as installed while being unable
---    to talk to it.
--- 2. No Fallbacks: these paths are the PKG install locations and are not
---    configurable. A missing binary is reported by the caller that needs it,
---    loudly, rather than silently substituted here.
--- ==============================================================================

local M = {}

-- The PKG installs every binary under this directory; it has been stable from
-- Karabiner v14 through v16.
local BIN_DIR = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/"

--- The CLI. Present in every version since v14 and never renamed, which makes it
--- both the IPC channel (`--set-variable`, `--get-variable`) and the most
--- reliable "is the full stack installed" probe.
M.CLI = BIN_DIR .. "karabiner_cli"

--- The user-level bridge daemon. Starting it directly is what primes the stack
--- headlessly — no Dock icon, no window, no Space switch.
M.CONSOLE_USER_SERVER = BIN_DIR .. "karabiner_console_user_server"

--- The event grabber, v15 and earlier.
M.GRABBER = BIN_DIR .. "karabiner_grabber"

--- The same component under its v16 name. Both spellings have to be probed:
--- an install that only has one of them is still a complete install.
M.GRABBER_V16 = BIN_DIR .. "Karabiner-Core-Service"

return M
