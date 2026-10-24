--- ui/menu/pause_layout_rows.lua

--- ==============================================================================
--- MODULE: Pause Layout Rows (Linux)
--- DESCRIPTION:
--- Builds Layout > « Layout on pause / resume » from the shared manifest frames
--- (layout_switching_frame, layout_switch_picker_frame) macOS draws too: the
--- switch, then one picker per event listing the desktop's own layouts after
--- « No change ». The choices come from the input source adapter's last
--- reading; each build asks for a fresh one and the tray is rebuilt only when
--- the desktop's list changed. A desktop with no supported backend gets the
--- declared status line instead.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ManifestMenu = require("infra.manifest_menu")
local Policy = require("layout.pause_switch_policy")

local LOG = "ui.menu.pause_layout_rows"

--- Builds the three switching rows.
--- @param ctx table { paused, t, on_changed, show_error, preferences, switch }:
---   preferences reads and writes the settings (infra.pause_layout_preferences),
---   switch is the initialised modules.keymap.pause_layout_switch.
--- @return table rows
function M.rows(ctx)
	local preferences, switch = ctx.preferences, ctx.switch
	local switcher = switch.switcher()
	-- No backend can change this desktop's layout: say why rather than draw a
	-- switch and pickers that could never act.
	if switcher.backend() == nil then
		return ManifestMenu.status_rows("layout_menu", "layout_switching", "unsupported_desktop") or {}
	end
	local called, settings = pcall(preferences.settings)
	if not called then
		Logger.error(LOG, "The pause layout settings are unreadable: %s.", tostring(settings))
		return {}
	end
	local choices = switcher.choices()
	switcher.refresh(function(changed)
		if changed then ctx.on_changed() end
	end)

	local function label_for(value)
		local id = Policy.target_id(value)
		if id == nil then return ctx.t("menu.layout.layout_auto") end
		for _, choice in ipairs(choices) do
			if choice.id == id then return choice.label end
		end
		return id
	end

	local function persist(role, value)
		if not preferences.set(role, value) then
			ctx.show_error(ctx.t("dialog.bulk_toggle.save_failed"), ctx.t("common.error_title"))
			return
		end
		ctx.on_changed()
	end

	local enabled = settings.enabled == true
	local function picker(role)
		local current = Policy.target_id(settings[role])
		local native = {}
		for _, choice in ipairs(choices) do
			local id = choice.id
			native[#native + 1] = {
				label = choice.label,
				checked = current == id,
				action = function() persist(role, id) end,
			}
		end
		return ManifestMenu.template_rows("layout_switch_picker_frame", {
			["layout_picker_auto"] = function() persist(role, "") end,
		}, {
			["layout_picker_auto_checked"] = function() return current == nil end,
			["layout_picker_has_choices"] = function() return #native > 0 end,
		}, { ["layout_picker_choices"] = function() return native end }) or {}
	end

	return ManifestMenu.template_rows("layout_switching_frame", {
		["layout_switch_toggle"] = function() persist("enabled", not enabled) end,
	}, {
		["layout_switch_checked"] = function() return enabled end,
		["layout_switch_ready"] = function() return enabled and not ctx.paused end,
		["layout_pause_caption"] = function() return label_for(settings.on_pause) end,
		["layout_resume_caption"] = function() return label_for(settings.on_resume) end,
	}, {
		["layout_pause_picker"] = function() return picker("on_pause") end,
		["layout_resume_picker"] = function() return picker("on_resume") end,
	}) or {}
end

return M
