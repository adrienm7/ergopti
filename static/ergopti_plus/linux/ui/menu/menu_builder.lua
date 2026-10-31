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

-- The category id of the user's own hotstrings — the stem of personal.toml, and
-- the same name the editor bridge writes under. Named here so the default-section
-- picker reads the sections of that pack rather than guessing at a spelling.

-- Single source of the driver version and of the build identity.
local Version = require("infra.version")

-- The one answer to "installed build or source run".
local Installation = require("infra.installation")

-- The shared wording of the About version row.
local VersionLabel = require("updater.version_label")

-- The shared automatic-check schedule (frequency presets and their snap).
local Schedule = require("updater.schedule")


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

local _build_hotstrings = require("ui.menu.menu_hotstrings").build

local _build_llm = require("ui.menu.menu_llm").build

local _build_agent = require("ui.menu.menu_agent").build

local _build_metrics = require("ui.menu.menu_metrics").build

local _build_shortcuts = require("ui.menu.menu_shortcuts").build

local _build_tap_holds = require("ui.menu.menu_tap_holds").build

local _build_gestures = require("ui.menu.menu_gestures").build

local _build_configuration = require("ui.menu.menu_configuration").build

local _build_language = require("ui.menu.menu_language").build

local _about_update_rows = require("ui.menu.menu_about")._about_update_rows
local _build_about = require("ui.menu.menu_about").build

-- Read by the tests of the About update rows.
M._about_update_rows = _about_update_rows

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
