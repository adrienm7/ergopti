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
local Logger            = require("infra.logger")
local hotstrings_config = require("modules.hotstrings.hotstrings_config")
local ConfigSchema      = require("modules.hotstrings.hotstrings_config_schema")
local TomlReader        = require("infra.toml.reader")
local TomlRecordEditor  = require("infra.toml.record_editor")
local FileSystem        = require("adapters.file_system")
local i18n              = require("infra.i18n")
local Paths            = require("infra.paths")

local LOG = "hotstrings_config_window"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local _webview     = nil
local _usercontent = nil
local _closing_webview = nil

--- Releases one exact native bridge callback before dropping its Lua owner.
--- @param usercontent any Candidate or committed usercontent controller.
--- @return boolean released Whether callback release completed.
local function release_usercontent(usercontent)
	if not usercontent or type(usercontent.setCallback) ~= "function" then
		Logger.error(LOG, "Cannot release webview usercontent callback.")
		return false
	end
	local released = pcall(function() usercontent:setCallback(nil) end)
	if not released then
		Logger.error(LOG, "Failed to release webview usercontent callback.")
	end
	return released
end

-- Module-level config set by M.setup() before the first M.open() call.
local _config = {
	personal_dir   = nil,
	extensions_dir = nil,
}

-- Window geometry is resolved at open time from the shared manifest
-- (ui_builder.get_app_geometry → _shared/ui/apps.manifest.json, SSoT). No local
-- width/height constant: hardcoding here is what caused the cross-driver drift.

-- The global delay fallback (seconds) that applies when no TOML default is set.
-- Fallback only. The live value is read from hotstrings_config, which loads it
-- from the shared canon the AutoHotkey driver also reads. A hand-mirrored copy
-- with a comment saying the two "must stay in sync" IS the second source — and
-- the one that silently stops matching when the canon moves.
local GLOBAL_DEFAULT_DELAY_MS_FALLBACK = 750

--- Returns the shared global default expansion delay in milliseconds.
--- @return number
local function global_default_delay_ms()
	local ok, cfg = pcall(require, "modules.hotstrings.hotstrings_config")
	if ok and type(cfg) == "table" and type(cfg.get_global_default_delay_ms) == "function" then
		local v = cfg.get_global_default_delay_ms()
		if type(v) == "number" then return v end
	end
	return GLOBAL_DEFAULT_DELAY_MS_FALLBACK
end

-- The frontend (index.html / script.js / style.css) lives in the cross-driver
-- _shared/ui/ tree so the Windows WebView2 host renders the identical UI; both
-- drivers resolve it through Paths.shared. This init.lua stays macOS-specific.
local ASSETS_DIR = (Paths.shared("ui/hotstrings_config_window") or "") .. "/"

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
-- =========================================
-- ======= 2/ File Discovery Helpers =======
-- =========================================
-- =========================================

-- Blessed hs.fs.dir wrapper (throw- and state-safe) now lives in infra/fs_dir so
-- the contract is shared with init.lua's hotstring discovery; see
-- init-fsdir-drops-state. Aliased locally so every call site below is unchanged.
local safe_dir_entries = require("infra.fs_dir").entries

--- Lists TOML files in a directory, skipping names that start with `_`.
--- Returns an array of absolute paths.
--- @param dir string Absolute path to the directory.
--- @return table Array of absolute TOML paths.
local function list_toml_files(dir)
	local out = {}
	for _, name in ipairs(safe_dir_entries(dir)) do
		if name:sub(1, 1) ~= "_" and name:match("%.toml$") then
			table.insert(out, dir .. "/" .. name)
		end
	end
	table.sort(out)
	return out
end

--- Reads one committed TOML snapshot for all metadata and section derivations.
--- @param toml_path string Absolute path to the TOML file.
--- @return table|nil parsed
local function read_committed_toml(toml_path)
	local ok, parsed, committed = pcall(TomlReader.parse, toml_path)
	if not ok or committed ~= true or type(parsed) ~= "table" then
		Logger.error(LOG, "TOML UI read did not commit: '%s'.", toml_path)
		return nil
	end
	return parsed
end

