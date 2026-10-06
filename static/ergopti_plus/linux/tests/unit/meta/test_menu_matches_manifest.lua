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

--- Builds the real tray with a scoped entries source, retaining native callbacks.
--- @param context table
--- @return table
local function build_full_menu(context)
	return with_api_source(function(builder) return builder.build(context) end)
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
						if row.caption_getter ~= nil then
							local caption = fixture_captions[row.caption_getter]
							helpers.assert_type(caption, "string", "every declared caption needs independent fixture state")
							label = string.format(label, caption)
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
