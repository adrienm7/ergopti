--- tests/unit/modules/test_action_catalogue_parity.lua
---
--- ==============================================================================
--- MODULE: Linux Action Catalogue Parity (action-catalogue-parity)
--- DESCRIPTION:
--- The Linux picker lists exactly what this driver can run, grouped under
--- localized headings, the tray no longer inlines the whole catalogue under
--- every slot, and a binding naming an id the catalogue does not offer is
--- refused.
---
--- ROOT CAUSES ENCODED:
--- 1. The picker listed a hard-coded table of 42 ids, alphabetically, without a
---    heading and without the platform filter. It hid 38 actions the driver
---    runs (tab_new, open_*, screenshots, script_*, …) and offered bindings that
---    did nothing (select_line and tab fell through to "Unknown action" at
---    DEBUG). The old gate passed anyway: it counted an id as handled whenever
---    it appeared as a quoted literal anywhere in the tree, and "select_line"
---    and "tab" do. This compares the generated catalogue with the executor's
---    own tables, both ways, and drives every listed action through the real
---    dispatcher.
--- 2. The tray inlined about 640 rows under each gesture and keyboard slot.
--- 3. set_action warned about an unknown id and stored it anyway.
--- ==============================================================================

local helpers = require("tests.helpers")

local MANAGER = "modules.gestures.manager"

--- Loads a fresh manager whose logger records every warning and error.
--- @return table manager, table warnings
local function recording_manager()
	local warnings = {}
	local logger = helpers.make_logger_stub()
	logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
	logger.error = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
	local saved = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = logger
	package.loaded[MANAGER] = nil
	-- The workspace provider captures its shell and display dependencies when
	-- required. Earlier native fixtures may have replaced either table.
	package.loaded["modules.gestures.workspace_switcher"] = nil
	local ok, manager = pcall(require, MANAGER)
	package.loaded["logger.shim"] = saved
	if not ok then error(manager, 0) end
	return manager, warnings
end

--- The handlers the daemon injects, built by the same composer it calls: the
--- script-control actions, the shortcuts manager's text actions and the
--- prediction engine's manual trigger.
--- @return table
local function daemon_handlers()
	local ScriptActions = helpers.load_module("modules.shortcuts.script_actions")
	local ActionHandlers = helpers.load_module("modules.shortcuts.action_handlers")
	local Shortcuts = helpers.load_module("modules.shortcuts.manager")
	local Prediction = helpers.load_module("modules.llm.prediction_engine")
	local noop = function() end
	return ActionHandlers.compose(
		ScriptActions.new({ reset = noop, reload = noop, quit = noop }).handlers, Shortcuts, Prediction)
end

--- Runs `body` with every tool probe answering "absent", without a shell.
--- The compositor sockets are hidden too: the workspace requirement reads
--- them, so a developer running the suite from sway or Hyprland would see
--- that compositor instead of the session the test scripts.
--- @param body function
local function without_tools(body)
	local Shell = require("adapters.shell_runner")
	local real_getenv = os.getenv
	os.getenv = function(name)
		if name == "HYPRLAND_INSTANCE_SIGNATURE" or name == "SWAYSOCK" then return nil end
		return real_getenv(name)
	end
	Shell._set_runner(function() return false end)
	local ok, err = pcall(body)
	Shell._reset_runner()
	os.getenv = real_getenv
	if not ok then error(err, 0) end
end

--- Runs `body` with os.execute and io.popen recorded instead of run.
--- @param body function
local function with_recorded_shell(body)
	local real_execute, real_popen = os.execute, io.popen
	os.execute = function() return true end
	io.popen = function() return nil end
	local saved_webview = package.loaded["ui.webview_manager"]
	package.loaded["ui.webview_manager"] = { show = function() return true end }
	local ok, err = pcall(body)
	os.execute, io.popen = real_execute, real_popen
	package.loaded["ui.webview_manager"] = saved_webview
	if not ok then error(err, 0) end
end





-- =====================================================
-- =====================================================
-- ======= 1/ Catalogue <-> executor, both ways ========
-- =====================================================
-- =====================================================

