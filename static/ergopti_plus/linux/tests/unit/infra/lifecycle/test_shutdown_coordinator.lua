--- tests/unit/infra/lifecycle/test_shutdown_coordinator.lua

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
		local native_closed = { discovery = false, programs = false, watchers = false }
		local native_calls = { discovery = 0, programs = 0, watchers = 0 }
		local function native_stop(name)
			return function()
				native_calls[name] = native_calls[name] + 1
				return native_closed[name]
			end
		end
		local env = setmetatable({ ShutdownCoordinator = ShutdownCoordinator,
			keylogger = { stop = function() return state.metrics_closed end },
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
			} } }, require = function() return { cleanup = function() end, flush = function() end } end,
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
		local signal = { SIGINT = 2, SIGTERM = 15, SIGHUP = 1,
			signal = function(number, callback) state.handlers[number] = callback; return true end }
		local env = setmetatable({ shutdown = coordinator, require = function(name)
			helpers.assert_eq(name, "posix.signal"); return signal
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
				keylogger = { get_session_stats = function() return { keystrokes = 0, words = 0, duration_ms = 0 } end },
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
			helpers.assert_true(pcall(finish))
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
			helpers.assert_true(pcall(finish))
			helpers.assert_eq(calls.success, 2)
			helpers.assert_eq(calls.destroy, 0)
			helpers.assert_eq(calls.close, 0)
			helpers.assert_eq(writer.has_output_debt(), false)
		end)
	end)
end)
