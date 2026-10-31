--- ui/menu/menu_builder.lua

--- ==============================================================================
--- MODULE: Menu Builder (Linux)
--- DESCRIPTION:
--- Builds the tray menu item list from the daemon's runtime state. Called by
--- ergopti_hotstrings.lua to populate the tray_menu adapter with dynamic items
--- reflecting the current hotstring groups, layouts, LLM models, and metrics.
---
--- The menu tree mirrors the macOS menubar (§9 of the parity plan): its rows,
--- their order and the separators between them are the manifest's `top_level`,
--- which M.build dispatches through its builder table.
---
--- Items that depend on features not yet implemented on Linux
--- are present as labelled stubs that log the action — they don't crash and
--- they show the intended final shape.
---
--- FEATURES & RATIONALE:
--- 1. Hierarchical items: items with a `menu` sub-table are rendered as
---    submenus, which the tray backend renders as real nested GtkMenus.
--- 2. All callbacks are closures over the daemon's state — zero global coupling.
--- 3. New sections (shortcuts, tap-holds, gestures, configuration, language,
---    debug) are added as documented stubs so the menu shape is correct.
--- ==============================================================================

local M = {}
local WindowTitles = require("window_titles")
local NativePresentation = require("infra.native_presentation")
local PrepareNativePresentation, NativePresentationTitle = NativePresentation.prepare, NativePresentation.title
local NumberRowPolicy = require("layout.number_row_policy")
local ParameterLabel = require("action_parameter_label")
local RowDialect = require("menu.row_dialect")

local Logger = require("logger.shim")
local Extensions = require("hotstrings.extensions")
local PersonalFiles = require("hotstrings.personal_files")
local PersonalFileMenu = require("menu.personal_files")
local Languages = require("hotstrings.languages")
local LocaleTable = require("_generated.locale_table")
local MagicKey = require("modules.hotstrings.magic_key")
local MagicKeySourceRows = require("keymap.magic_key_source")
local MagicFrame = require("menu.frames.magic_frame")
local ParentSource = require("menu.frames.parent_source")
local PersonalInfoSource = require("menu.frames.personal_info_source")
local PreviewSettings = require("modules.hotstrings.preview_settings")
local RepeatKey = require("modules.hotstrings.repeat_key")
local Modal = require("ui.modal")
local TextPrompt = require("ui.text_prompt")
local PrivacyPolicy = require("llm.trigger_policy")
local LlmBackendRows = require("ui.menu.llm_backend_rows")
local ProgrammableHotstrings = require("ui.menu.programmatic_hotstrings")
local ProgrammableMenuPolicy = require("menu.programmable_hotstrings")
local LOG = "ui.menu.menu_builder"
local COMMAND = require("config_keys").COMMAND


-- Delays are stored in seconds and typed in milliseconds: seconds is what the
-- cascade and the TOMLs speak, milliseconds is what a person means by "wait a
-- bit longer". The conversion happens only at this boundary.
local MS_PER_SEC = 1000

-- The category id of the user's own hotstrings — the stem of personal.toml, and
-- the same name the editor bridge writes under. Named here so the default-section
-- picker reads the sections of that pack rather than guessing at a spelling.
local PERSONAL_CATEGORY = "personal"

-- Single source of the driver version and of the build identity.
local Version = require("infra.version")

-- The one answer to "installed build or source run".
local Installation = require("infra.installation")

-- The shared wording of the About version row.
local VersionLabel = require("updater.version_label")

-- The shared automatic-check schedule (frequency presets and their snap).
local Schedule = require("updater.schedule")

--- Flag and native name of a locale code, from the generated locale table.
--- @param code string
--- @return string
local function language_label(code)
	return Languages.label(code, LocaleTable)
end

-- The shared manifest menu renderer, bound for this driver (infra/manifest_menu).
-- pcall for the same reason i18n_safe exists: the tray menu must still build when
-- the shared tree is not reachable, which is a real boot-order case on a partial
-- install rather than a hypothetical.
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

-- The imported facade and its actual functions own every later boundary read.
local separator_modules = package.loaded
local separator_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "top_level_separator_receiver")
local separator_render = type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")
local separator_array = type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_array")
local separator_root = type(ManifestMenu) == "table" and rawget(ManifestMenu, "get_root")
local header_template = type(ManifestMenu) == "table" and rawget(ManifestMenu, "template_rows")
local header_command = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_row")
local uninstall_caption_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_caption_receiver")
local uninstall_caption_i18n = rawget(separator_modules, "infra.i18n")
local uninstall_caption_get = type(uninstall_caption_i18n) == "table" and rawget(uninstall_caption_i18n, "get")

--- Retains only the actual caption facade and translator used by removal options.
--- @return boolean current
local function uninstall_caption_facade_current()
	return type(ManifestMenu) == "table" and getmetatable(ManifestMenu) == nil
		and rawget(package, "loaded") == separator_modules
		and rawget(separator_modules, "infra.manifest_menu") == ManifestMenu
		and type(uninstall_caption_factory) == "function" and rawget(ManifestMenu, "command_caption_receiver") == uninstall_caption_factory
		and type(uninstall_caption_i18n) == "table" and getmetatable(uninstall_caption_i18n) == nil
		and rawget(separator_modules, "infra.i18n") == uninstall_caption_i18n
		and type(uninstall_caption_get) == "function" and rawget(uninstall_caption_i18n, "get") == uninstall_caption_get
end

--- Refuses facade or function withdrawal without invoking its replacement.
--- @return boolean
local function separator_facade_current()
	return type(ManifestMenu) == "table" and getmetatable(ManifestMenu) == nil
		and rawget(package, "loaded") == separator_modules
		and rawget(separator_modules, "infra.manifest_menu") == ManifestMenu
		and type(separator_factory) == "function" and rawget(ManifestMenu, "top_level_separator_receiver") == separator_factory
		and type(separator_render) == "function" and rawget(ManifestMenu, "render_rows") == separator_render
		and type(separator_array) == "function" and rawget(ManifestMenu, "get_array") == separator_array
		and type(separator_root) == "function" and rawget(ManifestMenu, "get_root") == separator_root
end

--- Retains the imported template and command row owners across header readers.
--- @return boolean current
local function header_facade_current()
	return separator_facade_current()
		and type(header_template) == "function" and rawget(ManifestMenu, "template_rows") == header_template
		and type(header_command) == "function" and rawget(ManifestMenu, "command_row") == header_command
end

local _fill = require("ui.menu.menu_dialogs")._fill
local shell_quote = require("ui.menu.menu_dialogs").shell_quote
local succeeded = require("ui.menu.menu_dialogs").succeeded
local prompt_text = require("ui.menu.menu_dialogs").prompt_text
local show_error = require("ui.menu.menu_dialogs").show_error
local show_info = require("ui.menu.menu_dialogs").show_info
local zenity_plain = require("ui.menu.menu_dialogs").zenity_plain
local assign_parameterized_action = require("ui.menu.menu_dialogs").assign_parameterized_action
local open_action_picker = require("ui.menu.menu_dialogs").open_action_picker
local slot_binding_rows = require("ui.menu.menu_dialogs").slot_binding_rows
local ask_yes_no = require("ui.menu.menu_dialogs").ask_yes_no



-- =========================================
-- =========================================
-- ======= 1/ Section Builders =============
-- =========================================
-- =========================================

--- The version as the header shows it: "v0.0.0-dev.12" for a release, the bare
--- token for a source run or an unknown build ("local", "unknown").
--- @param version string
--- @return string
local function _version_text(version)
	local v = tostring(version)
	if v:match("^%d") then return "v" .. v end
	return v
end

--- Builds the top-level header with version.
--- Returns one provider row and its retained publication receipt.
---
--- While the script is paused the header is the way back, as on macOS, where the
--- title row resumes: it used to stay a disabled label, so a paused script could
--- only be resumed by a gesture or a shortcut the user had to remember.
local function _build_header(ctx)
	if not header_facade_current() then return nil end
	local root = separator_root()
	if not header_facade_current() or type(root) ~= "table" or getmetatable(root) ~= nil then return nil end
	local active = separator_array("linux_tray_active_header")
	if not header_facade_current() or getmetatable(root) ~= nil then return nil end
	local paused = separator_array("linux_tray_paused_header")
	if not header_facade_current() or type(root) ~= "table" or getmetatable(root) ~= nil then return nil end
	local captured = {}
	local projected, projected_fields
	for key, rows in next, { linux_tray_active_header = active, linux_tray_paused_header = paused } do
		if type(rows) ~= "table" or getmetatable(rows) ~= nil or rawget(root, key) ~= rows then return nil end
		for index in next, rows do if index ~= 1 then return nil end end
		local record = rawget(rows, 1)
		if type(record) ~= "table" or getmetatable(record) ~= nil then return nil end
		local fields = {}
		for name, value in next, record do
			if name ~= "type" and name ~= "id" and name ~= "i18n" and name ~= "caption_getter"
				and name ~= "caption_layout" and name ~= "caption_joiner" and name ~= "platforms"
				and name ~= "unavailable" then return nil end
			fields[name] = value
		end
		local expected_kind = key == "linux_tray_active_header" and "label" or "command"
		local expected_id = key == "linux_tray_active_header" and "linux_tray_active_header" or require("config_keys").COMMAND.LINUX_TRAY_RESUME
		if rawget(record, "type") ~= expected_kind or rawget(record, "id") ~= expected_id
			or type(rawget(record, "i18n")) ~= "string" or rawget(record, "i18n") == ""
			or rawget(record, "caption_getter") ~= "linux_tray_version"
			or rawget(record, "caption_layout") ~= "prefix" or rawget(record, "caption_joiner") ~= " — "
			or rawget(record, "unavailable") ~= "hide" then return nil end
		local platforms = rawget(record, "platforms")
		if type(platforms) ~= "table" or getmetatable(platforms) ~= nil
			or rawget(platforms, 1) ~= "linux" then return nil end
		for index in next, platforms do if index ~= 1 then return nil end end
		captured[key] = { rows = rows, record = record, fields = fields, platforms = platforms }
	end
	if captured.linux_tray_active_header == nil or captured.linux_tray_paused_header == nil then return nil end

	local function current()
		if not header_facade_current() or separator_root() ~= root or getmetatable(root) ~= nil then return false end
		for key, snapshot in next, captured do
			local rows, record, platforms = snapshot.rows, snapshot.record, snapshot.platforms
			if not header_facade_current() or separator_array(key) ~= rows or rawget(root, key) ~= rows
				or getmetatable(rows) ~= nil or rawget(rows, 1) ~= record or getmetatable(record) ~= nil
				or rawget(record, "platforms") ~= platforms or getmetatable(platforms) ~= nil
				or rawget(platforms, 1) ~= "linux" then return false end
			for index in next, rows do if index ~= 1 then return false end end
			for index in next, platforms do if index ~= 1 then return false end end
			for name, value in next, snapshot.fields do if rawget(record, name) ~= value then return false end end
			for name in next, record do if snapshot.fields[name] == nil then return false end end
		end
		if projected ~= nil then
			if getmetatable(projected) ~= nil then return false end
			for name, value in next, projected_fields do if rawget(projected, name) ~= value then return false end end
			for name in next, projected do if projected_fields[name] == nil then return false end end
		end
		return header_facade_current()
	end

	local version = _version_text(ctx._version or Version.VERSION)
	local is_paused = ctx.paused == true
	if not current() then return nil end
	local ok, rows = pcall(function()
		if is_paused then
			return ManifestMenu.template_rows("linux_tray_paused_header", { [require("config_keys").COMMAND.LINUX_TRAY_RESUME] = function()
				if type(ctx.on_toggle_pause) ~= "function" then
					Logger.error(LOG, "Paused title row: ctx.on_toggle_pause is absent — the script stays paused.")
					return
				end
				ctx.on_toggle_pause()
			end },
				{ ["linux_tray_version"] = function() return version end }, {})
		end
		return ManifestMenu.template_rows("linux_tray_active_header", {},
			{ ["linux_tray_version"] = function() return version end }, {})
	end)
	if not ok or not current() or type(rows) ~= "table" or getmetatable(rows) ~= nil then return nil end
	for index in next, rows do if index ~= 1 then return nil end end
	local row = rawget(rows, 1)
	if type(row) ~= "table" or getmetatable(row) ~= nil or type(rawget(row, "label")) ~= "string"
		or rawget(row, "label") == "" then return nil end
	for name in next, row do
		if name ~= "label" and (is_paused and name ~= "action" or not is_paused and name ~= "disabled") then return nil end
	end
	if is_paused then
		if type(rawget(row, "action")) ~= "function" then return nil end
	elseif rawget(row, "disabled") ~= true then return nil end
	projected, projected_fields = row, {}
	for name, value in next, row do projected_fields[name] = value end
	if not current() then return nil end
	return row, current
