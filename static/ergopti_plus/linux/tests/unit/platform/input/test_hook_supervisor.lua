--- tests/unit/platform/input/test_hook_supervisor.lua

--- ==============================================================================
--- MODULE: Keyboard Hook Supervisor
--- DESCRIPTION:
--- A keyboard hook that stopped while nobody asked it to used to end the whole
--- daemon (« Shutdown quiescence started (keyboard hook stopped) »), with no
--- cause in the log; a refused window, a dialog or a watchdog tick shortly
--- before it was the only trace. These cases pin what replaces it: the cause is
--- named, the hook is started again within a bounded budget, a window refusal
--- never touches capture, and only a deliberate stop is left alone.
--- ==============================================================================

local restore_loaded = require("tests.helpers").keep_loaded({ "core.ui.ui.webview_manager",
	"platform.input.hook_supervisor", "hotstrings.engine.injector" })
local helpers = require("tests.helpers")

--- A controlled hook: running state and last stop are set by the case.
--- @return table hook
local function fake_hook()
	local hook = { running = true, stop = nil }
	function hook.isRunning() return hook.running end
	function hook.isRecovering() return false end
	function hook.last_stop() return hook.stop end
	return hook
end

--- A supervisor over a fake hook and a controlled clock.
--- @param restart function The restart port, given the hook and the clock.
--- @return table supervisor, table hook, table clock
local function supervised(restart)
	local Supervisor = helpers.load_module("platform.input.hook_supervisor")
	local hook, clock = fake_hook(), { now = 0 }
	local supervisor = Supervisor.new({ hook = hook, restart = function() return restart(hook, clock) end,
		now_ms = function() return clock.now end })
	return supervisor, hook, clock, Supervisor
end