--- Derives the effective metadata from one committed TOML snapshot.
--- @param parsed table Committed reader result.
--- @return table metadata
local function read_file_meta(parsed)
	return {
		delay        = parsed.meta and parsed.meta.delay,
		color        = parsed.meta and parsed.meta.color,
		show_tooltip = parsed.meta and parsed.meta.show_tooltip,
		priority     = parsed.meta and parsed.meta.priority,
		sections     = (parsed.meta and parsed.meta.sections) or {},
	}
end

--- Derives the sections list from one committed TOML snapshot.
--- @param parsed table Committed reader result.
--- @return table Array of { name = string, description = string }.
local function read_file_sections(parsed)
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

--- Resolves a personal category through the server-owned directory catalogue.
--- The WebView receives display data, not filesystem authority: a bridge
--- message may identify a rendered category, but it may never choose a path.
--- @param category any Expected `personal:<stem>` category identifier.
--- @return string|nil toml_path
local function personal_toml_path(category)
	if type(category) ~= "string" or category == "" then return nil end
	for _, toml_path in ipairs(list_toml_files(_config.personal_dir)) do
		if category == "personal:" .. stem(toml_path) then return toml_path end
	end
	return nil
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
	local ext_dirs = {}
	for _, name in ipairs(safe_dir_entries(extensions_dir)) do
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
		local read_ok, manifest_content, manifest_status, manifest_detail =
			pcall(FileSystem.read_with_status, manifest)
		if read_ok and manifest_status == "ok" and type(manifest_content) == "string" then
			for line in (manifest_content .. "\n"):gmatch("([^\n]*)\n") do
				line = line:gsub("\r$", "")
				local v = line:match('^name%s*=%s*"(.-)"')
				if v then label = v; break end
			end
		elseif not read_ok or manifest_status ~= "absent" then
			Logger.error(LOG, "Extension manifest read did not commit for '%s' — %s.",
				manifest, tostring(read_ok and manifest_detail or manifest_content))
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

--- Source-default collision priority (personal 50 / package 30 / common 10) for a
--- UI group, read from the keymap engine so the window never hardcodes a fourth
--- copy of the tiers (the single source is _shared/modules/hotstrings/priority.json, held
--- equal across drivers by tools/test/test-priority-parity.cjs). The keymap module
--- is required lazily — it is loaded long before this window opens, but a headless
--- harness may lack it, in which case the source default is simply omitted.
--- @param group string Group key ("common", "personal", or "ext:<id>").
--- @param name string Unique category name (the common category for the "common" group).
--- @return number|nil The source-default priority, or nil when keymap is unavailable.
local function source_priority_for(group, name)
	local ok, keymap = pcall(require, "modules.keymap")
	if not ok or type(keymap.source_priority) ~= "function" then return nil end
	local category
	if group == "personal" then
		category = "personal"
	elseif type(group) == "string" and group:sub(1, 4) == "ext:" then
		category = "ext." .. group:sub(5)
	else
		category = name
	end
	local ok2, p = pcall(keymap.source_priority, category)
	return ok2 and p or nil
end

