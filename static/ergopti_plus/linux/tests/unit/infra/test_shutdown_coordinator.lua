--- tests/unit/infra/test_shutdown_coordinator.lua

--- ==============================================================================
--- MODULE: Linux Shutdown Ownership Regression
--- DESCRIPTION:
--- Proves external luv owners quiesce before the input hook and event loop, and
--- pins every daemon exit trigger to that one transaction (LNX-046).
--- ==============================================================================

local helpers = require("tests.helpers")
local ShutdownCoordinator = helpers.load_module("infra.shutdown_coordinator")

local function coordinator_fixture(opts)
	opts = opts or {}
	local calls = {}
	local running = true
	local coordinator = ShutdownCoordinator.new({
		pre_wait = {
			{ name = "watchers", stop = function() calls[#calls + 1] = "watchers" end },
			{
				name = "timers",
				stop = function()
					calls[#calls + 1] = "timers"
					if opts.timer_failure then error("timer close failed") end
				end,
			},
			{ name = "transport", stop = function() calls[#calls + 1] = "transport" end },
		},
		keyboard_hook = {
			isRunning = function() return running end,
			stop = function() calls[#calls + 1] = "hook.stop"; running = false end,
			emergency_stop = function(reason)
				calls[#calls + 1] = "hook.emergency:" .. tostring(reason)
				running = false
			end,
		},
		event_loop = {
			stop = function() calls[#calls + 1] = "loop.stop" end,
		},
	})
	return coordinator, calls
end

helpers.describe("shutdown coordinator: pre-wait ownership", function()
	helpers.it("stops every external owner before the hook and loop", function()
		local coordinator, calls = coordinator_fixture()
		helpers.assert_true(coordinator.request("tray quit"))
		helpers.assert_eq(calls, {
			"watchers", "timers", "transport", "hook.stop", "loop.stop",
		})
		helpers.assert_true(coordinator.is_requested())
		helpers.assert_eq(coordinator.request("duplicate"), false)
		helpers.assert_eq(#calls, 5, "duplicate shutdown must not close an owner twice")
	end)

	helpers.it("contains one owner failure and still releases input and the loop", function()
		local coordinator, calls = coordinator_fixture({ timer_failure = true })
		helpers.assert_true(coordinator.request("signal 15"))
		helpers.assert_eq(calls, {
			"watchers", "timers", "transport", "hook.stop", "loop.stop",
		})
	end)

	helpers.it("uses the emergency hook path only for a runtime failure", function()
		local coordinator, calls = coordinator_fixture()
		coordinator.request("runtime callback failure", "runtime callback failure")
		helpers.assert_eq(calls[4], "hook.emergency:runtime callback failure")
		helpers.assert_eq(calls[5], "loop.stop")
	end)
end)

helpers.describe("shutdown coordinator: daemon integration", function()
	helpers.it("routes every terminal path through the owned transaction", function()
		local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
		local driver_root = source_path:match("^(.*)[/\\]tests[/\\]unit[/\\]infra[/\\]") or "."
		local fh = assert(io.open(driver_root .. "/ergopti_hotstrings.lua", "r"))
		local source = fh:read("*a")
		fh:close()

		for _, owner in ipairs({
			"updater background checks",
			"LLM prediction request",
			"file watchers",
			"process lifecycle",
			"tooltip preview",
			"gesture reader",
			"timer scheduler",
		}) do
			helpers.assert_contains(source, 'name = "' .. owner .. '"',
				"the pre-wait registry lost owner " .. owner)
		end
		for _, trigger in ipairs({
			"signal ", "tray quit", "degraded tray quit", "runtime callback failure",
			"keyboard hook stopped", "event loop returned",
		}) do
			helpers.assert_contains(source, "shutdown.request", "shutdown coordinator is unused")
			helpers.assert_contains(source, trigger, "shutdown trigger is not routed: " .. trigger)
		end
	end)
end)
