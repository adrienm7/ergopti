--- tests/unit/modules/keymap/test_interceptor_failure_visible.lua

--- ==============================================================================
--- MODULE: Regression — a throwing keystroke interceptor must not fail silently
--- DESCRIPTION:
--- Interceptors are dispatched from the keyDown handler under a pcall whose
--- failure branch did nothing at all:
---
---   local ok, result = pcall(interceptor, e, CoreState.buffer)
---   if ok then ... end        -- no else
---
--- The interceptor list is how dynamic_hotstrings implements @-tag expansion and
--- the date rules. A throw in one of them therefore disabled that whole feature
--- for the session with no error, no warning, and nothing in the file logger —
--- the user simply found that "@phone stopped working" with no way to find out
--- why. This is the silent-async-failure class the project's logging rules exist
--- to prevent, in the one place it is least visible: the hot path.
---
--- The report is one-shot per interceptor index, because the fault is persistent
--- and this runs on every keystroke — logging per keystroke would flood the log
--- and the dedup window would hide the rest.
---
--- WHY A SOURCE GUARD: the interceptor loop lives inside the keyDown handler, which
--- is a file-local wired directly into an hs.eventtap and is not reachable from the
--- module's public surface. A first version of this test pretended to drive it and
--- ended up asserting nothing; the contract below is what is actually decidable.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==============================================
-- ==============================================
-- ======= 1/ Keymap Source Reader ==============
-- ==============================================
-- ==============================================

--- Reads the keymap source once per assertion.
--- @return string The keymap/init.lua source.
local function keymap_source()
	-- Selected by a declaration unique to modules/keymap/init.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("function M.get_base_delay")
	helpers.assert_true(src ~= nil, "modules/keymap/init.lua source must be locatable")
	if not src then return end
	return src
end




-- ==============================================
-- ==============================================
-- ======= 2/ The Failure Is Reported ===========
-- ==============================================
-- ==============================================

helpers.describe("a throwing interceptor is reported instead of silently skipped", function()
	helpers.it("logs an ERROR naming the interceptor when it raises", function()
		local src = keymap_source()

		helpers.assert_true(src:find("_interceptor_error_logged") ~= nil,
			"the interceptor dispatch must report a raise. Its pcall failure branch was "
			.. "empty, so a throwing interceptor disabled @-tag and date expansion for the "
			.. "whole session with nothing in the log")
		helpers.assert_true(src:find("Interceptor #", 1, true) ~= nil and src:find("raised", 1, true) ~= nil,
			"the report must name which interceptor raised, so the broken feature is "
			.. "identifiable from the log alone")
	end)

	helpers.it("reports once per interceptor rather than once per keystroke", function()
		local src = keymap_source()

		helpers.assert_true(src:find("_interceptor_error_logged%[idx%]") ~= nil,
			"the one-shot latch must be keyed by interceptor index")
		helpers.assert_true(src:find("if not _interceptor_error_logged%[idx%] then") ~= nil,
			"the log must be gated on the latch — this runs on every keystroke, so an "
			.. "ungated Logger.error would flood the log and the dedup window would then "
			.. "hide the very line that identifies the fault")
	end)
end)
