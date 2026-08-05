--- tests/unit/modules/hotstrings/test_category_counts_and_ticks.lua

--- ==============================================================================
--- MODULE: What a Category Row Reports
--- DESCRIPTION:
--- The number beside a category, and whether its sections stay ticked when the
--- category is switched off.
---
--- WHY BOTH ARE ABOUT THE SAME MISTAKE:
--- In each case one question was answered with the value of a different one.
---
--- The count showed how many hotstrings the FILE HOLDS, while a user reads it as
--- how many are FIRING — that is how they check a disable took effect, which is
--- most of the reason to look at it. A fully disabled Autocorrection went on
--- advertising 14 231 entries.
---
--- The tick showed the EFFECTIVE state, which folds in the category's gate. So
--- switching a category off unticked every section it holds at once, and the
--- information "here is what you get back" vanished. The choices were never lost;
--- only the screen said they were, which is indistinguishable from a reset.
---
--- Windows has an explicit, unit-tested policy for the first
--- (infra/hotstrings/hotstring_count_policy.ahk: "a disabled scope shows no
--- active hotstrings, not the count it would have if re-enabled"), and macOS
--- keeps `checked` and `disabled` as two independent reads for the second.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A config module with the gate and section state a real one has.
--- @param opts table { enabled = boolean, sections_off = table }
--- @return table
local function fake_config(opts)
	opts = opts or {}
	local enabled = opts.enabled ~= false
	local off = opts.sections_off or {}

	local COUNTS = { hc = 10, rare = 5, misc = 2 }
	local ORDER  = { "hc", "rare", "misc" }

	local config
	config = {
		get_groups = function() return { "rolls" } end,
		is_group_enabled = function(id) return id == "rolls" and enabled or false end,
		toggle_group = function() end,
		toggle_section = function() end,
		set_all_sections = function() end,
		is_section_checked = function(_, section) return not off[section] end,
		is_section_enabled = function(_, section)
			if not enabled then return false end
			return not off[section]
		end,
		active_count = function(id)
			if id ~= "rolls" or not enabled then return 0 end
			local total = 0
			for _, name in ipairs(ORDER) do
				if not off[name] then total = total + COUNTS[name] end
			end
			return total
		end,
		get_category = function(id)
			if id ~= "rolls" then return nil end
			local sections = {}
			for name, count in pairs(COUNTS) do sections[name] = { count = count } end
			return {
				id = "rolls", path = "/tmp/rolls.toml", count = 17,
				description = { en = "Rolls", fr = "Roulements" },
				sections_order = ORDER, sections = sections,
			}
		end,
		get_categories = function() return { rolls = config.get_category("rolls") } end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}
	return config
end

--- The Rolls category row from a freshly built menu.
--- @param config table
--- @return table|nil
local function rolls_row(config)
	local mb = helpers.load_module("ui.menu.menu_builder")
	local found = nil
	local function search(list)
		for _, item in ipairs(list or {}) do
			if type(item.title) == "string"
				and (item.title:find("Rolls", 1, true) or item.title:find("Roulements", 1, true))
				and type(item.menu) == "table" then
				found = item
				return
			end
			if type(item.menu) == "table" then search(item.menu) ; if found then return end end
		end
	end
	search(mb.build({ config = config, _version = "9.9.9" }))
	return found
end

--- The section rows of a category submenu, by shape.
--- @param row table
--- @return table
local function section_rows(row)
	local out = {}
	for _, item in ipairs(row.menu or {}) do
		if type(item.title) == "string" and item.title:match("^%S+ %(%d+%)$") then out[#out + 1] = item end
	end
	return out
end




-- =================================================================
-- =================================================================
-- ======= 1/ The count reflects what is firing ====================
-- =================================================================
-- =================================================================

helpers.describe("category row: the number beside it", function()

	helpers.it("counts every section when everything is on", function()
		local row = rolls_row(fake_config({}))
		helpers.assert_true(row ~= nil, "the category must appear at all")
		helpers.assert_true(row.title:find("(17)", 1, true) ~= nil,
			"10 + 5 + 2; got: " .. tostring(row.title))
	end)

	helpers.it("falls when a section is unticked", function()
		local row = rolls_row(fake_config({ sections_off = { hc = true } }))
		helpers.assert_true(row.title:find("(7)", 1, true) ~= nil,
			"the row must stop counting a section the user switched off; got: " .. tostring(row.title))
	end)

	helpers.it("reads zero when the whole category is off", function()
		local row = rolls_row(fake_config({ enabled = false }))
		helpers.assert_true(row.title:find("(0)", 1, true) ~= nil,
			"a disabled scope shows no active hotstrings, not the count it would have "
				.. "if re-enabled; got: " .. tostring(row.title))
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The ticks survive the gate ===========================
-- =================================================================
-- =================================================================

helpers.describe("category row: its section ticks", function()

	helpers.it("keeps a section ticked while its category is off", function()
		local rows = section_rows(rolls_row(fake_config({ enabled = false })))
		helpers.assert_true(#rows >= 3, "every section must still be listed; saw " .. #rows)
		for _, item in ipairs(rows) do
			helpers.assert_true(item.checked,
				"a switched-off category must GREY its sections, not untick them — the "
					.. "tick is what tells the user which ones come back")
			helpers.assert_true(item.disabled, "and grey them, so the state is still legible")
		end
	end)

	helpers.it("still unticks a section the user actually switched off", function()
		local rows = section_rows(rolls_row(fake_config({ sections_off = { rare = true } })))
		local seen = false
		for _, item in ipairs(rows) do
			if item.title:find("rare", 1, true) then
				seen = true
				helpers.assert_true(not item.checked, "the user's own choice must still show")
			end
		end
		helpers.assert_true(seen, "the 'rare' section must be listed")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The bulk rows ========================================
-- =================================================================
-- =================================================================

helpers.describe("category row: its bulk rows", function()

	helpers.it("leaves the enable-all row clickable while the category is off", function()
		local row = rolls_row(fake_config({ enabled = false }))
		local enable_row = row.menu[3]
		helpers.assert_true(enable_row ~= nil and enable_row.disabled ~= true,
			"greying it forced the user to find and click the gate first, then reopen "
				.. "the menu — on the other two drivers this is one click")
	end)

end)
