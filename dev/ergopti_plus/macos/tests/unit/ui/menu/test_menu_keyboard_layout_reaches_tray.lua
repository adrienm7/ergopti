--- tests/unit/ui/menu/test_menu_keyboard_layout_reaches_tray.lua

--- ==============================================================================
--- MODULE: Regression — the Keyboard layout submenu reaches the tray populated
--- DESCRIPTION:
--- The tray root is rendered as provider DATA: a component row hands over
--- `items` (rows to materialise) or `submenu` (a tree already materialised).
--- menu_keyboard_layout returned the rows ManifestMenu.build had ALREADY turned
--- into `title`/`fn` rows under `items`, so the tray renderer dropped every one
--- of them and the submenu opened empty on the real menu bar.
---
--- The same builder also asked the renderer for the pause/resume pickers before
--- it had collected them, so `layout_switching` always rendered nothing.
---
--- Both cases go through the exact render call Builder.generate makes.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the layout row and renders it the way the tray root does.
--- @param ctx table Menu context.
--- @return table|nil rendered The materialised tray row.
local function tray_row(ctx)
	local layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
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

helpers.describe("Keyboard layout submenu reaches the tray populated", function()
	helpers.it("the rendered tray row carries a non-empty submenu", function()
		local row = tray_row(make_ctx())
		helpers.assert_true(type(row) == "table", "the layout row must survive the tray render")
		helpers.assert_true(type(row.menu) == "table" and #row.menu > 0,
			"the Keyboard layout submenu reached the tray empty — materialised rows handed over as `items` "
			.. "are dropped by the tray renderer; they must be handed over as `submenu`")
		local seen = titles(row.menu)
		helpers.assert_true(seen["— menu.layout.header_custom —"] or seen["menu.layout.header_custom"],
			"the manifest's custom layout header must be in the rendered submenu")
		helpers.assert_true(seen["menu.layout.manage"], "the layout manager row must be in the rendered submenu")
		helpers.assert_true(seen["menu.layout.menubar_icon"], "the menubar icon row must be in the rendered submenu")
	end)

	helpers.it("the pause/resume pickers are collected before the manifest renders them", function()
		local row = tray_row(make_ctx())
		local seen = titles(row and row.menu)
		helpers.assert_true(seen["menu.layout.pause_layout_enabled"],
			"`layout_switching` rendered nothing — the provider was read before its rows were collected")
	end)

	helpers.it("places replacement in the extension while Layout retains its physical picker", function()
		local ctx = make_ctx()
		local row = tray_row(ctx)
		local seen = titles(row and row.menu)
		helpers.assert_nil(seen["Replace J with the magic key"],
			"the relocated replacement control must have no second Layout owner")
		local physical_picker = false
		for title in pairs(seen) do
			if title:sub(1, #"menu.layout.magic_key_source : ") == "menu.layout.magic_key_source : " then
				physical_picker = true
			end
		end
		helpers.assert_true(physical_picker, "the actual Layout renderer still exposes physical-key selection")
		local Hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local ManifestMenu = require("infra.manifest_menu")
		local rows = Hotstrings.build_bound_section_rows(ctx, { { group = "magickey", section = "replace" } })
		local rendered = ManifestMenu.render_rows(rows, "extension_hotstrings")
		helpers.assert_true(titles(rendered)["Replace J with the magic key"],
			"the actual extension provider's replacement row must reach the native renderer")
	end)
end)

--- Captures actual provider data while forwarding its status and rendering to the real binding.
--- @param callback function Receives the native build, fixture state and binding.
local function with_empty_layout(callback)
	helpers.with_stub_scope({ "ui.menu.menu_keyboard_layout", "infra.manifest_menu", "infra.i18n",
		"adapters.json_codec", "menu.renderer", "modules.keymap.layout_registry" }, function()
		local module = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
		local binding = require("infra.manifest_menu")
		local state = { selections = 0, installed = false }
		package.loaded["modules.keymap.layout_registry"] = {
			picker = function()
				return { layouts = state.installed and { { id = "native", name = "Native layout" } } or {}, active = "native" }
			end,
			select = function() state.selections = state.selections + 1; return true end,
		}
		local native_build = binding.build
		binding.build = function(key, title, dynamic, click, ctx, providers)
			if key == "layout_menu" then
				local provider = providers.custom_layouts
				providers.custom_layouts = function()
					state.data = provider()
					return state.data
				end
			end
			return native_build(key, title, dynamic, click, ctx, providers)
		end
		callback(function()
			local item = module.build(make_ctx())
			helpers.assert_eq(type(item), "table")
			helpers.assert_eq(type(item.submenu), "table")
			return item.submenu
		end, state, binding)
	end)
end

-- Independent pre-migration captions; the generated status declaration is the subject.
local EmptyLayoutJson = require("json")
local function read_empty_layout_json(path)
	local file = assert(io.open(path, "rb"))
	local value = assert(EmptyLayoutJson.decode(file:read("*a")))
	file:close()
	return value
end

local EmptyLayoutCorpus = read_empty_layout_json(helpers.shared("tests/corpus/menu/layout_empty_status.json"))

local function empty_layout_owner(binding)
	for _, row in ipairs(binding.get_array(EmptyLayoutCorpus.section)) do
		if row.id == EmptyLayoutCorpus.provider then return row end
	end
	error("The actual custom-layout provider declaration must exist.")
end

local function count_empty_layout_caption(rows, title)
	local count = 0
	for _, row in ipairs(rows or {}) do
		if row.title == title then
			count = count + 1
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_nil(row.menu)
		end
	end
	return count
end

helpers.describe("the shared empty native-layout status", function()
	helpers.it("(layout-empty-status) retains the independent inert declaration", function()
		with_empty_layout(function(_, state, binding)
			helpers.assert_eq(empty_layout_owner(binding).status_rows[EmptyLayoutCorpus.status], { EmptyLayoutCorpus.row })
			local count = 0
			for _ in pairs(EmptyLayoutCorpus.captions) do count = count + 1 end
			helpers.assert_eq(count, 21)
			helpers.assert_eq(state.selections, 0)
		end)
	end)

	for locale, expected in pairs(EmptyLayoutCorpus.captions) do
		helpers.it("(layout-empty-status) renders the real empty provider in " .. locale, function()
			with_empty_layout(function(build, state, binding)
				local catalogue = read_empty_layout_json(helpers.shared("data/locales/" .. locale .. ".json"))
				helpers.assert_eq(catalogue[EmptyLayoutCorpus.row.i18n], expected)
				require("infra.i18n").get = function(key) return catalogue[key] or key end
				local rows = build()
				helpers.assert_eq(state.data, { { label = expected, disabled = true } })
				helpers.assert_eq(count_empty_layout_caption(rows, expected), 1)
				helpers.assert_eq(state.selections, 0)
				local declaration = empty_layout_owner(binding).status_rows[EmptyLayoutCorpus.status][1]
				declaration.i18n = "menu.layout.manage"
				build()
				helpers.assert_eq(state.data, { { label = catalogue["menu.layout.manage"], disabled = true } },
					"The native provider consumes the live declaration, not a repeated native caption.")
			end)
		end)
	end

	for _, invalid in ipairs({ "missing", "empty", "command", "effectful_label" }) do
		helpers.it("(layout-empty-status) refuses the empty caption after " .. invalid, function()
			with_empty_layout(function(build, state, binding)
				local statuses = empty_layout_owner(binding).status_rows
				local baseline = build()
				local caption = require("infra.i18n").get(EmptyLayoutCorpus.row.i18n)
				helpers.assert_eq(count_empty_layout_caption(baseline, caption), 1)
				local bad = {
					empty = {}, command = { { type = "command", id = "layout_manager", i18n = "menu.layout.manage" } },
					effectful_label = { { type = "label", i18n = EmptyLayoutCorpus.row.i18n, action = "layout_manager" } },
				}
				statuses[EmptyLayoutCorpus.status] = bad[invalid]
				local rows = build()
				helpers.assert_eq(state.data, {})
				helpers.assert_eq(count_empty_layout_caption(rows, caption), 0)
				helpers.assert_eq(state.selections, 0)
			end)
		end)
	end

	helpers.it("(layout-empty-status) refuses an unavailable status-renderer port", function()
		with_empty_layout(function(build, state, binding)
			build()
			helpers.assert_eq(#state.data, 1)
			binding.status_rows = nil
			build()
			helpers.assert_eq(state.data, {})
			helpers.assert_eq(state.selections, 0)
		end)
	end)

	helpers.it("(layout-empty-status) leaves installed native layout data actionable", function()
		with_empty_layout(function(build, state, binding)
			state.installed = true
			empty_layout_owner(binding).status_rows[EmptyLayoutCorpus.status] = nil
			build()
			helpers.assert_eq(#state.data, 1)
			helpers.assert_eq(state.data[1].label, "Native layout")
			helpers.assert_eq(state.data[1].checked, true)
			helpers.assert_eq(type(state.data[1].action), "function")
			helpers.assert_true(state.data[1].disabled ~= true)
			helpers.assert_eq(state.selections, 0)
		end)
	end)
end)


--- Uses the actual empty-source list, canonical binding and native row renderer.
--- Native effect ports are controlled; successful UI dispatch still returns nil.
local function with_empty_source_preferences(callback, labels)
	helpers.with_stub_scope({"ui.menu.menu_keyboard_layout", "infra.manifest_menu", "infra.i18n",
		"modules.keymap.input_sources", "modules.keymap.layout_install"}, function()
		local sources = helpers.load_with_stubs("modules.keymap.input_sources")
		local installer = require("modules.keymap.layout_install")
		local state = {records = {}, commands = {}, result = true, effects = 0}
		sources.list_active_keyboard_layouts = function() return state.records end
		sources.build_kl_name_to_tis_id = function() return {} end
		sources.resolve_installed_ergopti_version = function() return nil end
		installer.pick_latest_bundle = function() return nil end
		installer.highest_installed = function() return nil end
		installer.bundle_variants = function() return {} end
		local function forbid_effect() state.effects = state.effects + 1; error("Opening preferences must not mutate layouts") end
		installer.install_user = forbid_effect
		installer.install_system = forbid_effect
		sources.set_input_source_async = forbid_effect
		hs.execute = function(command)
			state.commands[#state.commands + 1] = command
			if state.result == "throw" then error("Native launch refused") end
			return state.result
		end
		local translator = require("infra.i18n")
		if labels then translator.get = function(key) return labels[key] or key end end
		package.loaded["infra.manifest_menu"] = nil
		local binding = require("infra.manifest_menu")
		package.loaded["ui.menu.menu_keyboard_layout"] = nil
		local module = require("ui.menu.menu_keyboard_layout")
		callback(function() return module.build(make_ctx()).submenu end, state, binding)
		helpers.assert_eq(state.effects, 0, "the preferences command never mutates native layout state")
	end)
end

local function empty_preferences_row(rows, title)
	for _, row in ipairs(rows) do if row.title == title then return row end end
end

helpers.describe("empty native Input Sources consumes the canonical preferences command", function()
	helpers.it("retains its independently declared caption and exact native launch command", function()
		with_empty_source_preferences(function(build, state, binding)
			helpers.assert_eq(binding.get_root().layout_active_source_empty_commands, {{type = "command",
				id = "layout_open_preferences", i18n = "menu.layout.open_prefs", platforms = {"hs"}, unavailable = "hide"}})
			local row = empty_preferences_row(build(), "menu.layout.open_prefs")
			helpers.assert_not_nil(row)
			helpers.assert_eq(type(row.fn), "function")
			helpers.assert_true(row.disabled ~= true)
			helpers.assert_nil(row.checked)
			helpers.assert_eq(#state.commands, 0, "building the actual provider never launches preferences")
			helpers.assert_nil(row.fn(), "the unchanged native UI callback does not fabricate a true ACK")
			helpers.assert_eq(state.commands, {"open 'x-apple.systempreferences:com.apple.preference.keyboard?InputSources'"})
		end)
	end)
	for _, result in ipairs({false, "throw"}) do
		helpers.it("preserves the native nil receipt on launch refusal " .. tostring(result), function()
			with_empty_source_preferences(function(build, state)
				state.result = result
				local row = empty_preferences_row(build(), "menu.layout.open_prefs")
				helpers.assert_not_nil(row)
				helpers.assert_nil(row.fn(), "a refused native launch must not report a fabricated true ACK")
				helpers.assert_eq(state.commands, {"open 'x-apple.systempreferences:com.apple.preference.keyboard?InputSources'"})
			end)
		end)
	end
	helpers.it("materializes an independent caption mutation through the real provider", function()
		with_empty_source_preferences(function(build, state, binding)
			local item = binding.get_root().layout_active_source_empty_commands[1]
			local old = item.i18n
			item.i18n = "menu.about.check_for_updates"
			local ok, detail = xpcall(function()
				local rows = build()
				helpers.assert_nil(empty_preferences_row(rows, "menu.layout.open_prefs"))
				local row = empty_preferences_row(rows, "menu.about.check_for_updates")
				helpers.assert_not_nil(row)
				helpers.assert_nil(row.fn())
				helpers.assert_eq(#state.commands, 1)
			end, debug.traceback)
			item.i18n = old
			if not ok then error(detail, 0) end
		end)
	end)
	for _, mutation in ipairs({"missing", "wrong_id", "wrong_type", "empty_caption", "invalid_caption", "hidden_platform"}) do
		helpers.it("refuses the actual " .. mutation .. " declaration without inventing a native fallback", function()
			with_empty_source_preferences(function(build, state, binding)
				local root = binding.get_root()
				local old = root.layout_active_source_empty_commands
				local candidate = {{type = "command", id = "layout_open_preferences", i18n = "menu.layout.open_prefs",
					platforms = {"hs"}, unavailable = "hide"}}
				if mutation == "missing" then candidate = nil
				elseif mutation == "wrong_id" then candidate[1].id = "removed_layout_open_preferences"
				elseif mutation == "wrong_type" then candidate[1].type = "list"
				elseif mutation == "empty_caption" then candidate[1].i18n = ""
				elseif mutation == "invalid_caption" then candidate[1].i18n = {}
				else candidate[1].platforms = {"linux"} end
				root.layout_active_source_empty_commands = candidate
				local ok, detail = xpcall(function()
					local rows = build()
					helpers.assert_nil(empty_preferences_row(rows, "menu.layout.open_prefs"))
					helpers.assert_not_nil(empty_preferences_row(rows, "menu.layout.manage"))
					helpers.assert_eq(#state.commands, 0)
				end, debug.traceback)
				root.layout_active_source_empty_commands = old
				if not ok then error(detail, 0) end
			end)
		end)
	end
	helpers.it("withdraws a retained callback before any native preferences effect", function()
		with_empty_source_preferences(function(build, state, binding)
			local row = empty_preferences_row(build(), "menu.layout.open_prefs")
			helpers.assert_not_nil(row)
			local root = binding.get_root()
			local old = root.layout_active_source_empty_commands
			root.layout_active_source_empty_commands = nil
			local ok, detail = xpcall(function()
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(#state.commands, 0)
			end, debug.traceback)
			root.layout_active_source_empty_commands = old
			if not ok then error(detail, 0) end
		end)
	end)
	helpers.it("does not introduce preferences into nonempty native input-source data", function()
		with_empty_source_preferences(function(build, state, binding)
			state.records = {{id = "French", name = "French", selected = false}}
			binding.get_root().layout_active_source_empty_commands = nil
			local rows = build()
			helpers.assert_nil(empty_preferences_row(rows, "menu.layout.open_prefs"))
			local native = empty_preferences_row(rows, "French")
			helpers.assert_not_nil(native)
			helpers.assert_eq(type(native.fn), "function")
			helpers.assert_eq(#state.commands, 0)
		end)
	end)
	helpers.it("consumes every existing real locale caption without a native literal", function()
		local codec = require("adapters.json_codec")
		local file = assert(io.open(helpers.shared("data/locale_order.json"), "rb"))
		local locales = assert(codec.decode(file:read("*a"))).order; assert(file:close())
		helpers.assert_eq(#locales, 21)
		for _, locale in ipairs(locales) do
			file = assert(io.open(helpers.shared("data/locales/" .. locale .. ".json"), "rb"))
			local labels = assert(codec.decode(file:read("*a"))); assert(file:close())
			helpers.assert_true(type(labels["menu.layout.open_prefs"]) == "string" and labels["menu.layout.open_prefs"] ~= "")
			with_empty_source_preferences(function(build, state)
				local row = empty_preferences_row(build(), labels["menu.layout.open_prefs"])
				helpers.assert_not_nil(row, "actual native preferences caption: " .. locale)
				helpers.assert_eq(type(row.fn), "function")
				helpers.assert_nil(row.fn())
				helpers.assert_eq(state.commands, {"open 'x-apple.systempreferences:com.apple.preference.keyboard?InputSources'"})
			end, labels)
		end
	end)
end)
