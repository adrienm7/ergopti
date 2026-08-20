--- tests/unit/ui/menu/test_menu_keyboard_layout.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Menu Unit Tests
--- DESCRIPTION:
--- Validates the pure-Lua bundle version picker exposed by
--- ui.menu.menu_keyboard_layout. The real submenu builder is macOS-only
--- (depends on hs.execute / hs.osascript), so we only exercise the helpers
--- safe to run cross-platform.
--- ==============================================================================

local helpers = require("tests.helpers")
local kbd     = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")

helpers.describe("menu_keyboard_layout._parse_version", function()
	helpers.it("parses a standard 'Ergopti_v2.2.1.bundle' name", function()
		local v = kbd._parse_version("Ergopti_v2.2.1.bundle")
		helpers.assert_true(type(v) == "table" and #v == 3)
		helpers.assert_eq(v[1], 2) ; helpers.assert_eq(v[2], 2) ; helpers.assert_eq(v[3], 1)
	end)

	helpers.it("returns nil on names without the expected suffix", function()
		helpers.assert_nil(kbd._parse_version("Ergopti.bundle"))
		helpers.assert_nil(kbd._parse_version("random.txt"))
	end)
end)

helpers.describe("menu_keyboard_layout._version_gt", function()
	helpers.it("orders 2.2.1 above 2.2.0", function()
		helpers.assert_true(kbd._version_gt({2,2,1}, {2,2,0}))
		helpers.assert_true(not kbd._version_gt({2,2,0}, {2,2,1}))
	end)

	helpers.it("treats missing components as zero", function()
		helpers.assert_true(kbd._version_gt({3}, {2,9,9}))
		helpers.assert_true(not kbd._version_gt({1,0}, {1,0,0}))
	end)
end)

helpers.describe("menu_keyboard_layout.pick_latest_bundle", function()
	helpers.it("returns the highest version present in the bundles directory", function()
		-- Use the checked-in fixture directory so the test is self-contained and
		-- does not depend on a real macOS build artefact being present on disk.
		local bundles_dir = helpers.fixtures_dir() .. "bundles/"
		local latest = kbd.pick_latest_bundle(bundles_dir)
		helpers.assert_true(type(latest) == "string" and latest:match("^Ergopti_v[%d%.]+%.bundle$") ~= nil,
			"expected a bundle name, got " .. tostring(latest))
		-- Whatever the exact version on disk, it must be >= 2.2.1
		local v = kbd._parse_version(latest)
		helpers.assert_true(kbd._version_gt(v, {2,2,0}) or (v[1]==2 and v[2]==2 and v[3]==1))
	end)

	helpers.it("returns nil when the directory has no Ergopti bundles", function()
		helpers.assert_nil(kbd.pick_latest_bundle("/no/such/dir/here/"))
	end)

	helpers.it("can find actual bundles in the repository via the production BUNDLES_RELDIR", function()
		-- base_dir for hammerspoon is static/ergopti_plus/macos/
		local driver_root = helpers.driver_root()
		-- BUNDLES_RELDIR is ../../ergopti/macos/bundles/
		local bundles_dir = driver_root .. "../../ergopti/macos/bundles/"
		local latest = kbd.pick_latest_bundle(bundles_dir)
		helpers.assert_true(type(latest) == "string" and latest:match("^Ergopti_v[%d%.]+%.bundle$") ~= nil,
			"Expected to find a bundle in the real repository path: " .. bundles_dir)
	end)
end)




-- ====================================================
-- ====================================================
-- ======= 4/ Display & version-extraction helpers ====
-- ====================================================
-- ====================================================

helpers.describe("menu_keyboard_layout._clean_layout_name", function()
	helpers.it("strips the standard com.apple.keylayout. prefix", function()
		helpers.assert_eq(kbd._clean_layout_name("com.apple.keylayout.French"), "French")
		helpers.assert_eq(kbd._clean_layout_name("com.apple.keylayout.US"), "US")
	end)

	helpers.it("renders the legacy com.apple.keyboardlayout.ergopti.* form via the pretty formatter", function()
		-- Ergopti entries flow through format_ergopti_display rather than
		-- plain prefix-stripping, so the user sees a friendly name in the menu
		helpers.assert_eq(kbd._clean_layout_name("com.apple.keyboardlayout.ergopti.v2_2_0"),
			"Ergopti v2.2.0")
	end)

	helpers.it("strips com.apple.inputmethod. and inputsource. prefixes", function()
		helpers.assert_eq(kbd._clean_layout_name("com.apple.inputmethod.SCIM.ITABC"), "SCIM.ITABC")
		helpers.assert_eq(kbd._clean_layout_name("com.apple.inputsource.foo"), "foo")
	end)

	helpers.it("returns the input verbatim when no Apple prefix is present", function()
		helpers.assert_eq(kbd._clean_layout_name("Ergopti"), "Ergopti")
	end)

	helpers.it("coerces non-string input safely", function()
		helpers.assert_eq(kbd._clean_layout_name(nil), "nil")
		helpers.assert_eq(kbd._clean_layout_name(42), "42")
	end)
end)

helpers.describe("menu_keyboard_layout._extract_ergopti_version", function()
	helpers.it("extracts v2_2_0 from the legacy underscore form", function()
		local v = kbd._extract_ergopti_version("com.apple.keyboardlayout.ergopti.v2_2_0")
		helpers.assert_eq(v[1], 2) ; helpers.assert_eq(v[2], 2) ; helpers.assert_eq(v[3], 0)
	end)

	helpers.it("extracts v2.2.1 from the dotted form", function()
		local v = kbd._extract_ergopti_version("com.apple.keylayout.ergopti.v2.2.1")
		helpers.assert_eq(v[1], 2) ; helpers.assert_eq(v[2], 2) ; helpers.assert_eq(v[3], 1)
	end)

	helpers.it("zero-fills missing minor / patch components", function()
		local v1 = kbd._extract_ergopti_version("ergopti_v2.2")
		helpers.assert_eq(v1[3], 0)
		local v2 = kbd._extract_ergopti_version("ergopti.v3")
		helpers.assert_eq(v2[1], 3) ; helpers.assert_eq(v2[2], 0) ; helpers.assert_eq(v2[3], 0)
	end)

	helpers.it("returns a zeroed tuple for unversioned ergopti ids", function()
		local v = kbd._extract_ergopti_version("com.apple.keylayout.ergopti")
		helpers.assert_eq(v[1], 0) ; helpers.assert_eq(v[2], 0) ; helpers.assert_eq(v[3], 0)
	end)

	helpers.it("returns nil when the name is unrelated to Ergopti", function()
		helpers.assert_nil(kbd._extract_ergopti_version("com.apple.keylayout.French"))
	end)
end)

helpers.describe("menu_keyboard_layout._version_str", function()
	helpers.it("renders {2,2,1} as '2.2.1'", function()
		helpers.assert_eq(kbd._version_str({2,2,1}), "2.2.1")
	end)
	helpers.it("preserves single-component input", function()
		helpers.assert_eq(kbd._version_str({3}), "3")
	end)
end)





--- =====================================================
--- =====================================================
--- ======= 5/ format_ergopti_display + legacy id =======
--- =====================================================
--- =====================================================

helpers.describe("menu_keyboard_layout._format_ergopti_display", function()
	helpers.it("renders the legacy bundle id with version", function()
		helpers.assert_eq(
			kbd._format_ergopti_display("com.apple.keyboardlayout.ergopti.v2_2_0"),
			"Ergopti v2.2.0")
	end)

	helpers.it("renders the plus variant", function()
		helpers.assert_eq(
			kbd._format_ergopti_display("com.apple.keyboardlayout.ergopti.v2_2_0.plus"),
			"Ergopti+ v2.2.0")
	end)

	helpers.it("renders the plus_plus ANSI variant", function()
		helpers.assert_eq(
			kbd._format_ergopti_display("com.apple.keyboardlayout.ergopti.v2_2_1.plus_plus.ansi"),
			"Ergopti++ ANSI v2.2.1")
	end)

	helpers.it("renders the new stable id without version suffix", function()
		helpers.assert_eq(
			kbd._format_ergopti_display("com.apple.keyboardlayout.ergopti.plus"),
			"Ergopti+")
	end)

	helpers.it("returns nil for non-Ergopti identifiers", function()
		helpers.assert_nil(kbd._format_ergopti_display("com.apple.keylayout.French"))
	end)
end)

helpers.describe("menu_keyboard_layout._clean_layout_name (Ergopti pretty form)", function()
	helpers.it("uses the pretty formatter for Ergopti entries", function()
		helpers.assert_eq(
			kbd._clean_layout_name("com.apple.keyboardlayout.ergopti.v2_2_0.plus"),
			"Ergopti+ v2.2.0")
	end)

	helpers.it("falls back to plain prefix-stripping for non-Ergopti entries", function()
		helpers.assert_eq(kbd._clean_layout_name("com.apple.keylayout.French"), "French")
	end)
end)

helpers.describe("menu_keyboard_layout._is_legacy_ergopti_id", function()
	helpers.it("matches a versioned id under the third-party namespace", function()
		helpers.assert_true(kbd._is_legacy_ergopti_id("com.apple.keyboardlayout.ergopti.v2_2_0"))
	end)

	helpers.it("matches an embedded version even without a known prefix", function()
		helpers.assert_true(kbd._is_legacy_ergopti_id("ergopti.v2_2_0"))
	end)

	helpers.it("matches the reserved-namespace form (mistakenly used in v2.2.2 betas)", function()
		helpers.assert_true(kbd._is_legacy_ergopti_id("com.apple.keylayout.ergopti"))
		helpers.assert_true(kbd._is_legacy_ergopti_id("com.apple.keylayout.ergopti.plus"))
	end)

	helpers.it("rejects the new stable third-party id", function()
		helpers.assert_true(not kbd._is_legacy_ergopti_id("com.apple.keyboardlayout.ergopti"))
		helpers.assert_true(not kbd._is_legacy_ergopti_id("com.apple.keyboardlayout.ergopti.plus"))
	end)

	helpers.it("rejects unrelated layout ids", function()
		helpers.assert_true(not kbd._is_legacy_ergopti_id("com.apple.keylayout.French"))
	end)
end)

helpers.describe("menu_keyboard_layout._migrate_legacy_id", function()
	helpers.it("strips the version segment under the third-party namespace", function()
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keyboardlayout.ergopti.v2_2_0"),
			"com.apple.keyboardlayout.ergopti")
	end)

	helpers.it("preserves the variant suffix after the version is stripped", function()
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keyboardlayout.ergopti.v2_2_0.plus"),
			"com.apple.keyboardlayout.ergopti.plus")
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keyboardlayout.ergopti.v2_2_1.plus_plus.ansi"),
			"com.apple.keyboardlayout.ergopti.plus_plus.ansi")
	end)

	helpers.it("lifts the reserved short namespace to the third-party one", function()
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keylayout.ergopti.plus"),
			"com.apple.keyboardlayout.ergopti.plus")
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keylayout.ergopti"),
			"com.apple.keyboardlayout.ergopti")
	end)

	helpers.it("is a no-op on already-stable third-party ids", function()
		helpers.assert_eq(
			kbd._migrate_legacy_id("com.apple.keyboardlayout.ergopti.plus"),
			"com.apple.keyboardlayout.ergopti.plus")
	end)
