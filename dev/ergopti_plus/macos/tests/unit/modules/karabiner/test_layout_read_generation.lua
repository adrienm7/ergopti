--- tests/unit/modules/karabiner/test_layout_read_generation.lua

--- ==============================================================================
--- MODULE: Regression — a terminated layout read must not clobber the next one
---         (layout-read-generation)
--- DESCRIPTION:
--- Terminating a timed-out `defaults` read does not cancel its completion
--- callback: the OS still delivers the SIGTERM exit, moments later, by which
--- time the next poll tick has usually started read #2. That late callback then
--- ran against read #2's state and dismantled it — cleared its handle so the
--- watchdog had nothing left to terminate, released its pending guard so a third
--- read could pile on top, and cancelled its watchdog outright. The read that
--- was still running lost every protection it had, and the one thing that could
--- have recovered it was gone.
---
--- ROOT CAUSE ENCODED: the completion callback identified itself by nothing at
--- all. `_layout_poll_handle`, `_layout_poll_pending` and `_layout_poll_watchdog`
--- are single-slot module state shared by every read, so "the read that just
--- finished" and "the read currently in flight" were indistinguishable. Each
--- read now carries a generation stamp and a stale completion returns before
--- touching anything.
---
--- WHY IT WAS SILENT: the damage is invisible until the SECOND failure. Read #2
--- runs unwatched; if it also hangs, nothing releases the guard, and the Sequoia
--- fallback poll — the whole reason this code exists — stops for the session.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ============================================================================
-- ============================================================================
-- ======= 1/ Test harness ====================================================
-- ============================================================================
-- ============================================================================

--- Loads modules.karabiner.watchers with a ShellRunner stub that CAPTURES each
--- spawn's completion callback, so the test can deliver a terminated read's exit
--- late — exactly as the OS does.
--- @return table watchers, table ctx
local function load_watchers()
	package.loaded["modules.karabiner.watchers"] = nil
	package.loaded["adapters.shell_runner"] = nil
	package.loaded["adapters.timer_scheduler"] = nil

	local ctx = { spawns = {}, watchdogs = {}, poll_cb = nil }

	package.loaded["adapters.shell_runner"] = {
		spawn = function(_executable, _args, on_done)
			local rec = { on_done = on_done, terminated = 0, started = false }
			rec.handle = {
				start     = function() rec.started = true end,
				terminate = function() rec.terminated = rec.terminated + 1 end,
			}
			table.insert(ctx.spawns, rec)
			return rec.handle
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
		-- load_with_stubs replaces hs.keycodes wholesale, so this override must
		-- carry its own .map: watchers.lua resolves KEYCODE_F17_NAME at load time
		-- via Keycodes.to_name(), which iterates hs.keycodes.map.
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
-- ======= 2/ A superseded completion touches nothing =========================
-- ============================================================================
-- ============================================================================

helpers.describe("layout poll: a terminated read's late exit cannot dismantle the next read", function()
	helpers.it("leaves the in-flight read's watchdog, guard and handle intact", function()
		local _watchers, ctx = load_watchers()

		-- Read #1 starts and times out. The watchdog terminates it and releases
		-- the guard so the next tick may retry.
		ctx.poll_cb()
		helpers.assert_eq(#ctx.spawns, 1, "the first tick must start a read")
		helpers.assert_eq(#ctx.watchdogs, 1, "and arm a watchdog for it")
		ctx.watchdogs[1].fn()
		helpers.assert_true(ctx.spawns[1].terminated >= 1,
			"the timeout must terminate the abandoned read, not merely stop waiting for it")

		-- Read #2 starts on the next tick.
		ctx.poll_cb()
		helpers.assert_eq(#ctx.spawns, 2, "the released guard must let the next tick retry")
		helpers.assert_eq(#ctx.watchdogs, 2, "read #2 must arm its own watchdog")
		local watchdog_2 = ctx.watchdogs[2]

		-- The OS now delivers read #1's exit — a terminated process still reports
		-- its exit code, just late.
		helpers.assert_eq(type(ctx.spawns[1].on_done), "function",
			"the harness must hold read #1's completion callback, or this test proves nothing")
		ctx.spawns[1].on_done(143, "", "")

		helpers.assert_true(not watchdog_2.cancelled,
			"read #1's late exit must not cancel read #2's watchdog. Cancelled, read #2 runs "
				.. "with no timeout at all: if it hangs, nothing releases the pending guard and "
				.. "the Sequoia fallback poll stops for the rest of the session")

		-- The guard must still be held by read #2: a further tick must not spawn.
		ctx.poll_cb()
		helpers.assert_eq(#ctx.spawns, 2,
			"read #1's late exit must not release read #2's pending guard — that is the guard "
				.. "whose entire purpose is to stop concurrent `defaults` reads piling up")

		-- And read #2 must still be reclaimable: its handle must not have been
		-- cleared by the stale completion.
		watchdog_2.fn()
		helpers.assert_true(ctx.spawns[2].terminated >= 1,
			"read #2's own watchdog must still be able to terminate it. If the stale completion "
				.. "cleared the handle, the timeout can only stop waiting — and the subprocess "
				.. "and its GC pin leak for the rest of the session")
	end)

	helpers.it("the current read's completion still works normally", function()
		local _watchers, ctx = load_watchers()

		ctx.poll_cb()
		helpers.assert_eq(#ctx.spawns, 1, "a read must start")
		ctx.spawns[1].on_done(0, "", "")

		-- With the guard released by its OWN completion, the next tick must run.
		ctx.poll_cb()
		helpers.assert_eq(#ctx.spawns, 2,
			"a read that completes normally must still release the guard. A generation check "
				.. "that rejected the CURRENT read too would wedge the poll permanently — the "
				.. "exact failure the watchdog was added to prevent")
		helpers.assert_true(ctx.watchdogs[1].cancelled,
			"and it must still cancel its own watchdog, so a completed read cannot be "
				.. "'terminated' seconds later")
	end)
end)

-- Restore the real adapters for later test files: the stubs installed above
-- (a shell_runner that never execs, a fake timer_scheduler) would otherwise leak
-- through package.loaded into whichever module the runner loads next, and the
-- failure surfaces as an order-dependent crash — green locally, red in CI.
package.loaded["adapters.shell_runner"] = nil
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["modules.karabiner.watchers"] = nil
