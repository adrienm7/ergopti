--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_layout_change.lua

--- ==============================================================================
--- MODULE: Choosing A Layout Changes What Keys Mean
--- DESCRIPTION:
--- That the tray's layout submenu changes the physical keyboard family used by
--- metrics while capture and injection refresh from the same active XKB dump.
---
--- THE DEFECT THIS PINS:
--- The daemon's on_layout_change handler used to log "restart daemon to apply"
--- and return. The physical family never reached heatmap/finger-map metrics, and
--- the capture/injection keymap was not refreshed after a live system change.
---
--- WHY AN UNKNOWN NAME MUST BE REFUSED RATHER THAN ACCEPTED:
--- `LAYOUTS[layout] or LAYOUTS["qwerty"]` silently falls back. A name that is
--- stored but unknown therefore reports as applied and resolves every key
--- through the other table — the same failure as before, with the daemon now
--- claiming to have fixed it.
---
--- WHY THE ACTIVE KEYMAP IS CHECKED:
--- Text capture no longer trusts this two-value physical label. keyboard_layout
--- dumps the actual server keymap once, gives it to XKB capture, then builds the
--- inverse injection table from that same text.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Restored afterwards: load_module wipes the named module, not its dependencies,
-- so a recording stub left in place would follow every later test file.
local _saved_reader = package.loaded["modules.hotstrings.input_reader"]

