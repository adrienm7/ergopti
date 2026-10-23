--- tests/unit/adapters/system/test_own_window.lua

--- ==============================================================================
--- MODULE: Own Window Lookup Adapter Tests
--- DESCRIPTION:
--- The native double reproduces Hammerspoon's own chain: hswindow() calls
--- hs.window.windowForID, an alias of get(), which runs find() over
--- allWindows(), counted here as a scan of every window of every application.
--- The adapter must resolve the webview and console windows among this
--- process's windows only (webview-window-no-global-scan, issue #100).
--- ==============================================================================

local helpers = require("tests.helpers")
local OwnWindow = require("adapters.own_window")

local OWN_PID = 4242

--- Builds one window double with an id and a title.
--- @param id number Window number.
--- @param title string Window title.
--- @return table window
local function window_double(id, title)
	return { id = function() return id end, title = function() return title end }
end

--- Runs a callback with a Hammerspoon double installed as the global `hs`.
--- @param state table { own = windows, foreign = windows, focused = window|nil, own_missing = boolean }
--- @param callback function Receives the double and its call counts.
local function with_native(state, callback)
	local previous = rawget(_G, "hs")
	local counts = { scans = 0, own_reads = 0 }
	local window_module = {}
	function window_module.allWindows()
		counts.scans = counts.scans + 1
		local all = {}
		for _, w in ipairs(state.foreign or {}) do all[#all + 1] = w end
		for _, w in ipairs(state.own or {}) do all[#all + 1] = w end
		return all
	end
	function window_module.find(hint, _, wins)
		for _, w in ipairs(wins or window_module.allWindows()) do
			if w:id() == hint then return w end
		end
		return nil
	end
	function window_module.get(hint) return window_module.find(hint, true) end
	window_module.windowForID = window_module.get
	function window_module.focusedWindow() return state.focused end
	local own_app = {
		allWindows = function()
			counts.own_reads = counts.own_reads + 1
			return state.own or {}
		end,
	}
	local native = {
		window = window_module,
		application = {
			applicationForPID = function(pid)
				if pid == OWN_PID and not state.own_missing then return own_app end
				return nil
			end,
		},
		processInfo = { processID = OWN_PID },
		console = {
			hswindow = function() return hs.window.windowForID(state.console_number) end,
		},
	}
	hs = native
	local ok, err = pcall(callback, native, counts)
	hs = previous
	if not ok then error(err, 0) end
end

--- Builds a webview double whose hswindow() is Hammerspoon's native one.
--- @param number number Native window number (windowNumber).
--- @return table view
local function webview_double(number)
	return { hswindow = function() return hs.window.windowForID(number) end }
end

helpers.describe("own window lookup never scans every window (webview-window-no-global-scan)", function()
	helpers.it("finds the webview window among this process's windows only", function()
		local target = window_double(31, "ErgoptiPlus — Error")
		with_native({
			own = { window_double(30, "ErgoptiPlus — Error"), target },
			foreign = { window_double(31, "Foreign"), window_double(9, "Mail") },
		}, function(native, counts)
			local original = native.window.windowForID
			helpers.assert_true(rawequal(OwnWindow.for_webview(webview_double(31)), target),
				"the window carrying the webview's number must be returned, never one sharing its title")
			helpers.assert_eq(counts.scans, 0, "no window of another application may be read")
			helpers.assert_eq(counts.own_reads, 1, "this process's windows must actually be read")
			helpers.assert_true(rawequal(native.window.windowForID, original),
				"windowForID must be restored after the call")
		end)
	end)

	helpers.it("reads a window without a window device as not available yet", function()
		with_native({ own = { window_double(0, "x") } }, function(_, counts)
			helpers.assert_eq(OwnWindow.for_webview(webview_double(0)), nil)
			helpers.assert_eq(counts.scans + counts.own_reads, 0, "no window list may be read for number 0")
		end)
	end)

	helpers.it("reads a window Accessibility does not list yet as not available", function()
		with_native({ own = { window_double(5, "Other") } }, function(_, counts)
			helpers.assert_eq(OwnWindow.for_webview(webview_double(6)), nil)
			helpers.assert_eq(counts.scans, 0)
		end)
	end)

	helpers.it("raises when this process cannot be resolved", function()
		with_native({ own_missing = true }, function(_, counts)
			local ok, err = pcall(OwnWindow.for_webview, webview_double(7))
			helpers.assert_eq(ok, false, "a missing own process must fail, not read as not yet listed")
			helpers.assert_true(tostring(err):find("Hammerspoon process is unavailable", 1, true) ~= nil,
				tostring(err))
			helpers.assert_eq(counts.scans, 0)
		end)
	end)

	helpers.it("restores windowForID and raises when the native call fails", function()
		with_native({}, function(native)
			local original = native.window.windowForID
			local view = { hswindow = function() error("native failure", 0) end }
			local ok, err = pcall(OwnWindow.for_webview, view)
			helpers.assert_eq(ok, false)
			helpers.assert_eq(err, "native failure")
			helpers.assert_true(rawequal(native.window.windowForID, original),
				"a failing native call must not leave the recorder installed")
		end)
	end)

	helpers.it("finds the console window among this process's windows only", function()
		local console = window_double(12, "Hammerspoon Console")
		with_native({ own = { console }, foreign = { window_double(3, "Mail") }, console_number = 12 },
			function(_, counts)
				helpers.assert_true(rawequal(OwnWindow.console(), console))
				helpers.assert_eq(counts.scans, 0)
			end)
	end)

	helpers.it("compares focus by window number without reading any window list", function()
		local view = webview_double(44)
		with_native({ own = { window_double(44, "x") }, focused = window_double(44, "x") }, function(_, counts)
			helpers.assert_eq(OwnWindow.is_webview_focused(view), true)
			helpers.assert_eq(counts.scans + counts.own_reads, 0)
		end)
		with_native({ focused = window_double(45, "y") }, function(_, counts)
			helpers.assert_eq(OwnWindow.is_webview_focused(view), false)
			helpers.assert_eq(counts.scans, 0)
		end)
	end)
end)
