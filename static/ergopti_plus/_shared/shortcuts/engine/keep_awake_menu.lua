--- _shared/shortcuts/engine/keep_awake_menu.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Menu Rows — Shared Lua Implementation
--- DESCRIPTION:
--- The row DATA of the « Anti-veille » submenu's two lists
--- (_shared/menu/data/menu.toml, keep_awake_menu): the presets as one
--- single-choice group, and the active preset's switches with the click
--- counter and the reason anything cannot run. The macOS and Linux drivers
--- hand these rows to the shared renderer; the Windows driver builds the same
--- rows in its twin.
---
--- FEATURES & RATIONALE:
--- 1. The presets are radio rows: one is always ticked, the active one, and a
---    click makes another active for the next Ctrl+M.
--- 2. A switch that cannot run here is greyed with its translated reason
---    (keepawake.reason.<reason>), never hidden and never silently inert.
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

--- The rows of the options list.
--- @param preset table The active preset.
--- @param ports table {
---   text = i18n getter, switch = function(name, value),
---   auto_click_reason = string|nil why auto-click cannot run here,
---   problems = { reason… } capture or OCR problems to show,
---   clicks = integer clicks so far }
--- @return table rows
function M.option_rows(preset, ports)
	local rows = {
		{ label = ports.text("menu.keep_awake.keep_awake"), checked = preset.keep_awake,
			action = function() ports.switch("keep_awake", not preset.keep_awake) end },
	}
	local auto = { label = ports.text("menu.keep_awake.auto_click"), checked = preset.auto_click,
		action = function() ports.switch("auto_click", not preset.auto_click) end }
	if ports.auto_click_reason then
		auto.disabled = true
		auto.disabled_reason_key = "keepawake.reason." .. ports.auto_click_reason
		auto.action = nil
	end
	rows[#rows + 1] = auto
	rows[#rows + 1] = { label = (ports.text("menu.keep_awake.click_count"):gsub("{1}", tostring(ports.clicks))),
		disabled = true }
	for _, reason in ipairs(ports.problems or {}) do
		rows[#rows + 1] = { label = M.PROBLEM_DOT .. " " .. ports.text("keepawake.reason." .. reason), disabled = true }
	end
	return rows
end

return M
