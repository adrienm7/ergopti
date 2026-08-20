--- tests/unit/test_hot_path_costs.lua

--- ==============================================================================
--- MODULE: Regression — work that must not sit on the keystroke path
---         (hot-path-costs)
--- DESCRIPTION:
--- Four places paid an avoidable cost per keystroke, per gesture frame, or on
--- the boot critical path. None of them is a correctness bug on its own; the
--- common failure they feed is the one macOS punishes hardest — a keyboard tap
--- that stalls long enough to be disabled for being unresponsive.
---
--- ROOT CAUSE ENCODED:
---   1. The Spaces binding was require()d afresh and re-queried on every space
---      navigation, from the gesture frame callback.
---   2. The architecture and macOS-version probes each spawned a subprocess on
---      every call, twice during boot before the keymap starts, for values that
---      cannot change while the process runs.
---   3. onKeyDownRaw read the wall clock twice per keystroke.
---   4. The star buffer was concatenated on every keystroke even when the star
---      bucket was empty, which is the overwhelmingly common case.
---
--- Logger side effects have a separate causal test that drives the production
--- keyDown callback: modules/keymap/test_eventtap_logger_side_effects.lua. The
--- former source scan here blessed one DEBUG flush conditional while synchronous
--- console, file fan-out, errors mirror and notifications all remained live.
---
--- WHY THEY WERE SILENT: nothing fails. The driver simply spends longer inside
--- the callback than it needs to, and the cost only becomes visible as the
--- symptom it eventually causes.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================================
-- ================================================================
-- ======= 2/ Repeated OS probes are resolved once ================
-- ================================================================
-- ================================================================

helpers.describe("backend detection: the host probes run once per session", function()
	helpers.it("memoises the architecture and OS-version subprocesses", function()
		local src = helpers.read_driver_source("is_apple_silicon")
		helpers.assert_true(src ~= nil and src ~= "", "the backend detector must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("_is_arm_cached", 1, true) ~= nil,
			"the CPU architecture cannot change while the process runs, yet this spawned uname "
				.. "on every call — twice during boot, before the keymap starts")
		helpers.assert_true(code:find("_macos_major_cached", 1, true) ~= nil,
			"same for the macOS version probe, and a FAILED probe must be cached too or a broken "
				.. "sw_vers is re-spawned on every call instead")
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 3/ The gesture frame callback stops re-loading =========
-- ================================================================
-- ================================================================

helpers.describe("gestures: the Spaces binding is loaded and queried once", function()
	helpers.it("hoists the require and caches the layout", function()
		local src = helpers.read_driver_source("spaceNav")
		helpers.assert_true(src ~= nil and src ~= "", "the gesture actions must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("_spaces_module", 1, true) ~= nil,
			"the binding wraps a private API and was require()d afresh on every navigation, from "
				.. "the gesture frame callback where a stall shows up directly as input lag")
		helpers.assert_true(code:find("_cached_all_spaces", 1, true) ~= nil,
			"and the Space LAYOUT — which only changes when the user adds or removes a desktop — "
				.. "must not be re-queried on every navigation")

		-- The FOCUSED space must stay live: it changes with every navigation, so
		-- caching it would break the edge detection this code exists for.
		-- Anchored on the CALL: "local function _cached_all_spaces(spaces)" contains
		-- the same text and sits a hundred lines above the site being checked.
		local at = code:find("= _cached_all_spaces(spaces)", 1, true)
		helpers.assert_true(at ~= nil, "the cached lookup must be used, not merely defined")
		local after = code:sub(at, at + 200)
		helpers.assert_true(after:find("pcall(spaces.focusedSpace)", 1, true) ~= nil,
			"the focused Space must still be read live — it changes with every navigation, and "
				.. "caching it would break the very edge check this guards")
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 4/ The keystroke path does less per key ================
-- ================================================================
-- ================================================================

helpers.describe("keymap: one clock read and no wasted allocation per keystroke", function()
	helpers.it("reads the wall clock once", function()
		local src = helpers.read_driver_source("onKeyDownRaw")
		helpers.assert_true(src ~= nil and src ~= "", "the keymap tap must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("local function onKeyDownRaw", 1, true)
		helpers.assert_true(at ~= nil, "onKeyDownRaw must exist")

		local body = code:sub(at, at + 1600)
		local reads = 0
		for _ in body:gmatch("hs%.timer%.secondsSinceEpoch%(%)") do reads = reads + 1 end
		helpers.assert_eq(reads, 1,
			"the ignored-window cache and the inter-key delta must share one read (found "
				.. reads .. "). Two reads microseconds apart return the same value for every "
				.. "purpose either consumer has, on the hottest path in the driver")
	end)

	helpers.it("builds the star buffer only when there is a bucket to match", function()
		local src = helpers.read_driver_source("function M.resolve_magic_action")
		local code = src:gsub("%-%-[^\n]*", "")

		local bucket_at = code:find("local star_bucket", 1, true)
		local bare_at = bucket_at and code:find("local bare_star_bucket", bucket_at, true) or nil
		local concat_at = bare_at and code:find(
			"auto_buffer = (star_bucket or bare_star_bucket) and (buffer .. magic) or nil",
			bare_at, true) or nil
		helpers.assert_true(bucket_at ~= nil and bare_at ~= nil and concat_at ~= nil,
			"the prospective resolver must still build the magic-key buffer when needed")
		helpers.assert_true(bucket_at < bare_at and bare_at < concat_at,
			"the concatenation must be short-circuit gated on both buckets. It ran on every keystroke, and the "
				.. "overwhelmingly common case is an empty bucket — a string allocation bought "
				.. "for nothing on the latency-critical path")
	end)
end)
