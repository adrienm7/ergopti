--- tests/unit/ui/test_wpm_readouts.lua

--- ==============================================================================
--- MODULE: The WPM Readouts, Without A Screen
--- DESCRIPTION:
--- The floating widget and the tray readout, from the live stats to the frame a
--- surface is asked to draw, against the real shared canon.
---
--- WHAT WAS BROKEN, AND IS PINNED HERE:
---   - the widget called a renderer function that never existed, so it drew
---     nothing on any desktop while its menu row ticked;
---   - the stats it read carried no speed and no source, so even a surface
---     would have drawn "0" in the idle colour forever;
---   - its strip kept 60 % of each channel where macOS and Windows keep 40 %;
---   - with source colours off it drew the idle pill, never the manual one;
---   - its stop() hid the hotstring preview bubble, a different window.
--- WHAT ONLY A DISPLAY CAN SAY is in tests/hardware/run_wpm_widget_live.lua.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local Model = require("wpm_widget.model")
local Codec = require("toml_codec")
local Paths = require("infra.paths")
local LiveWpm = require("keylogger.live_wpm")

local CANON_PATH = Paths.shared("modules/wpm_widget/constants.toml")

local function canon()
	return assert(Model.load(CANON_PATH, Codec.decode))
end

--- Live stats as the keylogger reports them.
local function stats(wpm, source, variant, at_s)
	return { wpm = wpm, source = source or "none", source_variant = variant or source or "none",
		source_time = at_s or 0 }
end

local function opts(now_s, use_colors, resolve)
	return { now_s = now_s, hold_s = 1.0, use_colors = use_colors, resolve = resolve, unit = "MPM" }
end




-- =================================================================
-- =================================================================
-- ======= 1/ The canon ============================================
-- =================================================================
-- =================================================================

