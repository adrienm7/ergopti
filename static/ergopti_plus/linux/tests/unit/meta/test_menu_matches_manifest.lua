--- tests/unit/meta/test_menu_matches_manifest.lua

--- ==============================================================================
--- MODULE: The Menu the User Sees Is the Menu the Manifest Declares
--- DESCRIPTION:
--- Builds the whole tray with the daemon's own builder and checks, row by row,
--- that every entry the manifest promises this platform actually appears.
---
--- WHY THIS AND NOT ANOTHER STATIC GATE:
--- The cross-driver gates in tools/test read the manifest and the SOURCE. They
--- catch a manifest that promises a row no handler answers, and a driver that
--- builds rows no manifest describes. What neither can see is the third case:
--- a handler that exists, is registered, is reached — and appends nothing,
--- because a guard above it returned early, a context key was misspelled, or the
--- row it builds is conditional on state the daemon never sets. That row is
--- declared, handled, and invisible, and every gate stays green.
---
--- It happened. The gestures submenu declared eleven rows and rendered one; the
--- hotstrings dynamic category was a greyed "(aucun groupe chargé)" while the
--- engine behind it was expanding dates. Both were found by reading, not by a
--- test, because no test ever built the menu and looked at it.
---
--- WHAT IT CHECKS, AND WHAT IT CANNOT:
--- Only rows the RENDERER materialises with a label it owns — `action`, `group`,
--- `section_header`, `list`. A `dynamic` row's rows are the handler's to name,
--- and a `feature` or `toggle` row is built by the caller by contract, so
--- neither has a label this test could look for. Those stay with the
--- bijection ratchet, which asks the narrower question of whether a handler is
--- registered at all.
---
--- WHY IT LIVES IN THE DRIVER SUITE:
--- It needs the driver to actually run. That also means it runs on every
--- distribution's LuaJIT in CI, on a real Linux, rather than against a regex.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Rebound rather than required: `infra.manifest_menu` captures the i18n MODULE
-- TABLE when it is loaded, and tests/unit/meta/test_i18n_persistence.lua wipes
-- `package.loaded["infra.i18n"]` nine times. Whichever of them ran first, the
-- renderer would then be resolving labels against an i18n instance this file
-- cannot see, and every comparison below would be between two different
-- catalogues. Production is unaffected — `set_locale` mutates the module in
-- place and nothing there ever wipes the cache — so this is the harness being
-- made to agree with itself, not a defect being worked around.
local ManifestMenu = helpers.load_module("infra.manifest_menu")
local i18n         = require("infra.i18n")

-- The platform token this driver is declared under in the manifest.
local PLATFORM = "linux"

-- Row types the shared renderer materialises itself, with a label it resolves
-- from the manifest's own i18n key. Every other type is built by a handler or by
-- the caller, and carries no label this test could look for.
local RENDERED_TYPES = { action = true, group = true, section_header = true }

--- Whether the manifest declares a row for this platform.
--- @param row table
--- @return boolean
local function visible(row)
	if type(row.platforms) ~= "table" then return true end
	for _, platform in ipairs(row.platforms) do
		if platform == PLATFORM then return true end
	end
	return false
end