--- Builds one category entry table for the UI state.
--- @param name string Unique category name (used as mutation key).
--- @param title string Display title.
--- @param group string Group key ("common", "personal", or "ext:<id>").
--- @param effective table { delay, color } from resolve/resolve_ext.
--- @param default_meta table { delay, color, priority } TOML defaults (nil ok).
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

	-- Source-default priority for the group; the per-section rows inherit it.
	local source_prio = source_priority_for(group, name)

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
		priority              = override.priority or default_meta.priority or source_prio,
		priority_default      = default_meta.priority or source_prio,
		priority_overridden   = override.priority ~= nil,
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
			priority                = s_ov.priority or s_def.priority or source_prio,
			priority_default        = s_def.priority or source_prio,
			priority_overridden     = s_ov.priority ~= nil,
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
		global_default_delay_ms = global_default_delay_ms(),
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
		local personal_entries = {}
		for _, toml_path in ipairs(personal_files) do
			local parsed = read_committed_toml(toml_path)
			if parsed then
				local file_stem = stem(toml_path)
				local file_meta = read_file_meta(parsed)
				local file_secs = read_file_sections(parsed)
				local effective = {
					delay        = file_meta.delay,
					color        = file_meta.color,
					show_tooltip = file_meta.show_tooltip,
					priority     = file_meta.priority,
				}

				local entry = build_cat_entry(
					"personal:" .. file_stem,
					file_stem,
					"personal",
					effective,
					file_meta,
					nil,
					file_secs,
					function(sec_name)
						local sec_data = file_meta.sections[sec_name] or {}
						return {
							effective = { delay = sec_data.delay, color = sec_data.color,
								show_tooltip = sec_data.show_tooltip, priority = sec_data.priority },
							default_meta = { delay = sec_data.delay, color = sec_data.color,
								show_tooltip = sec_data.show_tooltip, priority = sec_data.priority },
							override = {},
						}
					end
				)
				entry.delay_overridden = false
				entry.color_overridden = false
				table.insert(personal_entries, entry)
			end
		end
		if #personal_entries > 0 then
			table.insert(out.groups, {
				key   = "personal",
				label = i18n.get("hs_config.group_personal"),
			})
			for _, entry in ipairs(personal_entries) do table.insert(out.categories, entry) end
		end
	end


	-- 3.3) Extension TOML files
	local extensions = discover_extensions(_config.extensions_dir)
	for _, ext in ipairs(extensions) do
		local group_key = "ext:" .. ext.ext_id
		local extension_entries = {}
		for _, file_info in ipairs(ext.files) do
			local toml_path = file_info.toml_path
			local file_stem = file_info.title
			local ext_id    = ext.ext_id
			local parsed = read_committed_toml(toml_path)
			if parsed then
				local file_secs = read_file_sections(parsed)
				local default_meta = {
					delay = parsed.meta and parsed.meta.delay,
					color = parsed.meta and parsed.meta.color,
					priority = parsed.meta and parsed.meta.priority,
				}
				local effective = hotstrings_config.resolve_ext(ext_id, toml_path, nil)
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
						local sections = parsed.meta and parsed.meta.sections or {}
						local section_meta = sections[sec_name] or {}
						return {
							effective = hotstrings_config.resolve_ext(ext_id, toml_path, sec_name),
							default_meta = { delay = section_meta.delay, color = section_meta.color,
								show_tooltip = section_meta.show_tooltip, priority = section_meta.priority },
							override = hotstrings_config.get_user_override("ext." .. ext_id, sec_name) or {},
						}
					end
				)
				entry.ext_id   = ext_id
				entry.ext_path = toml_path
				table.insert(extension_entries, entry)
			else
				Logger.error(LOG, "Extension TOML omitted after an uncommitted read: '%s'.", toml_path)
			end
		end
		if #extension_entries > 0 then
			table.insert(out.groups, { key = group_key, label = ext.label })
			for _, entry in ipairs(extension_entries) do table.insert(out.categories, entry) end
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
	if not ConfigSchema.is_section(section) then
		Logger.error(LOG, "patch_personal_toml: section must be a supported bare identifier.")
		return false
	end
	if field == "color" and value ~= nil and not ConfigSchema.is_color(value) then
		Logger.error(LOG, "patch_personal_toml: color must contain 3 to 8 hexadecimal digits.")
		return false
	end
	local read_ok, content, read_status, read_detail = pcall(FileSystem.read_with_status, toml_path)
	if not read_ok or read_status ~= "ok" or type(content) ~= "string" then
		Logger.error(LOG, "patch_personal_toml: source read did not commit for '%s' — %s.",
			toml_path, tostring(read_ok and read_detail or content))
		return false
	end
	-- The header we are looking for depends on whether section is set
	local target_header = section
		and ("[_meta.sections." .. section .. "]")
		or  "[_meta]"
	local val_str = nil
	if value ~= nil then
		if field == "delay" or field == "priority" then
			val_str = tostring(value)
		elseif field == "show_tooltip" then
			val_str = value and "true" or "false"
		else
			val_str = ConfigSchema.encode_basic_string(value)
			if not val_str then
				Logger.error(LOG, "patch_personal_toml: string field received an invalid value type.")
				return false
			end
		end
	end
	local patched, patch_err = TomlRecordEditor.patch_table_field(
		content,
		target_header,
		field,
		val_str
	)
	if not patched then
		Logger.error(LOG, "patch_personal_toml: source scan failed for '%s' — %s.",
			toml_path, tostring(patch_err))
		return false
	end

	local write_ok, committed = pcall(
		FileSystem.write_if_unchanged,
		toml_path,
		patched,
		{ status = "ok", content = content }
	)
	if not write_ok or committed ~= true then
		Logger.error(LOG, "patch_personal_toml: atomic publication failed for '%s'.", toml_path)
		return false
	end

	Logger.debug(LOG, "Personal TOML patched: '%s' [%s] %s = %s.",
		toml_path, section or "_meta", field, tostring(value))
	return true
