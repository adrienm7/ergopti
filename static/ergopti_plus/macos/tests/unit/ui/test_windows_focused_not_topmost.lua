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
