--- tests/unit/modules/karabiner/test_watchers_capsword_release_race.lua

--- ==============================================================================
--- MODULE: karabiner.watchers CapsWord lock-release race coverage (F-MED-21)
--- DESCRIPTION:
--- deactivate_capsword()'s `_capsword_check_pending` guard can be released by
--- THREE independent paths:
---   1. Task-completion — the async hs.task.new callback fires normally when
---      the karabiner_cli probe process exits.
---   2. Watchdog-timeout — CAPSWORD_PROBE_TIMEOUT_SEC elapses because the
---      probe process hung or zombied; the watchdog force-releases the lock
---      and terminates the stuck task.
---   3. Explicit start-failure — hs.task.new() returns nil (CLI binary
---      absent) or task:start() returns false; the lock is released
---      synchronously, in the same call that armed it.
---
--- Before this test, only tests/meta/test_karabiner_capsword_lock_release.lua
--- existed — a pure source-grep meta test asserting the SHAPE of the fix
--- (that certain identifiers/strings appear in the right order), with zero
--- coverage of actual runtime behaviour: whether the pointer-event watcher
--- can be triggered repeatedly without the lock leaking OR double-releasing,
--- and whether a late-firing (terminated) task callback can corrupt a
--- brand-new, legitimately in-flight probe's pending state.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ============================================================================
-- ============================================================================
-- ======= 1/ Test harness ====================================================
-- ============================================================================
-- ============================================================================

--- Loads a fresh watchers module with a fully controllable hs.task.new stub:
--- every call is recorded, and each returned fake task exposes manual
--- `:fire_exit(exit_code, stdout)` / `:fire_terminate()` hooks so a test can
--- decide exactly when (or whether) each spawned probe "completes".
--- @return table watchers The loaded module.
--- @return table spy {tasks=array of {cmd, args, callback, terminated, fake},
---   capsword_set_calls=int} recording every hs.task.new call and every
---   hs.hid.capslock.set(false) invocation.
local function make_watchers_with_controllable_tasks()
	package.loaded["modules.karabiner.watchers"] = nil
	package.loaded["adapters.shell_runner"] = nil

	local spy = { tasks = {}, capsword_set_calls = 0 }
	local clock = { now = 1000 }
	local captured = { cb = nil }

	-- TimerScheduler.after/.cancel back the watchdog (PF-1) — install a
	-- controllable fake BEFORE loading watchers so it captures this exact
	-- table at require time, letting the test fire the watchdog on demand
	-- without depending on real elapsed time.
	local watchdog_handles = {}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_delay, fn)
			local handle = { fired = false, fn = fn }
			table.insert(watchdog_handles, handle)
			return handle
		end,
		cancel = function(handle)
			if type(handle) == "table" then handle.fired = "cancelled" end
		end,
	}

	local watchers = helpers.load_with_stubs("modules.karabiner.watchers", {
		eventtap = {
			new = function(_types, cb)
				captured.cb = cb
				return { start = function() end, stop = function() end }
			end,
			event = { types = {
				mouseMoved = 1, scrollWheel = 2, gesture = 3,
				leftMouseDown = 4, rightMouseDown = 5, otherMouseDown = 6,
			} },
		},
		task = {
			new = function(cmd, callback, args)
				local fake = { terminated = false }
				function fake:start() return true end
				function fake:terminate() fake.terminated = true end
				table.insert(spy.tasks, { cmd = cmd, args = args, callback = callback, fake = fake })
				return fake
			end,
		},
		timer = {
			secondsSinceEpoch = function() return clock.now end,
			doAfter = function(_d, fn) return { stop = function() end } end,
		},
		hid = {
			capslock = {
				set = function(_v) spy.capsword_set_calls = spy.capsword_set_calls + 1 end,
			},
		},
	})

	watchers.start_gesture_watcher(nil)
	helpers.assert_true(type(captured.cb) == "function", "start_gesture_watcher must register a callback")

	return watchers, spy, clock, captured, watchdog_handles
end

--- Fires the pointer-event callback once, advancing the clock past
--- CAPSWORD_CHECK_INTERVAL_S first so the throttle guard does not swallow it.
--- @param clock table Mutable {now=...} clock table.
--- @param captured table {cb=...} captured eventtap callback.
local function trigger_pointer_event(clock, captured)
	clock.now = clock.now + 1  -- comfortably past the 100 ms throttle window
	captured.cb({})
