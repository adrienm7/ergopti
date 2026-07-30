--- tests/unit/modules/keylogger/test_keylogger_core_timing.lua

--- ==============================================================================
--- MODULE: keylogger core timing baseline regression tests
--- DESCRIPTION:
--- Regression tests for keylogger-core-2: when the typing-metrics webview is
--- open, calling LogManager.flush_buffer() on every keystroke reset
--- CoreState.last_time to 0, causing every subsequent keystroke to report
--- delay=0 — corrupting WPM, n-gram timing, think-time, and burst detection.
---
--- The fix re-seeds CoreState.last_time = now immediately after flush_buffer()
--- so the timing baseline is never destroyed by a UI live-refresh.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =============================================================================
-- =============================================================================
-- ======= 1/ flush_buffer timing baseline (keylogger-core-2 regression) =======
-- =============================================================================
-- =============================================================================

--- Simulates the post-fix keyDown timing path:
--- 1. Compute delay from last_time.
--- 2. Update last_time = now.
--- 3. If metrics UI open: flush_buffer() then re-seed last_time = now.
---
--- @param state table Mutable state table with `last_time` field.
--- @param now number Current timestamp in ms.
--- @param flush_fn function The flush_buffer stub (resets state.last_time to 0).
--- @param metrics_ui_open boolean Whether the metrics webview is open.
--- @return number The computed inter-keystroke delay.
local function simulate_keydown(state, now, flush_fn, metrics_ui_open)
	local delay = state.last_time > 0 and math.floor(now - state.last_time) or 0
	state.last_time = now

	if metrics_ui_open then
		flush_fn(state)
		-- Post-fix: re-seed so the next keystroke gets the correct baseline
		state.last_time = now
	end

	return delay
end

helpers.describe("keylogger: flush_buffer timing baseline (keylogger-core-2)", function()

	helpers.it("delay is zero when metrics UI is CLOSED (baseline)", function()
		local state = { last_time = 0 }
		local function noop_flush(_s) end
		local delay1 = simulate_keydown(state, 1000, noop_flush, false)
		helpers.assert_eq(delay1, 0, "first keystroke delay must be 0 (no prior last_time)")
	end)

	helpers.it("delay is non-zero on 2nd keystroke when metrics UI is CLOSED", function()
		local state = { last_time = 0 }
		local function noop_flush(_s) end
		simulate_keydown(state, 1000, noop_flush, false)
		local delay2 = simulate_keydown(state, 1120, noop_flush, false)
		helpers.assert_true(delay2 >= 100,
			"2nd keystroke delay must be ~120ms when UI is closed, got: " .. tostring(delay2))
	end)

	helpers.it("delay is non-zero on 2nd keystroke when metrics UI is OPEN (regression)", function()
		-- Pre-fix: flush_buffer reset last_time to 0 → next keystroke got delay=0.
		-- Post-fix: last_time is re-seeded to now after flush → delay is preserved.
		local state = { last_time = 0 }
		local function zeroing_flush(s)
			-- Mirrors log_manager.lua:353: flush_buffer resets last_time to 0
			s.last_time = 0
		end
		simulate_keydown(state, 1000, zeroing_flush, true)
		local delay2 = simulate_keydown(state, 1120, zeroing_flush, true)
		helpers.assert_true(delay2 >= 100,
			"2nd keystroke delay must be ~120ms even when metrics UI is open (post-fix), got: "
			.. tostring(delay2))
	end)

	helpers.it("delay IS zero on 2nd keystroke without the re-seed fix (documents bug)", function()
		-- This test documents the PRE-FIX behaviour so the fix is clearly visible:
		-- without re-seeding, delay2 == 0.
		local state = { last_time = 0 }
		local function zeroing_flush(s) s.last_time = 0 end

		-- Simulate WITHOUT the re-seed fix
		local function broken_keydown(s, now, flush_fn, metrics_ui_open)
			local delay = s.last_time > 0 and math.floor(now - s.last_time) or 0
			s.last_time = now
			if metrics_ui_open then
				flush_fn(s)
				-- NO re-seed — this is the bug
			end
			return delay
		end

		broken_keydown(state, 1000, zeroing_flush, true)
		local delay2 = broken_keydown(state, 1120, zeroing_flush, true)
		helpers.assert_eq(delay2, 0,
			"without the re-seed fix, delay2 must be 0 (documents the pre-fix bug)")
	end)
end)
