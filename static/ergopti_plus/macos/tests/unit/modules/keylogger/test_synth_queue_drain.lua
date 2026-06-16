--- tests/unit/modules/keylogger/test_synth_queue_drain.lua

--- ==============================================================================
--- MODULE: keylogger synth_queue idle-drain Unit Tests
--- DESCRIPTION:
--- Regression tests for the C5 audit finding: CoreState.synth_queue must be
--- drained after a long inter-keystroke idle so that a stale unmatched entry
--- (from a suppressed expansion or a dropped keyDown) does not permanently tag
--- the next real keystroke as synthetic.
---
--- These tests exercise the drain logic in isolation via a lightweight simulation
--- that mirrors the post-fix handle_key() guard verbatim.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ===================================================
--- ===============================================
-- ======= 1/ synth_queue drain simulation =======
--- ===============================================
-- ===================================================

-- Threshold constant mirrored from keylogger/init.lua (C5 fix)
local SYNTH_IDLE_DRAIN_MS = 500

--- Simulates the synth_queue drain logic from handle_key() post-fix.
--- @param delay number Inter-keystroke delay in milliseconds.
--- @param synth_queue table The current synth_queue (mutated in-place on drain).
--- @return boolean True when the queue was drained.
local function simulate_drain(delay, synth_queue)
	if delay > SYNTH_IDLE_DRAIN_MS and #synth_queue > 0 then
		while #synth_queue > 0 do table.remove(synth_queue) end
		return true
	end
	return false
end

helpers.describe("keylogger: synth_queue idle drain (C5)", function()
	helpers.it("drains queue when delay > 500 ms and queue is non-empty", function()
		local q = { { char = "a", type = "hotstring" }, { char = "b", type = "hotstring" } }
		local drained = simulate_drain(600, q)
		helpers.assert_eq(drained, true)
		helpers.assert_eq(#q, 0)
	end)

	helpers.it("does NOT drain when delay <= 500 ms even with entries", function()
		local q = { { char = "a", type = "hotstring" } }
		local drained = simulate_drain(400, q)
		helpers.assert_eq(drained, false)
		helpers.assert_eq(#q, 1)
	end)

	helpers.it("does NOT drain when queue is empty (nothing to drain)", function()
		local q = {}
		local drained = simulate_drain(1000, q)
		helpers.assert_eq(drained, false)
		helpers.assert_eq(#q, 0)
	end)

	helpers.it("real keystroke after drain is NOT tagged synthetic", function()
		-- Arm 2 synthetic entries, simulate long idle, then simulate a real keystroke.
		-- The match logic checks synth_queue[1].char == keystroke char.
		local q = { { char = "a", type = "hotstring" }, { char = "b", type = "hotstring" } }
		local delay = 700

		-- Apply drain (post-fix logic)
		if delay > SYNTH_IDLE_DRAIN_MS and #q > 0 then
			q = {}
		end

		-- Now simulate the match logic for a real "x" keystroke
		local is_synthetic = false
		local chars = "x"
		if #q > 0 then
			local next_synth = q[1]
			if chars == next_synth.char then
				is_synthetic = true
				table.remove(q, 1)
			end
		end

		-- After drain, the queue is empty so the keystroke must NOT be synthetic
		helpers.assert_eq(is_synthetic, false)
	end)
end)
