--- tests/support/modules/shortcuts/actions/action_handlers_declared_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_action_handlers_declared
--- DESCRIPTION:
--- Prelude shared by the test_action_handlers_declared_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

-- =========================================
-- =========================================
-- ======= 1/ Recording the shell ==========
-- =========================================
-- =========================================

--- Runs `body` with os.execute recording instead of running, and restores it.
---
--- The manager shells out through one local `_run`, so intercepting os.execute
--- catches every command whatever branch produced it — a stub on the module's
--- own helper would only see the branches that call the helper.
--- @param body function Receives the recorded command table.
local function with_recorded_shell(body)
	local commands = {}
	local real = os.execute
	os.execute = function(cmd)
		commands[#commands + 1] = tostring(cmd)
		return true
	end
	local ok, err = pcall(body, commands)
	os.execute = real
	if not ok then error(err, 0) end
end

--- Runs a callback with a fresh real page owner whose native SDK is unavailable.
--- Restores the exact previous page owner even when acquisition or the callback raises.
--- @param body function Receives the actual webview manager.
local function with_unavailable_webview(body)
	local name = "ui.webview_manager"
	local previous_webview = package.loaded[name]
	local ok, err = pcall(function()
		local Webview = helpers.load_module_with_dependency(name, "lgi", false)
		body(Webview)
	end)
	package.loaded[name] = previous_webview
	if not ok then error(err, 0) end
end

--- Every recorded command joined, for a substring hunt across all of them.
local function joined(commands)
	return table.concat(commands, "\n")
end

--- Runs every action in `ids` through the real dispatcher, with the shell, the
--- uinput emitter and the webview recorded, and returns the ids that reached
--- the "Unknown action" branch.
--- @param Gestures table The gestures manager.
--- @param ids table Action ids.
--- @param configure function|nil Installs daemon handlers after native doubles.
--- @return table unknown, table pressed Chords sent, by action id.
local function run_every_action(Gestures, ids, configure)
	local Logger = require("logger.shim")
	local saved = {
		debug = Logger.debug, warn = Logger.warn,
		emitter = package.loaded["modules.gestures.combo_emitter"],
		manager = package.loaded["modules.gestures.manager"],
		shortcuts = package.loaded["modules.shortcuts.manager"],
		webview = package.loaded["ui.webview_manager"], popen = io.popen,
	}
	-- Loaded again under the recording emitter below, since it keeps its own.
	package.loaded["modules.shortcuts.manager"] = nil
	local unknown, pressed, current = {}, {}, nil
	local function spy(fmt)
		if type(fmt) == "string" and fmt:find("Unknown action", 1, true) then unknown[#unknown + 1] = current end
	end
	Logger.debug = function(_, fmt) spy(fmt) end
	Logger.warn = function(_, fmt) spy(fmt) end
	package.loaded["modules.gestures.combo_emitter"] = {
		press = function(combo) pressed[current] = combo; return true end,
	}
	package.loaded["ui.webview_manager"] = { show = function() return true end }
	io.popen = function()
		return { read = function() return "selection" end, close = function() return true end }
	end
	local ok, err = pcall(with_recorded_shell, function()
		Gestures = helpers.load_module("modules.gestures.manager")
		if configure then configure(Gestures) end
		for _, id in ipairs(ids) do
			current = id
			Gestures.execute_action(id, "test__slot")
		end
	end)
	Logger.debug, Logger.warn = saved.debug, saved.warn
	package.loaded["modules.gestures.combo_emitter"] = saved.emitter
	package.loaded["modules.gestures.manager"] = saved.manager
	package.loaded["modules.shortcuts.manager"] = saved.shortcuts
	package.loaded["ui.webview_manager"] = saved.webview
	io.popen = saved.popen
	if not ok then error(err, 0) end
	return unknown, pressed
end

return {
	helpers = helpers,
	with_recorded_shell = with_recorded_shell,
	with_unavailable_webview = with_unavailable_webview,
	joined = joined,
	run_every_action = run_every_action,
}
