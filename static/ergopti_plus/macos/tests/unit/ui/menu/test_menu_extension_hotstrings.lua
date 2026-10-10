--- tests/unit/ui/menu/test_menu_extension_hotstrings.lua

--- ==============================================================================
--- MODULE: Hotstrings Menu — Extension Submenus (macOS)
--- DESCRIPTION:
--- The Hotstrings menu lists the hotstrings an extension brings under one
--- « Hotstrings <extension> » submenu in its extensions section. The Ergopti
--- layout extension binds SFB reduction and rolls there, under their historical
--- ids, instead of a « Disposition Ergopti » section of their own; without the
--- extension they are not listed at all.
--- ==============================================================================

local helpers = require("tests.helpers")
local CaptionFixture = require("tests.support.hotstrings_parent_caption_fixture")
local ExtensionTranslator = require("infra.i18n")
local shipped = require("toml_codec.codec").decode(require("tests.support.source_file").read(
	helpers.driver_root() .. "../../layouts/registry/ergopti/manifest.toml")).extension

local ERGOPTI = {
	id = shipped.id, name = shipped.name, toml_files = {},
	bound_files = {
		{ stem = "repeatcorrections", binding = { category = "magickey", sections = { "repeat_corrections" } } },
		{ stem = "rolls", binding = { category = "rolls" } },
		{ stem = "sfbsreduction", binding = { category = "sfbsreduction" } },
	},
}
local DEMO = { id = "demo", name = "Demo", toml_files = { { stem = "phrases" } }, bound_files = {} }

--- A menu context with the given loaded groups and discovery catalogue.
--- @param hotfiles table Loaded group names.
--- @param packs table Discovery catalogue.
--- @return table
local function context(hotfiles, packs)
	return { hotfiles = hotfiles, extension_packs = packs, get_group_name = function(name) return name end }
end

