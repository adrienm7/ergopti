--- tests/unit/modules/hotstrings/test_section_opt_in_defaults.lua

--- ==============================================================================
--- MODULE: Hotstring Sections Are Opt-In
--- DESCRIPTION:
--- Every bundled hotstring section ships disabled and the user opts in. The
--- choices are canonical config.toml keys read through the manifest's neutral
--- defaults, so an absent key is OFF and a missed lookup cannot switch the
--- corpus back on.
---
--- Also pins the language-pack bulk action: « tout activer » on the French
--- submenu enables every section of every French category in one write.
--- ==============================================================================

local helpers = require("tests.helpers")
local Choices = require("tests.support.hotstring_choices")

local CATEGORIES = {
	french_autocorrection = { id = "french_autocorrection", sections_order = { "accents", "minus" },
		sections = { accents = { count = 1 }, minus = { count = 1 } } },
	french_magickey = { id = "french_magickey", sections_order = { "text_expansion" },
		sections = { text_expansion = { count = 1 } } },
}

--- Runs body against a config manager over two known categories and a private,
--- initially absent config.toml.
--- @param body function body(Config, path)
--- @param source string|nil Private initial configuration bytes.
--- @param reject_candidate boolean|nil Refuses the second native publication only.
local function with_config(body, source, reject_candidate)
	local saved_loader = package.loaded["modules.hotstrings.loader"]
	package.loaded["modules.hotstrings.loader"] = {
		find_toml_files = function() return {} end,
		list_subdirs = function() return {} end,
		read_file = function() return nil end,
		load_catalogue = function()
			return { committed = true, errors = 0, categories = CATEGORIES, mappings = {
				{ trigger = "acc", replacement = "accents", group = "french_autocorrection", section = "accents" },
				{ trigger = "exp", replacement = "expansion", group = "french_magickey", section = "text_expansion" },
			} }
		end,
	}
	local ok, err = pcall(function()
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		Choices.with_file(Config, source, function(path)
			local published = {}
			Config.init({ load_mappings = function(_, mappings)
				published[#published + 1] = mappings
				return not (reject_candidate and #published == 2)
			end },
				"virtual.toml", nil)
			local _, committed = Config.load_all()
			helpers.assert_true(committed, "the fixture catalogue must publish")
			body(Config, path, published)
		end)
	end)
	package.loaded["modules.hotstrings.loader"] = saved_loader
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	if not ok then error(err, 0) end
end

local CATEGORY_SOURCE = "[category_enabled]\nhotstrings = false\n"
	.. "[hotstrings]\ngroups = { french_autocorrection = false, french_magickey = true }\n"
	.. "[hotstrings.modules.french_autocorrection]\naccents = true\nminus = false\n"
	.. "[hotstrings.modules.french_magickey]\ntext_expansion = true\n"
	.. '[private]\ncredential = "retain-fixture-value"\n'

helpers.describe("explicit hotstring category selection", function()
	for _, enabled in ipairs({ true, false }) do
		helpers.it("(hotstring-category-owner) commits category and sections " .. tostring(enabled), function()
			with_config(function(Config, path, published)
				helpers.assert_eq(Config.set_category_scope_enabled({ "french_autocorrection" }, enabled), true)
				helpers.assert_eq(Config.is_group_enabled("french_autocorrection"), enabled)
				for _, section in ipairs({ "accents", "minus" }) do
					helpers.assert_eq(Config.is_section_checked("french_autocorrection", section), enabled)
				end
				helpers.assert_eq(Config.is_group_enabled("french_magickey"), true)
				helpers.assert_eq(Config.is_section_checked("french_magickey", "text_expansion"), true)
				helpers.assert_eq(#published[#published], enabled and 2 or 1)
				local decoded = require("toml_codec").decode(Choices.read(path))
				helpers.assert_eq(decoded.category_enabled.hotstrings, false, "the independent master stays disabled")
				helpers.assert_eq(decoded.private.credential, "retain-fixture-value")
				helpers.assert_eq(Config.refresh_choices(), true, "the canonical reread must commit")
				helpers.assert_eq(Config.is_group_enabled("french_autocorrection"), enabled,
					"a canonical reread retains the committed selection")
			end, CATEGORY_SOURCE)
		end)

		for _, refusal in ipairs({ "false", "nil", "throw", "runtime" }) do
			helpers.it("(hotstring-category-owner) rolls back " .. tostring(enabled) .. "/" .. refusal, function()
				with_config(function(Config, path, published)
					local writer = require("toml_codec.writer")
					local previous = writer.batch_write
					local writes = 0
					writer.batch_write = function(...)
						writes = writes + 1
						if refusal == "throw" then error("injected write failure") end
						if refusal == "nil" then return nil end
						if refusal == "false" then return false end
						return previous(...)
					end
					local called, committed = pcall(Config.set_category_scope_enabled, { "french_autocorrection" }, enabled)
					writer.batch_write = previous
					helpers.assert_eq(called, true, "the owner contains a native refusal")
					helpers.assert_eq(committed, false)
					helpers.assert_eq(writes, refusal == "runtime" and 0 or 1)
					helpers.assert_eq(Choices.read(path), CATEGORY_SOURCE, "the exact source remains authoritative")
					helpers.assert_eq(Config.is_group_enabled("french_autocorrection"), false)
					helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), true)
					helpers.assert_eq(Config.is_section_checked("french_autocorrection", "minus"), false)
					helpers.assert_eq(Config.is_group_enabled("french_magickey"), true)
					helpers.assert_eq(#published[#published], 1, "the previous native catalogue is republished")
					helpers.assert_eq(published[#published][1].trigger, "exp")
				end, CATEGORY_SOURCE, refusal == "runtime")
			end)
		end
	end

	helpers.it("(hotstring-category-owner) rejects an unknown sibling without publishing or writing", function()
		with_config(function(Config, path, published)
			local before = #published
			helpers.assert_eq(Config.set_category_scope_enabled({ "french_autocorrection", "missing" }, true), false)
			helpers.assert_eq(#published, before)
			helpers.assert_eq(Choices.read(path), CATEGORY_SOURCE)
		end, CATEGORY_SOURCE)
	end)
end)

helpers.describe("hotstrings config: sections are opt-in", function()

	helpers.it("(hs-opt-in-linux) bundled and personal sections require explicit activation", function()
		with_config(function(Config, _, published)
			helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), false,
				"the manifest ships every bundled section disabled")
			helpers.assert_eq(Config.is_section_checked("distancesreduction", "qu"), false,
				"the file-stem spelling of a manifest category must find its row")
			helpers.assert_eq(Config.is_section_checked("personal", "anything"), false,
				"loading a personal pack does not grant activation")
			helpers.assert_eq(Config.is_group_enabled("french_autocorrection"), false,
				"an empty configuration opens no category gate")
			helpers.assert_eq(#published[#published], 0, "nothing reaches the engine without explicit intent")
		end)
	end)

	helpers.it("(hs-opt-in-linux) the language bulk action switches every French section on, then off", function()
		with_config(function(Config, path, published)
			helpers.assert_true(Config.set_categories_sections({ "french_autocorrection", "french_magickey" }, true))
			helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), true)
			helpers.assert_eq(Config.is_section_checked("french_autocorrection", "minus"), true)
			helpers.assert_eq(Config.is_section_checked("french_magickey", "text_expansion"), true)
			helpers.assert_eq(#published[#published], 2, "both activated sections reach the engine")
			local decoded = require("toml_codec").decode(Choices.read(path))
			helpers.assert_eq(decoded.hotstrings.groups.french_autocorrection, true)
			helpers.assert_eq(decoded.hotstrings.modules.french_autocorrection, { accents = true, minus = true })
			helpers.assert_true(Config.set_categories_sections({ "french_autocorrection", "french_magickey" }, false))
			helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), false)
			helpers.assert_eq(Config.is_section_checked("french_magickey", "text_expansion"), false)
			decoded = require("toml_codec").decode(Choices.read(path))
			for category, sections in pairs(decoded.hotstrings.modules or {}) do
				helpers.assert_eq(next(sections), nil, category .. " sections return to neutral absence")
			end
			helpers.assert_eq(decoded.hotstrings.groups.french_autocorrection, true,
				"switching sections off keeps the category's own choice")
		end)
	end)

	-- The setup wizard writes its hotstring answers only to config.toml, at the
	-- manifest's Linux file_path and section_path: this runtime must read them
	-- there, or a Yes is saved and reported while every section stays off.
	helpers.it("(hs-opt-in-linux) the wizard's config.toml answers are the choices in force", function()
		local Answers = require("onboarding_answers")
		local handle = assert(io.open(helpers.driver_root() .. "/../_shared/" .. Answers.CATALOGUE_PATH, "r"))
		local index = Answers.load(handle:read("*a"), "linux")
		handle:close()
		local operations = {
			{ path = "hotstrings.groups.french_autocorrection", value = true },
			{ path = "hotstrings.modules.french_autocorrection.accents", value = true },
		}
		for _, operation in ipairs(operations) do
			helpers.assert_not_nil(index.entries[operation.path], "the Linux wizard asks for " .. operation.path)
		end
		local rows = assert(Answers.rows(index, operations, require("infra.manifest_reader")))
		local lines = {}
		for _, row in ipairs(rows) do
			helpers.assert_nil(row.delete, "an opt-in answer is an explicit value")
			lines[#lines + 1] = "[" .. row.section .. "]\n" .. row.key .. " = " .. tostring(row.value) .. "\n"
		end
		local saved_loader = package.loaded["modules.hotstrings.loader"]
		package.loaded["modules.hotstrings.loader"] = {
			find_toml_files = function() return {} end,
			list_subdirs = function() return {} end,
			read_file = function() return nil end,
			load_catalogue = function()
				return { committed = true, errors = 0, categories = CATEGORIES, mappings = {} }
			end,
		}
		local ok, err = pcall(function()
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			Choices.with_file(Config, table.concat(lines), function()
				Config.init({ load_mappings = function() return true end }, "virtual.toml", nil)
				local _, committed = Config.load_all()
				helpers.assert_true(committed, "the fixture catalogue must publish")
				helpers.assert_eq(Config.is_group_enabled("french_autocorrection"), true)
				helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), true)
				helpers.assert_eq(Config.is_section_checked("french_autocorrection", "minus"), false,
					"a section the wizard left unanswered stays opt-in")
			end)
		end)
		package.loaded["modules.hotstrings.loader"] = saved_loader
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		if not ok then error(err, 0) end
	end)

	helpers.it("(hs-opt-in-linux) an unknown category refuses the whole language write", function()
		with_config(function(Config, path)
			helpers.assert_eq(Config.set_categories_sections({ "french_autocorrection", "nope" }, true), false)
			helpers.assert_eq(Config.is_section_checked("french_autocorrection", "accents"), false,
				"a refused language write must not publish a partial candidate")
			helpers.assert_nil(Choices.read(path), "a refused language write leaves the file absent")
		end)
	end)
end)
