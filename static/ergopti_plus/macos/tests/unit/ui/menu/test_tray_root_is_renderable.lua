--- tests/unit/ui/menu/test_tray_root_is_renderable.lua

--- ==============================================================================
--- MODULE: Every Row Of The Tray Root Is Something hs.menubar Can Draw
--- DESCRIPTION:
--- Builder.generate returns the table handed straight to hs.menubar:setMenu, so
--- every entry in it must carry a `title` (or be the "-" separator). This pins
--- that contract from the OUTSIDE, independently of how the root is assembled
--- inside.
---
--- WHY IT EXISTS:
--- the root is assembled from a dozen component builders, each returning the row
--- that hangs its submenu on the tray. When those rows became provider DATA —
--- `label` / `submenu`, materialised by the shared renderer, the way Linux has
--- built its whole tray root since 2026-08-07 — a single builder left in the old
--- dialect would return a row the renderer drops, and a whole submenu would
--- disappear from the menu bar with one warning in a log.
---
--- The three bugs that motivated this were each found by opening the menu and
--- noticing something missing: the About version row, every hotstring category's
--- section list, every grouped Karabiner action. A test that reads the OUTPUT
--- cannot miss the next one, whichever builder it comes from.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The actions table Builder.generate's top-level tail expects.
--- @return table
local function make_actions()
	return {
		set_log_level     = function() end,
		open_logs         = function() end,
		open_today_log    = function() end,
		open_error_log    = function() end,
		open_console      = function() end,
		show_setup_wizard = function() end,
		open_paths        = function() end,
		reload            = function() end,
		quit              = function() end,
		enable_all        = function() end,
		disable_all       = function() end,
		reset_defaults    = function() end,
	}
end

--- Describes a row that hs.menubar could not draw, or nil when it can.
--- @param row any One entry of the returned menu table.
--- @param path string Where it sits, for the failure message.
--- @return string|nil
local function undrawable(row, path)
	if type(row) ~= "table" then
		return path .. " is a " .. type(row) .. ", not a menu row"
	end
	-- An EMPTY title is legitimate for exactly one row: the canvas badge, which is
	-- an image and no text. A missing one never is.
	if type(row.title) ~= "string" or (row.title == "" and row.image == nil) then
		-- Name the provider field when it is present: that is the whole diagnosis.
		local hint = ""
		if row.label ~= nil then hint = " — it carries `label`, the PROVIDER field, so it never reached the renderer" end
		if row.items ~= nil then hint = hint .. " and `items`, which only a provider row has" end
		return path .. " has no title" .. hint
	end
	if row.menu ~= nil and type(row.menu) ~= "table" then
		return path .. " ('" .. row.title .. "') has a non-table `menu`"
	end
	return nil
end

--- Walks the whole returned tree, reporting the first undrawable row.
--- @param rows table
--- @param path string
--- @return string|nil
local function first_problem(rows, path)
	for index, row in ipairs(rows) do
		local where = path .. "[" .. index .. "]"
		local bad = undrawable(row, where)
		if bad then return bad end
		if type(row.menu) == "table" then
			local deeper = first_problem(row.menu, where .. ".menu")
			if deeper then return deeper end
		end
	end
	return nil
end

helpers.describe("the tray root is a table hs.menubar can draw", function()

	helpers.it("every row it returns carries a title, at every depth", function()
		local builder = helpers.load_with_stubs("ui.menu.builder")
		local i18n = require("infra.i18n")
		i18n.get = function(k) return k end
		i18n.build_language_menu_items = function() return {} end

		local ctx = { config = { log_level = 2 } }
		local ok_call, menu = pcall(builder.generate, ctx, {}, make_actions())
		helpers.assert_true(ok_call, "M.generate must not raise: " .. tostring(menu))
		helpers.assert_true(type(menu) == "table" and #menu > 0,
			"M.generate must return a non-empty menu, or this test measures nothing")

		local problem = first_problem(menu, "menu")
		helpers.assert_true(problem == nil,
			"a row hs.menubar cannot draw reached the tray root. Provider rows say `label` and `items`; "
			.. "what setMenu consumes says `title` and `menu`, and the shared renderer is what turns one "
			.. "into the other. " .. tostring(problem))
	end)

	helpers.it("no row is left holding both dialects at once", function()
		local builder = helpers.load_with_stubs("ui.menu.builder")
		local i18n = require("infra.i18n")
		i18n.get = function(k) return k end
		i18n.build_language_menu_items = function() return {} end

		local ctx = { config = { log_level = 2 } }
		local _, menu = pcall(builder.generate, ctx, {}, make_actions())
		helpers.assert_true(type(menu) == "table" and #menu > 0, "M.generate must return a menu")

		local mixed = nil
		local function walk(rows, path)
			for index, row in ipairs(rows) do
				if type(row) == "table" then
					local where = path .. "[" .. index .. "]"
					if row.title ~= nil and (row.label ~= nil or row.items ~= nil or row.action ~= nil) then
						mixed = where .. " ('" .. tostring(row.title) .. "')"
						return
					end
					if type(row.menu) == "table" then walk(row.menu, where .. ".menu") end
					if mixed then return end
				end
			end
		end
		walk(menu, "menu")

		helpers.assert_true(mixed == nil,
			"a row carries BOTH the hs.menubar fields and the provider fields: " .. tostring(mixed)
			.. ". Half-converted rows are how a subtree ends up attached to a field nothing reads")
	end)
end)