end

--- Greys one feature row for a pause, and strips what would let it act.
---
--- Stripped, not merely greyed: a disabled row whose submenu or handler survives
--- still acts the moment a tray backend renders the greying differently.
--- @param row table Row data from a section builder.
--- @return table The same row, greyed.
local function _grey_for_pause(row)
	if type(row) ~= "table" or row.separator then return row end
	row.disabled = true
	row.submenu = nil
	row.items = nil
	row.action = nil
	return row
end

--- Whether a manifest row is visible on this driver. A row with no ``platforms``
--- restriction is visible everywhere.
--- @param row table Manifest row.
--- @return boolean
local function _row_is_for_linux(row)
	if type(row.platforms) ~= "table" then return true end
	for _, p in ipairs(row.platforms) do
		if p == "linux" then return true end
	end
	return false
end

local _build_layouts = require("ui.menu.menu_layouts").build

--- Delegates the personal-information editor source admission to the shared module.
--- @return function|nil current
--- @return function|nil template
local function personal_info_editor_source()
	return PersonalInfoSource.read(ManifestMenu)
end

--- Whether any hotstring can expand: a category gate open, or the dynamic
--- hotstrings (dates, @-tags) on. The state the Hotstrings switch and its
--- parent row show on this driver, where the master is that set of gates
--- rather than a flag of its own. It used to be « every category on », so the
--- wizard's recommendation, which opens one category, showed the switch
--- unticked while ★ expanded, and a click switched every category on.
--- @param ctx table Menu context: config, dyn_hotstrings.
--- @return boolean
local function _hotstrings_on(ctx)
	local config = ctx.config
	if type(config.any_enabled) == "function" and config.any_enabled() then return true end
	local dyn = ctx.dyn_hotstrings
	return type(dyn) == "table" and type(dyn.is_enabled) == "function" and dyn.is_enabled() == true
end

--- Restores or clears the Hotstrings scope at once. Neither asks: the scope
--- owner's verified backups are the way back (the maintainer retired the
--- clear's question on 2026-09-30).
---
--- The one transaction that writes the manifest's recommended values after
--- verified backups. Deleting the explicit choices instead yields the neutral
--- state, where every catalogue is off: the opposite of the restore's label.
--- @param ctx table Menu context: paused, is_paused, dyn_hotstrings, tooltip_preview, on_menu_changed.
--- @param mode string "recommended" or "clear".
--- @return boolean committed
local function _apply_hotstrings_scope(ctx, mode)
	if ctx.paused == true or type(ctx.is_paused) ~= "function" or ctx.is_paused() then return false end
	local committed = require("infra.hotstrings_scope").apply(mode, ctx.is_paused,
		{ dynamic = ctx.dyn_hotstrings, preview = ctx.tooltip_preview })
	if committed == true and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
	return committed
end

--- Renders the rows of the hotstrings submenu that the manifest describes.
---
--- Defined BEFORE its caller: a `local function` is not hoisted
--- (project-lua-closure-before-local-nil-global).
---
--- THE GROUP CLASSIFICATION COMES FROM THE MANIFEST, and it spells the group ids
--- with underscores (`distances_reduction`) while the shared hotstring index
--- spells them without (`distancesreduction`). macOS reconciles the two by
--- comparing both forms; this does the same rather than inventing a third
--- answer. One vocabulary would be better and neither driver owns that decision.
--- @param ctx table Menu context; ctx.webview opens the settings window.
--- @param config table The hotstrings config module.
--- @return table Menu rows, empty when the renderer could not be bound.
--- Admits the whole canonical quick-delay caption map without native fallback.
--- @param root table The current published menu manifest.
--- @return table|nil Captions; unknown fields or malformed data refuse the frame.
local function parameter_delay_captions(root)
	local captions = type(root) == "table" and rawget(root, "hotstrings_delay_captions") or nil
	local keys = { default = true, magic_key = true, autocorrection = true,
		ai_acceptance = true, autocompletion = true }
	if type(captions) ~= "table" or getmetatable(captions) ~= nil then return nil end
	local count = 0
	for key, value in next, captions do
		if keys[key] ~= true or type(value) ~= "string" or value == "" then return nil end
		count = count + 1
	end
	if count ~= 5 then return nil end
	return captions
end




-- The frame snapshot and its currency check are one body shared by both drivers.
local function magic_frame_snapshot(renderer, key, expected)
	return MagicFrame.snapshot(renderer, key, expected)
end

local function magic_frame_current(renderer, snapshot)
	return MagicFrame.current(renderer, snapshot)
end

