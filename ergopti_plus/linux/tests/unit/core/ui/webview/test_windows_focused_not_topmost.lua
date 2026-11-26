--- tests/unit/core/ui/webview/test_windows_focused_not_topmost.lua

--- ==============================================================================
--- MODULE: Windows Are Focused, Never Kept On Top (Linux)
--- DESCRIPTION:
--- Maintainer rule (2026-09-29): an Ergopti window is shown, raised and focused
--- when it opens or is requested again, and never kept above the windows the
--- user opens afterwards. Drives the real GTK constructor and the real re-open
--- path against a recording Gtk.Window: the window is a TOPLEVEL, present()
--- raises it on open and on re-open, and nothing ever asks the window manager
--- to keep it above (set_keep_above, a floating type hint, stick). On Wayland
--- a re-open maps the window anew before present(): a mapped window's
--- present() without an activation token left a covered page covered on
--- GNOME Shell (tests/hardware/desktop/run_window_toggle.sh).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Window-manager requests that keep a window above others or on every desktop.
local ON_TOP_METHODS = { "set_keep_above", "set_type_hint", "stick", "set_transient_for" }

--- Runs one scenario with the real webview manager over a recording GTK.
--- @param scenario function(manager, windows) Behavioural assertions.
--- @param session string|nil The display server kind; X11 when nil.
local function with_gtk(scenario, session)
	local names = { "lgi", "core.ui.ui.webview_manager", "core.i18n.engine.i18n", "core.events.loop" }
	local DisplayServer = require("core.ui.engine.display_server")
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local ok, failure = xpcall(function()
		local windows = {}
		package.loaded.lgi = {
			Gtk = {
				WindowPosition = { CENTER = 1 }, WindowType = { TOPLEVEL = "TOPLEVEL", POPUP = "POPUP" },
				Window = function(properties)
					local window = { properties = properties, calls = {}, visible = false }
					setmetatable(window, { __index = function(self, key)
						return function(_, ...)
							self.calls[#self.calls + 1] = { name = key, args = { ... } }
							if key == "show_all" then rawset(self, "visible", true) end
							if key == "hide" then rawset(self, "visible", false) end
						end
					end })
					windows[#windows + 1] = window
					return window
				end,
			},
			WebKit2 = {
				UserContentManager = function()
					local manager = { connected = {} }
					manager.register_script_message_handler = function() return true end
					manager.unregister_script_message_handler = function() end
					manager.on_script_message_received = { connect = function(_, callback, detail)
						manager.connected[1] = true; return 1
					end }
					return manager
				end,
				WebView = function()
					local view = { load_html = function() end }
					function view:destroy() if self.on_destroy then self.on_destroy() end end
					return view
				end,
			},
			GObject = {
				signal_handler_disconnect = function(manager, id) manager.connected[id] = false end,
				signal_handler_is_connected = function(manager, id) return manager.connected[id] == true end,
			},
			GLib = {},
		}
		package.loaded["core.events.loop"] = { add_idle_handler = function() end }
		package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
		package.loaded["core.ui.ui.webview_manager"] = nil
		local manager = require("core.ui.ui.webview_manager")
		manager.init()
		DisplayServer._set_for_test(session or DisplayServer.X11, "")
		scenario(manager, windows)
	end, debug.traceback)
	DisplayServer._set_for_test(nil, nil)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
end

--- Counts the recorded calls of one method.
--- @param window table Recording window.
--- @param name string Method name.
--- @return integer
local function count(window, name)
	local total = 0
	for _, call in ipairs(window.calls) do
		if call.name == name then total = total + 1 end
	end
	return total
end

--- Asserts that nothing asked the window manager to keep the window on top.
--- @param window table Recording window.
local function assert_never_on_top(window)
	helpers.assert_eq(window.properties.type, "TOPLEVEL", "an Ergopti window is an ordinary toplevel")
	helpers.assert_nil(window.properties.type_hint, "no floating type hint")
	helpers.assert_nil(window.properties.keep_above, "no keep-above property")
	for _, name in ipairs(ON_TOP_METHODS) do
		helpers.assert_eq(count(window, name), 0, name .. " must never be requested for a window")
	end
end

--- Creates one app window through the real constructor.
--- @param manager table Webview manager.
--- @param app string App id.
local function create(manager, app)
	helpers.assert_true(manager._create_gtk_window(app, "<html></html>", {
		bridge_name = require("core.ui.ui.webkit_host").bridge_for_app(app),
	}))
end

helpers.describe("ui-focus-not-topmost: GTK windows (Linux)", function()

	helpers.it("opens the diagnostics window raised and focused, never kept above (ui-focus-not-topmost)", function()
		with_gtk(function(manager, windows)
			create(manager, "healthcheck")
			local window = windows[1]
			helpers.assert_eq(count(window, "show_all"), 1)
			helpers.assert_eq(count(window, "present"), 1, "an opened window is raised and focused once")
			assert_never_on_top(window)
		end)
	end)

	helpers.it("re-presents an open window without keeping it above (ui-focus-not-topmost)", function()
		with_gtk(function(manager, windows)
			create(manager, "healthcheck")
			manager._focus_gtk_window("healthcheck")
			local window = windows[1]
			helpers.assert_eq(count(window, "present"), 2, "a re-open raises and focuses the window again")
			helpers.assert_eq(count(window, "show_all"), 1, "a visible window is not mapped twice")
			assert_never_on_top(window)
		end)
	end)

	helpers.it("maps a covered Wayland window anew before raising it (ui-focus-not-topmost)", function()
		with_gtk(function(manager, windows)
			create(manager, "healthcheck")
			manager._focus_gtk_window("healthcheck")
			local window = windows[1]
			helpers.assert_eq(count(window, "hide"), 1, "the mapped window is unmapped once")
			helpers.assert_eq(count(window, "show_all"), 2, "then mapped again, so GNOME focuses it")
			helpers.assert_eq(count(window, "present"), 2)
			helpers.assert_eq(window.calls[#window.calls].name, "present", "present() comes after the new map")
			assert_never_on_top(window)
		end, "wayland")
	end)

	helpers.it("shows the error window without taking the keyboard or staying above (ui-focus-not-topmost)",
		function()
			with_gtk(function(manager, windows)
				create(manager, "error_dialog")
				local window = windows[1]
				helpers.assert_eq(window.properties.focus_on_map, false)
				helpers.assert_eq(count(window, "show_all"), 1)
				helpers.assert_eq(count(window, "present"), 0, "the error window leaves the keyboard where it was")
				assert_never_on_top(window)
			end)
		end)

end)
