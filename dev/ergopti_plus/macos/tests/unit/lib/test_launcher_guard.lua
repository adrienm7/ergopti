--- tests/unit/lib/test_launcher_guard.lua

--- ==============================================================================
--- MODULE: Launcher Parent-Liveness Guard Regression Tests
--- DESCRIPTION:
--- Exercises the native application-watcher guard that binds an embedded
--- Hammerspoon process to the exact Swift launcher process that spawned it.
---
--- FEATURES & RATIONALE:
--- 1. Race closure: the watcher must already be active when the immediate PID
---    lookup runs, so a launcher killed during boot cannot escape both checks.
--- 2. Exact identity: a live PID is accepted only with the expected observable
---    bundle identifier, while the exact terminated event remains authoritative
---    after macOS has already made that metadata unavailable.
--- 3. One-shot failure containment: duplicate events and a callback exception
---    cannot invoke teardown twice or disappear outside the central file logger.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================
-- =====================================
-- ======= 1/ Test Fixture =============
-- =====================================
-- =====================================

local LAUNCHER_PID = 4242
local LAUNCHER_BUNDLE_ID = "com.ergoptiplus.app"

--- Builds an application object exposing the native identity methods used by
--- the guard.
--- @param pid integer Process identifier returned by app:pid().
--- @param bundle_id string|nil Bundle identifier returned by app:bundleID().
--- @return table app Stub application object.
local function make_app(pid, bundle_id)
	local app = {
		running = true,
		pid = function() return pid end,
		bundleID = function() return bundle_id end,
		isRunning = function(self) return self.running == true end,
	}
	return app
end

--- Formats a central-logger call into one assertion-friendly string.
--- @param message string Format string received by Logger.error().
--- @param ... any Format arguments received by Logger.error().
--- @return string line Formatted log line.
local function format_log(message, ...)
	local ok, line = pcall(string.format, tostring(message), ...)
	return ok and line or tostring(message)
end

