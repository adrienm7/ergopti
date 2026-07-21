--- tests/unit/ui/menu/test_shortcuts_toggle_pause_gated.lua

--- ==============================================================================
--- MODULE: Regression — the Shortcuts master toggle must be pause-gated
--- DESCRIPTION:
--- Toggling « Raccourcis » while the script was paused either did nothing that
--- survived, or bound every hotkey during a pause.
---
--- ROOT CAUSE ENCODED:
--- Pause owns the bindings axis for the whole pause window: pause_all() snapshots
--- is_bindings_started() and resume_all() restores the bindings from that
--- snapshot. A toggle made in between writes state.shortcuts and calls
--- pause_bindings/resume_bindings, but resume_all() later overwrites that with
--- the pre-pause snapshot — so the user's choice is silently discarded. Worse,
--- toggling ON binds every hotkey immediately, breaking the « pause = tout
--- éteint » invariant the pause exists to guarantee.
---
--- WHY IT WAS SILENT:
--- The menu item still rendered enabled, still flipped its checkmark, and still
--- fired its notification — every visible signal reported success. Only the
--- resume, seconds or minutes later, quietly undid it.
---
--- Every other pause-sensitive item in this file already carries the
--- `disabled = paused or nil` / `fn = (not paused) and function` pair; the master
--- toggle was the one that did not.
---
--- WHY A SOURCE GUARD:
--- build() needs a full menu context (i18n, ctx.save_prefs, ctx.updateMenu, a
--- live shortcuts module) plus a menubar to render into. What is decidable, and
--- what was actually wrong, is that the toggle's own item table carries the gate.
--- `checked` is asserted to stay ungated on purpose — it must keep reporting the
--- stored preference, and test_pause_checked_state.lua forbids `not paused` there.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Characters after the toggle's title far enough to cover its item table but not
-- to reach the next item, so a gate belonging to a sibling cannot be miscredited.
local ITEM_WINDOW_CHARS = 400





-- ===================================================
-- ===================================================
-- ======= 1/ The Master Toggle Carries A Gate =======
-- ===================================================
-- ===================================================

--- Returns the source slice covering the Shortcuts master toggle's item table.
--- @return string
local function toggle_item_source()
	-- Selected by a declaration unique to ui/menu/menu_shortcuts.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant into a
	-- path error.
	local src = helpers.read_driver_source("menu.shortcuts.title")
	helpers.assert_true(src ~= nil, "ui/menu/menu_shortcuts.lua source must be locatable")
	if not src then return "" end

	-- The master toggle is the item whose fn flips state.shortcuts; anchor on the
	-- item table that contains it rather than on any title lookup, since the same
	-- i18n key is read in more than one place.
	local flip_at = src:find("state%.shortcuts%s*=%s*not%s+state%.shortcuts")
	helpers.assert_true(flip_at ~= nil, "the Shortcuts master toggle must be locatable")
	if not flip_at then return "" end

	-- Walk back to the opening of the item table so the fields above fn are in view.
	local item_at = src:sub(1, flip_at):find("local item = {[^\0]*$")
	helpers.assert_true(item_at ~= nil, "the toggle's item table must be locatable")
	if not item_at then return "" end

	return src:sub(item_at, flip_at + ITEM_WINDOW_CHARS)
end

helpers.describe("the Shortcuts master toggle is pause-gated like its siblings", function()
	helpers.it("greys the item out while the script is paused", function()
		local item = toggle_item_source()
		helpers.assert_true(item:find("disabled%s*=%s*paused") ~= nil,
			"the master toggle must set `disabled = paused or nil`. Left enabled, a mid-pause "
			.. "toggle is silently overwritten at resume — resume_all() restores bindings from "
			.. "the snapshot pause_all() took, so the user's choice never survives")
	end)

	helpers.it("refuses to run its handler while paused", function()
		local item = toggle_item_source()
		helpers.assert_true(item:find("fn%s*=%s*%(not paused%)") ~= nil,
			"the handler must be gated with `fn = (not paused) and function`. `disabled` alone "
			.. "is a rendering hint: enabling the feature mid-pause would bind every hotkey "
			.. "while the script is supposed to be entirely off (« pause = tout éteint »)")
	end)

	helpers.it("leaves `checked` reporting the stored preference", function()
		local item = toggle_item_source()
		local checked = item:match("checked%s*=%s*([^,]+),")
		helpers.assert_true(checked ~= nil, "the toggle must still expose a `checked` field")
		helpers.assert_true(not checked:find("paused", 1, true),
			"`checked` must NOT consult the pause state — a paused script still has a stored "
			.. "Shortcuts preference, and blanking the checkmark would misreport it as off")
	end)
end)