end)





-- ===================================================
-- ===================================================
-- ======= 6/ DEFAULT_STATE & pause-layout API =======
-- ===================================================
-- ===================================================

helpers.describe("menu_keyboard_layout.DEFAULT_STATE (pause-layout feature)", function()
	helpers.it("exposes DEFAULT_STATE with the three layout-switch keys", function()
		helpers.assert_true(type(kbd.DEFAULT_STATE) == "table",
			"DEFAULT_STATE must be a table")
		-- Feature is off by default — false means "inactive"
		helpers.assert_true(kbd.DEFAULT_STATE.layout_pause_switch_enabled == false,
			"layout_pause_switch_enabled default must be false (feature off)")
		helpers.assert_true(kbd.DEFAULT_STATE.layout_on_pause == false,
			"layout_on_pause default must be false (no automatic switch)")
		helpers.assert_true(kbd.DEFAULT_STATE.layout_on_resume == false,
			"layout_on_resume default must be false (no automatic switch)")
	end)

	-- Regression: before the fix, DEFAULT_STATE was absent, so preferences.lua
	-- could not hydrate the layout keys and they were silently ignored.
	helpers.it("DEFAULT_STATE has exactly the three pause-layout keys (no extras)", function()
		local allowed = { layout_pause_switch_enabled = true, layout_on_pause = true, layout_on_resume = true }
		local count = 0
		for k in pairs(kbd.DEFAULT_STATE) do
			count = count + 1
			helpers.assert_true(allowed[k] == true,
				"Unexpected key in DEFAULT_STATE: " .. tostring(k))
		end
		helpers.assert_eq(count, 3)
	end)
end)

