--- tests/unit/modules/test_classify_trigger_no_silent_fallback.lua

--- ==============================================================================
--- MODULE: Regression — the @-collector must not silently fall back to three scans
--- DESCRIPTION:
--- `classify_trigger` answers "is this string an exact trigger / a prefix of one /
--- a suffix of one" in ONE pass over the corpus, and its result is memoised. The
--- @-collector calls it, but behind `if _keymap.classify_trigger then` — and the
--- else branch ran `has_exact_trigger`, `has_trigger_prefix` and
--- `has_trigger_suffix` as three separate full-corpus scans, none of them memoised.
---
--- ROOT CAUSE ENCODED:
--- A hardcoded behavioural fallback for a function that is always exported
--- (`keymap/init.lua` assigns `M.classify_trigger = Registry.classify_trigger`).
--- Convention 5.4 forbids exactly this: a missing dependency must fail loudly, not
--- quietly select a slower path with different caching behaviour. The branch could
--- only ever be reached through a partial `_keymap` injection — i.e. a wiring
--- mistake — and it would then hide that mistake behind three silent scans instead
--- of reporting it.
---
--- The assertion is on the SHAPE of the dependency check, because the collector is
--- a state machine driven from an eventtap callback and the branch under test is
--- the one that must never execute.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The collector is located by its state constant rather than by a path.
local ANCHOR = "STATE_COLLECTING"

-- The three single-purpose predicates the fallback used.
local SCAN_PREDICATES = {
	"has_exact_trigger",
	"has_trigger_prefix",
	"has_trigger_suffix",
}




-- ==================================================================
-- ==================================================================
-- ======= 1/ One classifier, and it is required ====================
-- ==================================================================
-- ==================================================================

helpers.describe("@-collector: no silent fallback to per-predicate scans", function()

	helpers.it("does not call the three single-purpose predicates", function()
		local src = helpers.read_driver_source(ANCHOR)
		helpers.assert_true(src ~= nil and src ~= "",
			"the @-collector must be locatable by '" .. ANCHOR .. "'; an empty corpus would "
			.. "make every assertion below vacuous")

		-- Comments stripped: the prose that explains why the single-pass classifier
		-- replaced these three names mentions all three.
		local code = src:gsub("%-%-[^\n]*", "")

		local offenders = {}
		for _, name in ipairs(SCAN_PREDICATES) do
			if code:find(name, 1, true) then table.insert(offenders, name) end
		end

		helpers.assert_eq(#offenders, 0,
			"each of these walks the whole mapping corpus and none is memoised, so the "
			.. "fallback was three uncached full scans where the classifier does one cached "
			.. "pass. It is also unreachable in production - keymap always exports "
			.. "classify_trigger - so its only effect was to hide a partial injection "
			.. "behind a slower path: " .. table.concat(offenders, ", "))
	end)

	helpers.it("still calls the single-pass classifier", function()
		local code = helpers.read_driver_source(ANCHOR):gsub("%-%-[^\n]*", "")

		-- Without this case the assertion above would pass against a collector that
		-- stopped classifying altogether, which would let a trigger already claimed by
		-- a static hotstring be collected as a dynamic one.
		helpers.assert_true(code:find("classify_trigger", 1, true) ~= nil,
			"the collector must still ask whether the trigger is already claimed")
	end)

	helpers.it("reports a missing classifier instead of working around it", function()
		local code = helpers.read_driver_source(ANCHOR):gsub("%-%-[^\n]*", "")

		-- Convention 5.4: a required dependency that is absent must be loud. The old
		-- shape was `if _keymap.classify_trigger then … else <three scans> end`, which
		-- is the silent behavioural fallback the convention forbids.
		local at = code:find("classify_trigger", 1, true)
		helpers.assert_true(at ~= nil, "the call site must be findable")
		local window = code:sub(math.max(1, at - 400), at + 400)
		helpers.assert_true(window:find("Logger.error", 1, true) ~= nil,
			"an absent classifier means the keymap module was injected partially, which is "
			.. "a wiring mistake. It must be reported, not routed around")
	end)

end)
