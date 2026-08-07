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
