--- tests/unit/menu/structure/test_layout_emulation_choice.lua

--- ==============================================================================
--- MODULE: Layout To Emulate Choice Tests
--- DESCRIPTION:
--- Layouts and emulation › « Layout to emulate » on Linux, from the rows to the
--- engine: each click writes config.toml through the real preferences, the
--- rows rebuilt from it tick exactly one choice drawn as a radio, and
--- « None » turns the running emulation off (field report of 2026-11-25:
--- « None » and « bépo » ticked at once, the emulation still named bépo).
--- ==============================================================================

local helpers = require("tests.helpers")
local Paths = require("core.fs.engine.paths")
local ConfigPaths = require("settings.engine.paths")
local Json = require("core.text.engine.json")
local Preferences = require("infra.layout_emulation_preferences")
local EmulationRows = require("layouts.engine.emulation.menu")

local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	assert(handle:close())
	return text
end

local INDEX = Json.decode(read_all(Paths.shared("../../layouts/registry/index.json")))

--- The running emulation, reading the same config.toml the menu writes.
--- @return table emulation
local function started_emulation()
	package.loaded["modules.keymap.layout_emulation"] = nil
	local Emulation = require("modules.keymap.layout_emulation")
	Emulation.init({
		read_config = function() return (Preferences.snapshot()) end,
		default_for = require("menu.engine.manifest_reader").default_for,
		source = function(id)
			for _, entry in ipairs(INDEX.layouts) do
				if entry.id == id then
					return { id = id, text = read_all(Paths.shared("../../layouts/registry/" .. entry.file)),
						convention = entry.keycode_convention, composer = false }
				end
			end
			return nil, "not shipped"
		end,
		keycodes = function() return Json.decode(read_all(Paths.shared("layouts/data/mac_keycodes.json"))) end,
		registry = function()
			return Json.decode_lossless(read_all(Paths.shared("layouts/data/keycodes/physical_keys.json")))
		end,
		type_text = function() return true end,
		dispatch_char = function() end,
		emit_shortcut = function() return true end,
		emit_key = function() return true end,
		now_ms = function() return 0 end,
		caps_locked = function() return false end,
		is_active = function() return true end,
		ergopti_family = function() return "ergopti" end,
		typed_text = function() return "" end,
	})
	return Emulation
end

--- The « Layout to emulate » row as the menu builds it from the stored settings.
--- @param Emulation table
--- @return table row
local function choice_row(Emulation)
	return EmulationRows.choice_rows({
		t = function(key) return key end,
		settings = Preferences.settings(),
		status = Emulation.status(),
		snapshot = { index = INDEX },
		choose = function(choice)
			helpers.assert_true(Preferences.choose(choice), "the choice " .. choice .. " is stored")
			Emulation.reload_if_started()
		end,
	})[1]
end

--- The row label of a choice: the built-in ones by key, a registry layout by name.
--- @param choice string
--- @return string
local function label_for(choice)
	for _, entry in ipairs(INDEX.layouts) do
		if entry.id == choice and choice ~= "ergopti" then return entry.name end
	end
	return "onboarding.layout.emulated_" .. choice
end

