--- tests/unit/ui/test_menu_extension_hotstrings.lua

--- ==============================================================================
--- MODULE: Hotstrings Menu — Extension Submenus (Linux)
--- DESCRIPTION:
--- The Hotstrings menu lists the hotstrings an extension brings under one
--- « Hotstrings <extension> » submenu in its extensions section. The Ergopti
--- layout extension binds SFB reduction and rolls there, under their historical
--- ids, instead of a « Disposition Ergopti » section of their own; without the
--- extension they are not listed.
--- ==============================================================================

local helpers = require("tests.helpers")
local manifest_file = assert(io.open(helpers.driver_root() .. "/../../layouts/registry/ergopti/manifest.toml", "r"))
local shipped = require("toml_codec.codec").decode(assert(manifest_file:read("*a"))).extension
assert(manifest_file:close())

--- A hotstrings config double whose loaded categories name their extension.
--- @param with_ergopti boolean Whether the Ergopti extension supplied its categories.
--- @return table
local function fake_config(with_ergopti)
	local ergopti = { id = shipped.id, name = shipped.name }
	local categories = {
		magickey = { id = "magickey", count = 3, sections_order = { "symbols" },
			sections = { symbols = { count = 3 } } },
	}
	if with_ergopti then
		categories.magickey.count = 17
		categories.magickey.sections_order = { "repeat_corrections", "symbols" }
		categories.magickey.sections.repeat_corrections = { count = 14, extension = ergopti }
		categories.sfbsreduction = { id = "sfbsreduction", count = 5, extension = ergopti,
			sections_order = { "comma" }, sections = { comma = { count = 5 } } }
		categories.rolls = { id = "rolls", count = 7, extension = ergopti,
			sections_order = { "hc" }, sections = { hc = { count = 7 } } }
	end
	return {
		get_groups = function()
			local out = { "magickey" }
			if with_ergopti then out[#out + 1] = "rolls"; out[#out + 1] = "sfbsreduction" end
			return out
		end,
		is_group_enabled = function() return true end,
		toggle_group = function() end,
		enable_all = function() end,
		disable_all = function() end,
		is_section_enabled = function() return true end,
		get_category = function(id) return categories[id] end,
		get_categories = function() return categories end,
		language_packs = function() return {} end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}
end

--- Every row title of a built tree, depth first.
--- @param items table
--- @param out table|nil
--- @return table
local function titles(items, out)
	out = out or {}
	for _, item in ipairs(items or {}) do
		if type(item.title) == "string" then out[#out + 1] = item end
		if type(item.menu) == "table" then titles(item.menu, out) end
	end
	return out
end

--- The first row whose title starts with `prefix`.
--- @param items table
--- @param prefix string
--- @return table|nil
local function row_starting(items, prefix)
	for _, row in ipairs(titles(items)) do
		if row.title:sub(1, #prefix) == prefix then return row end
	end
	return nil
end

helpers.describe("Hotstrings menu (linux): extension submenus", function()
	helpers.it("(ergopti-hotstrings-ext) lists SFB reduction and rolls in a Hotstrings Ergopti submenu", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local i18n = require("infra.i18n")
		local label = string.format(i18n.get("menu.extensions.hotstrings_of"), "Ergopti+")
		local row = row_starting(mb.build({ config = fake_config(true), _version = "9.9.9" }), label)
		helpers.assert_true(row ~= nil, "the « " .. label .. " » submenu must be drawn")
		local inside = {}
		for _, child in ipairs(row.menu or {}) do inside[#inside + 1] = child.title end
		local text = table.concat(inside, "|")
		-- The rows are the categories' own submenus, labelled by their category.
		helpers.assert_true(text:find(" (7)", 1, true) ~= nil, "rolls: " .. text)
		helpers.assert_true(text:find(" (5)", 1, true) ~= nil, "SFB reduction: " .. text)
		helpers.assert_true(text:find("repeat_corrections (14)", 1, true) ~= nil, "repeat corrections: " .. text)
		-- The menu manifest's order, which Windows walks too and every driver
		-- listed before the move, although rolls loads first here.
		helpers.assert_true(text:find(" (5)", 1, true) < text:find(" (7)", 1, true),
			"SFB reduction comes before rolls: " .. text)
	end)

	helpers.it("(ergopti-hotstrings-ext) takes the repeat corrections out of the magic key submenu", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local built = mb.build({ config = fake_config(true), _version = "9.9.9" })
		local label = string.format(require("infra.i18n").get("menu.extensions.hotstrings_of"), "Ergopti+")
		local seen = 0
		for _, row in ipairs(titles(built)) do
			if row.title:find("repeat_corrections", 1, true) then seen = seen + 1 end
		end
		helpers.assert_eq(seen, 1, "the section is drawn once, in the Ergopti submenu")
		helpers.assert_true(row_starting(built, label) ~= nil)
		local symbols = row_starting(built, "symbols (3)")
		helpers.assert_true(symbols ~= nil, "the magic key keeps its own sections")
	end)

	helpers.it("(ergopti-hotstrings-ext) draws no Ergopti submenu when the extension is not installed", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local i18n = require("infra.i18n")
		local label = string.format(i18n.get("menu.extensions.hotstrings_of"), "Ergopti+")
		helpers.assert_nil(row_starting(mb.build({ config = fake_config(false), _version = "9.9.9" }), label))
	end)
end)


-- Capture only the fixture's actual renderer/consumer cohort and restore exact owners.
local function with_extension_frame(body, paused)
	local names = { "infra.manifest_menu", "ui.menu.menu_builder" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local ok, err = pcall(function()
		local translator = require("infra.i18n")
		local renderer = assert(require("menu.renderer").new({ platform = "linux",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = require("json").decode, i18n = translator, logger = require("logger.shim"),
		}))
		package.loaded["infra.manifest_menu"] = renderer
		local owner = helpers.load_module("ui.menu.menu_builder")
		local context = { config = fake_config(true), paused = paused == true, _version = "9.9.9" }
		context.is_paused = function() return context.paused end
		local label = string.format(translator.get("menu.extensions.hotstrings_of"), "Ergopti+")
		body({ root = renderer.get_root(), translator = translator, context = context,
			build = function() return row_starting(owner.build(context), label) end })
	end)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("complete installed extension shared frames (Linux)", function()
	helpers.it("retains the full command, category and bound-section order", function()
		with_extension_frame(function(f)
			local rows = assert(f.build()).menu
			helpers.assert_eq(#rows, 7)
			helpers.assert_eq(rows[1].title, f.translator.get("menu.hotstrings.check_all"))
			helpers.assert_eq(rows[2].title, f.translator.get("menu.hotstrings.uncheck_all"))
			helpers.assert_eq(rows[3].title, "-")
			helpers.assert_eq(rows[4].title, "sfbsreduction (5)")
			helpers.assert_eq(rows[5].title, f.translator.get("category.rolls") .. " (7)")
			helpers.assert_eq(rows[6].title, "-")
			helpers.assert_eq(rows[7].title, "repeat_corrections (14)")
			helpers.assert_eq(rows[7].checked, true)
			local writes = 0
			f.context.config.set_extension_sections_enabled = function() writes = writes + 1; return true end
			f.context.paused = true
			helpers.assert_eq(rows[1].fn(), false); helpers.assert_eq(rows[2].fn(), false)
			helpers.assert_eq(writes, 0)
		end)
	end)
	helpers.it("preserves the genuine paused top-level withdrawal of extension children", function()
		with_extension_frame(function(f)
			helpers.assert_eq(f.build(), nil)
		end, true)
	end)
	for _, section in ipairs({ "hotstring_extension_bulk_controls", "hotstring_extension_content_frame", "hotstrings_parameter_boundary" }) do
		helpers.it("withdraws and repairs missing " .. section .. " in the real installed provider", function()
			with_extension_frame(function(f)
				local saved = f.root[section]; f.root[section] = nil
				helpers.assert_eq(f.build(), nil)
				f.root[section] = saved
				helpers.assert_type(f.build(), "table")
			end)
		end)
	end
	helpers.it("refuses an unbound child slot and restores the current declaration", function()
		with_extension_frame(function(f)
			local row = f.root.hotstring_extension_content_frame[5]
			local saved = row.id; row.id = "foreign_extension_bound_rows"
			helpers.assert_eq(f.build(), nil)
			row.id = saved
			helpers.assert_type(f.build(), "table")
		end)
	end)
	helpers.it("reads both declared bulk captions through the authentic native provider", function()
		with_extension_frame(function(f)
			f.root.hotstring_extension_bulk_controls[2].i18n = "button.ok"
			f.root.hotstring_extension_bulk_controls[3].i18n = "button.cancel"
			local rows = assert(f.build()).menu
			helpers.assert_eq(rows[1].title, f.translator.get("button.ok"))
			helpers.assert_eq(rows[2].title, f.translator.get("button.cancel"))
		end)
	end)
	helpers.it("restores the genuine Linux cohort after a raised provider scenario", function()
		local names = { "infra.manifest_menu", "ui.menu.menu_builder" }
		local before = {}; for _, name in ipairs(names) do before[name] = package.loaded[name] end
		local ok, err = pcall(function()
			with_extension_frame(function(f) assert(f.build()); error("extension frame scenario sentinel", 0) end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("extension frame scenario sentinel", 1, true) ~= nil)
		for _, name in ipairs(names) do helpers.assert_true(rawequal(package.loaded[name], before[name]), name) end
	end)
end)


-- The standard-category empty marker is inert presentation owned by its live list.
local function read_standard_empty_json(path)
	local file = assert(io.open(path, "rb"))
	local value = assert(require("json").decode(file:read("*a")))
	file:close()
	return value
end

local StandardEmptyCorpus = read_standard_empty_json(require("infra.paths").shared("tests/corpus/menus/linux_standard_category_empty_status.json"))

--- Observes the real registered provider while forwarding the full public build.
--- @param callback function Receives native build, captured data and genuine binding.
local function with_standard_empty(callback, locale)
	local old_builder = package.loaded["ui.menu.menu_builder"]
	local binding = require("infra.manifest_menu")
	local i18n = require("infra.i18n")
	local old_build, old_status, old_get, old_locale = binding.build, binding.status_rows, i18n.get, i18n.get_locale
	local owner
	for _, row in ipairs(binding.get_array(StandardEmptyCorpus.section)) do
		if row.id == StandardEmptyCorpus.provider then
			helpers.assert_nil(owner, "the standard provider must have one actual declaration")
			owner = row
		end
	end
	assert(owner, "the real standard-category list declaration is required")
	local old_statuses = owner.status_rows
	local state = { loaded = false, data = nil, delivered = nil, writes = {} }
	local categories = {
		magickey = { id = "magickey", description = { en = "Native magic" }, count = 3, sections_order = {}, sections = {} },
		autocorrection = { id = "autocorrection", description = { en = "Native corrections" }, count = 2, sections_order = {}, sections = {} },
	}
	local config = {
		get_groups = function() return state.loaded and { "magickey", "autocorrection" } or {} end,
		get_categories = function() return state.loaded and categories or {} end,
		get_category = function(id) return state.loaded and categories[id] or nil end,
		active_count = function(id) return categories[id] and categories[id].count or 0 end,
		is_group_enabled = function() return true end,
		is_section_enabled = function() return true end,
		any_enabled = function() return state.loaded end,
		language_packs = function() return {} end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
		set_category_scope_enabled = function(ids, enabled)
			state.writes[#state.writes + 1] = { ids = ids, enabled = enabled }
			return true
		end,
	}
	local ok, detail = xpcall(function()
		local catalogue = read_standard_empty_json(require("infra.paths").shared("data/locales/" .. (locale or "en") .. ".json"))
		i18n.get = function(key) return catalogue[key] or key end
		i18n.get_locale = function() return locale or "en" end
		binding.build = function(key, category, dynamic, builders, ctx, providers)
			if key == StandardEmptyCorpus.section then
				local provider = assert(providers[StandardEmptyCorpus.provider], "actual standard provider registered")
				providers[StandardEmptyCorpus.provider] = function(...)
					state.data = provider(...)
					return state.data
				end
			end
			local rows = old_build(key, category, dynamic, builders, ctx, providers)
			if key == StandardEmptyCorpus.section then state.delivered = rows end
			return rows
		end
		local module = helpers.load_module("ui.menu.menu_builder")
		local function build()
			state.data, state.delivered = nil, nil
			local items = module.build({ config = config, _version = "9.9.9" })
			local title = i18n.get("menu.hotstrings.title")
			for _, row in ipairs(items or {}) do
				if type(row.title) == "string" and row.title:sub(1, #title) == title then
					helpers.assert_true(rawequal(row.menu, state.delivered), "real full tray publishes the completed Hotstrings menu")
					helpers.assert_type(state.data, "table", "actual list provider was consumed")
					local first, last
					for index, child in ipairs(row.menu) do
						if child.title == i18n.section("menu.hotstrings.header_common") then
							helpers.assert_nil(first, "one actual common-category header")
							first = index
						elseif child.title == i18n.section("menu.hotstrings.header_languages") then
							helpers.assert_nil(last, "one actual language header")
							last = index
						end
					end
					helpers.assert_not_nil(first); helpers.assert_not_nil(last)
					helpers.assert_true(first < last, "actual provider publication stays in its declared block")
					local standard = {}
					for index = first + 1, last - 1 do
						if row.menu[index].title ~= "-" then standard[#standard + 1] = row.menu[index] end
					end
					return standard
				end
			end
			error("the actual public builder must publish Hotstrings")
		end
		callback(build, state, binding, owner, catalogue)
	end, debug.traceback)
	owner.status_rows = old_statuses
	binding.build, binding.status_rows, i18n.get, i18n.get_locale = old_build, old_status, old_get, old_locale
	package.loaded["ui.menu.menu_builder"] = old_builder
	if not ok then error(detail, 0) end
end

local function count_standard_empty(rows, caption)
	local count = 0
	for _, row in ipairs(rows or {}) do
		if row.title == caption then
			count = count + 1
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_nil(row.menu)
		end
	end
	return count
end

helpers.describe("shared Linux standard-category empty status", function()
	for locale, expected in pairs(StandardEmptyCorpus.captions) do
		helpers.it("(standard-category-empty-status) retains the native inert caption in " .. locale, function()
			with_standard_empty(function(build, state, _, owner, catalogue)
				helpers.assert_eq(catalogue[StandardEmptyCorpus.row.i18n], expected)
				helpers.assert_eq(owner.status_rows[StandardEmptyCorpus.status], { StandardEmptyCorpus.row })
				local rows = build()
				helpers.assert_eq(state.data, { { label = expected, disabled = true } })
				helpers.assert_eq(count_standard_empty(rows, expected), 1)
				helpers.assert_eq(#state.writes, 0)
			end, locale)
		end)
	end

	helpers.it("(standard-category-empty-status) consumes a changed shared caption through the actual provider", function()
		with_standard_empty(function(build, state, _, owner, catalogue)
			local replacement = "menu.layout.none_installed"
			owner.status_rows = { [StandardEmptyCorpus.status] = { { type = "label", i18n = replacement } } }
			local rows = build()
			helpers.assert_eq(state.data, { { label = catalogue[replacement], disabled = true } })
			helpers.assert_eq(count_standard_empty(rows, catalogue[replacement]), 1)
			helpers.assert_eq(count_standard_empty(rows, StandardEmptyCorpus.captions.en), 0)
			helpers.assert_eq(#state.writes, 0)
		end)
	end)

	for _, invalid in ipairs({ "missing_status", "missing_statuses", "empty", "command", "effectful_label" }) do
		helpers.it("(standard-category-empty-status) refuses inert publication after " .. invalid, function()
			with_standard_empty(function(build, state, _, owner)
				helpers.assert_eq(count_standard_empty(build(), StandardEmptyCorpus.captions.en), 1)
				local bad = {
					empty = {}, command = { { type = "command", id = "foreign", i18n = StandardEmptyCorpus.row.i18n } },
					effectful_label = { { type = "label", i18n = StandardEmptyCorpus.row.i18n, action = function() state.writes[#state.writes + 1] = "forbidden" end } },
				}
				if invalid == "missing_statuses" then owner.status_rows = nil
				else owner.status_rows = { [StandardEmptyCorpus.status] = bad[invalid] } end
				local rows = build()
				helpers.assert_eq(state.data, {})
				helpers.assert_eq(count_standard_empty(rows, StandardEmptyCorpus.captions.en), 0)
				helpers.assert_eq(#state.writes, 0)
			end)
		end)
	end

	helpers.it("(standard-category-empty-status) refuses an unavailable status port without native fallback", function()
		with_standard_empty(function(build, state, binding)
			helpers.assert_eq(count_standard_empty(build(), StandardEmptyCorpus.captions.en), 1)
			binding.status_rows = nil
			helpers.assert_eq(count_standard_empty(build(), StandardEmptyCorpus.captions.en), 0)
			helpers.assert_eq(state.data, {})
			helpers.assert_eq(#state.writes, 0)
		end)
	end)

	helpers.it("(standard-category-empty-status) preserves loaded order, ticks and genuine category callbacks", function()
		with_standard_empty(function(build, state, _, owner)
			state.loaded = true
			owner.status_rows = nil
			local rows = build()
			helpers.assert_eq(#state.data, 2)
			helpers.assert_eq(state.data[1].label, "Native magic (3)")
			helpers.assert_eq(state.data[2].label, "Native corrections (2)")
			local first, second
			for index, row in ipairs(rows) do
				if row.title == "Native magic (3)" then first = index end
				if row.title == "Native corrections (2)" then second = index end
			end
			helpers.assert_not_nil(first); helpers.assert_eq(second, first + 1)
			for index, position in ipairs({ first, second }) do
				local native, data = rows[position], state.data[index]
				helpers.assert_eq(native.checked, true)
				helpers.assert_true(rawequal(native.menu, data.submenu))
				helpers.assert_eq(native.menu[1].fn(), true)
				helpers.assert_eq(native.menu[2].fn(), true)
			end
			helpers.assert_eq(state.writes, {
				{ ids = { "magickey" }, enabled = true }, { ids = { "magickey" }, enabled = false },
				{ ids = { "autocorrection" }, enabled = true }, { ids = { "autocorrection" }, enabled = false },
			})
			helpers.assert_eq(count_standard_empty(rows, StandardEmptyCorpus.captions.en), 0)
		end)
	end)
end)
