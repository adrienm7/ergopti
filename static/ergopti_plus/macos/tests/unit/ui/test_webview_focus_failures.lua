--- tests/unit/ui/test_webview_focus_failures.lua

--- ==============================================================================
--- MODULE: WebView Focus Failure Outcomes
--- DESCRIPTION:
--- Exercises native exceptions and scheduling refusal through the real focus API.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs one isolated focus transaction with faithful void and object returns.
--- @param mode string Injected failure boundary.
--- @param scenario function Behavioral assertions.
local function with_focus(mode, scenario)
	local saved, prior_hs = {}, _G.hs
	for key, value in pairs(package.loaded) do saved[key] = value end
	local records = { errors = {}, successes = 0, app_focuses = 0, deferred = {} }
	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = {
			debug = function() end, warn = function() end,
			info = function() records.successes = records.successes + 1 end,
			error = function(_, message, ...)
				records.errors[#records.errors + 1] = string.format(message, ...)
			end,
		}
		package.loaded["infra.paths"] = { shared = function() return "/virtual" end }
		package.loaded["infra.deferred_work"] = { after = function(_, callback)
			if mode == "schedule throw" then error("private native error") end
			if mode == "schedule refusal" then return false end
			records.deferred[#records.deferred + 1] = callback
			return true
		end }
		_G.hs = {
			screen = { mainScreen = function()
				if mode == "screen" then error("private native error") end
				return {}
			end },
			focus = function()
				if mode == "app" then error("private native error") end
				records.app_focuses = records.app_focuses + 1
			end,
		}
		local window = {}
		for _, method in ipairs({ "moveToScreen", "raise", "focus" }) do
			window[method] = function(self)
				if mode == method then error("private native error") end
				return self
			end
		end
		package.loaded["hs.spaces"] = {
			activeSpaceOnScreen = function()
				if mode == "space lookup" then error("private native error") end
				if mode == "space lookup refusal" then return nil, "private native error" end
				return 1
			end,
			moveWindowToSpace = function()
				if mode == "space move" then error("private native error") end
				if mode == "space move refusal" then return nil, "private native error" end
				return true
			end,
		}
		local view = {
			hswindow = function()
				if mode == "lookup" then error("private native error") end
				if mode:find("schedule", 1, true) or mode == "fallback" or mode == "async" then return nil end
				return window
			end,
			bringToFront = function(self)
				if mode == "fallback" or mode == "async" then error("private native error") end
				return self
			end,
		}
		package.loaded["ui.ui_builder"] = nil
		local lifecycle = { is_current = function()
			if mode == "owner validation" then error("private native error") end
			return true
		end }
		if mode:find("custom", 1, true) then
			lifecycle.schedule_after = function()
				if mode == "custom schedule throw" then error("private native error") end
				return false
			end
		end
		local result = require("ui.ui_builder").force_focus(view, not mode:find("space", 1, true), lifecycle)
		scenario(result, records)
	end, debug.traceback)
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

helpers.describe("webview focus failure outcomes", function()
	for _, mode in ipairs({ "lookup", "screen", "moveToScreen", "raise", "focus", "app",
		"schedule throw", "schedule refusal", "custom schedule throw", "custom schedule refusal",
		"owner validation", "space lookup", "space move", "space lookup refusal", "space move refusal" }) do
		helpers.it("rejects " .. mode .. " without false success (webview-focus-failure)", function()
			with_focus(mode, function(result, records)
				helpers.assert_eq(result, false)
				helpers.assert_eq(records.successes, 0)
				helpers.assert_eq(#records.errors, 1)
				helpers.assert_eq(records.errors[1]:find("private native error", 1, true), nil)
				helpers.assert_eq(records.app_focuses, 0)
			end)
		end)
	end

	helpers.it("reports an asynchronous terminal failure once (webview-focus-failure)", function()
		with_focus("async", function(result, records)
			helpers.assert_eq(result, true, "the initial retry was actually scheduled")
			for _, callback in ipairs(records.deferred) do callback() end
			helpers.assert_eq(#records.errors, 1)
			helpers.assert_eq(records.successes, 0)
			helpers.assert_eq(records.app_focuses, 0)
			records.deferred[#records.deferred]()
			helpers.assert_eq(#records.errors, 1)
		end)
	end)

	helpers.it("accepts the documented successful space move (webview-focus-failure)", function()
		with_focus("space valid", function(result, records)
			helpers.assert_eq(result, true)
			helpers.assert_eq(records.app_focuses, 1)
			helpers.assert_eq(records.successes, 1)
			helpers.assert_eq(#records.errors, 0)
		end)
	end)

	helpers.it("accepts hs.focus's documented void return (webview-focus-failure)", function()
		with_focus("valid", function(result, records)
			helpers.assert_eq(result, true)
			helpers.assert_eq(records.app_focuses, 1)
			helpers.assert_eq(records.successes, 1)
			helpers.assert_eq(#records.errors, 0)
		end)
	end)
end)