--- Every title in a built menu tree, flattened.
--- @param items table
--- @param out table|nil
--- @return table
local function all_titles(items, out)
	out = out or {}
	for _, item in ipairs(items or {}) do
		if type(item.title) == "string" then out[#out + 1] = item.title end
		if type(item.menu) == "table" then all_titles(item.menu, out) end
	end
	return out
end

--- Finds the first rendered row with an exact title.
--- @param items table
--- @param title string
--- @return table|nil
local function find_item(items, title)
	for _, item in ipairs(items or {}) do
		if item.title == title then return item end
		-- Absent native owners retain the declared inert child and its exact reason.
		local reasoned = nil
		for _, key in ipairs({ "llm_native_parent_linux", "agent_native_parent" }) do
			for _, declaration in ipairs(ManifestMenu.get_array(key) or {}) do
				if declaration.type == "group" and i18n.get(declaration.i18n) == title
					and type(declaration.disabled_reason_key) == "string" then
					local projected = ManifestMenu.render_rows({ { label = title, disabled = true,
						disabled_reason_key = declaration.disabled_reason_key } }, "absent-parent-selection")
					if #projected == 1 then reasoned = projected[1].title end
				end
			end
		end
		if item.disabled == true and reasoned ~= nil and item.title == reasoned then return item end
		local nested = type(item.menu) == "table" and find_item(item.menu, title) or nil
		if nested then return nested end
	end
	return nil
end

-- The provider list is genuine, while its entries file belongs to this fixture.
-- Fresh backend and builder modules must capture this exact private owner, not
-- a prior module whose source path or cached entries belong to another test.
local API_SOURCE_MODULES = {
	"modules.llm.api_entries", "ui.menu.llm_backend_rows", "ui.menu.menu_builder",
}

--- Builds with a genuine private API source and restores the complete module cohort.
--- @param scenario function Receives the actual builder, entries owner and source path.
--- @return any
local function with_api_source(scenario)
	local path = os.tmpname()
	local source = '{"version":1,"active_id":"","entries":[]}\n'
	local previous = {}
	for _, name in ipairs(API_SOURCE_MODULES) do previous[name] = rawget(package.loaded, name) end
	local file
	local ok, result = xpcall(function()
		file = assert(io.open(path, "wb"))
		assert(file:write(source)); assert(file:close()); file = nil
		for _, name in ipairs(API_SOURCE_MODULES) do rawset(package.loaded, name, nil) end
		local entries = require("modules.llm.api_entries")
		entries._set_path_for_test(path)
		require("ui.menu.llm_backend_rows")
		local builder = require("ui.menu.menu_builder")
		return scenario(builder, entries, path)
	end, debug.traceback)
	local closed = true
	if file then
		local close_ok, close_receipt = pcall(file.close, file)
		closed = close_ok and close_receipt == true
	end
	for _, name in ipairs(API_SOURCE_MODULES) do rawset(package.loaded, name, previous[name]) end
	for _, owned_path in ipairs({ path, path .. ".corrupt" }) do
		local owned = io.open(owned_path, "rb")
		if owned then assert(owned:close()); assert(os.remove(owned_path)) end
	end
	for _, name in ipairs(API_SOURCE_MODULES) do
		helpers.assert_true(rawequal(rawget(package.loaded, name), previous[name]), name)
	end
	helpers.assert_eq(closed, true, "the private seed descriptor closes on every exit")
	if not ok then error(result, 0) end
	return result
end

-- The complete tray requires the actual live-mode reader, not a fabricated state.
-- Its profiles read an owned physical neutral source through the real preference
-- transaction preview; engine initialization and native output are not exercised.
local LIVE_SOURCE_MODULES = {
	"infra.llm_preferences", "modules.llm.profile_settings", "modules.llm.prediction_engine",
	-- Settings cache source values, and Agent rows retain that actual module table.
	"modules.llm.agent_settings", "ui.menu.agent_rows",
}

local function with_live_source(context, scenario)
	if type(context.llm) ~= "table" or context.llm.get_live ~= nil then return scenario() end
	local prior = {}; for _, name in ipairs(LIVE_SOURCE_MODULES) do prior[name] = rawget(package.loaded, name) end
	local old_read, old_write = context.llm.get_live, context.llm.set_live
	local path, preferences, owner = os.tmpname(), nil, { pending = function() return false end }
	local descriptor
	local acquired, result = false, nil
	local ok, detail = xpcall(function()
		descriptor = assert(io.open(path, "wb")); assert(descriptor:write("")); assert(descriptor:close()); descriptor = nil
		for _, name in ipairs(LIVE_SOURCE_MODULES) do rawset(package.loaded, name, nil) end
		preferences = require("infra.llm_preferences")
		local bytes, status = require("toml_codec.writer").read_classified(path)
		assert(status == "ok" and bytes == "")
		assert(preferences.acquire(owner)); acquired = true
		assert(preferences.with_configuration(owner, { status = status, content = bytes }, function()
			-- Independent neutral physical input: both systems are Off, no model or excluded app.
			local settings = require("modules.llm.agent_settings")
			for _, system in ipairs({ "system1", "system2" }) do
				helpers.assert_eq(settings.get_spec(system), "")
				local model, reason = settings.resolve(system)
				helpers.assert_nil(model)
				helpers.assert_eq(reason, "off")
			end
			helpers.assert_eq(#settings.get_disabled_apps(), 0)
			helpers.assert_eq(settings.get_mode(), "off")
			local engine = require("modules.llm.prediction_engine")
			assert(engine.get_live() == nil)
			context.llm.get_live, context.llm.set_live = engine.get_live, engine.set_live
			result = scenario()
			return true
		end))
	end, debug.traceback)
	context.llm.get_live, context.llm.set_live = old_read, old_write
	local released, release_receipt = true, true
	if acquired then released, release_receipt = pcall(preferences.release, owner) end
	local closed, close_receipt = true, true
	if descriptor then closed, close_receipt = pcall(descriptor.close, descriptor) end
	for _, name in ipairs(LIVE_SOURCE_MODULES) do rawset(package.loaded, name, prior[name]) end
	local retained = io.open(path, "rb")
	if retained then assert(retained:close()); assert(os.remove(path)) end
	assert(released and release_receipt == true and closed and close_receipt == true)
	for _, name in ipairs(LIVE_SOURCE_MODULES) do
		helpers.assert_true(rawequal(rawget(package.loaded, name), prior[name]), name)
	end
	helpers.assert_true(rawequal(context.llm.get_live, old_read) and rawequal(context.llm.set_live, old_write))
	if not ok then error(detail, 0) end
	return result
end

--- Builds the real tray with a scoped entries source, retaining native callbacks.
--- @param context table
--- @return table
--- Builds with the actual ordered-pair owner over an owned neutral source.
--- Native editing is not exercised by this menu-shape fixture.
local function build_fixture_menu(context)
	local names = {"modules.shortcuts.key_combinations", "infra.key_combinations_scope", "ui.menu.key_combinations",
		"adapters.storage", "ui.hotstring_editor.bridge", "ui.gesture_conflicts",
		"infra.i18n", "infra.manifest_menu"}
	local magic_path, editor_directory, editor_source, editor_fs
	local original_getenv, original_i18n_safe = os.getenv, rawget(_G, "i18n_safe")
	local all_previous = {}; for name, value in pairs(package.loaded) do all_previous[name] = value end
	if context.magic_key_source == nil then
		names[#names + 1] = "modules.hotstrings.magic_key_source"
		names[#names + 1] = "infra.hotstring_preferences"
	end
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local ok, rows = pcall(function()
		local lfs = require("lfs"); editor_fs = lfs
		editor_directory = os.tmpname(); assert(os.remove(editor_directory)); assert(lfs.mkdir(editor_directory))
		assert(lfs.mkdir(editor_directory .. "/ergopti_plus"))
		editor_source = editor_directory .. "/ergopti_plus/storage.json"
		local seed = assert(io.open(editor_source, "wb"))
		assert(seed:write('{"hotstring_editor.default_section":"","future":{"keep":true}}\n')); assert(seed:close())
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" then return editor_directory end
			return original_getenv(name)
		end
		rawset(package.loaded, "adapters.storage", nil); rawset(package.loaded, "ui.hotstring_editor.bridge", nil)
		helpers.assert_eq(require("ui.hotstring_editor.bridge").get_pref("default_section"), "",
			"the real editor reads the independent neutral default-section source")
		if context.magic_key_source == nil then
			magic_path = os.tmpname()
			local source = assert(io.open(magic_path, "wb"))
			assert(source:write('[hotstrings]\nmagic_key_source = "auto"\n')); assert(source:close())
			local preferences = helpers.load_module("infra.hotstring_preferences")
			assert(preferences._set_file_for_test(magic_path))
			context.magic_key_source = helpers.load_module("modules.hotstrings.magic_key_source")
			helpers.assert_eq(context.magic_key_source.get(), "auto", "whole-tray fixture owns the actual automatic source")
		end
		local Paths = require("infra.paths")
		local file = assert(io.open(Paths.shared("tap_hold/defaults.toml"), "rb"))
		local defaults = assert(require("toml_codec").decode(file:read("*a"))); assert(file:close())
		local Pair = helpers.load_module("modules.shortcuts.key_combinations")
		context.is_paused = function() return false end
		context.gestures.is_assignable = function() return false end
		context.gestures.capture_parameter_source_guard = function() return function() return true end end
		local owner = Pair.new({keys = context.tap_holds.key_catalog(), hold_picker = defaults.tap_hold.hold_picker,
			route = function() return "/controlled/menu-certification.toml" end,
			files = {read_with_status = function() return nil, "absent" end},
			actions = context.gestures, is_paused = context.is_paused, changed = function() return true end})
		helpers.assert_true(Pair.set_instance(owner))
		package.loaded["infra.key_combinations_scope"] = {retry_restore = function() return true end,
			edit = function() error("menu-shape fixture cannot publish") end}
		package.loaded["ui.menu.key_combinations"] = nil
		-- Native delegates retain module tables. This fixture's new producer must
		-- share the exact current locale/manifest cohort used by its assertions.
		package.loaded["infra.i18n"], package.loaded["infra.manifest_menu"] = i18n, ManifestMenu
		helpers.load_module("ui.gesture_conflicts")
		local built = with_live_source(context, function()
			return with_api_source(function(builder) return builder.build(context) end)
		end)
		local source = assert(io.open(editor_source, "rb"))
		local content = source:read("*a"); assert(source:close())
		helpers.assert_eq(content, '{"hotstring_editor.default_section":"","future":{"keep":true}}\n',
			"the actual menu read preserves its independent editor source and foreign metadata")
		return built
	end)
	os.getenv = original_getenv
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	for name in pairs(package.loaded) do if all_previous[name] == nil then rawset(package.loaded, name, nil) end end
	for name, value in pairs(all_previous) do rawset(package.loaded, name, value) end
	rawset(_G, "i18n_safe", original_i18n_safe)
	-- Independent owned resources retire even when another native cleanup fails.
	-- Preserve the first exact native error and never return a successful build.
	local cleanup_ok, cleanup_error = true, nil
	local function cleanup(action)
		local retired, failure = pcall(action)
		if not retired and cleanup_ok then cleanup_ok, cleanup_error = false, failure end
	end
	if magic_path then cleanup(function() assert(os.remove(magic_path)) end) end
	if editor_directory then cleanup(function()
		local lfs = editor_fs
		for file in lfs.dir(editor_directory .. "/ergopti_plus") do
			if file ~= "." and file ~= ".." then assert(os.remove(editor_directory .. "/ergopti_plus/" .. file)) end
		end
		assert(lfs.rmdir(editor_directory .. "/ergopti_plus")); assert(lfs.rmdir(editor_directory))
	end) end
	helpers.assert_true(rawequal(rawget(_G, "i18n_safe"), original_i18n_safe))
	for _, name in ipairs(names) do helpers.assert_true(rawequal(rawget(package.loaded, name), saved[name]), name) end
	helpers.assert_true(rawequal(os.getenv, original_getenv))
	if not cleanup_ok then error(cleanup_error, 0) end
	if not ok then error(rows, 0) end
	return rows
end

--- Composes both genuine native source owners for the whole-tray fixture.
local function build_full_menu(context)
	return build_fixture_menu(context)
end

--- A menu context complete enough for every submenu to build.
---
--- Stubs rather than real modules: this test asks whether the BUILDER renders
--- what the manifest declares, and a real module that happens to be unavailable
--- on the test host would answer a different question — one about the host.
--- @return table
local function full_context()
	local function noop() end
	return {
		_version = "9.9.9",
		-- The API backend reaches the real provider-list builder. Without this
		-- collaborator the whole-tray fixture takes the unavailable-LLM branch
		-- before any declared API control can be rendered.
		llm = {
			is_enabled  = function() return true end,
			toggle      = noop,
			get_backend = function() return "api" end,
			set_backend = noop,
		},
		config = {
			get_groups         = function() return {} end,
			is_group_enabled   = function() return true end,
			toggle_group       = noop,
			is_section_enabled = function() return true end,
			toggle_section     = noop,
			set_all_sections   = noop,
			get_category       = function() return nil end,
			reload             = noop,
			enable_all         = noop,
			disable_all        = noop,
		},
		shortcuts = {
			is_enabled          = function() return true end,
			toggle              = noop,
			is_caps_word_active = function() return false end,
			toggle_caps_word    = noop,
			transform_uppercase = noop,
			transform_lowercase = noop,
			transform_titlecase = noop,
			select_word         = noop,
			select_line         = noop,
			paste_plain         = noop,
			wrap_selection      = noop,
			get_wrap_pairs      = function() return { ["("] = { left = "(", right = ")" } } end,
		},
		gestures = {
			-- The cached native status producer already consumed these collaborators.
			-- A neutral reader and genuine defaults describe fixture state only.
			DEFAULT_GESTURES = require("modules.gestures.manager").DEFAULT_GESTURES,
			is_reading     = function() return false end,
			get_action_label = require("modules.gestures.manager").get_action_label,
			is_enabled     = function() return true end,
			toggle         = noop,
			get_action     = function() return nil end,
			set_action     = noop,
			get_slots      = function() return {} end,
			get_sg_names   = function() return {} end,
		},
		-- `keylogger`, which is what _build_metrics reads. Named `metrics` in a
		-- first draft, and the metrics submenu then collapsed to "(métriques non
		-- disponibles)" — three manifest rows reported missing for a reason that
		-- was in the stub, not the driver.
		keylogger = {
			is_enabled        = function() return true end,
			toggle            = noop,
			get_session_stats = function() return { keystrokes = 0, words = 0, duration_ms = 0 } end,
			get_wpm           = function() return 0 end,
			get_ngrams        = function() return {} end,
			get_app_stats     = function() return {} end,
			get_privacy_state = function() return {} end,
			flush             = noop,
		},
		-- The tap-hold manager (platform/remap/tap_hold_manager). It replaced the
		-- kanata stub on 2026-09-24, when the tap-holds moved into the daemon:
		-- without it _build_tap_holds renders a disabled title and every row the
		-- manifest declares in tap_holds_menu goes unchecked.
		tap_holds = {
			is_enabled    = function() return true end,
			file_enabled  = function() return true end,
			set_enabled   = noop,
			keys          = function() return {} end,
			-- The shared builder, so every hold picker holds at least « none ».
			hold_options  = function() return require("tap_hold.hold_options").build({}) end,
			tap_actions   = function() return {} end,
			-- The shipped catalogue, so both hand lists have their rows.
			key_catalog   = function()
				return require("tap_hold.key_catalog").load(
					require("infra.paths").shared("tap_hold/defaults.toml"), "linux")
			end,
		},
		dyn_hotstrings = {
			is_enabled      = function() return true end,
			set_enabled     = noop,
			get_rules_count = function() return 0 end,
			active_count    = function() return 0 end,
			rule_families   = function() return {} end,
			set_rule_enabled = noop,
		},
	}
end




-- =================================================================
-- =================================================================
-- ======= 1/ Every declared row is on screen ======================
-- =================================================================
-- =================================================================

helpers.describe("menu certification: the manifest's rows are rendered", function()

	local built = nil
	local titles = nil

	helpers.before_each(function()
		if built then return end
		built = build_full_menu(full_context())
		titles = {}
		for _, title in ipairs(all_titles(built)) do titles[title] = true end
	end)

	helpers.it("builds a tray at all", function()
		helpers.assert_true(#built > 0, "an empty tray means everything below asserts nothing")
		helpers.assert_true(#all_titles(built) > 40,
			"the menu is dozens of rows deep; a handful means most submenus refused "
				.. "to build and the coverage below is measuring their absence")
	end)

	helpers.it("renders every action, group and header the manifest promises Linux", function()
		local root = ManifestMenu and ManifestMenu.get_root() or nil
		helpers.assert_not_nil(root, "the manifest must load, or this test checks nothing")

		-- The complete fixture has no configured key, so these independent captions
		-- name the native tap and absent hold. Provider templates format their rows.
		local fixture_captions = {
			tap_hold_key_tap_caption = i18n.get("tap_hold.tap.none"),
			tap_hold_key_hold_caption = i18n.get("tap_hold.hold.none"),
			tap_hold_key_delay_caption = "0 ms",
			personal_default_label = i18n.get("common.none"),
			-- The genuine source scope above owns these independently chosen neutral values.
			agent_system_backend_current_caption = i18n.get("menu.agent.off"),
			agent_system_model_caption = "",
			agent_disabled_apps_count = "0",
		}
		local checked, missing = 0, {}
		for menu_key in pairs(root) do
			local rows = ManifestMenu.get_array(menu_key)
			if type(rows) == "table" then
				for _, row in ipairs(rows) do
					local kind = row.type or ""
					if RENDERED_TYPES[kind] and visible(row) and type(row.i18n) == "string" then
						checked = checked + 1
						-- The renderer decorates a section header — `i18n.section`, not
						-- `i18n.get` — so comparing against the bare translation looks for
						-- a string the menu never contains. Resolved the same way the
						-- renderer resolves it, which is the only comparison that means
						-- anything.
						local label = (kind == "section_header")
							and i18n.section(row.i18n)
							or i18n.get(row.i18n)
						if row.id == "magic_key_source_heading" then
							label = label .. " : " .. i18n.get("menu.layout.magic_key_source.auto")
						end
						if row.caption_getter ~= nil then
							local caption = fixture_captions[row.caption_getter]
							helpers.assert_type(caption, "string", "every declared caption needs independent fixture state")
							if row.caption_format == "numbered" then
								-- Independently fill the declared old one-value caption; native bytes stay literal.
								label = label:gsub("{1}", function() return caption end)
							elseif row.caption_layout == "prefix" then
								helpers.assert_type(row.caption_joiner, "string")
								label = label .. row.caption_joiner .. caption
							elseif row.caption_layout == "suffix" then
								helpers.assert_type(row.caption_joiner, "string")
								label = caption .. row.caption_joiner .. label
							else label = string.format(label, caption) end
						end
						if not titles[label] then
							missing[#missing + 1] = menu_key .. "/" .. (row.id or row.i18n)
						end
					end
				end
			end
		end

		helpers.assert_true(checked > 0,
			"no row was examined — the projection is broken, not the menu, and a "
				.. "check that silently examines nothing is the failure this exists "
				.. "to prevent")
		helpers.assert_eq(#missing, 0,
			"the manifest declares these for Linux and the tray does not show them: "
				.. table.concat(missing, ", ")
				.. ". A row that is declared, handled and invisible passes every gate "
				.. "that reads only the manifest and the source.")
	end)

	helpers.it("does not advertise per-application settings without a profile model", function()
		local rows = ManifestMenu.get_array("apps_menu") or {}
		for _, row in ipairs(rows) do
			helpers.assert_true(not (visible(row) and row.id == "apps_per_app_config"),
				"Linux must not promise per-app settings until app identity, persistence, "
					.. "focus application, and restart restoration are implemented")
		end
	end)

	helpers.it("opens the personal-information editor from the production menu", function()
		local context = full_context()
		local opened = nil
		context.webview = {
			show = function(app_name)
				opened = app_name
				return true
			end,
		}
		local row = find_item(build_full_menu(context), i18n.get("menu.shortcuts.edit_personal_info"))
		helpers.assert_not_nil(row, "the shared editor must have a production caller")
		helpers.assert_true(type(row.fn) == "function")
		row.fn()
		helpers.assert_eq(opened, "personal_info_editor")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ No submenu is a dead end =============================
-- =================================================================
-- =================================================================

helpers.describe("menu certification: no empty submenu", function()

	helpers.it("gives every submenu at least one row", function()
		local empty = {}

		local function walk(items, path)
			for _, item in ipairs(items or {}) do
				if type(item.menu) == "table" then
					local where = path .. "/" .. tostring(item.title)
					if #item.menu == 0 then empty[#empty + 1] = where end
					walk(item.menu, where)
				end
			end
		end
		walk(build_full_menu(full_context()), "")

		helpers.assert_eq(#empty, 0,
			"a submenu that opens onto nothing is worse than a missing one: the user "
				.. "cannot tell it apart from a feature that failed to load. "
				.. table.concat(empty, ", "))
	end)

end)


helpers.describe("menu certification: actual API context reachability", function()

	helpers.it("reaches the genuine provider children without running mutation callbacks", function()
		local context = full_context()
		local mutations = 0
		context.llm.toggle = function() mutations = mutations + 1 end
		context.llm.set_backend = function() mutations = mutations + 1 end
		helpers.assert_eq(context.llm.get_backend(), "api")
		with_api_source(function(mb)
			local menu = mb.build(context)
			local remote = require("modules.llm.api_remote")
			local entries = require("modules.llm.api_entries")
			local add = find_item(menu, i18n.get("menu.llm.api_add_entry"))
			helpers.assert_not_nil(add, "the complete context must reach the real API provider group")
			helpers.assert_type(add.menu, "table")
			local providers = remote.providers()
			helpers.assert_true(#providers >= 16, "the actual shipped cloud catalogue must be reached")
			helpers.assert_eq(#add.menu, #providers)
			for index, provider in ipairs(providers) do
				helpers.assert_eq(add.menu[index].title, "➕ " .. provider.label)
				helpers.assert_type(add.menu[index].fn, "function")
			end
			helpers.assert_eq(add.menu[1].title, "➕ OpenAI")
			helpers.assert_eq(add.menu[2].title, "➕ Anthropic")
			helpers.assert_eq(add.menu[3].title, "➕ Google Gemini")
			helpers.assert_true(rawequal(remote, package.loaded["modules.llm.api_remote"]))
			helpers.assert_true(rawequal(entries, package.loaded["modules.llm.api_entries"]))
			helpers.assert_eq(mutations, 0, "building the whole tray must not change the runtime backend")
		end)
	end)

	helpers.it("keeps the genuine unavailable branch separate from the complete API context", function()
		local context = full_context()
		context.llm = nil
		local menu = build_full_menu(context)
		helpers.assert_nil(find_item(menu, i18n.get("menu.llm.api_add_entry")))
		helpers.assert_not_nil(find_item(menu, i18n.get("menu.llm.unavailable")))
		helpers.assert_not_nil(find_item(menu, i18n.get("menu.llm.ollama_start_hint")))
	end)

end)


helpers.describe("menu certification: private API source lifecycle", function()

	helpers.it("restores absent, false and genuine previous owners after successful and raised builds", function()
		local original, actual = {}, {}
		for _, name in ipairs(API_SOURCE_MODULES) do
			original[name] = rawget(package.loaded, name)
			actual[name] = require(name)
		end
		local ok, detail = pcall(function()
			for _, mode in ipairs({ "absent", "false", "existing" }) do
				local expected = {}
				for _, name in ipairs(API_SOURCE_MODULES) do
					if mode == "false" then expected[name] = false end
					if mode == "existing" then expected[name] = actual[name] end
					rawset(package.loaded, name, expected[name])
				end
				local menu = build_full_menu(full_context())
				helpers.assert_not_nil(find_item(menu, i18n.get("menu.llm.api_add_entry")))
				local private_path
				local succeeded, raised = pcall(function()
					with_api_source(function(builder, entries, path)
						private_path = path
						helpers.assert_eq(entries.path(), path)
						helpers.assert_eq(#entries.list(), 0)
						helpers.assert_not_nil(find_item(builder.build(full_context()), i18n.get("menu.llm.api_add_entry")))
						error("private API scope sentinel")
					end)
				end)
				helpers.assert_eq(succeeded, false)
				helpers.assert_contains(raised, "private API scope sentinel")
				helpers.assert_not_nil(private_path)
				helpers.assert_nil(io.open(private_path, "rb"))
				helpers.assert_nil(io.open(private_path .. ".corrupt", "rb"))
				for _, name in ipairs(API_SOURCE_MODULES) do
					helpers.assert_true(rawequal(rawget(package.loaded, name), expected[name]), name .. "/" .. mode)
				end
			end
		end)
		for _, name in ipairs(API_SOURCE_MODULES) do rawset(package.loaded, name, original[name]) end
		if not ok then error(detail, 0) end
	end)

	helpers.it("restores the genuine previous cohort after builder construction refuses", function()
		local previous = {}
		for _, name in ipairs(API_SOURCE_MODULES) do previous[name] = rawget(package.loaded, name) end
		local name = "ui.menu.menu_builder"
		local preload = rawget(package.preload, name)
		local private_path
		rawset(package.preload, name, function()
			private_path = assert(rawget(package.loaded, "modules.llm.api_entries")).path()
			error("private builder construction sentinel")
		end)
		local ok, detail = pcall(function() build_full_menu(full_context()) end)
		rawset(package.preload, name, preload)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(detail, "private builder construction sentinel")
		helpers.assert_not_nil(private_path)
		helpers.assert_nil(io.open(private_path, "rb"))
		helpers.assert_nil(io.open(private_path .. ".corrupt", "rb"))
		for _, module_name in ipairs(API_SOURCE_MODULES) do
			helpers.assert_true(rawequal(rawget(package.loaded, module_name), previous[module_name]), module_name)
		end
	end)

end)


-- Actual inert absent-module projections, preserving the original whole-tray prefix.
local function absent_module_corpus()
	local path = require("infra.paths").shared("tests/corpus/menus/linux_absent_modules.json")
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return assert(require("json").decode(bytes))
end

local function with_absent_current(scenario)
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }
	local prior = {}; for _, name in ipairs(names) do prior[name] = rawget(package.loaded, name) end
	local native = require("infra.i18n")
	helpers.assert_true(rawequal(native, i18n), "the original caption reader is the genuine current cohort")
	helpers.assert_true(rawequal(require("infra.manifest_menu"), ManifestMenu))
	local before = native.get_locale()
	local owner = { pending = function() return false end }
	assert(native.scope_acquire(owner))
	local receipt = assert(native.scope_capture(owner))
	local ok, result = xpcall(function()
		assert(native.scope_apply(owner, receipt, "en"))
		return scenario()
	end, debug.traceback)
	assert(native.scope_restore(owner, receipt))
	assert(native.scope_release(owner)); assert(native.scope_forget(owner, receipt))
	helpers.assert_eq(native.get_locale(), before, "the genuine predecessor locale is restored")
	for _, name in ipairs(names) do helpers.assert_true(rawequal(rawget(package.loaded, name), prior[name]), name) end
	if not ok then error(result, 0) end
	return result
end


-- Earlier suite cases can replace the backend under a cached caption reader.
-- Own a fresh, initialized native cohort for these new projections, then restore
-- the exact predecessor modules and file-local readers even if construction raises.
local function with_absent_english(scenario)
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }
	local prior = {}; for _, name in ipairs(names) do prior[name] = rawget(package.loaded, name) end
	local prior_i18n, prior_manifest = i18n, ManifestMenu
	local ok, result = xpcall(function()
		for _, name in ipairs(names) do rawset(package.loaded, name, nil) end
		local native = require("infra.i18n")
		native.init()
		i18n = native
		ManifestMenu = require("infra.manifest_menu")
		return with_absent_current(scenario)
	end, debug.traceback)
	i18n, ManifestMenu = prior_i18n, prior_manifest
	for _, name in ipairs(names) do rawset(package.loaded, name, prior[name]) end
	helpers.assert_true(rawequal(i18n, prior_i18n), "the original caption reader is restored")
	helpers.assert_true(rawequal(ManifestMenu, prior_manifest), "the original renderer is restored")
	for _, name in ipairs(names) do helpers.assert_true(rawequal(rawget(package.loaded, name), prior[name]), name) end
	if not ok then error(result, 0) end
	return result
end

local function absent_context()
	-- No data owner is constructed to manufacture absence. Native ctx fields are absent.
	return { _version = "9.9.9", on_menu_changed = function() error("inert status must not mutate") end }
end

helpers.describe("linux-absent-module templates: actual native branches", function()
	for _, vector in ipairs(absent_module_corpus().owners) do
		local contract = vector
		helpers.it(contract.owner .. " consumes its exact disabled declaration and refuses withdrawn status", function()
			with_absent_english(function()
				local root = ManifestMenu.get_root()
				local original = root[contract.section]
				helpers.assert_type(original, "table")
				local function inspect()
					return with_api_source(function(builder, entries, path)
						local function physical_source()
							local file = assert(io.open(path, "rb"))
							local bytes = assert(file:read("*a")); assert(file:close())
							return bytes
						end
						local before, changes = physical_source(), 0
						local context = absent_context()
						context.on_menu_changed = function() changes = changes + 1 end
						local menu = builder.build(context)
						helpers.assert_eq(changes, 0, "inert status construction cannot publish a native change")
						helpers.assert_eq(physical_source(), before, "the genuine private source is byte-exact")
						helpers.assert_nil(io.open(path .. ".corrupt", "rb"))
						helpers.assert_eq(entries.path(), path)
						return find_item(menu, i18n.get(contract.parent_key))
					end)
				end
				local row = assert(inspect())
				helpers.assert_eq(#row.menu, #contract.english)
				for index, caption in ipairs(contract.english) do
					helpers.assert_eq(row.menu[index].title, caption)
					helpers.assert_eq(row.menu[index].disabled, true)
					helpers.assert_nil(row.menu[index].fn)
				end
				local marker = { type = "label", id = "hand_absent_marker", i18n = "button.cancel", platforms = { "linux" }, unavailable = "hide" }
				local ok, detail = xpcall(function()
					root[contract.section] = { marker }
					local changed = assert(inspect())
					helpers.assert_eq(#changed.menu, 1)
					helpers.assert_eq(changed.menu[1].title, "Cancel")
					helpers.assert_eq(changed.menu[1].disabled, true)
					helpers.assert_nil(changed.menu[1].fn)
					root[contract.section] = nil
					helpers.assert_nil(inspect(), "withdrawn status must not be silently rebuilt in native source")
					root[contract.section] = { { type = "command", id = "hand_unbound_status", i18n = "button.cancel" } }
					helpers.assert_nil(inspect(), "unbound command cannot replace inert unavailable status")
				end, debug.traceback)
				root[contract.section] = original
				if not ok then error(detail, 0) end
				local repaired = assert(inspect())
				helpers.assert_eq(#repaired.menu, #contract.english)
				for index, caption in ipairs(contract.english) do
					helpers.assert_eq(repaired.menu[index].title, caption)
					helpers.assert_eq(repaired.menu[index].disabled, true)
					helpers.assert_nil(repaired.menu[index].fn)
				end
			end)
		end)
	end

	helpers.it("projects exactly the true Linux-only status role through the genuine shared renderer", function()
		with_absent_english(function()
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(require("menu.renderer").new({
					platform = platform,
					manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
					json_decode = require("json").decode,
					i18n = i18n,
					logger = require("logger.shim"),
				}))
				for _, contract in ipairs(absent_module_corpus().owners) do
					local rows = assert(renderer.template_rows(contract.section, {}, {}, {}))
					helpers.assert_eq(#rows, platform == "linux" and #contract.english or 0)
					for index, row in ipairs(rows) do
						helpers.assert_eq(row.label, contract.english[index])
						helpers.assert_eq(row.disabled, true)
						helpers.assert_nil(row.action)
					end
				end
			end
		end)
	end)

	helpers.it("restores its genuine French/English caption cohort after an exception", function()
		local before = i18n.get_locale()
		local ok, detail = pcall(function()
			with_absent_english(function() error("absent locale sentinel") end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(detail, "absent locale sentinel")
		helpers.assert_eq(i18n.get_locale(), before)
	end)

	helpers.it("retains the empty whole-tray contract when the actual shared renderer cannot load", function()
		with_api_source(function(_, entries, path)
			-- The already constructed genuine backend retains its private source owner.
			-- Only the new builder's optional renderer admission is withdrawn.
			helpers.assert_eq(entries.path(), path)
			local name, builder_name = "infra.manifest_menu", "ui.menu.menu_builder"
			local prior, preload = rawget(package.loaded, name), rawget(package.preload, name)
			local old_builder = rawget(package.loaded, builder_name)
			local ok, detail = xpcall(function()
				rawset(package.loaded, name, nil)
				rawset(package.preload, name, function() error("genuine renderer unavailable sentinel") end)
				rawset(package.loaded, builder_name, nil)
				local actual_builder = require(builder_name)
				helpers.assert_eq(#actual_builder.build(absent_context()), 0)
			end, debug.traceback)
			rawset(package.preload, name, preload); rawset(package.loaded, name, prior)
			rawset(package.loaded, builder_name, old_builder)
			helpers.assert_true(rawequal(rawget(package.loaded, name), prior))
			helpers.assert_true(rawequal(rawget(package.preload, name), preload))
			helpers.assert_true(rawequal(rawget(package.loaded, builder_name), old_builder))
			if not ok then error(detail, 0) end
		end)
	end)
end)


local function control_boundary_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/llm_control_boundaries.json"), "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return assert(require("json").decode(bytes))
end

--- Reuses the existing physical-source sandbox with genuine native preference/settings owners.
local function with_control_trigger_source(scenario)
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	Sandbox.with_config('# hand trigger source\n[llm]\nenabled = true\n[llm.models]\nselected = "api"\n'
		.. '[llm.trigger]\ndebounce_ms = 500\nfuture = "keep exact" # retained\n', function(path)
		local names = { "infra.llm_preferences", "modules.llm.trigger_settings" }
		local prior = {}; for _, name in ipairs(names) do prior[name] = rawget(package.loaded, name); rawset(package.loaded, name, nil) end
		local Paths = require("infra.config_paths")
		local original = Paths.config
		Paths.config = function(relative) helpers.assert_eq(relative, "config.toml"); return path end
		local ok, detail = xpcall(function()
			local settings = require("modules.llm.trigger_settings")
			scenario(settings, path, Sandbox)
		end, debug.traceback)
		Paths.config = original
		for _, name in ipairs(names) do rawset(package.loaded, name, prior[name]) end
		helpers.assert_true(rawequal(Paths.config, original))
		for _, name in ipairs(names) do helpers.assert_true(rawequal(rawget(package.loaded, name), prior[name]), name) end
		if not ok then error(detail, 0) end
	end)
end

helpers.describe("llm-control-boundaries: actual Linux trigger provider", function()
	helpers.it("retains the native debounce writer and shared privacy order around the boundary (llm-control-boundaries)", function()
		with_absent_english(function()
			with_control_trigger_source(function(settings, path, Sandbox)
				local expected = control_boundary_corpus()
				local boundary = expected.boundaries.trigger
				local root, original = ManifestMenu.get_root(), ManifestMenu.get_array(boundary.section)
				local context, changes = full_context(), 0
				context.on_menu_changed = function() changes = changes + 1 end
				local function build()
					return with_api_source(function(builder, entries, api_path)
						local source = Sandbox.read_bytes(api_path)
						local rows = builder.build(context)
						helpers.assert_eq(Sandbox.read_bytes(api_path), source)
						helpers.assert_nil(io.open(api_path .. ".corrupt", "rb"))
						helpers.assert_eq(entries.path(), api_path)
						return find_item(rows, i18n.get("menu.llm.trigger_menu_title"))
					end)
				end
				local row = assert(build())
				helpers.assert_eq(row.menu[1].title, expected.trigger_debounce_english)
				helpers.assert_eq(row.menu[2].title, "-")
				helpers.assert_not_nil(find_item(row.menu, i18n.get("menu.llm.disable_url_bars")))
				helpers.assert_not_nil(find_item(row.menu, i18n.get("menu.llm.disable_password_fields")))
				local before = Sandbox.read_bytes(path)
				local ok, detail = xpcall(function()
					root[boundary.section] = { { type = "label", id = "hand_trigger_boundary", i18n = expected.marker_key,
						platforms = { "ahk", "linux" }, unavailable = "hide" } }
					row = assert(build()); helpers.assert_eq(row.menu[2].title, expected.marker_english)
					helpers.assert_eq(row.menu[2].disabled, true); helpers.assert_nil(row.menu[2].fn)
					helpers.assert_eq(changes, 0); helpers.assert_eq(Sandbox.read_bytes(path), before)
					local preset = assert(find_item(row.menu[1].menu, "50 ms"))
					helpers.assert_type(preset.fn, "function"); helpers.assert_nil(preset.fn())
					helpers.assert_eq(settings.get("debounce_ms"), 50); helpers.assert_eq(changes, 1)
					helpers.assert_eq(Sandbox.read_bytes(path), before:gsub("debounce_ms = 500", "debounce_ms = 50"))
					root[boundary.section] = nil
					helpers.assert_nil(build(), "withdrawn boundary refuses the genuine native trigger child")
					root[boundary.section] = { { type = "command", id = "hand_unbound_trigger_boundary", i18n = expected.marker_key } }
					helpers.assert_nil(build())
					helpers.assert_eq(changes, 1)
					helpers.assert_eq(Sandbox.read_bytes(path), before:gsub("debounce_ms = 500", "debounce_ms = 50"))
				end, debug.traceback)
				root[boundary.section] = original
				if not ok then error(detail, 0) end
				row = assert(build()); helpers.assert_eq(row.menu[2].title, "-")
				helpers.assert_eq(changes, 1)
			end)
		end)
	end)

	helpers.it("projects independent platform boundaries using the actual initialized renderer (llm-control-boundaries)", function()
		with_absent_english(function()
			local expected = control_boundary_corpus()
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(require("menu.renderer").new({ platform = platform,
					manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
					json_decode = require("json").decode, i18n = i18n, logger = require("logger.shim") }))
				for _, boundary in pairs(expected.boundaries) do
					helpers.assert_eq(renderer.template_rows(boundary.section, {}, {}, {}), boundary.projections[platform])
				end
			end
		end)
	end)

	helpers.it("restores original source-routing and module identities after raised native construction (llm-control-boundaries)", function()
		local names = { "infra.llm_preferences", "modules.llm.trigger_settings" }
		local prior = {}; for _, name in ipairs(names) do prior[name] = rawget(package.loaded, name) end
		local Paths = require("infra.config_paths"); local original = Paths.config
		local path
		local ok, detail = pcall(function()
			with_control_trigger_source(function(_, owned) path = owned; error("trigger boundary inverse sentinel") end)
		end)
		helpers.assert_eq(ok, false); helpers.assert_contains(detail, "trigger boundary inverse sentinel")
		helpers.assert_true(rawequal(Paths.config, original))
		for _, name in ipairs(names) do helpers.assert_true(rawequal(rawget(package.loaded, name), prior[name]), name) end
		helpers.assert_nil(io.open(path, "rb"))
	end)
end)


helpers.describe("selection boundary fragments in the complete native tray", function()
	local path = require("infra.paths").shared("tests/corpus/menus/linux_selection_boundaries.json")
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	local corpus = assert(require("json").decode(bytes))

	helpers.it("keeps the independently declared nine-row selection order without invoking an action", function()
		with_absent_english(function()
			local context, changes = full_context(), 0
			context.on_menu_changed = function() changes = changes + 1 end
			local parent = assert(find_item(build_full_menu(context), i18n.get(corpus.parent_key)))
			local first
			for index, row in ipairs(parent.menu) do
				if row.title == corpus.selection_child_order[1].english then first = index; break end
			end
			helpers.assert_type(first, "number")
			for offset, expected in ipairs(corpus.selection_child_order) do
				local row = parent.menu[first + offset - 1]
				helpers.assert_type(row, "table")
				helpers.assert_eq(row.title, expected.separator and "-" or expected.english)
				if expected.separator then helpers.assert_nil(row.fn) end
			end
			helpers.assert_eq(changes, 0)
		end)
	end)

	helpers.it("follows both actual fragment captions at their exact whole-tray positions", function()
		with_absent_english(function()
			local root = ManifestMenu.get_root()
			local originals = { root.selection_case_boundary, root.selection_helper_boundary }
			local sections = { "selection_case_boundary", "selection_helper_boundary" }
			local ok, detail = xpcall(function()
				for _, section in ipairs(sections) do
					root[section] = { { type = "label", id = "selection_tray_marker",
						i18n = corpus.marker_key, platforms = { "linux" }, unavailable = "hide" } }
				end
				local parent = assert(find_item(build_full_menu(full_context()), i18n.get(corpus.parent_key)))
				local first
				for index, row in ipairs(parent.menu) do
					if row.title == corpus.selection_child_order[1].english then first = index; break end
				end
				helpers.assert_type(first, "number")
				for offset, expected in ipairs(corpus.selection_child_order) do
					local row = parent.menu[first + offset - 1]
					helpers.assert_eq(row.title, expected.separator and corpus.marker_english or expected.english)
					if expected.separator then
						helpers.assert_eq(row.disabled, true)
						helpers.assert_nil(row.fn)
					end
				end
			end, debug.traceback)
			for index, section in ipairs(sections) do root[section] = originals[index] end
			if not ok then error(detail, 0) end
		end)
	end)
end)


require("test.menu_native_child_rows").run(helpers, require("infra.manifest_menu"))

helpers.describe("magic key source: actual complete tray provider", function()
	helpers.it("(magic-key-source-family) native candidate rows preserve file-backed choices and declaration withdrawal", function()
		local names = { "modules.hotstrings.magic_key_source", "infra.hotstring_preferences" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		local path = os.tmpname()
		local file = assert(io.open(path, "wb")); assert(file:write('[hotstrings]\nmagic_key_source = "KeyJ"\nfuture_setting = "retain"\n')); assert(file:close())
		local declaration = ManifestMenu.get_root()
		local child = declaration.magic_key_source_children
		local ok, err = pcall(function()
			local preferences = require("infra.hotstring_preferences"); assert(preferences._set_file_for_test(path))
			local Source = require("modules.hotstrings.magic_key_source")
			local changes, deferred = 0, {}
			Source.init({ is_active = function() return true end, replace_on = function() return true end,
				magic_key = function() return "★" end, can_type = function() return true end,
				type_text = function() error("menu construction cannot type") end,
				dispatch_char = function() error("menu construction cannot dispatch") end,
				end_selection = function() end, can_capture = function() return true end,
				key_text = function(code) return code == 36 and "j" or nil end,
				defer = function(fn) deferred[#deferred + 1] = fn; return true end })
			local context = full_context(); context.magic_key_source = Source
			context.on_menu_changed = function() changes = changes + 1 end
			local label = i18n.get("menu.layout.magic_key_source") .. " : j   (KeyJ)"
			local heading = assert(find_item(build_full_menu(context), label))
			helpers.assert_eq(heading.menu[1].title, i18n.get("menu.layout.magic_key_source.capture"))
			helpers.assert_eq(heading.menu[2].title, "-")
			helpers.assert_eq(heading.menu[3].title, i18n.get("menu.layout.magic_key_source.auto"))
			helpers.assert_eq(heading.menu[4].title, "-")
			helpers.assert_eq(#heading.menu, #Source.resolver().candidates() + 4)
			helpers.assert_eq(changes, 0)
			local retained = heading.menu[3].fn
			declaration.magic_key_source_children = nil
			helpers.assert_nil(find_item(build_full_menu(context), label), "actual native provider cannot reconstruct the withdrawn family")
			helpers.assert_eq(retained(), false)
			helpers.assert_eq(Source.get(), "KeyJ", "withdrawal never enters the genuine native writer")
			helpers.assert_eq(changes, 0)
			declaration.magic_key_source_children = child
			local repaired = assert(find_item(build_full_menu(context), label))
			repaired.menu[3].fn()
			helpers.assert_eq(Source.get(), "auto")
			helpers.assert_eq(changes, 1)
			file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
			helpers.assert_eq(bytes, '[hotstrings]\nfuture_setting = "retain"\n', "actual native chooser publishes its neutral default sparsely and preserves the unknown neighbor")
		end)
		declaration.magic_key_source_children = child
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		for _, suffix in ipairs({ "", ".tmp" }) do
			local existing = io.open(path .. suffix, "rb")
			if existing then assert(existing:close()); assert(os.remove(path .. suffix)) end
		end
		if not ok then error(err, 0) end
	end)
end)

require("test.menu_dynamic_caption_contract").register(helpers, "linux")

require("test.menu_caption_layout_contract").register(helpers, "linux")

require("test.menu_group_row_contract").register(helpers, "linux")

require("test.menu_command_group_affix_contract").register(helpers, "linux")


helpers.describe("Whole LLM tray genuine live owner scope", function()
	for _, prior_kind in ipairs({ "absent", "false", "existing" }) do
		for _, raises in ipairs({ false, true }) do
			helpers.it("restores " .. prior_kind .. " live owner modules after " .. (raises and "raise" or "success"), function()
				local originals = {}; for _, name in ipairs(LIVE_SOURCE_MODULES) do originals[name] = rawget(package.loaded, name) end
				local seeds = {}
				local context = full_context()
				local before_read, before_write = context.llm.get_live, context.llm.set_live
				local ok, detail = xpcall(function()
					for _, name in ipairs(LIVE_SOURCE_MODULES) do
						local value
						if prior_kind == "false" then value = false elseif prior_kind == "existing" then value = { sentinel = name } end
						seeds[name] = value; rawset(package.loaded, name, value)
					end
					local ran = false
					local survived, result = pcall(function()
						return with_live_source(context, function()
							ran = true
							local engine = assert(rawget(package.loaded, "modules.llm.prediction_engine"))
							helpers.assert_true(rawequal(context.llm.get_live, engine.get_live))
							helpers.assert_true(rawequal(context.llm.set_live, engine.set_live))
							helpers.assert_nil(context.llm.get_live())
							helpers.assert_eq(context.llm.set_live(nil), true)
							local values, source = require("infra.llm_preferences").get_many({ "llm.profiles.num_predictions" })
							helpers.assert_eq(source.content, "")
							helpers.assert_type(values["llm.profiles.num_predictions"], "number")
							if raises then error("actual live scope sentinel") end
							return "actual live scope result"
						end)
					end)
					helpers.assert_eq(ran, true)
					helpers.assert_eq(survived, not raises)
					if raises then helpers.assert_contains(result, "actual live scope sentinel")
					else helpers.assert_eq(result, "actual live scope result") end
					for _, name in ipairs(LIVE_SOURCE_MODULES) do helpers.assert_true(rawequal(rawget(package.loaded, name), seeds[name]), name) end
					helpers.assert_true(rawequal(context.llm.get_live, before_read))
					helpers.assert_true(rawequal(context.llm.set_live, before_write))
				end, debug.traceback)
				for _, name in ipairs(LIVE_SOURCE_MODULES) do rawset(package.loaded, name, originals[name]) end
				if not ok then error(detail, 0) end
			end)
		end
	end
end)

-- The actual initialized locale owner and root renderer, restored as one private cohort.
local function language_parent_native(language, scenario)
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = rawget(package.loaded, name) end
	local previous_i18n, previous_manifest = i18n, ManifestMenu
	local ok, detail = xpcall(function()
		for _, name in ipairs(names) do rawset(package.loaded, name, nil) end
		i18n = require("infra.i18n"); i18n.init()
		local owner = { pending = function() return false end }
		assert(i18n.scope_acquire(owner))
		local receipt = assert(i18n.scope_capture(owner))
		assert(i18n.scope_apply(owner, receipt, language))
		assert(i18n.scope_release(owner)); assert(i18n.scope_forget(owner, receipt))
		ManifestMenu = require("infra.manifest_menu")
		local path = require("infra.paths").shared("tests/corpus/menus/language_parent.json")
		local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
		local corpus = assert(require("json").decode(bytes))
		assert(i18n.get("menu.global.language") == corpus.parent[language], "genuine locale file is initialized")
		return with_api_source(function(builder)
			return scenario(i18n, ManifestMenu, corpus, function(changed)
				return builder.build({ _version = "9.9.9", on_menu_changed = changed })
			end)
		end)
	end, debug.traceback)
	i18n, ManifestMenu = previous_i18n, previous_manifest
	for _, name in ipairs(names) do rawset(package.loaded, name, saved[name]) end
	for _, name in ipairs(names) do helpers.assert_true(rawequal(rawget(package.loaded, name), saved[name]), name .. " restored") end
	if not ok then error(detail, 0) end
end

helpers.describe("complete declared Language parent (Linux)", function()
	for _, code in ipairs({ "en", "fr" }) do
		local language = code
		helpers.it("retains full original hierarchy and same finished child in " .. language, function()
			language_parent_native(language, function(native, renderer, corpus, build)
				local original_list, original_group, original_set = native.list_locales, renderer.group_row, native.set_locale
				local calls, choices, changes, finished, supplied = 0, 0, 0, nil, nil
				local original_render = renderer.render_rows
				local ok, detail = xpcall(function()
					native.list_locales = function() calls = calls + 1; return original_list() end
					renderer.group_row = function(key, id, child, getters)
						if key == "top_level" and id == "language" then finished = child end
						return original_group(key, id, child, getters)
					end
					renderer.render_rows = function(rows, key)
						if key == "language_menu" then supplied = rows end
						return original_render(rows, key)
					end
					native.set_locale = function(...) choices = choices + 1; return original_set(...) end
					local row = assert(find_item(build(function() changes = changes + 1 end), corpus.parent[language]))
					helpers.assert_eq(calls, 1, "actual complete locale collection captured once")
					helpers.assert_eq(choices, 0, "no action during construction")
					helpers.assert_true(rawequal(row.menu, finished), "GroupRow retains the actual completed child")
					helpers.assert_eq(#row.menu, #corpus.locales, "complete original hierarchy")
					local active
					for index, expected in ipairs(corpus.locales) do
						local child = row.menu[index]
						helpers.assert_eq(child.title, expected.linux, "handwritten physical order and caption")
						helpers.assert_eq(child.checked, expected.code == language, "original active/inactive check states")
						helpers.assert_type(child.fn, "function", "original native action retained")
						helpers.assert_true(rawequal(child.fn, supplied[index].action), "admitted original callback identity retained")
						if expected.code == language then active = child end
					end
					assert(active).fn()
					helpers.assert_eq(choices, 1, "actual original callback reaches the genuine setter")
					helpers.assert_eq(changes, 1, "unchanged successful choice preserves its original redraw")
					helpers.assert_eq(native.get_locale(), language, "current identity stays exact")
				end, debug.traceback)
				native.list_locales, renderer.group_row, native.set_locale = original_list, original_group, original_set
				renderer.render_rows = original_render
				if not ok then error(detail, 0) end
			end)
		end)
	end
	helpers.it("retains a declared parent for a genuine valid empty collection", function()
		language_parent_native("en", function(native, _, corpus, build)
			local original = native.list_locales
			local ok, detail = xpcall(function()
				native.list_locales = function() return {} end
				local row = assert(find_item(build(), corpus.parent.en))
				helpers.assert_type(row.menu, "table")
				helpers.assert_eq(#row.menu, 0, "valid empty is not a fabricated locale")
			end, debug.traceback)
			native.list_locales = original
			if not ok then error(detail, 0) end
		end)
	end)
	for _, variant in ipairs({ "nil", "scalar", "malformed", "sparse", "child-withdrawn", "parent-withdrawn", "parent-wrong-kind" }) do
		local name = variant
		helpers.it("refuses " .. name .. " without a Language parent", function()
			language_parent_native("en", function(native, renderer, corpus, build)
				local root, original = renderer.get_root(), native.list_locales
				local child, parent = root.language_menu, nil
				for _, row in ipairs(root.top_level) do if row.id == "language" then parent = row; break end end
				local kind, id = parent.type, parent.id
				local ok, detail = xpcall(function()
					if name == "nil" then native.list_locales = function() return nil end
					elseif name == "scalar" then native.list_locales = function() return false end
					elseif name == "malformed" then native.list_locales = function() return { false } end
					elseif name == "sparse" then native.list_locales = function() return { [2] = "en" } end
					elseif name == "child-withdrawn" then root.language_menu = {}
					elseif name == "parent-withdrawn" then parent.id = "withdrawn-language"
					else parent.type = "label" end
					local rows = build()
					helpers.assert_type(rows, "table", "unrelated real root survives refusal")
					helpers.assert_nil(find_item(rows, corpus.parent.en), "no undeclared/nil-to-empty success")
				end, debug.traceback)
				root.language_menu, parent.type, parent.id, native.list_locales = child, kind, id, original
				if not ok then error(detail, 0) end
			end)
		end)
	end
end)


helpers.describe("Language completed-child admission (linux)", function()
	for _, mode in ipairs({ "deep", "nil", "scalar" }) do
		local case = mode
		helpers.it("keeps finished deep identity and refuses incomplete native result: " .. case, function()
			language_parent_native("en", function(_, renderer, corpus, build)
				local original, finished = renderer.render_rows, nil
				local ok, detail = xpcall(function()
					renderer.render_rows = function(rows, key)
						local native = original(rows, key)
						if key ~= "language_menu" then return native end
						if case == "nil" then return nil end
						if case == "scalar" then return false end
						assert(type(native) == "table" and #native == 21)
						local leaf = { title = "finished-leaf", fn = native[1].fn }
						local subtree = { leaf }
						for _ = 1, 8 do subtree = { { title = "finished-level", menu = subtree } } end
						native[1].menu = subtree
						finished = native
						return native
					end
					local parent = find_item(build(), corpus.parent.en)
					if case == "deep" then
						helpers.assert_true(parent ~= nil, "finished genuine native result remains attachable")
						helpers.assert_true(rawequal(parent.menu, finished), "no secondary native-child depth walk or copy")
						local child = parent.menu[1].menu
						for _ = 1, 8 do child = child[1].menu end
						helpers.assert_eq(child[1].title, "finished-leaf", "all finished deep levels retained")
						helpers.assert_true(rawequal(child[1].fn, finished[1].fn), "finished callback identity retained")
					else
						helpers.assert_nil(parent, "failed native rendering never becomes a valid empty parent")
					end
				end, debug.traceback)
				renderer.render_rows = original
				if not ok then error(detail, 0) end
			end)
		end)
	end
end)

require("test.menu_command_literal_prefix_contract").register(helpers, "linux")

helpers.describe("Complete-menu gesture status fixture owns its native cohort", function()
	helpers.it("rebuilds the native producer against current locale and manifest despite a stale loaded producer", function()
		local previous = rawget(package.loaded, "ui.gesture_conflicts")
		local stale = { rows = function() error("a stale gesture producer cannot own this fixture") end }
		rawset(package.loaded, "ui.gesture_conflicts", stale)
		local ok, rows = pcall(build_full_menu, full_context())
		helpers.assert_true(rawequal(rawget(package.loaded, "ui.gesture_conflicts"), stale), "the exact preceding module owner is restored")
		rawset(package.loaded, "ui.gesture_conflicts", previous)
		if not ok then error(rows, 0) end
		helpers.assert_not_nil(find_item(rows, i18n.get("gestures.system.unknown")), "the real native unknown-status parent survives the complete tray")
	end)
	helpers.it("provides the original reader ABI and genuine complete native defaults without starting input", function()
		local context = full_context()
		helpers.assert_eq(context.gestures.is_reading(), false)
		helpers.assert_true(rawequal(context.gestures.DEFAULT_GESTURES, require("modules.gestures.manager").DEFAULT_GESTURES),
			"the fixture uses the actual current native slot inventory")
		helpers.assert_true(next(context.gestures.DEFAULT_GESTURES) ~= nil, "a fabricated empty inventory cannot satisfy the fixture")
		local rows = build_full_menu(context)
		helpers.assert_not_nil(find_item(rows, i18n.get("gestures.system.unknown")))
		helpers.assert_true(#all_titles(rows) > 40, "the original whole-menu row-count floor remains meaningful")
	end)
end)

require("test.menu_layout_caption_values_contract").register(helpers, "linux")

require("test.menu_numbered_caption_contract").register(helpers, "linux")
