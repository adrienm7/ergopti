--- tests/unit/menu/structure/test_tall_submenus.lua

--- ==============================================================================
--- MODULE: Tall Tray Submenus Fold By Section
--- DESCRIPTION:
--- The shared renderer's fold_tall_menus over hand-built trees: a submenu within the
--- bound is the same table, an overlong one folds every titled section into a
--- submenu named by its title, and every row keeps its own action.
--- ==============================================================================

local helpers = require("tests.helpers")
local Renderer = require("menu.engine.renderer")
local Tall = { fold = Renderer.fold_tall_menus }

--- A section: its « — Title — » header and `count` rows.
--- @param title string
--- @param count integer
--- @param out table Receives the rows.
--- @param actions table Receives each row's action by title.
local function section(title, count, out, actions)
	out[#out + 1] = { title = "— " .. title .. " —", disabled = true }
	for index = 1, count do
		local label = title .. " " .. index
		actions[label] = function() return label end
		out[#out + 1] = { title = label, fn = actions[label] }
	end
end

helpers.describe("tall tray submenus (tray-submenu-height)", function()
	helpers.it("keeps a submenu within the bound as the same table", function()
		local rows, actions = { { title = "Switch", checked = true, fn = function() end } }, {}
		section("Small", 3, rows, actions)
		local tree = { { title = "Group", menu = rows } }
		helpers.assert_true(Tall.fold(tree, 10) == tree, "an unchanged tree stays one for the in-place patch")
	end)

	helpers.it("folds every section of an overlong submenu and keeps its switch first", function()
		local rows, actions = { { title = "Switch", checked = false, fn = function() end }, { title = "-" } }, {}
		section("Two", 6, rows, actions)
		rows[#rows + 1] = { title = "-" }
		section("Three", 6, rows, actions)
		rows[#rows + 1] = { title = "-" }
		rows[#rows + 1] = { title = "Last", fn = function() end }
		local folded = Tall.fold({ { title = "Group", checked = false, menu = rows } }, 10)
		local menu = folded[1].menu
		local titles = {}
		for index, row in ipairs(menu) do titles[index] = row.title end
		helpers.assert_eq(titles, { "Switch", "-", "Two", "Three", "-", "Last" },
			"the sections read as one list of submenus, the switch still first")
		helpers.assert_eq(folded[1].checked, false, "the parent row keeps its fields")
		helpers.assert_eq(#menu[3].menu, 6)
		helpers.assert_true(menu[4].menu[2].fn == actions["Three 2"], "a folded row keeps its own action")
		helpers.assert_eq(#rows, 19, "the model itself is left as built")
	end)

	helpers.it("splits a long list with no section into runs named by their first and last rows", function()
		local flat = { { title = "Switch", checked = true, fn = function() end }, { title = "-" } }
		for index = 1, 24 do
			local letter = string.char(64 + index)
			flat[#flat + 1] = { title = "Ctrl + " .. letter .. " → Copy", disabled = index == 3, fn = function() end }
			if index == 3 then flat[#flat + 1] = { title = "    tick the first row", disabled = true } end
		end
		local shown = Tall.fold(flat, 10)
		helpers.assert_eq(shown[1].title, "Switch", "the rows before the long run stay where they are")
		helpers.assert_eq(shown[2].title, "-")
		helpers.assert_eq(#shown, 5, "the 25 rows of the run became three submenus")
		helpers.assert_eq(shown[3].title, "Ctrl + A … Ctrl + H")
		helpers.assert_eq(shown[3].menu[4].title, "    tick the first row", "a reason line stays below its row")
		helpers.assert_eq(shown[5].title, "Ctrl + R … Ctrl + X")
		for _, row in ipairs(shown) do helpers.assert_true(row.menu == nil or #row.menu <= 10) end
	end)

	helpers.it("bounds the folded sections too, at every depth", function()
		local rows, actions = {}, {}
		section("Outer", 9, rows, actions)
		local inner = {}
		section("Deep", 6, inner, actions)
		section("Deeper", 6, inner, actions)
		rows[#rows + 1] = { title = "Nested", menu = inner }
		local folded = Tall.fold(rows, 10)
		helpers.assert_eq(folded[1].title, "Outer")
		helpers.assert_eq(folded[1].menu[10].menu[1].title, "Deep", "a deep overlong submenu folds as well")
		helpers.assert_eq(folded[1].menu[10].menu[2].title, "Deeper")
	end)

	helpers.it("the Linux tray reads its bound from the registry", function()
		helpers.assert_eq(require("tray.adapters.menu").MAX_SUBMENU_ENTRIES, 30)
	end)
end)
