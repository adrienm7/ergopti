--- _shared/shortcuts/engine/keep_awake_menu.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Menu Rows — Shared Lua Implementation
--- DESCRIPTION:
--- The runtime parts of the « Anti-veille » submenu
--- (_shared/menu/data/menu.toml, keep_awake_menu): the presets list as one
--- single-choice group and the status list (the click counter and the
--- reason anything cannot run). The macOS and Linux drivers hand them to the
--- shared renderer; the Windows driver builds the same in its twin.
---
--- FEATURES & RATIONALE:
--- 1. The presets are radio rows: one is always ticked, the active one, and a
---    click makes another active for the next Ctrl+M.
--- 2. The switches are `check` rows of the manifest, whose commands and
---    getters each driver's builder names; a switch that cannot run here is
---    greyed by its disabled_when, and its exact reason is a red status row.
--- 3. A capture or OCR problem is a red row of its own, so the user sees why
---    the auto-clicker does nothing even before opening a preset.
--- ==============================================================================

local M = {}

-- The prefix of a problem row, the red dot every component status row uses.
M.PROBLEM_DOT = "🔴"

--- The display name of a preset.
--- @param preset table
--- @param text function i18n getter.
--- @return string
function M.preset_name(preset, text)
	return preset.name or text(preset.name_key)
end

--- The rows of the presets list.
--- @param doc table The presets document.
--- @param ports table { text = i18n getter, select = function(id) }
--- @return table rows
function M.preset_rows(doc, ports)
	local rows = {}
	for _, preset in ipairs(doc.presets) do
		local id = preset.id
		rows[#rows + 1] = {
			label = M.preset_name(preset, ports.text),
			checked = id == doc.active,
			radio = true,
			action = function() ports.select(id) end,
		}
	end
	return rows
end

--- The rows of the status list: the click counter and every reason something
--- cannot run, each a red row.
--- @param ports table {
---   text = i18n getter,
---   auto_click_reason = string|nil why auto-click cannot run here,
---   problems = { reason… } capture or OCR problems to show,
---   clicks = integer clicks so far }
--- @return table rows
function M.status_rows(ports)
	local rows = {
		{ label = (ports.text("menu.keep_awake.click_count"):gsub("{1}", tostring(ports.clicks))), disabled = true },
	}
	local reasons = {}
	if ports.auto_click_reason then reasons[1] = ports.auto_click_reason end
	for _, reason in ipairs(ports.problems or {}) do reasons[#reasons + 1] = reason end
	for _, reason in ipairs(reasons) do
		rows[#rows + 1] = { label = M.PROBLEM_DOT .. " " .. ports.text("keepawake.reason." .. reason), disabled = true }
	end
	return rows
end

return M
