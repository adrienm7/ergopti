--- tests/unit/modules/karabiner/test_layout_poll_lock_release.lua

--- ==============================================================================
--- MODULE: Regression — the layout fallback poll must release its pending guard
--- DESCRIPTION:
--- The Sequoia layout-change fallback poll guards against piling up concurrent
--- `defaults` reads with `_layout_poll_pending`. That flag had exactly ONE release
--- path: inside the completion callback of the async read. But the completion
--- callback is not guaranteed to fire at all —
---   * ShellRunner.spawn() returns a handle UNCONDITIONALLY. When the underlying
---     task constructor failed, the handle's start() only logs an error and
---     returns, so on_done is never invoked.
---   * task:start() can itself return false under fork pressure, which is not a
---     throw either — that variant logs nothing at all.
--- In both cases the flag latched true and the `if _layout_poll_pending then
--- return end` guard short-circuited EVERY subsequent tick for the life of the
--- session, silently killing the very fallback poll that exists because
--- hs.keycodes.inputSourceChanged is unreliable on Sequoia.
---
--- The correct sibling lives in the same file: _capsword_check_pending has FOUR
--- release paths, including a CAPSWORD_PROBE_TIMEOUT_SEC watchdog for a
--- started-but-hung process. This test mirrors that watchdog's coverage.
---
--- ROOT CAUSE ENCODED HERE (behavioural, not a source grep): a spawn whose
--- completion callback NEVER fires must not wedge the poll forever. The stubbed
--- handle below is exactly what a nil/unstartable task produces — start() and
--- terminate() exist, but on_done is dropped on the floor.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ============================================================================
-- ============================================================================
-- ======= 1/ Test harness ====================================================
-- ============================================================================
-- ============================================================================

--- Loads modules.karabiner.watchers with:
---   * a ShellRunner stub whose spawn() returns a handle that NEVER invokes
---     on_done (the nil/unstartable-task shape),
---   * a TimerScheduler stub capturing every armed watchdog so the test can fire
---     it on demand,
---   * an hs.timer.doEvery stub capturing the poll callback so the test can tick
---     the poll manually.
--- @return table watchers The loaded module.
--- @return table ctx {spawns=int, watchdogs=array, poll_cb=function|nil}.
local function load_watchers_with_dead_spawn()
	package.loaded["modules.karabiner.watchers"] = nil
	package.loaded["adapters.shell_runner"] = nil
	package.loaded["adapters.timer_scheduler"] = nil

	local ctx = { spawns = 0, terminates = 0, watchdogs = {}, poll_cb = nil }

	package.loaded["adapters.shell_runner"] = {
		spawn = function(_executable, _args, _on_done)
			ctx.spawns = ctx.spawns + 1
			-- Deliberately drop _on_done: this is precisely what the production
			-- adapter yields when the task could not be created or started.
			-- terminate() is counted rather than ignored, so the test can tell
			-- "stopped waiting for the read" apart from "reclaimed the read".
			return {
				start     = function() end,
				terminate = function() ctx.terminates = ctx.terminates + 1 end,
			}
		end,
		_active_tasks = {},
	}

	package.loaded["adapters.timer_scheduler"] = {
		after = function(_delay, fn)
			local handle = { fn = fn, cancelled = false }
			table.insert(ctx.watchdogs, handle)
			return handle
		end,
		cancel = function(handle)
			if type(handle) == "table" then handle.cancelled = true end
		end,
	}

	local watchers = helpers.load_with_stubs("modules.karabiner.watchers", {
		timer = {
			doEvery = function(_interval, fn)
				ctx.poll_cb = fn
				return { stop = function() end }
			end,
			doAfter           = function(_d, _fn) return { stop = function() end } end,
			secondsSinceEpoch = function() return 1000 end,
		},
		-- load_with_stubs replaces hs.keycodes wholesale, so this override must carry
		-- its own .map: watchers.lua resolves KEYCODE_F17_NAME at module load time via
		-- Keycodes.to_name(), which iterates hs.keycodes.map.
		keycodes = {
			inputSourceChanged = function() end,
			currentLayout      = function() return "ABC" end,
			map                = { f17 = 64 },
		},
		execute = function() return "", true end,
	})

	watchers.start_input_source_watcher(function() end)
	helpers.assert_true(type(ctx.poll_cb) == "function",
		"start_input_source_watcher must register a recurring poll callback")

	return watchers, ctx
end




-- ============================================================================
-- ============================================================================
-- ======= 2/ The watchdog releases a wedged poll =============================
-- ============================================================================
-- ============================================================================

