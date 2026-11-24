--- menu/ui/builder/shortcut_hint.lua

--- ==============================================================================
--- MODULE: Linux Tray Shortcut Hints
--- DESCRIPTION:
--- Shows, beside « Suspendre », « Recharger » and « Quitter », the chord that
--- runs the same action (maintainer, 2026-11-24): « Recharger (AltGr + ⌫) »,
--- as Windows shows it after a tab and macOS in grey.
---
--- FEATURES & RATIONALE:
--- 1. The chord is the one the Shortcuts submenu names (sg_labels.<slot>) for
---    the slot the shared rule picks (keyboard.engine.layers.script_chords,
---    hint_slot, through modules.shortcuts.script_chords): the first slot whose
---    live chord runs the action. No chord, no hint.
--- 2. In the label text, not the dbusmenu `shortcut` property: the tray
---    adapter builds plain GtkMenuItems with no accelerator for
---    libdbusmenu-gtk to export, and that property names Control, Alt, Shift
---    and Super only, never AltGr nor a chord typed as a sequence.
--- 3. menu.global.shortcut_hint places the hint, so each locale spells its
---    brackets (full-width ones in Chinese and Japanese).
--- 4. Applied to the finished root by the tray build (timed_build.lua): the
---    rows are found by their declared caption (menu.engine.tray_shortcut_hints).
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local TrayHints = require("menu.engine.tray_shortcut_hints")

local LOG = "menu.ui.builder.shortcut_hint"

-- The locale template joining a row's label ({1}) to its chord ({2}).
M.KEY = "menu.global.shortcut_hint"

-- A lookup that answers with the key itself has no catalogue behind it (the
-- lookup already reported the raw key): the row keeps its hint, as
-- core.i18n.engine.label_value does. All 21 locales hold the key.
local NO_CATALOGUE_TEMPLATE = "{1} ({2})"

--- Fills the locale's template; both texts are literal data.
--- @param t function The i18n lookup, key to text.
--- @param label string The row's label.
--- @param hint string The chord's name.
--- @return string
function M.compose(t, label, hint)
	local template = t(M.KEY)
	if template == M.KEY then template = NO_CATALOGUE_TEMPLATE end
	if type(template) ~= "string" or not template:find("{1}", 1, true) or not template:find("{2}", 1, true) then
		error("locale key " .. M.KEY .. " does not hold {1} and {2}: " .. tostring(template), 2)
	end
	return (template:gsub("{([12])}", function(slot)
		return slot == "1" and label or hint
	end))
end

--- The chord shown beside a row whose click runs `action`, nil for none.
--- @param action string Action id.
--- @param t function The i18n lookup, key to text.
--- @return string|nil hint
local function hint_for(action, t)
	local ok, slot = pcall(function() return require("modules.shortcuts.script_chords").hint_slot(action) end)
	if not ok then
		Logger.error(LOG, "The script chords could not be read — the '%s' row shows no shortcut: %s.",
			tostring(action), tostring(slot))
		return nil
	end
	if slot == nil then return nil end
	return t("sg_labels." .. slot)
end

--- Appends to the finished root rows of Suspend, Reload and Quit the chord
--- that runs their action.
--- @param rows table The finished tray root, changed in place.
--- @param t function The i18n lookup, key to text.
--- @return table rows The same rows.
function M.decorate(rows, t)
	if type(rows) ~= "table" then return rows end
	local captions = TrayHints.captions(require("menu.engine.manifest_menu").get_array("top_level"), "linux", t)
	TrayHints.decorate(rows, captions, function(action) return hint_for(action, t) end,
		function(row, hint) return M.compose(t, row.title, hint) end)
	return rows
end

return M
