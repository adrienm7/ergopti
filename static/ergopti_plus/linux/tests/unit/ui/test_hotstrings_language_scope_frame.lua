--- tests/unit/ui/test_hotstrings_language_scope_frame.lua

--- ==============================================================================
--- MODULE: Actual Hotstring Language Scope Presentation
--- DESCRIPTION:
--- Exercises the genuine native provider against independently authored language
--- order, counted captions, borrowed category identity and publication callbacks.
--- Catalogue producers and scope writers remain the native owner's authority.
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

local function fixture(body)
	local native = require("infra.i18n")
	native.init()
	local renderer = require("infra.manifest_menu")
	local builder = require("ui.menu.menu_builder")
	local build = upvalue(builder.build, "_build_hotstrings")
	local source = renderer.get_root()
	local saved_frame, saved_parent, saved_check = source.hotstring_language_frame,
		source.hotstring_language_parent_lua, source.hotstring_scope_checkbox
	local categories = {
		french_autocorrection = { id = "french_autocorrection", count = 3,
			sections = { alpha = { count = 3 } }, sections_order = { "alpha" } },
		french_magickey = { id = "french_magickey", count = 999,
			sections = { beta = { count = 999 } }, sections_order = { "beta" } },
	}
	local writes, selected, desired, acknowledgement = 0, nil, nil, true
	local config = {
		get_groups = function() return { "french_autocorrection", "french_magickey" } end,
		get_categories = function() return categories end,
		get_category = function(id) return categories[id] end,
		is_group_enabled = function() return true end,
		is_section_enabled = function() return true end,
		language_packs = function()
			return { { id = "french", locale = "fr", categories = { "magickey", "absent", "autocorrection" } } }
		end,
		set_categories_sections = function(ids, enabled)
			writes, selected, desired = writes + 1, ids, enabled
			return acknowledgement
		end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}
	local function language()
		local rows = assert(build({ config = config }).submenu)
		for _, row in ipairs(rows) do
			if row.title and row.title:find("Français", 1, true) then return row end
		end
	end
	local ok, failure = xpcall(function()
		body({ root = source, language = language,
			writes = function() return writes, selected, desired end,
			refuse = function() acknowledgement = false end })
	end, debug.traceback)
	source.hotstring_language_frame, source.hotstring_language_parent_lua,
		source.hotstring_scope_checkbox = saved_frame, saved_parent, saved_check
	if not ok then error(failure, 0) end
end

helpers.describe("actual native Hotstrings language scope frame", function()
	helpers.it("preserves exact caption, categories in native order and aggregate callback targets", function()
		fixture(function(f)
			local row = assert(f.language())
			helpers.assert_eq(row.title, "🇫🇷 Français (1002)")
			helpers.assert_eq(#row.menu, 4)
			helpers.assert_eq(row.menu[2].title, "-")
			helpers.assert_eq(row.menu[3].title, "french_magickey (999)")
			helpers.assert_eq(row.menu[4].title, "french_autocorrection (3)")
			helpers.assert_eq(row.menu[1].checked, true, "native gates own the all-on state")
			helpers.assert_eq(row.menu[1].fn(), true)
			local writes, ids, enabled = f.writes()
			helpers.assert_eq(writes, 1)
			helpers.assert_eq(table.concat(ids, ","), "french_magickey,french_absent,french_autocorrection")
			helpers.assert_eq(enabled, false)
		end)
	end)

	helpers.it("actual provider consumes the shared caption recipe and actual category frame order", function()
		fixture(function(f)
			assert(type(f.root.hotstring_language_parent_lua) == "table", "genuine declared language parent required")
			local parent = {}
			for k, v in pairs(f.root.hotstring_language_parent_lua[1]) do parent[k] = v end
			parent.caption_count_format = "%s <%s>"
			f.root.hotstring_language_parent_lua = { parent }
			f.root.hotstring_language_frame = {
				{ type = "list", id = "hotstring_language_categories" },
				{ type = "---" }, { type = "list", id = "hotstring_language_switch" },
			}
			local row = assert(f.language())
			helpers.assert_eq(row.title, "🇫🇷 Français <1002>")
			helpers.assert_eq(row.menu[1].title, "french_magickey (999)")
			helpers.assert_eq(row.menu[2].title, "french_autocorrection (3)")
			helpers.assert_eq(row.menu[3].title, "-")
			helpers.assert_eq(type(row.menu[4].fn), "function")
			helpers.assert_eq(f.writes(), 0, "presentation owns no durable write")
		end)
	end)

	helpers.it("actual provider refuses a missing language declaration before any native writer", function()
		fixture(function(f)
			f.root.hotstring_language_frame = nil
			helpers.assert_eq(f.language(), nil)
			helpers.assert_eq(f.writes(), 0)
		end)
	end)

	helpers.it("actual provider refuses a malformed caption recipe before any native writer", function()
		fixture(function(f)
			local parent = assert(f.root.hotstring_language_parent_lua)
			local copy = {}; for k, v in pairs(parent[1]) do copy[k] = v end
			copy.caption_count_format = "%s %q"
			f.root.hotstring_language_parent_lua = { copy }
			helpers.assert_eq(f.language(), nil)
			helpers.assert_eq(f.writes(), 0)
		end)
	end)
	helpers.it("consumes escaped percent tokens without creating extra scalar slots", function()
		fixture(function(f)
			local original = assert(f.root.hotstring_language_parent_lua)[1]
			assert(original.caption_count_format == "%s (%s)", "literal default recipe retained")
			for _, case in ipairs({
				{ format = "%s (%s)", title = "🇫🇷 Français (1002)" },
				{ format = "%s (%s) %%s", title = "🇫🇷 Français (1002) %s" },
				{ format = "%%%s (%s)", title = "%🇫🇷 Français (1002)" },
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
