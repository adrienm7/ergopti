--- tests/unit/gestures/engine/actions/test_emit_actions.lua

--- ==============================================================================
--- MODULE: Gesture Emit-Action Registration (macOS)
--- DESCRIPTION:
--- The 27 actions macOS performs as a plain keystroke are registered from the
--- shared catalogue, and each must emit its own keystroke.
---
--- WHAT THIS DOES NOT DO, AND WHY:
--- It does not invoke a handler and observe the keystroke. The single-gesture
--- registry `SG` is a private local that the module never exports, so a test can
--- only reach it by guessing at an accessor that does not exist. A first draft
--- of this file did exactly that and fell back to `assert_true(true, …)` when the
--- guess failed — a tautology that would have passed forever while testing
--- nothing, and the false-green ratchet caught it. Rather than add a production
--- accessor purely for the test, the assertions below pin the generated rows,
--- which is where a wrong keystroke would actually come from.
---
--- The loop that registers these is safe in Lua by language guarantee: a generic
--- `for` binds fresh locals each iteration, so every closure keeps its own row.
--- The AHK twin has no such guarantee — an AHK loop closure captures the loop
--- VARIABLE — which is why that side builds its emitters in helper functions and
--- pins the construction instead.
---
--- The macOS values are NOT the Windows ones: of the 24 actions both drivers
--- implement as a keystroke, 15 differ. Asserting the real macOS keystrokes here
--- is what stops a future "share the rows" change from silently sending
--- ctrl+Right where macOS needs alt+right.
--- ==============================================================================

local helpers = require("tests.helpers")



-- =============================================================
-- =============================================================
-- ======= 1/ Every catalogue-declared action registers ========
-- =============================================================
-- =============================================================

helpers.describe("gesture emit actions (macOS)", function()

	helpers.it("the generated table is populated", function()
		local rows = require("_generated.gesture_emit_actions")
		helpers.assert_true(type(rows) == "table",
			"_generated/gesture_emit_actions.lua must return a table")
		helpers.assert_true(#rows >= 20,
			"the generated table carries only " .. tostring(#rows) .. " row(s) — a near-empty "
			.. "table would mean 27 gesture actions silently do nothing, and would make every "
			.. "assertion below vacuous")
	end)

	helpers.it("every generated row has a key and a modifier list", function()
		local rows = require("_generated.gesture_emit_actions")
		for _, row in ipairs(rows) do
			helpers.assert_true(type(row.id) == "string" and row.id ~= "",
				"every row needs an id")
			helpers.assert_true(type(row.key) == "string" and row.key ~= "",
				row.id .. ": a row with no key emits nothing")
			helpers.assert_true(type(row.mods) == "table",
				row.id .. ": mods must be a list, even when empty")
		end
	end)

	helpers.it("emits the macOS keystroke, not the Windows one", function()
		-- word_next is the clearest case: macOS moves by word with Option,
		-- Windows with Control. Sending ctrl+right on macOS does nothing at all,
		-- which is precisely the failure a shared row would have introduced.
		local rows = require("_generated.gesture_emit_actions")
		local by_id = {}
		for _, row in ipairs(rows) do by_id[row.id] = row end

		local word_next = by_id["word_next"]
		helpers.assert_true(word_next ~= nil, "word_next must be declared for macOS")
		helpers.assert_eq(word_next.key, "right", "word_next moves right on macOS")
		helpers.assert_eq(table.concat(word_next.mods, ","), "alt",
			"word_next must use Option on macOS. Windows uses Control for the same action; "
			.. "sending ctrl+right here does nothing, and no other test would catch it.")

		local close_window = by_id["close_window"]
		helpers.assert_true(close_window ~= nil, "close_window must be declared for macOS")
		helpers.assert_eq(close_window.key, "w", "macOS closes a window with cmd+w, not alt+F4")
		helpers.assert_eq(table.concat(close_window.mods, ","), "cmd")
	end)

	helpers.it("goes back and forward in the browser history with Cmd+arrow (action-parity-nav-history)", function()
		-- nav_back and nav_forward were Windows-only, though every macOS browser
		-- answers Cmd+Left and Cmd+Right. Cmd+[ is not used: the key typing "["
		-- moves with the keyboard layout, the arrows do not.
		local by_id = {}
		for _, row in ipairs(require("_generated.gesture_emit_actions")) do by_id[row.id] = row end
		for id, key in pairs({ nav_back = "left", nav_forward = "right" }) do
			helpers.assert_true(by_id[id] ~= nil, id .. " must be declared for macOS")
			helpers.assert_eq(by_id[id].key, key, id .. " key")
			helpers.assert_eq(table.concat(by_id[id].mods, ","), "cmd", id .. " modifiers")
		end
	end)

	helpers.it("presses Space from a binding, as on Windows and Linux (action-parity-space)", function()
		-- space was a Windows and Linux tap-hold value only; macOS had no row,
		-- so a shared tap-hold layout could not put Space on a key there.
		local by_id = {}
		for _, row in ipairs(require("_generated.gesture_emit_actions")) do by_id[row.id] = row end
		helpers.assert_true(by_id.space ~= nil, "space must be declared for macOS")
		helpers.assert_eq(by_id.space.key, "space")
		helpers.assert_eq(#by_id.space.mods, 0, "a bare Space, without Command (that is Spotlight)")
	end)

end)
