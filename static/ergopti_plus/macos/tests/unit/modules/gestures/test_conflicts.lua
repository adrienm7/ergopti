--- tests/unit/modules/gestures/test_conflicts.lua

--- ==============================================================================
--- MODULE: gestures.conflicts Unit Tests
--- DESCRIPTION:
--- Validates the macOS gesture conflict detector: on_action_changed returns a
--- structured warning for known conflicting slots, nil for everything else.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- Earlier test files (karabiner layout polling) install a shell_runner stub
-- without exec(); purge it so conflicts.lua captures the real adapter — the
-- CI runner's file order differs from local and made this leak fatal there
package.loaded["adapters.shell_runner"] = nil

local Conflicts = helpers.load_with_stubs("modules.gestures.conflicts")




-- =====================================
-- =====================================
-- ======= 1/ on_action_changed =========
-- =====================================
-- =====================================

helpers.describe("Conflicts.on_action_changed", function()
	helpers.it("returns nil for action 'none'", function()
		helpers.assert_eq(Conflicts.on_action_changed("tap_3", "none"), nil)
	end)

	helpers.it("returns warning for tap_3 with non-none action", function()
		local w = Conflicts.on_action_changed("tap_3", "lookup")
		helpers.assert_true(type(w) == "table")
		helpers.assert_true(type(w.msg) == "string" and w.msg ~= "")
		helpers.assert_true(type(w.url) == "string" and w.url ~= "")
	end)

	helpers.it("returns nil for unknown slot", function()
		helpers.assert_eq(Conflicts.on_action_changed("nonexistent", "lookup"), nil)
	end)

	helpers.it("returns warning for swipe_3_horiz", function()
		local w = Conflicts.on_action_changed("swipe_3_horiz", "back")
		helpers.assert_true(type(w) == "table")
	end)

	helpers.it("returns warning for swipe_4_up (in vertical group)", function()
		local w = Conflicts.on_action_changed("swipe_4_up", "ms")
		helpers.assert_true(type(w) == "table")
	end)

	helpers.it("warning URL is a System Settings deeplink", function()
		local w = Conflicts.on_action_changed("tap_3", "lookup")
		helpers.assert_true(w.url:find("x%-apple%.systempreferences") ~= nil)
	end)

	helpers.it("warning message starts with a separator dash line", function()
		local w = Conflicts.on_action_changed("tap_3", "lookup")
		-- Should have the U+2500 box-drawing dashes
		helpers.assert_true(w.msg:find("─") ~= nil)
	end)
end)





-- =============================================
-- =============================================
-- ======= 2/ Current macOS Preferences =========
-- =============================================
-- =============================================

--- Loads the conflict module with deterministic macOS preference output.
--- @param defaults_output string Synthetic output from the defaults tool.
--- @return table, table, table, function Module, warning entries, commands, cleanup.
local function load_with_macos_preferences(defaults_output)
	local warnings = {}
	local commands = {}
	package.loaded["modules.gestures.conflicts"] = nil
	package.loaded["infra.logger"] = {
		debug   = function() end,
		info    = function() end,
		warn    = function(_, message) table.insert(warnings, message) end,
		error   = function(_, message) table.insert(warnings, message) end,
		start   = function() end,
		success = function() end,
		trace   = function() end,
		done    = function() end,
	}
	package.loaded["adapters.shell_runner"] = {
		exec = function(command)
			table.insert(commands, command)
			return defaults_output
		end,
	}

	local conflicts = helpers.load_with_stubs("modules.gestures.conflicts")
	local function cleanup()
		package.loaded["modules.gestures.conflicts"] = nil
		package.loaded["infra.logger"] = nil
		package.loaded["adapters.shell_runner"] = nil
	end
	return conflicts, warnings, commands, cleanup
end

