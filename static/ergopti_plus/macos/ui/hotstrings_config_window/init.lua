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
--- 4. Group selector — three groups are exposed to the UI: Commun (built-in
---    categories), Personnel (personal TOML files), and one entry per
---    installed extension that ships hotstrings. Personal and extension files
---    are discovered at open-time from the paths configured via M.setup().
--- ==============================================================================

local M = {}

local hs                = hs
local ui_builder        = require("ui.ui_builder")
local Logger            = require("lib.logger")
local hotstrings_config = require("modules.hotstrings_config")
local TomlReader        = require("lib.toml_reader")
local i18n              = require("lib.i18n")

local LOG = "hotstrings_config_window"


-- ====================================
--- ====================================
-- ======= 1/ Constants & State =======
--- ====================================
-- ====================================

local _webview     = nil
local _usercontent = nil

-- Module-level config set by M.setup() before the first M.open() call.
local _config = {
	personal_dir   = nil,
	extensions_dir = nil,
}

local WINDOW_WIDTH  = 720
local WINDOW_HEIGHT = 640

-- The global delay fallback (seconds) that applies when no TOML default is set.
-- Mirrored from hotstrings_config GLOBAL_DEFAULT_DELAY — both must stay in sync.
local GLOBAL_DEFAULT_DELAY_MS = 750

local _src       = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = _src:match("^(.*[/\\])") or "./"

-- Display order for the built-in categories — matches the menu and the AHK driver.
local CATEGORY_ORDER = {
	"magickey", "autocorrection", "rolls",
	"sfbsreduction", "distancesreduction", "personal",
}

-- Friendly labels for each built-in category. Falls back to the TOML's [_meta]
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
--- =========================================
-- ======= 2/ File Discovery Helpers =======
--- =========================================
-- =========================================

--- Lists TOML files in a directory, skipping names that start with `_`.
--- Returns an array of absolute paths. Uses hs.fs.dir for directory scanning.
--- @param dir string Absolute path to the directory.
--- @return table Array of absolute TOML paths.
local function list_toml_files(dir)
	if type(dir) ~= "string" or dir == "" then return {} end
	local out = {}
	local ok, iter = pcall(function() return hs.fs.dir(dir) end)
	if not ok or not iter then return {} end
	for name in iter do
		if name:sub(1, 1) ~= "_" and name:match("%.toml$") then
			table.insert(out, dir .. "/" .. name)
		end
	end
	table.sort(out)
	return out
end

--- Parses the [_meta] block of an arbitrary TOML file and returns its effective
--- delay, color, and sections. This is used for personal files where the [_meta]
--- IS the canonical value (no user-override layer sits on top).
--- @param toml_path string Absolute path to the TOML file.
--- @return table { delay = number|nil, color = string|nil, sections = table }
local function read_file_meta(toml_path)
	local ok, parsed = pcall(function() return TomlReader.parse(toml_path) end)
	if not ok or not parsed then
		return { sections = {} }
	end
	return {
		delay        = parsed.meta and parsed.meta.delay,
		color        = parsed.meta and parsed.meta.color,
		show_tooltip = parsed.meta and parsed.meta.show_tooltip,
		sections     = (parsed.meta and parsed.meta.sections) or {},
	}
end

--- Reads the sections list from an arbitrary TOML file (personal or extension).
--- Returns an array of { name, description } descriptors, skipping separators.
--- @param toml_path string Absolute path to the TOML file.
--- @return table Array of { name = string, description = string }.
local function read_file_sections(toml_path)
	local ok, parsed = pcall(function() return TomlReader.parse(toml_path) end)
	if not ok or not parsed then return {} end
	local out = {}
	for _, name in ipairs(parsed.sections_order or {}) do
		if name ~= "-" then
			local sec  = parsed.sections and parsed.sections[name]
			local desc = (sec and sec.description) or name
			table.insert(out, { name = name, description = desc })
		end
	end
	return out
end

--- Derives a short display title from an absolute TOML path (stem without ext).
--- @param toml_path string
--- @return string
local function stem(toml_path)
	local name = toml_path:match("[/\\]([^/\\]+)%.toml$") or toml_path
	return name
end

