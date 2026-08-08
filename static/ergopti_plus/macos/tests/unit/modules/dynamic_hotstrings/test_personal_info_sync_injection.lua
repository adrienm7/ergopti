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
--- 2. The existing doAfter(0.15, ...) re-entry guard remains in this provenance
---    commit; its physical-input blind interval is removed by HS-M-02 separately.
--- 3. The fallback keeps deletion, field values, and Tabs inside one explicit
---    replacement transaction, then seals or cancels it before returning.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =============================================================================================
-- =============================================================================================
-- ======= 1/ personal_info interceptor calls do_expand synchronously (dynhotstrings-1) ========
-- =============================================================================================
-- =============================================================================================

helpers.describe("personal_info interceptor — synchronous do_expand (dynhotstrings-1 regression)", function()

	helpers.it("source does NOT defer do_expand via timer.doAfter(0, ...)", function()
		-- Selected by a declaration unique to modules/dynamic_hotstrings/personal_info.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function parse_toml_section")
		helpers.assert_true(src ~= nil, "modules/dynamic_hotstrings/personal_info.lua source must be locatable")

		-- The A3 race: the interceptor used to return "consume" while deferring the
		-- actual expansion to the next run-loop tick via doAfter(0, function() do_expand(...) end).
		-- Any keystroke in that window could corrupt the keymap buffer.
		helpers.assert_true(
			src:find("doAfter(0, function() do_expand", 1, true) == nil,
			"personal_info.lua must NOT defer do_expand via timer.doAfter(0, ...) — call it synchronously"
		)
	end)

	helpers.it("retains the existing 0.15-second re-entry guard until HS-M-02", function()
		-- Selected by a declaration unique to modules/dynamic_hotstrings/personal_info.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function parse_toml_section")
		helpers.assert_true(src ~= nil, "modules/dynamic_hotstrings/personal_info.lua source must be locatable")
		helpers.assert_true(
			src:find("doAfter(0.15", 1, true) ~= nil,
			"the provenance commit must not silently absorb the separate HS-M-02 behavior change"
		)
	end)

end)


helpers.describe("personal_info fallback — one explicit synthetic transaction", function()
	-- The fallback is not allowed to create independent implicit actions for its
	-- deletes, values, and Tabs. One transaction generation owns the whole output,
	-- and closing it prevents a later action from inheriting private output; a
	-- partially built transaction is cancelled rather than handed off.

	helpers.it("opens, scopes, and closes the fallback transaction in order", function()
		-- Selected by a declaration unique to modules/dynamic_hotstrings/personal_info.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function parse_toml_section")
		helpers.assert_true(src ~= nil, "modules/dynamic_hotstrings/personal_info.lua source must be locatable")

		local arm_pos = src:find("local transaction = _keymap.arm_synthetic", 1, true)
		local scope_pos = src:find("pcall(_keymap.with_synthetic_transaction, transaction", 1, true)
		local select_pos = src:find(
			"local close = ok_emit and _keymap.finish_synthetic or _keymap.cancel_synthetic", 1, true)
		local close_pos = src:find("pcall(close, transaction)", select_pos or 1, true)
		helpers.assert_true(arm_pos ~= nil and scope_pos ~= nil
			and select_pos ~= nil and close_pos ~= nil,
			"fallback must expose an explicit begin/scope/seal-or-cancel lifecycle")
		helpers.assert_true(arm_pos < scope_pos and scope_pos < select_pos and select_pos < close_pos,
			"the fallback must close only after every delete, field value, and Tab is attempted")
	end)

	helpers.it("fallback suppresses matching only after its transaction is opened", function()
		-- Selected by a declaration unique to modules/dynamic_hotstrings/personal_info.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function parse_toml_section")
		helpers.assert_true(src ~= nil, "modules/dynamic_hotstrings/personal_info.lua source must be locatable")
		local arm_pos = src:find("local transaction = _keymap.arm_synthetic", 1, true)
		local suppress_pos = src:find("_keymap.suppress_rescan()", arm_pos or 1, true)
		helpers.assert_true(arm_pos ~= nil and suppress_pos ~= nil and suppress_pos > arm_pos,
			"fallback must not alter matching state unless its replacement transaction exists")
	end)

end)
