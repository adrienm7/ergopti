--- tests/unit/shortcuts/engine/text_actions/fifo/test_cross_family_clipboard_admission.lua
--- Actual Text and Apps owners share one native board: a family that borrows the
--- clipboard is never snapshotted by another family as the user's original.
local helpers = require("tests.helpers")
local World = require("tests.support.modules.shortcuts.apps_fifo_capture_fixture")
local Destination = require("tests.support.text_destination_receipt")

--- Runs one scenario with the actual Text owner composed into the Apps world.
local function with_text_and_apps(body)
	helpers.with_fresh_modules({ "shortcuts.engine.actions.text", "hotstrings.engine.expander.utils" }, function()
		World.with_world({}, function(w)
			Destination.install()
			local board = hs.pasteboard
			board.setContents = function(text)
				return board.writeAllData({ ["public.utf8-plain-text"] = text })
			end
			local Text = require("shortcuts.engine.actions.text")
			body(w, Text)
			w.advance(2)
			helpers.assert_true(Text.stop_text_actions(), "Text settles")
		end)
	end)
end

helpers.describe("Clipboard borrowers share one admission (clipboard-cross-family-admission)", function()
	helpers.it("(clipboard-cross-family-admission) plain paste alone restores every original type", function()
		with_text_and_apps(function(w, Text)
			helpers.assert_true(Text.paste_as_plain_text())
			w.advance(2)
			helpers.assert_true(Text.stop_text_actions())
			helpers.assert_true(w.clipboard() == w.original, "the HTML type is restored too")
		end)
	end)

	helpers.it("(clipboard-cross-family-admission) Apps refuses while plain paste borrows the clipboard", function()
		with_text_and_apps(function(w, Text)
			helpers.assert_true(Text.paste_as_plain_text())
			helpers.assert_eq(w.clipboard()["public.html"], nil, "the plain payload borrows the clipboard")
			helpers.assert_eq(w.apps.copy_or_open_path(), false,
				"Apps must not snapshot the borrowed payload as the user's clipboard")
			w.advance(2)
			helpers.assert_true(Text.stop_text_actions())
			helpers.assert_true(w.clipboard() == w.original, "the original HTML type survives")
			local copies = w.counts()
			helpers.assert_eq(copies, 0, "Apps never copied")
		end)
	end)

	helpers.it("(clipboard-cross-family-admission) plain paste refuses while Apps borrows the clipboard", function()
		with_text_and_apps(function(w, Text)
			helpers.assert_true(w.apps.copy_or_open_path())
			helpers.assert_eq(Text.paste_as_plain_text(), false,
				"Text must not snapshot the Apps capture as the user's clipboard")
			w.advance(2)
			helpers.assert_true(w.clipboard() == w.original, "Apps restores the original")
		end)
	end)

	helpers.it("(clipboard-cross-family-admission) the admission ignores the asker and fails closed", function()
		helpers.with_fresh_modules({ "clipboard.borrowers" }, function()
			local Borrowers = require("clipboard.borrowers")
			local held = false
			Borrowers.register("one", function() return held end)
			helpers.assert_nil(Borrowers.foreign_holder("two"), "an idle family holds nothing")
			held = true
			helpers.assert_eq(Borrowers.foreign_holder("two"), "one")
			helpers.assert_nil(Borrowers.foreign_holder("one"), "a family never refuses itself")
			Borrowers.register("broken", function() error("predicate failure") end)
			helpers.assert_eq(Borrowers.foreign_holder("one"), "broken", "a raising predicate counts as holding")
		end)
	end)
end)
