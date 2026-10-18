--- tests/unit/ui/menu/keyboard_layout/test_menu_keyboard_layout_reaches_tray_submenu.lua

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
package.loaded["tests.support.ui.menu.keyboard_layout.menu_keyboard_layout_reaches_tray_fixture"] = nil
local Fixture = require("tests.support.ui.menu.keyboard_layout.menu_keyboard_layout_reaches_tray_fixture")
local install_legacy_layout_formats = Fixture.install_legacy_layout_formats
local make_ctx = Fixture.make_ctx
local switch_row = Fixture.switch_row
local titles = Fixture.titles
local tray_row = Fixture.tray_row
local with_switch_frame = Fixture.with_switch_frame





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