local function _manifest_hotstring_rows(ctx, config)
	if not ManifestMenu then
		Logger.warn(LOG, "Manifest renderer unavailable — the hotstrings submenu loses its declared rows.")
		return {}
	end

	local root    = ManifestMenu.get_root() or {}
	local captions = parameter_delay_captions(root)
	local boundaries = ManifestMenu.template_rows("hotstrings_parameter_boundary", {}, {}, {})
	local classes = type(root.hotstring_groups) == "table" and root.hotstring_groups or {}
	local groups  = type(config.get_groups) == "function" and (config.get_groups() or {}) or {}

	--- The group ids of one manifest class, in both spellings.
	--- @param class string "standard", "dynamic" or "ergopti".
	--- @return table Set of accepted ids.
	local function members_of(class)
		local set = {}
		for _, id in ipairs(classes[class] or {}) do
			set[id] = true
			local flattened = id:gsub("_", "")
			if flattened ~= id then set[flattened] = true end
		end
		return set
	end

	--- The name to show for a category, in the user's language.
	---
	--- The packs carry a description in 21 locales and the menu used to print the
	--- file stem, in every language: "distancesreduction" rather than "Réduction
	--- des distances". English is the fallback because it is the reference locale
	--- the others are checked against, and the stem is the last resort.
	--- @param id string Category id.
	--- @param category table|nil Category metadata from the loader.
	--- @return string
	local function category_label(id, category)
		if PersonalFiles.components(id) and category and PersonalFiles.is_descriptor(category.personal_source) then
			local descriptor = category.personal_source
			return descriptor.label ~= "" and descriptor.label or descriptor.components[#descriptor.components]
		end
		local description = category and category.description or nil
		-- A pack whose [_meta] description is a plain string, not a locale table —
		-- which is what the editor writes for personal.toml — used to fall straight
		-- through to the file stem, so the user's own hotstrings appeared as
		-- "personal (12)" while the other two drivers show "Hotstrings personnels".
		-- The category.* keys exist in all 21 locales for exactly this.
		if type(description) ~= "table" then
			local translated = i18n_safe("category." .. id)
			if translated ~= "category." .. id then return translated end
			return id
		end
		local locale = "en"
		local ok_i18n, i18n_mod = pcall(require, "infra.i18n")
		if ok_i18n and type(i18n_mod.get_locale) == "function" then
			local current = i18n_mod.get_locale()
			if type(current) == "string" and current ~= "" then locale = current end
		end
		return description[locale] or description.en or id
	end

	--- The display name of an installed extension.
	---
	--- The loader stapled the extension's manifest name onto every category it
	--- produced, so the name is read back from any one of its packs rather than by
	--- rescanning the disk from the menu — a menu build must not do file I/O, and
	--- the tray rebuilds this on every toggle.
	--- @param extension_id string The id parsed out of a namespaced category key.
	--- @return string
	local function extension_label(extension_id)
		for _, name in ipairs(groups) do
			local id = Extensions.parse_category_key(name)
			if id == extension_id then
				local category = type(config.get_category) == "function" and config.get_category(name) or nil
				local extension = category and category.extension or nil
				if type(extension) == "table" and type(extension.name) == "string" and extension.name ~= "" then
					return extension.name
				end
			end
		end
		return extension_id
	end

	--- How many hotstrings a category is firing right now.
	---
	--- Asked of the config module, which owns the gate and section state; the
	--- fallback is only for a harness that supplies a partial config table, and it
	--- is the honest one — the total the file holds, which is what this row showed
	--- unconditionally before.
	--- @param id string
	--- @param category table|nil
	--- @return integer
	local function active_count(id, category)
		if type(config.active_count) == "function" then return config.active_count(id) end
		return (category and category.count) or 0
	end

	--- Whether every listed category's gate is open and every one of its sections
	--- is ticked: the state an « all sections » checkbox shows. A list with no
	--- category is not « all on », since there is nothing the checkbox could have
	--- switched on.
	--- @param ids table Array of category ids.
	--- @return boolean
	local function sections_all_on(ids)
		-- The same per-section question the section rows below ask: what the user
		-- ticked, not what the closed gate makes effective.
		local section_on = config.is_section_checked or config.is_section_enabled
		if #ids == 0 or type(config.is_group_enabled) ~= "function" or type(section_on) ~= "function" then
			return false
		end
		for _, id in ipairs(ids) do
			if not config.is_group_enabled(id) then return false end
			local category = type(config.get_category) == "function" and config.get_category(id) or nil
			for name in pairs(category and category.sections or {}) do
				if not section_on(id, name) then return false end
			end
		end
		return true
	end

	--- One checkbox for every section of `ids`, where a « tout activer » / « tout
	--- désactiver » pair used to be: two rows and two keys for one control, whose
	--- state the user could only guess. Ticked when all of them are on; a click
	--- switches them all to the other side in one write, and enabling lifts each
	--- gate (config.set_categories_sections does it).
	--- @param ids table Array of category ids.
	--- @return table Provider row.
	local function all_sections_row(ids)
		local all_on = sections_all_on(ids)
		local action = function()
			local called, committed = false, false
			if type(config.set_categories_sections) == "function" then
				called, committed = pcall(config.set_categories_sections, ids, not all_on)
			end
			if called and committed == true then return true end
			Logger.error(LOG, "The aggregate hotstrings switch did not acknowledge durable publication.")
			show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
			return false
		end
		return ManifestMenu.check_row("hotstring_scope_checkbox", require("config_keys").COMMAND.HOTSTRING_SCOPE_ALL_SECTIONS,
			{ hotstring_scope_all_sections = action },
			{ hotstring_scope_all_on = function() return all_on end })
	end

	--- One category, as a submenu rather than a single toggle.
	---
	--- This is where roughly four fifths of the rows the other two drivers show
	--- come from, and Linux had none of them: a category was one line reading its
	--- own file stem with a tick, and its sections, its counts and its file were
	--- unreachable. Everything below comes from the loader's catalogue, which is
	--- the same parse the engine already did.
	--- @param id string Category id.
	--- @return table
	local function category_submenu(id)
		local category = (type(config.get_category) == "function") and config.get_category(id) or nil
		local on = config.is_group_enabled and config.is_group_enabled(id)
		local count = category and category.count or 0
		local personal = PersonalFiles.components(id) ~= nil
		local binding = personal and type(config.personal_file_scope_binding) == "function"
			and config.personal_file_scope_binding(id) or nil
		local function current_source()
			return not personal or type(binding) == "table" and type(binding.current) == "function"
				and binding.current() == true
		end

		local sub = {}

		local sections = category and category.sections_order or {}
		if #sections > 0 then

			for _, name in ipairs(sections) do
				local section = (category.sections or {})[name]
				-- A section an extension binds is drawn in that extension's submenu.
				if section and section.extension then goto continue_section end
				-- CHECKED, not ENABLED. The two are different questions and answering
				-- both with the effective state made a switched-off category untick
				-- every section it holds — so the information "here is what comes back
				-- when you switch it on" disappeared, and it looked as though the
				-- per-section choices had been reset. They never were; only the screen
				-- said so.
				local section_checked = config.is_section_checked
					and config.is_section_checked(id, name)
					or (config.is_section_enabled and config.is_section_enabled(id, name))
				sub[#sub + 1] = {
					-- The count is the point of the row: a section with three entries
					-- and one with nine hundred are the same line without it.
					label    = string.format("%s (%d)", name, section and section.count or 0),
					checked  = section_checked and true or false,
					-- Greyed rather than hidden while the category is off: a row that
					-- disappears reads as a bug, and the user still needs to see what
					-- they will get back when they switch the category on.
					disabled = not on,
					action = function()
						local called, committed = pcall(function()
							if not current_source() then return false end
							if type(config.toggle_section) ~= "function" then return false end
							return config.toggle_section(id, name)
						end)
						if called and committed == true then
							require("ui.menu.feature_notice").feature(name, config.is_section_checked and config.is_section_checked(id, name)
								or (config.is_section_enabled and config.is_section_enabled(id, name)) or false)
							return true
						end
						Logger.error(LOG, "Hotstring section toggle refused for '%s.%s' (%s).", id, name,
							called and "owner-not-committed" or "owner-error")
						show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
						return false
					end,
				}
				::continue_section::
			end
		end

		local function commit_scope(enabled)
			local called, committed = pcall(function()
				if not current_source() then return false end
				return config.set_category_scope_enabled({ id }, enabled)
			end)
			if called and committed == true then
				require("ui.menu.feature_notice").feature(category_label(id, category), enabled)
				return true
			end
			Logger.error(LOG, "Hotstring category scope refused for '%s' (%s).", id,
				called and "owner-not-committed" or "owner-error")
			show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
			return false
		end
		local render_ctx = { commands = {
			[require("config_keys").COMMAND.HOTSTRING_CATEGORY_ENABLE_ALL] = function()
				return commit_scope(true)
			end,
			[require("config_keys").COMMAND.HOTSTRING_CATEGORY_DISABLE_ALL] = function()
				return commit_scope(false)
			end,
		} }
		local rendered = ManifestMenu.build("hotstring_category_menu", "Hotstrings", nil, nil,
			render_ctx, {
				["hotstring_category_file"] = function()
					if not category or not category.path then return {} end
					local source = category.path
					local row = ManifestMenu.command_row("hotstring_file_commands", require("config_keys").COMMAND.HOTSTRING_FILE_OPEN,
						{ hotstring_file_open = function() return ctx.on_open_file(source) end },
						{ hotstring_file_ready = function() return type(ctx.on_open_file) == "function" end })
					return row and { row } or {}
				end,
				["hotstring_category_sections"] = function() return sub end,
			})
		if personal then
			local controls = type(config.personal_metadata_controls) == "function" and config.personal_metadata_controls(id) or nil
			local rows = PersonalFileMenu.build({ manifest = ManifestMenu, current = current_source,
				enabled = function() return type(config.is_group_enabled) == "function" and config.is_group_enabled(id) == true end,
				available = function(field) return controls ~= nil and controls.file[field] ~= true end,
				enable = function(enabled)
					local committed = (enabled and config.enable_group or config.disable_group)(id) == true
					if committed then require("ui.menu.feature_notice").feature(category_label(id, category), enabled) end
					return committed
				end,
				tooltip_enabled = function() return type(config.resolve) == "function" and config.resolve(id, nil).show_tooltip == true end,
				tooltip = function(value) return config.set_personal_metadata(id, nil, "show_tooltip", value) == true end,
				edit = function() return ctx.webview ~= nil and type(ctx.webview.show) == "function"
					and ctx.webview.show(require("config_keys").COMMAND.HOTSTRINGS_CONFIG_WINDOW) == true end,
				metadata_reason = function() return i18n_safe("menu.hotstrings.personal_metadata_unavailable") end,
				changed = function() if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end end,
			})
			for index = #rows, 1, -1 do table.insert(rendered, 1, rows[index]) end
		end
		if personal then
			PersonalFileMenu.apply_category_admission(rendered, {
				manifest = ManifestMenu, translate = i18n_safe, current = current_source,
			})
		end

		return {
			-- The ACTIVE count, not the file's total. A user reads this figure as
			-- "what is firing right now" and checks a disable by watching it fall;
			-- it never moved, so a fully disabled Autocorrection went on advertising
			-- every entry it would have had.
			label   = string.format("%s (%d)", category_label(id, category), active_count(id, category))
				.. (personal and not current_source() and (" — " .. i18n_safe("menu.hotstrings.personal_source_unavailable")) or ""),
			checked = on and true or false,
			submenu = rendered,
		}
	end

	--- Kept as the name the callers below already use.
	--- @param name string Category id.
	--- @return table
	local function group_row(name)
		return category_submenu(name)
	end

	--- Appends every loaded group belonging to `class`.
	--- @param items table
	--- @param class string
	local function append_class(items, class)
		local want  = members_of(class)
		local added = 0
		for _, name in ipairs(groups) do
			if want[name] then
				items[#items + 1] = group_row(name)
				added = added + 1
			end
		end
		if added == 0 then
			if type(ManifestMenu.status_rows) ~= "function" then return end
			local status = ManifestMenu.status_rows("hotstrings_menu", "hotstring_categories_standard", "no_groups")
			for _, row in ipairs(type(status) == "table" and status or {}) do
				items[#items + 1] = row
			end
		end
	end

	-- "Personal" is defined by exclusion: whatever the user loaded that the
	-- manifest does not classify. Listing it any other way would need a second
	-- classification to keep in step with the first.
	local classified = {}
	for _, class in ipairs({ "standard", "dynamic", "ergopti" }) do
		for id in pairs(members_of(class)) do classified[id] = true end
	end
	-- Language-pack groups are classified by the shared index, not the manifest's
	-- group classes: they render under their language's own submenu.
	local language_packs = type(config.language_packs) == "function" and config.language_packs() or {}
	for id in pairs(Languages.groups(language_packs)) do classified[id] = true end

	--- One row per language: its native name, one « all sections » checkbox for
	--- all of its categories, then each category's submenu.
	--- @return table
	local function language_rows()
		local rows = {}
		for _, pack in ipairs(language_packs) do
			local ids = {}
			for _, stem in ipairs(pack.categories) do ids[#ids + 1] = Languages.group_id(pack.id, stem) end
			local switch, categories = all_sections_row(ids), {}
			local total = 0
			for _, id in ipairs(ids) do
				local category = type(config.get_category) == "function" and config.get_category(id) or nil
				if category then
					categories[#categories + 1] = group_row(id)
					total = total + active_count(id, category)
				end
			end
			local items = switch and ManifestMenu.template_rows("hotstring_language_frame", {}, {}, {
				hotstring_language_switch = function() return { switch } end,
				hotstring_language_categories = function() return categories end,
			})
			if items then
				local parents = ManifestMenu.template_rows("hotstring_language_parent_lua", {}, {
					hotstring_language_name = function() return language_label(pack.locale) end,
					hotstring_language_count = function() return string.format("%d", total) end,
				}, { hotstring_language_children = items })
				for _, row in ipairs(parents or {}) do rows[#rows + 1] = row end
			end
		end
		return rows
	end

	--- Renders a delay for a menu label: "750 ms", or the infinity sign for 0.
	---
	--- Zero does not mean "fire instantly" — it means the trigger never expires,
	--- so the category stays armed however long the user pauses. Printing "0 ms"
	--- would read as the exact opposite of what it does.
	--- @param seconds number
	--- @return string
	local function delay_display(seconds)
		local ms = math.floor(seconds * MS_PER_SEC + 0.5)
		if ms == 0 then return i18n_safe("menu.hotstrings.infinite") end
		return ms .. " ms"
	end

	--- Asks for a delay in milliseconds and returns it in seconds.
	--- @param title string Already-translated dialog title.
	--- @param current_sec number
	--- @return number|nil Seconds, or nil when cancelled or refused.
	local function prompt_delay(title, current_sec)
		local raw = prompt_text(
			title,
			i18n_safe("menu.hotstrings.delay_prompt"),
			tostring(math.floor(current_sec * MS_PER_SEC + 0.5)))
		if raw == nil then return nil end

		local value = tonumber((raw:gsub("%s", "")))
		-- Refused rather than clamped: a negative or fractional millisecond is a
		-- typo, and silently rounding it would store a number the user never chose
		-- and cannot see is different from what they typed.
		if not value or value < 0 or value ~= math.floor(value) then
			show_error(i18n_safe("menu.hotstrings.delay_invalid_body"))
			return nil
		end
		return value / MS_PER_SEC
	end

	--- Contains the existing durable delay owner's receipt before repainting.
	--- @param setter function|nil
	--- @return boolean committed
	local function commit_delay(setter, ...)
		local ok, committed = false, false
		if type(setter) == "function" then ok, committed = pcall(setter, ...) end
		if not ok or committed ~= true then
			Logger.error(LOG, "The hotstring delay owner refused publication.")
			show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
			return false
		end
		if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		return true
	end

	--- The row for the base expansion delay (`hotstrings.expansion_delay`) — the
	--- one every category inherits when neither it nor its sections declare one,
	--- and that the delay overrides are offsets of.
	--- @return table
	local function global_delay_row()
		local current = config.get_base_delay and config.get_base_delay() or nil
		if type(current) ~= "number" then
			Logger.error(LOG, "hotstrings_config exposes no base delay — the row cannot show a value.")
			return {
				label    = i18n_safe(captions.default) .. " : " .. i18n_safe("menu.hotstrings.missing_value"),
				disabled = true,
			}
		end

		local overridden = config.has_base_delay_override and config.has_base_delay_override() or false
		local title = i18n_safe(captions.default)
		return {
			-- menu.settings.default_indicator carries its own leading space.
			label = title .. " : " .. delay_display(current)
				.. (overridden and "" or i18n_safe("menu.settings.default_indicator")),
			action = function()
				local chosen = prompt_delay(title, current)
				if chosen == nil then return end
				return commit_delay(config.set_base_delay, chosen)
			end,
		}
	end

	--- The row for one category's default delay.
	---
	--- Reads the EFFECTIVE value through resolve() so the number matches what the
	--- settings window shows and what the engine actually applies, and writes
	--- through set_override() so both UIs share one store.
	--- @param category string
	--- @param label_key string
	--- @return table
	local function category_delay_row(category, label_key)
		local title = i18n_safe(label_key)
		local ok, resolved = pcall(config.resolve, category, nil)
		local current = ok and type(resolved) == "table" and tonumber(resolved.delay) or nil
		if type(current) ~= "number" then
			Logger.error(LOG, "No resolvable delay for category '%s' — its row shows no value.", tostring(category))
			return {
				label    = title .. " : " .. i18n_safe("menu.hotstrings.missing_value"),
				disabled = true,
			}
		end

		local overridden = resolved.has_override == true
		return {
			label = title .. " : " .. delay_display(current)
				.. (overridden and "" or i18n_safe("menu.settings.default_indicator")),
			action = function()
				local chosen = prompt_delay(title, current)
				if chosen == nil then return end
				return commit_delay(config.set_override, category, nil, "delay", chosen)
			end,
		}
	end

	local ok_term, Terminators = pcall(require, "keymap.terminators")
	if not ok_term then Terminators = nil end

	local params_handlers = {
		["word_expanders"] = function()
			if not boundaries then return {} end
			if not Terminators then
				Logger.error(LOG, "keymap.terminators unavailable — the word-delimiter submenu is skipped.")
				return {}
			end

			local function word_expanders_ready()
				return ctx.paused ~= true and not (type(ctx.is_paused) == "function" and ctx.is_paused())
			end

			--- Captures enough catalogue state to undo a persistence failure.
			--- @return table
			local function snapshot()
				local saved = { enabled = {}, custom = {} }
				for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
					if def.key then
						saved.enabled[def.key] = Terminators.is_terminator_enabled(def.key)
						if def.custom then
							saved.custom[#saved.custom + 1] = {
								key = def.key,
								char = type(def.chars) == "table" and def.chars[1] or nil,
								label = def.label,
								consume = def.consume == true,
							}
						end
					end
				end
				return saved
			end

			--- Restores a snapshot after the durable write was refused.
			--- @param saved table
			local function restore(saved)
				local custom_keys = {}
				for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
					if def.key and def.custom then custom_keys[#custom_keys + 1] = def.key end
				end
				for _, key in ipairs(custom_keys) do Terminators.remove_custom_terminator(key) end
				for _, def in ipairs(saved.custom) do
					Terminators.add_custom_terminator(def.key, def.char, def.label, def.consume)
				end
				Terminators.set_terminators_enabled(saved.enabled)
			end

			--- Persists a mutation, rebuilding the menu only after durable success.
			--- @param saved table State from before the mutation.
			--- @return boolean
			local function commit(saved)
				local persisted = false
				if type(ctx.on_persist_terminators) == "function" then
					local called, result = pcall(ctx.on_persist_terminators)
					persisted = called and result == true
				end
				if not persisted then
					restore(saved)
					Logger.error(LOG, "Word-delimiter change was rolled back because persistence failed.")
					return false
				end
				if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				return true
			end

			--- The CATALOGUE delimiter keys — the user's own are excluded.
			---
			--- This used to include custom ones, and its comment said so as if it
			--- were a decision. Both reference drivers skip them deliberately: a
			--- delimiter the user added by hand must not be wiped by a bulk action
			--- aimed at the shipped set.
			--- @return table Array of key strings.
			local function all_keys()
				local keys = {}
				for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
					if def.key and not def.custom then keys[#keys + 1] = def.key end
				end
				return keys
			end

			--- Sets every catalogue delimiter at once.
			--- @param on boolean
			--- @return function
			local function set_all(on)
				return function()
					if not word_expanders_ready() then return false end
					local saved = snapshot()
					local changes = {}
					for _, key in ipairs(all_keys()) do
						changes[key] = on
					end
					if Terminators.set_terminators_enabled(changes) ~= true then return false end
					return commit(saved)
				end
			end

			local sub = {}

			local function reset_terminators()
				if not word_expanders_ready() then return false end
				local saved = snapshot()
				local changes, consumption = {}, {}
				for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
					if def.key and not def.custom then
						changes[def.key] = def.default_enabled ~= false
						consumption[def.key] = def.consume == true
					end
				end
				if Terminators.set_terminators_enabled(changes) ~= true then return false end
				-- The consumed choice of every built-in goes back to the catalogue too.
				if Terminators.set_terminators_consume(consumption) ~= true then return false end
				return commit(saved)
			end

			-- Whether an expansion swallows each built-in delimiter: a click on its
			-- catalogue row switches it on or off, so this half has its own rows.
			local consume_rows = {}
			for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
				if def.key and not def.custom and def.type ~= "separator" then
					local key = def.key
					local label = i18n_safe(def.label_key):gsub("★", MagicKey.get())
					consume_rows[#consume_rows + 1] = {
						label   = label,
						checked = Terminators.is_terminator_consume(key) and true or false,
						action  = function()
							if not word_expanders_ready() then return false end
							local saved = snapshot()
							local next_consume = not Terminators.is_terminator_consume(key)
							if Terminators.set_terminators_consume({ [key] = next_consume }) ~= true or not commit(saved) then
								return false
							end
							require("ui.menu.feature_notice").feature(string.format(i18n_safe("notify.word_expander_prefix"),
								label .. " " .. i18n_safe("menu.hotstrings.consumed_suffix")), next_consume)
							return true
						end,
					}
				end
			end

			for _, def in ipairs(Terminators.get_terminator_defs() or {}) do
				if def.type == "separator" then
					for _, boundary in ipairs(boundaries) do sub[#sub + 1] = boundary end
				elseif def.key then
					local key = def.key
					-- A built-in slot carries a locale key, never display text, so the
					-- row follows the active language; only a custom slot carries the
					-- literal label its user typed.
					local text = def.custom and def.label or i18n_safe(def.label_key)
					-- The live magic key, not the ★ the catalogue was written with.
					-- The label is shipped as a literal star; a user who changed the
					-- key saw the delimiter list still naming a character that is no
					-- longer their trigger, in every language.
					local label = text:gsub("★", MagicKey.get())
					-- A consumed delimiter is swallowed by the expansion; an unconsumed
					-- one is typed after it. The difference is visible only in the
					-- output, so the row has to say which it is — a space that vanishes
					-- and a space that stays look like a bug either way round.
					local first_char = type(def.chars) == "table" and def.chars[1] or nil
					if first_char and Terminators.terminator_is_consumed
						and Terminators.terminator_is_consumed(first_char) then
						label = label .. " " .. i18n_safe("menu.hotstrings.consumed_suffix")
					end
					sub[#sub + 1] = {
						label   = label,
						checked = Terminators.is_terminator_enabled(key) and true or false,
						action      = function()
							local saved = snapshot()
							if Terminators.set_terminator_enabled(key,
								not Terminators.is_terminator_enabled(key)) and commit(saved) then
								require("ui.menu.feature_notice").feature(string.format(i18n_safe("notify.word_expander_prefix"), label),
									Terminators.is_terminator_enabled(key))
							end
						end,
					}
					if def.custom then
						local delete_row = ManifestMenu.command_row("word_expander_custom_menu", require("config_keys").COMMAND.WORD_EXPANDER_DELETE, {
							[require("config_keys").COMMAND.WORD_EXPANDER_DELETE] = function()
								local saved = snapshot()
								if Terminators.remove_custom_terminator(key) ~= true then return false end
								return commit(saved) == true
							end,
						}, { ["word_expanders_ready"] = word_expanders_ready })
						if delete_row then sub[#sub + 1] = delete_row end
					end
				end
			end

			local catalogue_rows = sub
			sub = {}
			local add_row = ManifestMenu.command_row("word_expander_custom_menu", require("config_keys").COMMAND.WORD_EXPANDER_ADD, {
				[require("config_keys").COMMAND.WORD_EXPANDER_ADD] = function()
					local char = prompt_text(
						i18n_safe("dialog.hotstrings.new_delimiter_title"),
						i18n_safe("dialog.hotstrings.new_delimiter_prompt"),
						"")
					if not word_expanders_ready() then return false end
					if char == nil then return false end

					-- Codepoints, not bytes: "…" is three bytes and one character, so
					-- a byte-length check would refuse most of what a user would pick.
					local codepoints = 0
					for _ in char:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
						codepoints = codepoints + 1
					end
					if codepoints ~= 1 then
						show_error(i18n_safe("dialog.magic_key.error_length"))
						return false
					end

					local consume = ask_yes_no(
						i18n_safe("dialog.hotstrings.consume_title"),
						i18n_safe("dialog.hotstrings.consume_body"),
						i18n_safe("dialog.hotstrings.consume_yes"),
						i18n_safe("dialog.hotstrings.consume_no"))
					-- nil is "nobody could be asked", which must not be stored as a No.
					if not word_expanders_ready() then return false end
					if consume == nil then return false end

					local saved = snapshot()
					if Terminators.add_custom_terminator("custom_" .. char, char, char, consume) ~= true then return false end
					return commit(saved) == true
				end,
			}, { ["word_expanders_ready"] = word_expanders_ready })
			if add_row then sub[#sub + 1] = add_row end

			local exp_ctx = {
				commands = {
					[require("config_keys").COMMAND.WORD_EXPANDERS_ENABLE_ALL] = set_all(true),
					[require("config_keys").COMMAND.WORD_EXPANDERS_DISABLE_ALL] = set_all(false),
					[require("config_keys").COMMAND.WORD_EXPANDERS_RESTORE] = reset_terminators,
				},
				state_getters = { ["word_expanders_ready"] = word_expanders_ready },
			}
			local entries = ManifestMenu.template_rows("hotstrings_word_expander_frame", {}, {}, {
				["parameter_catalogue_entries"] = function() return catalogue_rows end,
				["parameter_consume_children"] = consume_rows,
				["parameter_custom_entries"] = function() return sub end,
			})
			if not entries then return {} end
			local rendered_expanders = ManifestMenu.build("word_expanders_menu", "HotstringsParams", nil, nil,
				exp_ctx, { ["word_expander_entries"] = function() return entries end })
			local children = ManifestMenu.native_child_rows(rendered_expanders)
			if not children then return {} end
			return ManifestMenu.template_rows("hotstrings_word_expander_parent", {},
				{ ["parameter_parent_ready"] = function() return true end },
				{ ["parameter_word_expander_children"] = children }) or {}
		end,
		["magic_key_config"] = function()
			local source = magic_frame_snapshot(ManifestMenu)
			if not source then return {} end
			local current = MagicKey.get()
			local customised = MagicKey.is_customised()
			local change = function()
					local chosen = prompt_text(
						i18n_safe("dialog.magic_key.title"),
						i18n_safe("dialog.magic_key.prompt"),
						current)
					-- nil is a cancelled dialog, which must change nothing. An empty
					-- string is a user who cleared the box and pressed OK, and that is
					-- refused by validate() with its own message rather than silently
					-- treated as a cancel.
					if chosen == nil then return end
					local ok, reason = MagicKey.set(chosen)
					if not ok then
						show_error(i18n_safe(reason or "dialog.magic_key.error_empty"))
						return
					end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end
			local reset = function()
						MagicKey.reset()
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end
			local rows = ManifestMenu.template_rows("hotstrings_magic_trigger_frame", { magic_key_change = change, magic_key_reset = reset },
				{ magic_key_value = function() return current end }, { magic_key_reset_if_custom = function()
					if not customised then return {} end
					local reset_source = magic_frame_snapshot(ManifestMenu, "hotstrings_magic_trigger_reset", 1)
					if not reset_source then return nil end
					local reset_rows = ManifestMenu.template_rows("hotstrings_magic_trigger_reset", { magic_key_reset = reset }, {}, {})
					if not reset_rows or not magic_frame_current(ManifestMenu, reset_source) then return nil end
					return reset_rows
				end })
			if not rows or not magic_frame_current(ManifestMenu, source) then return {} end
			return rows
		end,
		["delays_colors"] = function()
			-- A submenu, not the single row this used to be. The old row opened the
			-- settings window and stopped there, justified by a comment saying "this
			-- driver has no per-category delays to prompt for" — which was false when
			-- it was written: hotstrings_config.resolve() walks the same five-rung
			-- cascade as macOS, set_override() persists to the same file, and
			-- ergopti_hotstrings.lua consumes the resolved delay on every keystroke.
			-- The values were all there; only the prompts were missing.
			if not captions then return {} end

			local settings_row = ManifestMenu.command_row("hotstrings_delays_menu", require("config_keys").COMMAND.HOTSTRINGS_CONFIG_WINDOW, {
				hotstrings_config_window = function()
					if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
						Logger.error(LOG, "No webview manager in the menu context — cannot open the hotstrings settings.")
						return
					end
					-- The directory name under _shared/ui/. "hotstrings_config" has a
					-- bridge but no page, so this row opened a window reading
					-- "Error: app 'hotstrings_config' not found" — the settings window
					-- this whole submenu points at had never once opened on Linux.
					ctx.webview.show(require("config_keys").COMMAND.HOTSTRINGS_CONFIG_WINDOW)
				end,
			}, { hotstrings_config_ready = function() return true end })
			local sub = ManifestMenu.template_rows("hotstrings_delays_frame", {}, {}, {
				["parameter_delay_config"] = function() return settings_row and { settings_row } or {} end,
				["parameter_delay_default"] = function() return { global_delay_row() } end,
				["parameter_delay_magic_key"] = function() return { category_delay_row("magickey", captions.magic_key) } end,
				["parameter_delay_autocorrection"] = function() return { category_delay_row("autocorrection", captions.autocorrection) } end,
			})
			if not sub then return {} end
			return ManifestMenu.template_rows("hotstrings_delays_parent", {},
				{ ["parameter_parent_ready"] = function() return true end }, { ["parameter_delays_children"] = sub }) or {}
		end,
	}

	local personal_choices_admitted = true
	local providers = {
		["hotstring_categories_standard"] = function()
			local rows = {}
			append_class(rows, "standard")
			return rows
		end,
		["hotstring_categories_dynamic"] = function()
			local rows = {}
			-- Its own handler, not append_class. This driver's group list comes from
			-- TOML file stems and there is no dynamic-hotstrings TOML — the rules are
			-- registered in code — so append_class matched nothing and the row
			-- resolved to a greyed "(aucun groupe chargé)" while the engine was
			-- running and expanding dates and @-tags. A user could not see the
			-- category, count it, or switch it off.
			local dyn = ctx.dyn_hotstrings
			if type(dyn) ~= "table" or type(dyn.is_enabled) ~= "function" then
				Logger.error(LOG, "No dynamic-hotstrings manager in the menu context — its category is not shown.")
				return rows
			end

			local on = dyn.is_enabled()
			-- active_count, not get_rules_count: the latter counts the RULES the
			-- dynamic engine registered and knows nothing about the prefix
			-- expansions, which are mappings held by the ordinary matcher. The
			-- category would have advertised 3 while offering 13, and would not have
			-- moved when a family was switched off.
			local count = type(dyn.active_count) == "function" and dyn.active_count() or 0
			if on and type(dyn.user_code_is_enabled) == "function" and dyn.user_code_is_enabled() then
				count = count + dyn.user_code_count()
			end

			local sub = {}
			local current, template = personal_info_editor_source()
			if current then
				local editor = template("personal_info_editor_frame", {
					personal_info_editor_open = function()
						if not current() then return false end
						if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
							Logger.error(LOG, "Personal-info editor cannot open: webview manager is unavailable.")
							return
						end
						ctx.webview.show("personal_info_editor")
					end,
				}, {}, {})
				local valid = current() and type(editor) == "table" and getmetatable(editor) == nil
				if valid then for index in next, editor do if index ~= 1 then valid = false end end end
				local row = valid and rawget(editor, 1) or nil
				valid = type(row) == "table" and getmetatable(row) == nil
					and type(rawget(row, "label")) == "string" and rawget(row, "label") ~= ""
					and type(rawget(row, "action")) == "function" and rawget(row, "disabled") == nil
				if valid then for key in next, row do if key ~= "label" and key ~= "action" then valid = false end end end
				if valid then sub[1] = row end
			end

			-- One row per rule family, as Windows and macOS offer. The plan recorded
			-- this as blocked by the shared engine "registering the date rules as a
			-- batch with no identifier". That was wrong: add_rule has always carried
			-- a section, and match_buffer has always taken a predicate to filter on
			-- it. This driver simply passed nil for it.
			local families = type(dyn.rule_families) == "function" and dyn.rule_families() or {}
			if #families > 0 then
				-- The existing shared boundary is the only admitted inert entry.
				if type(boundaries) ~= "table" or getmetatable(boundaries) ~= nil or #boundaries ~= 1
					or type(boundaries[1]) ~= "table" or getmetatable(boundaries[1]) ~= nil
					or boundaries[1].separator ~= true then
					Logger.error(LOG, "Declared dynamic hotstring section boundary unavailable.")
					return rows
				end
				for index in next, boundaries do if index ~= 1 then return rows end end
				for key in next, boundaries[1] do if key ~= "separator" then return rows end end
				sub[#sub + 1] = boundaries[1]

				for _, family in ipairs(families) do
					if family.separator then
						sub[#sub + 1] = boundaries[1]
					else
						local section, enabled, family_id = family.section, family.enabled, family.id
						-- The count, on the families that have one. A prefix family with
						-- 0 behind it is a switch that can do nothing until the user
						-- fills in that field of personal_info.toml, and the count is
						-- the only thing on the row that says so.
						local family_label = family.count
							and string.format("%s (%d)", family.label, family.count)
							or family.label
						sub[#sub + 1] = {
							-- Resolved by the manager, which owns both the locale key
							-- and the engine that answers what "{date}" is today.
							label    = family_label,
							checked  = enabled,
							-- Greyed while the category itself is off, like a section
							-- row: the tick still says what comes back when it is
							-- switched on.
							disabled = not on,
							action       = function()
								local current_family
								local called, committed = pcall(function()
									local current = ctx.dyn_hotstrings
									if current ~= dyn or type(current.is_enabled) ~= "function"
										or type(current.rule_families) ~= "function"
										or type(current.is_rule_enabled) ~= "function"
										or type(current.set_rule_enabled) ~= "function" then return false end
									local declared = 0
									for _, entry in ipairs(ManifestMenu.get_dynamic_hotstring_families()) do
										if entry.id == family_id and (entry.linux_section or entry.section) == section then
											declared = declared + 1
										end
									end
									if declared ~= 1 then return false end
									for _, entry in ipairs(current.rule_families()) do
										if entry.id == family_id and entry.section == section then
											if current_family ~= nil then return false end
											current_family = entry
										end
									end
									if type(current_family) ~= "table" or type(current_family.enabled) ~= "boolean"
										or current.is_enabled() ~= true then return false end
									local live_enabled = current.is_rule_enabled(nil, section)
									if type(live_enabled) ~= "boolean" or live_enabled ~= current_family.enabled
										or ctx.dyn_hotstrings ~= current then return false end
									return current.set_rule_enabled(section, not live_enabled)
								end)
								if not called or committed ~= true then
									Logger.error(LOG, "Dynamic hotstring family refused (%s).", called and "owner-not-committed" or "owner-error")
									show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
									return false
								end
								-- A prefix family is matched by the ORDINARY engine, which
								-- knows nothing about dynamic families — so its switch has
								-- to add or remove mappings rather than filter them, and
								-- that means a reload. The date families need none of this;
								-- their guard is read at match time.
								-- The preference receipt above does not acknowledge this
								-- separate catalogue reload or invent its compensation.
								if current_family.count and config and type(config.reload) == "function" then
									config.reload()
								end
								if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
								return true
							end,
						}
					end
				end
			end

			local programmable = ProgrammableMenuPolicy.build_entry_rows(ManifestMenu,
				function() return ProgrammableHotstrings.build(ctx) end)
			for _, row in ipairs(programmable) do sub[#sub + 1] = row end

			local function commit_scope(enabled)
				local called, committed = pcall(function() return dyn.set_scope_enabled(enabled, config) end)
				if not called or committed ~= true then
					Logger.error(LOG, "Dynamic hotstring scope refused (%s).", called and "owner-not-committed" or "owner-error")
					show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
					return false
				end
				if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				return true
			end
			local rendered = ManifestMenu.build("hotstring_category_menu", "Hotstrings", nil, nil,
				{ commands = {
					hotstring_category_enable_all = function() return commit_scope(true) end,
					hotstring_category_disable_all = function() return commit_scope(false) end,
				} }, {
					hotstring_category_file = function() return {} end,
					hotstring_category_sections = function() return sub end,
				})

			rows[#rows + 1] = {
				-- category.dynamic_hotstrings, which is the key the CATEGORY carries in
				-- all 21 locales. menu.hotstrings.dynamic is the manifest's SECTION
				-- description key and has no translation of its own, so it would have
				-- rendered as the raw string.
				label   = string.format("%s (%d)", i18n_safe("category.dynamic_hotstrings"), count),
				checked = on,
				submenu = rendered,
			}
			return rows
		end,
		["hotstring_languages"] = language_rows,
		["hotstring_personal"] = function()
			local default_parent, group_rows, unavailable_rows = {}, {}, {}
			local preferences_present, close_on_add, close_action = false, false, nil
			local function editor_ready()
				if ctx.paused == true or type(ctx.is_paused) ~= "function"
					or type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then return false end
				local ok, current = pcall(ctx.is_paused)
				return ok and current == false
			end
			local editor_row = ManifestMenu.command_row("personal_hotstring_commands", require("config_keys").COMMAND.PERSONAL_HOTSTRING_OPEN_EDITOR,
				{ personal_hotstring_open_editor = function() return ctx.webview.show("hotstring_editor") end },
				{ personal_hotstring_editor_ready = editor_ready })

			local ok_editor, Editor = pcall(require, "ui.hotstring_editor.bridge")
			if ok_editor and type(Editor.get_pref) == "function" then
				-- Which section a new entry lands in. Built from the personal pack's
				-- own section order so the list is what the user actually has, and
				-- "none" is offered because leaving it unset is a real choice.
				local current = Editor.get_pref("default_section")
				local personal = type(config.get_category) == "function"
					and config.get_category(PERSONAL_CATEGORY) or nil
				local none_action = function()
						Editor.set_pref("default_section", "")
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end
				local choices = {}

				for _, name in ipairs(personal and personal.sections_order or {}) do
					local selected = (current == name)
					local choice = ManifestMenu.check_row("hotstring_personal_default_choice", require("config_keys").COMMAND.PERSONAL_DEFAULT_SECTION, {
						[require("config_keys").COMMAND.PERSONAL_DEFAULT_SECTION] = function()
							Editor.set_pref("default_section", name)
							if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
						end,
					}, {
						personal_default_section_label = function() return name end,
						personal_default_section_selected = function() return selected end,
					})
					if type(choice) ~= "table" then
						personal_choices_admitted = false
						return {}
					end
					choices[#choices + 1] = choice
				end
				local sub = ManifestMenu.template_rows("hotstring_personal_default_frame", {
					[require("config_keys").COMMAND.PERSONAL_DEFAULT_NONE] = none_action,
				}, {
					["personal_default_unset"] = function() return current == nil or current == "" end,
					["personal_default_boundary"] = function() return false end,
				}, { ["personal_default_choices"] = function() return choices end })
				if type(sub) ~= "table" then return {} end
				local projected_default = ManifestMenu.template_rows("hotstring_personal_default_parent", {},
					{ personal_default_label = function()
						return (current ~= nil and current ~= "") and current or i18n_safe("common.none")
					end }, { personal_default_caption = function() return sub end })
				if type(projected_default) ~= "table" then return {} end
				default_parent = projected_default

				preferences_present = true
				close_on_add = Editor.get_pref("auto_close") == true
				close_action = function()
						Editor.set_pref("auto_close", not close_on_add)
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end

			else
				Logger.error(LOG, "The hotstring editor bridge is unavailable — its preferences cannot be shown.")
			end


			local added, represented = 0, {}
			for _, name in ipairs(groups) do
				-- Extension packs are unclassified too, but they are not personal
				-- files: they belong to the extension that shipped them and get their
				-- own section below. Without this test they appeared here, under a
				-- heading that told the user they had written them.
				if not classified[name] and not Extensions.parse_category_key(name) then
					group_rows[#group_rows + 1] = group_row(name)
					represented[name] = true
					added = added + 1
				end
			end
			-- Empty or unavailable sources still own a file row; mappings are not
			-- a discovery inventory and must not hide their source controls.
			if type(config.personal_file_sources) == "function" then
				for _, source in ipairs(config.personal_file_sources()) do
					local descriptor = source.descriptor
					if PersonalFiles.is_descriptor(descriptor) and not represented[descriptor.id] then
						local row = group_row(descriptor.id)
						row.label = descriptor.label .. " (0)"
						if type(config.personal_file_scope_binding) ~= "function"
							or config.personal_file_scope_binding(descriptor.id) == nil then
							row.label = row.label .. " — " .. i18n_safe("menu.hotstrings.personal_source_unavailable")
						end
						group_rows[#group_rows + 1], represented[descriptor.id] = row, true
						added = added + 1
					end
				end
			end
			if type(config.personal_unavailable_directories) == "function" then
				for _, blocked in ipairs(config.personal_unavailable_directories()) do
					unavailable_rows[#unavailable_rows + 1] = { label = blocked.label,
						submenu = PersonalFileMenu.directory_unavailable(ManifestMenu) }
					added = added + 1
				end
			end
			local controls = ManifestMenu.template_rows("hotstring_personal_controls_frame", {
				[require("config_keys").COMMAND.PERSONAL_CLOSE_ON_ADD] = close_action,
			}, {
				["personal_open_present"] = function() return false end,
				["personal_controls_head_boundary"] = function() return false end,
				["personal_controls_tail_boundary"] = function() return true end,
				["personal_preferences_present"] = function() return preferences_present end,
				["personal_controls_ready"] = function() return true end,
				[require("config_keys").COMMAND.PERSONAL_CLOSE_ON_ADD] = function() return close_on_add end,
			}, {
				["personal_editor"] = function() return editor_row and { editor_row } or {} end,
				["personal_default_parent"] = function() return default_parent end,
				["personal_legacy_before"] = function() return {} end,
				["personal_legacy_after"] = function() return {} end,
			})
			if type(controls) ~= "table" then return {} end
			local rows = ManifestMenu.template_rows("hotstring_personal_content_frame", {}, {
				["personal_main_boundary"] = function() return false end,
				["personal_tree_boundary"] = function() return false end,
				["personal_custom_boundary"] = function() return false end,
				["personal_empty"] = function() return added == 0 end,
			}, {
				["personal_controls"] = function() return controls end,
				["personal_main_sections"] = function() return group_rows end,
				["personal_unavailable_directories"] = function() return unavailable_rows end,
				["personal_tree"] = function() return {} end,
				["personal_custom_sections"] = function() return {} end,
			})
			if type(rows) ~= "table" then return {} end
			if added == 0 then rows[#rows].action = function() end end

			return rows
		end,
		["hotstring_extensions"] = function()
			local rows = {}
			-- One « Hotstrings <extension> » submenu per installed extension, holding
			-- its packs and the bundled categories it binds whole (Ergopti's SFB
			-- reduction and rolls, which keep their historical ids). Grouped by
			-- extension rather than listed flat because an extension is the unit the
			-- user installed and the unit they will want to turn off; its individual
			-- packs are an implementation detail of how its author organised them.
			local by_extension, order, names = {}, {}, {}
			for _, name in ipairs(groups) do
				local extension_id = Extensions.parse_category_key(name)
				local label = nil
				if not extension_id then
					local category = type(config.get_category) == "function" and config.get_category(name) or nil
					local extension = category and category.extension or nil
					if type(extension) == "table" and type(extension.id) == "string" then
						extension_id = extension.id
						label = extension.name
					end
				end
				if extension_id then
					if not by_extension[extension_id] then
						by_extension[extension_id] = {}
						order[#order + 1] = extension_id
					end
					local list = by_extension[extension_id]
					list[#list + 1] = name
					names[extension_id] = names[extension_id] or label
				end
			end

			-- The sections an extension binds inside a bundled category (Ergopti's
			-- repeat corrections in the magic key): a row each in its submenu.
			local bound_sections = {}
			for _, name in ipairs(groups) do
				local category = type(config.get_category) == "function" and config.get_category(name) or nil
				for _, section in ipairs(category and category.sections_order or {}) do
					local record = (category.sections or {})[section]
					local extension = record and record.extension or nil
					if type(extension) == "table" and type(extension.id) == "string" then
						if not by_extension[extension.id] then
							by_extension[extension.id] = {}
							order[#order + 1] = extension.id
						end
						names[extension.id] = names[extension.id] or extension.name
						local list = bound_sections[extension.id] or {}
						bound_sections[extension.id] = list
						list[#list + 1] = { category = name, section = section, count = record.count or 0,
							description = record.description }
					end
				end
			end

			-- The bound categories in the menu manifest's order, the one Windows
			-- walks too, rather than in load order; the packs follow as loaded.
			for extension_id, list in pairs(by_extension) do
				by_extension[extension_id] = Extensions.menu_order(list, classes)
			end

			if #order == 0 then
				if type(ManifestMenu.status_rows) ~= "function" then return {} end
				local status = ManifestMenu.status_rows("hotstrings_menu", "hotstring_extensions", "none_installed")
				return type(status) == "table" and status or {}
			end

			for _, extension_id in ipairs(order) do
				local packs = by_extension[extension_id]
				local pack_rows, bound_rows = {}, {}
				local function commit_gates(enabled)
					if ctx.paused == true or (type(ctx.is_paused) == "function" and ctx.is_paused()) then return false end
					local bindings = {}
					for _, leaf in ipairs(bound_sections[extension_id] or {}) do
						bindings[#bindings + 1] = { group = leaf.category, section = leaf.section }
					end
					local called, committed = pcall(function()
						if type(config.set_extension_sections_enabled) ~= "function" then return false end
						return config.set_extension_sections_enabled(packs, bindings, enabled)
					end)
					if called and committed == true then
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
						return true
					end
					Logger.error(LOG, "Extension hotstring gate selection refused (%s).",
						called and "owner-not-committed" or "owner-error")
					show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
					return false
				end

				-- Turning the extension off means turning off every pack it brought.
				-- Offered first because it is the action the extension as a unit
				-- affords; the per-pack rows below are for the user who wants half.
				local bulk = ManifestMenu.template_rows("hotstring_extension_bulk_controls", {
					[require("config_keys").COMMAND.EXTENSION_ENABLE_ALL] = function() return commit_gates(true) end,
					[require("config_keys").COMMAND.EXTENSION_DISABLE_ALL] = function() return commit_gates(false) end,
				}, {}, {})

				for _, name in ipairs(packs) do
					pack_rows[#pack_rows + 1] = group_row(name)
				end
				for _, bound in ipairs(bound_sections[extension_id] or {}) do
					local category_on = config.is_group_enabled and config.is_group_enabled(bound.category)
					local checked = config.is_section_checked
						and config.is_section_checked(bound.category, bound.section)
						or (config.is_section_enabled and config.is_section_enabled(bound.category, bound.section))
					local description = bound.description
					if type(description) == "table" then
						local locale = require("infra.i18n").get_locale()
						description = description[locale] or description.en
					end
					if type(description) ~= "string" or description == "" then description = bound.section end
					bound_rows[#bound_rows + 1] = {
						label    = string.format("%s (%d)", description, bound.count),
						checked  = checked and true or false,
						-- Greyed while its category is off, like a section row there.
						disabled = not category_on or ctx.paused == true,
						action   = (category_on and ctx.paused ~= true) and function()
							if ctx.paused == true or (type(ctx.is_paused) == "function" and ctx.is_paused())
								or config.is_group_enabled(bound.category) ~= true then return false end
							local called, committed = pcall(function()
								if type(config.toggle_section) ~= "function" then return false end
								return config.toggle_section(bound.category, bound.section)
							end)
							if called and committed == true then
								require("ui.menu.feature_notice").feature(description, config.is_section_checked
									and config.is_section_checked(bound.category, bound.section) or false)
								return true
							end
							Logger.error(LOG, "Extension hotstring section toggle refused for '%s.%s' (%s).", bound.category, bound.section,
								called and "owner-not-committed" or "owner-error")
							show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
							return false
						end or nil,
					}
				end

				local sub = type(bulk) == "table" and ManifestMenu.template_rows("hotstring_extension_content_frame", {}, {}, {
					["extension_bulk_head"] = function() return bulk end,
					["extension_pack_rows"] = function() return pack_rows end,
					["extension_bound_boundary"] = function()
						if bound_sections[extension_id] and #packs > 0 then
							return ManifestMenu.template_rows("hotstrings_parameter_boundary", {}, {}, {})
						end
						return {}
					end,
					["extension_bound_tail"] = function() return bound_rows end,
				}) or nil
				local name = names[extension_id] or extension_label(extension_id)
				if sub then rows[#rows + 1] = {
					label = string.format(i18n_safe("menu.extensions.hotstrings_of"), name),
					items = sub,
				} end
			end
			return rows
		end,
	}

	-- word_expanders left params_handlers: its manifest row is `type = "list"`
	-- now, so the shared renderer materialises every row of the submenu from the
	-- data the provider returns rather than this driver assembling the menu.
	local params_providers = {
		["word_expanders"] = params_handlers["word_expanders"],
		["magic_key_config"] = params_handlers["magic_key_config"],
		["delays_colors"] = params_handlers["delays_colors"],
		-- The four toggles the manifest has declared for this driver all along and
		-- that nothing could reach: ui/tooltip/preview.lua honoured them on the hot
		-- path while its set_enabled() had no caller, so they were fixed at their
		-- load-time value. PreviewSettings owns them now; this menu is the way in.
		--
		-- Provider DATA since 2026-08-07: `{label, checked, action}` rows the
		-- renderer materialises, rather than a menu tree this driver assembled.
		["preview_bubbles"] = function()
			local choices = {}
			local row = ManifestMenu.check_row("preview_magic_control", require("config_keys").LEAF.PREVIEW_STAR_ENABLED, {
				[require("config_keys").LEAF.PREVIEW_STAR_ENABLED] = function()
					if PreviewSettings.toggle("star") ~= true then return false end
					require("ui.menu.feature_notice").feature(i18n_safe("menu.hotstrings.notify_bubble_star"), PreviewSettings.get("star") == true)
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end,
			}, {
				[require("config_keys").KEY.HOTSTRINGS_PREVIEW_STAR_ENABLED] = function() return PreviewSettings.get("star") == true end,
				-- Preserve configuration access while the Linux engine is paused.
				["preview_magic_ready"] = function() return true end,
			})
			if row then choices[#choices + 1] = row end
			local magic_rows = choices
			choices = {}
			local presence_commands, presence_getters = {}, { preview_presence_ready = function() return true end }
			local bubble_notice_keys = {
				autocorrect = "menu.hotstrings.notify_bubble_autocorrect",
				ai = "menu.hotstrings.notify_bubble_ai",
			}
			for key, name in pairs({ [COMMAND.PREVIEW_AUTOCORRECT_ENABLED] = "autocorrect", [COMMAND.PREVIEW_AI_ENABLED] = "ai" }) do
				presence_commands[key] = function()
					if PreviewSettings.toggle(name) ~= true then return false end
					require("ui.menu.feature_notice").feature(i18n_safe(bubble_notice_keys[name]), PreviewSettings.get(name) == true)
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end
				presence_getters["hotstrings." .. key] = function() return PreviewSettings.get(name) == true end
			end
			for _, declaration in ipairs(ManifestMenu.get_array("preview_presence_controls")) do
				local row = ManifestMenu.check_row("preview_presence_controls", declaration.id, presence_commands, presence_getters)
				if row then choices[#choices + 1] = row end
			end
			local presence_rows = choices
			choices = {}
			local row = ManifestMenu.check_row("preview_colored_control", require("config_keys").LEAF.PREVIEW_COLORED_TOOLTIPS, {
				[require("config_keys").LEAF.PREVIEW_COLORED_TOOLTIPS] = function()
					if PreviewSettings.toggle("colored") ~= true then return false end
					require("ui.menu.feature_notice").feature(i18n_safe("menu.hotstrings.notify_bubble_colored"), PreviewSettings.get("colored") == true)
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end,
			}, {
				[require("config_keys").KEY.HOTSTRINGS_PREVIEW_COLORED_TOOLTIPS] = function() return PreviewSettings.get("colored") == true end,
				-- Configuring a preview remains allowed while the Linux engine is paused.
				["preview_colored_ready"] = function() return true end,
			})
			if row then choices[#choices + 1] = row end

			local children = ManifestMenu.template_rows("hotstrings_preview_frame", {}, {}, {
				["parameter_preview_magic"] = function() return magic_rows end,
				["parameter_preview_presence"] = function() return presence_rows end,
				["parameter_preview_colored"] = function() return choices end,
			})
			if not children then return {} end
			return ManifestMenu.template_rows("hotstrings_preview_parent", {},
				{ ["parameter_parent_ready"] = function() return true end }, { ["parameter_preview_children"] = children }) or {}
		end,
	}
	params_handlers["word_expanders"] = nil
	params_handlers["magic_key_config"] = nil
	params_handlers["delays_colors"] = nil

	local group_builders = {
		["hotstrings_params"] = function(c)
			-- `repeat_key` is a `check` row: the renderer draws it from the
			-- declaration and this driver supplies only the toggle and the state
			-- behind the tick. Registered on the context the group is rendered
			-- with, because that is where the check branch looks.
			local params_ctx = {}
			for key, value in pairs(c) do params_ctx[key] = value end
			params_ctx.commands = {}
			for key, value in pairs(c.commands or {}) do params_ctx.commands[key] = value end
			params_ctx.commands[require("config_keys").COMMAND.REPEAT_KEY] = function()
				RepeatKey.toggle()
				if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			end
			params_ctx.state_getters = {}
			for key, value in pairs(c.state_getters or {}) do params_ctx.state_getters[key] = value end
			params_ctx.state_getters["hotstrings_repeat_enabled"] = function()
				return RepeatKey.is_enabled()
			end
			-- When the engine forgets the current word: the `idle_reset` choice
			-- (presets plus a free entry) and the click, arrow, shortcut and
			-- tap-hold checkboxes. The renderer draws the rows; these are their
			-- owners and states.
			-- Required here, not with the module imports: the menu manifest gate pins
			-- this file's top-level bindings.
			local WordReset = require("modules.hotstrings.word_reset")
			local function word_reset_changed(committed)
				if committed and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				return committed
			end
			params_ctx.commands[require("config_keys").COMMAND.IDLE_RESET] = function(seconds)
				return word_reset_changed(WordReset.set_idle_seconds(seconds))
			end
			params_ctx.commands["idle_reset_custom"] = function()
				local answer = prompt_text(i18n_safe("menu.hotstrings.idle_reset_title"),
					i18n_safe("menu.hotstrings.idle_reset_prompt"),
					string.format("%g", WordReset.idle_seconds()))
				if answer == nil then return false end
				local seconds = WordReset.parse_seconds(answer)
				if seconds == nil then
					Logger.warn(LOG, "Invalid idle delay '%s' — ignored.", tostring(answer))
					show_error(i18n_safe("menu.hotstrings.idle_reset_invalid"),
						i18n_safe("dialog.gestures.param_error_title"))
					return false
				end
				return word_reset_changed(WordReset.set_idle_seconds(seconds))
			end
			params_ctx.commands[COMMAND.CASCADE_MAX_ARROWS] = function(arrows)
				return word_reset_changed(WordReset.set_cascade_max_arrows(arrows))
			end
			params_ctx.commands[require("config_keys").COMMAND.CLICK_RESETS_WORD] = function()
				return word_reset_changed(WordReset.toggle_click_resets_word())
			end
			params_ctx.commands[require("config_keys").COMMAND.ARROW_RESETS_WORD] = function()
				return word_reset_changed(WordReset.toggle_arrow_resets_word())
			end
			params_ctx.commands[require("config_keys").COMMAND.SHORTCUT_RESETS_WORD] = function()
				return word_reset_changed(WordReset.toggle_shortcut_resets_word())
			end
			params_ctx.commands[require("config_keys").COMMAND.TAP_HOLD_RESETS_WORD] = function()
				return word_reset_changed(WordReset.toggle_tap_hold_resets_word())
			end
			params_ctx.state_getters[require("config_keys").KEY.HOTSTRINGS_IDLE_RESET_SECONDS] = function()
				return WordReset.idle_seconds()
			end
			params_ctx.state_getters[require("config_keys").KEY.HOTSTRINGS_CASCADE_MAX_ARROWS] = function()
				return WordReset.cascade_max_arrows()
			end
			params_ctx.state_getters["hotstrings_click_resets_word"] = function()
				return WordReset.click_resets_word()
			end
			params_ctx.state_getters["hotstrings_arrow_resets_word"] = function()
				return WordReset.arrow_resets_word()
			end
			params_ctx.state_getters["hotstrings_shortcut_resets_word"] = function()
				return WordReset.shortcut_resets_word()
			end
			params_ctx.state_getters["hotstrings_tap_hold_resets_word"] = function()
				return WordReset.tap_hold_resets_word()
			end
			return ManifestMenu.build("hotstrings_params_group", "HotstringsParams",
				params_handlers, nil, params_ctx, params_providers)
		end,
	}

	-- No whole-tree « all sections » row: it switched on the packs of every
	-- language at once. Each submenu owns the bulk rows of its own content.
	local hs_ctx = {}
	for key, value in pairs(ctx) do hs_ctx[key] = value end
	local function hotstrings_on() return _hotstrings_on(ctx) end

	--- Restores or clears the Hotstrings scope at once.
	--- @param mode string "recommended" or "clear".
	--- @return boolean committed
	local function apply_hotstrings_scope(mode)
		return _apply_hotstrings_scope(ctx, mode)
	end

	hs_ctx.commands = {
		[require("config_keys").COMMAND.SCOPE_RESTORE] = function() return apply_hotstrings_scope("recommended") end,
		[require("config_keys").COMMAND.SCOPE_CLEAR] = function() return apply_hotstrings_scope("clear") end,
		-- The category switch, the submenu's first row. Every driver registers it:
		-- no tray can switch a category from the row that opens its submenu.
		[require("config_keys").COMMAND.HOTSTRINGS_TOGGLE]      = function()
			-- The batched writers, not a loop of toggle_group: each toggle_group
			-- ends in a full load_all(), which re-parses every pack — magickey.toml
			-- alone is 305 KB — once per category, inside a menu callback.
			local changed
			local enabling = not hotstrings_on()
			if hotstrings_on() then
				-- Off stops every expansion: each gate closes, keeping its section
				-- choices, and the dynamic hotstrings stop with them.
				changed = config.disable_all()
				local dyn = ctx.dyn_hotstrings
				if changed ~= false and type(dyn) == "table" and type(dyn.is_enabled) == "function"
					and dyn.is_enabled() and dyn.set_enabled(false) ~= true then
					changed = false
				end
			else
				changed = config.enable_all()
			end
			if changed ~= false then require("ui.menu.feature_notice").feature(i18n_safe("notify.hotstrings"), enabling) end
			if changed ~= false and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
		-- Reloading the catalogue from disk: this driver's own affordance, because
		-- it is the only one whose hotstrings can change under it without a
		-- restart. Declared with that reason rather than appended unannounced.
		[require("config_keys").COMMAND.HOTSTRINGS_RELOAD]      = function()
			if config.reload then config.reload() end
		end,
	}
	hs_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do hs_ctx.state_getters[key] = value end
	hs_ctx.state_getters["hotstrings_enabled"] = hotstrings_on

	local rows = ManifestMenu.build("hotstrings_menu", "Hotstrings", nil, group_builders, hs_ctx, providers)
	if not personal_choices_admitted then return nil end
	return rows
end

--- Builds the hotstrings submenu: the manifest's rows, then this driver's own.
--- @param ctx table Menu context.
--- @return table One menu entry with its submenu.
local function _build_hotstrings(ctx)
	local receive = ManifestMenu and ManifestMenu.group_receiver("top_level", "hotstrings")
	if not receive then return nil end
	local config = ctx.config

	if type(config) ~= "table" then
		local status_rows = ManifestMenu and ManifestMenu.template_rows("linux_hotstrings_absent_rows", {}, {}, {})
		if not status_rows then return {} end
		local children = ManifestMenu.render_rows(status_rows, "linux_hotstrings_absent_rows")
		return receive(children, { hotstrings_enabled = function() return nil end,
			hotstrings_parent_total = function() return 0 end, hotstrings_parent_count_present = function() return false end })
	end

	local items = _manifest_hotstring_rows(ctx, config)

	-- The gate row and the reload row are BOTH the manifest's now, and both are
	-- built by the shared renderer from their declaration — see the `commands`
	-- and `state_getters` registered in _manifest_hotstring_rows.
	--
	-- The gate sits inside the submenu, as on every driver: appindicator binds
	-- item.fn only when the row has NO submenu (`if item.menu … elseif item.fn …`),
	-- and AppKit and Win32 never send a click for such a row either.

	-- The grand total, which macOS and Windows both put on this entry and Linux
	-- did not. On a driver that re-scans its catalogue from disk it is the fastest
	-- confirmation that a reload found the packs at all.
	--
	-- Summed from the ACTIVE counts, not the files' totals: a grand total computed
	-- the naive way would contradict the per-category numbers directly beneath it
	-- the moment anything was switched off.
	local grand_total = 0
	if type(config.get_groups) == "function" and type(config.active_count) == "function" then
		for _, name in ipairs(config.get_groups() or {}) do
			grand_total = grand_total + (config.active_count(name) or 0)
		end
	end


	-- The parent carries the same tick as the switch that opens the submenu, for
	-- a user scanning the top level. It cannot be clicked: no tray binds a click
	-- on a row that opens a submenu, which is why the switch is a row inside.
	return receive(items, { hotstrings_enabled = function() return _hotstrings_on(ctx) end,
		hotstrings_parent_total = function() return grand_total end, hotstrings_parent_count_present = function() return true end })
end

local _build_llm = require("ui.menu.menu_llm").build

local _build_agent = require("ui.menu.menu_agent").build

local _build_metrics = require("ui.menu.menu_metrics").build

local _build_shortcuts = require("ui.menu.menu_shortcuts").build

local _build_tap_holds = require("ui.menu.menu_tap_holds").build

local _build_gestures = require("ui.menu.menu_gestures").build

local _build_configuration = require("ui.menu.menu_configuration").build

local _build_language = require("ui.menu.menu_language").build

--- The channel picker of the About submenu: one submenu titled with the
--- subscribed channel's registry name, one row per registry channel in registry
--- order, ticked on the subscribed one. A click subscribes through the updater,
--- which persists the choice; the redraw it asks for retitles the picker.
--- @param ctx table Menu context.
--- @param up table The updater module.
--- @return table row A provider row with its items.
local function _channel_picker(ctx, up)
	return ManifestMenu.choice_row("about_update_channel_menu", require("config_keys").COMMAND.UPDATE_CHANNEL, {
		update_channel = function(id)
			local ok, committed = pcall(up.set_channel, id)
			if not ok or committed ~= true then return false end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			-- An open Versions page follows only an acknowledged subscription.
			local ok_bridge, Changelog = pcall(require, "ui.changelog.bridge")
			if ok_bridge then
				Changelog.push_subscribed_channel(id)
			else
				Logger.error(LOG, "The Versions page bridge is unavailable: %s.", tostring(Changelog))
			end
			return true
		end,
	}, {
		[require("config_keys").KEY.UPDATER_CHANNEL] = function() return up.get_channel() end,
		installed_build = function() return not Installation.is_source_run() end,
	})
end

--- Supplies the registered cadence choice to the existing updater owner.
--- @param ctx table Menu context.
--- @param up table Native updater owner.
--- @return table row Shared choice provider data.
local function _frequency_picker(ctx, up)
	return ManifestMenu.choice_row("about_update_frequency_menu", require("config_keys").COMMAND.UPDATE_CHECK_INTERVAL, {
		update_check_interval = function(seconds)
			if up.set_check_interval(seconds) ~= true then return false end
			if up.start_background_checks() ~= true then return false end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			return true
		end,
	}, {
		[require("config_keys").KEY.UPDATER_CHECK_INTERVAL_SECONDS] = function()
			return Schedule.snap_interval(up.get_check_interval(), up.TIMING)
		end,
		installed_build = function() return not Installation.is_source_run() end,
	})
end

--- The updater block of the About submenu, as provider DATA: the version, the
--- channel picker right before the check row, then the check-frequency picker.
--- It used to be a Linux-only top-level "Updates" submenu with its own
--- 'stable'/'dev' rows.
--- @param ctx table Menu context.
--- @return table rows
local function _about_update_rows(ctx)
	local up = ctx.updater
	-- The build and the commit it was built from, in the shared wording:
	-- « Version 0.0.0-dev.144 (c3005e0b9) » for a release, « Version locale
	-- (c3005e0b9) » for a source run. The identity is resolved once per daemon
	-- by infra/version.lua, so a rebuild reads no file.
	local identity = Version.identity()
	local out = {
		{
			label = VersionLabel.format(identity.kind, identity.version, identity.commit, i18n_safe),
			disabled = true,
		},
	}
	local separator_rows = ManifestMenu.template_rows("about_version_separator")
	if not separator_rows then return {} end
	for _, row in ipairs(separator_rows) do out[#out + 1] = row end
	if not up then
		Logger.error(LOG, "No updater module — the About menu shows no channel or check row.")
		return out
	end

	out[#out + 1] = _channel_picker(ctx, up)

	-- A local version has no installation to update, so it checks for nothing
	-- (the updater starts no background check for it). Its channel, check and
	-- frequency rows are still drawn, greyed with the reason: left out, nobody
	-- could tell whether the automatic update exists. The manifest's
	-- `disabled_when = ["installed_build"]` greys the two choices.
	local source_run = Installation.is_source_run()
	-- A system package never self-updates either, so it gets the same greyed rows
	-- with its own reason (the key the Versions window already shows).
	local update_blocked_reason = source_run and "menu.about.source_run_reason" or nil
	if not source_run and type(up.installation_kind) == "function" and up.installation_kind() == "package" then
		update_blocked_reason = "changelog_window.install_blocked_package"
	end
	local frequency_row = _frequency_picker(ctx, up)

	-- A check discovers releases; installation needs the separately named row.
	if source_run then
		local source_row = ManifestMenu.command_row("about_source_menu", require("config_keys").COMMAND.ABOUT_SOURCE_CHECK, {
			[require("config_keys").COMMAND.ABOUT_SOURCE_CHECK] = function() return false end,
		}, { ["about_source_release_ready"] = function() return not source_run end })
		if source_row then out[#out + 1] = source_row end
	else
		out[#out + 1] = {
		label = up.get_menu_label(),
		disabled = up.get_state() == "checking" or up.get_state() == "downloading"
			or up.get_state() == "installing",
		action = function()
			-- The answer is shown in the shared update-check window, with Update
			-- and the other channels' newer releases
			local opened = require("ui.update_check.bridge").open({
				updater            = up,
				on_menu_changed    = ctx.on_menu_changed,
				on_update_finished = ctx.on_update_finished,
				on_open_today_log  = ctx.on_open_today_log,
			})
			if opened then return end
			-- Without a window (no WebKitGTK, no display) the answer is announced
			-- by a notification instead
			Logger.warn(LOG, "The update-check window could not open; the answer is notified instead.")
			up.check_for_updates(nil, function(available, release, err)
				if available and release then
					Logger.info(LOG, "Update available: %s.", release.tag)
				elseif err then
					Logger.warn(LOG, "Update check failed: %s.", tostring(err))
				else
					Logger.info(LOG, "No update available (current: %s).", up.current_version())
				end
				if type(ctx.on_update_checked) == "function" then
					ctx.on_update_checked(available, release, err)
				end
				if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			end)
		end,
	}
	end

	-- Only once there is something to install: a permanently visible
	-- "download" row that does nothing is indistinguishable from a broken one.
	if up.get_state() == "available" then
		local rel = up.get_cached_release()
		if rel and rel.check_only == true then
			-- Read from the public feed because the API was unreachable: announced, not installable.
			out[#out + 1] = {
				label = _fill(i18n_safe("menu.about.update_now"), "{tag}", rel.tag),
				disabled = true,
				disabled_reason_key = "update_check.check_only",
			}
		elseif rel and update_blocked_reason then
			-- A source run offers the latest release to look at, but has no
			-- installation to replace; a system package is updated by its
			-- package manager: the row stays, greyed, and the renderer names why
			-- as on every greyed row with a reason, with no action a click could
			-- start.
			out[#out + 1] = {
				label = _fill(i18n_safe("menu.about.update_now"), "{tag}", rel.tag),
				disabled = true,
				disabled_reason_key = update_blocked_reason,
			}
		elseif rel then
			out[#out + 1] = {
				label = _fill(i18n_safe("menu.about.update_now"), "{tag}", rel.tag),
				action = function()
					-- Consent names the release this row shows: the manager refuses
					-- it if a background check replaced the cached release since.
					require("ui.update_check.bridge").download_offered(up, rel, ctx)
				end,
			}
		end
	end


	-- A system package is an installed build, so only its own reason is applied here.
	if update_blocked_reason and not source_run then
		frequency_row.items = nil
		frequency_row.disabled = true
		frequency_row.disabled_reason_key = update_blocked_reason
	end

	out[#out + 1] = frequency_row
	return out
end

M._about_update_rows = _about_update_rows

--- The action of the Uninstall row: the confirmed removal transaction of
--- ui/menu/uninstall.lua, which quits the daemon through ctx.on_quit once the
--- removal worker owns the files.
--- @param ctx table Menu context.
--- @return function
local function _uninstall_command(ctx)
	local receive, current
	if uninstall_caption_facade_current() then receive, current = uninstall_caption_factory("about_menu", "uninstall") end
	return function()
		if not uninstall_caption_facade_current() or type(receive) ~= "function" or type(current) ~= "function" or not current() then return false end
		local run = require("ui.menu.uninstall").run
		local title = receive()
		if title == nil or not uninstall_caption_facade_current() or not current() then return false end
		local confirmation = i18n_safe("dialog.uninstall.confirm")
		if not uninstall_caption_facade_current() or not current() then return false end
		local failure = i18n_safe("dialog.uninstall.failed")
		if not uninstall_caption_facade_current() or not current() then return false end
		local missing_program = i18n_safe("dialog.uninstall.missing_program")
		if not uninstall_caption_facade_current() or not current() then return false end
		local options = {
			title = title,
			confirmation = confirmation,
			failure = failure,
			missing_program = missing_program,
			confirm = function(title, text)
				return ask_yes_no(title, zenity_plain(text),
					i18n_safe("button.remove"), i18n_safe("button.cancel"))
			end,
			fail = function(text) show_error(zenity_plain(text), i18n_safe("menu.global.uninstall")) end,
			quit = function()
				if type(ctx.on_quit) ~= "function" then
					Logger.error(LOG, "Uninstall: ctx.on_quit is absent — the daemon cannot quit.")
					return
				end
				ctx.on_quit()
			end,
		}
		if not uninstall_caption_facade_current() or not current() then return false end
		run(options)
	end
end

--- Delegates the raw dense-array check to the shared section admission.
--- @param value table Source array.
--- @param records boolean Whether its values must be plain records.
--- @return boolean
local function about_dense(value, records)
	return ParentSource.dense(value, records)
end

--- Delegates the actual About source admission to the shared section admission.
--- @param renderer table|nil Actual manifest renderer.
--- @param platform string Native platform token.
--- @return table|nil root, table|nil top, table|nil children, table|nil parent, table|nil fields
local function about_source(renderer, platform)
	return ParentSource.read(renderer, platform, "about")
end

--- Delegates the direct parent recheck to the shared section admission.
--- @param parent table Actual direct source row.
--- @param fields table Captured raw field references and scalar values.
--- @return boolean
local function about_parent_unchanged(parent, fields)
	return ParentSource.unchanged(parent, fields)
end

--- Builds the about item: the updater block, Versions and its GitHub page, then
--- startup and Uninstall after a separator. Uninstall sat at the bottom of
--- Configuration until 2026-09, where it read as one more setting.
local function _build_about(ctx)
	local root, top, section, parent, fields = about_source(ManifestMenu, "linux")
	if root == nil then return nil end
	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	render_ctx.commands = {
		[require("config_keys").COMMAND.START_AT_LOGIN] = function()
			if not require("ui.menu.start_at_login").toggle() then
				show_error(i18n_safe("dialog.start_at_login.failed"), i18n_safe("menu.global.start_at_login"))
			end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
		["uninstall"] = _uninstall_command(ctx),
		-- Opens the release notes. It used to log one line to a file the user
		-- never sees and call that an About box — while ui/changelog/ was written,
		-- registered in webview_manager's bridge table and given a window title,
		-- with no caller anywhere. The page existed and nothing could reach it.
		[require("config_keys").COMMAND.ABOUT_CHANGELOG] = function()
			if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
				Logger.error(LOG, "No webview manager — the release notes cannot open.")
				return
			end
			ctx.webview.show("changelog")
		end,
		[require("config_keys").COMMAND.ABOUT_RELEASES_PAGE] = function()
			if type(ctx.updater) ~= "table" then
				Logger.error(LOG, "No updater module — the releases page URL is unknown.")
				return
			end
			local url = ctx.updater.releases_page_url()
			Logger.info(LOG, "Opening releases page: %s", url)
			pcall(function() os.execute("xdg-open " .. shell_quote(url) .. " 2>/dev/null &") end)
		end,
	}

	-- A local version run from source has nothing to uninstall: the row stays,
	-- greyed, and says why (the manifest's disabled_reason_key).
	local getters = {}
	for key, getter in pairs(type(render_ctx.state_getters) == "table" and render_ctx.state_getters or {}) do
		getters[key] = getter
	end
	getters["installed_build"] = function() return not Installation.is_source_run() end
	getters["startup_command_available"] = function()
		return require("ui.menu.start_at_login").command_available() ~= false
	end
	getters["start_at_login_enabled"] = function()
		return require("ui.menu.start_at_login").enabled() == true
	end
	render_ctx.state_getters = getters

	local rows = ManifestMenu
		and ManifestMenu.build("about_menu", "About", nil, nil, render_ctx, {
			["about_updates"] = function() return _about_update_rows(ctx) end,
		})
		or {}
	if not about_dense(rows, true) then return nil end
	local current_root, current_top, current_section, current_parent = about_source(ManifestMenu, "linux")
	if not rawequal(root, current_root) or not rawequal(top, current_top)
		or not rawequal(section, current_section) or not rawequal(parent, current_parent)
		or not about_parent_unchanged(parent, fields) then return nil end
	return ManifestMenu.group_row("top_level", "about", rows, render_ctx.state_getters)
end

local _build_reload = require("ui.menu.menu_reload").build

local _build_quit = require("ui.menu.menu_quit").build

local _build_debug = require("ui.menu.menu_debug").build


-- =========================================
-- =========================================
-- ======= 2/ i18n Safe Fallback ===========
-- =========================================
-- =========================================

--- Returns the translated string, or the KEY when the i18n module cannot be
--- loaded at all. Separated so the menu builder works before the i18n wiring is
--- done — the pcall guards a real boot-order case, not a missing translation.
---
--- It used to take a French `fallback` second argument, supplied at all 30 call
--- sites. Every one of those keys exists in en.json and the locale-parity gate
--- keeps all 21 locales in step with it, so the fallback was unreachable — and
--- had it ever been reached, it would have shown French to a user of any of the
--- other 20 languages. A raw key on screen is ugly and diagnosable; a silently
--- wrong language is neither.
--- @param key string i18n key.
--- @return string The translation, or the key itself.
function i18n_safe(key)
	local ok, i18n = pcall(require, "infra.i18n")
	if ok and i18n and type(i18n.get) == "function" then
		local val = i18n.get(key)
		if val and val ~= key then return val end
	end
	return key
end


-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
-- =========================================
-- =========================================

--- Builds the full tray menu item list from the daemon's current state.
--- @param ctx table {
---   _version       string   Driver version string.
---   paused         boolean  Whether the script is paused (greys the feature rows).
---   is_paused      function Live pause getter for deferred configuration actions.
---   on_toggle_pause function Resumes from the paused title row.
---   config         table    Hotstrings_config module.
---   layout         string   Current keyboard layout.
---   on_layout_change function Called with new layout name.
---   keystats      table    Keystats module.
---   llm            table|nil LLM prediction engine state.
---   dry_run        boolean  Dry-run mode flag.
---   verbose        boolean  Verbose flag.
---   on_quit        function Called when Quit is selected.
---   webview        table    Webview manager; opens the folders editor.
---   on_set_log_level function (optional) Log level change.
---   on_open_logs   function (optional) Open logs dir.
---   on_healthcheck function (optional) Launch healthcheck.
---   on_composer_check function (optional) Run the composed layout check.
---   on_show_setup_wizard function (optional) Launch setup wizard.
--- }
--- @return table Array of { title, menu?, fn?, checked?, disabled? } items.
function M.build(ctx)
	if not separator_facade_current() then return {} end
	local ctx = type(ctx) == "table" and ctx or {}
	-- Row DATA since 2026-08-07, rendered at the end of this function. Every
	-- builder used to return the finished tray row that hangs its submenu — the
	-- same three fields written by hand, once per submenu, twenty times over.
	-- They return `{ label, submenu }` now and the shared renderer draws the
	-- whole tray root.
	--
	-- `submenu` and not `items` for the trees that are already built: the
	-- renderer caps nested ROW data at three levels to stop a self-referential
	-- provider from recursing, and re-describing the hotstrings tree — which is
	-- already deeper than that — would truncate it silently.
	local rows = {}

	-- The shared header owns inert/paused presentation; the version remains native data.
	local header, header_current = _build_header(ctx)
	if not header or type(header_current) ~= "function" or not header_current() then return {} end
	rows[#rows + 1] = header

	-- Every entry below, and the separators between them, in the order the
	-- manifest declares — read rather than repeated here.
	--
	-- The order used to be written out in this function, and it had already
	-- drifted: this driver put the debug submenu between "reload" and "quit"
	-- while `top_level` declares it last, and nothing could see the difference
	-- because the sequence existed only as a list of calls. Windows has read this
	-- same array through its own loader all along.
	local builders = {
		["keyboard_layout"] = _build_layouts,
		["hotstrings"]      = _build_hotstrings,
		["llm"]             = _build_llm,
		["agent"]           = _build_agent,
		["metrics"]         = _build_metrics,
		["shortcuts"]       = _build_shortcuts,
		["tap_holds"]       = _build_tap_holds,
		["gestures"]        = _build_gestures,
		["configuration"]   = _build_configuration,
		["language"]        = _build_language,
		["about"]           = _build_about,
		["reload"]          = _build_reload,
		["quit"]            = _build_quit,
		["debug"]           = _build_debug,
	}

	-- Retain the existing real whole-array reader as well as shared admission.
	-- Its result must be the same canonical source, never an equal-looking copy.
	if not separator_facade_current() then return {} end
	local declared = ManifestMenu.get_array("top_level")
	if not separator_facade_current() then return {} end
	local receive_separator, source_rows = separator_factory()
	if not separator_facade_current() or type(receive_separator) ~= "function"
		or type(declared) ~= "table" or not rawequal(declared, source_rows) then
		Logger.error(LOG, "The canonical top-level boundary source is unavailable.")
		return {}
	end
	if #declared == 0 then
		Logger.error(LOG, "The manifest declares no top-level row — the tray would be empty.")
		return {}
	end

	-- Quit is held back and appended last, which is the ONE place this driver
	-- departs from the declared order. Every other tray application on this
	-- desktop puts it at the bottom (SNI/dbusmenu convention), and a user
	-- reaching for the last entry expects Quit. The manifest still decides that
	-- the row exists and what precedes it; only this one position is the
	-- platform's, and tools/test/test-menu-top-level-parity.cjs records it as a
	-- deliberate divergence rather than letting it pass unnoticed.
	local quit_row = nil

	for _, row in ipairs(declared) do
		if not separator_facade_current() or not receive_separator("current") then return {} end
		if type(row) == "table" then
			local id = row.id
			if id == "---" then
				if _row_is_for_linux(row) then
					local boundary = receive_separator(row)
					if not boundary then return {} end
					rows[#rows + 1] = boundary
				end
			elseif _row_is_for_linux(row) then
				local build = builders[id]
				if not build then
					-- A declared row this driver has no builder for is a row the user
					-- was promised and will not see. The bijection gate cannot catch it
					-- here, because top_level rows carry no behaviour type.
					Logger.error(LOG, "No builder for top-level row '%s' — the entry is missing.", tostring(id))
				elseif row.disabled == true then
					rows[#rows + 1] = { label = i18n_safe(row.i18n), disabled = true,
						disabled_reason_key = row.reason_key }
				elseif id == "quit" then
					quit_row = build(ctx)
				elseif ctx.paused == true and row.greyed_when_paused == true then
					-- The rows the manifest marks as features, the same ones on the
					-- three trays. The tail (updates, configuration, language, about,
					-- reload, quit, debug) stays live: it is how the user inspects,
					-- resumes or leaves a paused script.
					rows[#rows + 1] = _grey_for_pause(build(ctx))
				else
					rows[#rows + 1] = build(ctx)
				end
			end
		end
		if not separator_facade_current() or not receive_separator("current") then return {} end
	end

	if quit_row then
		-- The existing declared boundary before Quit follows its Linux-only last placement.
		local boundary = receive_separator("linux_quit_last")
		if not boundary then return {} end
		rows[#rows + 1] = boundary
		rows[#rows + 1] = quit_row
	else
		Logger.error(LOG, "The manifest declares no quit row for this driver — the tray cannot be closed.")
	end

	if not separator_facade_current() or not receive_separator("current") or not header_current() then return {} end
	local rendered = separator_render(rows, "top_level")
	if not separator_facade_current() or not receive_separator("current") or not header_current() then return {} end
	return rendered
end

return M
