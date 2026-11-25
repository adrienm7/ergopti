--- tests/unit/menu/ui/keyboard_layout/test_emulation_quick_picker.lua

--- ==============================================================================
--- MODULE: Layout To Emulate Quick Choices And Picker (macOS)
--- DESCRIPTION:
--- « Layouts and emulation › Layout to emulate » keeps one single-choice group:
--- « None » and the layouts chosen last, then « Others… », which opens the
--- picker of every layout (maintainer decision of 2026-11-25). Replays the
--- shared recents vectors, then drives the menu preferences, the shared rows
--- and the macOS picker window from a choice to the next menu.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")
local Recents = require("layouts.engine.emulation.recents")
local EmulationRows = require("layouts.engine.emulation.menu")

local KEY = require("settings.engine.keys").KEY
local MODULES = { "infra.layout_emulation_preferences", "settings.engine.preferences.preferences",
	"core.logger.engine.logger", "core.logger.engine.shim" }

local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	assert(handle:close())
	return text
end

local VECTORS = Json.decode(read_all(Paths.shared("tests/corpus/layouts/emulation_recents_vectors.json")))
local INDEX = { layouts = { { id = "ergopti", name = "Ergopti" }, { id = "bepo", name = "bépo" },
	{ id = "ergol", name = "Ergo-L" }, { id = "colemak", name = "Colemak" } } }

--- Runs `body` with fresh preferences and a silent logger.
--- @param body function Receives the preferences writer and the flat key resolver.
local function with_preferences(body)
	helpers.with_stub_scope(MODULES, function()
		local logger = helpers.make_logger_stub()
		package.loaded["core.logger.engine.logger"], package.loaded["core.logger.engine.shim"] = logger, logger
		package.loaded["infra.layout_emulation_preferences"] = nil
		local writer = require("infra.layout_emulation_preferences")
		local Preferences = require("settings.engine.preferences.preferences")
		body(writer, function(path) return assert(Preferences.flat_key_for(path)) end)
	end)
end

