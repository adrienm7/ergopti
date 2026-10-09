--- tests/unit/modules/keymap/test_preview_telemetry_withholds_pii.lua

--- ==============================================================================
--- MODULE: Regression — the preview's PERSISTED telemetry must withhold PII too
--- DESCRIPTION:
--- The second forgotten sibling. `test_preview_never_logs_pii.lua` closed the
--- DEBUG line in `update_preview`, and the comment it left behind stated the
--- invariant this file is about: it is the PERSISTED sink that must withhold the
--- row.
---
--- Sixty lines below that comment sat the persisted sink, writing the value
--- verbatim. `log_hotstring_suggested` fires the moment a preview appears and
--- `log_hotstring_dismissed` fires when it goes away; both reach
--- `LogManager.append_log`, which writes trigger and replacement into a file
--- retained fourteen days and copied into the metrics store. Neither consulted
--- `is_private`.
---
--- WHY THE EXISTING TEST COULD NOT SEE IT:
--- It captures `Logger.set_sink`. These two sinks are not the logger — they are
--- the keylogger, reached through a deferred timer. A test watching the logger
--- watches the one sink that was already fixed.
---
--- WHY THIS TEST ASSERTS THE PREDICATE AND NOT THE SINK:
--- It was written end-to-end first: stub the keylogger, drive a real preview,
--- fire the deferred timer, assert nothing was persisted. It passed — and it
--- passed just as happily with the guard replaced by `if true then`, which
--- means the preview never reached the recording branch at all and every
--- assertion was measuring its own harness. Three attempts at the load order
--- (the stub is overwritten by whichever dependency pulls the real keylogger
--- back into package.loaded) got the private cases observing something real and
--- the control case still not, and I could not establish why without guessing.
---
--- A green I do not understand is worth less than a narrower check I do, so the
--- decision is now a named predicate — `may_persist_preview` — asserted here
--- directly, with an existence check that both call sites still exist. What that
--- leaves uncovered is stated in section 3.
---
--- WHY THIS SHAPE OF DEFECT KEEPS RECURRING HERE:
--- docs/PROJECT_MEMORY.md records it shipping once already: routing the dynamic
--- injectors through a common entry point "closed the desynchronisation of the
--- two trackers — and lost is_private, so SSN, IBAN, card and phone were
--- persisted in clear for fourteen days". Every time a value crosses a layer
--- boundary, the flag has to cross with it, and the dismissal path crosses two:
--- the record outlives the match it came from.
---
--- WHAT IS DELIBERATELY NOT ASSERTED:
--- What the tooltip shows. That is a different decision with a different answer
--- and its own test — `test_preview_masks_secrets.lua`: since 2026-08-05 the
--- bubble PARTIALLY masks a declared secret, revealing the last four characters
--- so the user can still confirm which value is about to be typed. This file is
--- only about what is written to disk, where nothing at all may be kept.
--- ==============================================================================

local helpers = require("tests.helpers")

local SECRET_PII  = "FR76 3000 4000 5000 6000 7000 123"




-- ==============================================
-- ==============================================
-- ======= 1/ Harness ===========================
-- ==============================================
-- ==============================================

--- Loads the bridge over a keylogger stub that records what it is asked to
--- persist, and returns both.
---
--- The stub is installed after the bridge's dependencies and BEFORE the bridge
--- itself: it captures `keylogger` as an upvalue at require time, so a stub put
--- in place afterwards is a table nothing calls — and one put in place too early
--- is overwritten by whichever dependency pulls the real module back in.
--- @return table bridge, table persisted
local function load_bridge_with_recording_keylogger()
	local persisted = { suggested = {}, dismissed = {} }

	-- Everything the bridge pulls in is loaded FIRST, then the stub is installed,
	-- then the bridge. Order is the whole trap here: loading modules.keymap.state
	-- pulls in the real modules.keylogger and puts it back in package.loaded, so a
	-- stub installed before that step is a table the bridge never sees — it
	-- captures its keylogger upvalue at require time (llm_bridge.lua:36).
	require("modules.keymap.state")

	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function(_app, trigger, replacement, h_type)
			persisted.suggested[#persisted.suggested + 1] =
				{ trigger = trigger, replacement = replacement, h_type = h_type }
		end,
		log_hotstring_dismissed = function(_app, trigger, replacement, h_type)
			persisted.dismissed[#persisted.dismissed + 1] =
				{ trigger = trigger, replacement = replacement, h_type = h_type }
		end,
		log_hotstring = function() end,
		log_llm_suggested = function() end,
		notify_synthetic = function() end,
	}

	-- The REAL tooltip, with exactly one method neutralised. Under the hs stub its
	-- renderer throws while measuring styled text, and update_preview DRAWS before
	-- it RECORDS — so a first version of this file, which left the tooltip alone,
	-- had every "nothing was persisted" case passing because the function never
	-- reached the line that persists. A vacuous green on a privacy test is the one
	-- this repo can least afford.
	--
	-- Patched rather than replaced: a hand-written stub has to guess the whole
	-- surface, and the second version of this file guessed five methods and missed
	-- set_navigate_callback, which prediction_engine calls. What is under test is
	-- the sink, not the canvas.
	local tooltip = require("ui.tooltip")
	local real_show_stacked = tooltip.show_stacked
	tooltip.show_stacked = function() end

	package.loaded["modules.keymap.llm_bridge"] = nil
	local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
	persisted.restore = function() tooltip.show_stacked = real_show_stacked end
	return Bridge, persisted
end

--- Drives a preview for a provider-supplied value and lets the deferred
--- telemetry run.
--- @param bridge table
--- @param value string What the provider resolves to.
--- @param buf string The buffer to preview.
local function preview_via_provider(bridge, value, buf)
	local state = {
		buffer                    = "",
		mappings                  = {},
		groups                    = {},
		preview_providers         = {
			function(b) return (type(b) == "string" and b:match("@x$")) and value or nil end,
		},
		is_repeat_feature_enabled = function() return false end,
		DELAYS                    = {},
		SECTION_DELAYS            = {},
	}
	bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })
	bridge.set_preview_star_enabled(true)
	bridge.set_preview_autocorrect_enabled(true)

	-- NOT pcall'd. A throw inside update_preview means the function never reached
	-- the line that persists, and every absence assertion below would then be
	-- measuring the throw rather than the fix.
	bridge.update_preview(buf)
	-- The telemetry is deferred off the HID thread, so nothing is written until
	-- the scheduled timer runs. A test that asserted without firing it would pass
	-- against a build that leaks.
	hs.timer.__fire_all()