end





--- ==================================
--- ==================================
--- ======= 5/ Bridge Handlers =======
--- ==================================
--- ==================================

local function push_state()
	if not _webview then return end
	local ok, json = pcall(hs.json.encode, build_state())
	if not ok or not json then return end
	pcall(function() _webview:evaluateJavaScript("setData(" .. json .. ")") end)
end

--- Refresh callback injected by whoever opens this window (see M.open's caller in
--- ui.menu.menu_hotstrings_management). Left nil when nothing needs notifying.
--- @type function|nil
M._on_config_changed = nil

--- Pushes a freshly-resolved file-level delay into the running keymap engine.
--- The override store this window writes is persistent, but the expansion hot path
--- reads CoreState.DELAYS, which is populated at boot and afterwards written ONLY by
--- keymap.set_delay. Without this call the edit is saved and the menubar redraws with
--- the new number, yet the engine keeps enforcing the old threshold for the rest of
--- the session — the menubar sibling (ui/menu/menu_hotstrings_management.lua) has
--- always made this call; this window did not.
--- Only file-level delays are covered: per-section delays live in
--- CoreState.SECTION_DELAYS, which is rebuilt during hotstring registration rather
--- than through a setter, so they already require a reload to take effect.
--- @param category string The hotstring category whose file-level delay changed.
local function push_delay_to_engine(category)
	if type(category) ~= "string" or category == "" then return end
	local ok, keymap = pcall(require, "modules.keymap")
	if not ok or type(keymap) ~= "table" then return end
	if type(keymap.set_delay) ~= "function" or type(keymap.DELAY_KEY_TO_CATEGORY) ~= "table" then return end

	local resolved = hotstrings_config.resolve(category, nil)
	if type(resolved) ~= "table" or type(resolved.delay) ~= "number" then return end

	for key, cat in pairs(keymap.DELAY_KEY_TO_CATEGORY) do
		if cat == category then
			pcall(keymap.set_delay, key, resolved.delay)
			return
		end
	end
end

--- Re-renders the page AND notifies the opener that the override store changed.
--- The menubar bakes the resolved delay / colour and the "(default)" indicator
--- into its item titles at BUILD time, so without an explicit refresh those rows
--- keep rendering pre-edit values and a now-false default tag for the rest of the
--- session — the two UIs silently desync despite sharing one persistent store.
local function commit_and_push()
	push_state()
	if type(M._on_config_changed) == "function" then
		Logger.callback(LOG, "Hotstrings configuration refresh", M._on_config_changed)
	end
end

