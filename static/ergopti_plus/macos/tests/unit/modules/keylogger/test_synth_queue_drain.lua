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
-- ===============================================
-- ======= 1/ synth_queue drain simulation =======
-- ===============================================
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





-- ================================================================
-- ===============================================================
-- ======= 2/ fast-path synth_queue pop (keylogger-core-1) =======
-- ===============================================================
-- ================================================================

-- Threshold constant mirrored from keylogger/init.lua
local SYNTH_MATCH_DELAY_MS = 80

--- Simulates the synth_queue fast-path match logic from handle_key() post-fix.
--- @param chars string The keystroke character(s).
--- @param delay number Inter-keystroke delay in milliseconds.
--- @param synth_queue table The current synth_queue (mutated in-place on match/pop).
--- @return boolean, string Whether the keystroke is synthetic and its type.
local function simulate_synth_match(chars, delay, synth_queue)
	local is_synthetic = false
	local synth_type   = "unknown"
	if #synth_queue > 0 then
		local next_synth = synth_queue[1]
		if chars == next_synth.char then
			is_synthetic = true
			synth_type   = next_synth.type
			table.remove(synth_queue, 1)
		elseif delay < SYNTH_MATCH_DELAY_MS then
			is_synthetic = true
			synth_type   = next_synth.type
			-- Post-fix: pop even on char-mismatch fast-path
			table.remove(synth_queue, 1)
		end
	end
	return is_synthetic, synth_type
end

helpers.describe("keylogger: fast-path synth_queue pop (keylogger-core-1)", function()

	helpers.it("fast-path char-mismatch pops head entry (regression)", function()
		-- Before fix: fast-path would NOT pop the queue — head would re-match every
		-- subsequent fast keystroke until a 500 ms gap cleared the queue.
		local q = { { char = "X", type = "hotstring" }, { char = "Y", type = "hotstring" } }
		local is_syn, _ = simulate_synth_match("Z", 5, q)
		helpers.assert_eq(is_syn, true,
			"fast-path char-mismatch must still be marked synthetic")
		helpers.assert_eq(#q, 1,
			"fast-path must pop the head entry even on a char-mismatch")
		helpers.assert_eq(q[1].char, "Y",
			"remaining queue head must be the second entry after pop")
	end)

	helpers.it("exact-match still pops head entry (non-regression)", function()
		local q = { { char = "A", type = "hotstring" }, { char = "B", type = "hotstring" } }
		local is_syn, _ = simulate_synth_match("A", 5, q)
		helpers.assert_eq(is_syn, true,  "exact-match must be synthetic")
		helpers.assert_eq(#q, 1,         "exact-match must pop one entry")
	end)

	helpers.it("slow mismatch does NOT pop and is not synthetic", function()
		local q = { { char = "X", type = "hotstring" } }
		local is_syn, _ = simulate_synth_match("Z", 300, q)
		helpers.assert_eq(is_syn, false, "slow mismatch must NOT be synthetic")
		helpers.assert_eq(#q, 1,         "slow mismatch must NOT pop the queue")
	end)

	helpers.it("second fast keystroke uses the next entry after pop", function()
		-- With the fix: keystroke 1 (fast, char-mismatch) pops entry 1.
		-- Keystroke 2 (exact match for char Y) should find entry 2 at the head.
		local q = { { char = "X", type = "hotstring" }, { char = "Y", type = "hotstring" } }
		simulate_synth_match("Z", 5, q)    -- keystroke 1: fast mismatch → pops X
		local is_syn2, _ = simulate_synth_match("Y", 5, q)  -- keystroke 2: exact match on Y
		helpers.assert_eq(is_syn2, true, "keystroke 2 must be synthetic via exact-match")
		helpers.assert_eq(#q, 0,         "both entries must have been popped")
	end)
end)