--- The « Layout to emulate » row the menu draws from the state.
--- @param writer table infra.layout_emulation_preferences
--- @param state table
--- @param opened table|nil Receives the « Others… » openings.
--- @return table row
local function choice_row(writer, state, opened)
	return EmulationRows.choice_rows({
		t = function(key) return key end,
		settings = writer.settings(state),
		snapshot = { index = INDEX },
		choose = function(choice) writer.choose(state, function() return true end, choice) end,
		open_picker = function(options) if opened then opened[#opened + 1] = options end end,
		others_rows = function(open) return require("menu.engine.manifest_menu").template_rows("layout_emulation_others_commands", { layout_emulation_others = open }, {}, {}) end,
	})[1]
end

helpers.describe("layout to emulate: recent layouts (emulation-quick-picker)", function()
	helpers.it("replays the shared recents vectors", function()
		helpers.assert_eq(Recents.count(), VECTORS.count, "the shipped length is the one the vectors pin")
		for _, case in ipairs(VECTORS.after) do
			helpers.assert_eq(table.concat(Recents.after(case.recents, case.choice, VECTORS.count), ","),
				table.concat(case.expected, ","), case.name)
		end
		for _, case in ipairs(VECTORS.quick) do
			local offered = {}
			for _, id in ipairs(case.offered) do offered[id] = true end
			local ids = Recents.quick(case.current, case.recents, function(id) return offered[id] == true end,
				VECTORS.count)
			helpers.assert_eq(table.concat(ids, ","), table.concat(case.expected, ","), case.name)
		end
	end)

	helpers.it("a choice leads the stored recents, None is never recorded and a refusal restores them", function()
		with_preferences(function(writer, flat_key)
			local key = flat_key(KEY.LAYOUT_EMULATED_LAYOUT_RECENTS)
			local state = {}
			for _, choice in ipairs({ "bepo", "ergol", "none", "colemak", "ergopti" }) do
				helpers.assert_eq(writer.choose(state, function() return true end, choice), true)
			end
			helpers.assert_eq(table.concat(state[key], ","), "ergopti,colemak,ergol")
			local before = state[key]
			helpers.assert_eq(writer.choose(state, function() return false end, "bepo"), false)
			helpers.assert_true(state[key] == before, "a refused save restores the recent layouts")
		end)
	end)

	helpers.it("draws one checked group of None and the recent layouts, then « Others… »", function()
		with_preferences(function(writer)
			local state = {}
			local opened = {}
			local row = choice_row(writer, state, opened)
			helpers.assert_eq(#row.items, 3, "a fresh configuration offers None, a separator and « Others… »")
			for _, choice in ipairs({ "bepo", "ergol", "colemak", "ergopti", "none" }) do
				writer.choose(state, function() return true end, choice)
			end
			row = choice_row(writer, state, opened)
			local labels, checked = {}, 0
			for index, item in ipairs(row.items) do
				if index <= #row.items - 2 then
					helpers.assert_true(item.radio == true, item.label .. " is one choice of the group")
					labels[#labels + 1] = item.label
					if item.checked then checked = checked + 1 end
				end
			end
			helpers.assert_eq(table.concat(labels, ","), "onboarding.layout.emulated_none,"
				.. "onboarding.layout.emulated_ergopti,Colemak,Ergo-L")
			helpers.assert_eq(checked, 1, "exactly one row is checked")
			helpers.assert_true(row.items[#row.items - 1].separator == true)
			helpers.assert_eq(row.items[#row.items].label, require("core.i18n.engine.i18n").get("menu.layout.emulation_others"))
			row.items[#row.items].action()
			helpers.assert_eq(#opened, 1, "« Others… » opens the picker")
			helpers.assert_eq(#opened[1].choices(), #INDEX.layouts + 1, "with every layout, Ergopti+ included")
			-- A choice from the quick rows ticks it at once.
			row.items[3].action()
			row = choice_row(writer, state)
			helpers.assert_true(row.items[2].checked == true and row.items[2].label == "Colemak",
				"the chosen layout leads the group, ticked")
		end)
	end)
end)

--- Runs `run` with the macOS picker window over stubbed native owners.
--- @param run function Receives the window module and the recorded context.
local function with_window(run)
	local context = { views = {}, callbacks = {}, scripts = {} }
	local current_hs = _G.hs
	local logger = {}
	for _, name in ipairs({ "start", "success", "info", "warn", "error" }) do logger[name] = function() end end
	local stubs = {
		["core.logger.engine.logger"] = logger,
		["core.ui.ui.builder"] = {
			get_app_geometry = function(app_id) context.geometry = app_id; return { width = 440, height = 520 } end,
			force_focus = function() context.focused = true; return true end,
			show_webview = function(options)
				context.options = options
				local view = { deleted = 0 }
				function view:delete() self.deleted = self.deleted + 1; return true end
				function view:evaluateJavaScript(script) context.scripts[#context.scripts + 1] = script; return self end
				context.views[#context.views + 1] = view
				options.on_webview_created(view)
				return view
			end,
		},
	}
	_G.hs = {
		json = { encode = Json.encode },
		screen = { mainScreen = function()
			return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
		end },
		webview = { windowMasks = { titled = 1, closable = 2, resizable = 8 }, usercontent = { new = function(name)
			context.bridge = name
			return { setCallback = function(self, callback)
				if callback then context.callbacks[#context.callbacks + 1] = callback end
				return self
			end }
		end } },
	}
	local saved, names = {}, { "ui.emulation_picker" }
	for name in pairs(stubs) do names[#names + 1] = name end
	for _, name in ipairs(names) do saved[name] = { package.loaded[name] }; package.loaded[name] = stubs[name] end
	local ok, detail = xpcall(function() run(require("ui.emulation_picker"), context) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
	_G.hs = current_hs
	if not ok then error(detail, 0) end
end

helpers.describe("emulation picker window (macOS, emulation-quick-picker)", function()
	helpers.it("offers every layout, applies an offered choice and closes", function()
		with_window(function(window, context)
			local chosen = {}
			local choices = EmulationRows.picker_choices({ t = function(key) return key end,
				settings = { id = "bepo", recents = {} }, snapshot = { index = INDEX } })
			helpers.assert_eq(window.open({ choices = function() return choices end,
				choose = function(id) chosen[#chosen + 1] = id; return true end }), true)
			helpers.assert_eq(context.bridge, "emulation_picker_bridge")
			helpers.assert_eq(context.options.app_id, "emulation_picker", "the shared manifest names the window")
			helpers.assert_eq(context.geometry, "emulation_picker")
			context.callbacks[1]({ body = "ready" })
			helpers.assert_eq(#context.scripts, 1)
			local state = Json.decode(context.scripts[1]:match("receiveEmulationPicker%((.*)%)$"))
			local current = nil
			for _, choice in ipairs(state.choices) do
				helpers.assert_true(choice.id ~= "none", "None stays the menu's first row")
				if choice.current then current = choice.id end
			end
			helpers.assert_eq(current, "bepo", "the layout in force is marked")
			context.callbacks[1]({ body = { action = "choose", session = state.session, id = "made_up" } })
			context.callbacks[1]({ body = { action = "choose", session = "stale", id = "ergol" } })
			helpers.assert_eq(#chosen, 0, "an id never offered or a stale page writes nothing")
			context.callbacks[1]({ body = { action = "choose", session = state.session, id = "ergol" } })
			helpers.assert_eq(table.concat(chosen, ","), "ergol", "the offered choice is applied")
			helpers.assert_eq(context.views[1].deleted, 1, "and the window closes")
		end)
	end)

	helpers.it("keeps the window open and says so when the choice is refused", function()
		with_window(function(window, context)
			window.open({ choices = function() return { { id = "ergol", label = "Ergo-L", current = false } } end,
				choose = function() return false end })
			context.callbacks[1]({ body = "ready" })
			local state = Json.decode(context.scripts[1]:match("receiveEmulationPicker%((.*)%)$"))
			context.callbacks[1]({ body = { action = "choose", session = state.session, id = "ergol" } })
			helpers.assert_eq(context.views[1].deleted, 0, "a refused choice leaves the window open")
			helpers.assert_contains(context.scripts[2], '"refused":true')
			context.callbacks[1]({ body = { action = "cancel", session = state.session } })
			helpers.assert_eq(context.views[1].deleted, 1, "Cancel closes it")
		end)
	end)
end)
