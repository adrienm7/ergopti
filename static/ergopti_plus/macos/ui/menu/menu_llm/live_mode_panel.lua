--- ui/menu/menu_llm/live_mode_panel.lua

--- ==============================================================================
--- MODULE: LLM Live Mode Panel
--- DESCRIPTION:
--- Builds the "⚡ Live mode" submenu of the AI menu: "Off", then every prompt
--- live mode can run, the current one checked. Choosing a prompt turns live mode
--- on with it and the menu's prediction count; choosing "Off" turns it off.
---
--- FEATURES & RATIONALE:
--- 1. One owner: the state is the prediction engine's, reached through the
---    keymap bridge, the same state the llm_live_prompt_toggle action flips.
--- 2. Rewrite prompts only: live mode redraws the current sentence at every
---    keystroke, which only a prompt answering "REWRITE:" can do. The built-ins
---    come first in menu order, then the user's prompts, labelled like the
---    prompt list.
--- ==============================================================================

local M = {}

local Logger       = require("infra.logger")
local i18n         = require("infra.i18n")
local ManifestMenu = require("infra.manifest_menu")
local Rewrite      = require("llm.rewrite")
local ProfileLabel = require("ui.menu.menu_llm.profile_label")

local LOG = "menu_llm.live_mode"
local ROW_ID = "llm_live_mode"




-- =====================================
-- =====================================
-- ======= 1/ Public API ===============
-- =====================================
-- =====================================

--- Lists the prompts live mode offers: the rewrite-format built-ins in menu
--- order, then the user's rewrite-format prompts.
--- @param llm_mod table The LLM core (BUILTIN_PROFILES, get_user_profiles).
--- @param count number The AI menu's prediction count, for the labels.
--- @return table Array of { id = string, label = string }.
function M.live_prompts(llm_mod, count)
	local prompts = {}
	for _, profile in ipairs(llm_mod.BUILTIN_PROFILES) do
		if Rewrite.is_rewrite_profile(profile) then
			prompts[#prompts + 1] = { id = profile.id, label = ProfileLabel.format(profile.label, count) }
		end
	end
	for index, profile in ipairs(llm_mod.get_user_profiles()) do
		if type(profile) == "table" and type(profile.id) == "string" and Rewrite.is_rewrite_profile(profile) then
			-- The custom-profile fallback name mirrors the prompt list's own row
			local label = profile.label or (i18n.get("menu.profiles.custom_profile_label") .. " " .. index)
			prompts[#prompts + 1] = { id = profile.id, label = ProfileLabel.format(label, count) }
		end
	end
	return prompts
end

--- Builds the submenu's rendered rows.
--- @param ctx table { llm_mod, keymap, count, is_disabled, update_menu }.
--- @return table Rendered menu items; only a greyed "Off" row, with an error
---   logged, when the bridge or the core lacks what the submenu needs.
function M.build(ctx)
	local keymap, llm_mod = ctx.keymap, ctx.llm_mod
	if type(keymap) ~= "table" or type(keymap.get_live_prompt) ~= "function"
		or type(keymap.set_live_prompt) ~= "function"
		or type(llm_mod) ~= "table" or type(llm_mod.BUILTIN_PROFILES) ~= "table"
		or type(llm_mod.get_user_profiles) ~= "function" then
		-- The rest of the AI menu stays usable: this submenu alone is greyed
		Logger.error(LOG, "The keymap bridge or the LLM core lacks the live-mode API — submenu greyed.")
		return ManifestMenu.render_rows({
			ManifestMenu.check_row("llm_live_controls", "llm_live_mode_off",
				{ llm_live_mode_off = function() return false end },
				{ llm_live_is_off = function() return true end, llm_live_off_ready = function() return false end }),
		}, ROW_ID)
	end
	local live = keymap.get_live_prompt()
	local current = live and live.profile_id or nil
	local is_disabled = ctx.is_disabled == true

	--- Applies one choice and redraws the menu around the resulting state.
	--- @param value string|nil The prompt id, or nil for off.
	--- @return boolean committed
	local function choose(value)
		local committed = keymap.set_live_prompt(value) == true
		if not committed then
			Logger.info(LOG, "Live mode choice '%s' not applied.", tostring(value or "off"))
		end
		if type(ctx.update_menu) == "function" then ctx.update_menu() end
		return committed
	end

	local rows = {
		ManifestMenu.check_row("llm_live_controls", "llm_live_mode_off",
			{ llm_live_mode_off = function() return choose(nil) end },
			{ llm_live_is_off = function() return keymap.get_live_prompt() == nil end,
				llm_live_off_ready = function() return ctx.is_disabled ~= true end }),
	}
	local boundary_rows = ManifestMenu.template_rows("llm_live_off_boundary", {}, {}, {})
	if not boundary_rows then return {} end
	for _, row in ipairs(boundary_rows) do rows[#rows + 1] = row end
	for _, prompt in ipairs(M.live_prompts(llm_mod, ctx.count)) do
		local id = prompt.id
		rows[#rows + 1] = {
			label    = prompt.label,
			checked  = current == id,
			disabled = is_disabled or nil,
			action   = not is_disabled and function() return choose(id) end or nil,
		}
	end
	return ManifestMenu.render_rows(rows, ROW_ID)
end

return M