--- Discovers installed extensions that expose hotstrings.
--- Returns an array of { ext_id, label, files = { { toml_path, stem } } }.
--- Each extension lives in a subdirectory of extensions_dir and must have a
--- manifest.toml (for the label) and a hotstrings/ subdirectory with *.toml.
--- @param extensions_dir string
--- @return table
local function discover_extensions(extensions_dir)
	if type(extensions_dir) ~= "string" or extensions_dir == "" then return {} end
	local out = {}
	local ok, iter = pcall(function() return hs.fs.dir(extensions_dir) end)
	if not ok or not iter then return {} end
	local ext_dirs = {}
	for name in iter do
		if name:sub(1, 1) ~= "." then
			local attr_ok, attrs = pcall(function()
				return hs.fs.attributes(extensions_dir .. "/" .. name)
			end)
			if attr_ok and attrs and attrs.mode == "directory" then
				table.insert(ext_dirs, name)
			end
		end
	end
	table.sort(ext_dirs)

	for _, ext_name in ipairs(ext_dirs) do
		local ext_root   = extensions_dir .. "/" .. ext_name
		local manifest   = ext_root .. "/manifest.toml"
		local hs_dir     = ext_root .. "/hotstrings"

		-- Read the extension label from manifest.toml via a line scan;
		-- the manifest uses [extension] not [_meta], so TomlReader.meta won't help.
		local label = ext_name
		local fh = io.open(manifest, "r")
		if fh then
			for line in fh:lines() do
				local v = line:match('^name%s*=%s*"(.-)"')
				if v then label = v; break end
			end
			pcall(function() fh:close() end)
		end

		local toml_files = list_toml_files(hs_dir)
		if #toml_files > 0 then
			local files = {}
			for _, p in ipairs(toml_files) do
				table.insert(files, { toml_path = p, title = stem(p) })
			end
			table.insert(out, { ext_id = ext_name, label = label, files = files })
		end
	end
	return out
end


-- =========================================
-- =========================================
-- ======= 3/ State Builder ================
-- =========================================
-- =========================================

--- Builds one category entry table for the UI state.
--- @param name string Unique category name (used as mutation key).
--- @param title string Display title.
--- @param group string Group key ("common", "personal", or "ext:<id>").
--- @param effective table { delay, color } from resolve/resolve_ext.
--- @param default_meta table { delay, color } TOML defaults (nil ok).
--- @param override table|nil User override map (nil ok).
--- @param sections table Array of { name, description }.
--- @param sec_resolver function(sec_name) -> { effective, default_meta, override }
--- @return table The category entry.
local function build_cat_entry(name, title, group, effective, default_meta, override, sections, sec_resolver)
	override = override or {}
	default_meta = default_meta or {}

	-- show_tooltip resolves to true when not explicitly set (safe default)
	local eff_tooltip = effective.show_tooltip
	if eff_tooltip == nil then eff_tooltip = true end

	local cat_entry = {
		name                  = name,
		group                 = group,
		title                 = title,
		delay_ms              = math.floor((effective.delay or 0) * 1000 + 0.5),
		delay_default_ms      = math.floor((default_meta.delay or 0) * 1000 + 0.5),
		delay_overridden      = override.delay ~= nil,
		color                 = effective.color,
		color_default         = default_meta.color,
		color_overridden      = override.color ~= nil,
		show_tooltip          = eff_tooltip,
		show_tooltip_overridden = override.show_tooltip ~= nil,
		sections              = {},
	}

	for _, sec in ipairs(sections) do
		local sv = sec_resolver(sec.name)
		local s_eff  = sv.effective  or {}
		local s_def  = sv.default_meta or {}
		local s_ov   = sv.override or {}
		local s_tooltip = s_eff.show_tooltip
		if s_tooltip == nil then s_tooltip = eff_tooltip end  -- inherit file-level
		table.insert(cat_entry.sections, {
			name                    = sec.name,
			title                   = sec.description,
			delay_ms                = math.floor((s_eff.delay or 0) * 1000 + 0.5),
			delay_default_ms        = math.floor((s_def.delay or 0) * 1000 + 0.5),
			delay_overridden        = s_ov.delay ~= nil,
			color                   = s_eff.color,
			color_default           = s_def.color,
			color_overridden        = s_ov.color ~= nil,
			show_tooltip            = s_tooltip,
			show_tooltip_overridden = s_ov.show_tooltip ~= nil,
		})
	end

	return cat_entry
end

