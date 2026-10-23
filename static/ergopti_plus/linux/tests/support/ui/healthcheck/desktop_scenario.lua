--- tests/support/ui/healthcheck/desktop_scenario.lua

--- ==============================================================================
--- MODULE: Actual Main Desktop Shutdown Fixture (Linux)
--- DESCRIPTION:
--- Compiles the production shutdown constructor against an explicit private
--- module registry. Other native owners are absent, not borrowed from the suite.
--- ==============================================================================

local M = {}

--- Builds the real daemon coordinator with only the requested desktop owner.
--- @param options table { loaded?, webview_shutdown?, loop_stop? }
--- @return table coordinator
--- @return table observed
function M.shutdown(options)
	options = options or {}
	local root = require("tests.helpers").driver_root()
	local fh = assert(io.open(root .. "/ergopti_hotstrings.lua", "rb"))
	local source = fh:read("*a"); fh:close()
	local capture = assert(source:match("(local shutdown_runtime = prediction_engine and prediction_engine%.shutdown_runtime.-)\nlocal shutdown = ShutdownCoordinator"))
	local entries = assert(source:match("local shutdown = ShutdownCoordinator%.new%(%{(.-)\n%}%)[\r\n]"))
	local observed = { stops = 0, flushes = 0, timers = 0 }
	local env = setmetatable({
		ShutdownCoordinator = require("infra.shutdown_coordinator"), package = { loaded = options.loaded or {} },
		keystats = { stop = function() return true end }, privacy_owners = {},
		dyn_hotstrings = false, updater = false, file_watchers = false, process_lifecycle = false,
		tooltip_preview = false, gestures = false, input_capture_gate = false, prediction_engine = false,
		webview_manager = options.webview_shutdown and { shutdown = options.webview_shutdown } or false,
		TimerScheduler = { cancelAll = function() observed.timers = observed.timers + 1 end },
		require = function(name)
			assert(name == "modules.llm.agent_learning", "unexpected cold dependency: " .. name)
			return { flush = function() observed.flushes = observed.flushes + 1 end }
		end,
		keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
		event_loop = { stop = function()
			observed.stops = observed.stops + 1
			if options.loop_stop then options.loop_stop() end
		end },
	}, { __index = _G })
	local text = capture .. "\nreturn ShutdownCoordinator.new({" .. entries .. "\n})"
	local chunk
	if setfenv then chunk = assert(loadstring(text, "actual Main desktop shutdown")); setfenv(chunk, env)
	else chunk = assert(load(text, "actual Main desktop shutdown", "t", env)) end
	return chunk(), observed
end

return M
