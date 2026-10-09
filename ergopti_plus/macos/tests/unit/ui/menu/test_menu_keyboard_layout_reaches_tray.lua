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
		install_legacy_layout_formats()
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

--- Controls native discovery while exercising the genuine layout renderer.
--- All pre-existing registered subjects above remain unchanged.
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

helpers.describe("layout switching consumes its complete shared presentation frame", function()
	helpers.it("owns the check and both actual native-choice parents in declared order", function()
		with_switch_frame(function(build, _, _, ctx)
			local rows = build()
			local index
			for i, row in ipairs(rows) do if row.title == "menu.layout.pause_layout_enabled" then index = i end end
			helpers.assert_not_nil(index)
			helpers.assert_eq(rows[index].checked, true)
			helpers.assert_eq(rows[index + 1].title, "  ↳ menu.layout.layout_on_pause : menu.layout.layout_auto")
			helpers.assert_eq(rows[index + 2].title, "  ↳ menu.layout.layout_on_resume : menu.layout.layout_auto")
			helpers.assert_eq(#rows[index + 1].menu, 3)
			helpers.assert_eq(rows[index + 1].menu[1].title, "menu.layout.layout_auto")
			helpers.assert_eq(rows[index + 1].menu[1].checked, true)
			helpers.assert_eq(rows[index + 1].menu[2].title, "-")
			helpers.assert_eq(rows[index + 1].menu[3].title, "French")
			rows[index + 1].menu[3].fn()
			helpers.assert_eq(ctx.state.layout_on_pause, "French")
		end)
	end)
	for _, shape in ipairs({"off", "paused", "ready"}) do
		helpers.it("retains exact disabled state for " .. shape, function()
			with_switch_frame(function(build, _, _, ctx)
				ctx.state.layout_pause_switch_enabled = shape ~= "off"
				ctx.paused = shape == "paused"
				local rows = build()
				local parent = switch_row(rows, "  ↳ menu.layout.layout_on_pause : ")
				helpers.assert_not_nil(parent)
				helpers.assert_eq(parent.disabled == true, shape ~= "ready")
			end)
		end)
	end
	for _, owner in ipairs({"layout_switching_frame", "layout_switch_picker_frame", "layout_switch_picker_choices_frame"}) do
		helpers.it("refuses the actual family when its " .. owner .. " declaration is withdrawn", function()
			with_switch_frame(function(build, fixture, binding)
				local root, old = binding.get_root(), binding.get_root()[owner]
				root[owner] = nil
				local ok, detail = xpcall(function()
					helpers.assert_nil(build(), "Withdrawn presentation must not silently publish native copies")
					helpers.assert_eq(fixture.saves, 0)
				end, debug.traceback)
				root[owner] = old
				if not ok then error(detail, 0) end
			end)
		end)
	end
	for _, owner in ipairs({"layout_switching_frame", "layout_switch_picker_frame"}) do
		helpers.it("refuses a retained native choice after " .. owner .. " withdrawal", function()
			with_switch_frame(function(build, fixture, binding, ctx)
				local parent = switch_row(build(), "  ↳ menu.layout.layout_on_pause : ")
				local choose = parent.menu[3].fn
				local root, old = binding.get_root(), binding.get_root()[owner]
				root[owner] = nil
				local ok, detail = xpcall(function()
					helpers.assert_eq(choose(), false)
					helpers.assert_nil(ctx.state.layout_on_pause)
					helpers.assert_eq(fixture.saves, 0)
					helpers.assert_eq(fixture.updates, 0)
				end, debug.traceback)
				root[owner] = old
				if not ok then error(detail, 0) end
			end)
		end)
	end
	helpers.it("retains nil automatic choice, one save and one update, with no native switch", function()
		with_switch_frame(function(build, fixture, _, ctx)
			ctx.state.layout_on_resume = "French"
			local parent = switch_row(build(), "  ↳ menu.layout.layout_on_resume : ")
			helpers.assert_eq(parent.menu[1].checked, false)
			parent.menu[1].fn()
			helpers.assert_nil(ctx.state.layout_on_resume)
			helpers.assert_eq(fixture.saves, 1)
			helpers.assert_eq(fixture.updates, 1)
		end)
	end)
	helpers.it("retains failed save refusal before redraw", function()
		with_switch_frame(function(build, fixture, _, ctx)
			fixture.save_result = false
			local parent = switch_row(build(), "  ↳ menu.layout.layout_on_pause : ")
			helpers.assert_eq(parent.menu[3].fn(), false)
			helpers.assert_eq(ctx.state.layout_on_pause, "French")
			helpers.assert_eq(fixture.saves, 1)
			helpers.assert_eq(fixture.updates, 0)
		end)
	end)
	helpers.it("the empty native list shows only automatic choice without a dangling boundary", function()
		with_switch_frame(function(build, fixture)
			fixture.records = {}
			local parent = switch_row(build(), "  ↳ menu.layout.layout_on_pause : ")
			helpers.assert_eq(#parent.menu, 1)
			helpers.assert_eq(parent.menu[1].title, "menu.layout.layout_auto")
		end)
	end)
	helpers.it("preserves all 21 independently frozen old captions through actual renderer", function()
		local codec = require("adapters.json_codec")
		local file = assert(io.open(helpers.shared("tests/corpus/menus/layout_switching_captions.json"), "rb"))
		local vectors = assert(codec.decode(file:read("*a"))); assert(file:close())
		local count = 0
		for lang, vector in pairs(vectors) do
			count = count + 1
			file = assert(io.open(helpers.shared("data/locales/" .. lang .. ".json"), "rb"))
			local labels = assert(codec.decode(file:read("*a"))); assert(file:close())
			with_switch_frame(function(build)
				local rows = build()
				helpers.assert_not_nil(switch_row(rows, vector.pause), lang .. " pause caption")
				helpers.assert_not_nil(switch_row(rows, vector.resume), lang .. " resume caption")
				helpers.assert_not_nil(switch_row(rows, vector.switch), lang .. " check caption")
			end, labels)
		end
		helpers.assert_eq(count, 21)
	end)
end)

helpers.describe("the complete Layout family retains genuine native record and outer parent authority", function()
	for _, owner in ipairs({"layout_native_record_choice", "layout_bundle_install_first", "layout_bundle_frame", "layout_native_parent"}) do
		helpers.it("refuses to publish after " .. owner .. " withdrawal", function()
			with_switch_frame(function(build, fixture, binding)
				local root, old = binding.get_root(), binding.get_root()[owner]
				root[owner] = nil
				local ok, detail = xpcall(function()
					helpers.assert_nil(build(), "Missing complete Layout declaration cannot manufacture a native row")
					helpers.assert_eq(fixture.saves, 0)
					helpers.assert_eq(fixture.updates, 0)
				end, debug.traceback)
				root[owner] = old
				if not ok then error(detail, 0) end
			end)
		end)
	end
	helpers.it("retains selected active-source check and disabled state without invoking TIS", function()
		with_switch_frame(function(build, fixture)
			fixture.records = {{id = "French", name = "Native 100%s && 🦀", selected = true}}
			local row = switch_row(build(), "Native 100%s && 🦀")
			helpers.assert_not_nil(row)
			helpers.assert_eq(row.title, "Native 100%s && 🦀")
			helpers.assert_eq(row.checked, true)
			helpers.assert_eq(row.disabled, true)
		end)
	end)
	helpers.it("a retained policy choice refuses a withdrawn genuine record declaration", function()
		with_switch_frame(function(build, fixture, binding, ctx)
			local parent = switch_row(build(), "  ↳ menu.layout.layout_on_pause : ")
			local choose = parent.menu[3].fn
			local root, old = binding.get_root(), binding.get_root().layout_native_record_choice
			root.layout_native_record_choice = nil
			local ok, detail = xpcall(function()
				helpers.assert_eq(choose(), false)
				helpers.assert_nil(ctx.state.layout_on_pause)
				helpers.assert_eq(fixture.saves, 0)
			end, debug.traceback)
			root.layout_native_record_choice = old
			if not ok then error(detail, 0) end
		end)
	end)
	helpers.it("native record captions remain actual data when a translated layout caption changes", function()
		with_switch_frame(function(build, fixture, binding)
			fixture.records = {{id = "French", name = "Actual Record", selected = false}}
			local root, old = binding.get_root(), binding.get_root().layout_native_record_choice[1].caption_source
			root.layout_native_record_choice[1].caption_source = "translated"
			local ok, detail = xpcall(function()
				helpers.assert_nil(build())
			end, debug.traceback)
			root.layout_native_record_choice[1].caption_source = old
			if not ok then error(detail, 0) end
		end)
	end)
	helpers.it("actual materialized outer parent consumes the declared translated caption", function()
		with_switch_frame(function(_, fixture, binding, ctx)
			local module = require("ui.menu.menu_keyboard_layout")
			local root = binding.get_root()
			local old = root.layout_native_parent[1].i18n
			root.layout_native_parent[1].i18n = "menu.layout.manage"
			local ok, detail = xpcall(function()
				local built = module.build(ctx)
				helpers.assert_eq(built.label, "menu.layout.manage")
				helpers.assert_nil(built.items, "materialized title/fn rows must never be raw provider DATA")
				helpers.assert_true(type(built.submenu) == "table" and #built.submenu > 0)
				helpers.assert_eq(fixture.effects, 0)
			end, debug.traceback)
			root.layout_native_parent[1].i18n = old
			if not ok then error(detail, 0) end
		end)
	end)
end)

helpers.describe("Layout owns install-state choices, bundle truth and every frozen original caption", function()
	for _, state in ipairs({"fresh", "older", "current"}) do
		helpers.it("retains system/user/status order for " .. state .. " actual native installation state", function()
			local Json, Paths = require("json"), require("infra.paths")
			local file = assert(io.open(Paths.shared("data/locales/en.json"), "rb"))
			local labels = assert(Json.decode(assert(file:read("*a")))); assert(file:close())
			with_switch_frame(function(build, fixture)
				fixture.latest = "Ergopti_v2.2.2.bundle"
				if state ~= "fresh" then
					local version = state == "older" and {2, 2, 1} or {2, 2, 2}
					fixture.system = {name = "Ergopti.bundle", version = version}
					fixture.user = {name = "Ergopti.bundle", version = version}
				end
				if state == "current" then fixture.variants = {{name = "Ergopti_v2_2_2_plus", tis_id = "stable.plus", keylayout = "/actual/plus.keylayout"}} end
				local rows = assert(build())
				local expected = {
					fresh = {"🔐 Install Ergopti (system) v2.2.2", "📥 Install Ergopti (user) v2.2.2", "Install the bundle first"},
					older = {"Update Ergopti (system) v2.2.1 → v2.2.2", "Update Ergopti (user) v2.2.1 → v2.2.2", "Install the bundle first"},
					current = {"Ergopti (system) v2.2.2 — up to date ✅", "Ergopti (user) v2.2.2 — up to date ✅", "Add Ergopti v2.2.2 to input sources…"},
				}
				local index
				for i, row in ipairs(rows) do if row.title == expected[state][1] then index = i end end
				helpers.assert_not_nil(index)
				for offset, caption in ipairs(expected[state]) do helpers.assert_eq(rows[index + offset - 1].title, caption) end
				helpers.assert_eq(rows[index].disabled, state == "current" and true or nil)
				helpers.assert_eq(rows[index + 1].disabled, state == "current" and true or nil)
				helpers.assert_eq(fixture.effects, 0)
			end, labels)
		end)
	end
	for _, state in ipairs({"all_active", "legacy_installed", "legacy_missing", "variants", "absent"}) do
		helpers.it("publishes only the genuine " .. state .. " bundle status family", function()
			local Json, Paths = require("json"), require("infra.paths")
			local file = assert(io.open(Paths.shared("data/locales/en.json"), "rb"))
			local labels = assert(Json.decode(assert(file:read("*a")))); assert(file:close())
			with_switch_frame(function(build, fixture)
				fixture.latest = "Ergopti_v2.2.2.bundle"
				fixture.records = {{id = "French", name = "French", selected = false}}
				if state ~= "legacy_missing" and state ~= "absent" then
					fixture.system = {name = "Ergopti_v2.2.2.bundle", version = {2, 2, 2}}
					fixture.variants = {{name = "Ergopti_v2_2_2_plus", tis_id = "stable.plus", keylayout = "/actual/plus.keylayout"}}
				end
				if state == "all_active" then
					fixture.records = {{id = "Ergopti_v2_2_2_plus", name = "Ergopti+", selected = true}}
					fixture.mapping = {Ergopti_v2_2_2_plus = "stable.plus"}
				elseif state == "legacy_installed" or state == "legacy_missing" then
					fixture.records = {{id = "Ergopti_v2_2_1_plus", name = "Ergopti+", selected = false}}
				end
				local expected = {all_active = "All Ergopti variants active v2.2.2 ✅", legacy_installed = "Upgrade active list v2.2.1 → v2.2.2",
					legacy_missing = "Upgrade active list to v2.2.2 (install v2.2.2 first)", variants = "Add Ergopti v2.2.2 to input sources…", absent = "Install the bundle first"}
				local row = switch_row(assert(build()), expected[state])
				helpers.assert_not_nil(row)
				if state == "legacy_installed" then helpers.assert_true(type(row.fn) == "function")
				elseif state == "variants" then
					helpers.assert_eq(#row.menu, 1)
					helpers.assert_eq(row.menu[1].title, "Ergopti+ v2.2.2")
					helpers.assert_true(type(row.menu[1].fn) == "function")
				else helpers.assert_eq(row.disabled, true) end
				helpers.assert_eq(fixture.effects, 0)
			end, labels)
		end)
	end
	for _, language in ipairs({"da", "de", "en", "es", "fr", "it", "nl", "no", "pl", "pt", "sv", "tr", "cs", "ar", "he", "hi", "uk", "ru", "zh", "ja", "ko"}) do
		helpers.it("retains the independently frozen complete original caption family in " .. language, function()
			local Json, Paths = require("json"), require("infra.paths")
			local function load(relative)
				local file = assert(io.open(Paths.shared(relative), "rb"))
				local value = assert(Json.decode(assert(file:read("*a")))); assert(file:close()); return value
			end
			local expected = load("tests/corpus/menus/layout_complete_captions.json")[language]
			with_switch_frame(function(_, _, binding)
				local getters = {
					layout_install_scope = function() return "scope" end,
					layout_install_emoji = function() return "🔐" end,
					layout_install_latest = function() return "2.2.2" end,
					layout_install_old = function() return "2.2.1" end,
					layout_bundle_version = function() return "2.2.2" end,
					layout_bundle_old_version = function() return "2.2.1" end,
					layout_variant_label = function() return "Independent Variant" end,
				}
				local commands = {layout_install = function() return false end, layout_upgrade_list = function() return false end, layout_enable_variant = function() return false end}
				for _, case in ipairs({{"layout_bundle_installed", "installed"}, {"layout_bundle_install", "install"}, {"layout_bundle_update", "update"},
					{"layout_bundle_in_list", "in_list"}, {"layout_bundle_update_install_first", "update_install_first"}, {"layout_bundle_upgrade", "update_list"},
					{"layout_bundle_upgrade_to", "update_list_to"}, {"layout_bundle_variant_added", "already_added"}, {"layout_bundle_variant_add", "native_variant"},
					{"layout_bundle_variant_parent", "add_to_list"}, {"layout_bundle_install_first", "install_first"}, {"layout_native_parent", "parent"}}) do
					local rows = assert(binding.template_rows(case[1], commands, getters, {layout_variant_choices = {}, layout_parent_content = {}}))
					helpers.assert_eq(#rows, 1)
					helpers.assert_eq(rows[1].label, expected[case[2]])
				end
			end, load("data/locales/" .. language .. ".json"))
		end)
	end
end)

helpers.describe("Layout native choices retain data identity and declared state", function()
	helpers.it("retains custom registry record spelling, check and native selector without performing selection", function()
		with_switch_frame(function(build, fixture)
			fixture.custom = {layouts = {{id = "private.layout", name = "Custom 100%s && 🦀"}}, active = "private.layout"}
			local row = switch_row(assert(build()), "Custom 100%s && 🦀")
			helpers.assert_not_nil(row)
			helpers.assert_eq(row.checked, true)
			helpers.assert_nil(row.disabled)
			helpers.assert_true(type(row.fn) == "function")
			helpers.assert_eq(fixture.effects, 0)
		end)
	end)
	helpers.it("retains added and available variants in actual installed-bundle order", function()
		local Json, Paths = require("json"), require("infra.paths")
		local file = assert(io.open(Paths.shared("data/locales/en.json"), "rb"))
		local labels = assert(Json.decode(assert(file:read("*a")))); assert(file:close())
		with_switch_frame(function(build, fixture)
			fixture.latest = "Ergopti_v2.2.2.bundle"
			fixture.system = {name = "Ergopti_v2.2.2.bundle", version = {2, 2, 2}}
			fixture.variants = {{name = "Ergopti_v2_2_2", tis_id = "stable.base", keylayout = "/actual/base.keylayout"},
				{name = "Ergopti_v2_2_2_plus", tis_id = "stable.plus", keylayout = "/actual/plus.keylayout"}}
			fixture.records = {{id = "Ergopti_v2_2_2", name = "Ergopti", selected = true}}
			fixture.mapping = {Ergopti_v2_2_2 = "stable.base"}
			local parent = switch_row(assert(build()), "Add Ergopti v2.2.2 to input sources…")
			helpers.assert_not_nil(parent)
			helpers.assert_eq(#parent.menu, 2)
			helpers.assert_eq(parent.menu[1].title, "✅ Ergopti v2.2.2 — already added")
			helpers.assert_eq(parent.menu[1].disabled, true)
			helpers.assert_eq(parent.menu[2].title, "Ergopti+ v2.2.2")
			helpers.assert_true(type(parent.menu[2].fn) == "function")
			helpers.assert_eq(fixture.effects, 0)
		end, labels)
	end)
end)

helpers.describe("Layout installation state remains native per scope", function()
	helpers.it("does not borrow the user installation when the system scope is absent", function()
		local Json, Paths = require("json"), require("infra.paths")
		local file = assert(io.open(Paths.shared("data/locales/en.json"), "rb"))
		local labels = assert(Json.decode(assert(file:read("*a")))); assert(file:close())
		with_switch_frame(function(build, fixture)
			fixture.latest = "Ergopti_v2.2.2.bundle"
			fixture.user = {name = "Ergopti_v2.2.2.bundle", version = {2, 2, 2}}
			fixture.variants = {{name = "Ergopti_v2_2_2_plus", tis_id = "stable.plus", keylayout = "/actual/plus.keylayout"}}
			local rows = assert(build())
			local index
			for i, row in ipairs(rows) do if row.title == "🔐 Install Ergopti (system) v2.2.2" then index = i end end
			helpers.assert_not_nil(index)
			helpers.assert_true(type(rows[index].fn) == "function")
			helpers.assert_eq(rows[index + 1].title, "Ergopti (user) v2.2.2 — up to date ✅")
			helpers.assert_eq(rows[index + 1].disabled, true)
			helpers.assert_eq(fixture.effects, 0)
		end, labels)
	end)
end)
