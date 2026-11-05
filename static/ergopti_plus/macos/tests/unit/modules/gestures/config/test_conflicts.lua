--- tests/unit/modules/gestures/config/test_conflicts.lua

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
--- @return table, table, table, function, table Module, warning entries, commands, cleanup, info entries.
local function load_with_macos_preferences(defaults_output)
	local warnings = {}
	local infos = {}
	local commands = {}
	package.loaded["modules.gestures.conflicts"] = nil
	package.loaded["infra.logger"] = {
		debug   = function() end,
		info    = function(_, message, ...) table.insert(infos, string.format(message, ...)) end,
		warn    = function(_, message) table.insert(warnings, message) end,
		error   = function(_, message) table.insert(warnings, message) end,
		start   = function() end,
		success = function() end,
		trace   = function() end,
		done    = function() end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(command, args, callback)
			table.insert(commands, { command, args })
			callback(0, defaults_output, "")
			return { isSettled = function() return true end }
		end,
	}

	local conflicts = helpers.load_with_stubs("modules.gestures.conflicts")
	conflicts.refresh()
	local function cleanup()
		package.loaded["modules.gestures.conflicts"] = nil
		package.loaded["infra.logger"] = nil
		package.loaded["adapters.shell_runner"] = nil
	end
	return conflicts, warnings, commands, cleanup, infos
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
		helpers.assert_eq(#commands, 4, "all current Trackpad and Dock preference sources must be queried")
		cleanup()
	end)

	helpers.it("keeps the warning when any current macOS source still enables the native gesture", function()
		local conflicts, warnings, _commands, cleanup, infos = load_with_macos_preferences([[
{
    TrackpadThreeFingerHorizSwipeGesture = 2;
    com.apple.trackpad.threeFingerHorizSwipeGesture = 0;
}
]])
		local warning = conflicts.on_action_changed("swipe_3_left", "word_prev")
		helpers.assert_type(warning, "table", "an enabled native gesture remains a real conflict")
		helpers.assert_eq(#infos, 1, "the real conflict must remain visible in the diagnostics")
		helpers.assert_eq(#warnings, 0, "an overlap the user chose and is told about is no warning")
		cleanup()
	end)

	helpers.it("logs a conflict once however many menu rebuilds ask for it (issue #95)", function()
		local conflicts, warnings, _commands, cleanup, infos = load_with_macos_preferences([[
{
    TrackpadThreeFingerTapGesture = 2;
    TrackpadThreeFingerHorizSwipeGesture = 2;
}
]])
		local actions = { tap_3 = "lookup", swipe_3_left = "word_prev" }
		for _ = 1, 20 do
			helpers.assert_eq(#conflicts.active_conflicts(actions), 2, "every rebuild still gets its warnings")
		end
		helpers.assert_type(conflicts.on_action_changed("tap_3", "lookup"), "table")
		helpers.assert_eq(#infos, 2, "one line per conflicting group, not one per query")
		helpers.assert_eq(#warnings, 0)
		cleanup()
	end)

	helpers.it("does not warn at startup for blank gesture values", function()
		local conflicts, warnings, _commands, cleanup = load_with_macos_preferences([[
{
    TrackpadThreeFingerVertSwipeGesture = 2;
}
]])
		helpers.assert_eq(#conflicts.active_conflicts({ swipe_3_up = "   ", swipe_3_down = "" }), 0)
		helpers.assert_eq(#warnings, 0, "blank assignments must be treated as disabled gestures")
		cleanup()
	end)

	helpers.it("suppresses every active startup warning whose native gesture is confirmed disabled", function()
		local conflicts, warnings, _commands, cleanup = load_with_macos_preferences([[
{
    TrackpadThreeFingerTapGesture = 0;
    TrackpadThreeFingerHorizSwipeGesture = 0;
    TrackpadThreeFingerVertSwipeGesture = 0;
    TrackpadThreeFingerDrag = 0;
}
]])
		local active = conflicts.active_conflicts({
			tap_3 = "left_click_toggle",
			swipe_3_left = "word_prev",
			swipe_3_up = "tab_prev",
		})
		helpers.assert_eq(#active, 0, "both native motion policies must be off")
		helpers.assert_eq(#warnings, 0, "confirmed macOS opt-outs must leave the diagnostic clean")
		cleanup()
	end)
end)

-- Never a double action (maintainer, 2026-11-03): a slot whose macOS gesture
-- is on is taken, greyed in the menu and held back by the engine, and comes
-- back once the macOS gesture is off. The preferences come from an injected
-- defaults reader; nothing is ever written.
helpers.describe("Conflicts — slots taken by a macOS gesture", function()
	helpers.it("takes the slots of every macOS gesture that is on, and only those", function()
		local conflicts, _warnings, _commands, cleanup = load_with_macos_preferences([[
{
    TrackpadFourFingerHorizSwipeGesture = 2;
    TrackpadFourFingerVertSwipeGesture = 2;
    TrackpadThreeFingerTapGesture = 0;
    TrackpadThreeFingerHorizSwipeGesture = 0;
    TrackpadThreeFingerVertSwipeGesture = 0;
    TrackpadThreeFingerDrag = 0;
    showAppExposeGestureEnabled = 0;
}
]])
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_left"), "taken", "Spaces takes the four-finger swipes")
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_up"), "taken", "Mission Control is on by default")
		helpers.assert_eq(conflicts.slot_system_state("swipe_5_up"), "taken")
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_down"), "free", "App Exposé is off in the Dock")
		helpers.assert_eq(conflicts.slot_system_state("tap_3"), "free", "Look up is off")
		helpers.assert_eq(conflicts.slot_system_state("swipe_3_left"), "free")
		helpers.assert_eq(conflicts.slot_system_state("swipe_2_left_up"), "free", "two-finger touches never block")
		helpers.assert_true(conflicts.slot_held_by_system("swipe_4_right"))
		helpers.assert_true(not conflicts.slot_held_by_system("tap_3"))
		cleanup()
	end)

	helpers.it("frees every slot once the macOS gestures are off, App Exposé included", function()
		local conflicts, _warnings, _commands, cleanup = load_with_macos_preferences([[
{
    TrackpadFourFingerHorizSwipeGesture = 0;
    TrackpadFourFingerVertSwipeGesture = 2;
    showMissionControlGestureEnabled = 0;
    showAppExposeGestureEnabled = 1;
    TrackpadThreeFingerTapGesture = 2;
}
]])
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_left"), "free")
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_up"), "free", "Mission Control is off in the Dock")
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_down"), "taken", "App Exposé is on")
		helpers.assert_eq(conflicts.slot_system_state("tap_3"), "taken", "Look up is on")
		cleanup()
	end)

	helpers.it("holds the slots when the read returned nothing, and frees nothing before the first read", function()
		local conflicts, _warnings, _commands, cleanup = load_with_macos_preferences("")
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_left"), "unverified")
		helpers.assert_true(conflicts.slot_held_by_system("swipe_4_left"), "an unverified slot is held too")
		cleanup()
		package.loaded["modules.gestures.conflicts"] = nil
		local fresh = helpers.load_with_stubs("modules.gestures.conflicts")
		helpers.assert_eq(fresh.slot_system_state("swipe_4_left"), "free", "nothing is known before the boot read")
		package.loaded["modules.gestures.conflicts"] = nil
	end)

	helpers.it("rechecks: a macOS gesture turned on, then off, greys then restores its slot", function()
		local output = "{\n    TrackpadFourFingerHorizSwipeGesture = 0;\n}\n"
		local conflicts, _warnings, _commands, cleanup = load_with_macos_preferences(output)
		package.loaded["adapters.shell_runner"].spawn = function(_command, _args, callback)
			callback(0, output, "")
			return { isSettled = function() return true end }
		end
		local changes = 0
		conflicts.set_state_listener(function() changes = changes + 1 end)
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_left"), "free")
		output = "{\n    TrackpadFourFingerHorizSwipeGesture = 2;\n}\n"
		conflicts.recheck()
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_left"), "taken", "turned on: taken")
		helpers.assert_eq(changes, 1, "the menu is asked to rebuild")
		conflicts.recheck()
		helpers.assert_eq(changes, 1, "an unchanged read asks for nothing")
		output = "{\n    TrackpadFourFingerHorizSwipeGesture = 0;\n}\n"
		conflicts.recheck()
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_left"), "free", "turned off: back by itself")
		helpers.assert_eq(changes, 2)
		cleanup()
	end)

	helpers.it("arms one recheck timer and stops it at shutdown", function()
		local conflicts, _warnings, _commands, cleanup = load_with_macos_preferences("")
		local armed, cancelled = 0, 0
		local scheduler = {
			every = function(_interval, _fn) armed = armed + 1; return { id = armed }, true end,
			cancel = function() cancelled = cancelled + 1 end,
		}
		helpers.assert_true(conflicts.start_watch(scheduler))
		helpers.assert_true(conflicts.start_watch(scheduler))
		helpers.assert_eq(armed, 1, "a second start reuses the armed timer")
		conflicts.restore_all_overrides()
		helpers.assert_eq(cancelled, 1, "shutdown stops the recheck")
		cleanup()
	end)

	helpers.it("never writes a macOS preference", function()
		local src = helpers.read_driver_source("local function macos_gesture_is_disabled")
		helpers.assert_true(src ~= nil)
		helpers.assert_true(src:find('"write"', 1, true) == nil and src:find("'write'", 1, true) == nil,
			"the conflict module only reads the Trackpad and Dock preferences")
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

-- Field report 2026-11-05: ShellRunner.spawn only prepares a task, and the read
-- was never started, so no gesture macOS claims was greyed or held back.
helpers.describe("Conflicts — the macOS settings read is started", function()
	helpers.it("starts every prepared read and greys the four-finger swipe macOS uses", function()
		local started, pending = 0, {}
		package.loaded["modules.gestures.conflicts"] = nil
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.shell_runner"] = {
			spawn = function(_, _, callback)
				local settled = false
				local handle = { isSettled = function() return settled end }
				handle.start = function()
					started = started + 1
					pending[#pending + 1] = function()
						settled = true
						callback(0, "{\n    TrackpadFourFingerVertSwipeGesture = 2;\n}\n", "")
					end
					return true
				end
				return handle
			end,
		}
		local conflicts = helpers.load_with_stubs("modules.gestures.conflicts")
		conflicts.refresh()
		helpers.assert_eq(started, 4, "each prepared read must be started")
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_up"), "free", "nothing is held before the read ends")
		for _, finish in ipairs(pending) do finish() end
		helpers.assert_eq(conflicts.slot_system_state("swipe_4_up"), "taken")
		package.loaded["modules.gestures.conflicts"] = nil
		package.loaded["infra.logger"] = nil
		package.loaded["adapters.shell_runner"] = nil
	end)
end)