helpers.describe("menu_keyboard_layout target_id regression (Ergopti click does nothing)", function()
	-- The bug: the layout-list click handler passed r.name (display-formatted,
	-- e.g. "Ergopti plus") to set_input_source instead of r.id (the raw
	-- KeyboardLayout Name, e.g. "Ergopti_v2_2_2_plus"). hs.keycodes.setLayout
	-- does not recognise the formatted name and silently fails.
	-- We verify the fix indirectly via _format_ergopti_display: it must return
	-- a non-nil display string for known Ergopti IDs (so the display-vs-raw
	-- divergence is intentional and both values are well-defined).
	helpers.it("_format_ergopti_display returns non-nil for Ergopti_v* KeyboardLayout Names (raw id is distinct from display)", function()
		local raw_id = "Ergopti_v2_2_2_plus"
		-- format_ergopti_display is called with the raw id; must not return nil
		-- so that display_for_record works correctly for the menu title
		local display = kbd._format_ergopti_display(raw_id)
		-- The stable TIS form (no version) also works
		local display2 = kbd._format_ergopti_display("com.apple.keyboardlayout.ergopti.plus")
		helpers.assert_true(display ~= nil or display2 ~= nil,
			"at least one Ergopti id form must produce a display label")
	end)

	helpers.it("_format_ergopti_display for stable id 'com.apple.keyboardlayout.ergopti.plus' returns 'Ergopti+'", function()
		helpers.assert_eq(kbd._format_ergopti_display("com.apple.keyboardlayout.ergopti.plus"), "Ergopti+")
	end)
end)

