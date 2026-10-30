--- ui/menu/menu_agent.lua

--- ==============================================================================
--- MODULE: Linux Menu Agent Submenu
--- DESCRIPTION:
--- Builds the tray's AI agent submenu through ui/menu/agent_rows.lua and the
--- shared AI parent, with the dialogs the agent rows open.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local TextPrompt = require("ui.text_prompt")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local show_error = require("ui.menu.menu_dialogs").show_error
local zenity_plain = require("ui.menu.menu_dialogs").zenity_plain

local LOG = "ui.menu.menu_agent"

--- Builds the AI agent submenu (ui/menu/agent_rows.lua).
--- @param ctx table Menu context.
--- @return table Row data { label, submenu }.
local function _build_agent(ctx)
	if not ManifestMenu then
		Logger.error(LOG, "Manifest renderer unavailable — the AI agent submenu cannot be built.")
		return nil
	end
	return require("ui.menu.agent_rows").build(ctx, {
		prompt = function(title, text, initial, hidden, choices)
			return TextPrompt.ask(title, zenity_plain(text), initial, hidden, choices)
		end,
		error = function(text) show_error(zenity_plain(text)) end,
	})
end

M.build = _build_agent

return M