--- Runs one test with isolated environment variables, Hammerspoon state, and
--- a recording central logger, then restores every process-global mutation.
--- @param environment table<string, string|nil> Environment visible to the guard.
--- @param fn function Test body called with (guard, hs_stub, log_lines).
local function with_guard(environment, fn)
	local real_getenv = os.getenv
	local real_execute = os.execute
	local real_popen = io.popen
	local previous_hs = _G.hs
	local previous_hs_module = package.loaded["hs"]
	local previous_hs_stub = package.loaded["tests.stubs.hs"]
	local previous_logger = package.loaded["infra.logger"]
	local previous_guard = package.loaded["infra.launcher_guard"]
	local log_lines = {}
	local logger = helpers.make_logger_stub()

	logger.error = function(_, message, ...)
		log_lines[#log_lines + 1] = format_log(message, ...)
	end
	logger.warn = function(_, message, ...)
		log_lines[#log_lines + 1] = format_log(message, ...)
	end

	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	hs_stub.execute = function() error("launcher guard must not invoke hs.execute") end
	hs_stub.task.new = function() error("launcher guard must not spawn hs.task") end
	hs_stub.eventtap.new = function() error("launcher guard must not create an eventtap") end
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["infra.logger"] = logger
	package.loaded["infra.launcher_guard"] = nil
	os.getenv = function(name)
		return environment[name]
	end
	os.execute = function() error("launcher guard must not invoke os.execute") end
	io.popen = function() error("launcher guard must not invoke io.popen") end

	local ok, result = xpcall(function()
		local guard = require("infra.launcher_guard")
		return fn(guard, hs_stub, log_lines)
	end, debug.traceback)

	os.getenv = real_getenv
	os.execute = real_execute
	io.popen = real_popen
	_G.hs = previous_hs
	package.loaded["hs"] = previous_hs_module
	package.loaded["tests.stubs.hs"] = previous_hs_stub
	package.loaded["infra.logger"] = previous_logger
	package.loaded["infra.launcher_guard"] = previous_guard

	if not ok then error(result, 0) end
	return result
end

--- Returns the managed-launch environment used by most cases.
--- @return table<string, string> environment Exact launcher identity variables.
local function managed_environment()
	return {
		ERGOPTI_LAUNCHER_PID = tostring(LAUNCHER_PID),
		ERGOPTI_LAUNCHER_BUNDLE_ID = LAUNCHER_BUNDLE_ID,
	}
end





-- =====================================
-- =====================================
-- ======= 2/ Boot Race Closure ========
-- =====================================
-- =====================================

helpers.describe("launcher guard — boot race closure", function()
	helpers.it("quits once when the launcher is already absent before init", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local quit_reasons = {}
			local started = guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end)

			helpers.assert_true(not started,
				"an absent managed launcher must make initialization fail closed")
			helpers.assert_eq(#quit_reasons, 1,
				"the immediate PID lookup must request exactly one emergency quit")
			helpers.assert_eq(hs_stub.application.__query_watcher_counts[1], 1,
				"the watcher must already be active during the missing-parent lookup")
			helpers.assert_eq(hs_stub.application.__queries[1], LAUNCHER_PID,
				"the immediate lookup must query the exact exported launcher PID")
		end)
	end)

	helpers.it("strongly retains the native watcher across garbage collection", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			helpers.assert_true(guard.init(function() end))

			collectgarbage("collect")
			collectgarbage("collect")
			local watcher = hs_stub.application.watcher.__watchers[1]

			helpers.assert_true(watcher ~= nil,
				"the module must keep the native watcher alive after init returns")
			helpers.assert_true(watcher.running,
				"the strongly retained launcher watcher must remain active")
		end)
	end)

	helpers.it("keeps the launcher-guard module inert when tested without a parent PID", function()
		with_guard({}, function(guard, hs_stub)
			local quit_count = 0
			local started = guard.init(function() quit_count = quit_count + 1 end)

			helpers.assert_true(started,
				"the isolated guard module must allow its explicit no-parent mode")
			helpers.assert_eq(quit_count, 0,
				"the isolated no-parent guard must not request quit")
			helpers.assert_eq(#hs_stub.application.watcher.__watchers, 0,
				"the isolated no-parent guard must not arm an unknown watcher")
			helpers.assert_eq(#hs_stub.application.__queries, 0,
				"the isolated no-parent guard must not probe an invented PID")
		end)
	end)

	helpers.it("fails closed when the exact PID resolves to a different bundle", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			hs_stub.application.__set_for_pid(
				LAUNCHER_PID, make_app(LAUNCHER_PID, "example.unrelated"))
			local quit_count = 0

			local started = guard.init(function() quit_count = quit_count + 1 end)

			helpers.assert_true(not started,
				"a reused PID with the wrong observable bundle must not be trusted")
			helpers.assert_eq(quit_count, 1,
				"identity mismatch must request one emergency quit")
		end)
	end)

	helpers.it("fails closed when a live launcher PID has no observable bundle ID", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			hs_stub.application.__set_for_pid(
				LAUNCHER_PID, make_app(LAUNCHER_PID, nil))
			local quit_reasons = {}

			local started = guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end)

			helpers.assert_true(not started,
				"a live PID without its expected bundle identity must not be trusted")
			helpers.assert_eq(#quit_reasons, 1,
				"unobservable live identity must request one emergency quit")
			helpers.assert_eq(quit_reasons[1], "launcher_identity_unverifiable")
		end)
	end)

	helpers.it("fails closed when the live launcher bundle probe raises", function()
		with_guard(managed_environment(), function(guard, hs_stub, log_lines)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			launcher.bundleID = function() error("bundle probe exploded") end
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local quit_reasons = {}

			local started = guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end)

			helpers.assert_true(not started,
				"a raising live bundle probe must not degrade to PID-only trust")
			helpers.assert_eq(#quit_reasons, 1,
				"a failed live identity probe must request one emergency quit")
			helpers.assert_eq(quit_reasons[1], "launcher_identity_unverifiable")
			local joined = table.concat(log_lines, "\n")
			helpers.assert_true(joined:find("bundle probe exploded", 1, true) ~= nil,
				"the swallowed native bundle error must remain visible in the file logger")
		end)
	end)

	helpers.it("rejects a malformed managed-launch PID before arming resources", function()
		local environment = managed_environment()
		environment.ERGOPTI_LAUNCHER_PID = "4242x"
		with_guard(environment, function(guard, hs_stub)
			local quit_reasons = {}

			local started = guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end)

			helpers.assert_true(not started,
				"a malformed exported PID must make initialization fail closed")
			helpers.assert_eq(#quit_reasons, 1,
				"invalid managed identity must request one emergency quit")
			helpers.assert_eq(quit_reasons[1], "launcher_pid_invalid")
			helpers.assert_eq(#hs_stub.application.watcher.__watchers, 0,
				"invalid identity must not arm a watcher for an untrusted PID")
			helpers.assert_eq(#hs_stub.application.__queries, 0,
				"invalid identity must not reach the native PID API")
		end)
	end)

	helpers.it("rejects a managed PID without its expected bundle identity", function()
		for _, missing_value in ipairs({ false, "" }) do
			local environment = managed_environment()
			environment.ERGOPTI_LAUNCHER_BUNDLE_ID = missing_value or nil
			with_guard(environment, function(guard, hs_stub)
				local quit_reasons = {}
				local started = guard.init(function(reason)
					quit_reasons[#quit_reasons + 1] = reason
				end)

				helpers.assert_true(not started,
					"a managed PID without a trusted bundle identity must fail closed")
				helpers.assert_eq(#hs_stub.application.watcher.__watchers, 0,
					"invalid managed identity must be rejected before arming resources")
				helpers.assert_eq(quit_reasons[1], "launcher_bundle_id_invalid")
			end)
		end
	end)

	helpers.it("fails closed when the native watcher refuses to start", function()
		with_guard(managed_environment(), function(guard, hs_stub, log_lines)
			hs_stub.application.watcher.new = function(callback)
				return {
					fn = callback,
					start = function() return false end,
					stop = function() end,
				}
			end
			local quit_reasons = {}

			local started = guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end)

			helpers.assert_true(not started,
				"a false watcher start result must not be treated as an armed guard")
			helpers.assert_eq(quit_reasons[1], "launcher_watcher_unavailable",
				"managed launch must enter the emergency path when observation is unavailable")
			helpers.assert_true(
				table.concat(log_lines, "\n"):find("watcher start returned a false value", 1, true) ~= nil,
				"the swallowed native failure must remain visible in the central logger"
			)
		end)
	end)

	helpers.it("fails closed when the process-instance backstop cannot be retained", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			hs_stub.timer.new = function() return nil end
			local quit_reasons = {}

			local started = guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end)

			helpers.assert_true(not started,
				"the watcher alone cannot cover a termination event that is never delivered")
			helpers.assert_eq(quit_reasons[1], "launcher_backstop_unavailable",
				"missing retained-instance recovery must enter the one-shot emergency path")
			helpers.assert_true(hs_stub.application.watcher.__watchers[1].stopped == 1,
				"failed initialization must release the already-armed watcher")
		end)
	end)

	helpers.it("retains and fences a backstop whose start activates then raises", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local native = nil
			local start_calls = 0
			local stop_calls = 0
			local callback_calls = 0
			hs_stub.timer.new = function(_, callback)
				native = { running = false }
				function native:start()
					start_calls = start_calls + 1
					self.running = true
					launcher.running = false
					callback_calls = callback_calls + 1
					callback()
					error("active backstop start failure")
				end
				function native:stop()
					stop_calls = stop_calls + 1
					if stop_calls <= 2 then return false end
					self.running = false
					return self
				end
				return native
			end
			local quit_reasons = {}

			local started = guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end)

			helpers.assert_true(not started)
			helpers.assert_eq(quit_reasons[1], "launcher_backstop_unavailable",
				"a callback fired inside uncommitted start must remain logically inert")
			helpers.assert_eq(callback_calls, 1,
				"the fixture must exercise the re-entrant native callback")
			helpers.assert_eq(start_calls, 1,
				"a failed native candidate must never be replaced by a successor")
			helpers.assert_eq(stop_calls, 2,
				"initial rollback and emergency cleanup must retry the same candidate")
			helpers.assert_true(native.running,
				"explicit cleanup refusal must leave the exact candidate retained")
			helpers.assert_true(guard.stop(),
				"a later lifecycle pass must retry retained early-boot cleanup debt")
			helpers.assert_eq(stop_calls, 3)
			helpers.assert_true(not native.running)
		end)
	end)

	helpers.it("rolls back a backstop whose native start returns false", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local native = nil
			local start_calls = 0
			local stop_calls = 0
			hs_stub.timer.new = function(_, callback)
				native = { running = false }
				function native:start()
					start_calls = start_calls + 1
					self.running = true
					callback()
					return false
				end
				function native:stop()
					stop_calls = stop_calls + 1
					self.running = false
					return self
				end
				return native
			end
			local quit_reasons = {}

			local started = guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end)

			helpers.assert_true(not started)
			helpers.assert_eq(quit_reasons[1], "launcher_backstop_unavailable")
			helpers.assert_eq(start_calls, 1)
			helpers.assert_eq(stop_calls, 1,
				"an explicitly refused start must roll back its exact native object")
			helpers.assert_true(not native.running)
			helpers.assert_true(guard.stop())
			helpers.assert_eq(stop_calls, 1,
				"successful rollback must not leave a phantom cleanup owner")
		end)
	end)

	helpers.it("rejects a chainable backstop start whose native state stays stopped", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local native = nil
			local start_calls = 0
			local stop_calls = 0
			hs_stub.timer.new = function(_, callback)
				native = { callback = callback, live = false }
				function native:start()
					start_calls = start_calls + 1
					return self
				end
				function native:stop()
					stop_calls = stop_calls + 1
					self.live = false
					return self
				end
				function native:running() return self.live end
				return native
			end
			local quit_reasons = {}

			helpers.assert_eq(guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end), false)
			helpers.assert_eq(quit_reasons[1], "launcher_backstop_unavailable")
			helpers.assert_eq(start_calls, 1)
			helpers.assert_eq(stop_calls, 1,
				"false native commitment must roll back the exact candidate")
			helpers.assert_eq(native.live, false)
			helpers.assert_true(guard.stop())
			helpers.assert_eq(stop_calls, 1,
				"settled rollback must not retain phantom cleanup debt")
		end)
	end)

	helpers.it("retains and fences a chainably stopped live backstop", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local native = nil
			local stop_calls = 0
			hs_stub.timer.new = function(_, callback)
				native = { callback = callback, live = false }
				function native:start() self.live = true; return self end
				function native:stop()
					stop_calls = stop_calls + 1
					if stop_calls == 1 then return self end
					self.live = false
					return self
				end
				function native:running() return self.live end
				return native
			end
			local quit_count = 0
			helpers.assert_true(guard.init(function() quit_count = quit_count + 1 end))

			helpers.assert_eq(guard.stop(), false,
				"a chainable stop result cannot hide still-running native state")
			helpers.assert_true(native.live,
				"the exact backstop must remain retained for cleanup retry")
			launcher.running = false
			native.callback()
			helpers.assert_eq(quit_count, 0,
				"logical fencing must precede an ineffective native stop")
			helpers.assert_true(guard.stop(),
				"the next lifecycle pass must retry the same backstop")
			helpers.assert_eq(stop_calls, 2)
			helpers.assert_eq(native.live, false)
		end)
	end)
