--- modules/keymap/pause_layout_switch.lua

--- ==============================================================================
--- MODULE: Pause Layout Switch (Linux)
--- DESCRIPTION:
--- Switches the desktop's keyboard layout when the script pauses, resumes or
--- quits, to the layouts the user chose in Layout > « Layout on pause /
--- resume ». The shared policy (_shared/lua/layout/pause_switch_policy.lua)
--- decides which layout each event selects; the input source adapter switches.
---
--- FEATURES & RATIONALE:
--- 1. One owner, initialised once by the daemon. main() sits at LuaJIT's
---    upvalue limit, so its callers reach this module through require.
--- 2. A quit waits for the switch it started: the shutdown coordinator holds
---    the exit on is_settled()/when_settled() until the last command answers
---    (each one is bounded by the shared input-source deadline).
--- 3. A reload or a signal is not a quit: only the user's quit actions switch,
---    as on macOS.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Policy = require("layout.pause_switch_policy")

local LOG = "modules.keymap.pause_layout_switch"

local _switcher = nil
local _preferences = nil

--- Takes ownership of the switcher and the preferences reader.
--- @param deps table { switcher, preferences }: an input_source_switch switcher
---   and a reader exposing settings().
function M.init(deps)
	if _switcher ~= nil then error("the pause layout switch is already initialised", 2) end
	if type(deps) ~= "table" or type(deps.switcher) ~= "table" or type(deps.switcher.select) ~= "function"
		or type(deps.switcher.is_settled) ~= "function" or type(deps.switcher.when_settled) ~= "function"
		or type(deps.preferences) ~= "table" or type(deps.preferences.settings) ~= "function" then
		error("the pause layout switch needs a switcher and a preferences reader", 2)
	end
	_switcher, _preferences = deps.switcher, deps.preferences
end

local function initialised()
	if _switcher == nil then error("the pause layout switch is not initialised", 3) end
	return _switcher
end

--- Whether init() ran: a shutdown during a failed startup has no switch to wait for.
--- @return boolean
function M.is_initialised() return _switcher ~= nil end

--- Starts the switch one event asks for.
--- @param event string "pause", "resume" or "quit".
--- @return string "none" when nothing switches, "pending" once a switch started.
local function apply(event)
	local switcher = initialised()
	local called, settings = pcall(_preferences.settings)
	if not called then
		Logger.error(LOG, "Layout switch on %s skipped: the settings are unreadable (%s).", event, tostring(settings))
		return "none"
	end
	local target = Policy.target(settings, event)
	if target == nil then return "none" end
	Logger.start(LOG, "Switching the keyboard layout to '%s' on %s…", target, event)
	switcher.select(target, function(ok, detail)
		if ok then
			Logger.success(LOG, "Keyboard layout switched to '%s' on %s.", target, event)
		else
			Logger.error(LOG, "Keyboard layout not switched to '%s' on %s: %s.", target, event, tostring(detail))
		end
	end)
	return "pending"
end

--- Follows a pause transition of the script.
--- @param paused boolean True when the script just paused.
--- @return string "none" or "pending"
function M.on_pause_change(paused)
	if type(paused) ~= "boolean" then error("the pause state must be a boolean", 2) end
	return apply(paused and "pause" or "resume")
end

--- Switches to the pause layout before a user quit.
--- @return string "none" or "pending"
function M.on_quit() return apply("quit") end

--- on_quit for the quit actions: a failure is logged and never stops the quit,
--- which the user must always be able to reach.
--- @return string "none", "pending" or "failed"
function M.quit_safely()
	local called, result = pcall(M.on_quit)
	if called then return result end
	Logger.error(LOG, "The quit layout switch failed: %s.", tostring(result))
	return "failed"
end

--- Whether no switch is running or queued.
--- @return boolean
function M.is_settled() return initialised().is_settled() end

--- Calls listener once no switch is running or queued.
--- @param listener function
function M.when_settled(listener) initialised().when_settled(listener) end

--- The switcher the menu lists and selects layouts through.
--- @return table switcher
function M.switcher() return initialised() end

--- Test seam: forgets the owner so a test can initialise a fresh one.
function M._reset_for_test()
	_switcher, _preferences = nil, nil
end

return M
