--- tests/unit/modules/hotstrings/test_category_submenu.lua

--- ==============================================================================
--- MODULE: Category Submenus
--- DESCRIPTION:
--- What a hotstring category looks like in the tray, and what its rows do.
---
--- WHY THIS IS ROUGHLY FOUR FIFTHS OF THE MENU:
--- On the other two drivers a category is a submenu: a gate, a way to open its
--- file, and a checkbox per section with the number of entries behind it. On
--- Linux it was ONE line showing the file's own stem with a tick — so the
--- sections, the counts, the localised name and the file were all unreachable,
--- and the menu's category half was the part that did not exist rather than the
--- part that was untranslated.
---
--- WHAT THE COUNTS ARE FOR:
--- A section with three entries and one with nine hundred are the same row
--- without them, and the second is the one a user disables when autocorrection
--- fights them.
---
--- WHY DISABLED AND NOT HIDDEN:
--- Sections under a switched-off category are greyed. A row that disappears
--- reads as a bug, and the user still needs to see what they get back when they
--- switch the category on.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A config module standing in for hotstrings_config, recording what it is asked.
--- @param opts table { enabled = boolean, sections_enabled = table }
--- @return table config, table log
local function fake_config(opts)
	opts = opts or {}
	local log = { toggled = {}, sections = {}, bulk = {} }
	local enabled = opts.enabled ~= false
	local section_state = opts.sections_enabled or {}

	return {
		get_groups = function() return { "rolls" } end,
		is_group_enabled = function(id) return id == "rolls" and enabled or false end,
		toggle_group = function(id) log.toggled[#log.toggled + 1] = id end,
		is_section_enabled = function(_, section)
			if not enabled then return false end
			if section_state[section] == nil then return true end
			return section_state[section]
		end,
		toggle_section = function(id, section)
			log.sections[#log.sections + 1] = id .. "." .. section
		end,
		set_all_sections = function(id, on)
			log.bulk[#log.bulk + 1] = id .. "=" .. tostring(on)
		end,
		get_category = function(id)
			if id ~= "rolls" then return nil end
			return {
				id = "rolls",
				path = "/home/u/.config/ergopti/hotstrings/rolls.toml",
				description = { en = "Rolls", fr = "Roulements" },
				sections_order = { "hc", "sx" },
				sections = { hc = { count = 12 }, sx = { count = 3 } },
				count = 15,
			}
		end,
		reload = function() end,
	}, log
end

--- Builds the menu and returns the rolls category row.
--- @param config table
--- @param ctx_extra table|nil
--- @return table|nil row
local function rolls_row(config, ctx_extra)
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ctx = { config = config, _version = "9.9.9" }
	for k, v in pairs(ctx_extra or {}) do ctx[k] = v end

	local found = nil
	local function search(list)
		for _, item in ipairs(list or {}) do
			if type(item.title) == "string"
				and (item.title:find("Rolls", 1, true) or item.title:find("Roulements", 1, true))
				and type(item.menu) == "table" then
				found = item
				return
			end
			if type(item.menu) == "table" then
				search(item.menu)
				if found then return end
			end
		end
	end
	search(mb.build(ctx))
	return found
end





-- =================================================================
-- =================================================================
-- ======= 1/ The category row itself ==============================
-- =================================================================
-- =================================================================

helpers.describe("category submenu: the row that opens it", function()

	helpers.it("shows the localised name, not the file stem", function()
		local row = rolls_row((fake_config({})))
		helpers.assert_true(row ~= nil, "the category must appear in the menu at all")
		helpers.assert_true(row.title:find("Rolls", 1, true) ~= nil
			or row.title:find("Roulements", 1, true) ~= nil,
			"the packs carry a description in 21 locales and the menu printed the "
				.. "stem — 'distancesreduction' rather than 'Réduction des distances', "
				.. "in every language; got: " .. tostring(row.title))
	end)

	helpers.it("shows how many hotstrings it holds", function()
		local row = rolls_row((fake_config({})))
		helpers.assert_true(row.title:find("15", 1, true) ~= nil,
			"a category is chosen by size as much as by name; got: " .. tostring(row.title))
	end)

	helpers.it("reflects its enabled state as a checkmark", function()
		helpers.assert_eq(rolls_row((fake_config({ enabled = true }))).checked, true, "on")
		helpers.assert_eq(rolls_row((fake_config({ enabled = false }))).checked, false, "off")
	end)

	helpers.it("is a submenu, not a single toggle", function()
		local row = rolls_row((fake_config({})))
		helpers.assert_true(#row.menu >= 4,
			"a gate, a file, the bulk rows and one row per section; a single line "
				.. "cannot express any of it")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ What the rows inside do ==============================
-- =================================================================
-- =================================================================

helpers.describe("category submenu: its rows", function()

	helpers.it("puts the gate first, and it toggles the category", function()
		local config, log = fake_config({})
		local row = rolls_row(config)
		row.menu[1].fn()
		helpers.assert_eq(log.toggled, { "rolls" },
			"everything under the gate is inert while it is off, so it comes first "
				.. "and it must act on the category the user opened")
	end)

	helpers.it("offers the category's own file, at the path the loader resolved", function()
		local config = fake_config({})
		local opened = {}
		local row = rolls_row(config, { on_open_file = function(p) opened[#opened + 1] = p end })
		for _, item in ipairs(row.menu) do
			if type(item.title) == "string" and item.title:lower():find("open") then item.fn() end
			if type(item.title) == "string" and item.title:lower():find("ouvrir") then item.fn() end
		end
		helpers.assert_eq(opened, { "/home/u/.config/ergopti/hotstrings/rolls.toml" },
			"finding a pack by hand means knowing whether it came from the bundle or "
				.. "the user's own directory, which is exactly what the loader resolved")
	end)

	helpers.it("lists every section with its entry count", function()
		local row = rolls_row((fake_config({})))
		local titles = {}
		for _, item in ipairs(row.menu) do
			if type(item.title) == "string" then titles[#titles + 1] = item.title end
		end
		local joined = table.concat(titles, " | ")
		helpers.assert_true(joined:find("hc (12)", 1, true) ~= nil,
			"the section and how many entries it holds: " .. joined)
		helpers.assert_true(joined:find("sx (3)", 1, true) ~= nil,
			"and the next one: " .. joined)
	end)

	helpers.it("lists the sections in the order the file declares", function()
		local row = rolls_row((fake_config({})))
		local hc_at, sx_at
		for i, item in ipairs(row.menu) do
			if type(item.title) == "string" then
				if item.title:find("hc (", 1, true) then hc_at = i end
				if item.title:find("sx (", 1, true) then sx_at = i end
			end
		end
		helpers.assert_true(hc_at ~= nil and sx_at ~= nil and hc_at < sx_at,
			"sections_order groups related rolls together; sorting them alphabetically "
				.. "would scatter them")
	end)

	helpers.it("toggles the section the user clicked", function()
		local config, log = fake_config({})
		local row = rolls_row(config)
		for _, item in ipairs(row.menu) do
			if type(item.title) == "string" and item.title:find("sx (", 1, true) then item.fn() end
		end
		helpers.assert_eq(log.sections, { "rolls.sx" },
			"named, so a menu with two sections cannot toggle the wrong one")
	end)

	helpers.it("checks a section that is on and unchecks one that is off", function()
		local row = rolls_row((fake_config({ sections_enabled = { hc = true, sx = false } })))
		for _, item in ipairs(row.menu) do
			if type(item.title) == "string" and item.title:find("hc (", 1, true) then
				helpers.assert_eq(item.checked, true, "hc is on")
			end
			if type(item.title) == "string" and item.title:find("sx (", 1, true) then
				helpers.assert_eq(item.checked, false, "and sx is off")
			end
		end
	end)

	helpers.it("offers check-all and uncheck-all for the sections", function()
		local config, log = fake_config({})
		local row = rolls_row(config)
		for _, item in ipairs(row.menu) do
			if type(item.title) == "string"
				and (item.title:find("all", 1, true) or item.title:find("tout", 1, true)
					or item.title:find("Tout", 1, true)) then
				item.fn()
			end
		end
		helpers.assert_eq(log.bulk, { "rolls=true", "rolls=false" },
			"a pack with thirty sections is unusable without them, and the order is "
				.. "check then uncheck")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ A switched-off category ==============================
-- =================================================================
-- =================================================================

helpers.describe("category submenu: when the category is off", function()

	helpers.it("greys its sections rather than hiding them", function()
		local row = rolls_row((fake_config({ enabled = false })))
		local seen = 0
		for _, item in ipairs(row.menu) do
			-- A section row is "<name> (<count>)" and nothing else. Matched by shape
			-- rather than by " (" so the gate row — whose localised label ends in a
			-- parenthesised hint — is not mistaken for one.
			if type(item.title) == "string" and item.title:match("^%S+ %(%d+%)$") then
				seen = seen + 1
				helpers.assert_eq(item.disabled, true,
					"a row that disappears reads as a bug, and the user still needs to "
						.. "see what they get back when they switch the category on")
			end
		end
		helpers.assert_true(seen >= 2, "both sections must still be listed; saw " .. seen)
	end)

	helpers.it("leaves the gate itself clickable", function()
		local config, log = fake_config({ enabled = false })
		local row = rolls_row(config)
		helpers.assert_true(not row.menu[1].disabled,
			"greying the gate too would make a disabled category impossible to "
				.. "re-enable from the menu that disabled it")
		row.menu[1].fn()
		helpers.assert_eq(log.toggled, { "rolls" }, "and it must still act")
	end)

end)