end)





-- =====================================
-- =====================================
-- ======= 3/ Termination Events =======
-- =====================================
-- =====================================

helpers.describe("launcher guard — native termination events", function()
	helpers.it("reacts to SIGKILL's terminated event for the exact launcher", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			local terminated_launcher = make_app(LAUNCHER_PID, nil)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local quit_reasons = {}
			helpers.assert_true(guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end))

			hs_stub.application.__remove_for_pid(LAUNCHER_PID)
			hs_stub.application.__emit(
				nil, hs_stub.application.watcher.terminated, terminated_launcher)

			helpers.assert_eq(#quit_reasons, 1,
				"the exact launcher termination must request emergency quit")
			helpers.assert_eq(quit_reasons[1], "launcher_terminated",
				"the callback must receive a diagnostic termination reason")
		end)
	end)

	helpers.it("probes the retained launcher immediately when terminated has no app object", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local quit_reasons = {}
			helpers.assert_true(guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end))

			launcher.running = false
			hs_stub.application.__remove_for_pid(LAUNCHER_PID)
			hs_stub.application.__emit(nil, hs_stub.application.watcher.terminated, nil)

			helpers.assert_eq(quit_reasons[1], "launcher_missing",
				"a nil terminated app object must not defer launcher loss to the two-second timer")
			helpers.assert_eq(hs_stub.timer.__timers[1].fired, 0,
				"native watcher delivery must trigger the retained-instance probe immediately")
		end)
	end)

	helpers.it("ignores unrelated application termination", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local quit_count = 0
			helpers.assert_true(guard.init(function() quit_count = quit_count + 1 end))

			hs_stub.application.__emit(
				"Other", hs_stub.application.watcher.terminated,
				make_app(LAUNCHER_PID + 1, "example.other"))

			helpers.assert_eq(quit_count, 0,
				"a different PID must never terminate embedded Hammerspoon")
		end)
	end)

	helpers.it("invokes emergency quit exactly once across duplicate signals", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local quit_count = 0
			helpers.assert_true(guard.init(function() quit_count = quit_count + 1 end))
			local watcher = hs_stub.application.watcher.__watchers[1]

			hs_stub.application.__remove_for_pid(LAUNCHER_PID)
			watcher.fn("ErgoptiPlus", hs_stub.application.watcher.terminated, launcher)
			watcher.fn("ErgoptiPlus", hs_stub.application.watcher.terminated, launcher)
			for _, timer in ipairs(hs_stub.timer.__timers) do
				-- Model a callback already queued before stop(), not a future native tick.
				timer.fn()
			end

			helpers.assert_eq(quit_count, 1,
				"termination, duplicate delivery, and backstop must share one latch")
		end)
	end)

	helpers.it("uses the retained-instance backstop when the termination event is missed", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local quit_count = 0
			helpers.assert_true(guard.init(function() quit_count = quit_count + 1 end))

			launcher.running = false
			hs_stub.application.__remove_for_pid(LAUNCHER_PID)
			helpers.assert_true(#hs_stub.timer.__timers > 0,
				"the event watcher must have a low-frequency exact-instance backstop")
			hs_stub.timer.__timers[1]:fire()

			helpers.assert_eq(quit_count, 1,
				"a missed event must be recovered from the original app instance, without a shell")
		end)
	end)

	helpers.it("does not trust a new same-bundle process that reuses the launcher PID", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local original_launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, original_launcher)
			local quit_reasons = {}
			helpers.assert_true(guard.init(function(reason)
				quit_reasons[#quit_reasons + 1] = reason
			end))

			original_launcher.running = false
			hs_stub.application.__set_for_pid(
				LAUNCHER_PID, make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID))
			hs_stub.timer.__timers[1]:fire()

			helpers.assert_eq(quit_reasons[1], "launcher_missing",
				"the backstop must follow the retained process instance, not PID plus bundle")
			helpers.assert_eq(#hs_stub.application.__queries, 1,
				"a recurring check must never re-resolve and trust a reused PID")
		end)
	end)

	helpers.it("detaches before normal shutdown so launcher termination cannot run teardown twice", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local quit_count = 0
			helpers.assert_true(guard.init(function() quit_count = quit_count + 1 end))
			local watcher = hs_stub.application.watcher.__watchers[1]
			local backstop = hs_stub.timer.__timers[1]

			guard.stop()
			guard.stop()
			watcher.fn(nil, hs_stub.application.watcher.terminated, launcher)
			-- A runloop callback captured before :stop() may still execute once.
			backstop.fn()

			helpers.assert_eq(quit_count, 0,
				"normal shutdown must detach both loss paths before the launcher exits")
			helpers.assert_eq(watcher.stopped, 1,
				"idempotent stop must release the native watcher exactly once")
			helpers.assert_true(not backstop.running,
				"idempotent stop must release the recurring process-instance backstop")
		end)
	end)

	helpers.it("retains a watcher whose native stop fails and retries the exact handle", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local quit_count = 0
			helpers.assert_true(guard.init(function() quit_count = quit_count + 1 end))
			local watcher = hs_stub.application.watcher.__watchers[1]
			local real_stop = watcher.stop
			local stop_attempts = 0
			watcher.stop = function(self)
				stop_attempts = stop_attempts + 1
				if stop_attempts == 1 then return false end
				return real_stop(self)
			end

			helpers.assert_true(not guard.stop(),
				"an explicit native stop failure must keep local teardown retryable")
			watcher.fn(nil, hs_stub.application.watcher.terminated, launcher)
			helpers.assert_eq(quit_count, 0,
				"the retained watcher callback must already be logically fenced")
			helpers.assert_true(guard.stop(),
				"a later teardown pass must retry and release the same native watcher")
			helpers.assert_eq(stop_attempts, 2,
				"the failed watcher handle must not be dropped or replaced")
		end)
	end)

	helpers.it("retains a backstop timer whose native stop fails and retries the exact handle", function()
		with_guard(managed_environment(), function(guard, hs_stub)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local quit_count = 0
			helpers.assert_true(guard.init(function() quit_count = quit_count + 1 end))
			local backstop = hs_stub.timer.__timers[1]
			local real_stop = backstop.stop
			local stop_attempts = 0
			backstop.stop = function(self)
				stop_attempts = stop_attempts + 1
				if stop_attempts == 1 then return false end
				return real_stop(self)
			end

			helpers.assert_true(not guard.stop(),
				"an explicit native timer-stop failure must keep local teardown retryable")
			backstop.fn()
			helpers.assert_eq(quit_count, 0,
				"the retained timer callback must already be logically fenced")
			helpers.assert_true(guard.stop(),
				"a later teardown pass must retry and release the same native timer")
			helpers.assert_eq(stop_attempts, 2,
				"the failed timer handle must not be dropped or replaced")
		end)
	end)