--- Dispatches a mutation message from the webview.
--- Common categories go through hotstrings_config (user override file).
--- Personal categories patch the TOML file directly.
--- Extension categories go through hotstrings_config.resolve_ext override keys.
--- @param msg table The raw usercontent message.
--- @return boolean committed True only when the requested mutation committed.
local function on_message(msg)
	if type(msg) ~= "table" then return false end
	local body = msg.body
	if type(body) ~= "table" or type(body.action) ~= "string" then return false end

	local action  = body.action
	local cat     = body.category
	local group   = body.group
	local sec     = body.section == "" and nil or body.section
	if not ConfigSchema.is_section(sec) then
		Logger.error(LOG, "Rejected a hotstrings configuration message with an invalid section.")
		return false
	end
	if action == "set_color" and not ConfigSchema.is_color(body.hex) then
		Logger.error(LOG, "Rejected a hotstrings configuration message with an invalid color.")
		return false
	end

	-- Global bulk operations affect all common categories only
	if action == "reset_all" then
		for _, c in ipairs(CATEGORY_ORDER) do
			if hotstrings_config.clear_override(c, nil, nil) ~= true then return false end
			for _, s in ipairs(hotstrings_config.get_sections(c)) do
				if hotstrings_config.clear_override(c, s.name, nil) ~= true then return false end
			end
		end
		for _, c in ipairs(CATEGORY_ORDER) do push_delay_to_engine(c) end
		commit_and_push()
		return true
	end

	if action == "set_all_grey" then
		-- Set every common category's file-level colour to grey and wipe any
		-- per-section colour override so the grey cascades down. Delays untouched.
		local grey = "#6e6e73"
		for _, c in ipairs(CATEGORY_ORDER) do
			if hotstrings_config.set_override(c, nil, "color", grey) ~= true then return false end
			for _, s in ipairs(hotstrings_config.get_sections(c)) do
				if hotstrings_config.clear_override(c, s.name, "color") ~= true then return false end
			end
		end
		commit_and_push()
		return true
	end

	if action == "close" then
		M.close()
		return true
	end

	local committed = false

	-- Per-category mutations — dispatch by group
	if group == "personal" then
		local toml_path = personal_toml_path(cat)
		if not toml_path then
			Logger.error(LOG, "Rejected a personal hotstrings mutation for an unknown native category.")
			return false
		end
		if action == "set_delay" and type(body.ms) == "number" then
			committed = patch_personal_toml(toml_path, sec, "delay", body.ms / 1000)
		elseif action == "clear_delay" then
			committed = patch_personal_toml(toml_path, sec, "delay", nil)
		elseif action == "set_color" then
			committed = patch_personal_toml(toml_path, sec, "color", body.hex)
		elseif action == "clear_color" then
			committed = patch_personal_toml(toml_path, sec, "color", nil)
		elseif action == "set_tooltip" then
			committed = patch_personal_toml(toml_path, sec, "show_tooltip", body.show_tooltip == true)
		elseif action == "clear_tooltip" then
			committed = patch_personal_toml(toml_path, sec, "show_tooltip", nil)
		elseif action == "set_priority" and type(body.priority) == "number" then
			committed = patch_personal_toml(toml_path, sec, "priority", body.priority)
		elseif action == "clear_priority" then
			committed = patch_personal_toml(toml_path, sec, "priority", nil)
		else
			return false
		end

	elseif group and group:sub(1, 4) == "ext:" then
		-- Extension entries use "ext.<id>" as the override key in hotstrings_config
		local ext_id       = body.ext_id
		local override_key = ext_id and ("ext." .. ext_id) or cat
		if action == "set_delay" and type(body.ms) == "number" then
			committed = hotstrings_config.set_override(override_key, sec, "delay", body.ms / 1000)
		elseif action == "clear_delay" then
			committed = hotstrings_config.clear_override(override_key, sec, "delay")
		elseif action == "set_color" then
			committed = hotstrings_config.set_override(override_key, sec, "color", body.hex)
		elseif action == "clear_color" then
			committed = hotstrings_config.clear_override(override_key, sec, "color")
		elseif action == "set_tooltip" then
			committed = hotstrings_config.set_override(override_key, sec, "show_tooltip", body.show_tooltip == true)
		elseif action == "clear_tooltip" then
			committed = hotstrings_config.clear_override(override_key, sec, "show_tooltip")
		elseif action == "set_priority" and type(body.priority) == "number" then
			committed = hotstrings_config.set_override(override_key, sec, "priority", body.priority)
		elseif action == "clear_priority" then
			committed = hotstrings_config.clear_override(override_key, sec, "priority")
		else
			return false
		end

	else
		-- Common built-in categories
		if action == "set_delay" and type(body.ms) == "number" then
			committed = hotstrings_config.set_override(cat, sec, "delay", body.ms / 1000)
		elseif action == "clear_delay" then
			committed = hotstrings_config.clear_override(cat, sec, "delay")
		elseif action == "set_color" then
			committed = hotstrings_config.set_override(cat, sec, "color", body.hex)
		elseif action == "clear_color" then
			committed = hotstrings_config.clear_override(cat, sec, "color")
		elseif action == "set_tooltip" then
			committed = hotstrings_config.set_override(cat, sec, "show_tooltip", body.show_tooltip == true)
		elseif action == "clear_tooltip" then
			committed = hotstrings_config.clear_override(cat, sec, "show_tooltip")
		elseif action == "set_priority" and type(body.priority) == "number" then
			committed = hotstrings_config.set_override(cat, sec, "priority", body.priority)
		elseif action == "clear_priority" then
			committed = hotstrings_config.clear_override(cat, sec, "priority")
		else
			return false
		end
	end

	if committed ~= true then return false end
	if group ~= "personal" and (action == "set_delay" or action == "clear_delay") and sec == nil then
		push_delay_to_engine(cat)
	end
	commit_and_push()
	return true