helpers.describe("Hotstrings menu: extension submenus", function()
	helpers.it("renders the shipped Ergopti+ name in the actual tray tree", CaptionFixture.scoped(function()
		helpers.load_with_stubs("ui.menu.builder")
		CaptionFixture.install(require("infra.i18n"))
		package.loaded["ui.menu.builder"] = nil
		local Builder = require("ui.menu.builder")
		local Hotstrings = require("ui.menu.menu_hotstrings")
		local ctx = context({ "sfbsreduction", "rolls" }, { ERGOPTI })
		ctx.config, ctx.base_dir = { log_level = 2 }, helpers.driver_root()
		ctx.state = { keymap = false, hotstrings = {}, sections_order_overrides = {} }
		ctx.applyTriggerChar = function(text) return text end
		ctx.keymap = {
			get_sections = function() return { { name = "section", count = 1 } } end,
			is_group_enabled = function() return false end,
			is_section_enabled = function() return false end,
		}
		local actions = setmetatable({}, { __index = function() return function() end end })
		local tree = Builder.generate(ctx, { hotstrings = Hotstrings }, actions)
		local expected = string.format(require("infra.i18n").get("menu.extensions.hotstrings_of"), "Ergopti+")
		local function find(rows)
			for _, row in ipairs(rows or {}) do
				if type(row.title) == "string" and row.title:sub(1, #expected) == expected then return row end
				local nested = type(row.menu) == "table" and find(row.menu)
				if nested then return nested end
			end
		end
		helpers.assert_true(find(tree) ~= nil, "the rendered extension name must retain its plus")
	end))

	helpers.it("(ergopti-hotstrings-ext) lists SFB reduction and rolls under the Ergopti extension", function()
		local Builder = helpers.load_with_stubs("ui.menu.builder")
		local ctx = context({ "autocorrection", "magickey", "rolls", "sfbsreduction", "ext:demo:phrases" },
			{ DEMO, ERGOPTI })
		local by_extension, bound = Builder.bound_groups(ctx)
		helpers.assert_eq(bound, { rolls = true, sfbsreduction = true },
			"a section binding leaves the magic key among the common categories")
		local counts = {
			group_counts = { rolls = 7, sfbsreduction = 5 },
			ext_details = { { id = "demo", name = "Demo", total = 3, groups = { "ext:demo:phrases" } } },
		}
		local Hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local bound_sections = Hotstrings.bound_sections(ctx)
		helpers.assert_eq(Builder.extension_menus(ctx, counts, by_extension, bound_sections), {
			{ id = "demo", name = "Demo", groups = { "ext:demo:phrases" }, sections = {}, total = 3 },
			-- The menu manifest's order, which Windows walks too and every driver
			-- listed before the move: SFB reduction, then rolls.
			{ id = "ergopti", name = "Ergopti+", groups = { "sfbsreduction", "rolls" },
				sections = { { group = "magickey", section = "repeat_corrections" } }, total = 12 },
		})
		local source = helpers.read_driver_source("function M.extension_menus")
		helpers.assert_true(source:find("for _, name in ipairs(menu.groups) do\n\t\t\tfor _, row in ipairs(collect_groups({ [name] = true }, counts))",
			1, true) ~= nil, "the submenu draws its groups in that order, not in load order")
		helpers.assert_true(source:find('i18n.get("menu.extensions.hotstrings_of"), menu.name)', 1, true) ~= nil,
			"each submenu is labelled « Hotstrings <extension> »")
		helpers.assert_true(source:find('["hotstring_categories_ergopti"]', 1, true) == nil,
			"the « Disposition Ergopti » section is gone")
	end)

	helpers.it("(ergopti-hotstrings-ext) moves the repeat corrections from the magic key into the Ergopti submenu", function()
		local Hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local toggled = {}
		local sections = {
			magickey = {
				{ name = "repeat_corrections", count = 14, description = "Repeat corrections" },
				{ name = "text_expansion_symbols", count = 150, description = "Symbols" },
			},
		}
		local ctx = context({ "magickey" }, { ERGOPTI })
		ctx.applyTriggerChar = function(text) return text end
		ctx.state = { hotstrings = {}, sections_order_overrides = {} }
		ctx.keymap = {
			get_sections = function(name) return sections[name] or {} end,
			is_group_enabled = function() return true end,
			is_section_enabled = function() return true end,
			enable_section = function(group, section) toggled[#toggled + 1] = group .. "." .. section end,
			disable_section = function(group, section) toggled[#toggled + 1] = group .. "." .. section end,
		}
		local by_extension = Hotstrings.bound_sections(ctx)
		local rows, total = Hotstrings.build_bound_section_rows(ctx, by_extension.ergopti)
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].label, "Repeat corrections (14)")
		helpers.assert_eq(rows[1].checked, true)
		helpers.assert_eq(total, 14)
		local labels = {}
		for _, group in ipairs(Hotstrings.build_groups(ctx, nil, {})) do
			for _, row in ipairs(group.submenu or {}) do labels[#labels + 1] = tostring(row.title) end
		end
		local text = table.concat(labels, "|")
		helpers.assert_true(text:find("Symbols (150)", 1, true) ~= nil, text)
		helpers.assert_true(text:find("Repeat corrections", 1, true) == nil,
			"the bound section leaves the magic key submenu: " .. text)
	end)

	helpers.it("(ergopti-hotstrings-ext) lists nothing for an extension that is not installed", function()
		local Builder = helpers.load_with_stubs("ui.menu.builder")
		local ctx = context({ "autocorrection", "magickey" }, {})
		local by_extension, bound = Builder.bound_groups(ctx)
		helpers.assert_eq(bound, {})
		helpers.assert_eq(Builder.extension_menus(ctx, { group_counts = {}, ext_details = {} }, by_extension, {}), {})
	end)
end)


-- Bind the actual native providers to one fresh genuine declaration catalogue.
local function with_extension_frame(body, paused)
	local translator = ExtensionTranslator
	return helpers.with_stub_scope({ "infra.logger", "infra.manifest_menu", "ui.menu.builder",
		"ui.menu.menu_hotstrings", "ui.menu.hotstring_counter" }, function()
		helpers.load_with_stubs("infra.logger")
		package.loaded["infra.i18n"] = translator
		local renderer = assert(require("menu.renderer").new({ platform = "hs",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = require("adapters.json_codec").decode, i18n = translator, logger = require("infra.logger"),
		}))
		package.loaded["infra.manifest_menu"] = renderer
		local Hotstrings = require("ui.menu.menu_hotstrings")
		local Builder = require("ui.menu.builder")
		local ctx = context({ "magickey", "rolls", "sfbsreduction" }, { ERGOPTI })
		ctx.paused = paused == true
		ctx.config, ctx.base_dir = { log_level = 2 }, helpers.driver_root()
		ctx.state = { keymap = true, hotstrings = {}, sections_order_overrides = {} }
		ctx.applyTriggerChar = function(text) return text end
		local sections = {
			magickey = { { name = "repeat_corrections", count = 14, description = "Repeat corrections" },
				{ name = "symbols", count = 3, description = "Symbols" } },
			rolls = { { name = "hc", count = 7, description = "Roll" } },
			sfbsreduction = { { name = "comma", count = 5, description = "SFB" } },
		}
		ctx.keymap = { get_sections = function(name) return sections[name] or {} end,
			is_group_enabled = function() return true end, is_section_enabled = function() return true end }
		local actions = setmetatable({}, { __index = function() return function() end end })
		local label = string.format(translator.get("menu.extensions.hotstrings_of"), "Ergopti+")
		local function find(rows)
			for _, row in ipairs(rows or {}) do
				if type(row.title) == "string" and row.title:sub(1, #label) == label then return row end
				local found = find(row.menu); if found then return found end
			end
		end
		return body({ root = renderer.get_root(), translator = translator, context = ctx, owner = Hotstrings,
			build = function() return find(Builder.generate(ctx, { hotstrings = Hotstrings }, actions)) end })
	end)
end

helpers.describe("complete installed extension shared frames (macOS)", function()
	helpers.it("(shared-extension-frame) retains complete checkbox, category and bound-section order", function()
		with_extension_frame(function(f)
			local rows = assert(f.build()).menu
			helpers.assert_eq(#rows, 6)
			helpers.assert_eq(rows[1].title, f.translator.get("menu.hotstrings.enable_all_sections"))
			helpers.assert_eq(rows[1].checked, true)
			helpers.assert_eq(rows[2].title, "-")
			helpers.assert_eq(rows[3].title, "sfbsreduction (5)")
			helpers.assert_eq(rows[4].title, "rolls (7)")
			helpers.assert_eq(rows[5].title, "-")
			helpers.assert_eq(rows[6].title, "Repeat corrections (14)")
			helpers.assert_eq(rows[6].checked, true)
			f.context.paused = true
			helpers.assert_eq(rows[1].fn(), false, "a retained canonical checkbox refuses the live native pause")
		end)
	end)
	helpers.it("(shared-extension-frame) preserves the paused checkbox's original absent native action", function()
		with_extension_frame(function(f)
			local data = assert(f.owner.build_extension_bulk_actions(f.context, { "rolls" }, {}))
			helpers.assert_eq(#data, 1); helpers.assert_eq(data[1].checked, true)
			helpers.assert_eq(data[1].disabled, true); helpers.assert_eq(data[1].action, nil)
		end, true)
	end)
	for _, section in ipairs({ "hotstring_extension_bulk_controls", "hotstring_extension_content_frame", "hotstrings_parameter_boundary" }) do
		helpers.it("(shared-extension-frame) withdraws only the installed extension for missing " .. section, function()
			with_extension_frame(function(f)
				local saved = f.root[section]; f.root[section] = nil
				helpers.assert_eq(f.build(), nil)
				f.root[section] = saved
				helpers.assert_type(f.build(), "table")
			end)
		end)
	end
	helpers.it("(shared-extension-frame) refuses a foreign bound-provider slot and repairs the whole frame", function()
		with_extension_frame(function(f)
			local row = f.root.hotstring_extension_content_frame[5]
			local saved = row.id; row.id = "foreign_extension_bound_rows"
			helpers.assert_eq(f.build(), nil)
			row.id = saved
			helpers.assert_type(f.build(), "table")
		end)
	end)
	helpers.it("(shared-extension-frame) reads the current declared bulk caption in the native extension provider", function()
		with_extension_frame(function(f)
			f.root.hotstring_extension_bulk_controls[1].i18n = "button.ok"
			helpers.assert_eq(assert(f.build()).menu[1].title, f.translator.get("button.ok"))
		end)
	end)
	helpers.it("(shared-extension-frame) restores genuine owners after a raised native-provider scenario", function()
		local names = { "infra.i18n", "infra.manifest_menu", "infra.paths", "ui.menu.builder",
			"ui.menu.menu_hotstrings", "ui.menu.hotstring_counter" }
		local before = {}; for _, name in ipairs(names) do before[name] = package.loaded[name] end
		local previous_hs = rawget(_G, "hs")
		local ok, err = pcall(function()
			with_extension_frame(function(f) assert(f.build()); error("extension frame scenario sentinel", 0) end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("extension frame scenario sentinel", 1, true) ~= nil)
		for _, name in ipairs(names) do helpers.assert_true(rawequal(package.loaded[name], before[name]), name) end
		helpers.assert_true(rawequal(rawget(_G, "hs"), previous_hs))
	end)
end)
