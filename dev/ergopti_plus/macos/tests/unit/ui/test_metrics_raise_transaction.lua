--- tests/unit/ui/test_metrics_raise_transaction.lua

--- ==============================================================================
--- MODULE: Metrics Native Presentation Transactions
--- DESCRIPTION:
--- Stops actual dashboard presentation at retirement or a failed native boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.dashboard_window_fixture")

local boundaries = { "show", "bringToFront", "application", "hswindow", "raise", "focus" }

helpers.describe("metrics native presentation", function()
	for _, refused in ipairs({ false, true }) do
		helpers.it("reopens only after failed presentation cleanup, refusal=" .. tostring(refused), function()
			with_window("ui.metrics_apps", function(dashboard, state)
				local builder = package.loaded["ui.ui_builder"]
				local create, creates, stale = builder.show_webview, 0, 0
				builder.show_webview = function(options)
					creates = creates + 1
					local view = create(options)
					if creates == 1 then
						local deleted, delete = false, view.delete
						view.delete = function(self)
							delete(self)
							deleted = true
						end
						view.show = function()
							if deleted then stale = stale + 1 end
							error("native presentation refused")
						end
						view.hswindow = function()
							if deleted then stale = stale + 1; error("deleted native window") end
							return nil
						end
					end
					return view
				end
				state.refused = refused
				helpers.assert_eq(dashboard.show(), false)
				if refused then
					helpers.assert_eq(dashboard.show(), false)
					helpers.assert_eq(creates, 1)
					state.refused = false
					helpers.assert_true(dashboard.close())
				end
				helpers.assert_true(dashboard.show())
				helpers.assert_eq(creates, 2)
				helpers.assert_eq(stale, 0)
			end)
		end)
	end
	helpers.it("commits native void focus and a not-yet-materialized window", function()
		with_window("ui.metrics_apps", function(dashboard, state)
			local focused = 0
			hs.focus = function() focused = focused + 1 end
			helpers.assert_true(dashboard.show())
			helpers.assert_eq(focused, 1)
			helpers.assert_eq(state.deleted, 0)
		end)
	end)
	helpers.it("rolls back a synchronous native presentation exception without success", function()
		with_window("ui.metrics_apps", function(dashboard, state)
			local builder = package.loaded["ui.ui_builder"]
			local create, successes = builder.show_webview, 0
			builder.show_webview = function(options)
				local view = create(options)
				view.show = function() error("private native detail") end
				return view
			end
			package.loaded["infra.logger"].success = function() successes = successes + 1 end
			helpers.assert_eq(dashboard.show(), false)
			helpers.assert_eq(state.deleted, 1)
			helpers.assert_eq(successes, 0)
			helpers.assert_eq(state.view.options.is_current(), false)
		end)
	end)
	for _, boundary in ipairs(boundaries) do
		for _, mode in ipairs({ "retire", "throw" }) do
			helpers.it("stops after " .. boundary .. " " .. mode, function()
				with_window("ui.metrics_apps", function(dashboard, state)
					local pending, calls, errors = {}, {}, {}
					package.loaded["adapters.timer_scheduler"].after = function(_, callback)
						local handle = { timer = {} }
						pending[#pending + 1] = function() handle.timer = nil; callback() end
						return handle, true
					end
					helpers.assert_true(dashboard.show())
					package.loaded["infra.logger"].error = function(_, message, ...)
						errors[#errors + 1] = string.format(message, ...)
					end
					local function invoke(name)
						calls[#calls + 1] = name
						if name == boundary then
							if mode == "throw" then error("private native detail") end
							state.view.options.on_close()
						end
					end
					local win = {}
					for _, name in ipairs({ "raise", "focus" }) do
						win[name] = function(self) invoke(name); return self end
					end
					for _, name in ipairs({ "show", "bringToFront" }) do
						state.view[name] = function(self) invoke(name); return self end
					end
					state.view.hswindow = function() invoke("hswindow"); return win end
					hs.focus = function() invoke("application") end
					pending[1]()
					local expected = {}
					for _, name in ipairs(boundaries) do
						expected[#expected + 1] = name
						if name == boundary then break end
					end
					helpers.assert_eq(table.concat(calls, ","), table.concat(expected, ","))
					helpers.assert_eq(#errors, mode == "throw" and 1 or 0)
					if mode == "throw" then
						helpers.assert_true(errors[1]:find("presentation failed", 1, true) ~= nil)
						helpers.assert_eq(errors[1]:find("private native detail", 1, true), nil)
					end
				end)
			end)
		end
	end
end)
