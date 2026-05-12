--- ui/hotstrings_config_window/init.lua

--- ==============================================================================
--- MODULE: Hotstrings Config Window
--- DESCRIPTION:
--- Webview-based editor for the per-group expansion delay (in milliseconds)
--- and tooltip color of every hotstring category and section. Wraps the
--- `modules.hotstrings_config` module — every save call goes through that
--- module so the persisted file format stays consistent with the AHK driver
--- and any subsequent reload sees the same overrides.
---
--- FEATURES & RATIONALE:
--- 1. Singleton webview — opening the menu entry twice brings the existing
---    window to the front instead of stacking duplicates.
--- 2. Round-trip via the bridge — after every set / clear the Lua side
---    rebuilds the canonical state and pushes it to the page; the UI never
---    keeps a divergent local copy of the truth.
--- 3. Color presets reuse the bootstrap defaults shipped in the category
---    TOMLs so the user can recover the original look in one click.
--- ==============================================================================

local M = {}

local hs               = hs
local ui_builder       = require("ui.ui_builder")
local Logger           = require("lib.logger")
local hotstrings_config = require("modules.hotstrings_config")
local i18n             = require("lib.i18n")

local LOG = "hotstrings_config_window"


-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local _webview     = nil
local _usercontent = nil

local WINDOW_WIDTH  = 720
local WINDOW_HEIGHT = 640

local _src       = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = _src:match("^(.*[/\\])") or "./"

-- Display order for the categories — matches the menu and the AHK driver,
-- with `personal` last because it depends on a user-relocatable file.
local CATEGORY_ORDER = {
	"magickey", "autocorrection", "rolls",
	"sfbsreduction", "distancesreduction", "personal",
}

-- Friendly labels for each category. Falls back to the TOML's [_meta]
-- description when this table has no entry for a given key.
local CATEGORY_LABELS = {
	magickey           = i18n.get("hs_config.cat_magickey"),
	autocorrection     = i18n.get("hs_config.cat_autocorrection"),
	rolls              = i18n.get("hs_config.cat_rolls"),
	sfbsreduction      = i18n.get("hs_config.cat_sfbs"),
	distancesreduction = i18n.get("hs_config.cat_distances"),
	personal           = i18n.get("hs_config.cat_personal"),
}

-- Color palette offered in the "couleur" dropdown. The first six values
-- mirror the bootstrap defaults shipped in the category TOMLs so a user
-- who wandered too far can recover the original look in one click.
local COLOR_PRESETS = {
	{ label = i18n.get("hs_config.color_red"),    hex = "#e53935" },
	{ label = i18n.get("hs_config.color_green"),  hex = "#43a047" },
	{ label = i18n.get("hs_config.color_orange"), hex = "#fb8c00" },
	{ label = i18n.get("hs_config.color_blue"),   hex = "#1e88e5" },
	{ label = i18n.get("hs_config.color_purple"), hex = "#8e44ad" },
	{ label = i18n.get("hs_config.color_cyan"),   hex = "#00838f" },
	{ label = i18n.get("hs_config.color_yellow"), hex = "#fdd835" },
	{ label = i18n.get("hs_config.color_gray"),   hex = "#6e6e73" },
}


-- =========================================
-- =========================================
-- ======= 2/ State Builder ================
-- =========================================
-- =========================================

--- Pull the current configuration from `hotstrings_config` and shape it for
--- the UI. The returned table is JSON-encoded and pushed to the webview on
--- first render and after every mutation.
--- @return table The serialisable configuration tree.
local function build_state()
	local out = { categories = {}, presets = COLOR_PRESETS }

	for _, cat in ipairs(CATEGORY_ORDER) do
		local effective    = hotstrings_config.resolve(cat, nil)
		local default_meta = hotstrings_config.get_toml_defaults(cat, nil)
		local override     = hotstrings_config.get_user_override(cat, nil) or {}

		local cat_entry = {
			name              = cat,
			title             = CATEGORY_LABELS[cat] or cat,
			delay_ms          = math.floor((effective.delay or 0) * 1000 + 0.5),
			delay_default_ms  = math.floor((default_meta.delay or 0) * 1000 + 0.5),
			delay_overridden  = override.delay ~= nil,
			color             = effective.color,
			color_default     = default_meta.color,
			color_overridden  = override.color ~= nil,
			sections          = {},
		}

		for _, sec in ipairs(hotstrings_config.get_sections(cat)) do
			local sec_eff      = hotstrings_config.resolve(cat, sec.name)
			local sec_default  = hotstrings_config.get_toml_defaults(cat, sec.name)
			local sec_override = hotstrings_config.get_user_override(cat, sec.name) or {}
			table.insert(cat_entry.sections, {
				name              = sec.name,
				title             = sec.description,
				delay_ms          = math.floor((sec_eff.delay or 0) * 1000 + 0.5),
				delay_default_ms  = math.floor((sec_default.delay or 0) * 1000 + 0.5),
				delay_overridden  = sec_override.delay ~= nil,
				color             = sec_eff.color,
				color_default     = sec_default.color,
				color_overridden  = sec_override.color ~= nil,
			})
		end

		table.insert(out.categories, cat_entry)
	end

	return out
