--- platform/remap/ke_variables.lua

--- ==============================================================================
--- MODULE: Karabiner Variable Bridge
--- DESCRIPTION:
--- Sets a Karabiner-Elements engine variable from Hammerspoon, which is how the
--- driver reaches state that lives inside Karabiner rather than inside macOS.
---
--- FEATURES & RATIONALE:
--- 1. This is the ONLY IPC Karabiner offers. `karabiner_cli --set-variable`
---    writes a variable the running manipulators read on their next event; there
---    is no way to make Karabiner *perform* an action from outside. So every
---    catalogue action whose `karabiner_to` is a `set_variable` — the navigation
---    layer and CapsWord — is reachable from a gesture, and every action whose
---    `karabiner_to` is a manipulator construct (`sticky_modifier`) is not. That
---    split is why modules/gestures/sticky_modifiers.lua exists.
--- 2. Async, always. `hs.execute` blocks the Hammerspoon runloop, and these calls
---    are made from a gesture callback — the one place a blocking subprocess is
---    felt as the pointer stuttering under the user's fingers.
--- 3. Absence is reported, never absorbed. A user without Karabiner installed
---    gets an ERROR naming the binary, not a gesture that appears to work.
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local ShellRunner = require("adapters.shell_runner")
local KePaths     = require("platform.remap.ke_paths")

local LOG = "karabiner.variables"

-- `--set-variable` takes the name and the value as two separate argv entries.
local SET_VARIABLE_FLAG = "--set-variable"





-- =============================================
-- =============================================
-- ======= 1/ Writing an Engine Variable =======
-- =============================================
-- =============================================

--- Sets one Karabiner engine variable.
---
--- @param name string The variable name, as it appears in the generated config.
--- @param value number|string The value to write (Karabiner uses 0/1 for flags).
--- @return boolean True when the subprocess was started.
function M.set(name, value)
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "set(): variable name must be a non-empty string — nothing written.")
		return false
	end
	if value == nil then
		Logger.error(LOG, "set(): no value given for '%s' — nothing written.", name)
		return false
	end

	local text = tostring(value)
	Logger.trace(LOG, "Setting Karabiner variable %s=%s…", name, text)

	local started = ShellRunner.spawn(
		KePaths.CLI,
		{ SET_VARIABLE_FLAG, name, text },
		function(exit_code, _stdout, stderr)
			if exit_code == 0 then
				Logger.done(LOG, "Karabiner variable %s=%s.", name, text)
			else
				Logger.error(LOG, "Setting %s=%s failed (exit %s): %s",
					name, text, tostring(exit_code), tostring(stderr))
			end
		end
	).start()

	if not started then
		Logger.error(LOG, "Could not run '%s' — is Karabiner-Elements installed?", KePaths.CLI)
	end
	return started
end

--- Sets several variables in one call, in the order given.
--- The catalogue's layer actions each write two variables, and writing them one
--- call at a time from the action handler would let a failure on the second one
--- leave the engine in a half-switched state with nothing saying so.
---
--- @param pairs_list table Array of { name, value } pairs.
--- @return boolean True when every write started.
function M.set_all(pairs_list)
	if type(pairs_list) ~= "table" or #pairs_list == 0 then
		Logger.error(LOG, "set_all(): expected a non-empty array of { name, value } pairs.")
		return false
	end
	local all_started = true
	for _, entry in ipairs(pairs_list) do
		if not M.set(entry[1], entry[2]) then all_started = false end
	end
	return all_started
end

return M
