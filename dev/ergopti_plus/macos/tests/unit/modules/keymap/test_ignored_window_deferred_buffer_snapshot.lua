--- tests/unit/modules/keymap/test_ignored_window_deferred_buffer_snapshot.lua

--- ==============================================================================
--- MODULE: Regression — ignored-window deferred expansion snapshots the buffer
--- DESCRIPTION:
--- The deferred ignored-window expansion path in onKeyDownRaw captured the five
--- _tc_* upvalues into the doAfter(0) closure (H-19 fix), but still read
--- CoreState.buffer at execution time. A second rapid keystroke could append
--- more chars to the buffer between schedule and execution, causing the deferred
--- expansion to splice the wrong (later) buffer state.
---
--- The fix snapshots CoreState.buffer at schedule time into the closure and
--- temporarily swaps it in during execution. If no expansion fires the live
--- buffer (which may have grown) is restored. If an expansion DOES fire, any
--- chars typed after the snapshot are appended to the post-expansion buffer
--- so they are not lost (they remain on screen since the expansion only
--- backspaces over the trigger).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("ignored-window deferred expansion snapshots CoreState.buffer", function()
	helpers.it("the buffer snapshot is captured before doAfter(0) is scheduled", function()
		local fh = assert(io.open(helpers.driver_root() .. "/modules/keymap/init.lua", "r"))
		local src = fh:read("*a"); fh:close()

		-- Find the ignored-window branch.
		local ign_branch = src:find("if is_ignored then", 1, true)
		helpers.assert_true(ign_branch ~= nil, "could not find is_ignored branch")

		-- Find the doAfter(0) call that schedules the deferred expansion.
		local do_after = src:find("hs.timer.doAfter(0", ign_branch, true)
		helpers.assert_true(do_after ~= nil, "could not find hs.timer.doAfter(0) in ignored branch")

		-- The buffer snapshot must be captured BEFORE the doAfter call.
		local snapshot = src:find("local buf_snapshot = CoreState.buffer", ign_branch, true)
		helpers.assert_true(snapshot ~= nil, "could not find buf_snapshot capture")
		helpers.assert_true(snapshot < do_after,
			"buf_snapshot must be captured before hs.timer.doAfter(0)")

		-- The snapshot must be passed to the closure (appears in the IIFE argument list).
		-- Plain-text search (4th arg true), so the ")" must be literal, not the
		-- pattern escape "%)" — the escape would only match if plain were false.
		local iife_end = src:find("buf_snapshot)", do_after, true)
		helpers.assert_true(iife_end ~= nil,
			"buf_snapshot must be passed as an IIFE argument")
	end)

	helpers.it("the deferred closure swaps in the snapshot and restores on no-match", function()
		local fh = assert(io.open(helpers.driver_root() .. "/modules/keymap/init.lua", "r"))
		local src = fh:read("*a"); fh:close()

		-- Find the deferred closure body (after the doAfter scheduling).
		local do_after = src:find("hs.timer.doAfter(0", 1, true)
		helpers.assert_true(do_after ~= nil, "could not find hs.timer.doAfter(0)")

		-- The region after doAfter(0) should contain the closure body.
		local after_do = src:sub(do_after)

		-- The closure must save the live buffer before swapping.
		helpers.assert_true(after_do:find("local saved_buf = CoreState.buffer", 1, true) ~= nil,
			"saved_buf must be captured in the deferred closure")

		-- The closure must temporarily swap in the snapshot.
		helpers.assert_true(after_do:find("CoreState.buffer = buf", 1, true) ~= nil,
			"CoreState.buffer must be set to snapshot (buf) in the deferred closure")

		-- The closure must capture the return value so we know whether expansion fired.
		helpers.assert_true(after_do:find("local fired = run_trigger_checks()", 1, true) ~= nil,
			"run_trigger_checks return value must be captured")

		-- When no expansion fired, the live buffer must be restored.
		helpers.assert_true(after_do:find("if not fired then", 1, true) ~= nil,
			"restore guard (if not fired) must exist")
		helpers.assert_true(after_do:find("CoreState.buffer = saved_buf", 1, true) ~= nil,
			"live buffer must be restored when no expansion fires")

		-- When an expansion DID fire, extra chars typed after the snapshot
		-- must be appended to the post-expansion buffer.
		helpers.assert_true(after_do:find("else", 1, true) ~= nil,
			"else branch must exist for the expansion-fired case")
		helpers.assert_true(after_do:find("saved_buf:sub(#buf + 1)", 1, true) ~= nil,
			"extra chars must be extracted from saved_buf via sub")
		helpers.assert_true(after_do:find("CoreState.buffer = CoreState.buffer .. extra", 1, true) ~= nil,
			"extra chars must be appended to post-expansion buffer")
	end)

	helpers.it("the snapshot is taken from CoreState.buffer (not a copy of _tc_* upvalues)", function()
		local fh = assert(io.open(helpers.driver_root() .. "/modules/keymap/init.lua", "r"))
		local src = fh:read("*a"); fh:close()

		-- Verify the snapshot source is CoreState.buffer, not a derived value.
		local snapshot_line = src:find("local buf_snapshot = CoreState.buffer", 1, true)
		helpers.assert_true(snapshot_line ~= nil,
			"buf_snapshot must be assigned CoreState.buffer directly")

		-- The IIFE must receive buf_snapshot as the 6th argument (after chars, len, dt, mult, ign).
		local iife_start = src:find("(function(chars, len, dt, mult, ign, buf)", 1, true)
		helpers.assert_true(iife_start ~= nil,
			"IIFE must accept six parameters including buf")
	end)
end)