end


-- =================================
-- =================================
-- ======= 3/ Bridge Handlers ======
-- =================================
-- =================================

local function push_state()
	if not _webview then return end
	local ok, json = pcall(hs.json.encode, build_state())
	if not ok or not json then return end
	pcall(function() _webview:evaluateJavaScript("setData(" .. json .. ")") end)
end

local function on_message(msg)
	if type(msg) ~= "table" then return end
	local body = msg.body
	if type(body) ~= "table" or type(body.action) ~= "string" then return end

	-- All mutations go through the resolver module so the TOML override file
	-- on disk is written immediately. After every change we re-pull state
	-- and push the canonical version back to the UI to avoid drift.
	local action  = body.action
	local cat     = body.category
	local sec     = (type(body.section) == "string" and body.section ~= "") and body.section or nil

	if action == "set_delay" and type(body.ms) == "number" then
		hotstrings_config.set_override(cat, sec, "delay", body.ms / 1000)
	elseif action == "clear_delay" then
		hotstrings_config.clear_override(cat, sec, "delay")
	elseif action == "set_color" and type(body.hex) == "string" and body.hex ~= "" then
		hotstrings_config.set_override(cat, sec, "color", body.hex)
	elseif action == "clear_color" then
		hotstrings_config.clear_override(cat, sec, "color")
	elseif action == "reset_all" then
		for _, c in ipairs(CATEGORY_ORDER) do
			hotstrings_config.clear_override(c, nil, nil)
			for _, s in ipairs(hotstrings_config.get_sections(c)) do
				hotstrings_config.clear_override(c, s.name, nil)
			end
		end
	elseif action == "set_all_grey" then
		-- Set every category's file-level colour to grey and wipe any
		-- per-section colour override so the grey cascades down. Delays
		-- are left untouched.
		local grey = "#6e6e73"
		for _, c in ipairs(CATEGORY_ORDER) do
			hotstrings_config.set_override(c, nil, "color", grey)
			for _, s in ipairs(hotstrings_config.get_sections(c)) do
				hotstrings_config.clear_override(c, s.name, "color")
			end
		end
	elseif action == "close" then
		M.close()
		return
	else
		return
	end

	push_state()
end


-- ============================
-- ============================
-- ======= 4/ Public API ======
-- ============================
-- ============================

--- Open (or focus) the configuration window.
function M.open()
	if _webview then
		ui_builder.force_focus(_webview)
		return
	end

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "hotstrings_config_bridge")
	if not ok_uc or not uc then
		Logger.error(LOG, "Error creating usercontent bridge.")
		return
	end
	_usercontent = uc
	_usercontent:setCallback(on_message)

	_webview = ui_builder.show_webview({
		frame        = ui_builder.get_centered_frame(WINDOW_WIDTH, WINDOW_HEIGHT),
		title        = i18n.get("hs_config.window_title"),
		style_masks  = { "titled", "closable", "resizable", "utility" },
		usercontent  = _usercontent,
		assets_dir   = ASSETS_DIR,
		on_navigation = function(action)
			if action == "didFinishNavigation" then
				push_state()
			end
			return true
		end,
		on_close = function()
			_webview     = nil
			_usercontent = nil
		end,
	})
	Logger.info(LOG, "Hotstrings config window opened.")
end

--- Close and destroy the window.
function M.close()
	if _webview and type(_webview.delete) == "function" then
		pcall(function() _webview:delete() end)
	end
	_webview     = nil
	_usercontent = nil
end

return M
