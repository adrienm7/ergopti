--- tests/unit/ui/menu/test_provider_rows_speak_one_dialect.lua

--- ==============================================================================
--- MODULE: Regression — a provider row left in the driver dialect disappears
--- DESCRIPTION:
--- A list provider returns row DATA — `label`, `action`, `items` — and the shared
--- renderer turns it into the hs.menubar shape. A row left in the DRIVER dialect
--- (`title`, `fn`, `menu`) has no label as far as the renderer is concerned, so
--- it is dropped with a single warning and the user simply never sees it.
---
--- THE BUG (menu_about, found 2026-08-07): the About submenu's updater block
--- became an `about_updates` list provider, and two of its rows were never
--- converted — the version header (`title = ver_display`) and the channel
--- selector (`title = channel_title, menu = channel_items`). Both vanished from
--- the menu the day the block moved. Nothing failed: the suites were green, the
--- parity gate was green, and the only trace was one WARNING per menu build in a
--- log nobody reads while the menu still looks plausible.
---
--- WHY A SOURCE SCAN: the failure is invisible at runtime by construction. There
--- is nothing to assert about a row that was silently dropped, so the guard reads
--- the provider bodies and refuses the wrong dialect there.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("provider rows speak the provider dialect (a driver-dialect row is dropped)", function()
	-- Each entry: a declaration unique to the module, and the name of the array
	-- its list provider returns. Selected by declaration rather than by path so
	-- moving or splitting a module cannot turn this invariant into a path error.
	local GUARDED = {
		{ anchor = "local function get_update_menu_label", array = "menu_items" },
		{ anchor = "local function discover_bundled_apps", array = "provider_rows" },
	}

	helpers.it("no row pushed into a provider array uses `title` or `fn`", function()
		for _, guard in ipairs(GUARDED) do
			local src = helpers.read_driver_source(guard.anchor)
			helpers.assert_true(src ~= nil,
				"the module declaring '" .. guard.anchor .. "' must be locatable")

			local offending
			for line in src:gmatch("[^\n]+") do
				local stripped = line:match("^%s*(.-)%s*$") or line
				local pushes = stripped:find("table%.insert%(" .. guard.array .. ",")
					or stripped:find(guard.array .. "%[#" .. guard.array .. "%s*%+%s*1%]%s*=")
				if not stripped:match("^%-%-") and pushes then
					if stripped:find("%f[%w]title%s*=") or stripped:find("%f[%w]fn%s*=") then
						offending = stripped
						break
					end
				end
			end
			helpers.assert_true(offending == nil,
				"a row pushed into '" .. guard.array .. "' uses the driver dialect. The renderer reads "
				.. "provider data: `title` is not a label and the row is dropped with one warning. "
				.. "Offending: " .. tostring(offending))
		end
	end)

	-- Modules whose rows are ALL provider rows. The guard above reads the pushes
	-- into one named array, which is the right shape when a module builds a driver
	-- tree AND a provider array; these two build nothing else, so the stronger
	-- invariant applies and catches a row wherever it is written — including one
	-- assigned after the fact, which is exactly how the hotstring sections were
	-- lost (`item.menu = sec_menu`, four lines below the row it belonged to).
	local PROVIDER_ONLY_MODULES = {
		{ anchor = "function M.build_groups",           what = "the hotstring category builder" },
		{ anchor = "local function render_ext_tree",    what = "the personal-extensions tree" },
	}

	helpers.it("a module that emits only provider rows never names `title`, `fn` or `menu`", function()
		for _, guard in ipairs(PROVIDER_ONLY_MODULES) do
			local src, err = helpers.read_driver_unit(guard.anchor)
			helpers.assert_true(src ~= nil,
				"could not locate " .. guard.what .. ": " .. tostring(err))

			local offending, offending_line = nil, 0
			local line_no = 0
			for line in src:gmatch("[^\n]*") do
				line_no = line_no + 1
				local stripped = line:match("^%s*(.-)%s*$") or line
				if not stripped:match("^%-%-") then
					-- `%f[%w_]` so `sec_menu =`, `folder_menu =` and `update_menu =`
					-- are not read as the field `menu`.
					if stripped:find("%f[%w_]title%s*=")
						or stripped:find("%f[%w_]fn%s*=")
						or stripped:find("%f[%w_]menu%s*=") then
						offending, offending_line = stripped, line_no
						break
					end
				end
			end
			helpers.assert_true(offending == nil,
				guard.what .. " emits provider rows only, so `title`, `fn` and `menu` — the hs.menubar "
				.. "field names — must not appear in it. The renderer reads `label`, `action` and `items`: "
				.. "a `title` is dropped, a `menu` is never read and the row loses its whole subtree. "
				.. "Line " .. offending_line .. ": " .. tostring(offending))
		end
	end)

	helpers.it("every hotstring category still carries its sections", function()
		local src = helpers.read_driver_unit("function M.build_groups")
		helpers.assert_true(src ~= nil, "the hotstring category builder must be locatable")

		helpers.assert_true(src:find("item.items = sec_menu", 1, true) ~= nil,
			"the section list must be attached as `items`. Written as `menu` it is attached to a field "
			.. "the renderer never reads, and every standard and Ergopti category renders as a bare "
			.. "clickable row: no « ouvrir le fichier », no bulk actions, no section toggles, no warning")
	end)

	helpers.it("the extension tree emits rows in the dialect it also reads", function()
		local src = helpers.read_driver_unit("local function render_ext_tree")
		helpers.assert_true(src ~= nil, "the personal-extensions tree must be locatable")

		helpers.assert_true(src:find("label = folder_label, items = folder_menu", 1, true) ~= nil,
			"a folder row is `label` + `items`; as `title` + `menu` the folder renders empty")
		helpers.assert_true(src:find("label = file.label, items = file.items", 1, true) ~= nil,
			"a file row must read the fields the nodes actually carry — reading `file.title`/`file.menu` "
			.. "off a node built with `label`/`items` yields a row with no label at all, which the "
			.. "renderer drops")
		helpers.assert_true(src:find("a.label < b.label", 1, true) ~= nil,
			"and the sort must compare that same field: `a.title < b.title` on those nodes compares two "
			.. "nils, which throws inside the provider and takes the whole hotstrings menu with it as "
			.. "soon as one folder holds two extension files")
	end)

	helpers.it("the About submenu keeps its version header and its channel selector", function()
		local src = helpers.read_driver_source("local function get_update_menu_label")
		helpers.assert_true(src ~= nil, "ui/menu/menu_about.lua source must be locatable")

		helpers.assert_true(src:find("label = ver_display", 1, true) ~= nil,
			"the version header must be a provider row (`label = ver_display`) — as `title` it is "
			.. "dropped by the renderer and the submenu shows no version at all")
		helpers.assert_true(src:find("label = channel_title", 1, true) ~= nil,
			"the channel selector must be a provider row (`label = channel_title`) — as `title` it is "
			.. "dropped and there is no way to switch channel from the menu")
		helpers.assert_true(src:find("items = channel_items", 1, true) ~= nil,
			"the channel selector's own rows must be handed over as `items`; `menu` is the driver "
			.. "dialect and the renderer ignores it on a provider row")
	end)
end)
