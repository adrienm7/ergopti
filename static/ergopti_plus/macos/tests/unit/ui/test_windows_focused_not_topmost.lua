--- tests/unit/ui/test_windows_focused_not_topmost.lua

--- ==============================================================================
--- MODULE: Windows Are Focused, Never Kept On Top
--- DESCRIPTION:
--- The diagnostics window sat at the floating level: every window the user
--- opened afterwards stayed underneath it, and the focus fallback went further
--- with bringToFront(true), the screen-saver level. The maintainer rule is that
--- an Ergopti window is shown, raised and focused when it opens or is requested
--- again, and never given a level. These tests drive the real factory, the real
--- focus helper and the real diagnostics window against recording natives whose
--- levels are distinct numbers, so a floating window cannot pass as normal.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Distinct values: a stub that answers 0 for every level would hide the bug.
local LEVELS = { normal = 0, floating = 3, modalPanel = 8, screenSaver = 1000 }

--- Builds a native webview double that records every presentation call.
--- @param with_window boolean When false, hswindow() never materializes.
--- @return table view, table calls
local function recording_view(with_window)
	local calls = { levels = {}, fronts = 0, shows = 0, raises = 0, focuses = 0 }
	local window = {}
	function window:moveToScreen() return self end
	function window:unminimize() return self end
	function window:raise() calls.raises = calls.raises + 1; return self end
	function window:focus() calls.focuses = calls.focuses + 1; return self end
	local view = {}
	for _, name in ipairs({
		"windowTitle", "windowStyle", "shadow", "allowTextEntry", "allowGestures",
		"allowNewWindows", "html", "windowCallback", "navigationCallback", "evaluateJavaScript",
	}) do
		view[name] = function(self) return self end
	end
	function view:level(value)
		calls.levels[#calls.levels + 1] = value
		return self
	end
	function view:bringToFront()
		calls.fronts = calls.fronts + 1
		return self
	end
	function view:show()
		calls.shows = calls.shows + 1
		return self
	end
	function view:hswindow() return with_window and window or nil end
	function view:delete() return self end
	return view, calls
end

--- Loads the real ui_builder against a webview factory returning `view`.
--- @param view table Native double.
--- @param app table Records Hammerspoon activations.
--- @return table Builder
local function load_builder(view, app)
	return helpers.load_with_stubs("ui.ui_builder", {
		webview = {
			windowMasks = { titled = 1, closable = 2, utility = 16 },
			new = function() return view end,
		},
		drawing = { windowLevels = LEVELS },
		focus = function() app.activations = app.activations + 1 end,
		screen = { mainScreen = function() return {} end },
	})
end

--- Asserts that a window only ever received the normal level.
--- @param calls table Recorded calls.
--- @param context string Failure context.
local function assert_never_on_top(calls, context)
	for _, level in ipairs(calls.levels) do
		helpers.assert_eq(level, LEVELS.normal, context .. ": the window level must stay normal")
	end
	helpers.assert_eq(calls.fronts, 0,
		context .. ": bringToFront sets a floating or screen-saver level and must never run")
end





-- =============================================
-- =============================================
-- ======= 1/ The factory and the helper =======
-- =============================================
-- =============================================

helpers.describe("ui-focus-not-topmost: shared factory and focus helper (macOS)", function()

	helpers.it("opens a window at the normal level, raised and focused (ui-focus-not-topmost)", function()
		local view, calls = recording_view(true)
		local app = { activations = 0 }
		local Builder = load_builder(view, app)
		helpers.assert_true(Builder.show_webview({ frame = {}, html_string = "<html></html>" }) == view)
		helpers.assert_eq(#calls.levels, 1, "the chrome applies exactly one level")
		assert_never_on_top(calls, "open")
		helpers.assert_eq(calls.raises, 1)
		helpers.assert_eq(calls.focuses, 1)
		helpers.assert_eq(app.activations, 1)
	end)

	helpers.it("re-presents an open window without touching its level (ui-focus-not-topmost)", function()
		local view, calls = recording_view(true)
		local app = { activations = 0 }
		local Builder = load_builder(view, app)
		helpers.assert_true(Builder.show_webview({ frame = {}, html_string = "<html></html>" }) == view)
		helpers.assert_eq(Builder.force_focus(view, true), true)
		helpers.assert_eq(#calls.levels, 1, "presenting again must not set a level")
		assert_never_on_top(calls, "re-open")
		helpers.assert_eq(calls.raises, 2)
		helpers.assert_eq(calls.focuses, 2)
	end)

	helpers.it("falls back to show and activation, never a level (ui-focus-not-topmost)", function()
		local view, calls = recording_view(false)
		local app = { activations = 0 }
		local Builder = load_builder(view, app)
		local pending = {}
		local lifecycle = {
			is_current = function() return true end,
			schedule_after = function(_, callback)
				pending[#pending + 1] = callback
				return true
			end,
		}
		helpers.assert_eq(Builder.force_focus(view, true, lifecycle), true)
		local steps = 0
		while #pending > 0 and steps < 50 do
			steps = steps + 1
			table.remove(pending, 1)()
		end
		helpers.assert_eq(#pending, 0, "the retry must end in the fallback")
		helpers.assert_eq(calls.shows, 1, "the fallback orders the window front with show()")
		helpers.assert_eq(app.activations, 1, "the fallback activates Hammerspoon once")
		helpers.assert_eq(#calls.levels, 0)
		assert_never_on_top(calls, "fallback")
	end)

	helpers.it("refuses a floating window before creating it (ui-focus-not-topmost)", function()
		local view, calls = recording_view(true)
		local created = 0
		local Builder = helpers.load_with_stubs("ui.ui_builder", {
			webview = {
				windowMasks = {},
				new = function() created = created + 1; return view end,
			},
			drawing = { windowLevels = LEVELS },
			focus = function() end,
		})
		helpers.assert_nil(Builder.show_webview({ frame = {}, html_string = "", level = LEVELS.floating }))
		helpers.assert_eq(created, 0, "a refused window must never exist natively")
		helpers.assert_eq(#calls.levels, 0)
		helpers.assert_true(Builder.show_webview({ frame = {}, html_string = "" }) == view,
			"the refusal leaves the factory usable")
	end)

	-- The one exception: the permission dialog is shown while ErgoptiPlus is
	-- not trusted for Accessibility, where focus cannot find a window, and its
	-- steps are followed in System Settings, which would bury a normal window.
	helpers.it("floats only the permission dialog, never focused (ui-focus-not-topmost)", function()
		local view, calls = recording_view(false)
		local app = { activations = 0 }
		local Builder = load_builder(view, app)
		helpers.assert_true(Builder.show_webview({ frame = {}, html_string = "", focus = false,
			chrome = Builder.PERMISSION_DIALOG_CHROME }) == view)
		helpers.assert_eq(calls.levels, { LEVELS.floating }, "the permission chrome floats, once")
		helpers.assert_eq(app.activations, 0, "the dialog never activates the app")
		helpers.assert_eq(calls.raises + calls.focuses + calls.fronts, 0, "the dialog is never focused")
	end)

	helpers.it("refuses the floating chrome on a focused window or under another name (ui-focus-not-topmost)",
		function()
			local view, calls = recording_view(true)
			local created = 0
			local Builder = helpers.load_with_stubs("ui.ui_builder", {
				webview = {
					windowMasks = {},
					new = function() created = created + 1; return view end,
				},
				drawing = { windowLevels = LEVELS },
				focus = function() end,
			})
			helpers.assert_nil(Builder.show_webview({ frame = {}, html_string = "",
				chrome = Builder.PERMISSION_DIALOG_CHROME }), "a focused window may not float")
			helpers.assert_nil(Builder.show_webview({ frame = {}, html_string = "", focus = false,
				chrome = "diagnostics" }), "no other window may name a chrome")
			helpers.assert_eq(created, 0, "a refused window must never exist natively")
			helpers.assert_eq(#calls.levels, 0)
			helpers.assert_true(not pcall(Builder.window_chrome_steps, view, { chrome = "diagnostics" }),
				"the chrome steps refuse an unknown chrome")
		end)

end)





-- ================================================
-- ================================================
-- ======= 2/ The diagnostics window itself =======
-- ================================================
-- ================================================

--- Loads the real diagnostics window over the real focus helper and chrome.
--- @param view table Native double.
--- @return table healthcheck, table context
local function load_healthcheck(view)
	for _, name in ipairs({
		"ui.healthcheck.core", "ui.healthcheck.helpers", "healthcheck.snapshot",
		"infra.logger", "infra.paths", "infra.i18n", "ui.ui_builder",
	}) do package.loaded[name] = nil end
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	hs_stub.drawing.windowLevels = LEVELS
	hs_stub.webview.new = function() return view end
	hs_stub.webview.windowMasks = { titled = 1, closable = 2, miniaturizable = 4, resizable = 8 }
	hs_stub.screen.mainScreen = function()
		return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
	end
	hs_stub.json.encode = function() return "{}" end

	local context = {}
	view.windowCallback = function(self, callback)
		context.window_callback = callback
		return self
	end
	package.loaded["adapters.timer_scheduler"] = { cancel = function() return true end }
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["ui.healthcheck.helpers"] = {}
	package.loaded["healthcheck.snapshot"] = {}
	package.loaded["infra.paths"] = { shared = function() return "/shared" end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	local real = require("ui.ui_builder")
	package.loaded["ui.ui_builder"] = setmetatable({
		build_injected_html = function() return "<html></html>" end,
		get_app_geometry = function() return { width = 860, height = 720 } end,
	}, { __index = real })
	local healthcheck = require("ui.healthcheck.core")
	healthcheck.run = function() return {} end
	return healthcheck, context
end

helpers.describe("ui-focus-not-topmost: diagnostics window (macOS)", function()

	helpers.it("opens and re-opens at the normal level, never brought above other apps (ui-focus-not-topmost)",
		function()
			local saved = {}
			for key, value in pairs(package.loaded) do saved[key] = value end
			local prior_hs = _G.hs
			local ok, err = xpcall(function()
				local view, calls = recording_view(true)
				local healthcheck, context = load_healthcheck(view)
				helpers.assert_true(healthcheck.show_window())
				helpers.assert_eq(#calls.levels, 1)
				assert_never_on_top(calls, "diagnostics open")
				helpers.assert_true(calls.focuses >= 1, "the diagnostics window takes focus when it opens")
				helpers.assert_true(healthcheck.show_window())
				assert_never_on_top(calls, "diagnostics re-open")
				helpers.assert_eq(calls.focuses, 2, "a re-open focuses the window again")
				context.window_callback("closing")
			end, debug.traceback)
			for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
			for key, value in pairs(saved) do package.loaded[key] = value end
			_G.hs = prior_hs
			if not ok then error(err, 0) end
		end)

end)






-- ================================================
-- ================================================
-- ======= 3/ The error window is presented =======
-- ================================================
-- ================================================

--- Loads the real error window over the real focus helper and chrome.
--- @param view table Native double.
--- @param app table Records Hammerspoon activations.
--- @return table dialog, table timers
local function load_error_dialog(view, app)
	for _, name in ipairs({
		"ui.error_dialog", "ui.healthcheck.core", "ui.healthcheck.report", "infra.logger", "infra.i18n",
		"infra.locale", "ui.ui_builder", "adapters.timer_scheduler", "adapters.storage", "infra.manifest_reader",
	}) do package.loaded[name] = nil end
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	hs_stub.drawing.windowLevels = LEVELS
	hs_stub.focus = function() app.activations = app.activations + 1 end
	hs_stub.webview.new = function() return view end
	hs_stub.webview.windowMasks = { titled = 1, closable = 2, miniaturizable = 4, resizable = 8 }
	hs_stub.webview.usercontent.new = function()
		return { setCallback = function(self) return self end }
	end
	hs_stub.screen.mainScreen = function()
		return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
	end

	local timers = {}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.i18n"] = { get = function(key) return key end, get_locale = function() return "en" end }
	package.loaded["infra.locale"] = { all = function() return {} end }
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_, fn) timers[#timers + 1] = fn; return { timer = {} }, true end,
		now_ns = function() return 0 end,
		cancel = function() return true end,
	}
	package.loaded["adapters.storage"] = {
		get = function(_, default) return default end,
		set = function() return true end,
	}
	package.loaded["infra.manifest_reader"] = {
		default_for = function(path) return path == "script.show_error_dialog" and true or nil end,
	}
	package.loaded["ui.healthcheck.core"] = {
		DRIVER = "macos",
		config = function()
			return {
				redaction = { home_placeholder = "~", account_placeholder = "<user>", secret_placeholder = "<secret>",
					min_account_name_length = 3, token_prefixes = {}, bearer_min_length = 8, secret_keys = {},
					secret_value_min_length = 6 },
				templates = {}, repository = {},
			}
		end,
		run = function()
			return {
				generated_at = "2026-09-29T08:00:00Z",
				sections = { paths = { errors_today = "/Users/jdoe/Library/Logs/ergopti_plus/errors.log" } },
			}
		end,
	}
	package.loaded["ui.healthcheck.report"] = {
		redaction_context = function() return { home = "/Users/jdoe", user = "jdoe" } end,
		perform = function() return { ok = true } end,
	}
	local real = require("ui.ui_builder")
	package.loaded["ui.ui_builder"] = setmetatable({
		build_injected_html = function() return "<html></html>" end,
		get_app_geometry = function() return { width = 560, height = 460 } end,
	}, { __index = real })
	return require("ui.error_dialog"), timers
end

helpers.describe("ui-focus-not-topmost: error window (macOS)", function()

	helpers.it("is raised and focused when it opens, at the normal level (ui-focus-not-topmost)", function()
		local saved = {}
		for key, value in pairs(package.loaded) do saved[key] = value end
		local prior_hs = _G.hs
		local ok, err = xpcall(function()
			local view, calls = recording_view(true)
			local app = { activations = 0 }
			local dialog, timers = load_error_dialog(view, app)
			helpers.assert_true(dialog.init(), "the shipped policy must load")
			dialog.on_error("keylogger", "Flush failed", "Flush failed")
			helpers.assert_eq(#timers, 1, "the window opens on its timer")
			timers[1]()
			helpers.assert_eq(calls.shows, 1, "the error window is shown")
			helpers.assert_eq(#calls.levels, 1, "the chrome applies exactly one level")
			assert_never_on_top(calls, "error window")
			-- show() alone leaves a window of the inactive Hammerspoon app behind
			-- the user's key window: it must be raised and the app activated.
			helpers.assert_eq(calls.raises, 1, "the error window is raised once")
			helpers.assert_eq(calls.focuses, 1, "the error window is focused once")
			helpers.assert_eq(app.activations, 1, "Hammerspoon is activated once so the window comes forward")
		end, debug.traceback)
		for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
		for key, value in pairs(saved) do package.loaded[key] = value end
		_G.hs = prior_hs
		if not ok then error(err, 0) end
	end)

end)






-- =========================================================
-- =========================================================
-- ======= 4/ A toggle closes only a window in front =======
-- =========================================================
-- =========================================================

--- Loads the real ui_builder with a focused-window double.
--- @param focused function Returns the focused window, or raises.
--- @return table Builder
local function load_builder_focus(focused)
	return helpers.load_with_stubs("ui.ui_builder", {
		webview = { windowMasks = {}, new = function() return {} end },
		drawing = { windowLevels = LEVELS },
		window = { focusedWindow = focused },
	})
end

--- A webview double whose native window has the given id.
--- @param id number|nil Window id, or nil when no window exists yet.
--- @return table
local function view_with_window(id)
	return { hswindow = function() return id and { id = function() return id end } or nil end }
end

helpers.describe("ui-focus-not-topmost: toggles present a covered window (macOS)", function()

	helpers.it("reads the dashboard as focused only when it is the focused window (ui-focus-not-topmost)",
		function()
			local front = { id = function() return 7 end }
			local Builder = load_builder_focus(function() return front end)
			helpers.assert_true(Builder.is_window_focused(view_with_window(7)),
				"the window the user is looking at is closed by its toggle")
			helpers.assert_true(not Builder.is_window_focused(view_with_window(9)),
				"a window covered by another app must be presented, not closed")
			helpers.assert_true(not Builder.is_window_focused(view_with_window(nil)),
				"a window without a native handle is not in front")
			helpers.assert_true(not Builder.is_window_focused(nil))
			local Failing = load_builder_focus(function() error("private native error") end)
			helpers.assert_true(not Failing.is_window_focused(view_with_window(7)),
				"a failed lookup must present rather than close a window the user may not see")
		end)

	helpers.it("every toggle closes only a focused window (ui-focus-not-topmost)", function()
		local menu = helpers.read_driver_unit("local function close_loaded_dashboard(")
		helpers.assert_true(menu ~= nil, "the menu's dashboard toggle must exist")
		local toggle = menu:match("local function close_loaded_dashboard%(.-\nend")
			or menu:match("local function close_loaded_dashboard%(.-\n\tend")
		helpers.assert_true(toggle ~= nil, "close_loaded_dashboard must be readable")
		local focus_at = toggle:find("is_window_focused(dashboard._wv)", 1, true)
		local close_at = toggle:find("dashboard.close", 1, true)
		helpers.assert_true(focus_at ~= nil and close_at ~= nil and focus_at < close_at,
			"a dashboard shortcut or menu entry must check focus before closing the dashboard")

		local add = menu:match("add_hotstring = function%(%).-\n\t\t\tend,")
		helpers.assert_true(add ~= nil, "the add-hotstring entry must exist")
		local focused_at = add:find("is_editor_focused()", 1, true)
		local editor_close_at = add:find("hotstring_editor.close", 1, true)
		helpers.assert_true(focused_at ~= nil and editor_close_at ~= nil and focused_at < editor_close_at,
			"the add-hotstring entry must not close a covered editor that may hold typed text")

		local editor = helpers.read_driver_unit("function M.is_editor_focused()")
		helpers.assert_true(editor ~= nil, "the hotstring editor must exist")
		helpers.assert_true(editor:find("if _webview and _is_focused then M.close() else M.open(\"shortcut\") end",
			1, true) ~= nil, "the editor shortcut must present a covered editor instead of closing it")
	end)

end)
