--- tests/unit/modules/keymap/test_preview_telemetry_off_hid_thread.lua

--- ==============================================================================
--- MODULE: Regression — BOTH hotstring telemetry writers stay off the HID thread
--- DESCRIPTION:
--- The preview path emits two telemetry events: `log_hotstring_suggested` when a
--- hotstring preview appears, and `log_hotstring_dismissed` when it goes away.
--- Both end in an open/write/flush on the keylogger's rotating log, and both used
--- to run inside the keyDown eventtap callback — the one callback whose overrun
--- makes macOS disable the tap outright.
---
--- One of them was moved off the HID thread and the other was not, because the
--- deferral was applied PER CALL SITE instead of at the sink. This guard is
--- therefore over the whole class: every telemetry write from this module, not the
--- one that was reported.
---
--- ROOT CAUSE ENCODED:
--- The pcall is load-bearing for a second reason that has nothing to do with
--- latency, and the assertion covers it too. `reset_predictions` emits the dismiss
--- event and THEN clears `last_shown_hotstring` and calls `engine.reset()`. A
--- throw in the writer skipped both, leaving the tooltip state and the engine
--- live, so every later reset re-emitted the same stale dismiss event. On the
--- keyDown and mouse paths that throw is at least logged; the Escape trap calls
--- reset_predictions with no pcall of its own, so there it was silent as well.
---
--- PROVENANCE: this is a source invariant, not a behavioural one.
--- `last_shown_hotstring` is a module-local written only from deep inside
--- update_preview, so driving the dismiss path end to end would mean
--- reconstructing the whole preview pipeline. What makes it discriminating anyway
--- is that it checks BOTH conditions at EVERY site — a deferral wrapping one call
--- and not the other is exactly the state the driver shipped in, and it is what a
--- single-site grep could not see.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The module under test is located by a symbol rather than a path, so the guard
-- survives a file move (and satisfies the pinned-read ratchet).
local ANCHOR = "last_shown_hotstring"

-- Every telemetry writer the preview path reaches.
local TELEMETRY_CALLS = {
	"keylogger.log_hotstring_suggested",
	"keylogger.log_hotstring_dismissed",
}

-- How far back from a call the shared deferral helper may sit. The compliant form is
--   schedule_prediction_deferred("telemetry label", function()
--       pcall(keylogger.log_hotstring_x, …)
-- so the helper is on the previous line: one short line of slack, not enough to
-- let an unrelated deferral elsewhere in the function count.
local DEFERRAL_LOOKBACK = 120




-- ==================================================================
-- ==================================================================
-- ======= 1/ Every telemetry write is deferred and guarded =========
-- ==================================================================
-- ==================================================================

helpers.describe("preview telemetry: no hotstring log write runs on the HID thread", function()

	helpers.it("every telemetry call is deferred AND pcall-wrapped", function()
		local src = helpers.read_driver_source(ANCHOR)
		helpers.assert_true(src ~= nil and src ~= "",
			"the LLM bridge must be locatable by '" .. ANCHOR .. "'; an empty corpus would "
			.. "make every assertion below vacuous")

		-- Comments stripped so the prose above and in the module — which names both
		-- calls — cannot be mistaken for a call site.
		local code = src:gsub("%-%-[^\n]*", "")

		local sites, offenders = 0, {}
		for _, call in ipairs(TELEMETRY_CALLS) do
			local from = 1
			while true do
				local at = code:find(call, from, true)
				if not at then break end
				sites = sites + 1

				-- Condition 1: the call is an ARGUMENT to pcall, not a direct call. A
				-- throw here skips the state cleanup that follows it.
				local guarded = code:sub(math.max(1, at - 7), at - 1):find("pcall(", 1, true) ~= nil

				-- Condition 2: it sits inside the shared owned deferral, so the write
				-- happens on the next runloop turn instead of inside the tap callback.
				local window = code:sub(math.max(1, at - DEFERRAL_LOOKBACK), at)
				local deferred = window:find("schedule_prediction_deferred(", 1, true) ~= nil

				if not guarded or not deferred then
					local why = (not deferred and "not deferred" or "")
						.. ((not deferred and not guarded) and " + " or "")
						.. (not guarded and "not pcall-wrapped" or "")
					table.insert(offenders, call .. " (" .. why .. ")")
				end
				from = at + 1
			end
		end

		helpers.assert_true(sites >= 2,
			"both telemetry writers must still exist; found " .. sites .. ". A rename would "
			.. "otherwise make the assertion below pass over a module that logs nothing")

		helpers.assert_eq(#offenders, 0,
			"a hotstring telemetry write ends in a synchronous file write, and running it "
			.. "inside the keyDown callback is what makes macOS disable the typing tap. The "
			.. "pcall is not optional either: a throw skips the last_shown_hotstring clear "
			.. "and engine.reset() that follow it, so every later reset re-emits the same "
			.. "stale event: " .. table.concat(offenders, ", "))
	end)

	helpers.it("the detector rejects a bare call and accepts the compliant form", function()
		-- Positive control. Without it a typo in either condition would make the
		-- assertion above pass over both sites — the vacuous absence assertion this
		-- suite tracks as a false-green class.
		local BARE = 'keylogger.log_hotstring_dismissed(nil, a, b, c)\n'
		local COMPLIANT = 'schedule_prediction_deferred("dismiss telemetry", function()\n'
			.. '\t\t\tpcall(keylogger.log_hotstring_dismissed, nil, a, b, c)\n'
		-- Deferred but NOT guarded: the latency is fixed and the state corruption
		-- is not, which is a distinct and equally real defect.
		local HALF = 'schedule_prediction_deferred("dismiss telemetry", function()\n'
			.. '\t\t\tkeylogger.log_hotstring_dismissed(nil, a, b, c)\n'

		--- Mirrors the classifier above on a snippet.
		--- @param code string
		--- @return boolean compliant
		local function compliant(code)
			local at = code:find("keylogger.log_hotstring_dismissed", 1, true)
			if not at then return false end
			local guarded = code:sub(math.max(1, at - 7), at - 1):find("pcall(", 1, true) ~= nil
			local window  = code:sub(math.max(1, at - DEFERRAL_LOOKBACK), at)
			local deferred = window:find("schedule_prediction_deferred(", 1, true) ~= nil
			return guarded and deferred
		end

		helpers.assert_true(not compliant(BARE), "a bare synchronous call must be rejected")
		helpers.assert_true(not compliant(HALF),
			"deferred but unguarded must be rejected too: the state cleanup after the call "
			.. "is what a throw would skip")
		helpers.assert_true(compliant(COMPLIANT),
			"and the compliant form must be accepted, or the guard would forbid its own fix")
	end)

	helpers.it("the shared prediction deferral owns a zero-delay scheduler capability", function()
		local src = helpers.read_driver_source(ANCHOR)
		helpers.assert_true(src ~= nil and src ~= "",
			"the LLM bridge must remain locatable by its preview ownership anchor")
		local code = src:gsub("%-%-[^\n]*", "")
		local helper_at = code:find("local function schedule_prediction_deferred", 1, true)
		local helper_end = helper_at and code:find("\nend", helper_at, true)
		helpers.assert_true(helper_at ~= nil and helper_end ~= nil,
			"the shared prediction deferral helper must remain bounded")
		local helper_body = code:sub(helper_at, helper_end)
		helpers.assert_true(helper_body:find("TimerScheduler.after(0, function()", 1, true) ~= nil,
			"the shared helper must keep preview telemetry off the HID callback")
	end)

end)