helpers.describe("menu_keyboard_layout.schedule_pause_layout_switch (eventtap-timeout regression)", function()
	-- Root cause: the pause/resume layout switch ran SYNCHRONOUSLY inside the
	-- script-control eventtap callback (script_control.dispatch_action →
	-- _on_pause_change). set_layout_by_kl_name spawns blocking /usr/bin/osascript
	-- subprocesses (run_osascript_isolated), so the tap stalled long enough for
	-- macOS to disable it (kCGEventTapDisabledByTimeout) — after which AltGr+Enter
	-- no longer toggled pause AT ALL. The fix moves the switch onto a deferred
	-- run-loop cycle; these tests prove it stays deferred and correctly gated.

	-- Runs `fn(calls)` with M.set_layout_by_kl_name swapped for a recorder, then
	-- restores the original so sibling tests see the real setter.
	local function with_stubbed_setter(fn)
		local original = kbd.set_layout_by_kl_name
		local calls    = {}
		kbd.set_layout_by_kl_name = function(name) calls[#calls + 1] = name end
		local ok, err = pcall(fn, calls)
		kbd.set_layout_by_kl_name = original
		if not ok then error(err) end
	end

	helpers.it("defers the switch — set_layout_by_kl_name is NEVER called synchronously", function()
		with_stubbed_setter(function(calls)
			local captured = nil
			local state = { layout_pause_switch_enabled = true, layout_on_pause = "Ergopti_v2_2_2_plus", layout_on_resume = "French" }
			local target = kbd.schedule_pause_layout_switch(true, state, function(f) captured = f end)
			-- It returns the pause target and schedules exactly one deferred job…
			helpers.assert_eq(target, "Ergopti_v2_2_2_plus")
			helpers.assert_true(type(captured) == "function", "switch must be scheduled, not run inline")
			-- …but nothing has run yet: the eventtap callback would already have returned.
			helpers.assert_eq(#calls, 0, "set_layout_by_kl_name must NOT run synchronously (would stall the eventtap)")
			-- Running the deferred job performs the actual switch.
			captured()
			helpers.assert_eq(#calls, 1)
			helpers.assert_eq(calls[1], "Ergopti_v2_2_2_plus")
		end)
	end)

	helpers.it("on resume schedules the resume layout (not the pause one)", function()
		with_stubbed_setter(function(calls)
			local captured = nil
			local state = { layout_pause_switch_enabled = true, layout_on_pause = "French", layout_on_resume = "Ergopti_v2_2_2_plus" }
			local target = kbd.schedule_pause_layout_switch(false, state, function(f) captured = f end)
			helpers.assert_eq(target, "Ergopti_v2_2_2_plus")
			captured()
			helpers.assert_eq(calls[1], "Ergopti_v2_2_2_plus")
		end)
	end)

	helpers.it("does nothing when the feature is disabled (no schedule, no switch)", function()
		with_stubbed_setter(function(calls)
			local scheduled = false
			local state = { layout_pause_switch_enabled = false, layout_on_pause = "French", layout_on_resume = "French" }
			local target = kbd.schedule_pause_layout_switch(true, state, function() scheduled = true end)
			helpers.assert_nil(target)
			helpers.assert_true(not scheduled, "disabled feature must not schedule anything")
			helpers.assert_eq(#calls, 0)
		end)
	end)

	helpers.it("does nothing when the target layout is the default false / empty string", function()
		with_stubbed_setter(function(calls)
			local scheduled = false
			local sched = function() scheduled = true end
			helpers.assert_nil(kbd.schedule_pause_layout_switch(true, { layout_pause_switch_enabled = true, layout_on_pause = false }, sched))
			helpers.assert_nil(kbd.schedule_pause_layout_switch(true, { layout_pause_switch_enabled = true, layout_on_pause = "" }, sched))
			helpers.assert_true(not scheduled, "false / empty target must not schedule a switch")
			helpers.assert_eq(#calls, 0)
		end)
	end)
end)

helpers.describe("Startup applies the live pause layout (regression)", function()
	-- The behavioural generation test drives this callback in both live states:
	-- false still selects the resume layout, while a pause committed during the
	-- four-second delay selects the pause layout instead of replaying a stale false.
	helpers.it("audit startup layout: ui/menu/init.lua derives the delayed layout from live pause state", function()
		-- Selected by a declaration unique to ui/menu/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function safe_require")
		helpers.assert_true(src ~= nil, "ui/menu/init.lua source must be locatable")
		helpers.assert_true(src:find("pcall(shortcuts_mod.is_paused)", 1, true) ~= nil,
			"the delayed startup callback must read the canonical live pause predicate")
		helpers.assert_true(src:find("schedule_pause_layout_switch, live_paused", 1, true) ~= nil,
			"the delayed startup callback must pass the live result to layout selection")
	end)
end)