--- Pull the current configuration from `hotstrings_config` and shape it for
--- the UI. The returned table is JSON-encoded and pushed to the webview on
--- first render and after every mutation.
--- @return table The serialisable configuration tree.
local function build_state()
	local out = {
		categories            = {},
		groups                = {},
		presets               = COLOR_PRESETS,
		global_default_delay_ms = GLOBAL_DEFAULT_DELAY_MS,
	}

	-- Always present the common group
	table.insert(out.groups, {
		key   = "common",
		label = i18n.get("hs_config.group_common"),
	})


	-- 3.1) Common built-in categories
	for _, cat in ipairs(CATEGORY_ORDER) do
		local effective    = hotstrings_config.resolve(cat, nil)
		local default_meta = hotstrings_config.get_toml_defaults(cat, nil)
		local override     = hotstrings_config.get_user_override(cat, nil) or {}
		local sections     = hotstrings_config.get_sections(cat)

		local entry = build_cat_entry(
			cat,
			CATEGORY_LABELS[cat] or cat,
			"common",
			effective,
			default_meta,
			override,
			sections,
			function(sec_name)
				return {
					effective    = hotstrings_config.resolve(cat, sec_name),
					default_meta = hotstrings_config.get_toml_defaults(cat, sec_name),
					override     = hotstrings_config.get_user_override(cat, sec_name) or {},
				}
			end
		)
		table.insert(out.categories, entry)
	end


	-- 3.2) Personal TOML files
	local personal_files = list_toml_files(_config.personal_dir)
	if #personal_files > 0 then
		table.insert(out.groups, {
			key   = "personal",
			label = i18n.get("hs_config.group_personal"),
		})

		for _, toml_path in ipairs(personal_files) do
			local file_stem   = stem(toml_path)
			local file_meta   = read_file_meta(toml_path)
			local file_secs   = read_file_sections(toml_path)

			-- Personal files: the [_meta] IS the effective value — no override layer.
			-- We still present them uniformly so the UI can render them consistently.
			local effective = {
				delay        = file_meta.delay,
				color        = file_meta.color,
				show_tooltip = file_meta.show_tooltip,
			}

			local entry = build_cat_entry(
				"personal:" .. file_stem,
				file_stem,
				"personal",
				effective,
				file_meta,
				nil,   -- no user override table for personal files
				file_secs,
				function(sec_name)
					local sec_data = file_meta.sections[sec_name] or {}
					return {
						effective    = { delay = sec_data.delay, color = sec_data.color, show_tooltip = sec_data.show_tooltip },
						default_meta = { delay = sec_data.delay, color = sec_data.color, show_tooltip = sec_data.show_tooltip },
						override     = {},
					}
				end
			)
			-- Personal entries are never "overridden" — the file itself is the truth
			entry.delay_overridden = false
			entry.color_overridden = false
			entry.personal_path    = toml_path
			table.insert(out.categories, entry)
		end
	end


	-- 3.3) Extension TOML files
	local extensions = discover_extensions(_config.extensions_dir)
	for _, ext in ipairs(extensions) do
		local group_key = "ext:" .. ext.ext_id
		table.insert(out.groups, {
			key   = group_key,
			label = ext.label,
		})

		for _, file_info in ipairs(ext.files) do
			local toml_path = file_info.toml_path
			local file_stem = file_info.title
			local ext_id    = ext.ext_id
			local file_secs = read_file_sections(toml_path)

			local effective    = hotstrings_config.resolve_ext(ext_id, toml_path, nil)
			local default_meta = (function()
				local ok, parsed = pcall(function() return TomlReader.parse(toml_path) end)
				if ok and parsed then
					return {
						delay = parsed.meta and parsed.meta.delay,
						color = parsed.meta and parsed.meta.color,
					}
				end
				return {}
			end)()
			local override = hotstrings_config.get_user_override("ext." .. ext_id, nil) or {}

			local entry = build_cat_entry(
				"ext:" .. ext_id .. ":" .. file_stem,
				file_stem,
				group_key,
				effective,
				default_meta,
				override,
				file_secs,
				function(sec_name)
					return {
						effective    = hotstrings_config.resolve_ext(ext_id, toml_path, sec_name),
						default_meta = (function()
							local ok2, parsed2 = pcall(function() return TomlReader.parse(toml_path) end)
							if ok2 and parsed2 and parsed2.meta and parsed2.meta.sections then
								local s = parsed2.meta.sections[sec_name] or {}
								return { delay = s.delay, color = s.color, show_tooltip = s.show_tooltip }
							end
							return {}
						end)(),
						override = hotstrings_config.get_user_override("ext." .. ext_id, sec_name) or {},
					}
				end
			)
			entry.ext_id      = ext_id
			entry.ext_path    = toml_path
			table.insert(out.categories, entry)
		end
	end

	return out
