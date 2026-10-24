--- tests/unit/ui/menu/structure/test_pause_layout_rows.lua

--- ==============================================================================
--- MODULE: Pause Layout Rows Tests
--- DESCRIPTION:
--- Layout > « Layout on pause / resume » on Linux: the shared manifest frames
--- macOS draws, with the desktop's own layouts as choices. Exercises the rows
--- through the real renderer, the choices and writes through recording fakes,
--- and the provider through the actual layout menu owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local Rows = require("ui.menu.pause_layout_rows")
local Renderer = require("infra.manifest_menu")

local CHOICES = { { id = "xkb:fr", label = "fr" }, { id = "xkb:fr+ergopti", label = "fr+ergopti" } }

--- A recording world: settings, writes, refreshes and redraws.
--- @param settings table { enabled, on_pause, on_resume }
--- @param refresh_changed boolean|nil What the next refresh reports.
local function world(settings, refresh_changed)
	local state = { writes = {}, redraws = 0, refreshes = 0, errors = 0, backend = "gnome" }
	state.preferences = {
		settings = function() return settings end,
		set = function(role, value)
			state.writes[#state.writes + 1] = role .. "=" .. tostring(value)
			return state.refuse_write ~= true
		end,
	}
	state.switch = {
		switcher = function()
			return {
				backend = function() return state.backend end,
				choices = function() return CHOICES end,
				refresh = function(on_done)
					state.refreshes = state.refreshes + 1
					on_done(refresh_changed == true)
				end,
			}
		end,
	}
	state.ctx = {
		paused = false,
		t = function(key) return key end,
		on_changed = function() state.redraws = state.redraws + 1 end,
		show_error = function() state.errors = state.errors + 1 end,
		preferences = state.preferences,
		switch = state.switch,
	}
	return state
end

local function find(rows, needle)
	for _, row in ipairs(rows) do
		if type(row.label) == "string" and row.label:find(needle, 1, true) then return row end
	end
	return nil
end

helpers.describe("pause layout rows", function()
	helpers.it("draws the switch and two pickers captioned with the chosen layouts", function()
		local state = world({ enabled = true, on_pause = "xkb:fr+ergopti", on_resume = "" })
		local rows = Rows.rows(state.ctx)
		helpers.assert_eq(#rows, 3)
		helpers.assert_eq(rows[1].checked, true, "the switch is ticked while on")
		helpers.assert_true(rows[2].label:find(": fr+ergopti", 1, true) ~= nil, rows[2].label)
		helpers.assert_true(rows[3].label:find("menu.layout.layout_auto", 1, true) ~= nil, rows[3].label)
		local pause = rows[2].items
		helpers.assert_eq(#pause, 4, "no change, a separator and the two layouts")
		helpers.assert_eq(pause[1].checked, false)
		helpers.assert_eq(pause[3].label, "fr")
		helpers.assert_eq(pause[4].checked, true, "the chosen layout is ticked")
		helpers.assert_eq(rows[3].items[1].checked, true, "no change is ticked for an empty target")
		helpers.assert_eq(state.refreshes, 1, "every build asks for a fresh reading")
		helpers.assert_eq(state.redraws, 0, "an unchanged reading never redraws")
	end)

	helpers.it("writes a choice, no change and the switch, then redraws", function()
		local state = world({ enabled = false, on_pause = "", on_resume = "xkb:fr" })
		local rows = Rows.rows(state.ctx)
		rows[2].items[3].action()
		rows[3].items[1].action()
		rows[1].action()
		helpers.assert_eq(table.concat(state.writes, ","), "on_pause=xkb:fr,on_resume=,enabled=true")
		helpers.assert_eq(state.redraws, 3)
		state.refuse_write = true
		rows[1].action()
		helpers.assert_eq(state.errors, 1, "a refused write is shown")
		helpers.assert_eq(state.redraws, 3, "and nothing redraws")
	end)

	helpers.it("greys the pickers while switching is off or the script is paused", function()
		local off = world({ enabled = false, on_pause = "xkb:fr", on_resume = "" })
		local rows = Rows.rows(off.ctx)
		helpers.assert_eq(rows[2].disabled, true)
		helpers.assert_eq(rows[3].disabled, true)
		local paused = world({ enabled = true, on_pause = "xkb:fr", on_resume = "" })
		paused.ctx.paused = true
		rows = Rows.rows(paused.ctx)
		helpers.assert_eq(rows[2].disabled, true)
		local live = world({ enabled = true, on_pause = "xkb:fr", on_resume = "" })
		helpers.assert_nil(Rows.rows(live.ctx)[2].disabled)
	end)

	helpers.it("explains a desktop that cannot change its layout instead of drawing the switch", function()
		local state = world({ enabled = true, on_pause = "xkb:fr", on_resume = "" })
		state.backend = nil
		local rows = Rows.rows(state.ctx)
		helpers.assert_eq(#rows, 1, "one status line, no switch and no pickers")
		helpers.assert_eq(rows[1].label, require("infra.i18n").get("menu.layout.pause_layout_unsupported_desktop"))
		helpers.assert_true(rows[1].label:find("GNOME", 1, true) ~= nil, rows[1].label)
		helpers.assert_eq(rows[1].disabled, true, "the status line is inert")
		helpers.assert_eq(state.refreshes, 0, "nothing is listed on such a desktop")
	end)

	helpers.it("redraws once when the desktop's list changed", function()
		local state = world({ enabled = true, on_pause = "", on_resume = "" }, true)
		Rows.rows(state.ctx)
		helpers.assert_eq(state.redraws, 1)
	end)

	helpers.it("reaches the tray through the layout menu's provider", function()
		local state = world({ enabled = true, on_pause = "xkb:fr+ergopti", on_resume = "" })
		local names, saved = { "ui.menu.menu_builder", "infra.pause_layout_preferences" }, {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local ok, err = pcall(function()
			package.loaded["infra.pause_layout_preferences"] = state.preferences
			package.loaded["ui.menu.menu_builder"] = nil
			local builder, layouts = require("ui.menu.menu_builder"), nil
			local index = 1
			while true do
				local name, value = debug.getupvalue(builder.build, index)
				if name == nil then break end
				if name == "_build_layouts" then layouts = value end
				index = index + 1
			end
			assert(type(layouts) == "function", "the actual registered layout provider is required")
			local menu = Renderer.render_rows({ assert(layouts({ layout = "qwerty", pause_layout = state.switch })) },
				"pause-layout-rows")[1]
			local found = false
			for _, item in ipairs(menu.menu or {}) do
				if type(item.title) == "string" and item.title:find(": fr+ergopti", 1, true) then found = true end
			end
			helpers.assert_true(found, "the pause picker is drawn in Layout")
		end)
		-- A module absent before the test is absent after it: pairs() would skip it.
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end)

return true
