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
			"webview manager",
			"input capture gate",
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


helpers.describe("shutdown coordinator: explicit native acknowledgment", function()
	local function fixture(owner)
		local state = { stops = 0, hooks = 0, loops = 0 }
		local coordinator = ShutdownCoordinator.new({
			pre_wait = { owner, { name = "ordinary", stop = function() state.stops = state.stops + 1 end } },
			keyboard_hook = {
				isRunning = function() return state.hooks == 0 end,
				stop = function() state.hooks = state.hooks + 1 end,
				emergency_stop = function() state.hooks = state.hooks + 1 end,
			},
			event_loop = { stop = function() state.loops = state.loops + 1 end },
		})
		return coordinator, state
	end

	helpers.it("retains native false until exact acknowledgment without replaying ordinary owners", function()
		local native = { closed = false, calls = 0 }
		local coordinator, state = fixture({ name = "app runtime", wait_for_ack = true,
			stop = function() native.calls = native.calls + 1; return native.closed end })
		helpers.assert_true(coordinator.request("quit"))
		helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(state.loops, 0)
		helpers.assert_eq(state.hooks, 1)
		helpers.assert_eq(coordinator.request("duplicate"), false)
		helpers.assert_eq(coordinator.poll(), false)
		helpers.assert_eq(state.stops, 1)
		native.closed = true
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(state.loops, 1)
		helpers.assert_eq(state.hooks, 1)
		helpers.assert_eq(state.stops, 1)
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(state.loops, 1)
	end)

	helpers.it("contains opt-in exception while retaining its physical barrier", function()
		local closed = false
		local coordinator, state = fixture({ name = "app runtime", wait_for_ack = true,
			stop = function() if not closed then error("unknown native close") end; return true end })
		helpers.assert_true(coordinator.request("quit"))
		helpers.assert_eq(state.loops, 0)
		helpers.assert_eq(coordinator.poll(), false)
		closed = true
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(state.loops, 1)
	end)

	helpers.it("retains original stop callback across registry replacement and reentrant poll", function()
		local coordinator, reentered, closed
		local owner = { name = "app runtime", wait_for_ack = true }
		owner.stop = function()
			owner.stop = function() return true end
			owner.wait_for_ack = false
			reentered = coordinator.poll()
			return closed == true
		end
		local state
		coordinator, state = fixture(owner)
		coordinator.request("quit")
		helpers.assert_eq(reentered, false)
		helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(state.loops, 0)
		helpers.assert_eq(coordinator.poll(), false)
		closed = true
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(state.loops, 1)
	end)

	helpers.it("actual daemon registry admits no loop stop before owned runtime cleanup", function()
		local path = helpers.driver_root() .. "/ergopti_hotstrings.lua"
		local file = assert(io.open(path, "r")); local text = file:read("*a"); file:close()
		local registry = text:match("local shutdown = ShutdownCoordinator%.new%(%{(.-)\n%}%)[\r\n]")
		helpers.assert_true(type(registry) == "string" and registry ~= "", "actual daemon registry must exist")
		local state = { closed = false, stops = 0, loops = 0, cancelled = 0 }
		local env = setmetatable({ ShutdownCoordinator = ShutdownCoordinator,
			dyn_hotstrings = false, updater = false, file_watchers = false,
			process_lifecycle = false, secure_field_detector = false, metrics = false,
			webview_manager = false, tooltip_preview = false, gestures = false, input_capture_gate = false,
			prediction_engine = {
				shutdown_runtime = function() state.stops = state.stops + 1; return state.closed end,
				cancel = function() state.cancelled = state.cancelled + 1 end,
			},
			package = { loaded = {} }, require = function() return { cleanup = function() end, flush = function() end } end,
			TimerScheduler = { cancelAll = function() end }, Logger = { warn = function() end },
			keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() state.loops = state.loops + 1 end },
		}, { __index = _G })
		local capture = text:match("(local shutdown_runtime = prediction_engine and prediction_engine%.shutdown_runtime.-)\nlocal shutdown = ShutdownCoordinator")
		helpers.assert_true(type(capture) == "string", "actual daemon captures the exact runtime callback")
		local body = capture .. "\nreturn ShutdownCoordinator.new({" .. registry .. "\n})"
		local compiled, why
		if setfenv then compiled, why = loadstring(body, "actual daemon shutdown registry"); if compiled then setfenv(compiled, env) end
		else compiled, why = load(body, "actual daemon shutdown registry", "t", env) end
		helpers.assert_true(type(compiled) == "function", tostring(why))
		local coordinator = compiled()
		coordinator.request("quit")
		helpers.assert_eq(state.stops, 1, "actual daemon must stop the originating app service")
		helpers.assert_eq(state.loops, 0)
		helpers.assert_true(coordinator.is_pending())
		env.prediction_engine.shutdown_runtime = function() return true end
		helpers.assert_eq(coordinator.poll(), false, "foreign public replacement cannot acknowledge retained cleanup")
		state.closed = true
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(state.loops, 1)
		helpers.assert_eq(state.cancelled, 1, "existing prediction cleanup remains one-shot")
	end)
	helpers.it("captures opt-in debt before an earlier registry owner replaces its callback", function()
		local closed, old_calls, loops = false, 0, 0
		local native = { name = "runtime", wait_for_ack = true, stop = function()
			old_calls = old_calls + 1; return closed
		end }
		local coordinator = ShutdownCoordinator.new({
			pre_wait = {
				{ name = "earlier", stop = function()
					native.stop = function() return true end; native.wait_for_ack = false
				end }, native,
			},
			keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() loops = loops + 1 end },
		})
		coordinator.request("quit")
		helpers.assert_eq(old_calls, 1)
		helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(loops, 0)
		closed = true
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(old_calls, 2)
		helpers.assert_eq(loops, 1)
	end)

	helpers.it("throwing diagnostics cannot erase an acquired native cleanup barrier", function()
		local logger = require("logger.shim")
		local previous = logger.error
		local closed = false
		local coordinator, state = fixture({ name = "runtime", wait_for_ack = true,
			stop = function() if not closed then error("unknown native close") end; return true end })
		logger.error = function() error("diagnostic reporter failed") end
		local ok, err = xpcall(function()
			local requested, accepted = pcall(coordinator.request, "quit")
			helpers.assert_true(requested)
			helpers.assert_eq(accepted, true, "first request admits the actual retained cleanup barrier")
			helpers.assert_true(coordinator.is_pending())
			helpers.assert_eq(state.hooks, 1)
			helpers.assert_eq(state.loops, 0)
			helpers.assert_eq(coordinator.poll(), false)
			closed = true
			helpers.assert_true(coordinator.poll())
			helpers.assert_eq(state.loops, 1)
		end, debug.traceback)
		logger.error = previous
		if not ok then error(err, 0) end
	end)

	helpers.it("retains opted-in native debt after a preceding callback clears its registry slot", function()
		local closed, calls, loops = false, 0, 0
		local registry = {}
		registry[1] = { name = "earlier", stop = function() registry[2] = nil end }
		registry[2] = { name = "runtime", wait_for_ack = true, stop = function()
			calls = calls + 1; return closed
		end }
		local coordinator = ShutdownCoordinator.new({
			pre_wait = registry,
			keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() loops = loops + 1 end },
		})
		coordinator.request("quit")
		helpers.assert_eq(calls, 1, "captured native owner is not erased by a foreign registry mutation")
		helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(loops, 0)
		closed = true
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(calls, 2)
		helpers.assert_eq(loops, 1)
	end)

end)