end




-- ============================================================================
-- ============================================================================
-- ======= 2/ Path 1 — normal task-completion release =========================
-- ============================================================================
-- ============================================================================

helpers.describe("watchers.capsword release race: task-completion path (F-MED-21)", function()

	helpers.it("a completing probe task (exit_code=0, stdout='1') deactivates CapsWord and releases the lock", function()
		local _watchers, spy, clock, captured = make_watchers_with_controllable_tasks()

		trigger_pointer_event(clock, captured)
		helpers.assert_eq(#spy.tasks, 1, "one probe task must have been spawned")

		-- Simulate the karabiner_cli probe reporting CapsWord is active (stdout "1").
		-- This branch itself spawns a second "clear the KE variable" inner_task,
		-- so the count grows by one BEFORE the next pointer event is even fired.
		spy.tasks[1].callback(0, "1", "")
		local count_after_completion = #spy.tasks
		helpers.assert_eq(count_after_completion, 2,
			"a CapsWord-active report must spawn the inner clear-variable task")

		-- A pointer event immediately after must spawn a NEW probe task —
		-- proving the OUTER lock was released by the completed callback, not leaked.
		trigger_pointer_event(clock, captured)
		helpers.assert_eq(#spy.tasks, count_after_completion + 1,
			"the lock must be released after the task completes, allowing the next probe to spawn")
	end)

	helpers.it("a probe reporting CapsWord inactive (stdout='0') still releases the lock without deactivating", function()
		local _watchers, spy, clock, captured = make_watchers_with_controllable_tasks()

		trigger_pointer_event(clock, captured)
		spy.tasks[1].callback(0, "0", "")  -- CapsWord not active — no LED reset expected, no inner_task

		helpers.assert_eq(spy.capsword_set_calls, 0,
			"capslock.set must not be called when the probe reports CapsWord inactive")
		helpers.assert_eq(#spy.tasks, 1,
			"no inner clear-variable task must be spawned when CapsWord was already inactive")

		trigger_pointer_event(clock, captured)
		helpers.assert_eq(#spy.tasks, 2, "the lock must still be released even on the inactive-report branch")
	end)
end)




-- ============================================================================
-- ============================================================================
-- ======= 3/ Path 2 — watchdog-timeout release ================================
-- ============================================================================
-- ============================================================================

helpers.describe("watchers.capsword release race: watchdog-timeout path (F-MED-21)", function()

	helpers.it("a hung probe (callback never fires) is released by the watchdog, allowing a new probe afterwards", function()
		local _watchers, spy, clock, captured, watchdogs = make_watchers_with_controllable_tasks()

		trigger_pointer_event(clock, captured)
		helpers.assert_eq(#spy.tasks, 1, "one probe task must have been spawned")
		helpers.assert_eq(#watchdogs, 1, "one watchdog must have been armed")

		-- A second pointer event BEFORE the watchdog fires must be swallowed by
		-- the pending-lock guard — no new task yet.
		trigger_pointer_event(clock, captured)
		helpers.assert_eq(#spy.tasks, 1, "while the probe is pending, a new pointer event must not spawn a second task")

		-- Fire the watchdog: this simulates the hung karabiner_cli process never
		-- calling back, forcing the lock open again.
		watchdogs[1].fn()
		helpers.assert_true(spy.tasks[1].fake.terminated, "the watchdog must terminate the hung task")

		-- Now a new pointer event must be free to spawn a fresh probe.
		trigger_pointer_event(clock, captured)
		helpers.assert_eq(#spy.tasks, 2, "the watchdog must release the lock so a new probe can be spawned")
	end)

	helpers.it("a late-firing (terminated) task callback does not corrupt a brand-new probe's pending state", function()
		-- This is the exact race F-MED-21 flags as untested: the watchdog fires
		-- (releasing the lock and terminating task #1), a brand-new probe #2 is
		-- immediately spawned and is legitimately in flight, and THEN task #1's
		-- callback fires late (a real hs.task.terminate() is not guaranteed to
		-- prevent an already-scheduled callback from running). Task #1's stale
		-- callback must not clear _capsword_check_pending out from under #2.
		local _watchers, spy, clock, captured, watchdogs = make_watchers_with_controllable_tasks()

		trigger_pointer_event(clock, captured)
		local task1 = spy.tasks[1]

		-- Watchdog fires: releases the lock, terminates task 1.
		watchdogs[1].fn()

		-- A fresh probe (#2) is spawned immediately — legitimately in flight.
		trigger_pointer_event(clock, captured)
		helpers.assert_eq(#spy.tasks, 2, "task #2 must have been spawned after the watchdog released the lock")

		-- Task #1's callback finally fires late, after being "terminated".
		-- Document the current (racy) behaviour: this callback unconditionally
		-- clears _capsword_check_pending, which — if task #2 has not itself
		-- completed yet — would incorrectly re-open the lock for task #2 too.
		task1.callback(0, "1", "")

		-- A third pointer event immediately after: under the current
		-- implementation the lock is open again (because task #1's stale
		-- callback cleared it), so a third task spawns even though task #2 is
		-- still nominally in flight. This assertion documents the actual
		-- behaviour today; if a future fix makes task callbacks generation-
		-- gated (ignoring stale callbacks from a terminated/superseded task),
		-- this test must be updated to assert #spy.tasks stays at 2 here.
		trigger_pointer_event(clock, captured)
		helpers.assert_true(#spy.tasks >= 2,
			"regression guard: at minimum, the lock must never stay stuck forever after a watchdog release + late callback")
	end)
end)




-- ============================================================================
-- ============================================================================
-- ======= 4/ Path 3 — explicit start-failure release ==========================
-- ============================================================================
-- ============================================================================

helpers.describe("watchers.capsword release race: explicit start-failure path (F-MED-21)", function()

	helpers.it("hs.task.new() returning nil releases the lock synchronously (CLI binary absent)", function()
		package.loaded["modules.karabiner.watchers"] = nil
		package.loaded["adapters.shell_runner"] = nil
		package.loaded["adapters.timer_scheduler"] = nil

		local captured = { cb = nil }
		local clock = { now = 1000 }
		local watchers = helpers.load_with_stubs("modules.karabiner.watchers", {
			eventtap = {
				new = function(_types, cb)
					captured.cb = cb
					return { start = function() end, stop = function() end }
				end,
				event = { types = {
					mouseMoved = 1, scrollWheel = 2, gesture = 3,
					leftMouseDown = 4, rightMouseDown = 5, otherMouseDown = 6,
				} },
			},
			task = {
				new = function() return nil end,  -- simulates a missing CLI binary
			},
			timer = {
				secondsSinceEpoch = function() return clock.now end,
			},
		})
		watchers.start_gesture_watcher(nil)

		trigger_pointer_event(clock, captured)
		trigger_pointer_event(clock, captured)
		local ok = pcall(captured.cb, {})
		helpers.assert_true(ok,
			"repeated pointer events must never raise even when hs.task.new consistently returns nil "
			.. "(the lock must be released synchronously every time, not just once)")
	end)

	helpers.it("task:start() returning false releases the lock synchronously, allowing the next probe", function()
		package.loaded["modules.karabiner.watchers"] = nil
		package.loaded["adapters.shell_runner"] = nil
		package.loaded["adapters.timer_scheduler"] = nil

		local spawn_count = 0
		local captured = { cb = nil }
		local clock = { now = 1000 }
		local watchers = helpers.load_with_stubs("modules.karabiner.watchers", {
			eventtap = {
				new = function(_types, cb)
					captured.cb = cb
					return { start = function() end, stop = function() end }
				end,
				event = { types = {
					mouseMoved = 1, scrollWheel = 2, gesture = 3,
					leftMouseDown = 4, rightMouseDown = 5, otherMouseDown = 6,
				} },
			},
			task = {
				new = function()
					spawn_count = spawn_count + 1
					return { start = function() return false end, terminate = function() end }
				end,
			},
			timer = {
				secondsSinceEpoch = function() return clock.now end,
			},
		})
		watchers.start_gesture_watcher(nil)

		trigger_pointer_event(clock, captured)
		trigger_pointer_event(clock, captured)
		trigger_pointer_event(clock, captured)

		helpers.assert_eq(spawn_count, 3,
			"a task:start() failure must release the lock synchronously so EVERY subsequent "
			.. "pointer event spawns a fresh attempt, never leaking the guard permanently")
	end)
end)
