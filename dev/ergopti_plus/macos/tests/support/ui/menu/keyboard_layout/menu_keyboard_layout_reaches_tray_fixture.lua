--- tests/support/ui/menu/keyboard_layout/menu_keyboard_layout_reaches_tray_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_menu_keyboard_layout_reaches_tray
--- DESCRIPTION:
--- Prelude shared by the test_menu_keyboard_layout_reaches_tray_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The old assertions intentionally retain key-echo captions for unformatted rows.
--- Supply only genuine Layout format strings that the complete caption API now reads.
--- This is fixture input, never an expectation regenerated from the native producer.
local function install_legacy_layout_formats(translator)
	translator = translator or require("infra.i18n")
	local file = assert(io.open(helpers.shared("data/locales/en.json"), "rb"))
	local catalogue = assert(require("json").decode(file:read("*a")))
	assert(file:close())
	local original_get = translator.get
	translator.get = function(key)
		local format = catalogue[key]
		if type(key) == "string" and key:sub(1, #"menu.layout.") == "menu.layout."
			and type(format) == "string" and format:find("%s", 1, true) then return format end
		return original_get(key)
	end
end

--- Builds the layout row and renders it the way the tray root does.
--- @param ctx table Menu context.
--- @return table|nil rendered The materialised tray row.
local function tray_row(ctx)
	local layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
	install_legacy_layout_formats()
	local ManifestMenu = require("infra.manifest_menu")
	local item = layout.build(ctx)
	helpers.assert_true(type(item) == "table", "menu_keyboard_layout.build must return a row")
	return ManifestMenu.render_rows({ item }, "top_level")[1]
end

--- Collects every title in a rendered submenu.
--- @param rows table
--- @return table<string, boolean>
local function titles(rows)
	local set = {}
	for _, row in ipairs(rows or {}) do
		if type(row) == "table" and type(row.title) == "string" then set[row.title] = true end
	end
	return set
end

--- A context with live state and a magic-key section, as ui.menu.init supplies.
--- @return table
local function make_ctx()
	return {
		base_dir   = helpers.driver_root(),
		state      = { layout_pause_switch_enabled = true, hotstrings = { magickey = true } },
		applyTriggerChar = function(text) return text end,
		save_prefs = function() return true end,
		updateMenu = function() end,
		do_reload  = function() end,
		keymap     = {
			is_section_enabled = function() return true end,
			is_group_enabled   = function() return true end,
			get_sections       = function()
				return { { name = "replace", description = "Replace J with the magic key" } }
			end,
		},
	}
end


local function with_switch_frame(callback, labels)
	helpers.with_stub_scope({"ui.menu.menu_keyboard_layout", "infra.manifest_menu", "infra.i18n",
		"modules.keymap.input_sources", "modules.keymap.layout_install", "modules.keymap.layout_registry"}, function()
		local sources = helpers.load_with_stubs("modules.keymap.input_sources")
		local installer = require("modules.keymap.layout_install")
		local fixture = {records = {{id = "French", name = "French", selected = false}}, saves = 0, updates = 0, effects = 0}
		sources.list_active_keyboard_layouts = function() return fixture.records end
		sources.build_kl_name_to_tis_id = function() return fixture.mapping or {} end
		sources.resolve_installed_ergopti_version = function() return nil end
		installer.pick_latest_bundle = function() return fixture.latest end
		installer.highest_installed = function(directory)
			if directory == installer.SYSTEM_LAYOUTS_DIR then return fixture.system end
			return fixture.user
		end
		installer.bundle_variants = function() return fixture.variants or {} end
		local function forbidden() fixture.effects = fixture.effects + 1; error("Switching policy must not invoke TIS") end
		sources.set_input_source_async = forbidden
		installer.install_system = forbidden
		installer.install_user = forbidden
		package.loaded["modules.keymap.layout_registry"] = {picker = function() return fixture.custom or {layouts = {}, active = ""} end, select = forbidden}
		local translator = require("infra.i18n")
		local original_get = translator.get
		translator.get = function(key)
			if labels then return labels[key] or key end
			if key == "menu.layout.pause_picker_caption" then return "  ↳ " .. original_get("menu.layout.layout_on_pause") .. " : %s" end
			if key == "menu.layout.resume_picker_caption" then return "  ↳ " .. original_get("menu.layout.layout_on_resume") .. " : %s" end
			return original_get(key)
		end
		package.loaded["infra.manifest_menu"] = nil
		local binding = require("infra.manifest_menu")
		package.loaded["ui.menu.menu_keyboard_layout"] = nil
		local module = require("ui.menu.menu_keyboard_layout")
		local ctx = make_ctx()
		ctx.save_prefs = function() fixture.saves = fixture.saves + 1; return fixture.save_result ~= false end
		ctx.updateMenu = function() fixture.updates = fixture.updates + 1 end
		local function build()
			local item = module.build(ctx)
			if not item then return nil end
			return binding.render_rows({item}, "top_level")[1].menu
		end
		callback(build, fixture, binding, ctx)
		helpers.assert_eq(fixture.effects, 0, "Policy construction and selection must not dispatch TIS")
	end)
end

local function switch_row(rows, prefix)
	for _, row in ipairs(rows or {}) do if row.title:sub(1, #prefix) == prefix then return row end end
end

return {
	install_legacy_layout_formats = install_legacy_layout_formats,
	make_ctx = make_ctx,
	switch_row = switch_row,
	titles = titles,
	tray_row = tray_row,
	with_switch_frame = with_switch_frame,
}
