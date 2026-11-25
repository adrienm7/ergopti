--- menu/ui/builder/component_status_rows.lua

--- ==============================================================================
--- MODULE: Component Status Rows (Linux)
--- DESCRIPTION:
--- The tray's first rows: one red row per problem a Linux part reported
--- (core/ui/engine/component_status.lua) that still holds, then a separator;
--- none when nothing is wrong. Each row is menu.toml's
--- linux_component_problems command for that problem's code, drawn by the
--- shared renderer with the llm entry's unreachable health dot, and its click
--- shows the problem's title and explanation in the tray's status window.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "menu.ui.builder.component_status_rows"

--- The declared command of each problem code.
--- @return table code -> command id
local function commands_by_code()
	local COMMAND = require("settings.engine.keys").COMMAND
	return {
		windows_lgi = COMMAND.COMPONENT_PROBLEM_WINDOWS_LGI,
		windows_webkit = COMMAND.COMPONENT_PROBLEM_WINDOWS_WEBKIT,
		layout_unresolved = COMMAND.COMPONENT_PROBLEM_LAYOUT_UNRESOLVED,
		kwin_focus_script = COMMAND.COMPONENT_PROBLEM_KWIN_FOCUS_SCRIPT,
		ergopti_layout_install_failed = COMMAND.COMPONENT_PROBLEM_ERGOPTI_LAYOUT_INSTALL_FAILED,
		ergopti_layout_activate_failed = COMMAND.COMPONENT_PROBLEM_ERGOPTI_LAYOUT_ACTIVATE_FAILED,
		ergopti_layout_uninstall_failed = COMMAND.COMPONENT_PROBLEM_ERGOPTI_LAYOUT_UNINSTALL_FAILED,
	}
end

--- The shared « unreachable » health dot of the llm top-level entry, the glyph
--- the AI title shows (ai/ui/menu/parent.lua).
--- @param ManifestMenu table
--- @return string|nil
local function unreachable_dot(ManifestMenu)
	for _, row in ipairs(ManifestMenu.get_array("top_level") or {}) do
		if type(row) == "table" and row.id == "llm" and type(row.health_dot) == "table" then
			local glyph = row.health_dot.unreachable
			if type(glyph) == "string" and glyph ~= "" then return glyph end
		end
	end
	return nil
end

--- The rows of the problems that hold, then a separator; none otherwise.
--- @param deps table|nil { status, show }: the problem list and the status window
---   opener, a test's or the daemon's.
--- @return table rows Row data for the shared renderer.
function M.build(deps)
	deps = type(deps) == "table" and deps or {}
	local status = deps.status or require("core.ui.engine.component_status")
	local show = deps.show or function(title, body)
		return require("tray.adapters.menu").showStatusWindow(title, body)
	end
	local problems = status.current()
	if #problems == 0 then return {} end
	local ManifestMenu = require("menu.engine.manifest_menu")
	local dot = unreachable_dot(ManifestMenu)
	if dot == nil then Logger.error(LOG, "The menu declares no unreachable health dot; the problem rows show none.") end
	local known = commands_by_code()
	local rows = {}
	for _, problem in ipairs(problems) do
		local command = known[problem.code]
		local row = command and ManifestMenu.command_row("linux_component_problems", command, {
			[command] = function()
				if not show(problem.title, problem.body) then
					Logger.error(LOG, "Status window for '%s' could not open; the explanation is in the log.", problem.code)
				end
			end,
		}, { ["linux_component_health_dot"] = function() return dot or "" end }) or nil
		if row then
			rows[#rows + 1] = row
		else
			-- A problem with no declared row would be one the user never sees.
			Logger.error(LOG, "Problem %s has no linux_component_problems row; only its notice and log line remain.",
				problem.code)
		end
	end
	if #rows > 0 then
		for _, boundary in ipairs(ManifestMenu.template_rows("linux_component_problems_end", {}, {}, {}) or {}) do
			rows[#rows + 1] = boundary
		end
	end
	return rows
end

return M
