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

	-- The runtime transaction helper is unique to the master item and survives
	-- changing how the desired boolean is computed. Anchoring on the old assignment
	-- made this pause guard red when the toggle became transactional.
	local owner_at = src:find("local function commit_shortcuts_runtime", 1, true)
	helpers.assert_true(owner_at ~= nil, "the Shortcuts master toggle owner must be locatable")
	if not owner_at then return "" end

	local item_at = src:find("local item = {", owner_at, true)
	helpers.assert_true(item_at ~= nil, "the toggle's item table must be locatable")
	if not item_at then return "" end
	local end_at = src:find("-- ===== 2.1) Shortcut Item Factory Helpers =====", item_at, true)
	helpers.assert_true(end_at ~= nil, "the master item must end before subsection 2.1")
	if not end_at then return "" end

	return src:sub(item_at, end_at - 1)
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
		-- `action`, the provider field, since the tray root became row data on
		-- 2026-08-07. The rule is the one that matters and it did not change: the
		-- CALLBACK — whatever the field holding it is called — must not exist while
		-- paused.
		helpers.assert_true(item:find("action%s*=%s*%(not paused%)") ~= nil,
			"the handler must be gated with `action = (not paused) and function`. `disabled` "
			.. "alone is a rendering hint: enabling the feature mid-pause would bind every hotkey "
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