helpers.describe("hook supervisor: an unexpected stop is restarted, never a shutdown", function()
	helpers.it("hook-supervisor: waits its first pause, then restarts the hook", function()
		local restarts = 0
		local supervisor, hook, clock, Supervisor = supervised(function(h)
			restarts = restarts + 1; h.running = true; return true
		end)
		helpers.assert_eq(supervisor.poll(), "running")
		hook.running, hook.stop = false, { deliberate = false, reason = "source reconciliation refused" }
		helpers.assert_eq(supervisor.poll(), "waiting", "the stop is noticed and a restart is scheduled")
		helpers.assert_eq(restarts, 0, "no restart before the named pause")
		clock.now = Supervisor.RESTART_BACKOFF_MS[1] - 1
		helpers.assert_eq(supervisor.poll(), "waiting")
		clock.now = Supervisor.RESTART_BACKOFF_MS[1]
		helpers.assert_eq(supervisor.poll(), "restarted")
		helpers.assert_eq(restarts, 1)
		helpers.assert_true(hook.running)
	end)

	helpers.it("hook-supervisor: leaves a deliberate stop alone", function()
		local restarts = 0
		local supervisor, hook, clock = supervised(function() restarts = restarts + 1; return true end)
		hook.running, hook.stop = false, { deliberate = true, reason = "stopped by its owner" }
		for _ = 1, 3 do
			clock.now = clock.now + 60000
			helpers.assert_eq(supervisor.poll(), "stopped")
		end
		helpers.assert_eq(restarts, 0)
	end)

	helpers.it("hook-supervisor: gives up after the bounded budget, each pause longer than the last", function()
		local attempts_at = {}
		local supervisor, hook, clock, Supervisor = supervised(function(_, at)
			attempts_at[#attempts_at + 1] = at.now; return false, "open refused"
		end)
		hook.running, hook.stop = false, { deliberate = false, reason = "emergency" }
		local states, budget = {}, #Supervisor.RESTART_BACKOFF_MS
		for step = 0, 200000, 250 do
			clock.now = step
			local state = supervisor.poll()
			if state == "exhausted" then states[#states + 1] = state; break end
		end
		helpers.assert_eq(states[1], "exhausted")
		helpers.assert_eq(#attempts_at, budget, "exactly the named number of attempts")
		for index = 2, #attempts_at do
			helpers.assert_true(attempts_at[index] - attempts_at[index - 1] >= Supervisor.RESTART_BACKOFF_MS[index],
				"attempt " .. index .. " waited its pause")
		end
	end)

	helpers.it("hook-supervisor: restores the budget once a restart held long enough", function()
		local restarts = 0
		local supervisor, hook, clock, Supervisor = supervised(function(h)
			restarts = restarts + 1; h.running = true; return true
		end)
		for _ = 1, #Supervisor.RESTART_BACKOFF_MS + 2 do
			hook.running, hook.stop = false, { deliberate = false, reason = "emergency" }
			helpers.assert_eq(supervisor.poll(), "waiting")
			clock.now = clock.now + Supervisor.RESTART_BACKOFF_MS[1]
			helpers.assert_eq(supervisor.poll(), "restarted")
			clock.now = clock.now + Supervisor.STABLE_RESET_MS
		end
		helpers.assert_eq(restarts, #Supervisor.RESTART_BACKOFF_MS + 2, "stops far apart never exhaust the budget")
	end)
end)

helpers.describe("hook supervisor: the real hook after a silent retirement", function()
	helpers.it("hook-supervisor: names the cause and starts capture again with a fresh output channel", function()
		require("tests.support.input_owner_fixture").with_session({
			on_capture_reacquired = function() return true end }, function(s)
			-- A dialog whose restoration cannot read the key state (this fixture
			-- answers no EVIOCGKEY) retires capture and its output, as the field
			-- log's silent « Closed /dev/input/event3 » did.
			helpers.assert_eq(s.hook.while_released(function() return "answer" end), "answer")
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.hook.isRecovering(), false)
			local stop = s.hook.last_stop()
			helpers.assert_true(stop ~= nil and stop.deliberate == false, "the retirement is not a quit")
			helpers.assert_eq(stop.reason, "native state reconciliation refused")

			local Injector = helpers.load_module("hotstrings.engine.injector")
			Injector._set_uinput(s.writer)
			local node = os.tmpname()
			helpers.assert_true(s.writer._set_path_for_test(node) ~= false, "the retired writer accepts a controlled node")
			local Supervisor = helpers.load_module("platform.input.hook_supervisor")
			local clock = 0
			local supervisor = Supervisor.new({ hook = s.hook, now_ms = function() return clock end,
				restart = function()
					if Injector.reopen_fast_channel() ~= true then return false, "output" end
					s.start_options.outputBroker = Injector.output_broker()
					return s.hook.start(s.start_options) == true
				end })
			local ok, failure = pcall(function()
				helpers.assert_eq(supervisor.poll(), "waiting")
				clock = Supervisor.RESTART_BACKOFF_MS[1]
				helpers.assert_eq(supervisor.poll(), "restarted")
				helpers.assert_true(s.hook.isRunning(), "capture runs again")
				helpers.assert_eq(s.hook.last_stop(), nil)
				helpers.assert_true(s.reader.is_grabbed("keyboard:" .. s.paths.b), "the keyboard is grabbed again")
				s.successor = s.writer.capture_output()
			end)
			s.writer._set_path_for_test(nil)
			Injector._set_uinput(nil)
			os.remove(node)
			if not ok then error(failure, 0) end
		end)
	end)

	helpers.it("hook-supervisor: restarts capture after an emergency stop instead of ending the daemon", function()
		require("tests.support.input_owner_fixture").with_session({
			on_capture_reacquired = function() return true end }, function(s)
			-- Field crash report 2026-11-25 01:41:56: a failed clipboard
			-- restoration stopped the hook, and the idle tick shut the daemon down.
			s.hook.emergency_stop("inject(): clipboard restoration failed")
			helpers.assert_eq(s.hook.isRunning(), false)
			local stop = s.hook.last_stop()
			helpers.assert_true(stop ~= nil and stop.deliberate == false, "an emergency is not a quit")
			helpers.assert_eq(stop.reason, "inject(): clipboard restoration failed")
			local Supervisor = helpers.load_module("platform.input.hook_supervisor")
			local clock, restarts = 0, 0
			local supervisor = Supervisor.new({ hook = s.hook, now_ms = function() return clock end,
				restart = function()
					restarts = restarts + 1
					return s.hook.start(s.start_options) == true
				end })
			helpers.assert_eq(supervisor.poll(), "waiting", "the emergency is handed to a restart, not a shutdown")
			clock = Supervisor.RESTART_BACKOFF_MS[1]
			helpers.assert_eq(supervisor.poll(), "restarted")
			helpers.assert_eq(restarts, 1)
			helpers.assert_true(s.hook.isRunning(), "capture runs again")
			helpers.assert_true(s.reader.is_grabbed("keyboard:" .. s.paths.b), "the keyboard is grabbed again")
			s.successor = s.writer.capture_output()
		end)
	end)

	helpers.it("hook-supervisor: keeps a stop requested by its owner deliberate", function()
		require("tests.support.input_owner_fixture").with_session({ on_capture_reacquired = function() return true end }, function(s)
			assert(s.hook.stop() ~= false)
			local stop = s.hook.last_stop()
			helpers.assert_true(stop ~= nil and stop.deliberate == true)
		end)
	end)
end)

helpers.describe("hook supervisor: a refused window never stops capture", function()
	helpers.it("hook-supervisor: keeps the hook running and starts no shutdown when native acquisition is refused", function()
		require("tests.support.input_owner_fixture").with_session({ position_bits = true,
			on_capture_reacquired = function() return true end }, function(s)
			local manager = helpers.load_module_with_dependency("core.ui.ui.webview_manager", "lgi", false)
			manager.build_page_html = function() return "owned page fixture" end
			manager._create_gtk_window = function() return false end
			local name = "ui.metrics_typing.bridge"
			local previous = package.loaded[name]
			package.loaded[name] = { bridge_name = "metrics_typing_bridge", on_message = function() end }
			local ok, failure = pcall(function()
				helpers.assert_eq(manager.show("metrics_typing", "en"), false, "the window is refused, as without lgi")
				helpers.assert_eq(manager.current_epoch("metrics_typing"), nil, "the refused page is closed")
				for _ = 1, s.hook.DEVICE_CHECK_TICKS * 2 do s.hook.check_device() end
				s.edge("a", 30, 1, 10); s.edge("a", 30, 0, 20)
				helpers.assert_true(s.hook.isRunning(), "the keyboard hook outlives the refused window")
				local Supervisor = helpers.load_module("platform.input.hook_supervisor")
				local restarted = false
				local supervisor = Supervisor.new({ hook = s.hook, now_ms = function() return 0 end,
					restart = function() restarted = true; return true end })
				helpers.assert_eq(supervisor.poll(), "running", "nothing for the daemon to restart or shut down")
				helpers.assert_eq(restarted, false)
			end)
			package.loaded[name] = previous
			if not ok then error(failure, 0) end
		end)
	end)
end)

restore_loaded()
