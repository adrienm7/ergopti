--- tests/unit/ui/ui_builder/test_webview_window_no_global_scan.lua

--- ==============================================================================
--- MODULE: Presenting A Webview Never Scans Every Window
--- DESCRIPTION:
--- Opening any webview froze Hammerspoon 2.8 s to 3.2 s on macOS 26 (issue
--- #100): force_focus called wv:hswindow(), whose hs.window.windowForID is
--- get(), i.e. find() over allWindows(), every window of every application.
--- The native double below keeps that exact chain and counts allWindows(); the
--- real focus helper must present the window with no such scan, on a first
--- open, on a re-open and in the focus test (webview-window-no-global-scan).
--- ==============================================================================

local helpers = require("tests.helpers")

local OWN_PID = 4242
local WINDOW_NUMBER = 77

--- Builds the native namespaces and the presented window double.
--- @return table overrides, table counts, table view
local function native_double()
	local counts = { scans = 0, raises = 0, focuses = 0 }
	local own = { id = function() return WINDOW_NUMBER end }
	function own:moveToScreen() return self end
	function own:unminimize() return self end
	function own:raise() counts.raises = counts.raises + 1; return self end
	function own:focus() counts.focuses = counts.focuses + 1; return self end
	local foreign = { id = function() return 5 end }
	local window_module = {}
	function window_module.allWindows()
		counts.scans = counts.scans + 1
		return { foreign, own }
	end
	function window_module.find(hint, _, wins)
		for _, w in ipairs(wins or window_module.allWindows()) do
			if w:id() == hint then return w end
		end
		return nil
	end
	function window_module.get(hint) return window_module.find(hint, true) end
	window_module.windowForID = window_module.get
	function window_module.focusedWindow() return own end
	local view = {}
	function view:hswindow() return hs.window.windowForID(WINDOW_NUMBER) end
	function view:show() return self end
	local overrides = {
		window = window_module,
		application = {
			applicationForPID = function(pid)
				if pid ~= OWN_PID then return nil end
				return { allWindows = function() return { own } end }
			end,
		},
		processInfo = { processID = OWN_PID },
		focus = function() end,
		screen = { mainScreen = function() return {} end },
	}
	return overrides, counts, view
end

--- Runs scheduled retries immediately for the given focus lifecycle.
--- @return table lifecycle
local function immediate_lifecycle()
	return {
		is_current = function() return true end,
		schedule_after = function(_, callback) callback(); return true end,
	}
end

helpers.describe("webview presentation never scans every window (webview-window-no-global-scan)", function()
	helpers.it("presents a new window with no global window scan", function()
		local overrides, counts, view = native_double()
		local Builder = helpers.load_with_stubs("ui.ui_builder", overrides)
		helpers.assert_eq(Builder.force_focus(view, true, immediate_lifecycle()), true)
		helpers.assert_eq(counts.scans, 0, "hswindow() must never reach hs.window.allWindows()")
		helpers.assert_eq(counts.raises, 1, "the own window must still be raised")
		helpers.assert_eq(counts.focuses, 1, "the own window must still be focused")
	end)

	helpers.it("re-presents an open window with no global window scan", function()
		local overrides, counts, view = native_double()
		local moved = 0
		overrides.spaces = {
			activeSpaceOnScreen = function() return 1 end,
			moveWindowToSpace = function(win)
				if win:id() == WINDOW_NUMBER then moved = moved + 1 end
				return true
			end,
		}
		local Builder = helpers.load_with_stubs("ui.ui_builder", overrides)
		helpers.assert_eq(Builder.force_focus(view, false, immediate_lifecycle()), true)
		helpers.assert_eq(counts.scans, 0, "neither the Space move nor the focus may scan every window")
		helpers.assert_eq(moved, 1, "the own window must be moved to the active Space")
		helpers.assert_eq(counts.focuses, 1)
	end)

	helpers.it("tells a focused window with no global window scan", function()
		local overrides, counts, view = native_double()
		local Builder = helpers.load_with_stubs("ui.ui_builder", overrides)
		helpers.assert_eq(Builder.is_window_focused(view), true)
		helpers.assert_eq(counts.scans, 0)
	end)
end)
