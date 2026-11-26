--- menu/ui/builder/shortcut_hint.lua

--- ==============================================================================
--- MODULE: Tray Shortcut Hints
--- DESCRIPTION:
--- Shows, beside « Suspendre », « Recharger » and « Quitter », the chord that
--- runs the same action (maintainer, 2026-11-24), in the grey of a secondary
--- label, as Windows shows it after a tab and Linux in the label text.
---
--- FEATURES & RATIONALE:
--- 1. The chord is the one the Shortcuts submenu names (menu.ui.script_chord_labels)
---    for the slot the shared rule picks (keyboard.engine.layers.script_chords,
---    hint_slot): the first slot whose live chord runs the action.
--- 2. A styled title, not a native key equivalent: an NSMenu key equivalent
---    is one key with Command, Option, Control or Shift and cannot name the
---    right Option key alone, nor a chord typed as a sequence.
--- 3. Applied to the finished root, after its compositions: the declared root
---    compositions admit string titles only, while hs.menubar draws a styled
---    one. A row is found by its declared caption (menu.engine.tray_shortcut_hints),
---    so the top-level row builders stay as they are. The checkmark and the
---    disabled state stay row fields; a disabled row greys its styled text
---    itself, which AppKit does not do for it.
--- ==============================================================================

local M = {}
local Logger = require("core.logger.engine.logger")
local CanvasBadge = require("menu.ui.builder.canvas_badge")
local ChordLabels = require("menu.ui.script_chord_labels")
local StyledTitle = require("core.ui.adapters.styled_title")
local TrayHints = require("menu.engine.tray_shortcut_hints")
local i18n = require("core.i18n.engine.i18n")

local LOG = "menu.shortcut_hint"

-- AppKit's semantic colours, which follow the light and dark appearance.
local HINT_COLOR = { list = "System", name = "secondaryLabelColor" }
local DISABLED_COLOR = { list = "System", name = "disabledControlTextColor" }

-- What separates a row's label from its hint.
local HINT_GAP = "    "

--- The chord shown beside a tray row, nil when no chord runs its action.
--- @param script_control table|nil The script control owner (ctx.script_control).
--- @param action string The row's action id.
--- @return string|nil hint
function M.text(script_control, action)
	if type(script_control) ~= "table" or type(script_control.script_chord_hint_slot) ~= "function" then
		Logger.error(LOG, "The script control owner is absent — the '%s' row shows no shortcut.", tostring(action))
		return nil
	end
	local slot = script_control.script_chord_hint_slot(action)
	if slot == nil then return nil end
	return ChordLabels.label(slot)
end

--- A row title followed by its hint in the secondary label colour.
--- @param label string The row's title.
--- @param hint string The chord's name.
--- @param disabled boolean Whether the row is greyed.
--- @return any title An hs.styledtext (core.ui.adapters.styled_title).
function M.title(label, hint, disabled)
	local font = CanvasBadge.menu_font()
	local body = { font = font }
	if disabled then body.color = DISABLED_COLOR end
	return StyledTitle.compose({
		{ text = label, attributes = body },
		{ text = HINT_GAP .. hint, attributes = { font = font, color = disabled and DISABLED_COLOR or HINT_COLOR } },
	})
end

--- Styles the titles of the finished root rows of Suspend, Reload and Quit
--- whose action a chord runs.
--- @param rows table The finished root, in place.
--- @param script_control table|nil The script control owner (ctx.script_control).
--- @return number count The rows styled.
function M.decorate(rows, script_control)
	local captions = TrayHints.captions(require("menu.engine.manifest_menu").get_array("top_level"), "hs", i18n.get)
	return TrayHints.decorate(rows, captions, function(action) return M.text(script_control, action) end,
		function(row, hint) return M.title(row.title, hint, row.disabled == true) end)
end

--- The titles M.decorate will give the finished root rows, without changing
--- them: the header pill measures the rows before the hints are drawn (the
--- root compositions admit string titles only), and a hint row is often the
--- widest one.
--- @param rows table The finished root, left unchanged.
--- @param script_control table|nil The script control owner (ctx.script_control).
--- @return table titles Row -> its hinted title, for the hinted rows only.
function M.preview(rows, script_control)
	local probes, origins = {}, {}
	for _, row in ipairs(rows) do
		if type(row) == "table" then
			probes[#probes + 1] = { title = row.title, disabled = row.disabled }
			origins[#probes] = row
		end
	end
	M.decorate(probes, script_control)
	local titles = {}
	for index, probe in ipairs(probes) do
		local row = origins[index]
		if not rawequal(probe.title, row.title) then titles[row] = probe.title end
	end
	return titles
end

return M