helpers.describe("action catalogue parity (Linux)", function()

	helpers.it("declares tap actions before the daemon registers their handlers", function()
		-- TapHold.init reads this catalogue before the daemon calls Gestures.init.
		-- Handler registration must not make valid persisted taps look unsupported.
		local M = recording_manager()
		local available = {}
		for _, id in ipairs(M.get_executable_action_names()) do available[id] = true end
		for _, id in ipairs({ "script_pause_toggle", "selection_lowercase", "open_today_log" }) do
			helpers.assert_true(M.is_assignable(id), id .. " must be a declared fixture action")
			helpers.assert_true(available[id] == true, id .. " must be known during tap-hold startup")
		end
		helpers.assert_nil(available.none, "the no-op is not an executable tap action")
	end)

	helpers.it("lists every action it can run, and runs every action it lists (action-catalogue-parity)", function()
		local M = recording_manager()
		M.init({ enabled = false, persist = false, action_handlers = daemon_handlers() })
		local listed = M.get_action_names()
		helpers.assert_true(#listed >= 600,
			"the picker lists only " .. #listed .. " action(s) — the catalogue walk collapsed")
		local listed_set, dead = {}, {}
		for _, id in ipairs(listed) do
			listed_set[id] = true
			if not M.is_runnable(id) then dead[#dead + 1] = id end
		end
		local hidden = {}
		for _, id in ipairs(M.runnable_action_ids()) do
			if not listed_set[id] then hidden[#hidden + 1] = id end
		end
		helpers.assert_eq(#dead, 0, "listed but not runnable on Linux: " .. table.concat(dead, ", "))
		helpers.assert_eq(#hidden, 0, "runnable on Linux but never listed: " .. table.concat(hidden, ", "))
		for _, id in ipairs({ "tab", "select_line", "tab_new", "open_config", "screenshot_region_save",
			"script_quit", "desktop_prev", "app_window_previous" }) do
			helpers.assert_true(listed_set[id] == true, id .. " must be offered on Linux")
		end
	end)

	helpers.it("drives every listed action through the real dispatcher without an unknown one", function()
		local M, warnings = recording_manager()
		M.init({ enabled = false, persist = false, action_handlers = daemon_handlers() })
		local driven = 0
		with_recorded_shell(function()
			for _, id in ipairs(M.get_action_names()) do
				M.execute_action(id, "parity__slot")
				driven = driven + 1
			end
		end)
		helpers.assert_true(driven >= 600, "only " .. driven .. " action(s) driven — the catalogue walk collapsed")
		local unknown = {}
		for _, message in ipairs(warnings) do
			if message:find("Unknown action", 1, true) then unknown[#unknown + 1] = message end
		end
		helpers.assert_eq(#unknown, 0, "the dispatcher does not know: " .. table.concat(unknown, " | "))
	end)

end)





-- ===============================================================
-- ===============================================================
-- ======= 2/ The picker follows the catalogue's structure =======
-- ===============================================================
-- ===============================================================

helpers.describe("action picker items (Linux)", function()

	helpers.it("sends real, localized headings in catalogue order", function()
		-- infra.locale re-creates the shared locale core when it loads, so an
		-- i18n captured by an earlier test may read another core instance.
		-- Reload the chain, and the manager on top of it, so this test switches
		-- the very core the headings are read from.
		local saved = {}
		for _, name in ipairs({ "infra.i18n", "infra.locale", "locale.core", MANAGER }) do
			saved[name] = package.loaded[name]
		end
		package.loaded["infra.i18n"] = nil
		package.loaded["infra.locale"] = nil
		local i18n = require("infra.i18n")
		local Locale = require("locale.core")
		recording_manager()
		local ok, err = pcall(function()
			for _, code in ipairs({ "de", "en" }) do
				Locale.set_locale(code)
				local Bridge = helpers.load_module("ui.action_picker.bridge")
				local items
				without_tools(function() items = Bridge.build_init_payload({}).items end)
				local headings, actions = 0, {}
				local ctrl_title = (i18n.get("sg_actions.sg_order.header.modifier_chord_group")
					:gsub("{1}", "Ctrl"))
				local found_ctrl = false
				for _, item in ipairs(items) do
					if item.type == "heading" then
						headings = headings + 1
						helpers.assert_true(not item.text:find("Raccourcis", 1, true),
							code .. ": a heading is still French: " .. item.text)
						helpers.assert_true(not item.text:find("sg_actions.", 1, true),
							code .. ": a heading shows its raw key: " .. item.text)
						helpers.assert_true(item.level == 1 or item.level == 2, "heading level 1 or 2")
						found_ctrl = found_ctrl or (item.level == 2 and item.text == ctrl_title)
					else
						actions[#actions + 1] = item.id
					end
				end
				helpers.assert_true(headings >= 15, code .. ": only " .. headings .. " heading(s) reached the page")
				helpers.assert_true(found_ctrl, code .. ": the Ctrl chord group must read " .. ctrl_title)
				local expected = {}
				for _, id in ipairs(require(MANAGER).get_action_names()) do
					if id ~= "none" then expected[#expected + 1] = id end
				end
				helpers.assert_eq(table.concat(actions, ","), table.concat(expected, ","),
					code .. ": the page must list the catalogue's actions in the catalogue's order")
			end
		end)
		for name, module in pairs(saved) do package.loaded[name] = module end
		if not ok then error(err, 0) end
	end)

	helpers.it("greys an action whose requirement is proven absent, with the reason", function()
		local Display = require("infra.display_server")
		local M = recording_manager()
		Display._set_for_test(Display.WAYLAND, "gnome")
		local ok, items
		without_tools(function() ok, items = pcall(M.get_picker_items) end)
		Display._set_for_test(nil, nil)
		helpers.assert_true(ok, tostring(items))
		local by_id = {}
		for _, item in ipairs(items) do if item.type == "action" then by_id[item.id] = item end end
		helpers.assert_eq(by_id.left_click_toggle.disabled, true,
			"xdotool cannot hold a button under Wayland, so the row is greyed")
		helpers.assert_eq(by_id.left_click_toggle.hint,
			require("infra.i18n").get("dialog.action_picker.requires_x11"))
		helpers.assert_eq(by_id.open_url.disabled, true, "no xdg-open on PATH, nothing to open a URL with")
		helpers.assert_eq(by_id.open_url.hint,
			(require("infra.i18n").get("dialog.action_picker.requires_tool"):gsub("{1}", "xdg-open")))
		helpers.assert_eq(by_id.enter.disabled, nil, "an action with no requirement stays enabled")
		-- GNOME under Wayland lets no process read its workspaces: the plain
		-- step presses its own shortcut, which stops at the edges, but nothing
		-- can tell where the edge is to wrap past it.
		helpers.assert_eq(by_id.desktop_next.disabled, nil, "the plain step works on every desktop")
		helpers.assert_eq(by_id.desktop_next_wrap.disabled, true, "GNOME cannot wrap its workspaces")
		helpers.assert_eq(by_id.desktop_next_wrap.hint,
			require("infra.i18n").get("dialog.action_picker.requires_workspaces"))
		helpers.assert_eq(by_id.desktop_prev_wrap.disabled, true)
	end)

	helpers.it("names the missing tool when a desktop could wrap without it", function()
		local Display = require("infra.display_server")
		local M = recording_manager()
		Display._set_for_test(Display.X11, "xfce")
		local ok, items
		without_tools(function() ok, items = pcall(M.get_picker_items) end)
		Display._set_for_test(nil, nil)
		helpers.assert_true(ok, tostring(items))
		local by_id = {}
		for _, item in ipairs(items) do if item.type == "action" then by_id[item.id] = item end end
		helpers.assert_eq(by_id.desktop_prev_wrap.disabled, true, "X11 without wmctrl cannot list its desktops")
		helpers.assert_eq(by_id.desktop_prev_wrap.hint,
			(require("infra.i18n").get("dialog.action_picker.requires_tool"):gsub("{1}", "wmctrl")))
	end)

	helpers.it("does not borrow tool availability from an earlier workspace fixture", function()
		local name = "modules.gestures.workspace_switcher"
		local saved = package.loaded[name]
		local Display = require("infra.display_server")
		Display._set_for_test(Display.X11, "xfce")
		local ok, err = pcall(function()
			local stale = helpers.load_module_with_dependency(name, "adapters.shell_runner", {
				has_command = function() return true end,
			})
			helpers.assert_eq(stale.detect().name, "wmctrl", "the earlier fixture captured a different tool provider")
			local M = recording_manager()
			without_tools(function()
				local by_id = {}
				for _, item in ipairs(M.get_picker_items()) do
					if item.type == "action" then by_id[item.id] = item end
				end
				helpers.assert_eq(by_id.desktop_prev_wrap.disabled, true,
					"this fixture must inspect its own absent wmctrl provider")
				helpers.assert_eq(by_id.desktop_prev_wrap.hint,
					(require("infra.i18n").get("dialog.action_picker.requires_tool"):gsub("{1}", "wmctrl")))
			end)
		end)
		package.loaded[name] = saved
		Display._set_for_test(nil, nil)
		if not ok then error(err, 0) end
	end)

end)





-- ==============================================
-- ==============================================
-- ======= 3/ The tray does not inline it =======
-- ==============================================
-- ==============================================

helpers.describe("gesture slots in the tray (Linux)", function()

	helpers.it("offers the picker under each slot instead of the whole catalogue", function()
		local M = recording_manager()
		M.init({ enabled = false, persist = false })
		M._test_begin_reading({})
		helpers.assert_true(M.enable(), "the test reader must permit enabling gestures")
		local menu_builder = helpers.load_module("ui.menu.menu_builder")
		local items = menu_builder.build({ _version = "3.0.0", gestures = M })
		M.disable()
		M.stop_reading()

		local slot_rows = 0
		local function walk(rows)
			for _, row in ipairs(rows or {}) do
				if type(row) == "table" then
					if type(row.title) == "string" and row.title:find(" → ", 1, true)
						and type(row.menu) == "table" then
						slot_rows = slot_rows + 1
						helpers.assert_true(#row.menu <= 2,
							row.title .. " inlines " .. #row.menu .. " row(s); the picker is the list")
					end
					walk(row.menu)
				end
			end
		end
		walk(items)
		helpers.assert_true(slot_rows >= 30, "only " .. slot_rows .. " slot row(s) found — the walk missed the gestures submenu")
	end)

end)





-- ==========================================
-- ==========================================
-- ======= 4/ Unknown ids are refused =======
-- ==========================================
-- ==========================================

helpers.describe("gesture assignment validation (Linux)", function()

	helpers.it("refuses an id the catalogue does not offer and keeps the binding", function()
		local M = recording_manager()
		M.init({ enabled = false, persist = false })
		helpers.assert_true(M.set_action("tap_3", "enter"), "a catalogue id is accepted")
		helpers.assert_eq(M.set_action("tap_3", "no_such_action"), false,
			"an unknown id must be refused, as Windows refuses it")
		helpers.assert_eq(M.set_action("tap_3", "mission_control"), false,
			"a macOS-only id is not assignable on Linux")
		helpers.assert_eq(M.get_action("tap_3"), "enter", "a refused id must not replace the binding")
		helpers.assert_true(M.set_action("tap_3", "ctrl_shift_a"), "a modifier chord is assignable")
		helpers.assert_true(M.set_action("tap_3", "none"), "none clears a binding")
	end)

	helpers.it("ignores an unknown id found in config.toml, loudly", function()
		-- set_action refuses such an id, so config.toml can only carry one from a
		-- hand edit or another OS. The loader used to bind it anyway, and the
		-- gesture then dispatched a no-op every time it fired.
		local path = os.tmpname()
		local fh = assert(io.open(path, "w"))
		fh:write('[gestures]\ntap_3 = "no_such_action"\ntap_4 = "enter"\n')
		fh:close()
		local M, warnings = recording_manager()
		local ok, err = pcall(function()
			M.init({ enabled = false, persist = true, config_path = path })
			helpers.assert_eq(M.get_action("tap_4"), "enter", "a catalogue id still loads")
			helpers.assert_eq(M.get_action("tap_3"), "none", "an unknown id must not be bound")
		end)
		os.remove(path)
		if not ok then error(err, 0) end
		local named = false
		for _, message in ipairs(warnings) do
			named = named or message:find("no_such_action", 1, true) ~= nil
		end
		helpers.assert_true(named, "the ignored id must be named in a warning")
	end)

end)
