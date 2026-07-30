--- tests/unit/menu/test_preferences_gesture_space_wrap.lua

--- ==============================================================================
--- MODULE: Preferences gesture_space_wrap regression tests
--- DESCRIPTION:
--- Regressions for two related bugs in ui/menu/preferences.lua:
---
--- ui-menu-core-1: flatten_from_disk() classified ALL non-enabled scalars in
--- [gestures] as gesture_actions slots. Keys like space_wrap that have a KEY_MAP
--- entry (mapped to gesture_space_wrap) were never restored after reload and a
--- phantom gesture_actions.space_wrap slot was created.
---
--- ui-menu-core-2: save() computed gesture_space_wrap with the expression
--- `gestures.get_space_wrap() or true`, which always returns true when the getter
--- returns false — the Lua nil-vs-false trap. A disabled space-wrap was therefore
--- rewritten as true on every save.
---
--- FEATURES & RATIONALE:
--- 1. Runtime roundtrip test (core-1): writes a real TOML file with space_wrap=false
---    and a gesture action slot, loads it via M.load(), and checks the flat map.
--- 2. Source invariant (core-2): confirms no `get_space_wrap() or true` pattern
---    exists and that the explicit if/else guard is present.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ======================================================================================
-- ======================================================================================
-- ======= 1/ space_wrap routes to flat key, not gesture_actions (ui-menu-core-1) =======
-- ======================================================================================
-- ======================================================================================

helpers.describe("preferences.flatten_from_disk — space_wrap routing (ui-menu-core-1 regression)", function()

	helpers.it("space_wrap=false loads into gesture_space_wrap, not gesture_actions", function()
		-- Write a minimal TOML config with [gestures] containing space_wrap (a KEY_MAP
		-- key) alongside tap_2 (a genuine gesture action slot).
		local tmp = helpers.driver_root() .. "tests/scratch_test_dir/test_space_wrap_prefs.toml"
		local fh = io.open(tmp, "w")
		helpers.assert_true(fh ~= nil, "must be able to write a temp TOML file in scratch dir")
		fh:write("[gestures]\nspace_wrap = false\ntap_2 = \"copy\"\n")
		fh:close()

		local Prefs = helpers.load_with_stubs("ui.menu.preferences")
		local flat  = Prefs.load(tmp)
		pcall(os.remove, tmp)

		-- Pre-fix: flat.gesture_space_wrap was nil (routing miss) and
		--          flat.gesture_actions.space_wrap == false (phantom slot).
		helpers.assert_true(flat.gesture_space_wrap == false,
			"space_wrap=false from [gestures] must populate flat.gesture_space_wrap (got: " .. tostring(flat.gesture_space_wrap) .. ")")
		helpers.assert_true(flat.gesture_actions ~= nil and flat.gesture_actions.tap_2 == "copy",
			"tap_2='copy' from [gestures] must still populate gesture_actions.tap_2")
		helpers.assert_true(flat.gesture_actions == nil or flat.gesture_actions.space_wrap == nil,
			"gesture_actions must NOT have a phantom 'space_wrap' key (the slot is a flat-state key, not an action)")
	end)

end)





-- ========================================================================================
-- ========================================================================================
-- ======= 2/ Parameterized gesture values round-trip through user TOML ====================
-- ========================================================================================
-- ========================================================================================

helpers.describe("preferences — parameterized gesture action TOML round-trip", function()

	helpers.it("loads [gestures.action_parameters] without confusing values for action slots", function()
		local tmp = os.tmpname()
		pcall(os.remove, tmp)
		local fh = io.open(tmp, "w")
		helpers.assert_true(fh ~= nil, "must be able to write a temporary TOML file")
		fh:write("[gestures]\ntap_3 = \"open_url\"\n\n")
		fh:write("[gestures.action_parameters]\n")
		fh:write("tap_3__open_url = \"https://saved.example/path\"\n")
		fh:close()

		local Prefs = helpers.load_with_stubs("ui.menu.preferences")
		local flat = Prefs.load(tmp)
		pcall(os.remove, tmp)

		helpers.assert_eq(flat.gesture_actions.tap_3, "open_url")
		helpers.assert_eq(flat.gesture_action_parameters.tap_3__open_url, "https://saved.example/path")
		helpers.assert_true(flat.gesture_actions.action_parameters == nil,
			"the parameter table must never be treated as a gesture action slot")

		local fake_gestures = {
			get_all_actions = function() return { tap_3 = "open_url" } end,
			get_all_modes = function() return {} end,
			get_all_sensitivities = function() return {} end,
			get_all_action_parameters = function() return {
				tap_3__open_url = "https://saved.example/path",
			} end,
			get_space_wrap = function() return true end,
		}
		Prefs.save(tmp, { hotstrings = {} }, {}, { gestures = fake_gestures })
		local written = Prefs.load(tmp)
		pcall(os.remove, tmp)
		helpers.assert_eq(written.gesture_actions.tap_3, "open_url")
		helpers.assert_eq(written.gesture_action_parameters.tap_3__open_url, "https://saved.example/path")
	end)

end)







-- ===================================================================================
-- ===================================================================================
-- ======= 3/ save() uses explicit if/else for get_space_wrap (ui-menu-core-2) =======
-- ===================================================================================
-- ===================================================================================

helpers.describe("preferences.save — gesture_space_wrap nil-vs-false guard (ui-menu-core-2 regression)", function()

	helpers.it("source: no 'get_space_wrap() or true' short-circuit (Lua nil-vs-false trap)", function()
		-- Selected by a declaration unique to ui/menu/preferences.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function flatten_from_disk")
		helpers.assert_true(src ~= nil, "ui/menu/preferences.lua source must be locatable")

		-- The buggy expression: `fn() or true` returns true when fn() returns false.
		-- Even restricted to the get_space_wrap context the pattern is unambiguous.
		local has_buggy = src:find("get_space_wrap() or true", 1, true) ~= nil
		helpers.assert_true(
			not has_buggy,
			"preferences.lua must NOT use 'get_space_wrap() or true' — returns true when getter returns false (ui-menu-core-2)"
		)
	end)

	helpers.it("source: explicit if/else guards get_space_wrap call", function()
		-- Selected by a declaration unique to ui/menu/preferences.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function flatten_from_disk")
		helpers.assert_true(src ~= nil, "ui/menu/preferences.lua source must be locatable")

		-- The fix uses an explicit guard so false is not confused with nil.
		local has_guard = src:find('type(gestures.get_space_wrap) == "function" then', 1, true) ~= nil
		helpers.assert_true(
			has_guard,
			"preferences.lua must guard get_space_wrap with an explicit if/else to distinguish false from nil"
		)
	end)

end)
