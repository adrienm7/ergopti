--- tests/unit/ui/menu/test_hotstrings_language_scope_frame.lua

--- ==============================================================================
--- MODULE: Actual Hotstring Language Scope Presentation
--- DESCRIPTION:
--- Replays the actual menu builder and native category and bulk providers against
--- independent caption/order expectations; callbacks retain their native owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local function upvalue(callback, wanted)
	for index = 1, 100 do
		local name, value = debug.getupvalue(callback, index)
		if name == wanted then return assert(value) end
		if name == nil then break end
	end
	error("missing genuine native closure: " .. wanted)
end

local function native_fixture(body)
	local native = require("infra.i18n")
	native.init()
	local renderer = require("infra.manifest_menu")
	local builder = require("ui.menu.builder")
	local hotstrings = require("ui.menu.menu_hotstrings")
	local custom = require("ui.menu.menu_hotstrings_custom")
	local build = upvalue(builder.generate, "build_hotstrings_rows")
	local source = renderer.get_root()
	local saved_frame, saved_parent, saved_check = source.hotstring_language_frame,
		source.hotstring_language_parent_lua, source.hotstring_scope_checkbox
	local context = { state = { hotstrings = {}, keymap = true, sections_order_overrides = {} },
		hotfiles = { "french_magickey", "french_autocorrection" },
		get_group_name = function(file) return file end,
		applyTriggerChar = function(label) return label end,
		keymap = {
			get_sections = function(name)
				return { { name = "native_section", description = "Repeated%",
					count = name == "french_magickey" and 999 or 3 } }
			end,
			get_meta_description = function(name)
				return name == "french_magickey" and "Second%" or "First"
			end,
			is_group_enabled = function() return true end,
			is_section_enabled = function() return true end,
		}, updateMenu = function() end,
	}
	local modules = { hotstrings = { build_groups = hotstrings.build_groups,
		build_language_bulk_actions = hotstrings.build_language_bulk_actions,
		all_sections_switch = hotstrings.all_sections_switch } }
	local function language()
		local rows = assert(build(context, modules)[1]).submenu
		for _, row in ipairs(rows) do
			if row.title and row.title:find("Français", 1, true) then return row end
		end
	end
	local ok, failure = xpcall(function()
		body({ root = source, language = language, custom = custom, context = context })
	end, debug.traceback)
	source.hotstring_language_frame, source.hotstring_language_parent_lua,
		source.hotstring_scope_checkbox = saved_frame, saved_parent, saved_check
	if not ok then error(failure, 0) end
end

local function fixture(body)
	local aliases, previous = { "fs", "json", "timer", "sqlite3" }, {}
	for _, name in ipairs(aliases) do
		previous[name] = package.loaded["hs." .. name]
		package.loaded["hs." .. name] = hs[name]
	end
	local ok, failure = xpcall(function() native_fixture(body) end, debug.traceback)
	for _, name in ipairs(aliases) do package.loaded["hs." .. name] = previous[name] end
	if not ok then error(failure, 0) end
end

helpers.describe("actual native Hotstrings language scope frame", function()
	helpers.it("preserves the native count format and genuine category provider order", function()
		fixture(function(f)
			local row = assert(f.language())
			helpers.assert_eq(row.title, "🇫🇷 Français (1 002)")
			helpers.assert_eq(#row.menu, 4)
			helpers.assert_eq(row.menu[2].title, "-")
			helpers.assert_eq(row.menu[3].title, "Second% (999)")
			helpers.assert_eq(row.menu[4].title, "First (3)")
			helpers.assert_eq(row.menu[1].checked, true)
		end)
	end)

	helpers.it("actual provider consumes the shared caption recipe and frame order", function()
		fixture(function(f)
			local source = assert(f.root.hotstring_language_parent_lua, "genuine declared parent required")
			local parent = {}; for key, value in pairs(source[1]) do parent[key] = value end
			parent.caption_count_format = "%s <%s>"
			f.root.hotstring_language_parent_lua = { parent }
			f.root.hotstring_language_frame = {
				{ type = "list", id = "hotstring_language_categories" },
				{ type = "---" }, { type = "list", id = "hotstring_language_switch" },
			}
			local row = assert(f.language())
			helpers.assert_eq(row.title, "🇫🇷 Français <1 002>")
			helpers.assert_eq(row.menu[1].title, "Second% (999)")
			helpers.assert_eq(row.menu[2].title, "First (3)")
			helpers.assert_eq(row.menu[3].title, "-")
			helpers.assert_eq(type(row.menu[4].fn), "function")
		end)
	end)

	helpers.it("scope checkbox keeps its exact native callback and pause posture", function()
		fixture(function(f)
			local selections, calls = {}, 0
			local callback = function() calls = calls + 1; return false end
			local function selected(value) selections[#selections + 1] = value; return callback end
			local row = assert(f.custom.all_sections_row(f.context, { "french_magickey" }, selected))
			helpers.assert_true(rawequal(row.action, callback))
			helpers.assert_eq(row.action(), false)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(selections, { false })
			f.context.paused = true
			row = assert(f.custom.all_sections_row(f.context, { "french_magickey" }, selected))
			helpers.assert_eq(row.disabled, true)
			helpers.assert_eq(row.action, nil)
			helpers.assert_eq(selections, { false }, "paused menus acquire no native write callback")
		end)
	end)

	helpers.it("actual provider refuses missing frame and missing scope checkbox sources", function()
		fixture(function(f)
			f.root.hotstring_language_frame = nil
			helpers.assert_eq(f.language(), nil)
			f.root.hotstring_scope_checkbox = nil
			local acquisitions = 0
			helpers.assert_eq(f.custom.all_sections_row(f.context, { "french_magickey" }, function()
				acquisitions = acquisitions + 1
				return function() return true end
			end), nil)
			helpers.assert_eq(acquisitions, 0, "refused presentation acquires no scope callback")
		end)
	end)
	helpers.it("consumes escaped percent tokens without creating extra scalar slots", function()
		fixture(function(f)
			local original = assert(f.root.hotstring_language_parent_lua)[1]
			assert(original.caption_count_format == "%s (%s)", "literal default recipe retained")
			for _, case in ipairs({
				{ format = "%s (%s)", title = "🇫🇷 Français (1 002)" },
				{ format = "%s (%s) %%s", title = "🇫🇷 Français (1 002) %s" },
				{ format = "%%%s (%s)", title = "%🇫🇷 Français (1 002)" },
				{ format = "%s %%s" },
				{ format = "%%s" },
				{ format = "%s" },
				{ format = "%s %s %s" },
				{ format = "%s (%q)" },
				{ format = "%s (%s) %" },
			}) do
				local parent = {}; for key, value in pairs(original) do parent[key] = value end
				parent.caption_count_format = case.format
				f.root.hotstring_language_parent_lua = { parent }
				local row = f.language()
				if case.title then helpers.assert_eq(assert(row).title, case.title, case.format)
				else helpers.assert_eq(row, nil, case.format .. " must refuse") end
			end
		end)
	end)

end)
