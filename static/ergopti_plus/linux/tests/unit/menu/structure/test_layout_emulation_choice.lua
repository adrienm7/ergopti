--- tests/unit/menu/structure/test_layout_emulation_choice.lua

--- ==============================================================================
--- MODULE: Layout To Emulate Choice Tests
--- DESCRIPTION:
--- Layouts and emulation › « Layout to emulate » on Linux, from the rows to the
--- engine: each click writes config.toml through the real preferences, the
--- rows rebuilt from it tick exactly one choice drawn as a radio, and
--- « None » turns the running emulation off (field report of 2026-11-25:
--- « None » and « bépo » ticked at once, the emulation still named bépo). The
--- group holds None and the layouts chosen last, then « Others… » opens the
--- picker of every layout (maintainer decision of 2026-11-25).
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
		resolve_key = function() return nil end,
	})
	return Emulation
end

--- Stores a choice through the real preferences and applies it, as both the
--- radio rows and the picker window do.
--- @param Emulation table
--- @param choice string
local function apply(Emulation, choice)
	helpers.assert_true(Preferences.choose(choice), "the choice " .. choice .. " is stored")
	Emulation.reload_if_started()
	return true
end

--- The « Layout to emulate » row as the menu builds it from the stored settings.
--- @param Emulation table
--- @param opened table|nil Receives the « Others… » openings.
--- @return table row
local function choice_row(Emulation, opened)
	return EmulationRows.choice_rows({
		t = function(key) return key end,
		settings = Preferences.settings(),
		status = Emulation.status(),
		snapshot = { index = INDEX },
		choose = function(choice) apply(Emulation, choice) end,
		open_picker = function(options) if opened then opened[#opened + 1] = options end end,
		others_rows = function(open) return require("menu.engine.manifest_menu").template_rows("layout_emulation_others_commands", { layout_emulation_others = open }, {}, {}) end,
	})[1]
end

--- The row label of a choice: the built-in ones by key, a registry layout by name.
--- @param choice string
--- @return string
local function label_for(choice)
	for _, entry in ipairs(INDEX.layouts) do
		if entry.id == choice and choice ~= "ergopti" and choice ~= "ergopti_plus" then return entry.name end
	end
	return "onboarding.layout.emulated_" .. choice
end

--- Starts from an empty configuration.
--- @return string config The config.toml path.
local function fresh_config()
	local config = ConfigPaths.config("config.toml")
	os.execute("mkdir -p '" .. config:match("^(.*)/") .. "'")
	os.remove(config)
	return config
end

--- The radio rows of the submenu, and its rows after them.
--- @param row table The « Layout to emulate » row.
--- @return table radios
--- @return table rest
local function split(row)
	local radios, rest = {}, {}
	for _, item in ipairs(row.items) do
		if item.radio == true then
			helpers.assert_eq(#rest, 0, "the radio group is one block at the top")
			radios[#radios + 1] = item
		else
			rest[#rest + 1] = item
		end
	end
	return radios, rest
end

helpers.describe("layout to emulate: one choice, None turns it off (layout-emulation-none)", function()
	helpers.it("ticks exactly one radio row after each click and None stops the emulation", function()
		local config = fresh_config()
		local Emulation = started_emulation()
		Emulation.reload()
		local count = require("layouts.engine.emulation.recents").count()
		for _, choice in ipairs({ "bepo", "bepo", "none", "ergopti", "bepo", "none", "none" }) do
			local before = choice_row(Emulation)
			local clicked = nil
			for _, item in ipairs(before.items) do
				if item.radio and item.label == label_for(choice) then clicked = item end
			end
			if clicked then
				clicked.action()
			else
				-- Not among the quick choices: « Others… » offers it.
				local offered = false
				for _, entry in ipairs(EmulationRows.picker_choices({ t = function(key) return key end,
					settings = Preferences.settings(), snapshot = { index = INDEX } })) do
					offered = offered or entry.id == choice
				end
				helpers.assert_true(offered, "the picker offers " .. choice)
				apply(Emulation, choice)
			end
			local radios = split(choice_row(Emulation))
			helpers.assert_true(#radios <= count + 1, "None and at most " .. count .. " quick choices")
			helpers.assert_eq(radios[1].label, label_for("none"), "None leads the group")
			local ticked = {}
			for _, item in ipairs(radios) do
				if item.checked then ticked[#ticked + 1] = item.label end
			end
			helpers.assert_eq(#ticked, 1, "exactly one choice is ticked after choosing " .. choice)
			helpers.assert_eq(ticked[1], label_for(choice), "the chosen choice is the ticked one")
			local status = Emulation.status()
			if choice == "none" then
				helpers.assert_nil(Preferences.settings().id, "None stores no emulated layout")
				helpers.assert_true(status.active == false, "None stops the running emulation")
			else
				helpers.assert_eq(status.id, choice, "the engine emulates the chosen layout")
				helpers.assert_true(status.active == true, "and runs it")
			end
		end
		-- The layouts chosen last, most recent first; None is never recorded.
		helpers.assert_eq(table.concat(Preferences.settings().recents, ","), "bepo,ergopti")
		os.remove(config)
	end)

	helpers.it("draws None, the recent layouts, a separator and « Others… » (emulation-quick-picker)", function()
		local config = fresh_config()
		local Emulation = started_emulation()
		Emulation.reload()
		for _, choice in ipairs({ "ergopti", "bepo", "ergopti_plus", "ergol", "none" }) do apply(Emulation, choice) end
		local opened = {}
		local radios, rest = split(choice_row(Emulation, opened))
		local labels = {}
		for _, item in ipairs(radios) do labels[#labels + 1] = item.label end
		helpers.assert_eq(table.concat(labels, ","), table.concat({ label_for("none"), label_for("ergol"),
			label_for("ergopti_plus"), label_for("bepo") }, ","), "the three layouts chosen last, most recent first")
		helpers.assert_true(radios[1].checked == true, "None is in force")
		helpers.assert_eq(#rest, 2, "a separator, then « Others… »")
		helpers.assert_true(rest[1].separator == true, "the separator follows the group")
		helpers.assert_eq(rest[2].label, require("core.i18n.engine.i18n").get("menu.layout.emulation_others"))
		helpers.assert_nil(rest[2].checked, "« Others… » is no choice of the group")
		rest[2].action()
		helpers.assert_eq(#opened, 1, "« Others… » opens the picker")
		local offered = {}
		for _, choice in ipairs(opened[1].choices()) do offered[#offered + 1] = choice.id end
		helpers.assert_eq(#offered, #INDEX.layouts, "the picker offers every layout, None left to the menu")
		local stored = read_all(config)
		helpers.assert_contains(stored, "emulated_layout_recents", "the recent layouts are stored")
		os.remove(config)
		-- Absent by default: an empty configuration offers None alone.
		radios = split(choice_row(Emulation))
		helpers.assert_eq(#radios, 1, "no recent layout in a fresh configuration")
	end)

	helpers.it("a tray click applies the choice to the running emulation without a reload", function()
		local config = fresh_config()
		local Emulation = started_emulation()
		Emulation.reload()
		-- Chosen before, so each is a quick choice of the tray.
		for _, choice in ipairs({ "ergopti", "bepo", "none" }) do apply(Emulation, choice) end
		local MenuLayouts = require("ui.menu.menu_layouts")
		-- The menu owner's translator global, as the daemon's menu sets it.
		local original_safe = rawget(_G, "i18n_safe")
		rawset(_G, "i18n_safe", function(key) return key end)
		local changes = 0
		--- The tray rows of the « Layout to emulate » choices, as the daemon builds them.
		local function choices()
			local root = MenuLayouts.build({ on_menu_changed = function() changes = changes + 1 end })
			local found, others = {}, nil
			-- The group row is row data around the finished tray subtree; the
			-- choices are the submenu of the « Layout to emulate » row.
			for _, row in ipairs(root.submenu) do
				if type(row.title) == "string" and row.title:find("menu.layout.emulated_layout", 1, true) == 1 then
					for _, choice in ipairs(row.menu) do
						if choice.title == require("core.i18n.engine.i18n").get("menu.layout.emulation_others") then
							others = choice
						elseif choice.title ~= "-" then
							helpers.assert_true(choice.radio == true, choice.title .. " reaches the tray as a radio")
							found[choice.title] = choice
						end
					end
				end
			end
			helpers.assert_true(others ~= nil and others.radio == nil and type(others.fn) == "function",
				"« Others… » reaches the tray as a plain row")
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

	helpers.it("« Others… » opens the picker and its choice applies live (emulation-quick-picker)", function()
		local config = fresh_config()
		local Emulation = started_emulation()
		Emulation.reload()
		local scripts, epoch, closed = {}, nil, 0
		local manager = {
			show = function() epoch = epoch or 7; return true end,
			current_epoch = function() return epoch end,
			eval_js = function(_, script) scripts[#scripts + 1] = script; return true end,
		}
		local context = { epoch = 7, close_owned_window = function() closed = closed + 1; epoch = nil; return true end }
		local saved_manager = package.loaded["core.ui.ui.webview_manager"]
		package.loaded["core.ui.ui.webview_manager"] = manager
		local Bridge = require("ui.emulation_picker.bridge")
		Bridge._reset()
		local MenuLayouts = require("ui.menu.menu_layouts")
		local original_safe = rawget(_G, "i18n_safe")
		rawset(_G, "i18n_safe", function(key) return key end)
		local changes = 0
		local ok, detail = xpcall(function()
			local function submenu()
				local root = MenuLayouts.build({ on_menu_changed = function() changes = changes + 1 end })
				for _, row in ipairs(root.submenu) do
					if type(row.title) == "string" and row.title:find("menu.layout.emulated_layout", 1, true) == 1 then
						return row.menu
					end
				end
				error("no « Layout to emulate » row")
			end
			local others = nil
			for _, row in ipairs(submenu()) do
				if row.title == require("core.i18n.engine.i18n").get("menu.layout.emulation_others") then others = row end
			end
			others.fn()
			helpers.assert_eq(Bridge.on_message("ready", nil, context), nil)
			helpers.assert_eq(#scripts, 1, "the page receives the catalogue")
			local json = scripts[1]:match("receiveEmulationPicker%((.*)%)$")
			local state = Json.decode(json)
			local offered = {}
			for _, choice in ipairs(state.choices) do offered[choice.id] = choice end
			helpers.assert_nil(offered.none, "None stays the menu's first row")
			helpers.assert_true(offered.bepo ~= nil and offered.ergopti ~= nil, "every layout is offered")
			-- A layout id the page made up is refused.
			Bridge.on_message({ action = "choose", session = state.session, id = "made_up" }, nil, context)
			helpers.assert_true(Emulation.status().active == false, "an id never offered writes nothing")
			Bridge.on_message({ action = "choose", session = "stale", id = "bepo" }, nil, context)
			helpers.assert_true(Emulation.status().active == false, "a stale page writes nothing")
			local before = changes
			Bridge.on_message({ action = "choose", session = state.session, id = "bepo" }, nil, context)
			helpers.assert_true(Emulation.status().active == true and Emulation.status().id == "bepo",
				"the picker's choice applies at once")
			helpers.assert_eq(closed, 1, "and closes the window")
			helpers.assert_true(changes > before, "the menu is redrawn")
			local ticked = nil
			for _, row in ipairs(submenu()) do
				if row.radio and row.checked then ticked = row.title end
			end
			helpers.assert_eq(ticked, label_for("bepo"), "the chosen layout is the ticked quick choice")
		end, debug.traceback)
		package.loaded["core.ui.ui.webview_manager"] = saved_manager
		rawset(_G, "i18n_safe", original_safe)
		Bridge._reset()
		os.remove(config)
		if not ok then error(detail, 0) end
	end)

	helpers.it("replays the shared recents vectors (emulation-quick-picker)", function()
		local Recents = require("layouts.engine.emulation.recents")
		local vectors = Json.decode(read_all(Paths.shared("tests/corpus/layouts/emulation_recents_vectors.json")))
		helpers.assert_eq(Recents.count(), vectors.count, "the shipped length is the one the vectors pin")
		for _, case in ipairs(vectors.after) do
			helpers.assert_eq(table.concat(Recents.after(case.recents, case.choice, vectors.count), ","),
				table.concat(case.expected, ","), case.name)
		end
		for _, case in ipairs(vectors.quick) do
			local offered = {}
			for _, id in ipairs(case.offered) do offered[id] = true end
			helpers.assert_eq(table.concat(Recents.quick(case.current, case.recents,
				function(id) return offered[id] == true end, vectors.count), ","), table.concat(case.expected, ","), case.name)
		end
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