--- Installs an input_reader that records which layout name it is asked for.
--- @return table The layout names seen, in order.
local function install_recording_reader()
	local seen = {}
	package.loaded["modules.hotstrings.input_reader"] = {
		get_layouts = function() return { qwerty = {}, azerty = {} } end,
		resolve_char = function(_code, layout)
			seen[#seen + 1] = layout
			return "x"
		end,
	}
	return seen
end

-- =================================================================
-- =================================================================
-- ======= 1/ The change reaches the resolver ======================
-- =================================================================
-- =================================================================

helpers.describe("keyboard hook: a physical layout-family change", function()

	helpers.it("publishes the chosen family for metrics without resolving text", function()
		install_recording_reader()
		local hook = helpers.load_module("adapters.keyboard_hook")

		helpers.assert_true(hook.set_layout("azerty"),
			"a layout the driver knows must be accepted")
		package.loaded["modules.hotstrings.input_reader"] = _saved_reader
		helpers.assert_eq(hook.get_layout(), "azerty",
			"aggregate and heatmap readers must see the new physical family")
	end)

	helpers.it("refuses a name it cannot honour instead of falling back", function()
		install_recording_reader()
		local hook = helpers.load_module("adapters.keyboard_hook")

		helpers.assert_true(hook.set_layout("qwerty"), "the known name must be accepted first")
		local accepted = hook.set_layout("dvorak-imaginary")
		package.loaded["modules.hotstrings.input_reader"] = _saved_reader

		helpers.assert_true(not accepted,
			"the resolver falls back to qwerty for an unknown name, so storing one "
				.. "would report the change as applied while resolving every key "
				.. "through the other table — the original bug, now with the daemon "
				.. "claiming to have fixed it")
	end)

	helpers.it("rejects a non-string without changing anything", function()
		install_recording_reader()
		local hook = helpers.load_module("adapters.keyboard_hook")
		local accepted = hook.set_layout(nil)
		package.loaded["modules.hotstrings.input_reader"] = _saved_reader
		helpers.assert_true(not accepted,
			"a menu row wired to the wrong argument must not silently blank the "
				.. "layout — that is how the forty-one bridge calls failed")
	end)

end)

--- Uses the actual XKB adapter and its opaque inverse receipts over a stateful
--- software keymap. Reader/Writer keep the controlled native-consumer fixture.
local function with_capture_refresh(body)
	local saved = package.loaded["adapters.xkb_capture"]
	local Capture = helpers.load_module("adapters.xkb_capture")
	Capture._set_backend({
		create = function(map) return { map = map, held = {} } end, destroy = function() end,
		capture_group = function() return 0 end,
		key_sym = function(session, code)
			if code == 50 then return session.map == "ctrl-shift" and 0xffe3 or 0xffe1 end
			if code == 37 then return 0xffe3 end
			if code == 108 then return session.map == "fr" and 0xfe03 or 0xffea end
			return code == 38 and 0x61 or code == 26 and 0x65 or 0
		end,
		key_utf8 = function(session, code)
			if code == 38 then return session.held[50] and "A" or "a" end
			if code == 26 then return session.map == "fr" and session.held[108] and "€" or "e" end
			return ""
		end,
		sym_utf8 = function(_, sym) return sym == 0x61 and "a" or sym == 0x65 and "e" or "" end,
		update_key = function(session, code, direction) session.held[code] = direction == 1 or nil end,
		compose_feed = function() end, compose_status = function() return "nothing" end,
		compose_utf8 = function() end, compose_reset = function() end,
		inverse = function() return { a = { keycode = 30, level = 1, mods = {} }, A = { keycode = 30, level = 2, mods = { "shift" } } } end,
	})
	assert(Capture.load("us", "C"))
	local chars = {}
	local ok, err = pcall(function()
		require("tests.support.input_owner_fixture").with_session({ capture = Capture, position_bits = true,
			on_char = function(char) chars[#chars + 1] = char end,
			on_capture_reacquired = function() return true end }, function(s)
			s.chars = chars
			body(s, Capture)
		end)
	end)
	Capture._reset_backend(); package.loaded["adapters.xkb_capture"] = saved
	if not ok then error(err, 0) end
end

helpers.describe("layout refresh preserves native output custody", function()
	local function change(s, capture, map, check)
		return s.hook.refresh_capture("azerty", function()
			assert(s.hook.set_layout("azerty")); return capture.load(map, "C")
		end, check or function() return true end)
	end

	helpers.it("(linux-live-layout-refresh) preserves held Shift without emitting or retiring a physical key", function()
		with_capture_refresh(function(s, capture)
			s.edge("a", 42, 1, 1); s.edge("a", 30, 1, 2); s.edge("a", 30, 0, 3)
			local rows = #s.rows
			helpers.assert_true(change(s, capture, "us"))
			helpers.assert_eq(#s.rows, rows, "a keymap refresh has no output transitions")
			s.edge("a", 30, 1, 4); s.edge("a", 30, 0, 5); s.edge("a", 42, 0, 6)
			helpers.assert_eq(s.chars, { "A", "A" })
			helpers.assert_eq(s.hook.held_modifiers().shift, nil)
		end)
	end)

	helpers.it("(linux-live-layout-refresh) reclassifies a retained Right Alt from shortcut Alt to text AltGr", function()
		with_capture_refresh(function(s, capture)
			s.edge("a", 100, 1, 1)
			helpers.assert_true(s.hook.held_modifiers().alt)
			helpers.assert_true(change(s, capture, "fr"))
			helpers.assert_eq(s.hook.held_modifiers().alt, nil)
			helpers.assert_true(s.hook.held_modifiers().altgr)
			s.edge("a", 18, 1, 2); s.edge("a", 18, 0, 3); s.edge("a", 100, 0, 4)
			helpers.assert_eq(s.chars, { "€" })
		end)
	end)

	helpers.it("(linux-live-layout-refresh) preserves a remapper-owned hold and its output owner", function()
		with_capture_refresh(function(s, capture)
			s.edge("a", 58, 1, 1); s.pump_at(400)
			local held, rows = s.base.held[58], #s.rows
			helpers.assert_true(held ~= nil and s.hook.held_modifiers().ctrl)
			helpers.assert_true(change(s, capture, "us"))
			helpers.assert_eq(s.base.held[58], held)
			helpers.assert_eq(#s.rows, rows)
			helpers.assert_true(s.hook.held_modifiers().ctrl)
			s.edge("a", 58, 0, 401)
			helpers.assert_eq(s.hook.held_modifiers().ctrl, nil)
		end)
	end)

	helpers.it("(linux-live-layout-refresh) clears an unused logical arm before publishing the fresh inverse", function()
		with_capture_refresh(function(s, capture)
			s.pair(); helpers.assert_true(s.armed)
			s.edge("a", 58, 0, 150)
			helpers.assert_true(change(s, capture, "fr"))
			helpers.assert_eq(s.base.one_shot_shift, nil)
			s.edge("a", 30, 1, 200); s.edge("a", 30, 0, 201)
			helpers.assert_eq(s.chars, { "a" })
		end)
	end)

	helpers.it("(linux-live-layout-refresh) retires a spent logical arm before allowing a map callback", function()
		with_capture_refresh(function(s)
			s.pair(); helpers.assert_true(s.armed)
			s.edge("a", 58, 0, 150); s.edge("a", 30, 1, 200)
			local called = false
			helpers.assert_eq(s.hook.refresh_capture("azerty", function() called = true; return true end,
				function() return true end), false)
			helpers.assert_eq(called, false, "a consumed arm must acknowledge retirement before any map change")
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_true(s.broker.output_retired())
		end)
	end)

	helpers.it("(linux-live-layout-refresh) preserves the old cohort on refusal before any map change", function()
		with_capture_refresh(function(s)
			local old = s.reader.capture_source_owner("keyboard:" .. s.paths.a)
			helpers.assert_eq(s.hook.refresh_capture("azerty", function() return false end, function() return true end), false)
			helpers.assert_true(s.hook.isRunning() and s.reader.source_owner_current(old))
			helpers.assert_eq(s.hook.get_layout(), "qwerty")
		end)
	end)

	for _, mode in ipairs({ "throw", "selected-map-change", "stop" }) do
		helpers.it("(linux-live-layout-refresh) closes original admission after a fresh-map " .. mode, function()
			with_capture_refresh(function(s, capture)
				local selected = true
				local applied = s.hook.refresh_capture("azerty", function()
					assert(s.hook.set_layout("azerty")); assert(capture.load("fr", "C"))
					if mode == "throw" then error("controlled keymap failure") end
					if mode == "stop" then s.hook.stop() end
					selected = mode ~= "selected-map-change"
					return true
				end, function() return selected end)
				helpers.assert_eq(applied, false)
				helpers.assert_eq(s.hook.isRunning(), false)
				for _, path in pairs(s.paths) do helpers.assert_eq(s.reader.is_open("keyboard:" .. path), false) end
			end)
		end)
	end

	helpers.it("(linux-live-layout-refresh) refuses a foreign output owner introduced during the refresh", function()
		with_capture_refresh(function(s, capture)
			local foreign = {}
			helpers.assert_eq(s.hook.refresh_capture("azerty", function()
				assert(s.hook.set_layout("azerty")); assert(capture.load("fr", "C"))
				assert(s.broker.edge(foreign, 42, 1).ok)
				return true
			end, function() return true end), false)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_true(s.broker.output_retired())
		end)
	end)

	helpers.it("(linux-live-layout-refresh) rejects nested start and layout refresh while the selected map is being loaded", function()
		with_capture_refresh(function(s, capture)
			helpers.assert_true(s.hook.refresh_capture("azerty", function()
				helpers.assert_eq(s.hook.refresh_capture("qwerty", function() error("nested layout ran") end, function() return true end), false)
				helpers.assert_eq(s.hook.start(s.start_options), false)
				assert(s.hook.set_layout("azerty")); return capture.load("fr", "C")
			end, function() return true end))
			helpers.assert_true(s.hook.isRunning())
		end)
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 2/ Both directions move together ========================
-- =================================================================
-- =================================================================

helpers.describe("keyboard hook: the daemon refreshes the active XKB keymap", function()

	helpers.it("calls the reading side and the writing side from one handler", function()
		-- A source assertion, because the handler lives in the daemon entry point
		-- and loading that starts a device hook. The behaviour above carries the
		-- weight; this pins that the handler is wired to it at all, which is what
		-- was missing — it logged and returned.
		local handle = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = handle:read("*a")
		handle:close()

		local handler = source:match("on_layout_change = function.-\n\t\t\t\tend,")
		helpers.assert_not_nil(handler,
			"the handler must be findable, or this check passes against any file")
		helpers.assert_true(handler:find("set_layout", 1, true) ~= nil,
			"the physical family must still reach heatmap and aggregate metrics")
		helpers.assert_true(handler:find("keyboard_layout.refresh", 1, true) ~= nil,
			"the active server dump must refresh both capture and injection")

		local layout_handle = assert(io.open(
			helpers.driver_root() .. "/adapters/keyboard_layout.lua", "r"))
		local layout_source = layout_handle:read("*a")
		layout_handle:close()
		helpers.assert_true(layout_source:find("XkbCapture.load(text)", 1, true) ~= nil,
			"refresh must load capture from the exact text used to build injection")
	end)

end)
