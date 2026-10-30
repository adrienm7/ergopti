--- tests/unit/ui/menu/keyboard_layout/test_layout_scope_participant.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Scope Participant (macOS)
--- DESCRIPTION:
--- A global restore or clear that changes the number-row rows settles only once
--- the layout typing them was built and selected (docs/design/
--- layout-option-emulation.md, section 5); a layout the system did not take
--- reverts the rows; a choice with no layout of ours is acknowledged with its
--- reason (layout-scope-participant).
--- ==============================================================================

local helpers = require("tests.helpers")
local GlobalScope = require("ui.menu.global_scope")

--- A synchronous participant whose apply changes the stored rows.
local function world(live_answer)
	local w = { rows = { order = "native", edges = false }, reverted = 0, live_calls = {} }
	w.synchronous = {
		pending = function() return false end,
		apply = function(_, done)
			w.rows = { order = "symbols", edges = false }
			done(true)
		end,
		revert = function(done)
			w.reverted = w.reverted + 1
			w.rows = { order = "native", edges = false }
			done(true)
		end,
		release = function() return true end,
		retry_restore = function(done) done(true) end,
	}
	w.live = {
		REASON_NO_SOURCE = "no_source_layout",
		apply = function(rows, on_done)
			w.live_calls[#w.live_calls + 1] = rows
			-- Held until the test answers, as the live build answers later.
			w.answer = function() on_done(live_answer[1], live_answer[2]) end
			return true
		end,
	}
	w.participant = GlobalScope.layout_participant(w.synchronous,
		{ rows = function() return w.rows end, live = w.live }, function(fn) fn(); return true end)
	return w
end

helpers.describe("keyboard layout scope participant: settles on the typing layout (layout-scope-participant)", function()
	helpers.it("settles only once the live build answered", function()
		local w = world({ true, nil })
		local settled
		w.participant.apply("recommended", function(ok, detail) settled = { ok, detail } end)
		helpers.assert_nil(settled, "the request settled before the layout was selected")
		helpers.assert_eq(w.participant.pending(), true)
		helpers.assert_eq(#w.live_calls, 1)
		helpers.assert_eq(w.live_calls[1].order, "symbols")
		w.answer()
		helpers.assert_eq(settled[1], true)
		helpers.assert_eq(w.participant.pending(), false)
	end)

	helpers.it("reverts the rows when the system did not take the layout", function()
		local w = world({ false, "readback_mismatch" })
		local settled
		w.participant.apply("recommended", function(ok, detail) settled = { ok, detail } end)
		w.answer()
		helpers.assert_eq(settled[1], false)
		helpers.assert_contains(settled[2], "readback_mismatch")
		helpers.assert_eq(w.reverted, 1)
		helpers.assert_eq(w.rows.order, "native")
	end)

	helpers.it("acknowledges a choice with no layout of ours with its reason", function()
		local w = world({ false, "no_source_layout" })
		local settled
		w.participant.apply("clear", function(ok, detail) settled = { ok, detail } end)
		w.answer()
		helpers.assert_eq(settled[1], true)
		helpers.assert_eq(settled[2], "no_source_layout")
		helpers.assert_eq(w.reverted, 0)
	end)

	helpers.it("settles at once when the rows did not change", function()
		local w = world({ true, nil })
		w.synchronous.apply = function(_, done) done(true) end
		local settled
		w.participant.apply("recommended", function(ok, detail) settled = { ok, detail } end)
		helpers.assert_eq(settled[1], true)
		helpers.assert_eq(settled[2], "rows_unchanged")
		helpers.assert_eq(#w.live_calls, 0)
	end)
end)
