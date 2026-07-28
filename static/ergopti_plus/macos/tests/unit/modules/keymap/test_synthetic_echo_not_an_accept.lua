--- tests/unit/modules/keymap/test_synthetic_echo_not_an_accept.lua

--- ==============================================================================
--- MODULE: Regression — our own synthetic echo must not accept a prediction
---         (synthetic-echo-not-an-accept)
--- DESCRIPTION:
--- An expansion could inject LLM text into the middle of itself.
---
--- ROOT CAUSE ENCODED: the terminator re-type posts a REAL Return or Tab, and
--- that event comes straight back through the keymap tap. handle_llm_keys runs
--- before any synthetic-echo filtering, so with predictions on screen it read
--- our own echo as the user accepting one — and typed the completion into the
--- middle of the replacement still being emitted.
---
--- The synthetic-Delete guard immediately above already had the answer: compare
--- the event's source PID against our own. The check is narrowed to the window
--- in which an expansion is still emitting, so a human Tab pressed at any other
--- moment routes normally — an unconditional PID filter would break accepting a
--- prediction from any Hammerspoon-injected key.
---
--- WHY IT WAS SILENT: everything reported success. The expansion completed, the
--- prediction was "accepted", and the log recorded both. Only the text on screen
--- was wrong — two overlapping insertions that no single component considered a
--- failure.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================================
-- ================================================================
-- ======= 1/ The routing is gated on event provenance ============
-- ================================================================
-- ================================================================

helpers.describe("keymap: an LLM accept key is not routed from our own echo", function()
	helpers.it("checks the source PID before routing to handle_llm_keys", function()
		local src = helpers.read_driver_source("handle_llm_keys")
		helpers.assert_true(src ~= nil and src ~= "", "the keymap tap must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("LLMBridge.handle_llm_keys", 1, true)
		helpers.assert_true(at ~= nil, "the LLM key routing must still exist")

		-- The routing must carry its OWN gate. A wide lookback would be satisfied
		-- by the synthetic-Delete guard further up, which has always had a PID
		-- check and says nothing about whether this call site is protected.
		local guard_at = code:find("if not is_own_event then", 1, true)
		helpers.assert_true(guard_at ~= nil,
			"the routing must be gated on where the event came from. The terminator re-type "
				.. "posts a real Return or Tab that arrives back through this tap, and with "
				.. "predictions on screen it was read as the user accepting one — injecting the "
				.. "completion into the middle of the expansion still being typed")
		helpers.assert_true(guard_at < at and (at - guard_at) < 200,
			"and that gate must sit immediately before the routing call, not somewhere else in "
				.. "the tap")

		local decl_at = code:find("local is_own_event", 1, true)
		helpers.assert_true(decl_at ~= nil, "the provenance test must be computed")
		local decl = code:sub(decl_at, decl_at + 300)
		helpers.assert_true(decl:find("event_is_ours()", 1, true) ~= nil,
			"through the shared provenance probe — the same answer the synthetic-Delete guard "
				.. "needs, so it is resolved once per keystroke rather than read twice")

		-- And that probe must actually compare against our own process, not just
		-- exist: a helper that returned a constant would satisfy every check above.
		local probe_at = code:find("local function event_is_ours", 1, true)
		helpers.assert_true(probe_at ~= nil, "the shared probe must exist")
		local probe = code:sub(probe_at, probe_at + 400)
		helpers.assert_true(probe:find("eventSourceUnixProcessID", 1, true) ~= nil
			and probe:find("hs.processInfo.processID", 1, true) ~= nil,
			"the probe must compare the event's source against our OWN process id")
		helpers.assert_true(probe:find("_event_is_ours == nil", 1, true) ~= nil,
			"and memoise it: this is the hottest path in the driver and the property read is an "
				.. "ObjC round-trip, so it must not be paid twice per keystroke")
	end)

	helpers.it("the gate is narrowed to the emitting window", function()
		local src = helpers.read_driver_source("handle_llm_keys")
		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("LLMBridge.handle_llm_keys", 1, true)

		local before = code:sub(math.max(1, at - 700), at)
		helpers.assert_true(before:find("expected_synthetic_chars", 1, true) ~= nil
			or before:find("expected_synthetic_pastes", 1, true) ~= nil,
			"the filter must apply only while an expansion is still emitting. An unconditional "
				.. "PID test would also reject a genuine accept driven by any other "
				.. "Hammerspoon-injected key, turning a mis-accept into a dead feature")
	end)
end)





-- ================================================================
-- =================================================================
-- ======= 2/ The debounce callback reports its own failures =======
-- =================================================================
-- ================================================================

helpers.describe("prediction engine: the debounce callback is guarded", function()
	helpers.it("reports a throw through the logger, not the console", function()
		local src = helpers.read_driver_source("_inactivity_timer")
		helpers.assert_true(src ~= nil and src ~= "", "the prediction engine must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("hs.timer.delayed.new", 1, true)
		helpers.assert_true(at ~= nil, "the debounce timer must still be created")

		local body = code:sub(at, at + 600)
		helpers.assert_true(body:find("xpcall", 1, true) ~= nil,
			"this is the single entry point for EVERY debounced prediction. An unhandled throw "
				.. "reaches Hammerspoon's own handler, which the runtime capture persists only as "
				.. "an anonymous [CONSOLE] line — no module, no level, no context — while the "
				.. "prediction for that keystroke is simply gone")
		helpers.assert_true(body:find("Logger.error", 1, true) ~= nil,
			"and it must report through the logger, or the xpcall merely relocates the silence")
	end)
end)
