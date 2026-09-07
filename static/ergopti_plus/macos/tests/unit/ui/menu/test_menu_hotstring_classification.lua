--- tests/unit/ui/menu/test_menu_hotstring_classification.lua

--- ==============================================================================
--- MODULE: Hotstring Menu Classification Tests
--- DESCRIPTION:
--- Resolves real preference group names before looking up registered sections.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_classification(callback)
	return helpers.with_fresh_modules({ "infra.preferences", "ui.menu.hotstring_counter",
		"infra.logger", "infra.toml.codec", "adapters.file_system", "infra.fs_dir", "menu.labels" }, function()
		-- This contract is pure name resolution and counting, with no persistence or directory access
		local function unexpected_io() error("Classification must not access files", 0) end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.toml.codec"] = { encode = unexpected_io, decode = unexpected_io }
		package.loaded["adapters.file_system"] = { read_with_status = unexpected_io }
		package.loaded["infra.fs_dir"] = { try_entries = unexpected_io }
		local preferences = require("infra.preferences")
		local counter = require("ui.menu.hotstring_counter")
		local sections = {
			sfbsreduction = { { name = "test", count = 10 } },
			rolls = { { name = "test", count = 10 } },
			autocorrection = { { name = "test", count = 10 } },
		}
		local context = {
			hotfiles = {
				"/root/hotstrings/sfbsreduction.toml",
				"/root/hotstrings/rolls.toml",
				"/root/hotstrings/autocorrection.toml",
			},
			get_group_name = preferences.get_group_name,
			keymap = {
				get_sections = function(name) return sections[name] or {} end,
				is_group_enabled = function() return true end,
				is_section_enabled = function() return true end,
			},
		}
		callback(counter, context)
	end)
end

helpers.describe("Hotstrings Menu Classification", function()
	helpers.it("correctly classifies sfbsreduction and rolls as Ergopti groups", function()
		with_classification(function(counter, context)
			local ergopti_groups = { sfbs_reduction = true, rolls = true, sfbsreduction = true }
			local result = counter.count_all(context, ergopti_groups)
			helpers.assert_eq(result.ergopti, 20, "sfbsreduction and rolls should contribute 10 each to ergopti")
			helpers.assert_eq(result.common, 10, "autocorrection should contribute 10 to common")
		end)
	end)

	helpers.it("extracts real preference group names from absolute and relative paths (group-name-classification)", function()
		with_classification(function(_, context)
			for _, path in ipairs({ "/abs/path/to/mygroup.toml", "mygroup.toml",
				"/abs/path/to/mygroup.lua", "mygroup.lua", "C:\\hotstrings\\mygroup.toml" }) do
				helpers.assert_eq(context.get_group_name(path), "mygroup", path)
			end
		end)
	end)
end)
