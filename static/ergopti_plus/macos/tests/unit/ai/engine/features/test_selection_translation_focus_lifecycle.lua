--- tests/unit/ai/engine/features/test_selection_translation_focus_lifecycle.lua

--- ==============================================================================
--- MODULE: Selection Translation Focus Lifecycle
--- DESCRIPTION:
--- Runs the real selection, model and text pipeline over two native-window
--- identities containing identical selections. Copy and paste timers must never
--- transfer a translation, or its reselection, to the other window.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.llm.selection_translation_fixture")
local SOURCE, RESULT = "Hello", "Translated"

--- Delivers one native text timer, excluding its ownership failsafe.
--- @param world table Pipeline fixture.
local function step(world)
	for index = world.timer_baseline + 1, #hs.timer.__timers do
		local timer = hs.timer.__timers[index]
		if timer.running and timer.fired == 0 and (tonumber(timer.delay) or 0) < 1.5 then
			timer:fire()
			return
		end
	end
	error("the expected native text stage was not scheduled")
end

--- Starts an accepted translation without delivering its replacement timers.
--- @param world table Pipeline fixture.
local function accept_without_settling(world)
	helpers.assert_true(world.flow.run("en"))
	Fixture.settle(world)
	helpers.assert_eq(#world.posts, 1)
	Fixture.answer(world.posts[1], "TRANSLATION: " .. RESULT)
	local candidate = world.engine.consume(1)
	helpers.assert_not_nil(candidate)
	helpers.assert_true(candidate.on_accept(candidate.to_type))
end

helpers.describe("selection translation retains its original focus", function()
	helpers.it("keeps a healthy selection translation working (translation-focus-positive)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			accept_without_settling(world)
			Fixture.settle(world)
			helpers.assert_eq(world.document[1], RESULT)
			helpers.assert_eq(#world.document, 1)
			helpers.assert_eq(world.selection, RESULT)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("refuses unknown focus before copying (translation-focus-unknown)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			world.focus = nil
			helpers.assert_eq(world.flow.run("en"), false)
			helpers.assert_eq(#world.keys, 0)
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("refuses an unidentifiable native window before copying", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			local retained = package.loaded["platform.focus.window_info"]
			package.loaded["platform.focus.window_info"] = nil
			local real = require("platform.focus.window_info")
			package.loaded["platform.focus.window_info"] = retained
			retained.focused_identity = real.focused_identity
			-- Hammerspoon emits id 0 when _AXUIElementGetWindow failed.
			world.native_destination.change_focus("7:0")
			Fixture.settle(world)
			helpers.assert_eq(world.flow.run("en"), false, "zero is not a proved window identity")
			helpers.assert_eq(#world.keys, 0, "the selection must not be copied")
			helpers.assert_eq(#world.posts, 0)
			world.native_destination.change_focus("7:101")
			Fixture.settle(world)
			helpers.assert_eq(world.flow.run("en"), true, "a proved window remains usable")
		end)
	end)

	helpers.it("transforms a stable selection without probing AX in the initiating callback", function()
		Fixture.with_world("Mixed", "fr", function(world)
			local text = require("modules.shortcuts.actions.text")
			local before = world.native_destination.reads
			helpers.assert_eq(text.selection_uppercase("gestures"), true)
			helpers.assert_eq(world.native_destination.reads, before, "initial admission is RAM-only")
			helpers.assert_eq(world.keys[1], { mods = "cmd", key = "c" }, "the original copy is emitted")
			Fixture.settle(world)
			helpers.assert_eq(world.document, { "MIXED" })
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("refuses an unknown destination and allows a fresh retry after focus recovers", function()
		Fixture.with_world("Mixed", "fr", function(world)
			local text = require("modules.shortcuts.actions.text")
			world.native_destination.change_focus(nil)
			Fixture.settle(world)
			helpers.assert_eq(text.selection_uppercase("gestures"), false)
			helpers.assert_eq(#world.keys, 0)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
			world.native_destination.change_focus("7:101")
			Fixture.settle(world)
			helpers.assert_eq(text.selection_uppercase("gestures"), true)
			Fixture.settle(world)
			helpers.assert_eq(world.document, { "MIXED" })
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("does not load a missing destination tracker on the input callback", function()
		Fixture.with_world("Mixed", "fr", function(world)
			local text = require("modules.shortcuts.actions.text")
			local tracked = package.loaded["modules.keymap.utils"]
			package.loaded["modules.keymap.utils"] = nil
			local ok, result = pcall(text.selection_uppercase, "gestures")
			local loaded_during_call = package.loaded["modules.keymap.utils"]
			package.loaded["modules.keymap.utils"] = tracked
			helpers.assert_true(ok)
			helpers.assert_eq(result, false)
			helpers.assert_nil(loaded_during_call)
			helpers.assert_eq(#world.keys, 0)
		end)
	end)

	helpers.it("refuses a destination whose native window number is unavailable", function()
		Fixture.with_world("Mixed", "fr", function(world)
			local text = require("modules.shortcuts.actions.text")
			world.native_destination.change_focus("7:0")
			Fixture.settle(world)
			helpers.assert_eq(text.selection_uppercase("gestures"), false)
			helpers.assert_eq(#world.keys, 0)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("does not paste an uppercase selection after focus moves", function()
		Fixture.with_world("Mixed", "fr", function(world)
			local text = require("modules.shortcuts.actions.text")
			helpers.assert_eq(text.selection_uppercase("gestures"), true)
			step(world) -- Cmd+C has completed and its clipboard text is ready.
			world.native_destination.change_focus("8:202")
			world.selection = "other"
			Fixture.settle(world)
			helpers.assert_eq(#world.document, 0, "a delayed paste must not target the new window")
			helpers.assert_eq(world.selection, "other")
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("does not revive a transform after focus leaves and returns", function()
		Fixture.with_world("Mixed", "fr", function(world)
			local text = require("modules.shortcuts.actions.text")
			helpers.assert_eq(text.selection_uppercase("gestures"), true)
			step(world)
			world.native_destination.change_focus("8:202")
			world.native_destination.change_focus("7:101")
			Fixture.settle(world)
			helpers.assert_eq(#world.document, 0, "a previous generation cannot be revived")
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("does not rebind a copied selection to another window (translation-focus-copy)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			helpers.assert_true(world.flow.run("en"))
			world.focus = "8:202"
			world.selection = SOURCE
			Fixture.settle(world)
			helpers.assert_eq(#world.posts, 0, "the original selection must not be sent as the new window's text")
			helpers.assert_eq(world.loadings, 0)
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("refuses focus lost during the acceptance copy (translation-focus-accept-copy)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			accept_without_settling(world)
			world.focus = "8:202"
			world.selection = SOURCE
			Fixture.settle(world)
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.selection, SOURCE)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("refuses focus lost after copy but before paste (translation-focus-paste)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			accept_without_settling(world)
			step(world)
			helpers.assert_eq(world.clipboard, RESULT, "the matching copy must already have prepared the paste")
			world.focus = "8:202"
			world.selection = SOURCE
			Fixture.settle(world)
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.selection, SOURCE)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("does not reselect text in the new window after paste (translation-focus-reselect)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			accept_without_settling(world)
			step(world)
			step(world)
			helpers.assert_eq(world.document[1], RESULT, "the original window must have received the accepted paste")
			world.focus = "8:202"
			world.selection = SOURCE
			Fixture.settle(world)
			helpers.assert_eq(#world.document, 1)
			helpers.assert_eq(world.selection, SOURCE, "no cursor operation may target the newly focused window")
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("cancels an accepted replacement across reset (translation-focus-reset)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			accept_without_settling(world)
			world.flow.reset()
			Fixture.settle(world)
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.selection, SOURCE)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)
end)