helpers.describe("Conflicts current macOS preference checks", function()
	helpers.it("suppresses a three-finger tap warning only when macOS reports it disabled", function()
		local conflicts, warnings, commands, cleanup = load_with_macos_preferences([[
{
    TrackpadThreeFingerTapGesture = 0;
    "com.apple.trackpad.threeFingerTapGesture" = 0;
}
]])
		local warning = conflicts.on_action_changed("tap_3", "lookup")
		helpers.assert_nil(warning, "disabled native three-finger tap must not show a warning")
		helpers.assert_eq(#warnings, 0, "suppression must not emit a warning-level log")
		helpers.assert_eq(#commands, 3, "all current Trackpad preference sources must be queried")
		cleanup()
	end)

	helpers.it("keeps the warning when any current macOS source still enables the native gesture", function()
		local conflicts, warnings, _commands, cleanup = load_with_macos_preferences([[
{
    TrackpadThreeFingerHorizSwipeGesture = 2;
    com.apple.trackpad.threeFingerHorizSwipeGesture = 0;
}
]])
		local warning = conflicts.on_action_changed("swipe_3_left", "word_prev")
		helpers.assert_type(warning, "table", "an enabled native gesture remains a real conflict")
		helpers.assert_eq(#warnings, 1, "the real conflict must remain visible in the diagnostics")
		cleanup()
	end)

	helpers.it("does not warn at startup for blank gesture values", function()
		local conflicts, warnings, _commands, cleanup = load_with_macos_preferences([[
{
    TrackpadThreeFingerVertSwipeGesture = 2;
}
]])
		conflicts.apply_all_overrides({ swipe_3_up = "   ", swipe_3_down = "" })
		helpers.assert_eq(#warnings, 0, "blank assignments must be treated as disabled gestures")
		cleanup()
	end)

	helpers.it("suppresses every active startup warning whose native gesture is confirmed disabled", function()
		local conflicts, warnings, _commands, cleanup = load_with_macos_preferences([[
{
    TrackpadThreeFingerTapGesture = 0;
    TrackpadThreeFingerHorizSwipeGesture = 0;
    TrackpadThreeFingerVertSwipeGesture = 0;
}
]])
		conflicts.apply_all_overrides({
			tap_3 = "left_click_toggle",
			swipe_3_left = "word_prev",
			swipe_3_up = "tab_prev",
		})
		helpers.assert_eq(#warnings, 0, "confirmed macOS opt-outs must leave the diagnostic clean")
		cleanup()
	end)
end)

-- Three placeholders stood here, all restating "the detector is pure, so it is
-- pause-safe" and verifying none of it. Purity IS the claim, and purity is
-- checkable: the same question must get the same answer however many times it
-- is asked, and hostile input must not change what the next caller sees.
helpers.describe("Conflicts — purity under repetition and hostile input", function()
	helpers.it("the same slot and action give the same answer every time", function()
		local first = Conflicts.on_action_changed("tap_3", "lookup")
		for _ = 1, 150 do Conflicts.on_action_changed("tap_3", "lookup") end
		local last = Conflicts.on_action_changed("tap_3", "lookup")

		helpers.assert_eq(type(last), type(first),
			"150 repetitions must not change the SHAPE of the answer — a detector that latches after the first call is the failure this covers")
		if type(first) == "table" and type(last) == "table" then
			helpers.assert_eq(last.msg, first.msg, "nor its content")
		end
	end)

	helpers.it("an unknown slot answers nil, and does not poison the next real query", function()
		local before = Conflicts.on_action_changed("tap_3", "lookup")

		helpers.assert_nil(Conflicts.on_action_changed("no_such_slot", "lookup"),
			"an unrecognised slot has no group, so there is no conflict to report")

		local after = Conflicts.on_action_changed("tap_3", "lookup")
		helpers.assert_eq(type(after), type(before),
			"a query about an unknown slot must leave the detector answering real slots exactly as before")
	end)

	helpers.it("non-ASCII and empty action names answer without crashing", function()
		-- Called directly rather than through pcall: a throw fails this test with
		-- the real stack, where a pcall status would prove only that it returned.
		for _, action in ipairs({ "", "lookup ✎", "aç\tion" }) do
			local w = Conflicts.on_action_changed("tap_3", action)
			helpers.assert_true(w == nil or type(w) == "table",
				"the answer for action " .. string.format("%q", action) .. " must be nil or a warning table, never something else")
		end
	end)
end)





-- =========================================
-- =========================================
-- ======= 2/ apply_all_overrides ===========
-- =========================================
-- =========================================

helpers.describe("Conflicts.apply_all_overrides", function()
	helpers.it("does not error with an empty actions table", function()
		Conflicts.apply_all_overrides({})
	end)

	helpers.it("does not error with active actions", function()
		Conflicts.apply_all_overrides({ tap_3 = "lookup", swipe_3_up = "ms" })
	end)
end)




-- =========================================
-- =========================================
-- ======= 3/ restore_all_overrides =========
-- =========================================
-- =========================================

helpers.describe("Conflicts.restore_all_overrides", function()
	helpers.it("is a no-op", function()
		Conflicts.restore_all_overrides()
	end)
end)

-- The detector RETURNS a warning; it never acts on one. That separation is the
-- real invariant behind the two placeholders removed from here — one of which
-- claimed the dispatch layer drops warnings while paused, which is a property of
-- the dispatch layer and not of this module.
helpers.describe("Conflicts — the detector reports, it never acts", function()
	helpers.it("the module does not reach for any user-visible surface", function()
		local src = helpers.read_driver_source("local function macos_gesture_is_disabled")
		helpers.assert_true(src ~= nil, "modules/gestures/conflicts.lua source must be locatable")
		for _, forbidden in ipairs({ "hs.alert", "hs.dialog", "hs.menubar", "hs.notify" }) do
			helpers.assert_true(src:find(forbidden, 1, true) == nil,
				"conflicts.lua must not call " .. forbidden .. " — it returns a warning for its caller to decide about, and a detector that shows its own dialog cannot be silenced by a paused caller")
		end
	end)

	helpers.it("200 checks leave the answer unchanged", function()
		local before = Conflicts.on_action_changed("tap_2", "lookup")
		for _ = 1, 200 do Conflicts.on_action_changed("tap_2", "lookup") end
		local after = Conflicts.on_action_changed("tap_2", "lookup")
		helpers.assert_eq(type(after), type(before),
			"the detector must be stateless across calls — the placeholder this replaces ran the same 200 iterations and asserted nothing about them")
	end)
end)