end

--- Everything the stub was asked to persist, as one string.
--- @param persisted table
--- @return string
local function written(persisted)
	local parts = {}
	for _, group in ipairs({ persisted.suggested, persisted.dismissed }) do
		for _, row in ipairs(group) do
			parts[#parts + 1] = tostring(row.trigger) .. "|" .. tostring(row.replacement)
		end
	end
	return table.concat(parts, "\n")
end




-- ==============================================
-- ==============================================
-- ======= 2/ The decision ======================
-- ==============================================
-- ==============================================

helpers.describe("preview telemetry: what may be persisted", function()

	local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
	local may = Bridge._may_persist_preview

	helpers.it("refuses a private match", function()
		helpers.assert_true(type(may) == "function", "the predicate must be reachable")
		helpers.assert_eq(may({ trigger = "FR7630", replacement = SECRET_PII, is_private = true }), false,
			"log_hotstring_suggested fires the moment a preview appears and ends in "
			.. "LogManager.append_log — a file retained fourteen days and copied into "
			.. "the metrics store. The DEBUG line above it was fixed; this was not.")
	end)

	helpers.it("allows an ordinary match", function()
		helpers.assert_eq(may({ trigger = "btw", replacement = "by the way" }), true,
			"withholding must be scoped. A fix that muted the telemetry wholesale "
			.. "would satisfy every privacy case and destroy the suggested/dismissed "
			.. "metrics the dashboard is built on.")
		helpers.assert_eq(may({ trigger = "btw", replacement = "by the way", is_private = false }), true,
			"an explicit false is not a secret either")
	end)

	helpers.it("refuses anything that is not a record", function()
		helpers.assert_eq(may(nil), false,
			"the dismissal path reads a record that outlives the match it came from; "
			.. "if it is gone there is nothing to attribute, and persisting on a "
			.. "missing record is the failure this whole file is about")
		helpers.assert_eq(may("FR76 3000"), false)
	end)

end)




-- ==============================================
-- ==============================================
-- ======= 3/ The sink still exists =============
-- ==============================================
-- ==============================================

helpers.describe("preview telemetry: both call sites consult it", function()

	helpers.it("guards both sinks with the predicate, and still calls them", function()
		-- An EXISTENCE check, and the limits are worth naming: it cannot see a
		-- guard that became unconditional, and it pins the predicate's NAME. It
		-- buys one thing the predicate test cannot — that a future change deleting
		-- the two calls outright, which would satisfy every privacy case above
		-- because absence and withholding look identical from outside, fails here.
		-- Selected by a declaration unique to modules/keymap/llm_bridge.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function invalidate_pending_preview")
		helpers.assert_true(src ~= nil, "modules/keymap/llm_bridge.lua source must be locatable")

		helpers.assert_contains(src, "keylogger.log_hotstring_suggested",
			"the suggested sink must still be called: the dashboard's suggested and "
			.. "dismissed metrics are built on it")
		helpers.assert_contains(src, "keylogger.log_hotstring_dismissed",
			"and so must the dismissed sink")

		local guards = 0
		for _ in src:gmatch("may_persist_preview%s*%(") do guards = guards + 1 end
		helpers.assert_true(guards >= 2,
			"both call sites must consult the predicate — they are a hundred lines "
			.. "apart and one fires from reset_predictions, which is exactly how the "
			.. "rule came to be applied to one of them and not the other")
	end)

end)
