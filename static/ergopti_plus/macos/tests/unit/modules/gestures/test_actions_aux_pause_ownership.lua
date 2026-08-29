--- tests/unit/modules/gestures/test_actions_aux_pause_ownership.lua

--- ==============================================================================
--- MODULE: Gesture Auxiliary Pause Ownership
--- DESCRIPTION:
--- Drives the real auxiliary owner and TimerScheduler against hostile timer and
--- ShellRunner handles. Late line/reload/open callbacks must remain inert after
--- their parent pauses without fencing or terminating the sibling feature.
--- ==============================================================================

local helpers = require("tests.helpers")


local function fresh_owner()
	local saved_shell_runner = package.loaded["adapters.shell_runner"]
	for _, name in ipairs({
		"modules.gestures.actions_aux_owner",
		"adapters.timer_scheduler",
		"adapters.shell_runner",
		"infra.logger",
		"tests.stubs.hs",
		"hs",
	}) do package.loaded[name] = nil end

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	local fixture = {
		timers = {},
		next_timer_options = {},
		shells = {},
		next_shell_options = {},
		business = 0,
		errors = {},
	}

	function fixture.queue_timer(options)
		fixture.next_timer_options[#fixture.next_timer_options + 1] = options or {}
	end
	local timer_contract = {}
	for key, value in pairs(hs_stub.timer) do timer_contract[key] = value end
	timer_contract.new = function(delay, callback)
		local options = table.remove(fixture.next_timer_options, 1) or {}
		if options.construct_mode == "nil" then return nil end
		if options.construct_mode == "false" then return false end
		if options.construct_mode == "throw" then error("aux timer construction exploded") end
		local timer = {
			delay = delay,
			callback = callback,
			running_state = false,
			stop_calls = 0,
			stop_identities = {},
			stop_mode = options.stop_mode or "success",
		}
		function timer:start()
			self.running_state = true
			if options.start_mode == "false" then return false end
			if options.start_mode == "nil" then return nil end
			if options.start_mode == "throw" then error("aux timer start exploded") end
			return self
		end
		function timer:stop()
			self.stop_calls = self.stop_calls + 1
			self.stop_identities[self.stop_calls] = self
			if self.stop_mode == "false" then return false end
			if self.stop_mode == "nil" then return nil end
			if self.stop_mode == "throw" then error("aux timer stop exploded") end
			self.running_state = false
			return self
		end
		function timer:running() return self.running_state end
		function timer:fire() if self.running_state then self.callback() end end
		function timer:deliver() self.callback() end
		fixture.timers[#fixture.timers + 1] = timer
		return timer
	end
	hs_stub.timer = timer_contract

	function fixture.queue_shell(options)
		fixture.next_shell_options[#fixture.next_shell_options + 1] = options or {}
	end
	local function start_shell(kind, payload, callback)
		local options = table.remove(fixture.next_shell_options, 1) or {}
		local shell = {
			kind = kind,
			payload = payload,
			callback = callback,
			settled = false,
			terminate_mode = options.terminate_mode or "pending",
			terminate_calls = 0,
			terminate_identities = {},
			observers = {},
		}
		function shell.isSettled() return shell.settled end
		function shell.onSettled(observer)
			if shell.settled then observer()
			else shell.observers[#shell.observers + 1] = observer end
			return true
		end
		function shell:settle_before_terminal()
			if self.settled then return end
			self.settled = true
			local observers = self.observers
			self.observers = {}
			for _, observer in ipairs(observers) do observer() end
		end
		function shell.terminate()
			shell.terminate_calls = shell.terminate_calls + 1
			shell.terminate_identities[shell.terminate_calls] = shell
			if shell.terminate_mode == "false" then return false, "refused" end
			if shell.terminate_mode == "nil" then return nil, "refused" end
			if shell.terminate_mode == "throw" then error("aux shell terminate exploded") end
			if options.settle_on_terminate_call == shell.terminate_calls then
				shell:settle_before_terminal()
				return true, "settled"
			end
			return true, "pending"
		end
		function shell:deliver(...)
			local first = self.settled ~= true
			self.settled = true
			self.callback(...)
			if first then
				local observers = self.observers
				self.observers = {}
				for _, observer in ipairs(observers) do observer() end
			end
		end
		fixture.shells[#fixture.shells + 1] = shell
		if options.start_mode == "false" then return false, shell end
		if options.start_mode == "nil" then return nil, shell end
		if options.start_mode == "throw" then error("aux shell start exploded") end
		return true, shell
	end
	package.loaded["adapters.shell_runner"] = {
		open = function(target, callback) return start_shell("open", target, callback) end,
		applescript = function(script, callback)
			return start_shell("applescript", script, callback)
		end,
	}
	local logger = helpers.make_logger_stub()
	logger.error = function(_, format, ...)
		fixture.errors[#fixture.errors + 1] = string.format(format, ...)
	end
	package.loaded["infra.logger"] = logger
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.gestures.actions_aux_owner"] = nil
	fixture.subject = require("modules.gestures.actions_aux_owner")
	package.loaded["adapters.shell_runner"] = saved_shell_runner
	return fixture
end


helpers.describe("gesture auxiliary owner: positive controls", function()
	helpers.it("delivers timer and shell callbacks once while ACTIVE", function()
		local f = fresh_owner()
		helpers.assert_eq(f.subject.after(0, "line", function()
			f.business = f.business + 1
		end), true)
		f.timers[1]:fire()
		f.timers[1]:deliver()
		helpers.assert_eq(f.business, 1)

		helpers.assert_eq(f.subject.open("/tmp/example", "open", function(ok)
			if ok then f.business = f.business + 1 end
		end), true)
		f.shells[1]:deliver(true)
		f.shells[1]:deliver(true)
		helpers.assert_eq(f.business, 2)
		helpers.assert_eq(f.subject.has_pending(), false)
	end)
end)


helpers.describe("gesture auxiliary owner: process settlement deadline", function()
	helpers.it("degrades loudly after bounded termination retries", function()
		local f = fresh_owner()
		local outcomes = {}
		helpers.assert_eq(f.subject.applescript("return 1", "blocked TCC", function(ok)
			outcomes[#outcomes + 1] = ok
		end), true)
		local shell = f.shells[1]
		helpers.assert_eq(#f.timers, 1,
			"a committed shell must acquire one retained settlement deadline")
		helpers.assert_eq(f.timers[1].delay, 10)

		f.timers[1]:fire()
		helpers.assert_eq(shell.terminate_calls, 1)
		helpers.assert_eq(#outcomes, 1)
		helpers.assert_eq(outcomes[1], false,
			"the deadline must publish one explicit business failure")
		helpers.assert_eq(f.subject.has_pending(), true)
		helpers.assert_eq(#f.timers, 2,
			"the first unresolved TERM must arm one exact retry")
		helpers.assert_eq(f.timers[2].delay, 0.5)

		f.timers[2]:fire()
		helpers.assert_eq(shell.terminate_calls, 2)
		helpers.assert_eq(#f.timers, 3)
		f.timers[3]:fire()
		helpers.assert_eq(shell.terminate_calls, 3,
			"cleanup escalation must be bounded")
		helpers.assert_eq(#f.timers, 3,
			"the exhausted owner must not create an unbounded retry chain")
		helpers.assert_eq(f.subject.has_pending(), false,
			"degraded native debt may not wedge the action scope forever")
		helpers.assert_eq(f.subject.pause(), true)
		helpers.assert_eq(f.subject.resume(), true)
		helpers.assert_true(f.errors[#f.errors]:find("degraded", 1, true) ~= nil,
			"degraded release must remain loud in the file log")

		shell:deliver(true)
		helpers.assert_eq(#outcomes, 1,
			"a late degraded child may not regain business authority")
	end)

	helpers.it("releases exact ownership when a retry proves native settlement", function()
		local f = fresh_owner()
		f.queue_shell({ settle_on_terminate_call = 2 })
		local outcomes = {}
		helpers.assert_eq(f.subject.open("/tmp/TCC", "blocked open", function(ok)
			outcomes[#outcomes + 1] = ok
		end), true)
		local shell = f.shells[1]
		f.timers[1]:fire()
		helpers.assert_eq(f.subject.has_pending(), true)
		f.timers[2]:fire()

		helpers.assert_eq(shell.terminate_calls, 2)
		helpers.assert_eq(f.subject.has_pending(), false)
		helpers.assert_eq(#outcomes, 1)
		helpers.assert_eq(outcomes[1], false)
		helpers.assert_true(not table.concat(f.errors, "\n"):find("degraded", 1, true),
			"proven settlement must not be mislabeled as degraded")
	end)

	helpers.it("waits for exact deadline settlement before terminating the child", function()
		local f = fresh_owner()
		f.queue_timer({ stop_mode = "false" })
		local outcomes = {}
		helpers.assert_eq(f.subject.applescript("return 1", "blocked timer", function(ok)
			outcomes[#outcomes + 1] = ok
		end), true)
		local shell = f.shells[1]
		local deadline = f.timers[1]

		deadline:fire()
		helpers.assert_eq(shell.terminate_calls, 0,
			"an unsettled deadline capability may not publish its business timeout")
		helpers.assert_eq(#outcomes, 0)
		helpers.assert_eq(f.subject.has_pending(), true)

		deadline.stop_mode = "success"
		deadline:deliver()
		helpers.assert_eq(shell.terminate_calls, 1)
		helpers.assert_eq(#outcomes, 1)
		helpers.assert_eq(outcomes[1], false)
	end)
end)


helpers.describe("gesture auxiliary owner: timer settlement", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the same timer after stop " .. mode, function()
			local f = fresh_owner()
			helpers.assert_eq(f.subject.after(0, "line", function()
				f.business = f.business + 1
			end), true)
			local timer = f.timers[1]
			timer.stop_mode = mode
			helpers.assert_eq(f.subject.pause(), false)
			helpers.assert_eq(f.subject.is_paused(), true)
			helpers.assert_eq(timer.stop_calls, 1)
			helpers.assert_eq(timer.stop_identities[1] == timer, true)
			helpers.assert_eq(f.subject.after(0, "sibling", function() end), false)
			helpers.assert_eq(#f.timers, 1)

			timer.stop_mode = "success"
			timer:fire()
			timer:deliver()
			helpers.assert_eq(f.business, 0)
			helpers.assert_eq(timer.stop_calls, 2)
			helpers.assert_eq(f.subject.pause(), true)
			helpers.assert_eq(f.subject.resume(), true)
			helpers.assert_eq(#f.timers, 1)
		end)
	end
end)


helpers.describe("gesture auxiliary owner: process settlement", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the same open process after terminate " .. mode, function()
			local f = fresh_owner()
			helpers.assert_eq(f.subject.open("/tmp/example", "open", function()
				f.business = f.business + 1
			end), true)
			local shell = f.shells[1]
			shell.terminate_mode = mode
			helpers.assert_eq(f.subject.pause(), false)
			helpers.assert_eq(shell.terminate_calls, 1)
			helpers.assert_eq(shell.terminate_identities[1] == shell, true)
			helpers.assert_eq(f.subject.applescript("return 1", "sibling"), false)
			helpers.assert_eq(#f.shells, 1)

			shell.terminate_mode = "pending"
			f.timers[#f.timers]:fire()
			helpers.assert_eq(shell.terminate_calls, 2)
			shell:deliver(true)
			shell:deliver(true)
			helpers.assert_eq(f.business, 0)
			helpers.assert_eq(f.subject.pause(), true)
			helpers.assert_eq(f.subject.resume(), true)
			helpers.assert_eq(#f.shells, 1)
		end)
	end
end)


helpers.describe("gesture auxiliary owner: acquisition refusals", function()
	for _, boundary in ipairs({ "construct", "start" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("rejects timer " .. boundary .. " " .. mode .. " without late work", function()
				local f = fresh_owner()
				local options = {}
				options[boundary .. "_mode"] = mode
				f.queue_timer(options)
				helpers.assert_eq(f.subject.after(0, "refused timer", function()
					f.business = f.business + 1
				end), false)
				if f.timers[1] then f.timers[1]:deliver() end
				helpers.assert_eq(f.business, 0,
					"a refused timer boundary must never retain business authority")
				helpers.assert_eq(f.subject.has_pending(), false,
					"successful acquisition rollback must release the exact logical entry")
			end)
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rejects shell start " .. mode .. " and fences its late terminal", function()
			local f = fresh_owner()
			f.queue_shell({ start_mode = mode })
			helpers.assert_eq(f.subject.open("/tmp/refused", "refused shell", function()
				f.business = f.business + 1
			end), false)
			local shell = f.shells[1]
			if mode ~= "throw" then
				helpers.assert_eq(f.subject.has_pending(), true,
					"a returned handle must remain exact cleanup debt until settlement")
			end
			shell:deliver(true)
			helpers.assert_eq(f.business, 0,
				"a refused shell start must permanently revoke its terminal callback")
			helpers.assert_eq(f.subject.has_pending(), false)
		end)
	end
end)


helpers.describe("gesture auxiliary owner: staged timers", function()
	helpers.it("buffers a due callback until the caller commits the exact token", function()
		local f = fresh_owner()
		local prepared, token = f.subject.prepare_after(0, "staged", function()
			f.business = f.business + 1
		end)
		helpers.assert_eq(prepared, true)
		helpers.assert_eq(type(token), "table")
		f.timers[1]:fire()
		helpers.assert_eq(f.business, 0,
			"native delivery before transaction commit must remain buffered")
		helpers.assert_eq(f.subject.commit_after(token), true)
		helpers.assert_eq(f.business, 1)
		helpers.assert_eq(f.subject.has_pending(), false)
	end)

	helpers.it("rollback permanently revokes a prepared timer", function()
		local f = fresh_owner()
		local prepared, token = f.subject.prepare_after(0, "staged", function()
			f.business = f.business + 1
		end)
		helpers.assert_eq(prepared, true)
		helpers.assert_eq(f.subject.rollback_after(token), true)
		f.timers[1]:deliver()
		helpers.assert_eq(f.business, 0)
		helpers.assert_eq(f.subject.commit_after(token), false)
	end)
end)


helpers.describe("gesture auxiliary owner: terminal identity fence", function()
	helpers.it("rejects an old terminal delivered after onSettled released its slot", function()
		local f = fresh_owner()
		helpers.assert_eq(f.subject.open("/tmp/old", "old", function()
			f.business = f.business + 10
		end), true)
		local old = f.shells[1]
		old:settle_before_terminal()

		helpers.assert_eq(f.subject.open("/tmp/new", "new", function()
			f.business = f.business + 1
		end), true)
		old:deliver(true)
		f.shells[2]:deliver(true)

		helpers.assert_eq(f.business, 1,
			"a released predecessor must not borrow its successor's active generation")
		helpers.assert_eq(f.subject.has_pending(), false)
	end)
end)


helpers.describe("gesture auxiliary owner: parent isolation", function()
	for _, parent in ipairs({ "gestures", "shortcut_bindings" }) do
		helpers.it("keeps " .. parent .. " timer callback in-flight until business returns", function()
			local f = fresh_owner()
			local nested_pause
			helpers.assert_eq(f.subject.after(0, "reentrant timer", function()
				nested_pause = f.subject.pause(parent)
				f.business = f.business + 1
			end, parent), true)
			f.timers[1]:fire()
			helpers.assert_eq(nested_pause, false,
				"PAUSE inside business delivery may not report settled before return")
			helpers.assert_eq(f.business, 1)
			helpers.assert_eq(f.subject.is_paused(parent), true)
			helpers.assert_eq(f.subject.pause(parent), true)
		end)

		helpers.it("keeps " .. parent .. " shell terminal in-flight until business returns", function()
			local f = fresh_owner()
			local nested_pause
			helpers.assert_eq(f.subject.open("/tmp/reentrant", "reentrant shell", function()
				nested_pause = f.subject.pause(parent)
				f.business = f.business + 1
			end, parent), true)
			f.shells[1]:deliver(true)
			helpers.assert_eq(nested_pause, false)
			helpers.assert_eq(f.business, 1)
			helpers.assert_eq(f.subject.pause(parent), true)
		end)
	end

	helpers.it("does not let one parent's callback depth fence its sibling", function()
		local f = fresh_owner()
		local sibling_pause
		helpers.assert_eq(f.subject.after(0, "shortcut timer", function()
			sibling_pause = f.subject.pause("gestures")
			f.business = f.business + 1
		end, "shortcut_bindings"), true)
		f.timers[1]:fire()
		helpers.assert_eq(sibling_pause, true)
		helpers.assert_eq(f.business, 1)
		helpers.assert_eq(f.subject.is_paused("shortcut_bindings"), false)
	end)

	helpers.it("retains one parent's timer debt while a sibling shell publishes", function()
		local f = fresh_owner()
		helpers.assert_eq(f.subject.after(0, "gesture timer", function()
			f.business = f.business + 100
		end, "gestures"), true)
		local gesture_timer = f.timers[1]
		gesture_timer.stop_mode = "false"

		helpers.assert_eq(f.subject.open(
			"/tmp/shortcut", "shortcut shell", function()
				f.business = f.business + 1
			end, "shortcut_bindings"), true)
		local shortcut_shell = f.shells[1]

		helpers.assert_eq(f.subject.pause("gestures"), false)
		helpers.assert_eq(gesture_timer.stop_calls, 1)
		helpers.assert_eq(shortcut_shell.terminate_calls, 0,
			"gesture cleanup must not terminate shortcut work")
		helpers.assert_eq(f.subject.is_paused("gestures"), true)
		helpers.assert_eq(f.subject.is_paused("shortcut_bindings"), false)

		shortcut_shell:deliver(true)
		helpers.assert_eq(f.business, 1,
			"the sibling terminal must retain business authority")
		helpers.assert_eq(f.subject.has_pending("shortcut_bindings"), false)

		gesture_timer.stop_mode = "success"
		gesture_timer:deliver()
		helpers.assert_eq(f.business, 1,
			"the paused parent's late timer must stay fenced")
		helpers.assert_eq(f.subject.pause("gestures"), true)
		helpers.assert_eq(f.subject.resume("gestures"), true)
	end)
end)