end

-- Bridge-handler test seam: on_message is the only entry point that mutates the
-- override store, so the refresh contract is asserted by driving it directly
-- rather than by standing up a webview.
M._on_message = on_message





--- =============================
--- =============================
--- ======= 6/ Public API =======
--- =============================
--- =============================

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
		return true
	end
	if _usercontent and M.close() ~= true then
		Logger.error(LOG, "Cannot open hotstrings config while bridge cleanup remains pending.")
		return false
	end

	-- Fail before acquiring a native controller. A missing manifest entry has no
	-- webview to own or eventually release that controller.
	local geo = ui_builder.get_app_geometry("hotstrings_config_window")
	if not geo then return false end

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "hotstrings_config_bridge")
	if not ok_uc or not uc then
		Logger.error(LOG, "Error creating usercontent bridge.")
		return false
	end
	local callback_ok = pcall(function() uc:setCallback(on_message) end)
	if not callback_ok then
		Logger.error(LOG, "Failed to register webview usercontent callback.")
		release_usercontent(uc)
		return false
	end

	-- Stage both native owners locally. Module state becomes visible only after
	-- the factory returns the webview that owns this exact controller.
	local webview
	local closed = false
	local show_ok, candidate = xpcall(function()
		return ui_builder.show_webview({
			frame        = ui_builder.get_centered_frame(geo.width, geo.height),
			title        = i18n.get("hs_config.window_title"),
			style_masks  = { "titled", "closable", "resizable", "utility" },
			usercontent  = uc,
			assets_dir    = ASSETS_DIR,
			on_navigation = function(action)
				if action == "didFinishNavigation" then
					push_state()
				end
				return true
			end,
			on_close = function()
				if _closing_webview == webview then return end
				closed = true
				if _webview == webview then _webview = nil end
				if _usercontent == uc then
					if release_usercontent(uc) then _usercontent = nil end
				end
			end,
		})
	end, debug.traceback)
	webview = candidate
	if show_ok ~= true or not webview or closed then
		if show_ok ~= true then Logger.error(LOG, "Failed to create hotstrings config webview.") end
		release_usercontent(uc)
		return false
	end
	_usercontent = uc
	_webview = webview
	Logger.info(LOG, "Hotstrings config window opened.")
	return true
end

--- Close and destroy the window.
--- @return boolean committed
function M.close()
	local webview = _webview
	local usercontent = _usercontent
	if webview then
		if type(webview.delete) ~= "function" then
			Logger.error(LOG, "Hotstrings config close refused; owned WebView has no delete method.")
			return false
		end
		_closing_webview = webview
		local ok, err = xpcall(function() webview:delete() end, debug.traceback)
		if _closing_webview == webview then _closing_webview = nil end
		if not ok then
			Logger.error(LOG, "Hotstrings config close did not commit; exact WebView retained: %s.",
				tostring(err))
			return false
		end
		if _webview == webview then _webview = nil end
	end
	if usercontent and _usercontent == usercontent then
		if not release_usercontent(usercontent) then return false end
		_usercontent = nil
	end
	return true
end

return M
