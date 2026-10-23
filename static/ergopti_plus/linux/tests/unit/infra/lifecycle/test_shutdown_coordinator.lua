--- tests/unit/infra/lifecycle/test_shutdown_coordinator.lua

--- ==============================================================================
--- MODULE: Linux Shutdown Ownership Regression
--- DESCRIPTION:
--- Proves external luv owners quiesce before the input hook and event loop, and
--- pins every daemon exit trigger to that one transaction (LNX-046).
--- ==============================================================================

local helpers = require("tests.helpers")
local ShutdownCoordinator = helpers.load_module("infra.shutdown_coordinator")

helpers.describe("actual Main startup capture admission", function()
	local MainStartup = require("tests.support.main_startup_fixture")
	local function position(events, target)
		for index, event in ipairs(events) do if event == target then return index end end
		error("The actual Main sequence never reached " .. target, 0)
	end
	for _, boundary in ipairs({ "tray", "onboarding", "watchers" }) do
		helpers.it("(startup-late-grab) blocked " .. boundary .. " preparation has no keyboard grab", function()
			local state = MainStartup.run({ block = boundary })
			helpers.assert_true(state.resumed and state.blocked, "The actual Main must remain inside blocked native preparation")
			helpers.assert_contains(tostring(state.error), "controlled preparation remains blocked")
			helpers.assert_true(state.ui_entered, "The real Main must enter the selected service")
			helpers.assert_eq(state.grabbed, false, "Physical input must stay with the desktop while startup cannot pump")
			helpers.assert_eq(state.pumps, 0)
		end)
	end
	helpers.it("(startup-late-grab) completes services before grab then exact publication and first pump", function()
		local state = MainStartup.run()
		helpers.assert_true(state.ok, tostring(state.error))
		helpers.assert_true(position(state.events, "watchers") < position(state.events, "hook.start"))
		helpers.assert_true(position(state.events, "signals.start") < position(state.events, "output.open"))
		helpers.assert_true(position(state.events, "output.open") < position(state.events, "hook.start"))
		helpers.assert_true(position(state.events, "layout.refresh") < position(state.events, "hook.start"))
		helpers.assert_true(position(state.events, "hook.start") < position(state.events, "layout.publish"))
		helpers.assert_true(position(state.events, "layout.publish") < position(state.events, "hook.pump"))
		helpers.assert_true(position(state.events, "diagnostics.prepare") < position(state.events, "hook.start"))
		helpers.assert_true(position(state.events, "boot.complete") < position(state.events, "diagnostics"))
		helpers.assert_true(position(state.events, "layout.publish") < position(state.events, "boot.complete"))
		helpers.assert_true(position(state.events, "boot.complete") < position(state.events, "hook.pump"))
		helpers.assert_eq(state.pumps, 1)
		helpers.assert_eq(state.pump_services, true)
		helpers.assert_eq(state.loop_after_complete, false)
		-- The local reload control starts once ready, on the tray's reload owner,
		-- and SIGUSR1 rings it.
		helpers.assert_eq(state.driver_control and state.driver_control.pid, 4242)
		helpers.assert_type(state.driver_control.reload, "function")
		helpers.assert_type(state.callbacks.on_usr1, "function")
	end)
	helpers.it("(signal-census) the E2E children expect every native signal Main installs", function()
		-- The E2E children count the active libuv signal handles before playing a
		-- scenario. Adding SIGUSR1 to Main without updating that count killed
		-- every daemon scenario on Linux CI, which only the E2E lane could see.
		local state = MainStartup.run()
		helpers.assert_true(state.ok, tostring(state.error))
		local started = {}
		local fake_luv = {
			new_signal = function() return {} end,
			signal_start = function(_, name) started[#started + 1] = name; return 0 end,
			signal_stop = function() return 0 end,
			is_closing = function() return false end,
			close = function(_, on_closed) on_closed() end,
		}
		local saved_luv, saved_signals = package.loaded["luv"], package.loaded["infra.signal_handlers"]
		package.loaded["luv"], package.loaded["infra.signal_handlers"] = fake_luv, nil
		local ran, err = pcall(function()
			local Signals = require("infra.signal_handlers")
			helpers.assert_true(Signals.start(state.callbacks), "Main's signal callbacks must install")
			helpers.assert_true(Signals.stop(), "the census installation must retire")
		end)
		package.loaded["luv"], package.loaded["infra.signal_handlers"] = saved_luv, saved_signals
		if not ran then error(err, 0) end
		helpers.assert_eq(table.concat(started, ","), "sigint,sigterm,sighup,sigusr1")
		for _, child in ipairs({ "daemon_keys_child", "startup_child" }) do
			local path = helpers.driver_root() .. "/tests/e2e/" .. child .. ".lua"
			local file = assert(io.open(path, "rb"))
			local source = assert(file:read("*a"))
			file:close()
			local expected = tonumber(source:match("active_signals == (%d+)"))
			helpers.assert_eq(expected, #started, child .. " must expect every signal handle Main installs")
		end
	end)
	helpers.it("(startup-late-grab) preserves the onboarding capture gate through the first pump", function()
		local state = MainStartup.run()
		helpers.assert_true(state.ok, tostring(state.error))
		helpers.assert_eq(state.pumps, 1)
		helpers.assert_eq(state.pump_blocked, true, "The real guarded consumers cannot run automation in the wizard")
		helpers.assert_eq(state.automation, 0)
		helpers.assert_eq(state.capture_gate.release("onboarding", 0), false)
		helpers.assert_eq(state.capture_gate.blocks_text(), true)
		helpers.assert_eq(state.capture_gate.release("onboarding", 1), true)
		helpers.assert_eq(state.capture_gate.blocks_text(), false)
	end)
	helpers.it("(startup-late-grab) a refused final capture inverse still closes output after cleanup", function()
		local state = MainStartup.run({ layout_refused = true })
		helpers.assert_eq(state.ok, false)
		helpers.assert_contains(tostring(state.protected_error), "Current capture inverse publication refused")
		helpers.assert_eq(state.grabbed, false)
		helpers.assert_eq(state.pumps, 0)
		helpers.assert_eq(state.closes, 1)
	end)
	helpers.it("(startup-late-grab) a refused Hook start retires prepared services and output", function()
		local state = MainStartup.run({ hook_refused = true })
		helpers.assert_eq(state.ok, false)
		helpers.assert_eq(state.grabbed, false)
		helpers.assert_eq(state.pumps, 0)
		helpers.assert_eq(state.closes, 1, "Startup cannot abandon the output it admitted before capture")
		helpers.assert_true(state.service_stops > 0)
	end)
	for _, action in ipairs({ "TERM", "quit" }) do
		helpers.it("(startup-late-grab) defers " .. action .. " cleanup until onboarding acquisition returns", function()
			local callback_ran, marked, cleanup_early = false, false, false
			local state = MainStartup.run({ on_boundary = function(boundary, observed, env)
				if boundary ~= "onboarding" then return end
				callback_ran = true
				if action == "TERM" then observed.callbacks.on_term(15) else observed.tray_quit() end
				marked = env.shutdown.is_requested()
				cleanup_early = observed.service_stops > 0
				helpers.assert_true(observed.signals_active, "Terminal watchers must remain installed during preparation")
			end })
			helpers.assert_true(callback_ran and marked, "The actual quit/signal callback must mark the real coordinator")
			helpers.assert_true(state.ok, tostring(state.error))
			helpers.assert_eq(cleanup_early, false, "Cleanup cannot complete against a service still being constructed")
			helpers.assert_true(state.owner_after_request, "The constructing service commits its owner after the callback returns")
			helpers.assert_true(state.service_stops > 0)
			helpers.assert_true(position(state.events, "onboarding.returned") < position(state.events, "services.stop"))
			helpers.assert_eq(state.services, false)
			helpers.assert_eq(state.closes, 1)
			helpers.assert_eq(state.signals_active, false)
			helpers.assert_eq(state.application_loops, 0)
			helpers.assert_eq(state.coordinator.is_pending(), false)
			helpers.assert_eq(state.grabbed, false)
			helpers.assert_eq(state.pumps, 0)
			helpers.assert_eq(state.loop_after_complete, false, "A completed coordinator cannot own a newly started loop")
		end)
	end
	for _, boundary in ipairs({ "hook.start", "layout.publish" }) do
		helpers.it("(startup-late-grab) terminal cancellation during " .. boundary .. " cannot publish a later capture", function()
			local callback_ran, cleanup_early = false, false
			local state = MainStartup.run({ on_boundary = function(current, observed)
				if current ~= boundary then return end
				callback_ran = true
				observed.callbacks.on_term(15)
				cleanup_early = observed.service_stops > 0
			end })
			helpers.assert_true(callback_ran)
			helpers.assert_true(state.ok, tostring(state.error))
			helpers.assert_eq(cleanup_early, false, "The native acquisition callback only requests cancellation")
			helpers.assert_true(state.owner_after_request)
			helpers.assert_eq(state.services, false)
			helpers.assert_eq(state.closes, 1)
			helpers.assert_eq(state.application_loops, 0)
			helpers.assert_eq(state.coordinator.is_pending(), false)
			local publications = 0
			for _, event in ipairs(state.events) do if event == "layout.publish" then publications = publications + 1 end end
			helpers.assert_eq(publications, boundary == "hook.start" and 0 or 1)
			helpers.assert_eq(state.grabbed, false)
			helpers.assert_eq(state.pumps, 0)
			helpers.assert_eq(state.loop_after_complete, false)
		end)
	end
	helpers.it("(startup-late-grab) a refused fast output closes the admitted signal owner before exit", function()
		local state = MainStartup.run({ fast_refused = true })
		helpers.assert_eq(state.ok, false)
		helpers.assert_true(state.access_reported, "The actual refusal must preserve the actionable access diagnostic")
		helpers.assert_eq(state.grabbed, false)
		helpers.assert_eq(state.application_loops, 0)
		helpers.assert_eq(state.signals_active, false)
		helpers.assert_eq(state.signal_stops, 1)
	end)
	helpers.it("(startup-late-grab) a partial signal admission still drains before acquiring output", function()
		local state = MainStartup.run({ signal_refused = true })
		helpers.assert_eq(state.ok, false)
		helpers.assert_eq(state.opens, 0)
		helpers.assert_eq(state.application_loops, 0)
		helpers.assert_eq(state.signals_active, false)
		helpers.assert_eq(state.signal_stops, 1)
	end)
	helpers.it("(startup-late-grab) a throwing partial-signal diagnostic cannot bypass native retirement", function()
		local state = MainStartup.run({ signal_refused = true, terminal_logger_throws = true })
		helpers.assert_eq(state.ok, false)
		helpers.assert_eq(state.opens, 0)
		helpers.assert_eq(state.application_loops, 0)
		helpers.assert_eq(state.signals_active, false)
		helpers.assert_eq(state.signal_stops, 1)
		helpers.assert_eq(state.coordinator.is_pending(), false)
	end)
	for _, boundary in ipairs({ "tray", "watchers", "hook.start", "layout.publish" }) do
		helpers.it("(startup-late-grab) unwinds " .. boundary .. " failure before retiring prepared owners", function()
			local state = MainStartup.run({ throw_at = boundary })
			helpers.assert_eq(state.ok, false)
			helpers.assert_eq(state.cleanup_inside_preparation, nil)
			helpers.assert_true(state.service_stops > 0, "The real terminal block must release and drain preparation after unwind")
			helpers.assert_eq(state.services, false)
			helpers.assert_eq(state.grabbed, false)
			helpers.assert_eq(state.signals_active, false)
			helpers.assert_eq(state.closes, 1)
			helpers.assert_eq(state.application_loops, 0)
		end)
	end
	for _, boundary in ipairs({ "output.open", "watchers" }) do
		helpers.it("(startup-late-grab) TERM during " .. boundary .. " retires only after its native return", function()
			local callback_ran = false
			local state = MainStartup.run({ on_boundary = function(current, observed)
				if current ~= boundary then return end
				callback_ran = true
				observed.callbacks.on_term(15)
				helpers.assert_eq(observed.service_stops, 0)
				helpers.assert_true(observed.signals_active)
			end })
			helpers.assert_true(callback_ran)
			helpers.assert_true(state.ok, tostring(state.error))
			helpers.assert_true(state.owner_after_request)
			helpers.assert_eq(state.grabbed, false)
			helpers.assert_eq(state.services, false)
			helpers.assert_eq(state.closes, 1)
			helpers.assert_eq(state.application_loops, 0)
			helpers.assert_eq(state.coordinator.is_pending(), false)
		end)
	end
	for _, fault in ipairs({ "terminal_logger_throws", "reporter_throws", "loop_throws" }) do
		helpers.it("(startup-late-grab) drains owned startup when " .. fault, function()
			local options = { [fault] = true }
			if fault ~= "loop_throws" then options.throw_at = "watchers" end
			local state = MainStartup.run(options)
			helpers.assert_eq(state.ok, false)
			helpers.assert_true(state.service_stops > 0)
			helpers.assert_eq(state.cleanup_inside_preparation, nil)
			helpers.assert_eq(state.grabbed, false)
			helpers.assert_eq(state.services, false)
			helpers.assert_eq(state.signals_active, false)
			helpers.assert_eq(state.closes, 1)
			helpers.assert_eq(state.pumps, 0)
			helpers.assert_eq(state.coordinator.is_pending(), false)
		end)
	end
	for _, boundary in ipairs({ "input.stage", "hook.log" }) do
		helpers.it("(startup-late-grab) TERM at " .. boundary .. " cannot acquire or publish capture afterward", function()
			local callback_ran = false
			local state = MainStartup.run({ on_boundary = function(current, observed)
				if current ~= boundary then return end
				callback_ran = true
				observed.callbacks.on_term(15)
				helpers.assert_eq(observed.service_stops, 0)
			end })
			helpers.assert_true(callback_ran)
			helpers.assert_true(state.ok, tostring(state.error))
			for _, event in ipairs(state.events) do
				helpers.assert_true(event ~= "layout.publish", "A cancelled start cannot publish its inverse")
				if boundary == "input.stage" then helpers.assert_true(event ~= "hook.start") end
			end
			helpers.assert_eq(state.grabbed, false)
			helpers.assert_eq(state.services, false)
			helpers.assert_eq(state.closes, 1)
			helpers.assert_eq(state.application_loops, 0)
			helpers.assert_eq(state.pumps, 0)
			helpers.assert_eq(state.coordinator.is_pending(), false)
		end)
	end
	helpers.it("(startup-late-grab) retains terminal watchers until prepared services physically acknowledge", function()
		local state = MainStartup.run({ async_service = true, on_boundary = function(boundary, observed)
			if boundary == "onboarding" then observed.callbacks.on_term(15) end
		end })
		helpers.assert_true(state.ok, tostring(state.error))
		helpers.assert_eq(state.service_stops, 2)
		helpers.assert_true(position(state.events, "onboarding.returned") < position(state.events, "services.stop"))
		helpers.assert_true(position(state.events, "services.stop") < position(state.events, "signals.stop"))
		helpers.assert_eq(state.signals_active, false)
		helpers.assert_eq(state.services, false)
		helpers.assert_eq(state.closes, 1)
		helpers.assert_eq(state.application_loops, 0)
		helpers.assert_eq(state.pumps, 0)
		helpers.assert_eq(state.coordinator.is_pending(), false)
	end)
	helpers.it("(startup-late-grab) TERM during the first layout refresh cannot enter tray preparation", function()
		local state = MainStartup.run({ on_boundary = function(boundary, observed)
			if boundary == "layout.refresh" and observed.layout_refreshes == 1 then observed.callbacks.on_term(15) end
		end })
		helpers.assert_true(state.ok, tostring(state.error))
		helpers.assert_eq(state.ui_entered, false)
		helpers.assert_eq(state.grabbed, false)
		helpers.assert_eq(state.closes, 1)
		helpers.assert_eq(state.application_loops, 0)
		helpers.assert_eq(state.coordinator.is_pending(), false)
	end)
	helpers.it("(startup-late-grab) replaced loop during publication cannot borrow native cleanup acknowledgment", function()
		local state = MainStartup.run({ async_service = true, on_boundary = function(boundary, observed, env)
			if boundary ~= "layout.publish" then return end
			env.event_loop.run = function() observed.foreign_loops = observed.foreign_loops + 1 end
		end })
		helpers.assert_eq(state.ok, false)
		helpers.assert_eq(state.foreign_loops, 0)
		helpers.assert_eq(state.service_stops, 2)
		helpers.assert_eq(state.grabbed, false)
		helpers.assert_eq(state.services, false)
		helpers.assert_eq(state.closes, 1)
		helpers.assert_eq(state.application_loops, 0)
		helpers.assert_eq(state.coordinator.is_pending(), false)
	end)
end)

helpers.describe("shutdown coordinator: startup preparation token", function()
	local function fixture()
		local state = { stops = 0, ordinary = 0, final = 0, loops = 0, held = true }
		local owner = { name = "preparing native service", wait_for_ack = true }
		local ordinary = { name = "prepared ordinary service", stop = function() state.ordinary = state.ordinary + 1 end }
		owner.stop = function() state.stops = state.stops + 1; return not state.held end
		local coordinator = ShutdownCoordinator.new({ pre_wait = { owner, ordinary },
			final_wait = { { name = "terminal watchers", stop = function() state.final = state.final + 1; return true end } },
			keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() state.loops = state.loops + 1 end } })
		return coordinator, state, owner, ordinary
	end
	helpers.it("(startup-late-grab) marks and snapshots requests while all cleanup stays parked", function()
		local coordinator, state, owner, ordinary = fixture()
		local token = coordinator.begin_preparation()
		helpers.assert_true(type(token) == "table" or type(token) == "userdata")
		helpers.assert_true(coordinator.request("first TERM"))
		helpers.assert_true(coordinator.is_requested())
		helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(coordinator.request("second TERM"), false)
		owner.stop = function() error("A replacement callback cannot own the first request") end
		ordinary.stop = function() error("Ordinary replacement cannot own the first request") end
		helpers.assert_eq(coordinator.poll(), false)
		helpers.assert_eq(state.stops, 0)
		helpers.assert_eq(state.final, 0)
		helpers.assert_eq(state.loops, 0)
		state.held = false
		helpers.assert_true(coordinator.finish_preparation(token))
		helpers.assert_eq(state.stops, 1)
		helpers.assert_eq(state.ordinary, 1)
		helpers.assert_eq(state.final, 1)
		helpers.assert_eq(state.loops, 1)
		helpers.assert_eq(coordinator.is_pending(), false)
	end)
	helpers.it("(startup-late-grab) wrong and duplicate tokens cannot release or reacquire preparation", function()
		local coordinator, state = fixture()
		local token = coordinator.begin_preparation()
		helpers.assert_eq(coordinator.begin_preparation(), nil)
		coordinator.request("quit")
		helpers.assert_eq(coordinator.finish_preparation({}), false)
		local spoof = setmetatable({}, { __eq = function() return true end })
		setmetatable(token, getmetatable(spoof))
		helpers.assert_eq(coordinator.finish_preparation(spoof), false, "Opaque ownership cannot be forged with __eq")
		helpers.assert_eq(coordinator.finish_preparation(nil), false)
		helpers.assert_eq(state.stops, 0)
		state.held = false
		helpers.assert_true(coordinator.finish_preparation(token))
		helpers.assert_eq(coordinator.finish_preparation(token), false)
		helpers.assert_eq(coordinator.begin_preparation(), nil)
		helpers.assert_eq(state.stops, 1)
	end)
	helpers.it("(startup-late-grab) successful preparation release never requests shutdown", function()
		local coordinator, state = fixture()
		local token = coordinator.begin_preparation()
		helpers.assert_true(coordinator.finish_preparation(token))
		helpers.assert_eq(coordinator.is_requested(), false)
		helpers.assert_eq(coordinator.is_pending(), false)
		helpers.assert_eq(state.stops, 0)
		helpers.assert_eq(state.final, 0)
		helpers.assert_eq(state.loops, 0)
	end)
	helpers.it("(startup-late-grab) newly committed native debt survives finish until exact acknowledgment", function()
		local coordinator, state = fixture()
		local token = coordinator.begin_preparation()
		state.held = false
		coordinator.request("TERM inside constructor")
		helpers.assert_eq(state.stops, 0, "A resource absent at the request cannot be acknowledged before constructor return")
		-- The constructor commits a resource only after the callback returns.
		state.held = true
		helpers.assert_true(coordinator.finish_preparation(token))
		helpers.assert_eq(state.stops, 1)
		helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(state.final, 0)
		helpers.assert_eq(coordinator.poll(), false)
		state.held = false
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(state.final, 1)
		helpers.assert_eq(state.loops, 1)
	end)
	helpers.it("(startup-late-grab) snapshots ordinary cleanup and defers observer subscription until constructor return", function()
		local coordinator, state, owner = fixture()
		local subscriptions, notify = 0, nil
		owner.when_settled = function(callback) subscriptions = subscriptions + 1; notify = callback end
		local token = coordinator.begin_preparation()
		coordinator.request("TERM")
		owner.when_settled = function() error("Observer replacement must not acquire the old request") end
		helpers.assert_eq(subscriptions, 0)
		coordinator.poll()
		helpers.assert_eq(subscriptions, 0)
		helpers.assert_true(coordinator.finish_preparation(token))
		helpers.assert_eq(subscriptions, 1)
		helpers.assert_true(type(notify) == "function")
		helpers.assert_eq(coordinator.finish_preparation(token), false)
		state.held = false
		notify()
		helpers.assert_eq(state.final, 1)
		helpers.assert_eq(state.loops, 1)
		notify()
		helpers.assert_eq(state.loops, 1)
	end)
	helpers.it("(startup-late-grab) preserves the first parked diagnostic and emergency reason", function()
		local reason, emergency
		local factory = helpers.load_module_with_dependency("infra.shutdown_coordinator", "logger.shim", {
			start = function(_, _, value) reason = value end, done = function() end,
		})
		local coordinator = factory.new({ pre_wait = {}, keyboard_hook = {
			isRunning = function() return true end, stop = function() error("Emergency cleanup is owned by the first request") end,
			emergency_stop = function(value) emergency = value end,
		}, event_loop = { stop = function() end } })
		local token = coordinator.begin_preparation()
		coordinator.request("first TERM", "first native failure")
		helpers.assert_eq(coordinator.request("later TERM", "later failure"), false)
		helpers.assert_eq(reason, nil)
		helpers.assert_eq(emergency, nil)
		helpers.assert_true(coordinator.finish_preparation(token))
		helpers.assert_eq(reason, "first TERM")
		helpers.assert_eq(emergency, "first native failure")
	end)
end)


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
		local driver_root = source_path:match("^(.*)[/\\]tests[/\\]unit[/\\]") or "."
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

	helpers.it("(shutdown-native-registry-ack) actual daemon registry admits no loop stop before owned runtime cleanup", function()
		local path = helpers.driver_root() .. "/ergopti_hotstrings.lua"
		local file = assert(io.open(path, "r")); local text = file:read("*a"); file:close()
		local registry = text:match("local shutdown = ShutdownCoordinator%.new%(%{(.-)\n%}%)[\r\n]")
		helpers.assert_true(type(registry) == "string" and registry ~= "", "actual daemon registry must exist")
		local state = { closed = false, context_closed = false, watch_closed = false, metrics_closed = false, stops = 0, loops = 0, cancelled = 0 }
		local native_closed = { discovery = false, programs = false, watchers = false, layouts = false }
		local native_calls = { discovery = 0, programs = 0, watchers = 0, layouts = 0 }
		local function native_stop(name)
			return function()
				native_calls[name] = native_calls[name] + 1
				return native_closed[name]
			end
		end
		local env = setmetatable({ ShutdownCoordinator = ShutdownCoordinator,
			keystats = { stop = function() return state.metrics_closed end },
			privacy_owners = {
				context = { stop = function() return state.context_closed end },
				watch = { stop = function() return state.watch_closed end },
			},
			dyn_hotstrings = { stop_user_code = native_stop("programs") },
			updater = false, file_watchers = { stop = native_stop("watchers") },
			process_lifecycle = false, secure_field_detector = false, metrics = false,
			webview_manager = false, tooltip_preview = false, gestures = false, input_capture_gate = false,
			prediction_engine = {
				shutdown_runtime = function() state.stops = state.stops + 1; return state.closed end,
				cancel = function() state.cancelled = state.cancelled + 1 end,
			},
			package = { loaded = { ["modules.llm.local_servers"] = {
				shutdown = native_stop("discovery"),
			}, ["modules.keymap.layout_registry"] = { shutdown = native_stop("layouts") } } }, require = function() return { cleanup = function() end, flush = function() end } end,
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
		helpers.assert_eq(coordinator.poll(), false, "context and watcher cleanup remain independent debts")
		state.context_closed = true
		helpers.assert_eq(coordinator.poll(), false, "one privacy ACK cannot retire both owners")
		helpers.assert_eq(state.loops, 0)
		state.watch_closed = true
		helpers.assert_eq(coordinator.poll(), false, "SQLite cleanup is independent from both privacy ACKs")
		helpers.assert_eq(state.loops, 0)
		state.metrics_closed = true
		helpers.assert_eq(coordinator.poll(), false, "other native cleanup cannot acknowledge live discovery, programs or watchers")
		helpers.assert_eq(state.loops, 0)
		for name, calls in pairs(native_calls) do
			helpers.assert_true(calls > 1, name .. " must retain its own retryable native cleanup claim")
		end
		native_closed.discovery = true
		helpers.assert_eq(coordinator.poll(), false, "discovery ACK must not release live programs or watchers")
		native_closed.programs = true
		helpers.assert_eq(coordinator.poll(), false, "program ACK must not release live watchers")
		native_closed.watchers = true
		helpers.assert_eq(coordinator.poll(), false, "layout helpers require their own physical retirement ACK")
		native_closed.layouts = true
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



helpers.describe("shutdown coordinator: retained user program", function()
	helpers.it("stops input but retains the event loop until physical settlement", function()
		local terminal, notify, loop_calls, hook_calls = false, nil, 0, 0
		local coordinator = ShutdownCoordinator.new({
			pre_wait = { {
				name = "user programs",
				stop = function() return terminal end,
				when_settled = function(callback) notify = callback; return true end,
			} },
			keyboard_hook = {
				isRunning = function() return true end,
				stop = function() hook_calls = hook_calls + 1 end,
				emergency_stop = function() error("unexpected emergency stop") end,
			},
			event_loop = { stop = function() loop_calls = loop_calls + 1 end },
		})
		helpers.assert_eq(coordinator.request("owned fixture quit"), true)
		helpers.assert_eq(hook_calls, 1)
		helpers.assert_eq(loop_calls, 0)
		notify()
		helpers.assert_eq(loop_calls, 0, "early observer must not release a live child")
		terminal = true
		notify()
		helpers.assert_eq(loop_calls, 1)
		notify()
		helpers.assert_eq(loop_calls, 1, "the physical release is acknowledged once")
	end)
end)

helpers.describe("shutdown coordinator: combined native barriers", function()
	helpers.it("keeps observer and polling debts independent until both acknowledge", function()
		local program_closed, runtime_closed, notify = false, false, nil
		local loops, hooks, ordinary = 0, 0, 0
		local coordinator = ShutdownCoordinator.new({
			pre_wait = {
				{ name = "program", stop = function() return program_closed end,
					when_settled = function(callback) notify = callback; return true end },
				{ name = "runtime", wait_for_ack = true, stop = function() return runtime_closed end },
				{ name = "ordinary", stop = function() ordinary = ordinary + 1 end },
			},
			keyboard_hook = { isRunning = function() return hooks == 0 end,
				stop = function() hooks = hooks + 1 end, emergency_stop = function() error("unexpected emergency stop") end },
			event_loop = { stop = function() loops = loops + 1 end },
		})
		helpers.assert_true(coordinator.request("combined quit"))
		helpers.assert_eq(hooks, 1)
		helpers.assert_eq(loops, 0)
		program_closed = true
		notify()
		helpers.assert_true(coordinator.is_pending(), "runtime debt must survive program notification")
		helpers.assert_eq(loops, 0)
		helpers.assert_eq(coordinator.poll(), false)
		runtime_closed = true
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(loops, 1)
		helpers.assert_eq(ordinary, 1, "ordinary cleanup stays one-shot")
		notify()
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(loops, 1)
	end)

	helpers.it("pins observer callbacks before earlier cleanup and rejects recursive acknowledgment", function()
		local closed, notify, coordinator = false, nil, nil
		local loops, original_calls, replacement_calls = 0, 0, 0
		local program = { name = "program" }
		program.stop = function()
			original_calls = original_calls + 1
			if notify then notify() end
			if coordinator then helpers.assert_eq(coordinator.poll(), false, "a live observer cannot retire itself recursively") end
			return closed
		end
		program.when_settled = function(callback) notify = callback; callback(); return true end
		coordinator = ShutdownCoordinator.new({
			pre_wait = {
				{ name = "earlier", stop = function()
					program.stop = function() replacement_calls = replacement_calls + 1; return true end
					program.when_settled = function() error("foreign observer registration") end
				end },
				program,
			},
			keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() loops = loops + 1 end },
		})
		helpers.assert_true(coordinator.request("combined reentry"))
		helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(loops, 0)
		helpers.assert_eq(replacement_calls, 0)
		closed = true
		notify()
		helpers.assert_eq(loops, 1)
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(replacement_calls, 0)
		helpers.assert_eq(original_calls, 3, "initial, early observer and final physical readback only")
	end)
end)

helpers.describe("shutdown coordinator: signal output ownership", function()
	local function fixture(ready)
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = file:read("*a"); file:close()
		local install = assert(source:match("(local function install_signal_handlers%(%).-)%s*%-%- ========================================="),
			"actual signal installer must exist")
		local finish = assert(source:match('(shutdown.request%("event loop returned"%).-)%s*if file_watchers then'),
			"actual final output teardown must exist")
		local state = { ready = ready, handlers = {}, closes = 0, loops = 0, releases = 0, running = true }
		local coordinator = ShutdownCoordinator.new({
			pre_wait = { { name = "native owner", wait_for_ack = true, stop = function()
				if not state.ready then return false end
				if state.releases == 0 then
					helpers.assert_eq(state.closes, 0, "native retirement must retain its output channel")
					state.releases = state.releases + 1
				end
				return true
			end } },
			keyboard_hook = {
				isRunning = function() return state.running end,
				stop = function() state.running = false end,
				emergency_stop = function() error("TERM must use ordinary retirement") end,
			},
			event_loop = { stop = function() state.loops = state.loops + 1 end },
		})
		local env = setmetatable({ shutdown = coordinator, privacy_owners = {}, require = function(name)
			helpers.assert_eq(name, "infra.signal_handlers")
			return { stop = function() return true end, start = function(opts)
				state.handlers[2] = function() opts.on_term(2) end
				state.handlers[15] = function() opts.on_term(15) end
				return true
			end }
		end, Logger = { info = function() end, debug = function() end, error = function() end },
			injector = { close_fast_channel = function() state.closes = state.closes + 1; return true end },
			tooltip_preview = false, llm_overlay = false, perform_reload = function() end,
		}, { __index = _G })
		local function compile(body)
			local chunk, why
			if setfenv then chunk, why = loadstring(body, "actual signal teardown"); if chunk then setfenv(chunk, env) end
			else chunk, why = load(body, "actual signal teardown", "t", env) end
			return assert(chunk, why)
		end
		compile(install .. "\nreturn install_signal_handlers()")()
		return state, coordinator, compile(finish)
	end

	helpers.it("(signal-output-ack) retains output across TERM until native retirement and final teardown", function()
		local state, coordinator, finish = fixture(false)
		state.handlers[15](15)
		helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(state.closes, 0, "TERM must not close output while native owners remain")
		helpers.assert_eq(state.loops, 0)
		helpers.assert_eq(coordinator.poll(), false)
		state.ready = true
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(state.releases, 1)
		helpers.assert_eq(state.loops, 1)
		finish()
		helpers.assert_eq(state.closes, 1)
	end)

	helpers.it("(signal-output-ack) repeated TERM and INT cannot close or replay pending output retirement", function()
		local state, coordinator, finish = fixture(false)
		state.handlers[15](15); state.handlers[15](15); state.handlers[2](2)
		helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(state.closes, 0)
		local ok = pcall(finish)
		helpers.assert_eq(ok, false, "an early loop return must retain the barrier")
		helpers.assert_eq(state.closes, 0)
		state.ready = true
		helpers.assert_true(coordinator.poll())
		finish()
		state.handlers[15](15)
		helpers.assert_eq(state.releases, 1)
		helpers.assert_eq(state.closes, 1, "a late signal must not repeat final output teardown")
		helpers.assert_eq(state.loops, 1)
	end)

	helpers.it("(signal-output-ack) an already retired transaction uses the same final output teardown", function()
		local state, coordinator, finish = fixture(true)
		state.handlers[15](15); state.handlers[15](15)
		helpers.assert_eq(coordinator.is_pending(), false)
		helpers.assert_eq(state.releases, 1)
		helpers.assert_eq(state.loops, 1)
		helpers.assert_eq(state.closes, 0)
		finish()
		state.handlers[2](2)
		helpers.assert_eq(state.closes, 1)
	end)
end)

helpers.describe("shutdown coordinator: final native output acknowledgement", function()
	local function with_output(mode, check)
		local names = { "adapters.uinput_writer", "adapters.modifier_broker", "modules.hotstrings.injector" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		local ok, why = pcall(function()
			local writer = require("adapters.uinput_writer")
			local broker = require("adapters.modifier_broker")
			local injector = require("modules.hotstrings.injector")
			local calls = { destroy = 0, close = 0, success = 0, writes = 0 }
			writer._set_backend({
				open = function() return 47 end,
				ioctl = function(_, request)
					if request == writer.UI_DEV_DESTROY then
						calls.destroy = calls.destroy + 1
						if mode == "destroy throws" then error("controlled destroy failure") end
						return mode ~= "destroy refuses"
					end
					return true
				end,
				write = function() calls.writes = calls.writes + 1; return true end,
				close = function() calls.close = calls.close + 1; return mode ~= "close refuses" end,
			})
			-- The availability check reads this existing node; all native operations
			-- remain explicit controlled ports on the real Writer and Injector.
			writer._set_path_for_test("/dev/null")
			if mode ~= "absent" then helpers.assert_true(injector.open_fast_channel()) end
			local channel = injector.output_broker()
			if mode ~= "absent" then
				local capability = writer.capture_output()
				helpers.assert_true(writer.emit_owned(capability, 29, 1), "a held Ctrl reaches the acknowledged channel")
			end
			local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
			local source = file:read("*a"); file:close()
			local finish = assert(source:match('(shutdown.request%("event loop returned"%).-)\nend\n\n%-%- The daemon runs'),
				"actual Main final teardown must exist")
			local env = setmetatable({
				shutdown = { request = function() end, is_pending = function() return false end },
				injector = injector, tooltip_preview = false, llm_overlay = false,
				file_watchers = false, process_lifecycle = false, tray_menu = false,
				keystats = { get_session_stats = function() return { keystrokes = 0, words = 0, duration_ms = 0 } end },
				Logger = { flush_repeats = function() end, info = function() calls.success = calls.success + 1 end },
			}, { __index = _G })
			local chunk, err
			if setfenv then chunk, err = loadstring(finish, "actual final output teardown"); if chunk then setfenv(chunk, env) end
			else chunk, err = load(finish, "actual final output teardown", "t", env) end
			check(assert(chunk, err), injector, writer, broker, channel, calls)
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(why, 0) end
	end

	for _, mode in ipairs({ "destroy refuses", "close refuses", "destroy throws" }) do
		helpers.it("refuses clean exit when native output " .. mode, function()
			with_output(mode, function(finish, injector, writer, broker, channel, calls)
				local ok = pcall(finish)
				helpers.assert_eq(ok, false, "native retirement failure must reach Main's failure path")
				helpers.assert_eq(calls.success, 0, "unacknowledged retirement cannot announce a clean exit")
				helpers.assert_true(writer.has_output_debt())
				helpers.assert_eq(injector.output_broker(), channel, "retain the exact output owner")
				helpers.assert_eq(broker.for_channel(writer), channel)
				helpers.assert_eq(injector.close_fast_channel(), false)
				helpers.assert_eq(calls.destroy, 1, "unknown retirement must not retry a possibly recycled descriptor")
				helpers.assert_eq(calls.close, 1)
				helpers.assert_eq(calls.writes, 2, "retirement cannot replay the held key")
			end)
		end)
	end

	helpers.it("completes final teardown only after destroy and close both acknowledge", function()
		with_output("acknowledged", function(finish, injector, writer, broker, _, calls)
			finish()
			helpers.assert_eq(calls.success, 2)
			helpers.assert_eq(calls.destroy, 1)
			helpers.assert_eq(calls.close, 1)
			helpers.assert_eq(writer.is_open(), false)
			helpers.assert_eq(writer.has_output_debt(), false)
			helpers.assert_eq(broker.for_channel(writer), nil)
			helpers.assert_eq(injector.close_fast_channel(), true, "already retired output is acknowledged without another native attempt")
			helpers.assert_eq(calls.close, 1)
		end)
	end)

	helpers.it("acknowledges no-grab teardown when no output channel was acquired", function()
		with_output("absent", function(finish, injector, writer, _, _, calls)
			helpers.assert_eq(injector.close_fast_channel(), true)
			finish()
			helpers.assert_eq(calls.success, 2)
			helpers.assert_eq(calls.destroy, 0)
			helpers.assert_eq(calls.close, 0)
			helpers.assert_eq(writer.has_output_debt(), false)
		end)
	end)
end)

helpers.describe("shutdown coordinator: final native phase", function()
	local function fixture()
		local state = { external = false, final = false, stops = 0, loops = 0, observer = nil }
		local final = { name = "signal handlers", stop = function()
			state.stops = state.stops + 1; return state.final
		end, when_settled = function(callback) state.observer = callback end }
		local coordinator = ShutdownCoordinator.new({
			pre_wait = { { name = "external", wait_for_ack = true, stop = function()
				if state.on_external then state.on_external() end
				return state.external
			end } },
			final_wait = { final },
			keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() state.loops = state.loops + 1 end },
		})
		return state, final, coordinator
	end

	helpers.it("(signal-final-phase) retains signal handlers while external cleanup is pending", function()
		local state, _, coordinator = fixture()
		coordinator.request("TERM"); coordinator.poll(); coordinator.request("TERM again")
		helpers.assert_eq(state.stops, 0)
		state.external = true
		helpers.assert_eq(coordinator.poll(), false, "final native retirement has its own physical ACK")
		helpers.assert_eq(state.stops, 1)
		helpers.assert_eq(state.loops, 0)
		helpers.assert_true(coordinator.is_pending())
		state.final = true
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(state.loops, 1)
	end)

	helpers.it("(signal-final-phase) pins final cleanup before an earlier owner replaces it", function()
		local state, final, coordinator = fixture()
		state.on_external = function()
			final.stop = function() return true end
			final.when_settled = function(callback) callback() end
		end
		coordinator.request("TERM")
		state.external = true
		helpers.assert_eq(coordinator.poll(), false)
		helpers.assert_true(type(state.observer) == "function")
		state.observer()
		helpers.assert_true(coordinator.is_pending(), "observer notification cannot replace a physical ACK")
		state.final = true
		state.observer(); state.observer()
		helpers.assert_eq(coordinator.is_pending(), false)
		helpers.assert_eq(state.loops, 1)
	end)

	helpers.it("(signal-final-phase) final callbacks cannot recursively skip the retirement phase", function()
		local coordinator, calls, loops, reentered = nil, 0, 0, nil
		coordinator = ShutdownCoordinator.new({ pre_wait = {},
			final_wait = { { name = "signals", stop = function()
				calls = calls + 1; reentered = coordinator.poll(); return calls > 1
			end } },
			keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() loops = loops + 1 end },
		})
		coordinator.request("TERM")
		helpers.assert_eq(reentered, false)
		helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(loops, 0)
		helpers.assert_true(coordinator.poll())
		helpers.assert_eq(loops, 1)
	end)
end)


helpers.describe("shutdown coordinator: final phase refusals", function()
	helpers.it("(signal-final-phase) a final cleanup exception remains retryable native debt", function()
		local retired, loops = false, 0
		local coordinator = ShutdownCoordinator.new({ pre_wait = {}, final_wait = { { name = "signals", stop = function()
			if not retired then error("unknown native signal retirement") end
			return true
		end } }, keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() loops = loops + 1 end } })
		helpers.assert_true(coordinator.request("TERM")); helpers.assert_true(coordinator.is_pending())
		helpers.assert_eq(coordinator.poll(), false); helpers.assert_eq(loops, 0)
		retired = true; helpers.assert_true(coordinator.poll()); helpers.assert_eq(loops, 1)
	end)

	for _, registry in ipairs({ false, "signals", { { name = "signals" } } }) do
		helpers.it("(signal-final-phase) rejects invalid final registry " .. type(registry), function()
			local accepted = pcall(ShutdownCoordinator.new, { pre_wait = {}, final_wait = registry,
				keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
				event_loop = { stop = function() end } })
			helpers.assert_eq(accepted, false)
		end)
	end
end)

helpers.describe("native signal owner", function()
	local function fixture(options)
		options = options or {}
		local state = { handles = {}, loads = 0, starts = 0, stops = 0, closes = 0, callbacks = {}, delivered = {} }
		local uv = {}
		function uv.new_signal()
			local index = #state.handles + 1
			if options.allocation == index then
				if options.receipt == "throw" then error("simulated constructor throw") end
				if options.receipt == "false" then return false end
				return nil
			end
			local handle = { closing = false }
			state.handles[index] = handle
			return handle
		end
		function uv.signal_start(handle, name, callback)
			state.starts = state.starts + 1; handle.callback = callback; handle.signal = name
			if options.start == state.starts then
				if options.receipt == "throw" then error("simulated start throw after receiving exact handle") end
				if options.receipt == "false" then return false end
				return nil
			end
			return 0
		end
		function uv.signal_stop(handle)
			helpers.assert_eq(handle.closing, false, "signal_stop on closing native watchers asserts in libuv")
			state.stops = state.stops + 1
			if options.stop_failure then
				if options.receipt == "throw" then error("simulated signal_stop throw") end
				if options.receipt == "false" then return false end
				return nil
			end
			return 0
		end
		function uv.is_closing(handle)
			if options.probe_failure then error("simulated ownership probe throw") end
			return handle.closing
		end
		function uv.close(handle, callback)
			state.closes = state.closes + 1
			if options.close_before then options.close_before = false; error("simulated close refusal") end
			handle.closing = true; state.callbacks[#state.callbacks + 1] = callback
			if options.close_after then options.close_after = false; error("simulated close throw after native acceptance") end
		end
		local env = setmetatable({ require = function(name)
			state.loads = state.loads + 1; helpers.assert_eq(name, "luv")
			if options.missing then error("explicit missing native dependency") end
			return uv
		end }, { __index = _G })
		local path = helpers.driver_root() .. "/infra/signal_handlers.lua"
		local chunk = assert(loadfile(path))
		if setfenv then setfenv(chunk, env) else chunk = assert(loadfile(path, "t", env)) end
		local owner = chunk()
		local function start()
			return owner.start({ on_term = function(number) state.delivered[#state.delivered + 1] = number end,
				on_hup = function(number) state.delivered[#state.delivered + 1] = number end })
		end
		local function acknowledge()
			local callbacks = state.callbacks; state.callbacks = {}
			for _, callback in ipairs(callbacks) do callback(); callback() end
		end
		return owner, state, uv, start, acknowledge
	end

	helpers.it("(signal-native-owner) loads without native libraries and refuses missing luv before acquisition", function()
		local owner, state, _, start = fixture({ missing = true })
		helpers.assert_eq(state.loads, 0)
		helpers.assert_true(owner.is_settled())
		local admitted, why = start()
		helpers.assert_eq(admitted, false); helpers.assert_contains(why, "luv")
		helpers.assert_eq(#state.handles, 0); helpers.assert_true(owner.stop())
	end)

	helpers.it("(signal-native-owner) admits zero native receipts and retires once only on exact close callbacks", function()
		local owner, state, uv, start, acknowledge = fixture()
		helpers.assert_true(start()); helpers.assert_eq(#state.handles, 3)
		for _, handle in ipairs(state.handles) do handle.callback() end
		helpers.assert_eq(state.delivered, { 2, 15, 1 })
		for _, name in ipairs({ "signal_stop", "close", "is_closing" }) do uv[name] = function() error("foreign export replacement") end end
		helpers.assert_eq(start(), false, "duplicate start cannot replace the admitted generation")
		helpers.assert_eq(owner.stop(), false); helpers.assert_eq(owner.stop(), false)
		helpers.assert_eq(state.stops, 3); helpers.assert_eq(state.closes, 3)
		for _, handle in ipairs(state.handles) do handle.callback() end
		helpers.assert_eq(state.delivered, { 2, 15, 1 }, "late callbacks cannot dispatch after retirement begins")
		acknowledge(); helpers.assert_true(owner.is_settled()); helpers.assert_true(owner.stop())
	end)

	for _, receipt in ipairs({ "nil", "false", "throw" }) do
		for index = 1, 3 do
			helpers.it("(signal-native-owner) constructor " .. index .. " " .. receipt .. " retains partial ownership", function()
				local owner, state, _, start, acknowledge = fixture({ allocation = index, receipt = receipt })
				local admitted, why = start()
				helpers.assert_eq(admitted, false); helpers.assert_contains(why, "allocation")
				helpers.assert_eq(#state.handles, index - 1)
				if index > 1 then helpers.assert_eq(owner.is_settled(), false) end
				acknowledge()
				helpers.assert_eq(owner.is_settled(), receipt ~= "throw", "an unobservable thrown acquisition cannot prove retirement")
				if receipt == "throw" then helpers.assert_eq(start(), false) end
			end)
			helpers.it("(signal-native-owner) start " .. index .. " " .. receipt .. " waits for every known handle", function()
				local owner, state, _, start, acknowledge = fixture({ start = index, receipt = receipt })
				local admitted, why = start()
				helpers.assert_eq(admitted, false); helpers.assert_contains(why, "activation")
				helpers.assert_eq(#state.handles, index); helpers.assert_eq(owner.is_settled(), false)
				for _, handle in ipairs(state.handles) do handle.callback() end
				helpers.assert_eq(#state.delivered, 0)
				acknowledge(); helpers.assert_true(owner.is_settled())
			end)
		end
		helpers.it("(signal-native-owner) signal_stop " .. receipt .. " cannot acknowledge a missing close callback", function()
			local owner, state, _, start, acknowledge = fixture({ stop_failure = true, receipt = receipt })
			helpers.assert_true(start()); helpers.assert_eq(owner.stop(), false)
			helpers.assert_eq(state.stops, 3); helpers.assert_eq(owner.is_settled(), false)
			acknowledge(); helpers.assert_true(owner.stop())
		end)
	end

	for _, fault in ipairs({ "close_before", "close_after", "probe_failure" }) do
		helpers.it("(signal-native-owner) retains and retries " .. fault .. " without guessing native settlement", function()
			local options = { [fault] = true }
			local owner, _, _, start, acknowledge = fixture(options)
			helpers.assert_true(start()); helpers.assert_eq(owner.stop(), false)
			options.probe_failure = false
			acknowledge()
			if fault ~= "close_after" then helpers.assert_eq(owner.is_settled(), false); helpers.assert_eq(owner.stop(), false) end
			acknowledge(); helpers.assert_true(owner.is_settled())
		end)
	end

	for _, name in ipairs({ "new_signal", "signal_start", "signal_stop", "is_closing", "close" }) do
		helpers.it("(signal-native-owner) refuses missing " .. name .. " before native acquisition", function()
			local owner, state, uv, start = fixture()
			uv[name] = nil
			local admitted, why = start()
			helpers.assert_eq(admitted, false); helpers.assert_contains(why, name)
			helpers.assert_eq(#state.handles, 0); helpers.assert_true(owner.is_settled())
		end)
	end

	helpers.it("(signal-native-owner) rejects incomplete callbacks before probing native support", function()
		local owner, state = fixture()
		helpers.assert_eq(owner.start({ on_term = function() end }), false)
		helpers.assert_eq(state.loads, 0); helpers.assert_true(owner.is_settled())
	end)

	for _, refused in ipairs({ true, false }) do
		helpers.it("(signal-native-admission) actual Main " .. (refused and "refusal" or "success") .. " precedes input acquisition", function()
			local owner, native, _, _, acknowledge = fixture(refused and { start = 2, receipt = "false" } or {})
			local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
			local source = file:read("*a"); file:close()
			local installer = assert(source:match("(local function install_signal_handlers%(%).-)%s*%-%- ========================================="))
			local first = assert(source:find("-- Admit graceful terminal signals", 1, true))
			local marker = "local fast_channel_ready = injector.open_fast_channel()"
			local last = assert(source:find(marker, 1, true))
			helpers.assert_true(first < last, "native signal admission must precede output acquisition")
			local state = { opens = 0, loops = 0, runs = 0 }
			local private = {}
			local env = setmetatable({ privacy_owners = private, require = function(name)
				helpers.assert_eq(name, "infra.signal_handlers"); return owner
			end, Logger = { info = function() end, error = function() end },
				BootProfiler = { stage = function() end },
				injector = { open_fast_channel = function() state.opens = state.opens + 1; return true end },
			}, { __index = _G })
			local function compile(body)
				if setfenv then return setfenv(assert(loadstring(body, "actual Main signal admission")), env) end
				return assert(load(body, "actual Main signal admission", "t", env))
			end
			env.shutdown = ShutdownCoordinator.new({ pre_wait = {},
				final_wait = compile("return " .. assert(source:match("final_wait%s*=%s*(%b{})")))(),
				keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
				event_loop = { stop = function() state.loops = state.loops + 1 end },
			})
			env.event_loop = { run = function(opts)
				state.runs = state.runs + 1; helpers.assert_true(env.shutdown.is_pending())
				acknowledge(); opts.onIdle()
			end }
			local accepted, why = pcall(compile(installer .. "\n" .. source:sub(first, last + #marker - 1)))
			if refused then
				helpers.assert_eq(accepted, false); helpers.assert_contains(tostring(why), "refusing input capture")
				helpers.assert_eq(state.opens, 0); helpers.assert_eq(state.runs, 1)
				helpers.assert_eq(#native.handles, 2); helpers.assert_true(owner.is_settled())
			else
				helpers.assert_true(accepted, tostring(why)); helpers.assert_eq(state.opens, 1)
				helpers.assert_eq(state.runs, 0)
				-- This source span ends at output admission, before Main's eventual
				-- finish. Release its exact fixture-owned phase before testing signals.
				if private.startup then
					helpers.assert_true(private.startup.token ~= nil)
					helpers.assert_true(env.shutdown.finish_preparation(private.startup.token))
					private.startup.token = nil
				end
				owner.stop = function() return true end
				env.shutdown.request("TERM")
				helpers.assert_true(env.shutdown.is_pending(), "public replacement cannot acknowledge the retained signal owner")
				acknowledge(); helpers.assert_true(env.shutdown.poll())
			end
			helpers.assert_eq(state.loops, 1)
		end)
	end

	helpers.it("(signal-native-owner) stale close and terminal callbacks cannot retire or dispatch a later installation", function()
		local owner, state, _, start, acknowledge = fixture()
		helpers.assert_true(start()); local stale = state.handles[1].callback
		owner.stop(); local stale_close = state.callbacks[1]; acknowledge()
		helpers.assert_true(start()); stale_close(); stale()
		helpers.assert_eq(owner.is_settled(), false); helpers.assert_eq(#state.delivered, 0)
		owner.stop(); acknowledge(); helpers.assert_true(owner.is_settled())
	end)
end)

helpers.describe("native signal regression child", function()
	helpers.it("(signal-native-child) actual TERM/INT/HUP and partial startup retire without POSIX", function()
		local uv = require("luv")
		local executable = assert(uv.exepath(), "native interpreter identity must be available")
		local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
		local result = os.execute(quote(executable) .. " " .. quote(helpers.driver_root() .. "/tests/fixtures/native_signal_shutdown.lua"))
		helpers.assert_true(result == true or result == 0, "native signal ownership child must pass")
	end)
end)


helpers.describe("actual Main layout helper retirement", function()
	local function fixture(loaded, receipt)
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local text = file:read("*a"); file:close()
		local registry = assert(text:match("local shutdown = ShutdownCoordinator%.new%(%{(.-)\n%}%)[\r\n]"),
			"actual Main shutdown constructor must exist")
		local capture = assert(text:match("(local shutdown_runtime = prediction_engine and prediction_engine%.shutdown_runtime.-)\nlocal shutdown = ShutdownCoordinator"))
		local state = { calls = 0, loops = 0, timers = 0, receipt = receipt }
		local layout = { shutdown = function()
			state.calls = state.calls + 1
			if state.receipt == "throw" then error("controlled layout cleanup failure") end
			return state.receipt
		end }
		local env = setmetatable({ ShutdownCoordinator = ShutdownCoordinator,
			keystats = { stop = function() return true end }, privacy_owners = {},
			dyn_hotstrings = false, updater = false, file_watchers = false, process_lifecycle = false,
			webview_manager = false, tooltip_preview = false, gestures = false, input_capture_gate = false,
			prediction_engine = false,
			package = { loaded = { ["modules.keymap.layout_registry"] = loaded and layout or nil } },
			require = function(name)
				assert(name == "modules.llm.agent_connectors" or name == "modules.llm.agent_learning",
					"cold shutdown must not import " .. tostring(name))
				return { cleanup = function() end, flush = function() end }
			end,
			TimerScheduler = { cancelAll = function() state.timers = state.timers + 1 end },
			keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() state.loops = state.loops + 1 end },
		}, { __index = _G })
		local body = capture .. "\nreturn ShutdownCoordinator.new({" .. registry .. "\n})"
		local chunk, why
		if setfenv then chunk, why = loadstring(body, "actual Main layout shutdown"); if chunk then setfenv(chunk, env) end
		else chunk, why = load(body, "actual Main layout shutdown", "t", env) end
		return assert(chunk, why)(), state, layout, env
	end

	helpers.it("(layout-helper-shutdown) cold quit imports no layout module", function()
		local coordinator, state = fixture(false)
		helpers.assert_true(coordinator.request("cold quit"))
		helpers.assert_eq(coordinator.is_pending(), false)
		helpers.assert_eq(state.calls, 0)
		helpers.assert_eq(state.loops, 1)
	end)

	for _, refusal in ipairs({ "nil", "false", "zero", "throw" }) do
		helpers.it("(layout-helper-shutdown) actual Main retains " .. refusal .. " until exact helper ACK", function()
			local receipt
			if refusal == "false" then receipt = false elseif refusal == "zero" then receipt = 0
			elseif refusal == "throw" then receipt = "throw" end
			local coordinator, state = fixture(true, receipt)
			helpers.assert_true(coordinator.request("quit while installer runs"))
			helpers.assert_true(coordinator.is_pending(), "a logical cancellation cannot acknowledge native helper retirement")
			helpers.assert_eq(state.calls, 1)
			helpers.assert_eq(state.loops, 0)
			helpers.assert_eq(state.timers, 1, "cancelAll must not prevent later native helper ACK")
			helpers.assert_eq(coordinator.request("repeated TERM"), false)
			helpers.assert_eq(coordinator.poll(), false)
			helpers.assert_eq(state.calls, 2)
			helpers.assert_eq(state.loops, 0)
			state.receipt = true
			helpers.assert_true(coordinator.poll())
			helpers.assert_eq(state.calls, 3)
			helpers.assert_eq(state.loops, 1)
			helpers.assert_true(coordinator.poll())
			helpers.assert_eq(state.calls, 3)
			helpers.assert_eq(state.loops, 1)
		end)
	end

	for _, replacement in ipairs({ "module", "method", "unload" }) do
		helpers.it("(layout-helper-shutdown) retains original helper ACK after " .. replacement .. " replacement", function()
			local coordinator, state, layout, env = fixture(true, false)
			helpers.assert_true(coordinator.request("quit"))
			helpers.assert_true(coordinator.is_pending())
			local foreign_calls = 0
			local function foreign_stop() foreign_calls = foreign_calls + 1; return true end
			if replacement == "module" then env.package.loaded["modules.keymap.layout_registry"] = { shutdown = foreign_stop }
			elseif replacement == "method" then layout.shutdown = foreign_stop
			else env.package.loaded["modules.keymap.layout_registry"] = nil end
			helpers.assert_eq(coordinator.poll(), false, "foreign public exports cannot acknowledge the captured helper")
			helpers.assert_eq(state.calls, 2)
			helpers.assert_eq(foreign_calls, 0)
			helpers.assert_eq(state.loops, 0)
			state.receipt = true
			helpers.assert_true(coordinator.poll())
			helpers.assert_eq(state.calls, 3)
			helpers.assert_eq(foreign_calls, 0)
			helpers.assert_eq(state.loops, 1)
		end)
	end
end)


helpers.describe("actual Main HTTP transport retirement", function()
	local function fixture(loaded, receipt)
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local text = file:read("*a"); file:close()
		local registry = assert(text:match("local shutdown = ShutdownCoordinator%.new%(%{(.-)\n%}%)[\r\n]"),
			"actual Main shutdown constructor must exist")
		local capture = assert(text:match("(local shutdown_runtime = prediction_engine and prediction_engine%.shutdown_runtime.-)\nlocal shutdown = ShutdownCoordinator"))
		local state = { calls = 0, loops = 0, timers = 0, receipt = receipt }
		local http = { shutdown = function()
			state.calls = state.calls + 1
			if state.receipt == "throw" then error("controlled HTTP cleanup failure") end
			return state.receipt
		end }
		local env = setmetatable({ ShutdownCoordinator = ShutdownCoordinator,
			keystats = { stop = function() return true end }, privacy_owners = {},
			dyn_hotstrings = false, updater = false, file_watchers = false, process_lifecycle = false,
			webview_manager = false, tooltip_preview = false, gestures = false, input_capture_gate = false,
			prediction_engine = false,
			package = { loaded = { ["adapters.http_client"] = loaded and http or nil } },
			require = function(name)
				assert(name == "modules.llm.agent_connectors" or name == "modules.llm.agent_learning",
					"cold shutdown must not import " .. tostring(name))
				return { cleanup = function() end, flush = function() end }
			end,
			TimerScheduler = { cancelAll = function() state.timers = state.timers + 1 end },
			keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() state.loops = state.loops + 1 end },
		}, { __index = _G })
		local body = capture .. "\nreturn ShutdownCoordinator.new({" .. registry .. "\n})"
		local chunk, why
		if setfenv then chunk, why = loadstring(body, "actual Main http shutdown"); if chunk then setfenv(chunk, env) end
		else chunk, why = load(body, "actual Main http shutdown", "t", env) end
		return assert(chunk, why)(), state, http, env
	end

	helpers.it("(http-native-shutdown) cold quit imports no HTTP client", function()
		local coordinator, state = fixture(false)
		helpers.assert_true(coordinator.request("cold quit"))
		helpers.assert_eq(coordinator.is_pending(), false)
		helpers.assert_eq(state.calls, 0)
		helpers.assert_eq(state.loops, 1)
	end)

	for _, refusal in ipairs({ "nil", "false", "zero", "throw" }) do
		helpers.it("(http-native-shutdown) actual Main retains " .. refusal .. " until exact transport ACK", function()
			local receipt
			if refusal == "false" then receipt = false elseif refusal == "zero" then receipt = 0
			elseif refusal == "throw" then receipt = "throw" end
			local coordinator, state = fixture(true, receipt)
			helpers.assert_true(coordinator.request("quit while HTTP transport runs"))
			helpers.assert_true(coordinator.is_pending(), "a logical cancellation cannot acknowledge native transport retirement")
			helpers.assert_eq(state.calls, 1)
			helpers.assert_eq(state.loops, 0)
			helpers.assert_eq(state.timers, 1, "cancelAll must not prevent later native transport ACK")
			helpers.assert_eq(coordinator.request("repeated TERM"), false)
			helpers.assert_eq(coordinator.poll(), false)
			helpers.assert_eq(state.calls, 2)
			helpers.assert_eq(state.loops, 0)
			state.receipt = true
			helpers.assert_true(coordinator.poll())
			helpers.assert_eq(state.calls, 3)
			helpers.assert_eq(state.loops, 1)
			helpers.assert_true(coordinator.poll())
			helpers.assert_eq(state.calls, 3)
			helpers.assert_eq(state.loops, 1)
		end)
	end

	for _, replacement in ipairs({ "module", "method", "unload" }) do
		helpers.it("(http-native-shutdown) retains original transport ACK after " .. replacement .. " replacement", function()
			local coordinator, state, http, env = fixture(true, false)
			helpers.assert_true(coordinator.request("quit"))
			helpers.assert_true(coordinator.is_pending())
			local foreign_calls = 0
			local function foreign_stop() foreign_calls = foreign_calls + 1; return true end
			if replacement == "module" then env.package.loaded["adapters.http_client"] = { shutdown = foreign_stop }
			elseif replacement == "method" then http.shutdown = foreign_stop
			else env.package.loaded["adapters.http_client"] = nil end
			helpers.assert_eq(coordinator.poll(), false, "foreign public exports cannot acknowledge the captured transport")
			helpers.assert_eq(state.calls, 2)
			helpers.assert_eq(foreign_calls, 0)
			helpers.assert_eq(state.loops, 0)
			state.receipt = true
			helpers.assert_true(coordinator.poll())
			helpers.assert_eq(state.calls, 3)
			helpers.assert_eq(foreign_calls, 0)
			helpers.assert_eq(state.loops, 1)
		end)
	end
end)
