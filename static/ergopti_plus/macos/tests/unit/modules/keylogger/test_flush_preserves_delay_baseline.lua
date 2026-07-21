--- tests/unit/modules/keylogger/test_flush_preserves_delay_baseline.lua

--- ==============================================================================
--- MODULE: Regression — a keystroke-driven flush must not zero the next delay
--- DESCRIPTION:
--- Corrupted timing data: roughly one keystroke in six was logged with delay 0.
---
--- ROOT CAUSE ENCODED:
--- LogManager.flush_buffer() resets CoreState.last_time to 0. handle_key computes
--- the inter-keystroke delay as `now - CoreState.last_time`, so the FIRST keystroke
--- after any flush measured against 0 and recorded a delay of 0 — losing exactly
--- the inter-word gap, which is the most meaningful pause in typing telemetry.
--- Every space and sentence-ending punctuation flushes, so the loss was systematic
--- rather than occasional, and it silently skewed every WPM and n-gram timing
--- statistic derived from the data.
---
--- The file already knew: the metrics-webview flush re-seeds `CoreState.last_time =
--- now` immediately after flushing, with a comment naming this exact hazard. The
--- seven keystroke-driven flush sites — Tab, Escape, Enter, F-keys, nav keys, and
--- the two space/punctuation branches — did not. This is the repo's signature
--- shape: the invariant was written down once and applied at one site.
---
--- The guard asserts the STRUCTURE, because the defect is a property of every flush
--- site rather than of one observable call: handle_key is a local driven by an
--- eventtap, and reaching all seven branches behaviourally would need a synthetic
--- keycode per branch without ever observing CoreState.last_time, which the module
--- does not expose. What is decidable is that no keystroke-driven flush calls
--- flush_buffer() directly any more.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Flush sites inside handle_key that are driven by a keystroke and therefore must
-- preserve the timing baseline. Identified by the marker each branch logs.
local KEYSTROKE_FLUSH_MARKERS = { "%[TAB%]", "%[ESC%]", "%[ENTER%]", "F_KEY_CODES", "NAV_KEY_CODES" }




-- ==============================================
-- ==============================================
-- ======= 1/ Every Flush Re-seeds ==============
-- ==============================================
-- ==============================================

helpers.describe("keystroke-driven flushes preserve the inter-key delay baseline", function()
	helpers.it("declares the baseline-preserving flush helper", function()
		-- Selected by a declaration unique to modules/keylogger/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function flush_keeping_baseline")
		helpers.assert_true(src ~= nil, "modules/keylogger/init.lua source must be locatable")
		if not src then return end

		helpers.assert_true(src:find("local function flush_keeping_baseline") ~= nil,
			"handle_key must route its flushes through a helper that re-seeds "
			.. "CoreState.last_time, or the next keystroke reports a delay of 0")

		-- The helper must be declared BEFORE the branch chain that calls it, or it
		-- binds a nil global and every flush site raises inside the eventtap.
		local decl_at  = src:find("local function flush_keeping_baseline")
		local first_use = src:find("\n%s*flush_keeping_baseline%(%)")
		helpers.assert_true(first_use ~= nil, "the helper must actually be called")
		helpers.assert_true(decl_at < first_use,
			"the helper must be declared above its first call site (closure-before-local rule)")
	end)

	helpers.it("no keystroke-driven branch still calls flush_buffer directly", function()
		-- Selected by a declaration unique to modules/keylogger/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function flush_keeping_baseline")
		helpers.assert_true(src ~= nil, "modules/keylogger/init.lua source must be locatable")
		if not src then return end

		local offenders = {}
		for _, marker in ipairs(KEYSTROKE_FLUSH_MARKERS) do
			local at = src:find(marker)
			if at then
				-- Look at the branch body immediately after the marker.
				local body = src:sub(at, at + 400)
				local direct = body:find("LogManager%.flush_buffer%(%)")
				local seeded = body:find("flush_keeping_baseline%(%)")
				if direct and (not seeded or direct < seeded) then
					offenders[#offenders + 1] = marker
				end
			end
		end

		helpers.assert_true(#offenders == 0, string.format(
			"%d keystroke-driven branch(es) still flush without re-seeding the baseline (%s). "
			.. "flush_buffer() zeroes CoreState.last_time, so the next keystroke records a "
			.. "delay of 0 and the inter-word gap is lost from the timing data",
			#offenders, table.concat(offenders, ", ")))
	end)

	helpers.it("the space and punctuation branches re-seed too", function()
		-- Selected by a declaration unique to modules/keylogger/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function flush_keeping_baseline")
		helpers.assert_true(src ~= nil, "modules/keylogger/init.lua source must be locatable")
		if not src then return end

		-- These two are the highest-frequency flushes of all: every space, and every
		-- sentence-ending punctuation mark.
		for _, guard in ipairs({ 'sub_char:match%("%[%.%?!%]"%)', 'chars:match%("%[%.%?!%]"%)' }) do
			local at = src:find(guard)
			helpers.assert_true(at ~= nil, "branch guard must be locatable: " .. guard)
			if at then
				local body = src:sub(at, at + 200)
				helpers.assert_true(body:find("flush_keeping_baseline%(%)") ~= nil,
					"the space/punctuation flush must preserve the baseline — it is the most "
					.. "frequent flush in the driver, so losing its delay skews every timing stat")
			end
		end
	end)
end)