end)





-- =======================================
-- =======================================
-- ======= 4/ Callback Containment =======
-- =======================================
-- =======================================

helpers.describe("launcher guard — callback containment", function()
	helpers.it("catches and file-logs an emergency callback throw exactly once", function()
		with_guard(managed_environment(), function(guard, hs_stub, log_lines)
			local launcher = make_app(LAUNCHER_PID, LAUNCHER_BUNDLE_ID)
			hs_stub.application.__set_for_pid(LAUNCHER_PID, launcher)
			local callback_count = 0
			helpers.assert_true(guard.init(function()
				callback_count = callback_count + 1
				error("teardown exploded")
			end))
			local watcher = hs_stub.application.watcher.__watchers[1]

			-- An escaping exception fails this test directly before any assertion
			watcher.fn("ErgoptiPlus", hs_stub.application.watcher.terminated, launcher)
			watcher.fn("ErgoptiPlus", hs_stub.application.watcher.terminated, launcher)
			helpers.assert_eq(callback_count, 1,
				"a throwing emergency callback must still consume the one-shot latch")
			local joined = table.concat(log_lines, "\n")
			helpers.assert_true(
				joined:find("Emergency quit callback raised", 1, true) ~= nil,
				"the swallowed async error must be routed to the central file logger"
			)
			helpers.assert_true(joined:find("teardown exploded", 1, true) ~= nil,
				"the file log must preserve the callback's actual error")
		end)
	end)
end)
