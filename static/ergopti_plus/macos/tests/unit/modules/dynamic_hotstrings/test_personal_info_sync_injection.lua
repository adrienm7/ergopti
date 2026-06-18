--- tests/unit/modules/dynamic_hotstrings/test_personal_info_sync_injection.lua

--- ==============================================================================
--- MODULE: personal_info sync injection regression tests
--- DESCRIPTION:
--- Verifies that personal_info.lua's interceptor calls do_expand() synchronously
--- rather than deferring it via timer.doAfter(0, ...) (the A3 race pattern).
--- The deferred path created a window between the "consume" return and the actual
--- expansion where a real keystroke could mutate the keymap buffer, causing
--- do_expand to delete the wrong characters on the next run-loop tick.
---
--- FEATURES & RATIONALE:
--- 1. Source Invariant: the interceptor must NOT contain timer.doAfter(0, ...)
---    wrapping do_expand — a source-level check that fails on regression.
--- 2. The doAfter(0.15, ...) that releases _replacing remains valid and must
---    still be present (it is not part of the expansion dispatch path).
--- ==============================================================================

local helpers = require("tests.helpers")




-- =============================================================================================
-- =============================================================================================
-- ======= 1/ personal_info interceptor calls do_expand synchronously (dynhotstrings-1) ========
-- =============================================================================================
-- =============================================================================================

helpers.describe("personal_info interceptor — synchronous do_expand (dynhotstrings-1 regression)", function()

	helpers.it("source does NOT defer do_expand via timer.doAfter(0, ...)", function()
		local src_path = helpers.driver_root() .. "modules/dynamic_hotstrings/personal_info.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil, "personal_info.lua must be readable")
		local src = fh:read("*a"); fh:close()

		-- The A3 race: the interceptor used to return "consume" while deferring the
		-- actual expansion to the next run-loop tick via doAfter(0, function() do_expand(...) end).
		-- Any keystroke in that window could corrupt the keymap buffer.
		helpers.assert_true(
			src:find("doAfter(0, function() do_expand", 1, true) == nil,
			"personal_info.lua must NOT defer do_expand via timer.doAfter(0, ...) — call it synchronously"
		)
	end)

	helpers.it("source still defers _replacing release via doAfter(0.15, ...) — that path is valid", function()
		local src_path = helpers.driver_root() .. "modules/dynamic_hotstrings/personal_info.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil)
		local src = fh:read("*a"); fh:close()
		-- The 0.15 s deferred _replacing release is intentional (prevents re-entrant
		-- expansion on the same keystroke) and must still be present.
		helpers.assert_true(
			src:find("doAfter(0.15", 1, true) ~= nil,
			"the 0.15 s _replacing release timer must still be present in do_expand"
		)
	end)

end)
