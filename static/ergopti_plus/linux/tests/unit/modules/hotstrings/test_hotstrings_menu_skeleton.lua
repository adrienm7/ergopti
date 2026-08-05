--- tests/unit/modules/hotstrings/test_hotstrings_menu_skeleton.lua

--- ==============================================================================
--- MODULE: The Hotstrings Submenu's Own Skeleton
--- DESCRIPTION:
--- The rows the manifest declares for the Hotstrings submenu that this driver
--- has to build itself, because the shared renderer cannot: the master toggle,
--- and the way into the personal-hotstring editor.
---
--- WHY THESE TWO NEEDED A TEST OF THEIR OWN:
--- Both were declared and both were missing, and every existing gate passed.
---
--- The master toggle is row 1 of `[[menu.hotstrings_menu]]`. The shared renderer
--- skips `toggle` rows by contract — "Category toggles rendered by caller" — so
--- a manifest gate sees a declared row, a renderer gate sees a deliberate skip,
--- and nobody checks that the caller then rendered one. This caller did not, so
--- there was no single switch that turned hotstrings off and no indication on
--- screen of whether they were on.
---
--- The editor is worse, because nothing declared it missing at all:
--- `_shared/ui/hotstring_editor/` shipped with the driver, its bridge was
--- complete and had its own passing tests, and no code path anywhere called
--- `webview.show("hotstring_editor")`. A Linux user could not create, edit or
--- delete a single personal hotstring. Tests of a bridge nobody opens are the
--- reason a feature can be fully tested and entirely unreachable.
---
--- WHY THE TOGGLE IS A ROW AND NOT A CLICKABLE PARENT:
--- macOS puts it on the parent item. `platform/tray/appindicator.lua` binds
--- `item.fn` only when a row has NO submenu (`if item.menu … elseif item.fn …`),
--- so a parent that both opens a submenu and acts is not representable on this
--- backend. Windows' placement — first row inside — is the one that works here,
--- and it is also the manifest's position.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A config module standing in for hotstrings_config, recording the bulk calls.
--- @param opts table { all_enabled = boolean }
--- @return table config, table log
local function fake_config(opts)
	opts = opts or {}
	local log = { enabled_all = 0, disabled_all = 0, toggled = {} }
	local all_enabled = opts.all_enabled ~= false

	return {
		get_groups = function() return { "rolls", "personal" } end,
		is_group_enabled = function() return all_enabled end,
		toggle_group = function(id) log.toggled[#log.toggled + 1] = id end,
		enable_all = function() log.enabled_all = log.enabled_all + 1 end,
		disable_all = function() log.disabled_all = log.disabled_all + 1 end,
		is_section_enabled = function() return true end,
		get_category = function(id)
			if id ~= "personal" then return nil end
			return { id = "personal", count = 3, sections_order = { "work", "home" }, sections = {
				work = { count = 2 }, home = { count = 1 },
			} }
		end,
		get_categories = function() return {} end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}, log
end

--- Builds the whole tray menu and returns the Hotstrings submenu's row list.
--- @param config table
--- @param ctx_extra table|nil
--- @return table|nil rows, table|nil parent
local function hotstrings_rows(config, ctx_extra)
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ctx = { config = config, _version = "9.9.9" }
	for k, v in pairs(ctx_extra or {}) do ctx[k] = v end

	for _, item in ipairs(mb.build(ctx) or {}) do
		-- Matched on having a submenu that contains the master-toggle label rather
		-- than on the parent's own title, which is localised.
		if type(item.menu) == "table" then
			for _, row in ipairs(item.menu) do
				if type(row.title) == "string" and row.title:find("otstring", 1, true) then
					return item.menu, item
				end
			end
		end
	end
	return nil, nil
end




-- =================================================================
-- =================================================================
-- ======= 1/ The master toggle ====================================
-- =================================================================
-- =================================================================

helpers.describe("hotstrings submenu: the master toggle", function()

	helpers.it("is the first row, and it acts", function()
		local config, log = fake_config({ all_enabled = true })
		local rows = hotstrings_rows(config)
		helpers.assert_true(rows ~= nil, "the Hotstrings submenu must exist at all")

		local first = rows[1]
		helpers.assert_true(type(first) == "table" and type(first.fn) == "function",
			"row 1 of the manifest is a toggle and the shared renderer skips it by "
				.. "contract — so this caller has to build it, and for a long time did not")

		first.fn()
		helpers.assert_eq(log.disabled_all, 1,
			"everything was on, so the switch must turn everything off")
	end)

	helpers.it("turns everything back on when everything is off", function()
		local config, log = fake_config({ all_enabled = false })
		local rows = hotstrings_rows(config)
		rows[1].fn()
		helpers.assert_eq(log.enabled_all, 1, "and the label says so before it is clicked")
	end)

	helpers.it("uses the batched writers rather than a loop of toggle_group", function()
		-- Each toggle_group ends in a full load_all(), which re-parses every pack —
		-- magickey.toml alone is 305 KB — once per category, inside a menu callback.
		local config, log = fake_config({ all_enabled = true })
		local rows = hotstrings_rows(config)
		rows[1].fn()
		helpers.assert_eq(#log.toggled, 0,
			"one bulk write, not one catalogue reload per category")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The way into the editor ==============================
-- =================================================================
-- =================================================================

helpers.describe("hotstrings submenu: the personal-hotstring editor", function()

	--- Builds the submenu with a recording webview, and returns every app name the
	--- rows ask it to open.
	---
	--- Rows are matched by their translated LABEL and only the matched row's `fn`
	--- is run. Walking the tree and firing every callback to see what each does
	--- would also fire the magic-key prompt, which shells out to zenity — on a
	--- machine that has zenity and a display, the suite would stop at a dialog.
	--- @return table Set of app names, and the label lookup used.
	local function apps_opened_by_labels(labels)
		local asked = {}
		local config = fake_config({})
		local rows = hotstrings_rows(config, {
			webview = { show = function(name) asked[name] = true; return true end },
		})
		helpers.assert_true(rows ~= nil, "the Hotstrings submenu must exist at all")

		local i18n = require("infra.i18n")
		local wanted = {}
		for _, key in ipairs(labels) do wanted[i18n.get(key)] = true end

		local fired = 0
		local function walk(list)
			for _, item in ipairs(list or {}) do
				if type(item.title) == "string" and wanted[item.title] and type(item.fn) == "function" then
					item.fn()
					fired = fired + 1
				end
				if type(item.menu) == "table" then walk(item.menu) end
			end
		end
		walk(rows)
		return asked, fired
	end

	helpers.it("offers a row that opens the shared editor", function()
		local asked, fired = apps_opened_by_labels({ "menu.hotstrings.open_editor" })
		helpers.assert_true(fired >= 1,
			"there must be a row carrying the open-editor label at all")
		helpers.assert_true(asked["hotstring_editor"] == true,
			"nothing in this driver ever called webview.show(\"hotstring_editor\"): the "
				.. "editor shipped, its bridge was complete and tested, and no user could "
				.. "reach it to write a single personal hotstring")
	end)

	helpers.it("opens the settings window by its real directory name", function()
		local asked, fired = apps_opened_by_labels({ "menu.hotstrings.config_item" })
		helpers.assert_true(fired >= 1, "the configure-delays row must exist")
		helpers.assert_true(asked["hotstrings_config_window"] == true,
			"the delays-and-colours window must be reachable")
		helpers.assert_true(asked["hotstrings_config"] == nil,
			"and never by the name that has a bridge but no page — that one renders "
				.. "\"Error: app not found\"")
	end)

end)
