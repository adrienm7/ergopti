--- _shared/menu/engine/tray_shortcut_hints.lua

--- ==============================================================================
--- MODULE: Tray Shortcut Hints (shared rows)
--- DESCRIPTION:
--- Which tray rows show the shortcut bound to their action (maintainer,
--- 2026-11-24): « Suspendre », « Recharger » and « Quitter », and how the macOS
--- and Linux drivers find them in their finished root. The chord itself is
--- chosen by keyboard.engine.layers.script_chords (hint_slot); each driver
--- draws it its own way (macOS in grey, Linux in the label text). Windows
--- passes the same three action ids where it stages the rows (menu_init.ahk).
---
--- FEATURES & RATIONALE:
--- 1. Applied to the finished root: the top-level row builders and the root
---    renderer stay as they are, and a row is found by the caption its
---    declaration gives it, which is unique in the root.
--- 2. Pure: the caller hands over the declaration, the lookup and the drawing.
--- ==============================================================================

local M = {}

-- Top-level row id (_shared/menu/data/menu.toml) -> the action id its click
-- runs (_shared/shortcuts/data/actions/actions.toml).
M.ACTIONS = {
	suspend = "script_pause_toggle",
	reload  = "script_reload",
	quit    = "script_quit",
}

--- The caption of each hinted row a platform's root draws, mapped to its action.
--- @param top_level table The manifest's top_level array.
--- @param platform string "hs" or "linux".
--- @param t function The i18n lookup, key to text.
--- @return table captions Caption -> action id.
function M.captions(top_level, platform, t)
	assert(type(top_level) == "table", "tray shortcut hints: the top-level declaration is required")
	local captions = {}
	for _, item in ipairs(top_level) do
		local action = type(item) == "table" and M.ACTIONS[item.id] or nil
		local drawn = action ~= nil and type(item.i18n) == "string"
		if drawn and type(item.platforms) == "table" then
			drawn = false
			for _, name in ipairs(item.platforms) do
				if name == platform then drawn = true end
			end
		end
		if drawn then captions[t(item.i18n)] = action end
	end
	return captions
end

--- Redraws the title of each finished root row whose caption is a hinted one.
--- @param rows table The finished root, changed in place.
--- @param captions table From M.captions.
--- @param hint_for function Action id -> hint text, nil for none.
--- @param draw function (row, hint) -> the row's new title.
--- @return number count The rows redrawn.
function M.decorate(rows, captions, hint_for, draw)
	local count = 0
	for _, row in ipairs(rows) do
		local action = type(row) == "table" and type(row.title) == "string" and captions[row.title] or nil
		local hint = action ~= nil and hint_for(action) or nil
		if hint ~= nil then
			row.title = draw(row, hint)
			count = count + 1
		end
	end
	return count
end

return M