helpers.describe("wpm readouts: the shared canon", function()

	helpers.it("loads, with every key the readouts draw with", function()
		local loaded, err = Model.load(CANON_PATH, Codec.decode)
		helpers.assert_true(loaded ~= nil, tostring(err))
	end)

	helpers.it("refuses a canon missing a key rather than drawing with a guess", function()
		local broken = canon()
		broken.graph.scale_max = nil
		local refused, err = Model.validate(broken)
		helpers.assert_nil(refused)
		helpers.assert_true(err:find("scale_max", 1, true) ~= nil, err)
	end)

	helpers.it("refuses a colour that is not #RRGGBB", function()
		local broken = canon()
		broken.colors.bg_ai = "purple"
		helpers.assert_nil((Model.validate(broken)))
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Colours and text =====================================
-- =================================================================
-- =================================================================

helpers.describe("wpm readouts: colours", function()

	helpers.it("darkens the strip to 40 % of each channel, as macOS and Windows do", function()
		-- 0x55 × 0.40 = 34 (0x22), 0xcc × 0.40 = 81.6 → 82 (0x52). Linux kept 60 %.
		helpers.assert_eq(Model.darken_hex("#0055cc", 0.40), "#002252")
		local c = canon()
		local frame = Model.compact_frame(c, stats(50), opts(10, true))
		helpers.assert_eq(frame.strip, Model.darken_hex(c.colors.bg_manual, c.compact.unit_strip_darken_factor))
	end)

	helpers.it("paints the AI's text in the AI colour", function()
		local c = canon()
		local frame = Model.compact_frame(c, stats(50, "llm", "llm", 9.5), opts(10, true))
		helpers.assert_eq(frame.background, c.colors.bg_ai)
	end)

	helpers.it("paints a hotstring in its group's own colour", function()
		local c = canon()
		local asked = nil
		local frame = Model.compact_frame(c, stats(50, "hotstring", "magickey", 9.5), opts(10, true,
			function(group) asked = group; return "#FF8800" end))
		helpers.assert_eq(asked, "magickey")
		helpers.assert_eq(frame.background, "#ff8800")
	end)

	helpers.it("falls back to the canon's accent when a group has no usable colour", function()
		local c = canon()
		local frame = Model.compact_frame(c, stats(50, "hotstring", "magickey", 9.5), opts(10, true,
			function() return "not-a-colour" end))
		helpers.assert_eq(frame.background, c.colors.fallback_accent)
	end)

	helpers.it("keeps neutral sources in the manual colour", function()
		local c = canon()
		local frame = Model.compact_frame(c, stats(50, "repeat_key", "repeat_key", 9.5), opts(10, true))
		helpers.assert_eq(frame.background, c.colors.bg_manual)
	end)

	helpers.it("returns to the manual colour once the source is older than the hold", function()
		local c = canon()
		local frame = Model.compact_frame(c, stats(50, "llm", "llm", 8), opts(10, true))
		helpers.assert_eq(frame.background, c.colors.bg_manual)
	end)

	helpers.it("with colours off, draws the manual pill — never the idle one", function()
		local c = canon()
		local frame = Model.compact_frame(c, stats(50, "llm", "llm", 9.9), opts(10, false))
		helpers.assert_eq(frame.background, c.colors.bg_manual)
		helpers.assert_eq(frame.alpha, c.transparency.alpha_active / 255)
	end)

	helpers.it("shows the number and the translated unit apart", function()
		local frame = Model.compact_frame(canon(), stats(87.6), opts(0, true))
		helpers.assert_eq(frame.number, "87")
		helpers.assert_eq(frame.unit, "MPM")
		helpers.assert_eq(Model.readout_label(87, "WPM"), "87 WPM")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The graph ============================================
-- =================================================================
-- =================================================================

helpers.describe("wpm readouts: the graph", function()

	helpers.it("keeps the canon's number of samples", function()
		local c = canon()
		local history = {}
		for index = 1, c.graph.history_samples + 15 do Model.push_history(c, history, index, "none") end
		helpers.assert_eq(#history, c.graph.history_samples)
		helpers.assert_eq(history[#history].wpm, c.graph.history_samples + 15)
	end)

	helpers.it("draws the curve inside the panel, clamped at the fixed scale", function()
		local c = canon()
		local history = {}
		for _, wpm in ipairs({ 0, 40, c.graph.scale_max * 3 }) do Model.push_history(c, history, wpm, "none") end
		local frame = Model.graph_frame(c, history, stats(40), opts(0, true))
		for _, point in ipairs(frame.points) do
			helpers.assert_true(point.x >= 0 and point.x <= frame.width, "x inside the panel")
			helpers.assert_true(point.y >= 0 and point.y <= frame.height, "y inside the panel")
		end
		helpers.assert_eq(frame.points[1].y, frame.bottom, "zero sits on the floor")
		helpers.assert_true(frame.points[3].y >= frame.bottom - (c.graph.height - 2 * c.graph.text_size),
			"a speed over the scale stops at its top")
		helpers.assert_eq(frame.label, "40 MPM")
	end)

	helpers.it("shares the pill's bottom-right corner, so switching mode does not move it", function()
		local c = canon()
		local pill = Model.compact_frame(c, stats(1), opts(0, true))
		local graph = Model.graph_frame(c, {}, stats(1), opts(0, true))
		local gx, gy = Model.frame_origin(c, graph, 100, 200)
		helpers.assert_eq(gx + graph.width, 100 + pill.width)
		helpers.assert_eq(gy + graph.height, 200 + pill.height)
		local ax, ay = Model.anchor_from_origin(c, graph, gx, gy)
		helpers.assert_eq(ax, 100)
		helpers.assert_eq(ay, 200)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 4/ Showing ==============================================
-- =================================================================
-- =================================================================

helpers.describe("wpm readouts: when they show", function()

	local function visible(fields)
		local ctx = { wpm = 0, source = "none", now_s = 100, last_active_s = 0, last_mouse_s = 0, idle_hide_s = 3 }
		for key, value in pairs(fields) do ctx[key] = value end
		return (Model.widget_visible(ctx))
	end

	helpers.it("shows while text is appearing", function()
		helpers.assert_true(visible({ wpm = 40 }))
	end)

	helpers.it("stays up briefly after typing stops, then hides", function()
		helpers.assert_true(visible({ last_active_s = 98 }))
		helpers.assert_true(not visible({ last_active_s = 96 }))
	end)

	helpers.it("hides as soon as the mouse moves after the last keystroke", function()
		helpers.assert_true(not visible({ last_active_s = 99, last_mouse_s = 99.5 }))
	end)

	helpers.it("stays up while a preview is on screen", function()
		helpers.assert_true(visible({ tooltip_visible = true }))
	end)

	helpers.it("shows the menu bar readout while typing or while a source colours it", function()
		helpers.assert_true(Model.menubar_visible(stats(10), "none", false))
		helpers.assert_true(Model.menubar_visible(stats(0), "llm", false))
		helpers.assert_true(not Model.menubar_visible(stats(0), "none", false))
	end)

	helpers.it("sits by default in the screen's bottom-right corner, inset", function()
		local c = canon()
		local x, y = Model.default_anchor(c, { x = 0, y = 0, w = 1920, h = 1080 })
		local height = c.compact.height_number + c.compact.height_gap + c.compact.height_unit
		helpers.assert_eq(x, 1920 - c.compact.width - c.compact.edge_margin)
		helpers.assert_eq(y, 1080 - height - c.compact.edge_margin)
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 5/ The live speed =======================================
-- =================================================================
-- =================================================================

helpers.describe("wpm readouts: the live speed", function()

	local function tracker()
		return LiveWpm.new({ window_ms = 15000, min_duration_ms = 2000, idle_reset_ms = 5000 })
	end

	helpers.it("counts typed characters as words per minute", function()
		local t = tracker()
		-- 5 characters per second = 60 WPM.
		for index = 0, 49 do LiveWpm.record(t, 1, index * 200) end
		local wpm = LiveWpm.stats(t, 9800).wpm
		helpers.assert_true(wpm >= 58 and wpm <= 62, "about 60, got " .. wpm)
	end)

	helpers.it("reads 0 after a pause, not the last burst's speed", function()
		local t = tracker()
		for index = 0, 49 do LiveWpm.record(t, 1, index * 200) end
		helpers.assert_eq(LiveWpm.stats(t, 9800 + 5001).wpm, 0)
	end)

	helpers.it("names the last source and its group", function()
		local t = tracker()
		LiveWpm.mark_source(t, "hotstring", "magickey", 4200)
		local s = LiveWpm.stats(t, 4300)
		helpers.assert_eq(s.source, "hotstring")
		helpers.assert_eq(s.source_variant, "magickey")
		helpers.assert_eq(s.source_time, 4.2)
	end)

	helpers.it("is fed by the Linux keylogger's typing, expansions and completions", function()
		local keylogger = helpers.load_module("modules.keylogger.keylogger")
		keylogger.reset_session()
		for index = 0, 29 do keylogger.on_keydown("a", 1000 + index * 150, "app", 30) end
		keylogger.record_hotstring("app", "adn", "au début", 5600, "magickey", 3, false)
		local live = keylogger.get_live_stats(5700)
		helpers.assert_true(live.wpm > 0, "the speed reaches the readouts")
		helpers.assert_eq(live.source, "hotstring")
		helpers.assert_eq(live.source_variant, "magickey", "the group picks the colour")
		keylogger.record_synthetic_output("app", "suite", "llm", 5800, 0, 0)
		helpers.assert_eq(keylogger.get_live_stats(5900).source, "llm")
		keylogger.reset_session()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 6/ The widget and the tray readout =====================
-- =================================================================
-- =================================================================

--- A surface that records what it is asked to draw.
local function fake_surface()
	local surface = { draws = {}, hidden = 0, visible = false, dragging = false, moved = nil, pointer = { 5, 5 } }
	function surface.is_available() return true end
	function surface.draw(frame, x, y)
		surface.draws[#surface.draws + 1] = { frame = frame, x = x, y = y }
		surface.visible = true
		return true
	end
	function surface.hide() surface.hidden = surface.hidden + 1; surface.visible = false end
	function surface.is_dragging() return surface.dragging end
	function surface.on_moved(fn) surface.moved = fn end
	function surface.screen_frame() return { x = 0, y = 0, w = 1920, h = 1080 } end
	function surface.pointer_position() return surface.pointer[1], surface.pointer[2] end
	return surface
end

local _displaced = {}

local function with_storage(initial, body)
	_displaced.storage = package.loaded["adapters.storage"]
	-- The previews other suites leave up would keep the readouts shown.
	_displaced.preview = package.loaded["ui.tooltip.preview"]
	_displaced.llm = package.loaded["ui.tooltip.llm"]
	package.loaded["ui.tooltip.preview"] = { is_visible = function() return false end }
	package.loaded["ui.tooltip.llm"] = { is_showing = function() return false end }
	local store = Fakes.storage({ initial = initial or {} })
	package.loaded["adapters.storage"] = store
	package.loaded["ui.wpm.widget"] = nil
	package.loaded["ui.wpm.tray_readout"] = nil
	local ok, err = pcall(body, store)
	package.loaded["adapters.storage"] = _displaced.storage
	package.loaded["ui.tooltip.preview"] = _displaced.preview
	package.loaded["ui.tooltip.llm"] = _displaced.llm
	package.loaded["ui.wpm.widget"] = nil
	package.loaded["ui.wpm.tray_readout"] = nil
	if not ok then error(err, 0) end
end

helpers.describe("wpm readouts: the floating widget", function()

	helpers.it("draws the pill in the bottom-right corner while the user types", function()
		with_storage({}, function()
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			helpers.assert_true(Widget.start())
			Widget.tick(stats(42), 10)
			helpers.assert_eq(#surface.draws, 1, "the widget really asks for a drawing")
			local drawn = surface.draws[1]
			helpers.assert_eq(drawn.frame.mode, "compact")
			helpers.assert_eq(drawn.frame.number, "42")
			local c = canon()
			helpers.assert_eq(drawn.x, 1920 - c.compact.width - c.compact.edge_margin)
		end)
	end)

	helpers.it("redraws at the shared rate, however often it is ticked", function()
		with_storage({}, function()
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			Widget.start()
			Widget.tick(stats(42), 10)
			Widget.tick(stats(43), 10.05)
			helpers.assert_eq(#surface.draws, 1)
			Widget.tick(stats(44), 10.3)
			helpers.assert_eq(#surface.draws, 2)
		end)
	end)

	helpers.it("hides once the user stops typing and goes back to the mouse", function()
		with_storage({}, function()
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			Widget.start()
			Widget.tick(stats(42), 10)
			surface.pointer = { 300, 400 }
			Widget.tick(stats(0), 10.5)
			helpers.assert_true(not surface.visible)
		end)
	end)

	helpers.it("keeps the place the user drags it to, across a restart", function()
		with_storage({}, function(store)
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			Widget.start()
			Widget.tick(stats(42), 10)
			surface.moved(640, 360)
			helpers.assert_eq(store.values["wpm_widget.pos_x"], 640)
			helpers.assert_eq(store.values["wpm_widget.pos_y"], 360)
			package.loaded["ui.wpm.widget"] = nil
			local Restarted = require("ui.wpm.widget")
			local again = fake_surface()
			Restarted._set_surface(again)
			Restarted.restore()
			Restarted.tick(stats(42), 20)
			helpers.assert_eq(again.draws[1].x, 640)
			helpers.assert_eq(again.draws[1].y, 360)
			helpers.assert_true(Restarted.reset_position())
			helpers.assert_nil(store.values["wpm_widget.pos_x"])
		end)
	end)

	helpers.it("draws the graph in graph mode, and keeps that choice", function()
		with_storage({}, function(store)
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			Widget.start()
			helpers.assert_true(Widget.set_graph(true))
			Widget.tick(stats(42), 10)
			helpers.assert_eq(surface.draws[1].frame.mode, "graph")
			helpers.assert_eq(store.values["wpm_widget.graph"], true)
		end)
	end)

	helpers.it("hides its own window on stop, never the preview bubble", function()
		with_storage({}, function()
			local Renderer = require("adapters.graphics_renderer")
			local preview_hidden = false
			local real_hide = Renderer.hide
			Renderer.hide = function() preview_hidden = true end
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			Widget.start()
			Widget.tick(stats(42), 10)
			Widget.stop()
			Renderer.hide = real_hide
			helpers.assert_eq(surface.hidden, 1)
			helpers.assert_true(not preview_hidden)
		end)
	end)

end)

helpers.describe("wpm readouts: the tray readout", function()

	local function fake_tray()
		local tray = { items = {}, updates = {} }
		function tray.new_item(id, icon, items)
			local handle = { id = id, icon = icon, menu = items }
			tray.items[#tray.items + 1] = handle
			return handle
		end
		function tray.update_item(handle, opts_)
			tray.updates[#tray.updates + 1] = opts_
			for key, value in pairs(opts_) do handle[key] = value end
			return true
		end
		function tray.remove_item(handle) handle.removed = true end
		return tray
	end

	local function setup()
		local Readout = require("ui.wpm.tray_readout")
		local tray = fake_tray()
		local painted = {}
		Readout._set_tray(tray)
		Readout._set_painter(function(frame, path) painted[#painted + 1] = { frame = frame, path = path }; return true end)
		return Readout, tray, painted
	end

	helpers.it("appears with the speed while typing, and leaves the panel after", function()
		with_storage({}, function()
			local Readout, tray, painted = setup()
			helpers.assert_true(Readout.start())
			Readout.tick(stats(57), 10)
			helpers.assert_eq(#tray.items, 1)
			helpers.assert_eq(tray.items[1].active, true)
			helpers.assert_eq(tray.items[1].title, "57 " .. require("infra.i18n").get("menu.metrics.wpm_unit"))
			helpers.assert_eq(painted[1].frame.number, "57")
			Readout.tick(stats(0), 11)
			helpers.assert_eq(tray.items[1].active, false)
		end)
	end)

	helpers.it("paints a new icon file when the number changes, so a panel's cache cannot hold the old one", function()
		with_storage({}, function()
			local Readout, _, painted = setup()
			Readout.start()
			Readout.tick(stats(57), 10)
			Readout.tick(stats(57), 11)
			helpers.assert_eq(#painted, 1, "an unchanged number is not repainted")
			Readout.tick(stats(58), 12)
			helpers.assert_eq(#painted, 2)
			helpers.assert_true(painted[1].path ~= painted[2].path)
		end)
	end)

	helpers.it("is coloured by the source, as on macOS, unless colours are off", function()
		with_storage({}, function()
			local Readout, _, painted = setup()
			Readout.start()
			Readout.tick(stats(57, "llm", "llm", 9.8), 10)
			helpers.assert_eq(painted[1].frame.background, canon().colors.bg_ai)
			helpers.assert_true(Readout.set_use_source_colors(false))
			Readout.tick(stats(58, "llm", "llm", 10.9), 11)
			helpers.assert_nil(painted[2].frame.background)
		end)
	end)

	helpers.it("removes its item on stop, and keeps that choice", function()
		with_storage({}, function(store)
			local Readout, tray = setup()
			Readout.start()
			Readout.tick(stats(57), 10)
			helpers.assert_true(Readout.stop())
			helpers.assert_true(tray.items[1].removed)
			helpers.assert_eq(store.values["wpm_menubar.visible"], nil, "off is the shipped default: nothing stored")
		end)
	end)

end)