helpers.describe("karabiner.watchers: layout poll guard is released when the read never completes", function()

	helpers.it("a second tick spawns again after the watchdog fires", function()
		local _watchers, ctx = load_watchers_with_dead_spawn()

		-- Tick 1: arms the guard and spawns a read whose callback will never fire.
		ctx.poll_cb()
		helpers.assert_eq(ctx.spawns, 1, "the first tick must spawn a layout read")

		-- Tick 2 while still pending: correctly swallowed by the guard.
		ctx.poll_cb()
		helpers.assert_eq(ctx.spawns, 1,
			"a tick while a read is genuinely in flight must not pile up a second spawn")

		-- Fire the watchdog if one was armed. Kept tolerant on purpose so the
		-- decisive assertion below is the OBSERVABLE wedge (the poll never spawning
		-- again), not the mere presence of a timer — pre-fix there is no watchdog at
		-- all and the guard is simply never released by anything.
		local watchdog = ctx.watchdogs[#ctx.watchdogs]
		if watchdog then watchdog.fn() end

		-- Tick 3: must spawn again. Against the pre-fix code this stays at 1 forever.
		ctx.poll_cb()
		helpers.assert_eq(ctx.spawns, 2,
			"after the watchdog releases the guard the poll must resume — otherwise the "
			.. "Sequoia layout-change fallback is dead for the rest of the session")
	end)

	helpers.it("terminates the abandoned read instead of only dropping the guard", function()
		local _watchers, ctx = load_watchers_with_dead_spawn()

		ctx.poll_cb()
		helpers.assert_eq(ctx.spawns, 1, "the first tick must spawn a layout read")
		helpers.assert_eq(ctx.terminates, 0, "nothing may be terminated while the read is in flight")

		local watchdog = ctx.watchdogs[#ctx.watchdogs]
		helpers.assert_true(watchdog ~= nil, "the poll must arm a watchdog for the in-flight read")
		watchdog.fn()

		helpers.assert_eq(ctx.terminates, 1,
			"the watchdog must terminate the read it gave up on. Releasing only the guard "
			.. "leaves the `defaults read` running AND pinned in ShellRunner._active_tasks — "
			.. "the pin exists to stop the GC collecting a live task, so an abandoned one is "
			.. "never reclaimed and every timeout leaks a process for the rest of the session")
	end)

	helpers.it("never terminates a read that already completed", function()
		local _watchers, ctx = load_watchers_with_dead_spawn()

		ctx.poll_cb()
		local watchdog = ctx.watchdogs[#ctx.watchdogs]
		helpers.assert_true(watchdog ~= nil, "a watchdog must be armed")

		-- Two watchdog firings in a row: the second must find no handle to kill.
		watchdog.fn()
		watchdog.fn()

		helpers.assert_eq(ctx.terminates, 1,
			"the handle reference must be cleared as it is terminated, so a second watchdog "
			.. "tick cannot terminate a handle twice — or, worse, kill the read a LATER tick "
			.. "has since started")
	end)

	helpers.it("keeps recovering on every subsequent failure, not just the first", function()
		local _watchers, ctx = load_watchers_with_dead_spawn()

		-- Three full failure cycles: a permanently-latching guard would stop at 1.
		for expected = 1, 3 do
			ctx.poll_cb()
			helpers.assert_eq(ctx.spawns, expected,
				"each watchdog release must allow exactly one more spawn attempt")
			local watchdog = ctx.watchdogs[#ctx.watchdogs]
			if watchdog then watchdog.fn() end
		end
	end)
end)




-- ============================================================================
-- ============================================================================
-- ======= 3/ The watchdog is cancelled on the happy path and on stop =========
-- ============================================================================
-- ============================================================================

helpers.describe("karabiner.watchers: layout poll watchdog lifecycle", function()

	helpers.it("is cancelled by a completing read so it cannot fire spuriously", function()
		package.loaded["modules.karabiner.watchers"] = nil
		package.loaded["adapters.shell_runner"] = nil
		package.loaded["adapters.timer_scheduler"] = nil

		local ctx = { spawns = 0, watchdogs = {}, poll_cb = nil }

		-- This spawn DOES complete, immediately and synchronously.
		package.loaded["adapters.shell_runner"] = {
			spawn = function(_executable, _args, on_done)
				ctx.spawns = ctx.spawns + 1
				return {
					start     = function() if on_done then on_done(0, "", "") end end,
					terminate = function() end,
				}
			end,
			_active_tasks = {},
		}
		package.loaded["adapters.timer_scheduler"] = {
			after = function(_delay, fn)
				local handle = { fn = fn, cancelled = false }
				table.insert(ctx.watchdogs, handle)
				return handle
			end,
			cancel = function(handle)
				if type(handle) == "table" then handle.cancelled = true end
			end,
		}

		local watchers = helpers.load_with_stubs("modules.karabiner.watchers", {
			timer = {
				doEvery = function(_i, fn) ctx.poll_cb = fn; return { stop = function() end } end,
				doAfter = function(_d, _fn) return { stop = function() end } end,
				secondsSinceEpoch = function() return 1000 end,
			},
			keycodes = {
				inputSourceChanged = function() end,
				currentLayout      = function() return "ABC" end,
				map                = { f17 = 64 },
			},
			execute = function() return "", true end,
		})
		watchers.start_input_source_watcher(function() end)

		ctx.poll_cb()
		helpers.assert_eq(ctx.spawns, 1, "the tick must spawn a read")
		helpers.assert_true(ctx.watchdogs[1] ~= nil and ctx.watchdogs[1].cancelled,
			"a read that completes normally must cancel its watchdog — a stray timer "
			.. "firing later would clear the guard out from under a legitimate in-flight read")

		-- The guard was released by the completion callback, so the poll keeps running.
		ctx.poll_cb()
		helpers.assert_eq(ctx.spawns, 2, "a completed read must leave the poll free to tick again")
	end)

	helpers.it("is cancelled when the watcher is stopped", function()
		local watchers, ctx = load_watchers_with_dead_spawn()

		ctx.poll_cb()
		local watchdog = ctx.watchdogs[#ctx.watchdogs]
		helpers.assert_true(watchdog ~= nil, "a watchdog must have been armed")

		watchers.stop_input_source_watcher()

		helpers.assert_true(watchdog.cancelled,
			"stopping the watcher must cancel the in-flight read's watchdog so it cannot "
			.. "fire against a module that is no longer polling")
	end)
end)
