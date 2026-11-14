--- tests/unit/ui/metrics/test_wpm_readouts.lua

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
local Model = require("metrics.engine.wpm_widget_model")
local Codec = require("core.text.engine.toml_codec")
local Paths = require("core.fs.engine.paths")
local LiveWpm = require("metrics.engine.wpm.live_wpm")

local CANON_PATH = Paths.shared("metrics/data/wpm_widget/constants.toml")

local function canon()
	return assert(Model.load(CANON_PATH, Codec.decode))
end

--- Live stats as the keystats reports them.
local function stats(wpm, source, variant, at_s)
	return { wpm = wpm, source = source or "none", source_variant = variant or source or "none",
		source_time = at_s or 0, last_input_time = at_s,
		source_holds = source and { { source = source, variant = variant or source, time = at_s or 0 } } or {} }
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

	helpers.it("names the Storage keys of the saved place, the same on every driver", function()
		local loaded = canon()
		helpers.assert_eq(loaded.position.storage_x, "wpm_widget.pos_x")
		helpers.assert_eq(loaded.position.storage_y, "wpm_widget.pos_y")
		helpers.assert_eq(loaded.position.storage_pair, "wpm_widget.pos")
		for _, key in ipairs({ "storage_x", "storage_y", "storage_pair" }) do
			local broken = canon()
			broken.position[key] = nil
			local refused, err = Model.validate(broken)
			helpers.assert_nil(refused)
			helpers.assert_true(err:find(key, 1, true) ~= nil, err)
		end
		local missing = canon()
		missing.position = nil
		helpers.assert_nil((Model.validate(missing)))
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

	helpers.it("(wpm-pointer-wiring) timestamps the native pointer callback before any event return", function()
		local code = assert(helpers.read_driver_unit("local function on_pointer_event(kind_of_event"))
		local first = assert(code:find("local function on_pointer_event(kind_of_event", 1, true))
		local final = assert(code:find("\n\tend", first, true))
		local callback = code:sub(first, final)
		local stamp = assert(callback:find("wpm_widget.observe_pointer(kind_of_event, value, Monotonic.now_ms() / 1000)", 1, true))
		local early_return = assert(callback:find("then return end", 1, true))
		helpers.assert_true(stamp < early_return, "native activity must precede frame filtering")
		helpers.assert_true(code:find("onPointerEvent = on_pointer_event", 1, true) ~= nil,
			"the clock owner must receive the real hook callback")
	end)

	local function visible(fields)
		local ctx = { wpm = 0, source = "none", now_s = 100, last_input_s = 0, last_mouse_s = 0, idle_hide_s = 3 }
		for key, value in pairs(fields) do ctx[key] = value end
		return (Model.widget_visible(ctx))
	end

	helpers.it("shows while text is appearing", function()
		helpers.assert_true(visible({ wpm = 40, last_input_s = 100 }))
	end)

	helpers.it("stays up briefly after typing stops, then hides", function()
		helpers.assert_true(visible({ last_input_s = 98 }))
		helpers.assert_true(not visible({ last_input_s = 96 }))
	end)

	helpers.it("hides as soon as the mouse moves after the last keystroke", function()
		helpers.assert_true(not visible({ last_input_s = 99, last_mouse_s = 99.5 }))
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
		return LiveWpm.new({ window_ms = 15000, min_duration_ms = 2000, idle_reset_ms = 5000, source_hold_ms = 1000 })
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

	helpers.it("is fed by the Linux keystats's typing, expansions and completions", function()
		local keystats = helpers.load_module("modules.keystats.keystats")
		require("tests.support.metrics_consent_fixture").enable(keystats)
		keystats.reset_session()
		for index = 0, 29 do keystats.on_keydown("a", 1000 + index * 150, "app", 30) end
		keystats.record_hotstring("app", "adn", "au début", 5600, "magickey", 3, false)
		local live = keystats.get_live_stats(5700)
		helpers.assert_true(live.wpm > 0, "the speed reaches the readouts")
		helpers.assert_eq(live.source, "hotstring")
		helpers.assert_eq(live.source_variant, "magickey", "the group picks the colour")
		keystats.record_synthetic_output("app", "suite", "llm", 5800, 0, 0)
		helpers.assert_eq(keystats.get_live_stats(5900).source, "llm")
		keystats.reset_session()
	end)

	helpers.it("(wpm-pointer-parity) orders a raw key and mouse inside the same millisecond", function()
		require("tests.support.keystats_native_fixture").with(function(keystats)
			require("tests.support.metrics_consent_fixture").enable(keystats)
			local clock = require("infra.monotonic")
			local previous = clock.now_ms
			clock.now_ms = function() return 10000.9 end
			local ok, err = pcall(function()
				keystats.record_physical_key("app", 30, 10000)
				keystats.on_keydown("a", 10000, "app", 30)
				local live = keystats.get_live_stats(10001)
				helpers.assert_eq(live.last_input_time, 10000.9 / 1000,
					"rounded character telemetry cannot rewind the raw physical input")
				helpers.assert_true(Model.widget_visible({ last_input_s = live.last_input_time,
					last_mouse_s = 10000.1 / 1000, now_s = 10.001, idle_hide_s = 3 }))
				helpers.assert_true(not Model.widget_visible({ last_input_s = live.last_input_time,
					last_mouse_s = 10000.95 / 1000, now_s = 10.001, idle_hide_s = 3 }))
			end)
			clock.now_ms = previous
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("(wpm-source-parity) real keystats preserves independent holds and the physical clock", function()
		require("tests.support.keystats_native_fixture").with(function(keystats)
			require("tests.support.metrics_consent_fixture").enable(keystats)
			local hold = require("infra.timings").ms("ui", "wpm_color_hold_ms")
			local start = 10000
			keystats.on_keydown("a", start, "app", 30)
			keystats.record_synthetic_output("app", "AI", "llm", start, 0, 0)
			keystats.record_hotstring("app", "a", "expand", start + hold / 4, "magickey", 1, false)
			keystats.record_hotstring("app", "b", "correct", start + hold / 2, "autocorrection", 1, false)
			keystats.record_hotstring("app", "c", "repeat", start + hold * 3 / 4, "repeat_key", 1, false)
			local function source(at)
				local live = keystats.get_live_stats(at)
				helpers.assert_eq(live.last_input_time, start / 1000, "synthetic text cannot become real input")
				return Model.active_source(live, hold / 1000, at / 1000, canon())
			end
			helpers.assert_eq(source(start + hold * 3 / 4), "llm")
			helpers.assert_eq(source(start + hold), "magickey", "AI expires at its own deadline")
			helpers.assert_eq(source(start + hold * 5 / 4), "autocorrection")
			helpers.assert_eq(source(start + hold * 3 / 2), "none")
			keystats.record_correction("app", start + hold * 2)
			helpers.assert_eq(keystats.get_live_stats(start + hold * 2).last_input_time, (start + hold * 2) / 1000)
			keystats.suspend_collection()
			keystats.resume_collection()
			helpers.assert_eq(keystats.get_live_stats(start + hold * 2).last_input_time, nil)
			helpers.assert_eq(#keystats.get_live_stats(start + hold * 2).source_holds, 0)
			keystats.record_synthetic_output("app", "AI", "llm", start + hold * 3, 0, 0)
			require("tests.support.metrics_preferences_fixture").with(function()
				helpers.assert_true(keystats.set_enabled(false))
			end)
			require("tests.support.metrics_consent_fixture").enable(keystats)
			helpers.assert_eq(#keystats.get_live_stats(start + hold * 3).source_holds, 0,
				"turning collection back on cannot revive old colour")
		end)
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
	function surface.hide() surface.hidden = surface.hidden + 1; surface.visible = false; return true end
	function surface.is_dragging() return surface.dragging end
	function surface.on_moved(fn) surface.moved = fn end
	function surface.screen_frame() return { x = 0, y = 0, w = 1920, h = 1080 } end
	function surface.pointer_position() return surface.pointer[1], surface.pointer[2] end
	return surface
end

local _displaced = {}

local function with_storage(initial, body)
	_displaced.storage = package.loaded["core.fs.adapters.storage"]
	-- The previews other suites leave up would keep the readouts shown.
	_displaced.preview = package.loaded["ui.tooltip.preview"]
	_displaced.llm = package.loaded["ui.tooltip.llm"]
	package.loaded["ui.tooltip.preview"] = { is_visible = function() return false end }
	package.loaded["ui.tooltip.llm"] = { is_showing = function() return false end }
	local store = Fakes.storage({ initial = initial or {} })
	-- This fixture models the mandatory all-or-none position batch, including deletions.
	function store.set_many(updates, deletions)
		for key, value in pairs(updates) do store.values[key] = value end
		for _, key in ipairs(deletions or {}) do store.values[key] = nil end
		return true
	end
	package.loaded["core.fs.adapters.storage"] = store
	package.loaded["ui.wpm.widget"] = nil
	package.loaded["ui.wpm.tray_readout"] = nil
	local ok, err = pcall(function()
		require("tests.support.metrics_preferences_fixture").with(function(preferences)
			body(store, preferences)
		end, { initial = initial })
	end)
	package.loaded["core.fs.adapters.storage"] = _displaced.storage
	package.loaded["ui.tooltip.preview"] = _displaced.preview
	package.loaded["ui.tooltip.llm"] = _displaced.llm
	package.loaded["ui.wpm.widget"] = nil
	package.loaded["ui.wpm.tray_readout"] = nil
	if not ok then error(err, 0) end
end

--- A stored choice of the compact pill, merged into extra stored values. The
--- graph ships on (decision of 2026-11-03), so a test measuring the compact pill
--- states that choice instead of relying on the default.
--- @param extra table|nil Further stored values.
--- @return table initial
local function compact(extra)
	local initial = { ["metrics.wpm_widget_graph"] = false }
	for key, value in pairs(extra or {}) do initial[key] = value end
	return initial
end

helpers.describe("wpm readouts: the floating widget", function()
	helpers.it("refuses native hide before changing the persisted visibility", function()
		with_storage({}, function(_, preferences)
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			helpers.assert_true(Widget.start())
			Widget.tick(stats(42, nil, nil, 10), 10)
			surface.hide = function() surface.visible = false; return false end
			helpers.assert_eq(Widget.stop(), false)
			helpers.assert_eq(preferences.get("metrics.wpm_widget_visible"), true)
			helpers.assert_true(Widget.is_running())
			helpers.assert_true(surface.visible, "a partially hidden native surface must be restored")
		end)
	end)

	helpers.it("captures and reapplies its exact frame without preference writes", function()
		with_storage(compact(), function(_, preferences)
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			Widget.restore()
			helpers.assert_true(Widget.start())
			Widget.tick(stats(42, nil, nil, 10), 10)
			local before = Widget.configuration_snapshot()
			local changed = Widget.configuration_snapshot()
			changed.running, changed.shown, changed.graph = false, false, true
			helpers.assert_true(Widget.apply_configuration(changed))
			helpers.assert_eq(surface.visible, false)
			helpers.assert_eq(preferences.get("metrics.wpm_widget_visible"), true)
			helpers.assert_true(Widget.apply_configuration(before))
			helpers.assert_true(surface.visible)
			helpers.assert_eq(surface.draws[#surface.draws].frame.number, "42")
			before.last_frame.number = "mutated"
			helpers.assert_eq(Widget.configuration_snapshot().last_frame.number, "42")
		end)
	end)

	helpers.it("draws the pill in the bottom-right corner while the user types", function()
		with_storage(compact(), function()
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			Widget.restore()
			helpers.assert_true(Widget.start())
			Widget.tick(stats(42, nil, nil, 10), 10)
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
			Widget.tick(stats(42, nil, nil, 10), 10)
			Widget.tick(stats(43, nil, nil, 10.05), 10.05)
			helpers.assert_eq(#surface.draws, 1)
			Widget.tick(stats(44, nil, nil, 10.3), 10.3)
			helpers.assert_eq(#surface.draws, 2)
		end)
	end)

	helpers.it("(wpm-pointer-parity) hides on pointer movement despite nonzero WPM and a held source", function()
		with_storage({}, function()
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			Widget.start()
			Widget.tick(stats(42, nil, nil, 10), 10)
			surface.pointer = { 300, 400 }
			Widget.observe_pointer("motion", 1, 10.5)
			Widget.tick(stats(42, "llm", "llm", 10), 10.5)
			helpers.assert_true(not surface.visible)
			package.loaded["ui.tooltip.preview"].is_visible = function() return true end
			Widget.tick(stats(42, "llm", "llm", 10), 10.8)
			helpers.assert_true(surface.visible)
			package.loaded["ui.tooltip.preview"].is_visible = function() return false end
			Widget.tick(stats(42, "llm", "llm", 10), 11.1)
			helpers.assert_true(not surface.visible)
			Widget.observe_pointer("motion", 1, 11.3)
			Widget.tick(stats(42, nil, nil, 11.4), 11.4)
			helpers.assert_true(surface.visible)
			Widget.tick(stats(42, nil, nil, 11.4), 100)
			helpers.assert_true(not surface.visible, "refresh cannot extend real input")
		end)
	end)

	helpers.it("(wpm-position-nonfinite) ignores a nonfinite stored coordinate", function()
		local initial = compact()
		initial["metrics.wpm_widget_visible"] = true
		initial["wpm_widget.pos_x"], initial["wpm_widget.pos_y"] = "1e999", 30
		with_storage(initial, function()
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			assert(Widget.restore())
			Widget.tick(stats(42, nil, nil, 10), 10)
			local x, y = Model.default_anchor(canon(), surface.screen_frame())
			helpers.assert_eq({ surface.draws[1].x, surface.draws[1].y }, { x, y })
		end)
	end)

	helpers.it("(wpm-position-nonfinite) refuses malformed native drag coordinates", function()
		with_storage(compact(), function(store)
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			assert(Widget.start())
			Widget.tick(stats(42, nil, nil, 10), 10)
			surface.moved(math.huge, 30)
			surface.moved({}, 30)
			helpers.assert_nil(store.values["wpm_widget.pos_x"])
			helpers.assert_nil(store.values["wpm_widget.pos_y"])
		end)
	end)

	helpers.it("(wpm-widget-hide-refusal) retains an ambiguous hide until native acknowledgment", function()
		with_storage(compact(), function()
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			assert(Widget.start())
			Widget.tick(stats(42, nil, nil, 10), 10)
			local original = surface.hide
			surface.hide = function() surface.visible = false; return false end
			surface.pointer = { 300, 400 }
			Widget.observe_pointer("motion", 1, 10.5)
			Widget.tick(stats(0, nil, nil, 10), 10.5)
			helpers.assert_eq(surface.visible, false)
			helpers.assert_nil(Widget.configuration_snapshot(), "partially hidden surface is not a stable snapshot")
			local draws = #surface.draws
			Widget.tick(stats(42, nil, nil, 11), 11)
			helpers.assert_eq(#surface.draws, draws, "a refused hide must settle before a new frame")
			surface.hide = original
			Widget.tick(stats(42, nil, nil, 12), 12)
			helpers.assert_true(surface.visible, "after the hide ACK the visible frame is drawn again")
			helpers.assert_type(Widget.configuration_snapshot(), "table")
		end)
	end)

	helpers.it("(wpm-draw-partial) hides a surface when drawing partially fails", function()
		with_storage(compact(), function()
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			assert(Widget.start())
			surface.draw = function() surface.visible = true; return false end
			Widget.tick(stats(42, nil, nil, 10), 10)
			helpers.assert_eq(surface.hidden, 1, "a failed draw may already have shown the window")
			helpers.assert_true(not surface.visible)
		end)
	end)

	helpers.it("(wpm-draw-partial) retries a refused hide after a failed draw", function()
		with_storage(compact(), function()
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			assert(Widget.start())
			surface.draw = function() surface.visible = true; error("draw failed after show") end
			local attempts = 0
			surface.hide = function()
				attempts = attempts + 1
				if attempts == 1 then return false end
				surface.visible = false
				return true
			end
			Widget.tick(stats(42, nil, nil, 10), 10)
			Widget.tick(stats(0, nil, nil, 10), 100)
			helpers.assert_eq(attempts, 2)
			helpers.assert_true(not surface.visible)
		end)
	end)

	helpers.it("keeps the place the user drags it to, across a restart", function()
		with_storage(compact(), function(store)
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			Widget.restore()
			Widget.start()
			Widget.tick(stats(42, nil, nil, 10), 10)
			surface.moved(640, 360)
			helpers.assert_eq(store.values["wpm_widget.pos_x"], 640)
			helpers.assert_eq(store.values["wpm_widget.pos_y"], 360)
			package.loaded["ui.wpm.widget"] = nil
			local Restarted = require("ui.wpm.widget")
			local again = fake_surface()
			Restarted._set_surface(again)
			Restarted.restore()
			Restarted.tick(stats(42, nil, nil, 20), 20)
			helpers.assert_eq(again.draws[1].x, 640)
			helpers.assert_eq(again.draws[1].y, 360)
			helpers.assert_true(Restarted.reset_position())
			helpers.assert_nil(store.values["wpm_widget.pos_x"])
		end)
	end)

	for _, operation in ipairs({ "drag", "reset" }) do
		helpers.it("keeps the complete WPM position when the second scalar " .. operation .. " publication refuses", function()
			with_storage(compact({ ["wpm_widget.pos_x"] = "120", ["wpm_widget.pos_y"] = "180" }), function(store)
				local Widget = require("ui.wpm.widget")
				local surface = fake_surface()
				Widget._set_surface(surface)
				helpers.assert_true(Widget.start())
				helpers.assert_true(Widget.restore())
				Widget.tick(stats(42, nil, nil, 10), 10)
				local scalar, batch = 0, 0
				local original = store.set_many
				local function refuse_second(key, value)
					scalar = scalar + 1
					if scalar == 2 then return false end
					store.values[key] = value
					return true
				end
				store.set, store.delete = refuse_second, function(key) return refuse_second(key, nil) end
				store.set_many = function(...)
					batch = batch + 1
					return original(...)
				end
				if operation == "drag" then surface.moved(640, 360)
				else helpers.assert_true(Widget.reset_position()) end
				helpers.assert_eq(scalar, 0, "one position cannot cross two independent publications")
				helpers.assert_eq(batch, 1)
				package.loaded["ui.wpm.widget"] = nil
				local Restarted = require("ui.wpm.widget")
				local again = fake_surface()
				Restarted._set_surface(again)
				helpers.assert_true(Restarted.restore())
				Restarted.tick(stats(42, nil, nil, 20), 20)
				if operation == "drag" then
					helpers.assert_eq(again.draws[1].x, 640)
					helpers.assert_eq(again.draws[1].y, 360)
				else
					local x, y = Model.default_anchor(canon(), again.screen_frame())
					helpers.assert_eq(again.draws[1].x, x)
					helpers.assert_eq(again.draws[1].y, y)
				end
			end)
		end)
	end

	for _, refusal in ipairs({ "false", "throw", "missing" }) do
		helpers.it("keeps both saved WPM coordinates after a " .. refusal .. " batch refusal", function()
			with_storage(compact({ ["wpm_widget.pos_x"] = "120", ["wpm_widget.pos_y"] = "180" }), function(store)
				local Widget = require("ui.wpm.widget")
				local surface = fake_surface()
				Widget._set_surface(surface)
				helpers.assert_true(Widget.start())
				helpers.assert_true(Widget.restore())
				Widget.tick(stats(42, nil, nil, 10), 10)
				helpers.assert_eq(surface.draws[1].x, 120, "persisted numeric strings remain supported")
				helpers.assert_eq(surface.draws[1].y, 180)
				if refusal == "missing" then store.set_many = nil
				else store.set_many = function() if refusal == "throw" then error("controlled position refusal") end; return false end end
				surface.moved(640, 360)
				helpers.assert_eq(Widget.reset_position(), false)
				package.loaded["ui.wpm.widget"] = nil
				local Restarted = require("ui.wpm.widget")
				local again = fake_surface()
				Restarted._set_surface(again)
				helpers.assert_true(Restarted.restore())
				Restarted.tick(stats(42, nil, nil, 20), 20)
				helpers.assert_eq(again.draws[1].x, 120)
				helpers.assert_eq(again.draws[1].y, 180)
				helpers.assert_eq(store.get("wpm_widget.pos_x"), "120")
				helpers.assert_eq(store.get("wpm_widget.pos_y"), "180")
			end)
		end)
	end

	helpers.it("draws the graph in graph mode, and keeps that choice", function()
		with_storage(compact(), function()
			local Widget = require("ui.wpm.widget")
			local surface = fake_surface()
			Widget._set_surface(surface)
			Widget.restore()
			Widget.start()
			helpers.assert_true(Widget.set_graph(true))
			Widget.tick(stats(42, nil, nil, 10), 10)
			helpers.assert_eq(surface.draws[1].frame.mode, "graph")
			-- The choice survives a restart, whether stored or now the default.
			package.loaded["ui.wpm.widget"] = nil
			local Restarted = require("ui.wpm.widget")
			local again = fake_surface()
			Restarted._set_surface(again)
			Restarted.restore()
			Restarted.start()
			Restarted.tick(stats(42, nil, nil, 20), 20)
			helpers.assert_eq(again.draws[1].frame.mode, "graph")
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
			Widget.tick(stats(42, nil, nil, 10), 10)
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
		function tray.remove_item(handle) handle.removed = true; return true end
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

	helpers.it("(wpm-tray-hide-refusal) restores a visible frame after a partially refused hide", function()
		with_storage({}, function()
			local Readout, tray = setup()
			assert(Readout.start())
			Readout.tick(stats(10), 10)
			local original = tray.update_item
			tray.update_item = function(handle, options)
				if options.active == false then handle.active = false; tray.update_item = original; return false end
				return original(handle, options)
			end
			Readout.tick(stats(0), 20)
			helpers.assert_nil(Readout.configuration_snapshot(), "an ambiguous hide must not become a stable snapshot")
			helpers.assert_eq(tray.items[1].active, false, "the refused native update may have hidden it")
			Readout.tick(stats(10), 30)
			helpers.assert_eq(tray.items[1].active, true, "the visible frame must be republished")
		end)
	end)

	helpers.it("(wpm-icon-paint-refusal) never repaints the icon still displayed", function()
		with_storage({}, function()
			local Readout, tray = setup()
			local paths, calls = {}, 0
			Readout._set_painter(function(_, path)
				calls = calls + 1
				paths[calls] = path
				return calls ~= 2
			end)
			assert(Readout.start())
			Readout.tick(stats(10), 10)
			local displayed = tray.items[1].icon
			Readout.tick(stats(20), 20)
			Readout.tick(stats(30), 30)
			helpers.assert_true(paths[2] ~= displayed)
			helpers.assert_true(paths[3] ~= displayed, "a refused paint must keep the current icon immutable")
		end)
	end)

	helpers.it("(wpm-icon-paint-refusal) retries an ambiguous tray update before repainting", function()
		with_storage({}, function()
			local Readout, tray, paths = setup()
			assert(Readout.start())
			Readout.tick(stats(10), 10)
			local original_update = tray.update_item
			local calls = 0
			tray.update_item = function(handle, options)
				calls = calls + 1
				if calls == 1 then handle.icon = options.icon; return false end
				return original_update(handle, options)
			end
			Readout.tick(stats(20), 20)
			local possibly_displayed = tray.items[1].icon
			Readout.tick(stats(30), 30)
			helpers.assert_eq(calls, 3, "the ambiguous icon is acknowledged before the next frame")
			helpers.assert_true(paths[3].path ~= possibly_displayed, "the potentially displayed file stays intact")
		end)
	end)

	helpers.it("(wpm-icon-paint-refusal) keeps an unresolved update through stop refusal", function()
		with_storage({}, function(_, preferences)
			local Readout, tray = setup()
			assert(Readout.start())
			Readout.tick(stats(10), 10)
			local original = tray.update_item
			tray.update_item = function() return false end
			Readout.tick(stats(20), 20)
			helpers.assert_nil(Readout.configuration_snapshot(), "an ambiguous icon is not a stable snapshot")
			helpers.assert_eq(Readout.stop(), false)
			helpers.assert_true(Readout.is_running())
			helpers.assert_eq(preferences.get("metrics.wpm_menubar_visible"), true)
			tray.update_item = original
			helpers.assert_true(Readout.stop())
		end)
	end)

	helpers.it("refuses native retirement without losing the live item or preference", function()
		with_storage({}, function(_, preferences)
			local Readout, tray = setup()
			helpers.assert_true(Readout.start())
			Readout.tick(stats(57), 10)
			tray.remove_item = function(handle) handle.active = false; return false end
			helpers.assert_eq(Readout.stop(), false)
			helpers.assert_true(Readout.is_running())
			helpers.assert_eq(preferences.get("metrics.wpm_menubar_visible"), true)
			helpers.assert_true(tray.items[1].active)
		end)
	end)

	helpers.it("recreates the exact retired readout without preference writes", function()
		with_storage({}, function(_, preferences)
			local Readout, tray = setup()
			helpers.assert_true(Readout.start())
			Readout.tick(stats(57), 10)
			local before = Readout.configuration_snapshot()
			local changed = Readout.configuration_snapshot()
			changed.running, changed.presentation = false, nil
			helpers.assert_true(Readout.apply_configuration(changed))
			helpers.assert_true(tray.items[1].removed)
			helpers.assert_true(Readout.apply_configuration(before))
			helpers.assert_eq(#tray.items, 2)
			helpers.assert_true(tray.items[2].active)
			helpers.assert_eq(tray.items[2].title, tray.items[1].title)
			helpers.assert_eq(preferences.get("metrics.wpm_menubar_visible"), true)
		end)
	end)

	helpers.it("appears with the speed while typing, and leaves the panel after", function()
		with_storage({}, function()
			local Readout, tray, painted = setup()
			helpers.assert_true(Readout.start())
			Readout.tick(stats(57), 10)
			helpers.assert_eq(#tray.items, 1)
			helpers.assert_eq(tray.items[1].active, true)
			helpers.assert_eq(tray.items[1].title, "57 " .. require("core.i18n.engine.i18n").get("menu.metrics.wpm_unit"))
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
		with_storage({}, function(_, preferences)
			local Readout, tray = setup()
			Readout.start()
			Readout.tick(stats(57), 10)
			helpers.assert_eq(preferences.get("metrics.wpm_menubar_visible"), true)
			helpers.assert_true(Readout.stop())
			helpers.assert_true(tray.items[1].removed)
			helpers.assert_eq(preferences.get("metrics.wpm_menubar_visible"), nil, "off is the shipped default: nothing stored")
		end)
	end)

end)