end


-- =====================================================
-- =====================================================
-- ======= 4/ Personal-file TOML Patch Helpers ========
-- =====================================================
-- =====================================================

--- Patches a single field in the [_meta] or [_meta.sections.<sec>] block of a
--- personal TOML file. Reads the file, finds or creates the target header,
--- then replaces or removes the field line, and writes back.
---
--- We edit the file in-place so existing comments and formatting are preserved
--- as much as possible. Only the target field line is touched.
---
--- @param toml_path string Absolute path to the TOML file.
--- @param section string|nil Section name, or nil for the file-level [_meta].
--- @param field string "delay" or "color".
--- @param value string|number|nil The new value, or nil to remove the field.
local function patch_personal_toml(toml_path, section, field, value)
	local f = io.open(toml_path, "r")
	if not f then
		Logger.error(LOG, "patch_personal_toml: cannot open '%s' for reading.", toml_path)
		return
	end
	local lines = {}
	for raw in f:lines() do table.insert(lines, raw) end
	pcall(function() f:close() end)

	-- The header we are looking for depends on whether section is set
	local target_header = section
		and ("[_meta.sections." .. section .. "]")
		or  "[_meta]"

	-- Scan once: find the header line and collect its span until next header
	local header_line = nil
	local field_line  = nil   -- index of an existing field=… inside the block
	local next_header = nil   -- index of the next [section] after our block

	for i, ln in ipairs(lines) do
		local trimmed = ln:match("^%s*(.-)%s*$")
		if trimmed == target_header then
			header_line = i
		elseif header_line and not next_header then
			if trimmed:match("^%[") then
				-- Entered a new TOML section — stop scanning
				next_header = i
			elseif trimmed:match("^" .. field .. "%s*=") then
				field_line = i
			end
		end
	end

	if value ~= nil then
		-- Build the raw value string
		local val_str
		if field == "delay" then
			val_str = tostring(value)
		elseif field == "show_tooltip" then
			val_str = value and "true" or "false"
		else
			val_str = '"' .. tostring(value) .. '"'
		end
		local new_line = field .. " = " .. val_str

		if field_line then
			-- Replace the existing field line
			lines[field_line] = new_line
		elseif header_line then
			-- Insert the new field right after the header
			table.insert(lines, header_line + 1, new_line)
		else
			-- The target header does not exist — append it at the end
			table.insert(lines, "")
			table.insert(lines, target_header)
			table.insert(lines, new_line)
		end
	else
		-- Remove the field line if it exists
		if field_line then
			table.remove(lines, field_line)
		end
	end

	local out_f = io.open(toml_path, "w")
	if not out_f then
		Logger.error(LOG, "patch_personal_toml: cannot open '%s' for writing.", toml_path)
		return
	end
	pcall(function() out_f:write(table.concat(lines, "\n") .. "\n") end)
	pcall(function() out_f:close() end)

	Logger.debug(LOG, "Personal TOML patched: '%s' [%s] %s = %s.",
		toml_path, section or "_meta", field, tostring(value))
end





-- =================================
--- ==================================
--- ======= 5/ Bridge Handlers =======
--- ==================================
-- =================================

local function push_state()
	if not _webview then return end
	local ok, json = pcall(hs.json.encode, build_state())
	if not ok or not json then return end
	pcall(function() _webview:evaluateJavaScript("setData(" .. json .. ")") end)
end