helpers.describe("layout to emulate: one choice, None turns it off (layout-emulation-none)", function()
	helpers.it("ticks exactly one radio row after each click and None stops the emulation", function()
		local config = ConfigPaths.config("config.toml")
		os.execute("mkdir -p '" .. config:match("^(.*)/") .. "'")
		os.remove(config)
		local Emulation = started_emulation()
		Emulation.reload()
		for _, choice in ipairs({ "bepo", "bepo", "none", "ergopti", "bepo", "none", "none" }) do
			local before = choice_row(Emulation)
			local clicked = nil
			for _, item in ipairs(before.items) do
				if item.label == label_for(choice) then clicked = item end
			end
			assert(clicked, "no row for " .. choice)
			clicked.action()
			local after = choice_row(Emulation)
			local ticked = {}
			for _, item in ipairs(after.items) do
				helpers.assert_true(item.radio == true, item.label .. " is one choice of several")
				if item.checked then ticked[#ticked + 1] = item.label end
			end
			helpers.assert_eq(#ticked, 1, "exactly one choice is ticked after choosing " .. choice)
			helpers.assert_true(ticked[1] == clicked.label, "the clicked choice is the ticked one")
			local status = Emulation.status()
			if choice == "none" then
				helpers.assert_nil(Preferences.settings().id, "None stores no emulated layout")
				helpers.assert_true(status.active == false, "None stops the running emulation")
			else
				helpers.assert_eq(status.id, choice, "the engine emulates the chosen layout")
				helpers.assert_true(status.active == true, "and runs it")
			end
		end
		os.remove(config)
	end)

	helpers.it("a tray click applies the choice to the running emulation without a reload", function()
		local config = ConfigPaths.config("config.toml")
		os.execute("mkdir -p '" .. config:match("^(.*)/") .. "'")
		os.remove(config)
		local Emulation = started_emulation()
		Emulation.reload()
		local MenuLayouts = require("ui.menu.menu_layouts")
		-- The menu owner's translator global, as the daemon's menu sets it.
		local original_safe = rawget(_G, "i18n_safe")
		rawset(_G, "i18n_safe", function(key) return key end)
		local changes = 0
		--- The tray rows of the « Layout to emulate » choices, as the daemon builds them.
		local function choices()
			local root = MenuLayouts.build({ on_menu_changed = function() changes = changes + 1 end })
			local found = {}
			-- The group row is row data around the finished tray subtree; the
			-- choices are the submenu of the « Layout to emulate » row.
			for _, row in ipairs(root.submenu) do
				if type(row.title) == "string" and row.title:find("menu.layout.emulated_layout", 1, true) == 1 then
					for _, choice in ipairs(row.menu) do
						helpers.assert_true(choice.radio == true, choice.title .. " reaches the tray as a radio")
						found[choice.title] = choice
					end
				end
			end
			return found
		end
		for _, choice in ipairs({ "bepo", "none", "bepo", "ergopti", "none" }) do
			local before = changes
			local row = choices()[label_for(choice)]
			assert(row, "no tray row for " .. choice)
			row.fn()
			helpers.assert_true(changes > before, "the menu is redrawn after choosing " .. choice)
			local status = Emulation.status()
			if choice == "none" then
				helpers.assert_true(status.active == false, "None stops the emulation at once")
			else
				helpers.assert_true(status.active == true and status.id == choice,
					"the engine emulates " .. choice .. " right after the click")
			end
			local ticked = {}
			for title, rendered in pairs(choices()) do
				if rendered.checked then ticked[#ticked + 1] = title end
			end
			helpers.assert_eq(table.concat(ticked, ","), label_for(choice), "one tick, on the click's choice")
		end
		rawset(_G, "i18n_safe", original_safe)
		os.remove(config)
	end)

	helpers.it("the shared renderer hands a choice's radio mark to the tray rows", function()
		local ManifestMenu = require("menu.engine.manifest_menu")
		local rendered = ManifestMenu.render_rows({
			{ label = "Choices", items = {
				{ label = "None", checked = true, radio = true, action = function() end },
				{ label = "bépo", checked = false, radio = true, action = function() end },
				{ label = "Switch", checked = true, action = function() end },
			} },
		}, "test")
		local rows = rendered[1].menu
		helpers.assert_true(rows[1].radio == true and rows[2].radio == true, "both choices stay radios")
		helpers.assert_nil(rows[3].radio, "an independent switch is no radio")
		local back = ManifestMenu.native_child_rows(rows)
		helpers.assert_true(back ~= nil and back[1].radio == true and back[3].radio == nil,
			"converting rendered rows back keeps the mark")
	end)
end)