--- Dispatches a mutation message from the webview.
--- Common categories go through hotstrings_config (user override file).
--- Personal categories patch the TOML file directly.
--- Extension categories go through hotstrings_config.resolve_ext override keys.
--- @param msg table The raw usercontent message.
local function on_message(msg)
	if type(msg) ~= "table" then return end
	local body = msg.body
	if type(body) ~= "table" or type(body.action) ~= "string" then return end

	local action  = body.action
	local cat     = body.category
	local group   = body.group
	local sec     = (type(body.section) == "string" and body.section ~= "") and body.section or nil

	-- Global bulk operations affect all common categories only
	if action == "reset_all" then
		for _, c in ipairs(CATEGORY_ORDER) do
			hotstrings_config.clear_override(c, nil, nil)
			for _, s in ipairs(hotstrings_config.get_sections(c)) do
				hotstrings_config.clear_override(c, s.name, nil)
			end
		end
		push_state()
		return
	end

	if action == "set_all_grey" then
		-- Set every common category's file-level colour to grey and wipe any
		-- per-section colour override so the grey cascades down. Delays untouched.
		local grey = "#6e6e73"
		for _, c in ipairs(CATEGORY_ORDER) do
			hotstrings_config.set_override(c, nil, "color", grey)
			for _, s in ipairs(hotstrings_config.get_sections(c)) do
				hotstrings_config.clear_override(c, s.name, "color")
			end
		end
		push_state()
		return
	end

	if action == "close" then
		M.close()
		return
	end

	-- Per-category mutations — dispatch by group
	if group == "personal" and type(body.personal_path) == "string" then
		local toml_path = body.personal_path
		if action == "set_delay" and type(body.ms) == "number" then
			patch_personal_toml(toml_path, sec, "delay", body.ms / 1000)
		elseif action == "clear_delay" then
			patch_personal_toml(toml_path, sec, "delay", nil)
		elseif action == "set_color" and type(body.hex) == "string" and body.hex ~= "" then
			patch_personal_toml(toml_path, sec, "color", body.hex)
		elseif action == "clear_color" then
			patch_personal_toml(toml_path, sec, "color", nil)
		elseif action == "set_tooltip" then
			patch_personal_toml(toml_path, sec, "show_tooltip", body.show_tooltip == true)
		elseif action == "clear_tooltip" then
			patch_personal_toml(toml_path, sec, "show_tooltip", nil)
		end

	elseif group and group:sub(1, 4) == "ext:" then
		-- Extension entries use "ext.<id>" as the override key in hotstrings_config
		local ext_id       = body.ext_id
		local override_key = ext_id and ("ext." .. ext_id) or cat
		if action == "set_delay" and type(body.ms) == "number" then
			hotstrings_config.set_override(override_key, sec, "delay", body.ms / 1000)
		elseif action == "clear_delay" then
			hotstrings_config.clear_override(override_key, sec, "delay")
		elseif action == "set_color" and type(body.hex) == "string" and body.hex ~= "" then
			hotstrings_config.set_override(override_key, sec, "color", body.hex)
		elseif action == "clear_color" then
			hotstrings_config.clear_override(override_key, sec, "color")
		elseif action == "set_tooltip" then
			hotstrings_config.set_override(override_key, sec, "show_tooltip", body.show_tooltip == true)
		elseif action == "clear_tooltip" then
			hotstrings_config.clear_override(override_key, sec, "show_tooltip")
		end

	else
		-- Common built-in categories
		if action == "set_delay" and type(body.ms) == "number" then
			hotstrings_config.set_override(cat, sec, "delay", body.ms / 1000)
		elseif action == "clear_delay" then
			hotstrings_config.clear_override(cat, sec, "delay")
		elseif action == "set_color" and type(body.hex) == "string" and body.hex ~= "" then
			hotstrings_config.set_override(cat, sec, "color", body.hex)
		elseif action == "clear_color" then
			hotstrings_config.clear_override(cat, sec, "color")
		elseif action == "set_tooltip" then
			hotstrings_config.set_override(cat, sec, "show_tooltip", body.show_tooltip == true)
		elseif action == "clear_tooltip" then
			hotstrings_config.clear_override(cat, sec, "show_tooltip")
		else
			return
		end
	end

	push_state()
end





-- ============================
--- =============================
--- ======= 6/ Public API =======
--- =============================
-- ============================

--- Configure optional directories for personal and extension hotstring discovery.
--- Must be called before M.open() if personal/extension groups are desired.
--- @param opts table { personal_dir = string|nil, extensions_dir = string|nil }
function M.setup(opts)
	if type(opts) ~= "table" then
		Logger.error(LOG, "M.setup(): opts must be a table.")
		return
	end
	if type(opts.personal_dir) == "string" and opts.personal_dir ~= "" then
		_config.personal_dir = opts.personal_dir
		Logger.debug(LOG, "Personal dir configured: '%s'.", _config.personal_dir)
	end
	if type(opts.extensions_dir) == "string" and opts.extensions_dir ~= "" then
		_config.extensions_dir = opts.extensions_dir
		Logger.debug(LOG, "Extensions dir configured: '%s'.", _config.extensions_dir)
	end
end

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
		assets_dir    = ASSETS_DIR,
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
